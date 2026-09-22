import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UIKit  // UIDevice.playInputClick()（表盘拨轮声）；AVFoundation 不保证带出来
import Vision

/// 一个已经封闭的分段。
struct ClosedSegment {
    let filePath: String
    let sequence: Int
    /// 相对会话起点的**单调**毫秒偏移。
    let startedAtMs: Int
    let endedAtMs: Int
}

/// 原生层向 Dart 上报的事件。
enum RecorderEvent {
    case segmentClosed(ClosedSegment)
    /// 画面是否「连续无显著变化」（规格 §3.3.3）。
    case sceneSampled(isStatic: Bool)
    /// 识别到一个条码。
    ///
    /// ⚠️ **这不等于「用户扫了一次码」** —— 相机是连续识码的，
    /// 包裹摆在画面里会每秒报好几次。把它变成离散的扫码事件是 Dart 侧
    /// `ScanGate` 的职责（那一层带测试）。
    case barcodeDetected(text: String, centerX: Double, centerY: Double, confidence: Double)
    case failed(String)
}

/// 连续分段录制（iOS）。
///
/// 规格 §3.1.1：
/// > 连续录制，**不因单次时长、文件大小、切分而中断用户体验**
/// > （用户感知为「一直在录」）；落盘为若干分段，每段可独立播放。
///
/// ## 与 Android 实现的差异（刻意的）
///
/// Android 是「**一个编码器 + 换封装器**」：`MediaCodec` 全程不停，只换 `MediaMuxer`。
/// 那边必须**自己保证轮转落在关键帧上**，否则新分段开头不是 I 帧、整个文件解不开。
///
/// iOS 的 `AVAssetWriter` 没这个口子 —— 轮转必然是「收掉旧的、开新的」，
/// 而每个新 writer 都从头编码，**天然从 I 帧开始**。
/// 少了一层要小心的地方，代价是每次轮转要重开一次编码会话。
///
/// ## ⚠️ 两条容易写错的地方
///
/// **一、先开新的，再收旧的。** `finishWriting` 是异步的。按直觉写成
/// 「先 finish 再开新 writer」，finish 期间到达的帧就无处可去 —— 直接丢掉，
/// 用户看到画面跳一下，正好违反上面那条「不因切分而中断」。
///
/// **二、`stop` 要等最后一段封完才算完。** 否则调用方拿到返回就以为录完了，
/// 而最后一段还在写 —— 那段录像会被漏掉。见 [stop]。
///
/// ## ⚠️ 这个文件没有在真机上跑过
///
/// 见 `docs/实现决策.md`：本机是 Windows，连 Xcode 都没有，
/// 只验证到「CI 的 macOS 编译能过」。相机时序、轮转、掉电收尾
/// **必须**走一遍真机回归才能算数。
final class CameraSegmentRecorder: NSObject {

    // MARK: - 配置

    /// 单段时长。掉电最多丢这么多。
    static let defaultSegmentDuration: TimeInterval = 5 * 60

    private static let analysisWidth = 160
    private static let analysisHeight = 120
    private static let analysisInterval: TimeInterval = 0.5

    /// 相邻两次采样之间，亮度平均绝对差低于这个值就算「没动」。
    private static let staticDiffThreshold = 3.0

    private static let bitRate = 8_000_000
    private static let frameRate: Int32 = 30

    /// 关键帧间隔（秒）。它决定「单独播放某一段时，开头要等多久才出画面」。
    private static let keyFrameIntervalSeconds = 1

    /// 识码的采样间隔。**不跑满帧** —— 识码比静止检测贵得多，
    /// 而包裹摆在那儿几秒内扫到就够了。
    private static let barcodeScanInterval: TimeInterval = 0.3

    /// 支持的条码类型。
    ///
    /// 只开了**一维码**：这类条码里装的就是单号本身。
    ///
    /// **刻意没开二维码（QR / DataMatrix / PDF417）**：电子面单上的二维码里
    /// 装的往往是 URL 或一段结构化文本，直接当单号用会往单号字段里灌进
    /// 一整条 URL。要用得先知道各家承运商的载荷格式、从里面抽出单号 ——
    /// 那是另一件事，别在这里猜。
    private static let barcodeSymbologies: [VNBarcodeSymbology] = [
        .code128,  // 快递面单上最常见
        .code39,
        .code93,
        .itf14,
        .ean13,
        .ean8,
        .upce,
    ]

