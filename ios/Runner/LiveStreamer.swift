import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// 实时推流那一路的编码器（规格 §3.8，需求方 2026-10-01 定的方案）。
///
/// ## 它是什么
///
/// 在**录制那台相机会话**上挂**第二路输出**，把画面编成 H.264 裸流（Annex-B），
/// 交给 Dart 那边的 "LiveServer" 出去。电脑端拉的就是这一路。
///
/// ## ⚠️ 三条隔离规则（规格 §3.8 的硬约束，缺一不可）
///
/// 1. **不许阻塞** —— 这一路的输出用 "alwaysDiscardsLateVideoFrames = true"，
///    而且 delegate 挂在一个**自己的串行队列**上。编码器吃不下时由 AVFoundation
///    自己丢帧，**绝不排队**：等一帧就是让录制那条路一起卡，
///    而录制掉帧是证据缺失，推流掉帧只是画面顿一下。
///    （也**没有**自己写「上一帧还没编完就丢」的判据：AVFoundation 那个开关
///    就是干这件事的，而自己写一个在真机上没验过的判据，
///    有可能变成「把所有帧都丢了」—— 那比不丢更难查。）
/// 2. **不许传染** —— 这一路的所有失败只走 [onFailure]（一条日志），
///    **绝不**影响 [CameraSegmentRecorder] 那边任何一次调用。
///    录制用的那个输出与编码器（"AVAssetWriter"）和这里**完全是两套**。
/// 3. **该让就让** —— 由 Dart 那边的 "LiveService.notifyRecordingPressure" 落实
///    （录制报压力 ⇒ 调 [CameraSegmentRecorder.stopLive]）。
///
/// ## ⚠️ 尺寸是**自己缩**的，没指望会话帮我们缩
///
/// "AVCaptureVideoDataOutput.videoSettings" 里塞宽高看着更省事，但那个行为
/// （要不要缩、缩到多少、与另一个全分辨率输出共存时怎么办）**本机验不了**。
/// 万一它被忽略，我们就会把一个 1080P 的流当成 480P 推出去 ——
/// 手机白热、电脑端白卡，而两边都以为自己按 480P 在跑。
/// 所以走 "VTPixelTransferSession" 显式缩到目标尺寸，结果是确定的。
///
/// ⚠️ **本机既编不了也跑不了**（Windows 上没有 Xcode / 没有真机），
/// 唯一的验证途径是 CI 的 "ios-compile-check.yml" 与真机 ".ipa"。
/// 要改就改这一条：**写完立刻手动派一次那个 workflow**（它不挂 push）。
final class LiveStreamer: NSObject {

    /// 一档推流要的东西。
    struct Step {
        /// 短边的行数（480 / 720 / 1080）。
        let lines: Int

        /// 码率（bps）。按短边给，与「多少 P」这件事直接挂钩。
        let bitRate: Int
    }

    /// 三档。⚠️ 与 Dart 的 "LiveQuality"（480/720/1080）**同一套数字** ——
    /// 电脑端那边按这个数选档，手机上认不出来就回落成格子那一档。
    static func step(forLines lines: Int) -> Step {
        switch lines {
        case 1080: return Step(lines: 1080, bitRate: 4_500_000)
        case 720: return Step(lines: 720, bitRate: 2_500_000)
        default: return Step(lines: 480, bitRate: 1_200_000)
        }
    }

    /// 挂上去时先用哪一档。
    ///
    /// ⚠️ **格子那一档（480P）**：手机一开始总是被当成格子里的一个，
    /// 直到电脑端双击进全屏才会来改（规格 §3.8）。
    static let tileLines = 480

    /// 关键帧间隔（秒）。
    ///
    /// ⚠️ 这个数直接决定「电脑端中途接入要等多久才有画面」：
    /// 裸流没有容器，客户端必须从关键帧开始才解得出来。
    /// 2 秒 = 最坏等 2 秒，代价是每 2 秒一个大帧。
    private static let keyFrameInterval: Double = 2

    /// 挂到会话上的那一路输出。
    ///
    /// ⚠️ **它在开会话时就挂上去了**（"CameraSegmentRecorder.openCamera" 的
    /// "live" 参数），而不是等用户打开开关才加 —— 往跑着的会话里加输出会让
    /// 会话重新配置，那一下断的是**正在录的证据**（规格 §3.8 第 1/2 条）。
    /// 不推的时候这个输出**没有 delegate**，帧不会送到这里来。
    let captureOutput = AVCaptureVideoDataOutput()

    /// 编好的一块（"isKey" 为真时**已经前置了 SPS/PPS**）。
    ///
    /// ⚠️ 前置参数集是**约定**（见 Dart 那边 "LiveFrame" 的说明）：
    /// 裸流没有容器，中途接入的客户端只能靠关键帧那一块里带的参数集建解码器。
    private var onFrame: ((Bool, Data) -> Void)?

    /// 出事了（编码器建不起来、编码报错）。**只用来记一条日志**。
    private var onFailure: ((String) -> Void)?

