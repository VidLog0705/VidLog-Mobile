import AVFoundation
import AVKit
import AudioToolbox
import Flutter
import Foundation
import Photos
import UIKit

/// 原生录制器 ↔ Dart 的桥。
///
/// ## 契约
///
/// 与 Android 侧的 `RecorderChannel.kt` **逐字一致** ——
/// 两端对 Dart 必须长得一样，否则 `lib/recording/recorder_gateway.dart`
/// 就得按平台分叉。
///
/// Dart 侧的对应实现在 `lib/recording/`：本类只负责**投递**，
/// 停录决策、会话收尾、索引写入全部由 Dart 完成。
/// 那些逻辑最容易写错，放在 Dart 里才测得完整（见 `docs/实现决策.md`）。
///
/// | 方法 | 方向 | 语义 |
/// |---|---|---|
/// | `hasCameraPermission` | Dart → 原生 | 是否已授权 |
/// | `requestCameraPermission` | Dart → 原生 | 弹授权框 |
/// | `requestMicrophonePermission` | Dart → 原生 | 弹麦克风授权框（录制声音）；失败不挡录制 |
/// | `openCamera` | Dart → 原生 | 开相机送预览，**不录**；参数含录制规格（§3.1.7）与 `audio` |
/// | `firstUsableSpec` | Dart → 原生 | 候选表里第一个真能跑的**下标**（§3.1.7 的可用性检查） |
/// | `startRecording` | Dart → 原生 | 开始录一段，参数含工作区目录、单段时长 |
/// | `stopRecording` | Dart → 原生 | 停止；**等最后一段封完才返回** |
/// | `closeCamera` | Dart → 原生 | 关相机（结束工作） |
/// | `setZoom` | Dart → 原生 | 变焦 |
/// | `speak` | Dart → 原生 | 语音播报，`beep` 为真时先滴一声（规格 §3.3.2 / §3.3.4 / §3.3.6） |
/// | `segmentClosed` | 原生 → Dart | 一个分段已封闭（**Dart 必须立刻写进 manifest**） |
/// | `sceneSampled` | 原生 → Dart | 画面是否静止 |
/// | `failed` | Dart ← 原生 | 相机/编码出错 |
///
/// ## ⚠️ 未在真机上验证
///
/// 见 `docs/实现决策.md`。
final class RecorderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private static let methodChannelName = "vidlog/recorder"
    private static let eventChannelName = "vidlog/recorder/events"

    private var recorder: CameraSegmentRecorder?
    private var eventSink: FlutterEventSink?

    /// 语音播报（规格 §3.3.2 / §3.3.4 / §3.3.6）。
    ///
    /// 用系统 TTS：不用多带一份音频资源，也**没有许可证要核对**（规格 §10）。
    /// 持住这个实例 —— `AVSpeechSynthesizer` 被释放时会把没念完的话一起丢掉。
    private let speaker = AVSpeechSynthesizer()

    /// 「滴」一声用的系统提示音 id（规格 §3.3.6）。
    ///
    /// 用 `AudioServicesPlaySystemSound` 而**不是** `UIDevice.playInputClick()`：
    /// 后者跟随系统的「键盘反馈」开关 —— 用户把它关掉时功能提示音会一起消失，
    /// 而那一声「滴」是操作员判断「系统认了这一下」的唯一反馈，会被当成 bug
    /// （表盘那个拨轮声用 `playInputClick` 是对的，它本来就该跟着系统开关走；
    /// 这两个音性质不同，所以走两条路）。
    ///
    /// 音频资源：**零**。与 TTS 同一条理由（规格 §10 的许可证账目）。
    /// ⚠️ 音色**本机不可验**（开发机是 Windows、没有真机）。要换就改这一个数字 ——
    /// `1057` = Tink（短促、最像「滴」）、`1005` = New Mail、`1104` = sms-received1。
    private static let beepSoundId: SystemSoundID = 1057

    /// 滴完之后隔多久开口。
    ///
    /// 系统提示音是**异步**播的，紧接着念的话两个音会叠在一起，
    /// 听起来像「滴」被咬了半口。让出一小段，用户听到的才是
    /// 规格 §3.3.6 要的顺序：先滴、再播。
    private static let beepLeadIn: TimeInterval = 0.3

    /// 排着队还没开口的那一次播报。
    ///
    /// 用来兑现「新提示顶掉旧的那句」：见 [speak] 里的说明。
    private var pendingSpeech: DispatchWorkItem?

    /// 预览视图的类型名，与 Dart 侧 `UiKitView(viewType:)` 一致。
    static let previewViewType = "vidlog/camera_preview"

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = RecorderPlugin()
        instance.attach(messenger: registrar.messenger())

        // 预览视图。没有它用户看不到画面、也就没法把面单对准取景框。
        registrar.register(
            CameraPreviewFactory(recorderProvider: { [weak instance] in instance?.recorder }),
            withId: previewViewType)

        // 实时推流那条通道（规格 §3.8）—— **另开一条**，不并进上面那条。
        // 理由见 `LiveChannel` 的类注释（第 2 条隔离规则）。
        let live = LiveChannel(recorderProvider: { [weak instance] in instance?.recorder })
        live.attach(messenger: registrar.messenger())
        registrar.publish(live)

        // 让注册表持住实例 —— 否则它会被释放，通道就成了哑的。
        registrar.publish(instance)
    }

    private func attach(messenger: FlutterBinaryMessenger) {
        let methods = FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        let events = FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: messenger)
        events.setStreamHandler(self)
    }

    // MARK: - EventChannel

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - MethodChannel

    /// 方法分发。
    ///
    /// **不能声明成 `private`** —— 这个签名与 `FlutterPlugin` 协议的要求同名同形，
    /// 可见性必须不低于协议要求（internal），否则编译报
    /// 「must be as accessible as its enclosing type」。
    /// （这个错是 CI 的 macOS 编译抓出来的，Windows 上发现不了。）
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasCameraPermission":
            result(CameraSegmentRecorder.hasCameraPermission)

        case "requestCameraPermission":
            CameraSegmentRecorder.requestCameraPermission { granted in
                DispatchQueue.main.async { result(granted) }
            }

        // 麦克风权限（录制声音，需求方 2026-09-28）。
        // ⚠️ 与相机那条**不一样的地方**：拿不到权限**不挡任何事**（I4），
        // 所以 Dart 那边只看一眼、不据此拦。它唯一的用途是把系统那个框弹出来 ——
        // 不弹的话 `AVCaptureDeviceInput` 会静静地失败，用户看到的就是一个
        // 「打开了却永远没声音」的开关。
        // 已经问过时 `requestAccess` 直接回当前答案，不再弹框。
        case "requestMicrophonePermission":
            CameraSegmentRecorder.requestMicrophonePermission { granted in
                DispatchQueue.main.async { result(granted) }
            }

        // ── 相机与录制是**两件事** ──
        // 规格 §3.2.2：点「开始工作」→ 出现可见的取景框（开相机，不录）；
        // 扫到面单 → 开录。把这两件事合成一个「startSession」是之前的错，
        // 表现是「点了按钮屏幕上什么都没有，但其实在录」。

        case "openCamera":
            openCamera(call, result: result)

        case "firstUsableSpec":
            // 录制前那次**真实的可用性检查**（规格 §3.1.7）。
            //
            // **不需要相机权限、也不开会话** —— 它只是读设备格式。
            // 所以它可以在 Dart 决定要不要开相机之前被调用。
            //
            // 一个都跑不通 / 根本没有相机时给 nil：那是「问不出来」，
            // 与「都不行」在 Dart 那边走同一条路（照用户选的走，见
            // `recording_spec_probe.dart`）—— 那里刻意不把 nil 当成
            // 「降到底档」，否则一次问不出来就会静默改掉用户的画质。
            let candidates = RecorderSpec.parseList(
                (call.arguments as? [String: Any])?["candidates"])
            result(CameraSegmentRecorder.firstUsableIndex(candidates))

        case "startRecording":
            startRecording(call, result: result)

        case "stopRecording":
            stopRecording(result: result)

        case "closeCamera":
            closeCamera(result: result)

        case "setZoom":
            guard let args = call.arguments as? [String: Any],
                  let ratio = args["ratio"] as? NSNumber
            else {
                result(FlutterError(code: "bad_args", message: "缺少 ratio", details: nil))
                return
            }
            recorder?.setZoom(CGFloat(truncating: ratio))
            result(nil)

        case "maxZoom":
            // 相机没开时给 nil —— Dart 侧用保守的默认值，不去猜设备。
            result(recorder?.maxZoomRatio.map { Double($0) })

        case "minZoom":
            // 同上，相机没开时给 nil —— Dart 侧按 1.0 处理
            // （也就是「这台设备没有超广角」，表盘左半圈是平的）。
            result(recorder?.minZoomRatio.map { Double($0) })

        case "focusNow":
            // 表盘滑动时重新对焦（规格 §3.1.2）。
            //
            // 与 `autoFocusAndZoom` 一样刻意**不给 FlutterError 分支**：
            // 相机没开、设备不支持对焦都不是错误，是尽力而为。
            recorder?.focusNow()
            result(nil)

        case "playDetentSound":
            // 拨轮声。同样尽力而为 —— 用户关掉系统「键盘反馈」时就该没声，
            // 那不是失败，是用户自己的选择。
            recorder?.playDetentSound()
            result(nil)

        case "autoFocusAndZoom":
            // 面单进框：对焦 + 临时放大两秒（需求方 2026-09-22）。
            //
            // 刻意**不给 FlutterError 分支**：和 `setZoom` 一样是尽力而为的
            // no-op —— 相机没开、设备不支持对焦，都不该让 Dart 侧看见错误。
            // 两秒后自动回弹的那笔账**由 `recorder` 自己记**（见类里的说明），
            // 这里只管把请求递进去。
            recorder?.autoFocusAndZoom()
            result(nil)

        case "generateThumbnail":
            generateThumbnail(call, result: result)

        case "verifyPlayable":
            verifyPlayable(call, result: result)

        case "readResources":
            readResources(call, result: result)

        case "playVideo":
            playVideo(call, result: result)

        case "shareVideo":
            shareVideo(call, result: result)

        case "speak":
            speak(call, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// 读三个资源信号：剩余存储 / 电量 / 热度（规格 §3.1.1）。
    ///
    /// ⚠️ **三个各自独立地读**，任何一个读不到就**不放那个键** ——
    /// Dart 那边对缺失的语义是「**这一项不参与判定**」
    /// （见 `StopController._onResource`），所以少一项 = 少一重保护，
    /// **不是**「那一项正常」。
    private func readResources(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        var payload: [String: Any] = [:]

        // ① 剩余存储：用 `volumeAvailableCapacityForImportantUsage` —— 它是
        // **给应用用的**那个余量（系统在空间紧张时会先清缓存腾地方），
        // 比 `volumeAvailableCapacity` 更接近「还能录多久」。录像写在 documents 下。
        if let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false),
           let values = try? documents.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            payload["freeStorageBytes"] = free
        }

        // ② 电量：⚠️ **必须先开** `isBatteryMonitoringEnabled`，否则 `batteryLevel`
        // 永远是 -1 —— 而那是个**读不到**，不是「电量 0」。
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            payload["batteryPercent"] = Int((level * 100).rounded())
        }

        // ③ 热度：iOS 只有**四档**，映射到我们那六档（与安卓同一套，都由轻到重）：
        //
        //      .nominal  → 0 nominal
        //      .fair     → 1 light      （轻微，不到阈值）
        //      .serious  → 3 severe     ← 阈值就是这一档 ⇒ **从这里开始停录**
        //      .critical → 4 critical
        //
        // ⚠️ **跳过 2（moderate）是刻意的**：iOS 没有对应档，而把 `.serious`
        // 说成 `moderate` 会让它**够不到阈值**（`reaches(severe)` 为假）——
        // 那等于把最该停的那一档降级了。
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            payload["thermal"] = 0
        case .fair:
            payload["thermal"] = 1
        case .serious:
            payload["thermal"] = 3
        case .critical:
            payload["thermal"] = 4
        @unknown default:
            // 将来加了档 ⇒ **不判定、不猜**（缺键的语义就是「这一项不参与判定」）。
            break
        }

        result(payload)
    }

    /// 这一段成品**解不解得开**（规格 §3.1.4 的「实际解码校验」）。
    ///
    /// ⚠️ **不是**「文件在不在 / 大小对不对」—— 那些收尾里已经查过了。
    /// 这一条要的是**真解码一次**：`AVAssetImageGenerator` 拿得到帧，
    /// 就意味着解码器真的跑通了那一段的数据。
    ///
    /// ⚠️ 解**首尾两处**：只解首帧的话，「录到一半编码器挂了」（头部好、尾部坏）
    /// 会整个漏过去 —— 而那恰恰是最常见的坏法。
    ///
    /// ⚠️ 时长读不出来也**算失败**：连时长都没有，说明容器本身就不对。
    ///
    /// 用 `load(.duration)`（iOS 15+ 的异步版）而不是 `asset.duration` ——
    /// 后者从 iOS 16 起被 deprecate，而本仓的部署目标是 **15.0**
    /// （见 `ios/Runner.xcodeproj` 的 `IPHONEOS_DEPLOYMENT_TARGET`）。
    private func verifyPlayable(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String,
              !videoPath.isEmpty
        else {
            result(FlutterError(code: "bad_args", message: "缺少 videoPath", details: nil))
            return
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))

        Task {
            let seconds: Double

            do {
                seconds = CMTimeGetSeconds(try await asset.load(.duration))
            } catch {
                NSLog("成品校验没过：读不出时长 \(videoPath)（\(error)）")
                result(false)
                return
            }

            guard seconds.isFinite, seconds > 0 else {
                NSLog("成品校验没过：时长无效 \(videoPath)")
                result(false)
                return
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // 只要「解得开」，不看画质 —— 缩到很小，省解码开销。
            generator.maximumSize = CGSize(width: 64, height: 64)
            // ⚠️ 校验**要精确**（与抽帧那条**相反**）：允许容差的话它会拿一个邻近的
            // 关键帧糊弄过去，而那正是「尾部坏了却判成好」的那条路。
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            // 首：1 秒处（第 0 秒常常还是黑的，与抽帧同一个理由）；短视频取一半。
            // 尾：最后 1 秒处（末尾那一帧未必是关键帧，留点余量）。
            let targets = [min(1.0, seconds / 2), max(0, seconds - 1)]

            var ok = true

            for target in targets {
                do {
                    _ = try generator.copyCGImage(
                        at: CMTime(seconds: target, preferredTimescale: 600),
                        actualTime: nil)
                } catch {
                    NSLog("成品校验没过：\(target)s 处解不出帧 \(videoPath)（\(error)）")
                    ok = false
                    break
                }
            }

            result(ok)
        }
    }

    /// 抽一帧当缩略图（规格 §3.4.3）。
    ///
    /// 用系统的 `AVAssetImageGenerator` —— **不引任何第三方包**。
    /// 抽不出来（文件坏了、编解码器不支持）时回 false，**不报错**：
    /// 缩略图是锦上添花，界面显示一个占位方块就行。
    private func generateThumbnail(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String,
              let outputPath = args["outputPath"] as? String,
              !videoPath.isEmpty, !outputPath.isEmpty
        else {
            result(FlutterError(code: "bad_args", message: "缺少 videoPath / outputPath", details: nil))
            return
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        let generator = AVAssetImageGenerator(asset: asset)

        // ⚠️ 允许容差：精确到帧会**逐帧解码**，一页十几条要等很久。
        // 缩略图只要「一眼认出是哪一段」，不要求那一帧正好。
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        DispatchQueue.global(qos: .utility).async {
            do {
                // 取第 1 秒那一帧：第 0 秒常常还是黑的（相机刚起来 / 第一帧没内容）。
                let time = CMTime(seconds: 1, preferredTimescale: 600)
                let image = try generator.copyCGImage(at: time, actualTime: nil)

                guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) else {
                    DispatchQueue.main.async { result(false) }
                    return
                }

                try data.write(to: URL(fileURLWithPath: outputPath))
                DispatchQueue.main.async { result(true) }
            } catch {
                // 抽不出来不是错误 —— 见方法注释。
                DispatchQueue.main.async { result(false) }
            }
        }
    }

    /// 用**系统播放器**播放这一段（规格 §3.4.3 的「播放按钮」）。
    ///
    /// ⚠️ 刻意**不引 `video_player`**：多一个依赖就多一份要核的许可证，
    /// 而系统那个播放器本来就在（与本仓「能走系统 API 就不引包」同一条立场）。
    private func playVideo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String, !videoPath.isEmpty
        else {
            result(FlutterError(code: "bad_args", message: "缺少 videoPath", details: nil))
            return
        }

        guard FileManager.default.fileExists(atPath: videoPath) else {
            // I3：播不了要当场说清楚，而不是「点了没反应」。
            result(FlutterError(code: "missing", message: "这一段在本机上已经不在了", details: nil))
            return
        }

        let player = AVPlayer(url: URL(fileURLWithPath: videoPath))
        let controller = AVPlayerViewController()
        controller.player = player

        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController
        else {
            result(FlutterError(code: "no_view", message: "找不到可以展示播放器的界面", details: nil))
            return
        }

        // 从最顶上那个控制器弹 —— 当前可能已经有别的弹窗（比如删除确认）。
        var presenter = root
        while let next = presenter.presentedViewController {
            presenter = next
        }

        presenter.present(controller, animated: true) {
            player.play()
        }

        result(nil)
    }

    /// 把这一段**原样**交出去（规格 §3.7）：先存进**系统相册**，再弹**系统分享面板**。
    ///
    /// ⚠️ 规格原话：「改掉分享连接，只分享视频本身**无损完整**视频」。
    /// 所以这里**没有任何处理视频的代码** —— 它是「保存 + 交给系统」两步。
    ///
    /// ⚠️ **每一步失败都要说得出原因**（I3）：相册权限被拒是最常见的一种，
    /// 而它表现为「点了没反应」的话，用户只会以为功能坏了。
    /// 分享面板那一步失败**不算整体失败**（东西已经进相册了）。
    private func shareVideo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let videoPath = args["videoPath"] as? String, !videoPath.isEmpty
        else {
            result(FlutterError(code: "bad_args", message: "缺少 videoPath", details: nil))
            return
        }

        let url = URL(fileURLWithPath: videoPath)

        guard FileManager.default.fileExists(atPath: videoPath) else {
            // 「只在归档层就先取回本地」—— 那一步由 Dart 侧负责（它知道归档层在哪儿）。
            result(FlutterError(
                code: "missing",
                message: "这一段的本地副本不在了 —— 先从电脑端取回来再交付。",
                details: nil))
            return
        }

        saveToPhotoLibrary(url) { saveError in
            if let saveError {
                // 相册没存进去 ⇒ 整体失败（用户以为交付了，而相册里什么都没有）。
                result(FlutterError(code: "save_failed", message: saveError, details: nil))
                return
            }

            self.presentShareSheet(url) { shared in
                // 分享面板**没弹出来**也回成功：东西已经在相册里了，
                // 而「用户从相册里自己发」是一条走得通的路。
                result(shared ? nil : nil)
            }
        }
    }

    /// 存进系统相册。回调里的字符串非空表示失败（给用户看的原因）。
    ///
    /// ⚠️ 只要 **`.addOnly`**（「只写」）—— 我们**从不相册里读任何东西**，
    /// 要一个能看光用户全部照片的权限是过分的（iOS 会把两者分成两个授权）。
    private func saveToPhotoLibrary(_ url: URL, completion: @escaping (String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion("没有相册权限。去系统设置里给这个应用打开「照片」，再试一次。")
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    completion(success ? nil : "存进相册失败：\(error?.localizedDescription ?? "未知原因")")
                }
            }
        }
    }

    /// 弹系统分享面板。
    private func presentShareSheet(_ url: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.rootViewController
            else {
                completion(false)
                return
            }

            var presenter = root
            while let next = presenter.presentedViewController {
                presenter = next
            }

            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)

            // iPad 上不给 sourceView 会直接崩（`popoverPresentationController` 为 nil）。
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                    width: 0, height: 0)
            }

            presenter.present(sheet, animated: true) { completion(true) }
        }
    }

    /// 读出一句提示。`beep` 为真时**先滴一声再开口**（规格 §3.3.6）。
    ///
    /// 引擎没装中文语音时 `voice` 会给 nil —— **不能因此判定失败**：
    /// 那时系统会退化成默认语音，用户至少还听得见有提示。
    /// 播报是尽力而为的，Dart 侧也按成功处理（见 `RecorderGateway.speak`）。
    ///
    /// **不等念完就 `result(nil)`**：TTS 是异步的，等它等于让 Dart 侧
    /// 那条事件链干等一两秒。Dart 只关心「递出去了没有」。
    private func speak(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String, !text.isEmpty
        else {
            result(FlutterError(code: "bad_args", message: "缺少 text", details: nil))
            return
        }

        // 新提示顶掉旧的那句。两句提示本来就不会同时出现，
        // 而「面单错误，请扫描正确面单」连着报两次时，叠着念比只念一遍更糟 ——
        // 用户要先听完才知道是同一句。
        //
        // ⚠️ 排队等着开口的那一次也要顶掉（连续扫时两句提示可能只隔几百毫秒，
        // 秒前那句此刻还没出声）。少了这一步，`stopSpeaking` 拦不住它 ——
        // 它是在这之后才被 `speaker.speak` 交进去的。
        pendingSpeech?.cancel()
        pendingSpeech = nil

        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")

        guard args["beep"] as? Bool == true else {
            speaker.speak(utterance)
            result(nil)
            return
        }

        // 顺序是规格 §3.3.6 的原话：「滴一声**然后**播报」。
        AudioServicesPlaySystemSound(Self.beepSoundId)

        let item = DispatchWorkItem { [weak self] in
            self?.pendingSpeech = nil
            self?.speaker.speak(utterance)
        }
        pendingSpeech = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.beepLeadIn, execute: item)

        result(nil)
    }

    /// 开相机、开始送预览。**不录。**
    ///
    /// 规格 §3.2.2：点「开始工作」→ 出现可见的取景框。那时还没扫码。
    private func openCamera(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard CameraSegmentRecorder.hasCameraPermission else {
            result(FlutterError(code: "permission_denied", message: "没有相机权限", details: nil))
            return
        }

        // 只认二维码 —— 只有「扫码连接」那个界面会打开它（规格 §3.4.5 ④）。
        // 缺参数 = false：老版本 Dart 不带这个参数时行为一个字都不变。
        let qrOnly = (call.arguments as? [String: Any])?["qrOnly"] as? Bool ?? false

        // 录制规格。**缺参数 = 默认档**：老版本 Dart 不带它时行为与从前一致。
        let spec = RecorderSpec.parse((call.arguments as? [String: Any])?["spec"])

        // 录制声音（需求方 2026-09-28）。**缺参数 = false = 老行为（不录音）**
        // —— 所以 Dart 那边是显式传这个键的（见 `recorder_gateway.dart`）。
        // 它只能在这一趟给：麦克风是在 `openCamera` 开会话那一步加进去的，
        // 会话建好之后补不进来。
        let audio = (call.arguments as? [String: Any])?["audio"] as? Bool ?? false

        // 实时共享那一路（规格 §3.8）。与 `audio` 同一类：**开会话时定死**，
        // 中途补不上 —— 往跑着的会话里加输出会让它重新配置，
        // 那一下断的是正在录的证据。缺参数 = false = 老行为（不推流）。
        let live = (call.arguments as? [String: Any])?["live"] as? Bool ?? false

        if let recorder, recorder.captureSession.isRunning {
            // ⚠️ 相机已经开着时**只能换识码范围**，不能就这么返回：
            // 录制页把相机开着、用户切到扫码连接那一下，返回早退的话
            // 屏幕上是一维码的白名单在扫一张二维码 —— 表现是**扫了没反应**。
            //
            // ⚠️ **规格换不了**（分辨率与编码是开会话时定死的）。Dart 那边
            // 知道这件事：规格一变它会先 `closeCamera` 再开（见
            // `RecordingCoordinator.openCamera`），所以走到这里还带着不同的
            // 规格，说明那是「顺手带上的默认值」，不是真想改档。
            recorder.qrOnly = qrOnly
            result(nil)
            return
        }

        let created = CameraSegmentRecorder(onEvent: { [weak self] event in
            self?.emit(event)
        })
        created.qrOnly = qrOnly

        guard created.openCamera(spec: spec, audio: audio, live: live) else {
            result(FlutterError(code: "camera_failed", message: "相机未能打开", details: nil))
            return
        }

        recorder = created
        result(nil)
    }

    /// 开始录一段。
    private func startRecording(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let recorder else {
            result(FlutterError(code: "no_camera", message: "相机还没打开", details: nil))
            return
        }

        guard let args = call.arguments as? [String: Any],
              let directory = args["directory"] as? String, !directory.isEmpty
        else {
            result(FlutterError(code: "bad_args", message: "缺少 directory", details: nil))
            return
        }

        let durationMs = (args["segmentDurationMs"] as? NSNumber)?.doubleValue
            ?? CameraSegmentRecorder.defaultSegmentDuration * 1000

        // 水印（规格 §3.6.2）：单号 + **可信时钟**给的开录时刻。
        // ⚠️ 缺参数时退回「没有单号 + 墙钟」——老版本 Dart 不带它们时
        // 行为与从前一致（水印仍会画，只是那行单号是空的）。
        let waybill = args["waybill"] as? String ?? ""
        let trustedStartMs = (args["trustedStartMs"] as? NSNumber)?.doubleValue

        // 录制声音。与 `openCamera` 那处同一个道理：**缺参数 = false = 老行为**。
        // 真正的音轨开关在 `CameraSegmentRecorder.startRecording` 里逐段生效
        // （每一段 writer 都是新起的），这里只是把它带过去。
        let audio = args["audio"] as? Bool ?? false

        let started = recorder.startRecording(
            directory: URL(fileURLWithPath: directory),
            segmentDuration: durationMs / 1000,
            waybill: waybill,
            trustedStartMs: trustedStartMs,
            audio: audio)

        if started {
            result(nil)
        } else {
            result(FlutterError(code: "record_failed", message: "未能开始录制", details: nil))
        }
    }

    /// 停止录制。相机保持开着。
    ///
    /// **result 要等最后一段封完才回。** 这是刻意的：`finishWriting` 是异步的，
    /// 立刻返回的话 Dart 会以为录完了而马上收尾 —— 最后一段还在写，就被漏掉了。
    private func stopRecording(result: @escaping FlutterResult) {
        guard let recorder else {
            result(nil)
            return
        }

        recorder.stopRecording {
            DispatchQueue.main.async { result(nil) }
        }
    }

    /// 关闭相机（结束工作）。
    private func closeCamera(result: @escaping FlutterResult) {
        guard let recorder else {
            result(nil)
            return
        }

        recorder.closeCamera { [weak self] in
            DispatchQueue.main.async {
                self?.recorder = nil
                result(nil)
            }
        }
    }

    // MARK: - 事件投递

    private func emit(_ event: RecorderEvent) {
        // 事件来自相机线程 / 封装完成回调，而 sink **必须在主线程**用。
        DispatchQueue.main.async { [weak self] in
            guard let sink = self?.eventSink else { return }

            switch event {
            case .segmentClosed(let segment):
                sink([
                    "type": "segmentClosed",
                    "filePath": segment.filePath,
                    "sequence": segment.sequence,
                    "startedAtMs": segment.startedAtMs,
                    "endedAtMs": segment.endedAtMs,
                ])

            case .sceneSampled(let isStatic):
                sink([
                    "type": "sceneSampled",
                    "isStatic": isStatic,
                ])

            case .barcodeDetected(let text, let centerX, let centerY, let confidence):
                sink([
                    "type": "barcodeDetected",
                    "text": text,
                    "centerX": centerX,
                    "centerY": centerY,
                    "confidence": confidence,
                ])

            case .failed(let message):
                sink([
                    "type": "failed",
                    "message": message,
                ])
            }
        }
    }
}