    // MARK: - 状态

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "vidlog.camera.session")
    private let videoQueue = DispatchQueue(label: "vidlog.camera.video")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var analysisOutput: AVCaptureVideoDataOutput?
    private var captureDevice: AVCaptureDevice?

    /// 当前录制段的落盘位置。**只在录制期间有效** —— 相机可以开着而不录。
    private var outputDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private var segmentDuration: TimeInterval = CameraSegmentRecorder.defaultSegmentDuration
    private let onEvent: (RecorderEvent) -> Void

    /// 相机是否已打开（**不等于正在录**）。
    ///
    /// 这两件事必须分开：规格 §3.2.2 要求点了「开始工作」就**出现可见的取景框**，
    /// 而那时还没扫码、还不该录。相机开着预览、等扫到面单才开始录。
    private var cameraOpen = false

    private var currentWriter: SegmentWriter?
    private var segmentSequence = -1
    private var sessionStartedAt: TimeInterval = 0
    private var sessionStartedWallClock = Date()

    private var lastAnalysisAt: TimeInterval = 0
    private var lastBarcodeScanAt: TimeInterval = 0
    private var previousLuma: [UInt8]?
    private var lastReportedStatic: Bool?

    /// 停止时等最后一段封完。
    private var pendingStopCompletion: (() -> Void)?

    /// 状态锁保护 [running] 与 [currentWriter]（相机线程与调用方线程都会碰）。
    private let stateLock = NSLock()
    private var running = false

    var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    init(onEvent: @escaping (RecorderEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    /// 预览层要挂的会话。
    ///
    /// 预览与录制共用同一个 `AVCaptureSession` —— 这是必须的：
    /// 分成两个会话会抢相机，而且用户看到的画面与录下来的画面可能不一致。
    var captureSession: AVCaptureSession { session }

    // MARK: - 权限

    static var hasCameraPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestCameraPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    // MARK: - 生命周期

    /// 打开相机并开始送预览。
    ///
    /// **不开始录制。** 规格 §3.2.2：用户点「开始工作」→ 画面出现**可见的取景框**；
    /// 那时还没扫码，不该录。所以相机开着送预览、等扫到面单才开始录。
    ///
    /// 返回 false 表示相机打不开。
    func openCamera() -> Bool {
        guard !cameraOpen else { return true }

        guard let device = Self.pickBackCamera() else {
            onEvent(.failed("找不到可用的后置摄像头"))
            return false
        }
        captureDevice = device

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                onEvent(.failed("相机输入无法加入会话"))
                return false
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            onEvent(.failed("打开相机失败：\(error.localizedDescription)"))
            return false
        }

        guard addVideoOutput() else {
            session.commitConfiguration()
            return false
        }
        addAnalysisOutput()

        session.commitConfiguration()

        // 方向必须在 commit 之后设 —— 输出刚 add 进去时它的 connection
        // 还不一定存在，那时设等于白设，画面会拍成横的。
        //
        // **分析那一路也要设同样的方向**：识码是在那一路的帧上跑的，
        // 两边方向不一致的话，录出来的画面和识码看到的画面会差 90°。
        for output in [videoOutput, analysisOutput].compactMap({ $0 }) {
            if let connection = output.connection(with: .video) {
                applyOrientation(to: connection)
            }
        }

        cameraOpen = true

        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }

        return true
    }

    /// 开始录一段。
    ///
    /// 与 [openCamera] 分开是刻意的 —— 见那边的说明。
    /// [directory] 是这一段（= 一个会话）的落盘位置。
    func startRecording(directory: URL, segmentDuration: TimeInterval) -> Bool {
        guard cameraOpen, !isRecording else { return false }

        outputDirectory = directory
        self.segmentDuration = segmentDuration

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        sessionStartedAt = CACurrentMediaTime()
        sessionStartedWallClock = Date()
        segmentSequence = -1
        currentWriter = nil
        previousLuma = nil
        lastReportedStatic = nil

        stateLock.lock()
        running = true
        stateLock.unlock()

        // writer 不在这里建 —— 尺寸与像素格式要等第一帧才知道（见 appendFrame）。
        return true
    }

    /// 停止录制。**相机保持开着**，取景框还在，下件包裹接着扫。
    ///
    /// **回调在最后一段封闭之后才会触发。** 这是刻意的：
    /// `finishWriting` 是异步的，如果立刻返回，调用方会以为录完了，
    /// 而最后一段还在写 —— 那段录像就被漏掉了。
    func stopRecording(_ completion: @escaping () -> Void) {
        stateLock.lock()
        let wasRunning = running
        running = false
        let writer = currentWriter
        currentWriter = nil

        // 只在真的需要等的时候挂上 —— 否则下面那条 `completion()` 直通路径
        // 会让同一个 completion 被调两次，而 FlutterResult 提交两次会直接崩。
        if wasRunning {
            pendingStopCompletion = completion
        }
        stateLock.unlock()

        guard wasRunning else {
            completion()
            return
        }

        if let writer {
            finish(writer)

            // 兜底：万一 finishWriting 的回调没来（文件已被移走、writer 处于
            // 异常态等等），stopSession 会**永久挂住**，Dart 侧跟着卡死。
            // 到点强制作答一次；正常路径已经答过的话这里是空操作。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.completeStopIfNeeded()
            }
        } else {
            // 一段都没录到（比如刚开就停）。
            completeStopIfNeeded()
        }
    }

    /// 关闭相机（结束工作）。会先把在录的那段收干净。
    func closeCamera(_ completion: (() -> Void)? = nil) {
        // 待回弹的自动放大要撤掉：会话马上就要拆了，那个闭包会在两秒后
        // 去改一台 `captureDevice` 已经是 nil 的设备（或更糟 —— 改到
        // 下一次开相机的新设备上）。
        cancelPendingAutoZoomRestore()

        stopRecording { [weak self] in
            guard let self else {
                completion?()
                return
            }

            self.sessionQueue.async {
                self.session.stopRunning()
            }

            self.cameraOpen = false
            self.captureDevice = nil
            completion?()
        }
    }

    /// 设备支持的变焦上限。相机没开时为 nil。
    ///
    /// 规格 §3.1.2：半圆刻度盘的刻度要画到哪，取决于这个值 ——
    /// 表盘划到底就该是设备的上限，不然表盘在骗用户。
    var maxZoomRatio: CGFloat? {
        captureDevice?.maxAvailableVideoZoomFactor
    }

    /// 设备支持的**最小**变焦下限。相机没开时为 nil。
    ///
    /// 2026-09-22 起表盘左端不再是个常数：`pickBackCamera` 会优先挑带超广角的
    /// 虚拟设备，那时这里给 **0.5**；只有广角镜头的设备仍是 1.0。
    /// 表盘的左半圈（比初始画面更广的那一半）只有它小于 1 时才存在。
    var minZoomRatio: CGFloat? {
        captureDevice?.minAvailableVideoZoomFactor
    }

    /// 设置缩放倍率。规格 §3.1.2：倍率不得超过设备能力上限。
    ///
    /// **这里是瞬时的，不 ramp。** 表盘要跟手 —— 手指划到哪画面就得在哪，
    /// 中间隔一段平滑动画的话手感是「拖不动」。缓进缓出只针对
    /// **面单进框的自动放大**（见 `rampZoom`）。
    func setZoom(_ ratio: CGFloat) {
        // 操作员自己拖了表盘 —— 那是他**此刻的意图**，要撤销待回弹的自动放大。
        // 不撤销的话，两秒后画面会从他刚调好的倍率跳回去，看起来像表盘失灵。
        cancelPendingAutoZoomRestore()

        guard let device = captureDevice else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // 自动放大正在路上时，用户又拖了表盘：把那段 ramp 掐掉再赋值。
            // 直接赋 `videoZoomFactor` 也会取消 ramp，但那靠的是文档里一句话；
            // 明写一行不花钱，而「表盘和自己在飞的动画打架」是很难查的现象。
            device.cancelVideoZoomRamp()

            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(ratio, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
        } catch {
            // 变焦失败不该中断录制。
            NSLog("VidLog: 设置变焦失败 %@", error.localizedDescription)
        }
    }

    // MARK: - 面单进框：自动对焦 + 临时放大

    /// 自动放大到几倍（需求方 2026-09-22 裁决 #8：固定 2 倍）。
    private static let autoZoomFactor: CGFloat = 2.0

    /// 放大保持多久。之后回到操作员原来的倍率。
    ///
    /// ⚠️ 这是**到位之后**再保持的时长，不是从触发算起 —— 见
    /// `scheduleAutoZoomRestore(after:)`：路上走的时间要另加。
    private static let autoZoomHold: TimeInterval = 2.0

    /// 平滑变焦的速率（倍/秒）。**这就是「缓进缓出」那个「缓」**。
    ///
    /// 规格 §3.1.2：面单进框的自动放大「**必须是缓进缓出**（推进 / 推远都有
    /// 过程），**不得**表现为画面瞬间跳大、瞬间跳小」。
    /// 3.0 ≈ 1×→2× 走约 0.33 秒。
    ///
    /// ⚠️ **这个数只能真机调。** `withRate` 在文档里是「倍/秒」，但实际手感
    /// 是不是严格线性、慢到多少算合适，本机（Windows、没有摄像头）验不了。
    /// 嫌快就调小、嫌慢就调大，**只改这一个数**。
    ///
    /// ⚠️ 诚实说明：`ramp` 是**线性**速率，不是 S 曲线。需求方要的
    /// 「不要突然放大 / 突然缩小」它完全满足；严格意义的「缓进缓出」
    /// （起手慢、中间快、收尾慢）它没有。真机觉得硬再改逐帧曲线。
    private static let zoomRampRate: CGFloat = 3.0

    /// 自动放大前的倍率。**只在没有待回弹时才记**，见 `autoFocusAndZoom`。
    private var savedZoomFactor: CGFloat?

    /// 待回弹的定时任务。非 nil 就表示「现在是自动放大状态」。
    private var zoomRestoreWorkItem: DispatchWorkItem?

    /// 面单刚进框：对焦到画面正中 + 临时放大，两秒后回到原倍率。
    ///
    /// 计时**归原生**，不是 Dart —— 回弹必须落在**同一台 `AVCaptureDevice`
    /// 对象**上。放 Dart 计时的话，中间一次 `closeCamera`/`openCamera`
    /// 会让回调去改新会话的倍率。原生自己持有就等于零同步、零新 Dart 状态。
    ///
    /// **尽力而为，什么都不抛**：与 `setZoom` 一样，失败就当作没发生。
    func autoFocusAndZoom() {
        guard let device = captureDevice else { return }

        applyAutoFocus(on: device)

        // ── 放大 ──
        //
        // 棘轮式：`min(max(当前倍率, 2.0), 上限)` —— **绝不往回缩**。
        // 操作员自己拖到 3× 时，自动放大不该先把画面变小一下。
        let current = device.videoZoomFactor
        let target = max(device.minAvailableVideoZoomFactor,
                         min(max(current, Self.autoZoomFactor),
                             device.maxAvailableVideoZoomFactor))
        rampZoom(to: target, on: device)

        // ⚠️ **只在「没有待回弹」时记原值。**
        // 连续扫每件都会触发一次；每次都记的话，记下的就是上一次放大后的值，
        // 倍率会一级一级往上爬，最后停在设备上限上再也回不来。
        if zoomRestoreWorkItem == nil {
            savedZoomFactor = current
        }

        scheduleAutoZoomRestore(after: rampSeconds(from: current, to: target))
    }

    /// 从 `from` 推到 `to` 要走多久（秒）。
    ///
    /// `withRate` 的单位是**倍/秒**，所以是距离除以速率。`rampZoom` 走不到
    /// 的那一小段距离会被它当成 0 —— 这里也要一致，不然会白等一小会儿。
    private func rampSeconds(from: CGFloat, to: CGFloat) -> TimeInterval {
        let distance = abs(to - from)
        guard distance > Self.rampMinimumDistance, Self.zoomRampRate > 0 else { return 0 }
        return TimeInterval(distance / Self.zoomRampRate)
    }

    /// 平滑地把倍率推到 `target`。**「缓进缓出」的实现就在这一句 `ramp`。**
    ///
    /// 为什么不用 `videoZoomFactor = x`：那是**瞬时跳变**，需求方 2026-09-22
    /// 明确否掉了（「不要突然放大，突然缩小」）。这一条**撤回了**
    /// `docs/实现决策.md` §18.6 里「不用动画」的旧决策。
    ///
    /// 表盘**不走这里**：拖动要跟手，必须瞬时（见 `setZoom`）。
    ///
    /// **尽力而为，什么都不抛。**
    private func rampZoom(to target: CGFloat, on device: AVCaptureDevice) {
        let clamped = max(device.minAvailableVideoZoomFactor,
                          min(target, device.maxAvailableVideoZoomFactor))

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // 距离太小就别起步：`ramp` 在零距离上没有意义，而且不同机型
            // 对「速率必须为正」的挑剔程度不一样，不值得去撞。
            if abs(clamped - device.videoZoomFactor) < Self.rampMinimumDistance {
                device.videoZoomFactor = clamped
                return
            }

            device.ramp(toVideoZoomFactor: clamped,
                        withRate: Float(Self.zoomRampRate))
        } catch {
            NSLog("VidLog: 平滑变焦失败 %@", error.localizedDescription)
        }
    }

    /// 认为「已经很接近目标、不必再 ramp」的距离阈值（倍）。
    ///
    /// 0.005 相当于屏幕上几个像素 —— 比它小就没人看得出来。
    private static let rampMinimumDistance: CGFloat = 0.005

    /// 立刻对焦到画面正中，**不动倍率**。
    ///
    /// 规格 §3.1.2：表盘滑动时「无论怎么滑都自动对焦」。倍率一变，原来对好的
    /// 那点就不实了 —— 所以每滑一段都要重新对一次。与 `autoFocusAndZoom`
    /// 共用 `applyAutoFocus`，区别只是不放大、不计时回弹。
    ///
    /// **尽力而为，什么都不抛**：与 `setZoom` 一样，失败就当作没发生。
    func focusNow() {
        guard let device = captureDevice else { return }
        applyAutoFocus(on: device)
    }

    /// 拨一下齿轮的模拟声（表盘滑过一个刻度）。规格 §3.1.2。
    ///
    /// 用系统的**输入点击音**（`UIDevice.playInputClick()`）：文档化 API、
    /// **不带任何音频资源** —— 洁净室与许可证（规格 §10）的账上就少一笔，
    /// 与 TTS 走系统是同一个理由。
    ///
    /// 音量与开关**跟随系统**的「键盘反馈」：用户把它关掉时不响是**正常的**，
    /// 不是 bug。真机上要按这条验。
    ///
    /// **尽力而为，什么都不抛。**
    func playDetentSound() {
        UIDevice.current.playInputClick()
    }

    /// 把对焦点设到画面正中并触发一次自动对焦。
    ///
    /// 对焦点取 `(0.5, 0.5)`（画面正中），**不是算出来的**。
    /// 取景框永远是屏幕居中的（`Viewfinder.rectOn` 只居中不偏移），
    /// 而正中在任何屏幕方向下都是正中 —— 绕开了 `focusPointOfInterest`
    /// 那一圈方向换算。那一圈是经典 bug 源，且**在这台机器上定不了**：
    /// 本文件里就有一处自相矛盾（分析缓冲按 1280×720 说，另一处按竖屏算）。
    ///
    /// 任何时候要把对焦点挪到非中心，先在真机上把那圈方向问题解决掉，
    /// **不要猜**。
    private func applyAutoFocus(on device: AVCaptureDevice) {
        guard device.isFocusPointOfInterestSupported,
              device.isFocusModeSupported(.autoFocus) else { return }

        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            device.focusMode = .autoFocus
            device.unlockForConfiguration()
        } catch {
            NSLog("VidLog: 自动对焦失败 %@", error.localizedDescription)
        }
    }

    /// 排下回弹。`delay` 是**推到位**要花的时间，保持时长另加。
    ///
    /// ⚠️ 为什么不是直接 `autoZoomHold`：那 2 秒里得有一段是在路上，
    /// 面单拿到「清晰且在 2 倍上」的时间就缩水了（推 1×→2× 要 0.33 秒，
    /// 就少了六分之一）。规格 §3.1.2 说「约 2 秒后推回」，
    /// 指的是**到位之后**再保持约 2 秒。
    private func scheduleAutoZoomRestore(after delay: TimeInterval) {
        zoomRestoreWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.restoreAfterAutoZoom()
        }
        zoomRestoreWorkItem = work

        // 主队列：`captureDevice` 的配置与关闭都在主线程那侧，避免与
        // `closeCamera` 抢同一台设备。
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay + Self.autoZoomHold,
            execute: work)
    }

    private func restoreAfterAutoZoom() {
        zoomRestoreWorkItem = nil

        defer { savedZoomFactor = nil }

        guard let device = captureDevice, let saved = savedZoomFactor else { return }

        rampZoom(to: saved, on: device)
    }

    /// 撤销待回弹的自动放大（操作员自己动了表盘、或相机会话要拆了）。
    ///
    /// 不撤销的话：前者表现为「表盘失灵」（画面从刚调好的倍率跳回去），
    /// 后者表现为「回弹落在一个已经拆掉的会话上」。
    private func cancelPendingAutoZoomRestore() {
        zoomRestoreWorkItem?.cancel()
        zoomRestoreWorkItem = nil
        savedZoomFactor = nil
    }

    // MARK: - 相机配置

    /// 挑后置摄像头。**顺序是有讲究的**（需求方 2026-09-22 裁决：要真做到 0.5×）。
    ///
    /// 逐个按**显式优先序**问 `AVCaptureDevice.default(_:for:position:)`，
    /// **不用 `DiscoverySession.devices.first`** —— 它的顺序没有保证，
    /// 拿到广角镜头就再也划不到 0.5×（表盘左半圈整段是死的，用户会以为坏了）。
    ///
    /// `.builtInTripleCamera` / `.builtInDualWideCamera` 是**虚拟设备**：
    /// 它们自带超广角，`minAvailableVideoZoomFactor` 会给到 0.5，
    /// 跨过 1.0 时由 iOS 自动在组成镜头之间切换。
    ///
    /// 为什么不把 `.builtInDualCamera`（广角 + 长焦）也排进来：它的下限同样是
    /// 1.0，给不了 0.5×，而它的上限并不比广角高 —— 加了只会多一个分支，
    /// 不改变任何行为。
    private static func pickBackCamera() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
        ]

        for type in preferred {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }

        // 一个都没匹配上：按「随便给个后置」兜底，总比没有画面强。
        return AVCaptureDevice.default(for: .video)
    }

    private func addVideoOutput() -> Bool {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true

        // 用相机原生的双平面 YUV，避免每帧多做一次色彩空间转换。
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]

        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            onEvent(.failed("无法加入视频输出"))
            return false
        }

        session.addOutput(output)
        videoOutput = output
        return true
    }

    /// 静止检测用的第二路输出。
    ///
    /// ⚠️ **它拿到的仍然是会话分辨率**（1280×720）——
    /// `videoSettings` 只能改像素格式，改不了尺寸。
    /// 所以真正的降采样在 [handleAnalysisFrame] 里按网格抽样做，
    /// 这里只是把这一路跟录制那一路分开，免得分析影响编码。
    private func addAnalysisOutput() {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]

        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            // 静止检测起不来不该让录制起不来（I4 的同一条精神）。
            NSLog("VidLog: 无法加入分析输出，静止检测将不可用")
            return
        }

        session.addOutput(output)
        analysisOutput = output
    }

    /// 让画面跟上设备方向。
    ///
    /// iOS 17 起 `videoOrientation` 废弃，改用 `videoRotationAngle`；两套都写。
    private func applyOrientation(to connection: AVCaptureConnection) {
        let angle: CGFloat = 90 // 竖屏持机

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - 分段

    /// 一个正在写的分段。
    private final class SegmentWriter {
        let sequence: Int
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let fileURL: URL
        let startedAt: TimeInterval

        /// 记下来给下一个分段用 —— 轮转时不该再去反推尺寸。
        let width: Int
        let height: Int

        /// 是否已经 `startSession(atSourceTime:)`。
        ///
        /// **这个标志是必需的**：`AVAssetWriter` 在 `startWriting()` 之后、
        /// 追加任何样本之前，**必须**先开一个写入会话。少了这一步，
        /// 第一次 append 会直接抛 `NSException` —— 应用当场闪退。
        /// （这个 bug 是真机抓到的：编译全绿，一按开始工作就崩。）
        var sessionStarted = false

        init(sequence: Int, writer: AVAssetWriter, input: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor, fileURL: URL,
             startedAt: TimeInterval, width: Int, height: Int) {
            self.sequence = sequence
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.fileURL = fileURL
            self.startedAt = startedAt
            self.width = width
            self.height = height
        }
    }

    private func segmentURL(_ sequence: Int) -> URL {
        outputDirectory.appendingPathComponent(String(format: "segment-%03d.mp4", sequence))
    }

    private func makeWriter(sequence: Int, width: Int, height: Int) -> SegmentWriter? {
        let url = segmentURL(sequence)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            onEvent(.failed("无法创建分段文件 segment-\(sequence)"))
            return nil
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.frameRate),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.frameRate) * Self.keyFrameIntervalSeconds,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ])

        guard writer.canAdd(input) else {
            onEvent(.failed("无法加入视频轨"))
            return nil
        }

        writer.add(input)

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "未知原因"
            onEvent(.failed("分段 \(sequence) 开始写入失败：\(reason)"))
            return nil
        }

        return SegmentWriter(sequence: sequence, writer: writer, input: input,
                             adaptor: adaptor, fileURL: url,
                             startedAt: CACurrentMediaTime(),
                             width: width, height: height)
    }

    /// 封闭一个分段并上报。
    private func finish(_ segment: SegmentWriter) {
        let sequence = segment.sequence
        let url = segment.fileURL
        let startedAt = segment.startedAt
        let sessionStart = sessionStartedAt

        segment.input.markAsFinished()

        segment.writer.finishWriting { [weak self] in
            guard let self else { return }
            let endedAt = CACurrentMediaTime()

            if segment.writer.status == .completed, Self.fileHasContent(url) {
                let segment = ClosedSegment(
                    filePath: url.path,
                    sequence: sequence,
                    startedAtMs: Int((startedAt - sessionStart) * 1000),
                    endedAtMs: Int((endedAt - sessionStart) * 1000))
                self.onEvent(.segmentClosed(segment))
            }
            // 没写进内容的分段（比如刚开始轮转就停了）就不上报 ——
            // 报一条空分段只会让上层多一条无用的记录。

            self.completeStopIfNeeded()
        }
    }

    private static func fileHasContent(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }

    /// 停止请求等的那一段封完了吗。
    private func completeStopIfNeeded() {
        stateLock.lock()
        let completion = pendingStopCompletion
        pendingStopCompletion = nil
        stateLock.unlock()

        completion?()
    }
}

