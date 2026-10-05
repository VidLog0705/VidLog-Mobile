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
/// 录制规格（规格 §3.1.7）—— 与 Dart 的 `RecordingSpec` **逐字对应**。
///
/// 名字用的是 Dart 那边的枚举名（`h264` / `uhd4K` / `landscapeLeft`），
/// 而 `fromConfig` 那种宽容解析在这里**刻意不做**：Dart 已经归一过了，
/// 原生再猜一遍只是给同一件事留两个说法。认不出来一律回默认档 ——
/// 与设置层「越界回落默认值」同一条规矩（I4）。
///
/// ⚠️ **放在这个文件里，没有单独开一个 Swift 文件**：本工程的
/// `project.pbxproj` 还是老式的文件引用（不是 Xcode 16 的目录同步），
/// 新加一个文件要手改 pbxproj —— 而那份工程文件是本项目里**最容易改坏**
/// 的东西（改坏了 CI 才看得见）。一个小结构体不值得冒这个险。
struct RecorderSpec {
    enum Codec: String {
        case h264
        case h265
    }

    enum Resolution: String {
        case uhd4K
        case p1080
        case p720
    }

    enum Orientation: String {
        case landscapeLeft
        case portrait
        case landscapeRight
    }

    var codec: Codec = .h264
    var resolution: Resolution = .p1080
    var orientation: Orientation = .portrait

    /// 默认档：H.264 + 1080P + 竖屏（与 Dart 的 `RecordingSpec.standard` 同一档）。
    static let standard = RecorderSpec()

    static func parse(_ raw: Any?) -> RecorderSpec {
        guard let map = raw as? [String: Any] else { return .standard }

        var spec = RecorderSpec.standard
        if let name = map["codec"] as? String, let value = Codec(rawValue: name) {
            spec.codec = value
        }
        if let name = map["resolution"] as? String, let value = Resolution(rawValue: name) {
            spec.resolution = value
        }
        if let name = map["orientation"] as? String, let value = Orientation(rawValue: name) {
            spec.orientation = value
        }
        return spec
    }

    static func parseList(_ raw: Any?) -> [RecorderSpec] {
        guard let list = raw as? [Any] else { return [] }
        return list.map { parse($0) }
    }

    /// **编码尺寸**（恒为横向的那一组）：会话 preset 与 writer 都用它。
    ///
    /// ⚠️ 竖屏时成片是它的宽高对调 —— 那件事**不在这里做**：
    /// 它由 connection 的旋转完成，收到的帧本身就是转好的
    /// （所以 `dimensions(of:)` 读出来的已经是竖的，writer 跟着走）。
    var landscapeSize: (width: Int, height: Int) {
        switch resolution {
        case .uhd4K: return (3840, 2160)
        case .p1080: return (1920, 1080)
        case .p720: return (1280, 720)
        }
    }

    var preset: AVCaptureSession.Preset {
        switch resolution {
        case .uhd4K: return .hd4K3840x2160
        case .p1080: return .hd1920x1080
        case .p720: return .hd1280x720
        }
    }

    /// 编码器。**界面上写「H.265」，代码里可以写 `.hevc`** ——
    /// 那是 Apple 的 API 名字，用户看不到（规格禁的是**界面文案**里混用两个名字）。
    var codecType: AVVideoCodecType {
        codec == .h265 ? .hevc : .h264
    }

    /// 录制码率。以原来那个写死的 8 Mbps 为 720P 的基准按像素数放大，
    /// H.265 再打六折（同画质下它本来就省）。
    ///
    /// ⚠️ 不按像素等比的话，**4K 会按 720P 的码率编** ——
    /// 选项做得出来、画面却糊得没法当证据。
    var bitRate: Int {
        let (width, height) = landscapeSize
        let baselinePixels = 1280 * 720
        let scaled = 8_000_000.0 * Double(width * height) / Double(baselinePixels)
        return Int(codec == .h265 ? scaled * 0.6 : scaled)
    }

    /// 旋转角（iOS 17 起 `videoOrientation` 废弃，改用这个）。
    ///
    /// ⚠️ **0 对应 Apple 所谓的 `.landscapeRight`**（Apple 的定义是
    /// 「Home 键在右手侧」）—— 那个握姿的**听筒朝左**，正是我们的「横左」。
    /// 两边名字是反的，这里按**角度**写，别照着名字改。
    ///
    /// ⚠️ 三个数**都没在真机上验过**（开发机是 Windows、没有 iPhone）。
    /// 真机上若发现两个横屏方向反了，对调的就是这里的 0 与 180。
    var rotationAngle: CGFloat {
        switch orientation {
        case .portrait: return 90
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        }
    }

    /// 老系统那条路（iOS 17 之前）。
    ///
    /// ⚠️ **这里是对调着写的，不是笔误** —— Apple 的 `.landscapeRight`
    /// 指「Home 键在右手侧」（= 我们的横左），见 [rotationAngle]。
    var videoOrientation: AVCaptureVideoOrientation {
        switch orientation {
        case .portrait: return .portrait
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        }
    }

    /// 这台设备真的跑得通这一档吗（规格 §3.1.7 的可用性检查）。
    ///
    /// 两件事都要成立：
    /// 1. 编码器有（`availableVideoCodecTypes` 里有没有 HEVC）
    /// 2. 有一个**正好这个尺寸**的设备格式（不是「能缩放到」——
    ///    会话 preset 走的是「按这个模式打开设备」，列不出来就是打开不了）
    ///
    /// ⚠️ `availableVideoCodecTypes` 是**实例属性**，不是类型属性 ——
    /// CI 的 macOS 编译抓到的（写成 `AVCaptureVideoDataOutput.…` 报
    /// 「Instance member cannot be used on type」）。所以现造一个空输出对象只为读它：
    /// 那个列表只跟机型与 iOS 版本有关，与这个对象的状态无关。
    func isUsable(on device: AVCaptureDevice) -> Bool {
        guard AVCaptureVideoDataOutput().availableVideoCodecTypes.contains(codecType) else {
            return false
        }

        let (width, height) = landscapeSize

        return device.formats.contains { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dimensions.width)
            let h = Int(dimensions.height)

            // 有些设备把格式按传感器方向登记（宽高对调），两边都认。
            return (w == width && h == height) || (w == height && h == width)
        }
    }
}