/// 实时推流那条通道（规格 §3.8，需求方 2026-10-01 定的方案）。
///
/// ## ⚠️ 为什么**另开一条通道**，不并进 `vidlog/recorder`
///
/// 规格第 2 条（不许传染）：两条通道的失败面分开之后，推流起不来
/// **不会**让录制那条通道上的任何一次调用跟着进错误分支 ——
/// 并进去的话，`RecorderGateway` 的每一个调用点都要开始考虑
/// 「这次失败是不是推流引起的」。
///
/// ## 两条路
///
/// | 通道 | 给什么 |
/// |---|---|
/// | `vidlog/live`（方法） | `startLive(height)` / `stopLive()` / `setLiveQuality(height)` |
/// | `vidlog/live/frames`（事件） | `{type:"frame", key:是否关键帧, data:字节}` 与 `{type:"failed", message}` |
///
/// ⚠️ **失败要回 `FlutterError`，不能回一个字符串** —— Dart 那边
/// `invokeMethod<void>` 会把返回值丢掉，回字符串等于「这边失败了、那边以为成了」。
///
/// ⚠️ **本机编不了**（Windows 上没有 Xcode）。唯一的验证途径是 CI 的
/// `ios-compile-check.yml` 与真机 `.ipa`。
final class LiveChannel: NSObject, FlutterStreamHandler {