    /// 编码 + 缩放都在这个队列上。**它只跑这一路** ——
    /// 与录制那个队列分开，是「不许传染」的一半。
    private let queue = DispatchQueue(label: "vidlog.live.encode")

    private var step: Step
    private var compression: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    /// 目标尺寸（已取偶）。0 表示还没定（第一帧才知道源的比例）。
    private var width = 0
    private var height = 0

    /// 已经关掉了（关掉之后送进来的帧一律丢）。
    private var closed = false

    init(lines: Int) {
        self.step = Self.step(forLines: lines)
        super.init()

        // ⚠️ **这一行就是第 1 条隔离规则**：编码器吃不下时丢帧，不排队。
        captureOutput.alwaysDiscardsLateVideoFrames = true

        // 420v（视频范围）—— 硬件编码器最省事的那一种，不需要再转一次。
        captureOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
    }

    /// 开始往外送（用户打开了实时共享）。
    ///
    /// ⚠️ 只接上 delegate —— **不碰会话**。所以起停推流不会打断录制。
    ///
    /// ⚠️ "setSampleBufferDelegate" 在**调用方那个线程**上同步调，
    /// 状态却在 "queue" 上改：那个方法会等正在跑的回调返回，
    /// 从 delegate 队列自己调自己是最容易写出死锁的一种写法。
    /// 顺序是「先把状态挂上、再接 delegate」——接上之前来的帧会被丢掉，
    /// 而丢一帧比卡住强。
    func attach(
        lines: Int,
        onFrame: @escaping (Bool, Data) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }

            self.step = Self.step(forLines: lines)
            self.onFrame = onFrame
            self.onFailure = onFailure