/// 把水印画进相机的帧里（规格 §3.6.2）。
///
/// ## 为什么在**采集这一层**画
///
/// 录下来的就是最终成品（原生直接写 MP4，没有 remux 那一步），
/// 所以「烧进视频」只能发生在帧进编码器之前 —— 导出时再叠是做不到的
/// （手机上没有 ffmpeg）。
///
/// ## 怎么画的
///
/// 相机的帧是 **NV12 双平面**（`420YpCbCr8BiPlanarFullRange`）：Y 平面是亮度、
/// CbCr 平面是色度（每 2×2 像素共用一个）。
///
/// 1. 用 `UIGraphicsImageRenderer` 把两行字画进一张 **RGBA** 小图（只画一次/秒）；
/// 2. 把那张小图转成 NV12，缓存在内存里；
/// 3. 每帧按矩形往 Y 平面与 CbCr 平面各拷一段。
///
/// ⚠️ **红字要求动色度平面**：只改 Y 平面的话所有字都是灰的
/// （规格明写第二行是**红色**，而且屏幕上的那一行也是红的 —— 所见即所得）。
///
/// ⚠️ **一次算、一秒钟重画一次**：字每秒才变一次，而帧是每秒 30 张。
/// 每帧重画一次文字会把录制的算力吃掉一大块（性能是规格 §3.1 的硬要求）。
///
/// ⚠️ **这份代码没有在真机上跑过**（开发机是 Windows、没有 Xcode 也没有 iPhone）。
/// 真机验收见 `docs/真机验收清单.md` §1.26。
///
/// ⚠️ 而且它**第一次过编译是 2026-09-27**（`ios-compile-check.yml` run `36296934767`），
/// 比它写下来晚了整整一天 —— 期间这里写着「只过了 CI 的 macOS 编译」，
/// **那句话是假的**（`ios-compile-check.yml` 是手动 dispatch 的，没人 dispatch 就没跑过）。
/// 修掉的三处见 `git log -- ios/Runner/CameraSegmentRecorder.swift`。
/// **写完 iOS 代码要手动 dispatch 那一次** —— 这是本条最该记住的事。
final class WatermarkOverlay {

    /// 第一行：走时（北京时间）。
    private(set) var startDate = Date()

    /// 第二行：完整单号。空串 = 不画那一行（没在录时不出现）。
    private(set) var renderWaybill = ""

    /// 第一帧的时间戳 —— 会话时间的原点。到第一帧才知道，所以是可选的。
    var firstPresentationTime: CMTime?

    /// 已经渲染好的那一秒（缓存键）。
    var cachedSecond: Int?

    /// 缓存：Y 与 CbCr 的字节，以及它该贴在哪儿。
    private var cachedY: [UInt8] = []
    private var cachedCbCr: [UInt8] = []
    private var cachedRect = CGRect.zero
    private var cachedBufferWidth = 0

    /// 北京时间（UTC+8）。规格：「与设备本地时区无关，用户改时区不影响水印」。
    private static let beijing = TimeZone(secondsFromGMT: 8 * 3600)!

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = WatermarkOverlay.beijing
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    /// 与 Dart 侧 `watermarkClockLine` **逐字相同**的格式。
    static func ClockLine(_ moment: Date) -> String {
        clockFormatter.string(from: moment)
    }

    /// 与 Dart 侧 `watermarkWaybillLine` **逐字相同**：只 trim，不截断。
    static func WaybillLine(_ waybill: String) -> String {
        waybill.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 开一段之前把两行字设好。
    ///
    /// ⚠️ **两个字段只能一起设**（所以没有各自的 setter）：时间原点与单号
    /// 是同一次开录的两个事实，分开设的话「换了单号但时间原点还是上一段的」
    /// 会录出一段水印时间对不上的视频 —— 而画面上看不出来那是错的。
    ///
    /// ⚠️ 起算点是 **`trustedStartMs`（可信时钟给的毫秒）**，不是 `Date()`：
    /// 用户改系统时间不得改变视频里的时间（规格 §3.6.3）。
    /// 取不到时**回落到 `Date()`** —— 那一段的时间就不可信了，但**录不出来是事故**
    /// （与「写水印失败不让采集失败」同一条精神）。
    func configure(waybill: String, trustedStartMs: Double?) {
        renderWaybill = WatermarkOverlay.WaybillLine(waybill)
        startDate = trustedStartMs
            .map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

        // 新的一段 = 新的原点：缓存与第一帧时间戳都必须清掉，
        // 否则第二段会接着上一段的那一秒往下画。
        firstPresentationTime = nil
        cachedSecond = nil
    }

    /// 把水印画进这一帧。**失败就什么都不做** —— 采集绝不能因为水印出错（I4 的精神）。
    func draw(into pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) {
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
        }
        guard let origin = firstPresentationTime else { return }

        let seconds = CMTimeGetSeconds(presentationTime - origin)
        guard seconds.isFinite, seconds >= 0 else { return }

        let moment = startDate.addingTimeInterval(seconds)
        let second = Int(seconds)

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if cachedSecond != second || cachedBufferWidth != width {
            render(moment: moment, width: width, height: height)
        }

        guard !cachedY.isEmpty, cachedRect.width > 0 else { return }

        blit(into: pixelBuffer, width: width, height: height)
    }

