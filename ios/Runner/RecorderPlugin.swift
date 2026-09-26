import AVFoundation
import AudioToolbox
import Flutter
import Foundation

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
/// | `openCamera` | Dart → 原生 | 开相机送预览，**不录** |
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

        // ── 相机与录制是**两件事** ──
        // 规格 §3.2.2：点「开始工作」→ 出现可见的取景框（开相机，不录）；
        // 扫到面单 → 开录。把这两件事合成一个「startSession」是之前的错，
        // 表现是「点了按钮屏幕上什么都没有，但其实在录」。

        case "openCamera":
            openCamera(call, result: result)

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

        case "speak":
            speak(call, result: result)

        default:
            result(FlutterMethodNotImplemented)
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

        if let recorder, recorder.captureSession.isRunning {
            // ⚠️ 相机已经开着时**只能换识码范围**，不能就这么返回：
            // 录制页把相机开着、用户切到扫码连接那一下，返回早退的话
            // 屏幕上是一维码的白名单在扫一张二维码 —— 表现是**扫了没反应**。
            recorder.qrOnly = qrOnly
            result(nil)
            return
        }

        let created = CameraSegmentRecorder(onEvent: { [weak self] event in
            self?.emit(event)
        })
        created.qrOnly = qrOnly

        guard created.openCamera() else {
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

        let started = recorder.startRecording(
            directory: URL(fileURLWithPath: directory),
            segmentDuration: durationMs / 1000)

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