            // 换档：把上一档的编码器收掉，第一帧会按新档重建。
            self.tearDown()
        }

        captureOutput.setSampleBufferDelegate(self, queue: queue)
    }

    /// 停止往外送（用户关掉了实时共享）。**输出仍挂在会话上** ——
    /// 摘掉它要重新配置会话，而那正是这两条路要分开的原因。
    func detach() {
        captureOutput.setSampleBufferDelegate(nil, queue: nil)

        queue.async { [weak self] in
            guard let self else { return }

            self.onFrame = nil
            self.onFailure = nil
            self.tearDown()
        }
    }

    /// 换档（电脑端进/出全屏时叫它）。
    ///
    /// ⚠️ **只重建这一路的编码器**；录制那边的 "AVAssetWriter" 一个字都不动。
    func setLines(_ lines: Int) {
        let wanted = Self.step(forLines: lines)

        queue.async { [weak self] in
            guard let self, !self.closed, wanted.lines != self.step.lines else { return }

            self.step = wanted
            // 尺寸在第一帧里才知道（源的比例要隔一个旋转之后才定），
            // 所以这里只把编码器收掉 —— 下一帧会按新档重建。
            self.tearDown()
        }
    }

    /// 关掉这一路。幂等。**相机拆掉时调**（那时输出会随会话一起消失）。
    func close() {
        captureOutput.setSampleBufferDelegate(nil, queue: nil)

        queue.sync {
            closed = true
            tearDown()
        }
    }

    // MARK: - 缩放 + 编码

    /// 按目标档把源尺寸算出来。
    ///
    /// ⚠️ 按**短边**算："480P" 说的是短边那 480 行。
    /// 竖着拍的时候（面单就是竖着的）长边是 854 —— 不这么算的话，
    /// 竖屏视频会按长边 480 缩，短边只剩 270，画面糊一半。
    /// 两个数都取偶：H.264 的 4:2:0 不接受奇数尺寸。
    private func targetSize(sourceWidth: Int, sourceHeight: Int) -> (Int, Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }

        let lines = Double(step.lines)
        let even: (Double) -> Int = { Int(($0 / 2).rounded()) * 2 }

        return sourceWidth >= sourceHeight
            ? (even(lines * Double(sourceWidth) / Double(sourceHeight)), Int(lines))
            : (Int(lines), even(lines * Double(sourceHeight) / Double(sourceWidth)))
    }

    private func prepare(sourceWidth: Int, sourceHeight: Int) -> Bool {
        let (wantedWidth, wantedHeight) = targetSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        guard wantedWidth > 0, wantedHeight > 0 else {
            onFailure?.("这一路量不出源画面的尺寸，推流起不来")
            return false
        }

        if compression != nil, wantedWidth == width, wantedHeight == height { return true }

        tearDown()

        width = wantedWidth
        height = wantedHeight

        // 缩放这一级。
        var transferSession: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession) == noErr,
            let transferSession
        else {
            onFailure?.("缩放器建不起来，推流起不来")
            return false
        }

        // 目标帧池：缩放要有个地方落。
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // IOSurface 这一条不是可选的：VideoToolbox 那两个会话之间传画面走的就是它。
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]

        var pixelPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &pixelPool) == noErr,
            let pixelPool
        else {
            onFailure?.("帧池建不起来，推流起不来")
            return false
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.encodeCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)

        guard status == noErr, let session else {
            onFailure?.("编码器建不起来（VideoToolbox 回了 \(status)），推流起不来")
            return false
        }

        // ── 编码器参数 ────────────────────────────────────────────
        //
        // ⚠️ 三条都是为了「实时」与「不拖累录制」：
        //   RealTime         —— 宁可掉质量也不要积压；
        //   AllowFrameReordering=false —— 不产生 B 帧，编码延迟就一帧；
        //   Baseline         —— 兼容性最好（每一格都是一个独立可解的点）。
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel)
        // ⚠️ 数字要包成 `NSNumber` 再传（与 CFNumber 是 toll-free 的）——
        // 直接写 `Int as CFNumber` 在 Swift 里过不了编译。
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: step.bitRate))
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: Self.keyFrameInterval))

        VTCompressionSessionPrepareToEncodeFrames(session)

        compression = session
        transfer = transferSession
        pool = pixelPool

        return true
    }

    /// 把一帧源画面缩到目标尺寸，然后交给编码器。
    ///
    /// 返回 false 表示这一帧没编 —— **丢掉，不重试、不等待**（第 1 条规则）。
    private func encode(_ source: CVPixelBuffer, at time: CMTime) -> Bool {
        guard let transfer, let compression, let pool else { return false }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == noErr,
            let destination
        else {
            // 池子空了（编码器还没还回来）—— 这一帧就是「吃不下」，丢掉。
            return false
        }

        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else {
            return false
        }

        let status = VTCompressionSessionEncodeFrame(
            compression,
            imageBuffer: destination,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil)

        return status == noErr
    }

    private func tearDown() {
        if let compression {
            VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compression)
        }

        compression = nil
        transfer = nil
        pool = nil
        width = 0
        height = 0
    }

    // MARK: - VideoToolbox 回调

    private static let encodeCallback: VTCompressionOutputCallback = {
        refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }

        Unmanaged<LiveStreamer>.fromOpaque(refcon).takeUnretainedValue()
            .handleEncoded(status: status, sampleBuffer: sampleBuffer)
    }

    private func handleEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        if status != noErr {
            // ⚠️ 只记一条：这一路坏了不该影响任何别的东西（第 2 条规则）。
            onFailure?.("推流编码报了错（\(status)）")
            return
        }

        guard !closed, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let (isKey, data) = Self.annexB(from: sampleBuffer), !data.isEmpty else { return }

        onFrame?(isKey, data)
    }

    // MARK: - 裸流封装（AVCC → Annex-B）

    /// 把一块编码成品转成 Annex-B，并在关键帧前**前置 SPS/PPS**。
    ///
    /// ⚠️ 为什么非要转："AVAssetWriter" 那种容器格式每一块前面是**长度前缀**，
    /// 而裸流要的是 "00 00 00 01" 起始码。不转的话电脑端那边 ffmpeg 收进去
    /// 是一堆解不开的字节 —— 表现是「连上了、一直在收、一个画面都没有」。
    static func annexB(from sampleBuffer: CMSampleBuffer) -> (Bool, Data)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }

        let isKey = !Self.isNotSync(sampleBuffer)
        var out = Data()

        if isKey, let sets = Self.parameterSets(from: format) {
            out.append(sets)
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)

        guard status == kCMBlockBufferNoErr, let pointer, length >= 4 else { return nil }

        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0

        while offset + 4 <= length {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, bytes + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)

            offset += 4
            let size = Int(nalLength)

            guard size > 0, offset + size <= length else { break }

            // 起始码 + 这一段 NALU。
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(UnsafeBufferPointer(start: bytes + offset, count: size))
            offset += size
        }

        return (isKey, out)
    }

    /// SPS / PPS。
    private static func parameterSets(from format: CMFormatDescription) -> Data? {
        var count = 0
        var headerLength: Int32 = 0

        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr,
            count > 0
        else {
            return nil
        }

        var out = Data()

        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0

            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr,
                let pointer
            else {
                continue
            }

            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(pointer, count: size)
        }

        return out
    }

    /// 这一块是不是「不是同步点」（= 不是关键帧）。
    private static func isNotSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
            let first = attachments.first
        else {
            // 没有附件数组 ⇒ 没有被标成「非同步点」⇒ 它是关键帧。
            return false
        }

        return first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }
}

// MARK: - 相机帧

extension LiveStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !closed else { return }

        // ⚠️ 这个回调在**主线程之外的专属队列**上，而它从头到尾不碰录制那边
        // 任何状态 —— 第 2 条规则靠的就是这一点。
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let ready = CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
        defer { if ready { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) } }

        guard ready else { return }

        guard prepare(
            sourceWidth: CVPixelBufferGetWidth(pixels),
            sourceHeight: CVPixelBufferGetHeight(pixels))
        else {
            return
        }

        // 编不进去就是这一帧不要了（第 1 条规则）。
        _ = encode(pixels, at: time)
    }
}