// MARK: - 帧处理

extension CameraSegmentRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if let analysis = analysisOutput, output === analysis {
            handleAnalysisFrame(sampleBuffer)
            return
        }

        guard output === videoOutput else { return }
        appendFrame(sampleBuffer)
    }

    private func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        stateLock.lock()
        var writer = currentWriter

        if writer == nil {
            // 第一帧才知道真实尺寸与像素格式 —— 所以 writer 在这里建，不在 start() 里。
            let dimensions = Self.dimensions(of: sampleBuffer)
            writer = makeWriter(sequence: segmentSequence + 1,
                                width: dimensions.width,
                                height: dimensions.height)
            currentWriter = writer
            segmentSequence += 1
        }

        // 到点就轮转。**必须在追加这一帧之前** ——
        // 新 writer 从这一帧开始写，而它天然是 I 帧。
        if let current = writer,
           CACurrentMediaTime() - current.startedAt >= segmentDuration {
            let next = makeWriter(sequence: current.sequence + 1,
                                  width: current.width,
                                  height: current.height)

            // 先切指针再收旧的：轮转期间到达的帧走新 writer，一帧不丢。
            currentWriter = next
            segmentSequence = current.sequence + 1
            writer = next

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.finish(current)
            }
        }

        let ready = writer.map { $0.writer.status == .writing && $0.input.isReadyForMoreMediaData } ?? false
        stateLock.unlock()

        guard ready, let active = writer else { return }

        // 写入会话要在这里开 —— 因为**起始时间只能是第一帧的时刻**，
        // 而那个时刻到 append 之前才知道。
        if !active.sessionStarted {
            active.writer.startSession(atSourceTime: presentationTime)
            active.sessionStarted = true
        }

        active.adaptor.append(imageBuffer, withPresentationTime: presentationTime)
    }

    private static let fallbackWidth = 1280
    private static let fallbackHeight = 720

    private static func dimensions(of sampleBuffer: CMSampleBuffer) -> (width: Int, height: Int) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return (fallbackWidth, fallbackHeight)
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        return (Int(dimensions.width), Int(dimensions.height))
    }

    /// 规格 §3.3.3：画面**连续无显著变化**即判定为静止。
    ///
    /// 相邻两帧亮度平面的平均绝对差。够用且极省电 ——
    /// 真正的静止判定不该吃掉录制的算力。
    private func handleAnalysisFrame(_ sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysisAt >= Self.analysisInterval else { return }
        lastAnalysisAt = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else { return }

        let width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)

        let sampleWidth = min(Self.analysisWidth, width)
        let sampleHeight = min(Self.analysisHeight, height)
        guard sampleWidth > 0, sampleHeight > 0 else { return }

        // **在整个画面上按网格抽样**，不是只读左上角一块。
        // 只读一角的话，动作发生在别处、那个角落恰好不动时会被误判成「静止」。
        let stepX = max(1, width / Self.analysisWidth)
        let stepY = max(1, height / Self.analysisHeight)

        var luma = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            let row = base.advanced(by: (y * stepY) * bytesPerRow)
            for x in 0..<sampleWidth {
                luma[y * sampleWidth + x] = row.load(fromByteOffset: x * stepX, as: UInt8.self)
            }
        }

        let previous = previousLuma
        previousLuma = luma

        guard let previous, previous.count == luma.count else { return }

        var total = 0
        for i in 0..<luma.count {
            total += abs(Int(luma[i]) - Int(previous[i]))
        }

        let average = Double(total) / Double(luma.count)
        let isStatic = average < Self.staticDiffThreshold

        // 只在状态**变化**时上报，别把通道刷爆。
        if lastReportedStatic != isStatic {
            lastReportedStatic = isStatic
            onEvent(.sceneSampled(isStatic: isStatic))
        }

        detectBarcodes(in: imageBuffer, now: now)
    }

    /// 用系统自带的 Vision 识码（规格 §3.2.1「摄像头识码」）。
    ///
    /// 选 Vision 而不是第三方库有两个理由：**零新依赖**，
    /// 以及**没有许可证要逐个核对**（规格 §10 要求核对第三方库的许可证）。
    ///
    /// ## ⚠️ 坐标系要翻 y
    ///
    /// Vision 的 `boundingBox` 原点在**左下**，而 Dart 侧的约定是**左上**。
    /// 不翻的话取景框判定会**上下颠倒** —— 框画在下半屏时，
    /// 会错误地接受上半屏的面单、拒绝框里的那个。
    ///
    /// ## ⚠️ 方向（真机上如果扫不到，先查这里）
    ///
    /// 这里按 `.up` 处理，依赖的是「分析那一路的 connection 已经设过方向、
    /// 送来的帧是正的」。本机没法验这一点 —— **如果真机上识不到码，
    /// 第一个要试的就是把 `orientation` 换成 `.right` 或 `.left`**。
    private func detectBarcodes(in pixelBuffer: CVPixelBuffer, now: TimeInterval) {
        guard now - lastBarcodeScanAt >= Self.barcodeScanInterval else { return }
        lastBarcodeScanAt = now

        let request = VNDetectBarcodesRequest()
        request.symbologies = Self.barcodeSymbologies

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            // 识码失败不该影响录制 —— 它只是个输入通道。
            return
        }

        guard let observations = request.results else { return }

        for observation in observations {
            guard let payload = observation.payloadStringValue, !payload.isEmpty else {
                continue
            }

            let box = observation.boundingBox
            onEvent(.barcodeDetected(
                text: payload,
                centerX: Double(box.midX),
                centerY: Double(1.0 - box.midY),
                confidence: Double(observation.confidence)))
        }
    }
}