    /// 把两行字画成 RGBA，再转成 NV12 缓存起来。
    private func render(moment: Date, width: Int, height: Int) {
        // 字号按画面高度取比例 —— 与电脑端同一个口径（换分辨率不用另配一套）。
        let clockSize = max(10, (Double(height) * 0.040).rounded())
        let waybillSize = max(10, (Double(height) * 0.050).rounded())
        let margin = max(6, (Double(height) * 0.02).rounded())

        let clockText = WatermarkOverlay.ClockLine(moment)
        let waybillText = renderWaybill

        let attributesClock: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: clockSize),
            .foregroundColor: UIColor.white,
            // 黑描边：白字压在**白面单**上时没有它就完全看不见
            // （与界面上那四角括号同一个理由）。
            .strokeColor: UIColor.black,
            .strokeWidth: -3.0,
        ]

        let attributesWaybill: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: waybillSize),
            .foregroundColor: UIColor.red,
            .strokeColor: UIColor.black,
            .strokeWidth: -3.0,
        ]

        let clockString = NSAttributedString(string: clockText, attributes: attributesClock)
        let waybillString = NSAttributedString(
            string: waybillText, attributes: attributesWaybill)

        let clockSizePx = clockString.size()
        let waybillSizePx = waybillText.isEmpty ? .zero : waybillString.size()

        let stripWidth = Int(max(clockSizePx.width, waybillSizePx.width).rounded(.up)) + 8
        let stripHeight = Int(clockSizePx.height.rounded(.up))
            + (waybillText.isEmpty ? 0 : Int(waybillSizePx.height.rounded(.up)))
            + 8

        // 顶部居中：**不得遮挡取景框**（规格 §3.6.2）—— 取景框在画面中间，
        // 水印在最上方那一条里。
        //
        // ## ⚠️ 这里**不需要**按方向做坐标变换 —— 与安卓那边**不一样**，别照抄
        //
        // 规格 §3.1.7 ② 要求「水印的绘制坐标要按方向做一次变换」。安卓那边**必须**
        // 做（`WatermarkGlRenderer.rotatedAboutCenter`）：它的成片像素永远是**传感器
        // 方向**的，竖屏只是 `MediaMuxer.setOrientationHint` 写了一个标记，播放器
        // 转整帧时会把烧进去的字一起转 —— 不抵消就会出现「水印跑到侧边、字躺倒 90°」。
        //
        // **iOS 不是那个形状**：旋转加在 `AVCaptureConnection` 上
        //（`applyOrientation`：`videoRotationAngle` / `videoOrientation`），
        // 也就是**交付出来的像素本身就是正的了**；而且全文没有 `AVAssetWriterInput
        // .transform` 那一层元数据旋转。所以这个 buffer 的「上」就是成片的「上」，
        // 画在顶部居中即正确。
        //
        // ⚠️ 谁要是照安卓的样子在这里也加一次反向旋转，**竖屏时水印会歪**。
        // 两边形状不同，是因为两个平台交付像素的方式不同，不是因为谁漏了一段。
        //
        // ⚠️ **横坐标要取偶**（`/ 2 * 2`）：色度平面是 2×2 下采样的，贴的时候
        // 按 `(originX / 2) * 2` 算偏移 —— 奇数原点会被它舍掉一个像素，
        // 于是**色度整体错开一列**（画面看着像在字边上蒙了一层彩边）。
        // 尺寸那边的对齐见 `toNV12`；位置这边同样要对齐，只是不那么显眼。
        let originX = max(0, (width - stripWidth) / 2) / 2 * 2
        let originY = Int(margin)

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: stripWidth, height: stripHeight))

        let image = renderer.image { _ in
            clockString.draw(at: CGPoint(x: 4, y: 4))

            if !waybillText.isEmpty {
                waybillString.draw(
                    at: CGPoint(x: 4, y: 4 + clockSizePx.height))
            }
        }

        guard let cgImage = image.cgImage else { return }

        let (yBytes, cbcrBytes, rect) = WatermarkOverlay.toNV12(
            cgImage, at: CGPoint(x: originX, y: originY), canvasWidth: width)

        cachedY = yBytes
        cachedCbCr = cbcrBytes
        cachedRect = rect
        cachedBufferWidth = width
        cachedSecond = Int(moment.timeIntervalSince1970)
    }

    /// RGBA → NV12 的字节（Y 每像素一个，CbCr 每 2×2 一个）。
    ///
    /// ⚠️ 小图按 **16 的倍数**对齐：NV12 的色度平面是 2×2 下采样的，
    /// 宽高不是偶数的话，贴上去会**整体错位一列/一行**（画面看起来像花屏）。
    private static func toNV12(
        _ image: CGImage, at origin: CGPoint, canvasWidth: Int
    ) -> ([UInt8], [UInt8], CGRect) {
        let rawWidth = image.width
        let rawHeight = image.height

        // 宽高各补到偶数。
        let width = rawWidth + (rawWidth % 2)
        let height = rawHeight + (rawHeight % 2)

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }

            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: rawWidth, height: rawHeight))
        }

        var y = [UInt8](repeating: 0, count: width * height)
        var cbcr = [UInt8](repeating: 128, count: width * height / 2)

        // BT.601 全范围（与 `420YpCbCr8BiPlanarFullRange` 对应）。
        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                let r = Double(rgba[index])
                let g = Double(rgba[index + 1])
                let b = Double(rgba[index + 2])
                let a = Double(rgba[index + 3]) / 255.0

                // ⚠️ 半透明像素要**与底下的画面混合**吗？——不，这里画的是
                // 「盖上去」的那一层；描边本身不透明，而字与描边已经把这一条
                // 铺满了。所以直接按不透明度加权到「黑底」上。
                let luma = (0.299 * r + 0.587 * g + 0.114 * b) * a
                y[row * width + column] = UInt8(max(0, min(255, luma)).rounded())

                // 色度只在偶数行列上采一次（每 2×2 共用）。
                if row % 2 == 0 && column % 2 == 0 {
                    let cb = (-0.169 * r - 0.331 * g + 0.5 * b) * a + 128
                    let cr = (0.5 * r - 0.419 * g - 0.081 * b) * a + 128
                    let chroma = ((row / 2) * width + (column / 2) * 2)

                    cbcr[chroma] = UInt8(max(0, min(255, cb)).rounded())
                    cbcr[chroma + 1] = UInt8(max(0, min(255, cr)).rounded())
                }
            }
        }

        return (y, cbcr, CGRect(x: origin.x, y: origin.y, width: CGFloat(width), height: CGFloat(height)))
    }

    /// 把缓存的 NV12 字节贴到这一帧上。
    private func blit(into pixelBuffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])

        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let patchWidth = Int(cachedRect.width)
        let patchHeight = Int(cachedRect.height)
        let originX = Int(cachedRect.minX)
        let originY = Int(cachedRect.minY)

        guard originX + patchWidth <= width, originY + patchHeight <= height else { return }

        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let planeStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let destination = base.assumingMemoryBound(to: UInt8.self)

            for row in 0..<patchHeight {
                let from = row * patchWidth
                let to = (originY + row) * planeStride + originX

                cachedY.withUnsafeBufferPointer { source in
                    memcpy(destination + to, source.baseAddress! + from, patchWidth)
                }
            }
        }

        if CVPixelBufferGetPlaneCount(pixelBuffer) > 1,
           let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            // ⚠️ **别把这个局部变量叫 `stride`** —— 那会遮蔽同名的全局函数
            // `stride(from:to:by:)`，于是下面那个循环报一句
            // 「Cannot call value of non-function type 'Int'」，
            // 而错的地方看起来完全不像这里（2026-09-27 CI 上就是这么红的）。
            let planeStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let destination = base.assumingMemoryBound(to: UInt8.self)

            // 色度是 2×2 下采样：行列都减半。
            for row in 0..<(patchHeight / 2) {
                let from = row * patchWidth
                let to = ((originY / 2) + row) * planeStride + (originX / 2) * 2

                cachedCbCr.withUnsafeBufferPointer { source in
                    memcpy(destination + to, source.baseAddress! + from, patchWidth)
                }
            }
        }
    }
}

