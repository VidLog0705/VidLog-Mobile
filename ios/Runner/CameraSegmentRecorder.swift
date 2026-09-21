import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
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

    /// 设置缩放倍率。规格 §3.1.2：倍率不得超过设备能力上限。
    func setZoom(_ ratio: CGFloat) {
        guard let device = captureDevice else { return }

        do {
            try device.lockForConfiguration()
            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(ratio, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            // 变焦失败不该中断录制。
            NSLog("VidLog: 设置变焦失败 %@", error.localizedDescription)
        }
    }

    // MARK: - 相机配置

    private static func pickBackCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera],
            mediaType: .video,
            position: .back)

        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
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
