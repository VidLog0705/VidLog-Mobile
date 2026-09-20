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
/// | `startSession` | Dart → 原生 | 开始录制，参数含工作区目录、单段时长 |
/// | `stopSession` | Dart → 原生 | 停止；**等最后一段封完才返回** |
/// | `setZoom` | Dart → 原生 | 变焦 |
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

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = RecorderPlugin()
        instance.attach(messenger: registrar.messenger())
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

        case "startSession":
            startSession(call, result: result)

        case "stopSession":
            stopSession(result: result)

        case "setZoom":
            guard let args = call.arguments as? [String: Any],
                  let ratio = args["ratio"] as? NSNumber
            else {
                result(FlutterError(code: "bad_args", message: "缺少 ratio", details: nil))
                return
            }
            recorder?.setZoom(CGFloat(truncating: ratio))
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startSession(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard CameraSegmentRecorder.hasCameraPermission else {
            result(FlutterError(code: "permission_denied", message: "没有相机权限", details: nil))
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
        let segmentDuration = durationMs / 1000

        // 上一次没停干净就先停掉，别让两个录制器抢相机。
        recorder?.stop {}

        let created = CameraSegmentRecorder(
            outputDirectory: URL(fileURLWithPath: directory),
            segmentDuration: segmentDuration,
            onEvent: { [weak self] event in self?.emit(event) })

        guard created.start() else {
            result(FlutterError(code: "start_failed", message: "相机未能启动", details: nil))
            return
        }

        recorder = created
        result(nil)
    }

    /// 停止录制。
    ///
    /// **result 要等最后一段封完才回。** 这是刻意的：`finishWriting` 是异步的，
    /// 立刻返回的话 Dart 会以为录完了而马上收尾 —— 最后一段还在写，就被漏掉了。
    private func stopSession(result: @escaping FlutterResult) {
        guard let recorder else {
            result(nil)
            return
        }

        recorder.stop { [weak self] in
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

            case .failed(let message):
                sink([
                    "type": "failed",
                    "message": message,
                ])
            }
        }
    }
}