final class CameraSegmentRecorder: NSObject {

    // MARK: - 配置

    /// 单段时长。掉电最多丢这么多。
    static let defaultSegmentDuration: TimeInterval = 5 * 60

    private static let analysisWidth = 160
    private static let analysisHeight = 120
    private static let analysisInterval: TimeInterval = 0.5

    /// 相邻两次采样之间，亮度平均绝对差低于这个值就算「没动」。
    private static let staticDiffThreshold = 3.0

    private static let frameRate: Int32 = 30

    /// 关键帧间隔（秒）。它决定「单独播放某一段时，开头要等多久才出画面」。
    private static let keyFrameIntervalSeconds = 1

    // ── 音轨的参数（录制声音，需求方 2026-09-28）──────────────────
    //
    // 取证声音要的是「听得出人说了什么、有没有异响」，**不是音乐**。
    // 所以是单声道 44.1kHz / 64kbps：一瓶 5 分钟的水大约 2.4 MB，
    // 相对同一段的视频（几十上百 MB）可以忽略。
    //
    // ⚠️ **必须与安卓那边是同一套数**（`CameraSegmentRecorder.kt` 里那三个
    // 常量）—— 两端录出来的文件属性不一致的话，电脑端的回放与转码
    // 会按其中一边的假设来，另一边出问题。

    /// 单声道。
    private static let audioChannels = 1

    /// 44.1kHz —— 语音的常见采样率，两端都支持。
    private static let audioSampleRate = 44100

    /// 64kbps。
    private static let audioBitRate = 64000

    /// 识码的采样间隔。**不跑满帧** —— 识码比静止检测贵得多，
    /// 而包裹摆在那儿几秒内扫到就够了。
    private static let barcodeScanInterval: TimeInterval = 0.3

    /// 识码范围（录制页 / 取景框那一半）：**只有一维码**，这类条码里装的就是单号本身。
    ///
    /// **刻意没开二维码（QR / DataMatrix / PDF417）**：电子面单上的二维码里
    /// 装的往往是 URL 或一段结构化文本，直接当单号用会往单号字段里灌进
    /// 一整条 URL。要用得先知道各家承运商的载荷格式、从里面抽出单号 ——
    /// 那是另一件事，别在这里猜。
    private static let waybillSymbologies: [VNBarcodeSymbology] = [
        .code128,  // 快递面单上最常见
        .code39,
        .code93,
        .itf14,
        .ean13,
        .ean8,
        .upce,
    ]

    /// 识码范围（**扫码连接**那一半）：只有二维码。
    ///
    /// 规格 §3.4.5 ④：二维码**只在那个专用界面里**开，录制页仍然只认一维码 ——
    /// 反过来也一样：在扫码连接界面里认出一维码没有任何用处（那张码里
    /// 装的是 `vidlog://…`，一维码装不下），放进来只会多一次没用的判定。
    private static let qrSymbologies: [VNBarcodeSymbology] = [.qr]