    private static let methodChannelName = "vidlog/live"
    private static let eventChannelName = "vidlog/live/frames"

    /// 当前那台录制器。**每次调用现取**：相机会关掉重开，录制器实例会换
    /// （与 `CameraPreviewFactory` 同一个路数）。
    private let recorderProvider: () -> CameraSegmentRecorder?

    private var sink: FlutterEventSink?

    init(recorderProvider: @escaping () -> CameraSegmentRecorder?) {
        self.recorderProvider = recorderProvider
        super.init()
    }

    /// 注册通道。**由 `RecorderPlugin.register` 调**，不由注册表直接发现 ——
    /// 它要拿到同一个 `recorder` 实例（那个实例会随相机关开而换）。
    func attach(messenger: FlutterBinaryMessenger) {
        let methods = FlutterMethodChannel(name: Self.methodChannelName, binaryMessenger: messenger)
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        let events = FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: messenger)
        events.setStreamHandler(self)
    }

    // MARK: - EventChannel

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    // MARK: - MethodChannel

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "startLive":
            guard let recorder = recorderProvider() else {
                result(FlutterError(
                    code: "live_failed", message: "相机还没开，推流起不来", details: nil))
                return
            }

            let lines = args?["height"] as? Int ?? LiveStreamer.tileLines

            let failure = recorder.startLive(
                lines: lines,
                onFrame: { [weak self] isKey, data in self?.emitFrame(isKey: isKey, data: data) },
                onFailure: { [weak self] message in self?.emitFailure(message) })

            if let failure {
                // ⚠️ **回 FlutterError，不是回那个字符串**：Dart 那边
                // `invokeMethod<void>` 会把返回值丢掉。
                result(FlutterError(code: "live_failed", message: failure, details: nil))
            } else {
                result(nil)
            }

        case "stopLive":
            recorderProvider()?.stopLive()
            result(nil)

        case "setLiveQuality":
            let lines = args?["height"] as? Int ?? LiveStreamer.tileLines
            recorderProvider()?.setLiveLines(lines)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 事件投递

    private func emitFrame(isKey: Bool, data: Data) {
        // ⚠️ 没有订阅者时**一个字节都不发**：这条路每帧都要拷一次内存
        // （30fps × 几万字节），而没人看的时候那些拷贝是白花的 ——
        // 本仓已经因为「白跑的活儿」吃过一次亏。
        guard sink != nil else { return }

        DispatchQueue.main.async { [weak self] in
            self?.sink?([
                "type": "frame",
                "key": isKey,
                "data": FlutterStandardTypedData(bytes: data),
            ])
        }
    }

    private func emitFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.sink?(["type": "failed", "message": message])
        }
    }
}
