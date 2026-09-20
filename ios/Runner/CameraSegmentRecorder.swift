import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

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

    // MARK: - 状态

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "vidlog.camera.session")
    private let videoQueue = DispatchQueue(label: "vidlog.camera.video")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var analysisOutput: AVCaptureVideoDataOutput?
    private var captureDevice: AVCaptureDevice?

    private let outputDirectory: URL
    private let segmentDuration: TimeInterval
    private let onEvent: (RecorderEvent) -> Void

    private var currentWriter: SegmentWriter?
    private var segmentSequence = -1
    private var sessionStartedAt: TimeInterval = 0
    private var sessionStartedWallClock = Date()

    private var lastAnalysisAt: TimeInterval = 0
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

    init(outputDirectory: URL,
         segmentDuration: TimeInterval,
         onEvent: @escaping (RecorderEvent) -> Void) {
        self.outputDirectory = outputDirectory
        self.segmentDuration = segmentDuration
        self.onEvent = onEvent
        super.init()
    }

    // MARK: - 权限

    static var hasCameraPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestCameraPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    // MARK: - 生命周期

    /// 开始录制。返回 false 表示相机打不开。
    func start() -> Bool {
        guard !isRecording else { return false }

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

        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        sessionStartedAt = CACurrentMediaTime()
        sessionStartedWallClock = Date()
        segmentSequence = -1
        currentWriter = nil

        stateLock.lock()
        running = true
        stateLock.unlock()

        sessionQueue.async { [weak self] in
            self?.session.startRunning()
        }

        // writer 不在这里建 —— 尺寸与像素格式要等第一帧才知道（见 appendFrame）。
        return true
    }

    /// 停止录制。
    ///
    /// **回调在最后一段封闭之后才会触发。** 这是刻意的：
    /// `finishWriting` 是异步的，如果立刻返回，调用方会以为录完了，
    /// 而最后一段还在写 —— 那段录像就被漏掉了。
    func stop(_ completion: @escaping () -> Void) {
        stateLock.lock()
        let wasRunning = running
        running = false
        let writer = currentWriter
        currentWriter = nil
        pendingStopCompletion = completion
        stateLock.unlock()

        guard wasRunning else {
            completion()
            return
        }

        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }

        if let writer {
            finish(writer)
        } else {
            // 一段都没录到（比如刚开就停）。
            self.completeStopIfNeeded()
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

        if let connection = output.connection(with: .video) {
            applyOrientation(to: connection)
        }

        return true
    }

    /// 静止检测用一路低分辨率输出，不影响录制。
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

        var luma = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<sampleWidth {
                luma[y * sampleWidth + x] = row.load(fromByteOffset: x, as: UInt8.self)
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
    }
}