    // MARK: - 状态

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "vidlog.camera.session")
    private let videoQueue = DispatchQueue(label: "vidlog.camera.video")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var analysisOutput: AVCaptureVideoDataOutput?
    private var captureDevice: AVCaptureDevice?

    /// 麦克风那一路（录制声音，需求方 2026-09-28）。
    ///
    /// ⚠️ **只有 `recordAudio` 为真时才会建** —— 录音关掉的时候，
    /// 这一路输出和那个麦克风输入都不进会话，手机顶上的录音指示也不会亮。
    /// 见 [openCamera]。
    private var audioOutput: AVCaptureAudioDataOutput?

    /// 录不录音。**由 [openCamera] 定一次**（会话配置时就要知道，
    /// 因为麦克风输入是开会话时加进去的）—— 与 [spec] 同一个待遇。
    ///
    /// ⚠️ 与「工作模式 / 兜底档位 / 录制规格」同一组：**改了要等下次
    /// 「开始工作」**（设置页「什么时候生效」那张卡上写着这一条）。
    /// Dart 那边同一个设置项也随 `startRecording` 再传一次（[startRecording]），
    /// 两次的值来自同一个 `_recordAudio` —— 它们必须一致。
    private var recordAudio = false

    /// 只认二维码。由「扫码连接」那个界面打开，**录制页永远不打开**
    /// （规格 §3.4.5 ④）。
    ///
    /// 读写都走 `sessionQueue`：识码在 `videoQueue` 上跑，而这个开关从
    /// **主线程**（方法通道）改 —— 不加锁就是一个 Bool 的数据竞争。
    /// 每 0.3 秒 sync 一次的开销可以忽略。
    private var qrOnlyStorage = false

    var qrOnly: Bool {
        get { sessionQueue.sync { qrOnlyStorage } }
        set { sessionQueue.sync { qrOnlyStorage = newValue } }
    }

    /// 当前录制段的落盘位置。**只在录制期间有效** —— 相机可以开着而不录。
    private var outputDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private var segmentDuration: TimeInterval = CameraSegmentRecorder.defaultSegmentDuration
    private let onEvent: (RecorderEvent) -> Void

    /// 本次会话用的录制规格。**只在 [openCamera] 里定一次** ——
    /// 改了它要重开会话（Dart 那边就是这么做的：规格变了先关相机再开）。
    private var spec: RecorderSpec = .standard

    /// 水印（规格 §3.6.2）。
    private let watermark = WatermarkOverlay()

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

    /// 实时推流那一路（规格 §3.8）。
    ///
    /// ⚠️ **它与录制那一路是完全独立的两套编码**：这里换档、坏掉、被停掉，
    /// 都不碰 [currentWriter] / [videoOutput] 那边的任何东西。
    /// 挂进来的只有相机帧（第二路输出），编码器是它自己的。
    private var liveStreamer: LiveStreamer?

    /// 状态锁保护 [running] 与 [currentWriter]（相机线程与调用方线程都会碰）。
    private let stateLock = NSLock()
    private var running = false

    /// 写样本失败**累计**了几次（本会话内）。节流用，见 [reportWriteFailure]。
    ///
    /// ⚠️ 与 [lastWriteFailureAt] 一样由 [stateLock] 保护：
    /// [appendFrame] 在采集队列上、[finish] 在后台队列上，两条都会报。
    private var writeFailureCount = 0

    /// 上一次因写失败上报的时刻（`CACurrentMediaTime()`）。
    ///
    /// **0 = 本会话还没报过** —— 头一次失败要立刻报出去，不能等节流窗口。
    private var lastWriteFailureAt: TimeInterval = 0

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

    // MARK: - 可用性检查

    /// 录制前那次**真实的可用性检查**（规格 §3.1.7）。
    ///
    /// 返回候选表里**第一个真能跑**的下标；一个都跑不通返回 nil。
    ///
    /// ⚠️ **候选表的顺序不是这里决定的** —— Dart 那边排好了送进来
    /// （`RecordingSpec.fallbacksFrom`，有测试）。这里只回答设备能力，
    /// 因为「先保编码还是先保分辨率」是产品决定，不是设备事实。
    ///
    /// 相机没开时也能调：它只是读设备格式，不动会话。
    static func firstUsableIndex(_ candidates: [RecorderSpec]) -> Int? {
        guard let device = pickBackCamera() else { return nil }

        for (index, candidate) in candidates.enumerated() {
            if candidate.isUsable(on: device) {
                return index
            }
        }

        return nil
    }

    // MARK: - 权限

    static var hasCameraPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestCameraPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    /// 麦克风权限（录制声音，需求方 2026-09-28）。
    ///
    /// ⚠️ 权限被拒**不影响录像**（不变量 I4）：那一段照常录，只是没有音轨。
    /// `AVCaptureDeviceInput(device: .default(for: .audio))` 在没授权时会抛，
    /// 而那个 catch 就是这条降级路径（见 [openCamera]）。
    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    // MARK: - 生命周期

    /// 打开相机并开始送预览。
    ///
    /// **不开始录制。** 规格 §3.2.2：用户点「开始工作」→ 画面出现**可见的取景框**；
    /// 那时还没扫码，不该录。所以相机开着送预览、等扫到面单才开始录。
    ///
    /// 返回 false 表示相机打不开。
    ///
    /// <param name="audio">
    /// 录不录音（需求方 2026-09-28）。**只能在开会话这一趟给**：麦克风输入
    /// 是 `beginConfiguration` 里加进会话的，会话建好之后补不进来。
    /// 缺参数按 **false** 走 —— 老版本 Dart 不带它 = 老行为 = 不录音。
    /// </param>
    func openCamera(spec: RecorderSpec = .standard, audio: Bool = false, live: Bool = false) -> Bool {
        guard !cameraOpen else { return true }

        guard let device = Self.pickBackCamera() else {
            onEvent(.failed("找不到可用的后置摄像头"))
            return false
        }
        captureDevice = device
        self.spec = spec
        self.recordAudio = audio

        session.beginConfiguration()

        // 分辨率走会话 preset。设不上时**不静默降级**：把设备实际给的档说出来 ——
        // 规格 §3.1.7「不得静默回落」，而 Dart 那边已经做过一次可用性检查，
        // 走到这里还设不上说明设备在探测之后变了（切换镜头、被别的 App 占了）。
        if session.canSetSessionPreset(spec.preset) {
            session.sessionPreset = spec.preset
        } else {
            onEvent(.failed("这台设备设不上 \(spec.preset.rawValue)，仍按默认档录制"))
        }

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

        // ── 实时推流（规格 §3.8）──────────────────────────────────
        //
        // ⚠️ **在这里挂，不在用户打开开关时挂**：往一个跑着的会话里加输出
        // 会让它重新配置，那一下断的是**正在录的证据**。规格写死了
        // 「录制是证据，推流是便利，两者冲突时无条件舍推流」。
        // 所以开关是「改了等下次开始工作」那一组里的（与录音同一条）。
        //
        // ⚠️ 挂上 ≠ 在推：不推的时候这个输出没有 delegate，帧不会送到它那里。
        if live {
            addLiveOutput()
        }

        // ── 麦克风（录制声音，需求方 2026-09-28）──────────────────────
        //
        // ⚠️ **整段都在 I4 的保护之下**：音频这一路出任何问题都只是
        // 「这一段没有声音」，绝不 return false。少一条音轨是遗憾，
        // 录不出来是事故。
        if recordAudio {
            configureAudioSession()
            addAudioInput()
            addAudioOutput()
        }

        session.commitConfiguration()

        // 方向必须在 commit 之后设 —— 输出刚 add 进去时它的 connection
        // 还不一定存在，那时设等于白设，画面会拍成横的。
        //
        // **分析那一路也要设同样的方向**：识码是在那一路的帧上跑的，
        // 两边方向不一致的话，录出来的画面和识码看到的画面会差 90°。
        // ⚠️ 推流那一路（有的话）也要算进来：方向不一致的话，
        // 录出来的画面是正的、电脑端看到的是躺着的。
        for output in [videoOutput, analysisOutput, liveStreamer?.captureOutput].compactMap({ $0 }) {
            if let connection = output.connection(with: .video) {
                applyOrientation(to: connection, spec: spec)
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
    /// <param name="trustedStartMs">
    /// **可信时钟**给的开录时刻（epoch 毫秒，规格 §3.6.4）。
    /// 水印上那行时间就从它推 —— 规格 §3.6.3：「水印与时长都不得取自墙钟」。
    /// 传 nil 时退回墙钟（老调用方 / 测试路径）。
    /// </param>
    /// <param name="audio">
    /// 这一段录不录音（需求方 2026-09-28）。
    /// ⚠️ 缺参数按 **false** 走（老版本 Dart 不带这个参数 = 老行为 = 不录音），
    /// 但 Dart 那边**每次都显式传**（有测试钉着）——「缺参数 = 不录音」
    /// 这个默认值只是给老调用方兜底，不是一条可以依赖的路径。
    /// </param>
    func startRecording(
        directory: URL, segmentDuration: TimeInterval, waybill: String = "",
        trustedStartMs: Double? = nil, audio: Bool = false
    ) -> Bool {
        guard cameraOpen, !isRecording else { return false }

        outputDirectory = directory
        self.segmentDuration = segmentDuration

        // 与会话里那个值来自 Dart 的同一个设置项，正常情况下一模一样
        // （见 `recordAudio` 的注释）。这里覆盖一次是为了让「这一段录不录」
        // 由这一次调用说了算 —— 而 [makeWriter] 还额外要求 `audioOutput`
        // 真的建起来了，两者不一致时降级成「没有音轨」而不是「一条空音轨」。
        recordAudio = audio

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        sessionStartedAt = CACurrentMediaTime()
        sessionStartedWallClock = Date()
        segmentSequence = -1
        currentWriter = nil
        previousLuma = nil
        lastReportedStatic = nil

        // ── 水印（规格 §3.6.2）────────────────────────────────────────
        //
        // ⚠️ 起算点是**可信时钟**给的那个时刻（`trustedStartMs`），不是 Date()：
        // 用户改系统时间不得改变视频里的时间。
        watermark.configure(waybill: waybill, trustedStartMs: trustedStartMs)

        stateLock.lock()
        running = true
        writeFailureCount = 0
        lastWriteFailureAt = 0
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
    // MARK: - 实时推流（规格 §3.8）

    /// 把推流那一路的输出挂进会话。**只在 [openCamera] 里调**（见那里的说明）。
    private func addLiveOutput() {
        let streamer = LiveStreamer(lines: LiveStreamer.tileLines)

        guard session.canAddOutput(streamer.captureOutput) else {
            // ⚠️ 加不上**只是没有推流**（设备给不了第三路输出）。
            // **绝不 return false** —— 录制不受影响，而那才是要紧的那件事。
            NSLog("VidLog: 无法加入实时推流输出，实时共享将不可用")
            return
        }

        session.addOutput(streamer.captureOutput)
        liveStreamer = streamer
    }

    /// 开始往外推（用户打开了实时共享，并且相机是按「要推流」开的）。
    ///
    /// 返回 nil 表示起来了；非 nil 是给用户看的原因。
    ///
    /// ⚠️ **不碰会话**：只把 delegate 接上（见 `LiveStreamer.attach`）。
    func startLive(
        lines: Int,
        onFrame: @escaping (Bool, Data) -> Void,
        onFailure: @escaping (String) -> Void
    ) -> String? {
        guard cameraOpen else { return "相机还没开，推流起不来" }

        guard let liveStreamer else {
            // 开会话那一刻这个开关是关的 —— 而补挂要重新配置会话、
            // 会打断正在录的那一段。如实说，别偷偷做。
            return "还要等下一次【开始工作】才生效（推流那一路是开会话时接上的，"
                + "中途接会打断正在录的那一段）"
        }

        liveStreamer.attach(lines: lines, onFrame: onFrame, onFailure: onFailure)
        return nil
    }

    /// 停止往外推。**输出仍留在会话上**（摘掉它要重新配置会话）。
    func stopLive() {
        liveStreamer?.detach()
    }

    /// 换档（电脑端进/出全屏）。
    ///
    /// ⚠️ 只重建推流那一个编码器，录制那边一个字都不动（规格 §3.8）。
    func setLiveLines(_ lines: Int) {
        liveStreamer?.setLines(lines)
    }

    func closeCamera(_ completion: (() -> Void)? = nil) {
        // 待回弹的自动放大要撤掉：会话马上就要拆了，那个闭包会在两秒后
        // 去改一台 `captureDevice` 已经是 nil 的设备（或更糟 —— 改到
        // 下一次开相机的新设备上）。
        cancelPendingAutoZoomRestore()

        // ⚠️ 手电筒显式关掉。设备跟着会话一起放掉时灯**通常**会灭，但那是「通常」——
        // 而灯关不掉是最难解释的一种故障（用户手里亮着一盏找不到开关的灯）。
        // 必须在 `captureDevice = nil` **之前**调：它要拿设备。
        setTorch(false)

        // 推流那一路先收（规格 §3.8）。它自己那套编码器要显式 invalidate，
        // 而输出会随会话一起没了 —— 顺序是先收编码器、再停会话。
        liveStreamer?.close()
        liveStreamer = nil

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

            // 音频这一路跟着一起收（录制声音，需求方 2026-09-28）。
            // ⚠️ **必须把 audio session 也 deactivate** —— 不放的话，
            // 「结束工作」之后这台手机仍然占着录音通道，别的 App
            // （录音机、语音消息）会拿不到麦克风，而且顶上的录音指示还亮着。
            self.audioOutput = nil
            if self.recordAudio {
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation)
            }

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

    /// 这台设备的后置相机**有没有闪光灯**。相机没开时为 nil。
    ///
    /// 采集页右上角那个手电筒按钮**画不画**看它 ——
    /// 没有闪光灯的设备上画一个按下去什么都不发生的按钮，就是踩坑 #13。
    var hasTorch: Bool? {
        captureDevice?.hasTorch
    }

    /// 开关手电筒（后置闪光灯常亮，照亮面单）。
    ///
    /// ⚠️ 它**只管灯**：不进录像、不改曝光。
    ///
    /// **尽力而为，什么都不抛**：与 `focusNow` 同一条。
    func setTorch(_ on: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }

        // ⚠️ `isTorchAvailable` 是**运行时**的（机身热了、别处在用灯时会变假），
        // 而给不可用的设备赋 `torchMode` 会**抛 NSException** —— 那个是这个
        // `catch` 接不住的（它不是 Swift 的 error）。所以先判再赋。
        //
        // ⚠️ 只在**开**的时候判，关的那条路照走：灯可能真的亮着
        // （开的时候还好好的，之后机身热了）—— 那时更要把它关掉。
        if on && !device.isTorchAvailable {
            NSLog("VidLog: 手电筒现在开不了（灯被别的用着，或机身过热）")
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = on ? .on : .off
        } catch {
            // 灯开不起来不该中断任何事（与变焦失败同一条）。
            NSLog("VidLog: 开关手电筒失败 %@", error.localizedDescription)
        }
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
    /// ⚠️ **它拿到的仍然是会话分辨率**（由规格决定，720P 时是 1280×720）——
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

    /// 录音要用的 `AVAudioSession` 档（录制声音，需求方 2026-09-28）。
    ///
    /// ⚠️ **必须显式设 `.playAndRecord`。** 会话里一加麦克风输入，系统就按
    /// 当前 audio session 的档位决定采不采得到声音；默认档（`.soloAmbient`）
    /// 不支持录音 —— 表现是**音轨是空的、一点都不报错**。
    ///
    /// ⚠️ `.defaultToSpeaker` 是给语音播报用的：不加它，`.playAndRecord` 会把
    /// 声音默认送到**听筒**，播报小到听不见（而那是错码保护唯一的线索）。
    ///
    /// ⚠️ **不要**加 `.mixWithOthers` —— 那会把别的 App 正在放的音乐混进
    /// 取证录像里。规格要的是现场的声音，不是现场的手机外放。
    ///
    /// ⚠️ 失败也不抛：采不到声音就是没有音轨，录像照旧。
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            NSLog("VidLog: 音频会话设不上（\(error.localizedDescription)），这一段可能没有声音")
        }
    }

    /// 把麦克风接进会话。
    ///
    /// 未授权时会抛（`AVCaptureDeviceInput` 的构造是 throwing），
    /// 那个 catch 就是 I4 的降级路径 —— 照常录，只是没有音轨。
    private func addAudioInput() {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            NSLog("VidLog: 找不到可用的麦克风，这一段将没有声音")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                NSLog("VidLog: 麦克风输入无法加入会话，这一段将没有声音")
                return
            }
            session.addInput(input)
        } catch {
            NSLog("VidLog: 麦克风用不了（\(error.localizedDescription)），这一段将没有声音")
        }
    }

    /// 音频输出。
    ///
    /// ⚠️ **它挂的是 `videoQueue`，不是自己一条队列。**
    /// `AVCaptureSession` 会把两个 output 的回调**串行**派发到同一条队列上，
    /// 所以音频这一路与视频那一路永远不会同时在跑 —— `currentWriter` /
    /// `sessionStarted` 那两个标志也就还是单线程在碰，一行锁都不用加。
    /// （分成两条队列的话要上锁，而那一处是 iOS 侧最容易写错的地方。）
    /// 代价只是音视频回调互相等一小下，而音频这一路干的活只有一句 append。
    private func addAudioOutput() {
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            NSLog("VidLog: 无法加入音频输出，这一段将没有声音")
            return
        }

        session.addOutput(output)
        audioOutput = output
    }

    /// 让画面按**用户选的方向**摆（规格 §3.1.7）。
    ///
    /// iOS 17 起 `videoOrientation` 废弃，改用 `videoRotationAngle`；两套都写。
    ///
    /// ⚠️ 与旧版的区别：以前这里写死 90（竖屏）。方向变成选项之后，
    /// **成片的宽高比也跟着它变** —— 所以这不是「转一下画面」，
    /// 而是「录出来的是横的还是竖的」。Dart 那边的取景框与预览比例
    /// 读的是同一个规格（§3.2.2 的连带项），两边才不会各歪各的。
    private func applyOrientation(to connection: AVCaptureConnection, spec: RecorderSpec) {
        if #available(iOS 17.0, *) {
            let angle = spec.rotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = spec.videoOrientation
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

        /// 音轨那一路（录制声音）。**录音关掉时是 nil**。
        ///
        /// ⚠️ 它是**第二个 `AVAssetWriterInput`** —— 所以 [finish] 里
        /// 两个都要 `markAsFinished()`。只 mark 视频那一路的话，
        /// `finishWriting` 会一直等音频 input，表现是
        /// **「停止录像卡住不回」**（而 `stop()` 的完成本来就等最后一段封完）。
        let audioInput: AVAssetWriterInput?

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
             startedAt: TimeInterval, width: Int, height: Int,
             audioInput: AVAssetWriterInput? = nil) {
            self.sequence = sequence
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.fileURL = fileURL
            self.startedAt = startedAt
            self.width = width
            self.height = height
            self.audioInput = audioInput
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
            // 编码与码率都按**这一段实际用的那一档**走（规格 §3.1.7）。
            // `spec` 在 openCamera 时定下，改了规格 Dart 会重开会话。
            AVVideoCodecKey: spec.codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: spec.bitRate,
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

        // ── 音轨（录制声音，需求方 2026-09-28）────────────────────────
        //
        // ⚠️ 三个条件缺一不可：用户开了录音、麦克风那一路真的接上了
        // （`audioOutput != nil`，会话配置时才能确定）、writer 收得下。
        // 少判一个的后果是**一条空的音轨** —— 播放器上显示有声音、点开一片静音，
        // 而「关掉开关后录像不带声音」那条验收会因此判错。
        //
        // ⚠️ **不加 `AVAssetWriterInputPixelBufferAdaptor`** —— adaptor 是给
        // `CVPixelBuffer` 用的（视频专用）。音频是直接 append `CMSampleBuffer`。
        var audioInput: AVAssetWriterInput?
        if recordAudio, audioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: Self.audioChannels,
                AVSampleRateKey: Self.audioSampleRate,
                AVEncoderBitRateKey: Self.audioBitRate,
            ]
            let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            candidate.expectsMediaDataInRealTime = true

            if writer.canAdd(candidate) {
                writer.add(candidate)
                audioInput = candidate
            } else {
                // 加不上就不加：没有音轨是遗憾，录不出来是事故（I4）。
                NSLog("VidLog: 无法加入音频轨，分段 \(sequence) 将没有声音")
            }
        }

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "未知原因"
            onEvent(.failed("分段 \(sequence) 开始写入失败：\(reason)"))
            return nil
        }

        return SegmentWriter(sequence: sequence, writer: writer, input: input,
                             adaptor: adaptor, fileURL: url,
                             startedAt: CACurrentMediaTime(),
                             width: width, height: height,
                             audioInput: audioInput)
    }

    /// 封闭一个分段并上报。
    private func finish(_ segment: SegmentWriter) {
        let sequence = segment.sequence
        let url = segment.fileURL
        let startedAt = segment.startedAt
        let sessionStart = sessionStartedAt

        segment.input.markAsFinished()

        // ⚠️ 音轨那一路**也要 mark**（录制声音，需求方 2026-09-28）。
        // 两个 input 只 mark 一个的话，`finishWriting` 会一直等另一个，
        // 表现是**「停止录像卡住不回」** —— 而 `stop()` 的完成本来就等
        // 最后一段的 `finishWriting`，所以那一下会一直卡着。
        segment.audioInput?.markAsFinished()

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
            //
            // ⚠️ 但 `.failed` **不是**那种情况：那是写坏了，这一段**整段没了**，
            // 而它既不会进收尾、也不会有任何一条记录 —— 不看状态把它和
            // 「空分段」一起丢掉，就是正在丢证据（I2/I3）。
            if segment.writer.status == .failed {
                self.reportWriteFailure("这一分段写失败，整段没进收尾")
            }

            self.completeStopIfNeeded()
        }
    }

    /// 写失败：**上报一条、继续录**（不变量 I3：不存在静默失败）。
    ///
    /// ⚠️ **不停录。** 写失败往往是一时的（缓冲抖动、磁盘正忙），
    /// 停掉等于把一次可能自己好的毛病变成整场没了 —— 录制优先。
    ///
    /// ⚠️ **要节流。** writer 一旦坏掉就是**每一帧**都失败，30 fps 下原样上报
    /// 是一秒三十条，而 `AppLog` 的环与盘上都有上限 —— **刷满的日志等于没有日志**。
    /// 所以：**头一次立刻报**，之后每 [writeFailureReportInterval] 最多一条，
    /// 每条都带累计次数（「还在坏着、一共坏了几次」比「这一帧又坏了」有用）。
    ///
    /// ⚠️ 两个调用点在不同的队列上（[appendFrame] 在采集队列、[finish] 在后台队列），
    /// 所以计数与计时都由 [stateLock] 保护。
    /// ⚠️ 也**别在持锁时调它**（`NSLock` 不是递归锁）。
    private func reportWriteFailure(_ what: String) {
        stateLock.lock()
        writeFailureCount += 1
        let count = writeFailureCount
        let now = CACurrentMediaTime()
        let throttled = lastWriteFailureAt != 0
            && now - lastWriteFailureAt < Self.writeFailureReportInterval
        if !throttled { lastWriteFailureAt = now }
        stateLock.unlock()

        if throttled { return }

        // 走的是**已有的那条上报路径**（`RecorderEvent.failed`，与
        // `makeWriter` 里 startWriting 失败时同一条）—— Dart 那边收到只会
        // 记日志 + 告诉界面，**不会停录**。
        onEvent(.failed("\(what)（累计 \(count) 次）"))
    }

    /// 10 秒是这么定的：比资源闸那 30 秒的轮询快得多（那一条的症状正是
    /// 「告警还没来，东西已经在丢了」），又不至于把日志刷满。
    private static let writeFailureReportInterval: TimeInterval = 10

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

// ⚠️ **两个协议都要声明。** 视频与音频那两路输出（[videoOutput] /
// [audioOutput]）的 delegate 都是 `self`，而它们是**两个不同的协议**
// —— 只写视频那个的话，`setSampleBufferDelegate(self, ...)` 那一行
// 直接编译不过（"does not conform to expected type
// AVCaptureAudioDataOutputSampleBufferDelegate"）。
//
// 下面的 `captureOutput` **一个实现同时满足两个协议**：两个协议要求的
// 方法签名逐字相同，所以不用写两份。哪一路进来靠 `output ===` 分流。
extension CameraSegmentRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                                AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if let analysis = analysisOutput, output === analysis {
            handleAnalysisFrame(sampleBuffer)
            return
        }

        // 音频那一路上来先判 —— 它挂的是**同一条 `videoQueue`**（见
        // [addAudioOutput]），所以下面那些 `currentWriter` / `sessionStarted`
        // 的读写与视频那一路是串行的，不用再加锁。
        if let audio = audioOutput, output === audio {
            appendAudio(sampleBuffer)
            return
        }

        guard output === videoOutput else { return }
        appendFrame(sampleBuffer)
    }

    /// 音轨的一帧（录制声音，需求方 2026-09-28）。
    ///
    /// ## 三条守卫，一条都不能少
    ///
    /// ① `isRecording` —— 相机开着但还没扫到面单时，音频那一路上照样有样本
    ///    （音频输出是从 `openCamera` 就在送）。不拦的话，录制还没开始
    ///    就往一个不存在的 writer 上 append。
    /// ② `currentWriter != nil` —— writer 是**第一帧视频**建起来的
    ///    （尺寸要等第一帧才知道）。在那之前到的音频样本没有地方可写。
    /// ③ `sessionStarted` —— ⚠️ **这一条是本机的关键**：`startSession(atSourceTime:)`
    ///    只能调一次，而现在**只由视频那一帧来调**（见 [appendFrame]）。
    ///    音频的第一帧可能早于视频的第一帧，那时 writer 还没开会话，
    ///    append 会直接抛 `NSException` —— 应用当场闪退。
    ///
    ///    这里刻意**不让音频去开这个会话**：`startSession` 的起始时刻
    ///    要是早于 `startWriting()` 的真实时刻，`AVAssetWriter` 会直接失败。
    ///    代价是开头最多丢一帧视频那么长（约 33ms）的声音 ——
    ///    比「偶尔崩一次」划算得多。
    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }

        stateLock.lock()
        let writer = currentWriter
        stateLock.unlock()

        guard let active = writer, active.sessionStarted,
              let audioInput = active.audioInput,
              active.writer.status == .writing,
              audioInput.isReadyForMoreMediaData
        else { return }

        audioInput.append(sampleBuffer)
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

        // ⚠️ `ready` 把**两件完全不同的事**混在一起，必须分开：
        //   - `writer.status == .failed` ⇒ **写坏了**，这一帧、以及后面每一帧都丢 —— 要报；
        //   - `!input.isReadyForMoreMediaData` ⇒ 编码器正忙，**正常的背压**。
        //     负载高的时候它一直为假，把它当故障报就是误报。
        let writerFailed = writer.map { $0.writer.status == .failed } ?? false
        let ready = writer.map { $0.writer.status == .writing && $0.input.isReadyForMoreMediaData } ?? false
        stateLock.unlock()

        if writerFailed {
            reportWriteFailure("写入视频失败")
            return
        }

        guard ready, let active = writer else { return }

        // 水印（规格 §3.6.2）：**帧进编码器之前**画上去。
        // ⚠️ 失败绝不打断采集 —— 那一段没有水印是遗憾，录不出来是事故。
        watermark.draw(into: imageBuffer, at: presentationTime)

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
        request.symbologies = qrOnly ? Self.qrSymbologies : Self.waybillSymbologies

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
