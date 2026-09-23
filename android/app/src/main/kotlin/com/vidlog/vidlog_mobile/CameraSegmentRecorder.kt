package com.vidlog.vidlog_mobile

import android.Manifest
import android.animation.ValueAnimator
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.Size
import android.view.Surface
import android.view.animation.LinearInterpolator
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.max

/**
 * 一个已经封闭的分段。
 *
 * @param filePath 落盘位置。
 * @param sequence 会话内序号，从 0 起。
 * @param startedAtMs 相对会话起点的**单调**毫秒偏移。
 * @param endedAtMs 同上。
 */
data class ClosedSegment(
    val filePath: String,
    val sequence: Int,
    val startedAtMs: Long,
    val endedAtMs: Long,
)

/** 原生层向 Dart 上报的相机状态。 */
sealed interface RecorderEvent {
    data class SegmentClosed(val segment: ClosedSegment) : RecorderEvent

    /** 画面静止采样（规格 §3.3.3）。[isStatic] 为 true 表示画面连续无显著变化。 */
    data class SceneSampled(val isStatic: Boolean) : RecorderEvent

    /**
     * 识别到一个条码。
     *
     * ⚠️ **这不等于「用户扫了一次码」** —— 相机是连续识码的，包裹摆在画面里
     * 会每秒报好几次。把它变成离散的扫码事件是 Dart 侧 `ScanGate` 的职责
     * （那一层带测试，见 `lib/scanning/scan_gate.dart`）。
     *
     * 坐标是**归一化**的、**原点在左上**，与 iOS 侧逐字一致。
     */
    data class BarcodeDetected(
        val text: String,
        val centerX: Double,
        val centerY: Double,
        val confidence: Double,
    ) : RecorderEvent

    data class Failed(val message: String) : RecorderEvent
}

/**
 * 连续分段录制（Android）。
 *
 * 规格 §3.1.1：
 * > 连续录制，**不因单次时长、文件大小、切分而中断用户体验**
 * > （用户感知为「一直在录」）；落盘为若干分段，每段可独立播放。
 *
 * ## 相机与录制是**两件事**（2026-09-23 拆开）
 *
 * 规格 §3.2.2：点「开始工作」→ 画面出现**可见的取景框**；扫到面单才开录。
 * 所以 [openCamera]（开相机送预览）与 [startRecording]（开录）必须分开 ——
 * 合成一个「startSession」的话，用户一点按钮就在录，屏幕上却什么都没有。
 * iOS 那边（`CameraSegmentRecorder.swift`）从一开始就是分开的，这里对齐它。
 *
 * 拆开之后，[stopRecording] **不再关相机**：取景框还在，下件包裹接着扫。
 *
 * ## 这条流水线
 *
 * ```
 * Camera2 ──(Surface)──> MediaCodec ──(编码后的帧)──> MediaMuxer ──> segment-000.mp4
 *    │                                                    └──轮转──> segment-001.mp4
 *    ├──> ImageReader ──> 静止检测（§3.3.3）+ 识码（§3.2.1）
 *    └──> 预览 Surface（可选，取景框要看得见）
 * ```
 *
 * **编码器全程不停**，只换封装器。这是「不因切分而中断」的落点 ——
 * 如果每次切分都重启编码器，中间会丢掉若干帧，用户看到的就是画面跳一下。
 * 代价是：没在录的时候编码器也在空转，那部分输出被**丢掉**（iOS 同样如此）。
 *
 * ## ⚠️ 轮转必须落在关键帧上
 *
 * 新分段的第一个样本**必须**是 I 帧，否则那个文件从头就是花屏/解不开 ——
 * 正是规格 §8 点名要防的「无法播放的半成品」。
 * 所以 [openSegmentIfNeeded] 只在 `BUFFER_FLAG_KEY_FRAME` 上开新段，
 * [maybeRotate] 同理，且把 `KEY_I_FRAME_INTERVAL` 设成 1 秒让轮转粒度不至于太粗。
 *
 * 拆开之后这还多了一层：编码器从 [openCamera] 就在跑，[startRecording] 那一刻
 * 到达的样本**大概率不是** I 帧。所以开录时显式向编码器要一个同步帧
 * （见 [startRecording]），否则第一段开头就是花屏。
 *
 * ## ⚠️ 时间戳要重新定基准
 *
 * 编码器从开相机就在跑，样本的 PTS 是相机时钟。照原样写进封装器的话，
 * 第一段会从「开相机到开录之间过了多久」那个时刻开始 —— 播出来前面是空的。
 * 所以每段把**本段第一个样本**的 PTS 记成基准，写之前减掉（见 [drainEncoder]）。
 *
 * ## ⚠️ 识码的坐标系（改这段之前先读）
 *
 * 识码跑在分析那一路，取景框判定用的是录像那一路。两者**长宽比常常不同**
 * （比如分析 640x480、录像 1920x1080），而不同长宽比的输出是同一块传感器
 * 有效区的**居中裁切**，不是拉伸 —— 也就是**取景范围本来就不一样**。
 *
 * 不做换算的话，「框里 / 框外」会按纵向错开四分之一屏，
 * 表现是「看着框里却说不算」—— 取证工具最不能有的行为。
 * 换算见 [analysisToDisplay]。
 *
 * ## ⚠️ 这个文件没有在真机上跑过
 *
 * 见 `docs/实现决策.md`：本机没有摄像头、没有真机、不跑模拟器，
 * 所以下面这些代码只验证到「能编译」。真机行为（尤其是轮转与掉电收尾）
 * **必须**走一遍回归才能算数。
 */
class CameraSegmentRecorder(
    private val context: Context,
    private val onEvent: (RecorderEvent) -> Unit,
) {
    companion object {
        private const val TAG = "VidLogRecorder"

        const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC

        /** 单段时长。掉电最多丢这么多 —— 太短会让分段碎，太长会让丢失变大。 */
        const val DEFAULT_SEGMENT_DURATION_MS = 5 * 60 * 1000L

        private const val FRAME_RATE = 30
        private const val I_FRAME_INTERVAL_SECONDS = 1
        private const val BIT_RATE = 8_000_000
        private const val MAX_WIDTH = 1920
        private const val MAX_HEIGHT = 1080

        /**
         * 静止检测的抽样网格大小。
         *
         * 注意这是**抽样后的格数**，不是采集尺寸 —— 采集尺寸由相机支持的
         * 列表决定（见 `pickAnalysisSize`），这里只决定从中抽多少个点。
         */
        private const val ANALYSIS_SAMPLE_WIDTH = 160
        private const val ANALYSIS_SAMPLE_HEIGHT = 120

        /** 相邻两次采样之间，亮度平均绝对差低于这个值就算「没动」。 */
        private const val STATIC_DIFF_THRESHOLD = 3.0

        /** 静止检测的采样间隔。 */
        private const val ANALYSIS_INTERVAL_MS = 500L

        /**
         * 识码的采样间隔。**不跑满帧** —— 识码比静止检测贵得多，
         * 而包裹摆在那儿几秒内扫到就够了（与 iOS 的 0.3 秒一致）。
         */
        private const val BARCODE_SCAN_INTERVAL_MS = 300L

        private const val MUXER_TIMEOUT_US = 10_000L

        /** 面单进框自动放大到几倍（需求方 2026-09-22 裁决 #8：固定 2 倍）。 */
        private const val AUTO_ZOOM_FACTOR = 2.0f

        /** 放大**到位之后**再保持多久（秒）。与 iOS 的 `autoZoomHold` 一致。 */
        private const val AUTO_ZOOM_HOLD_SECONDS = 2.0

        /**
         * 平滑变焦的速率（倍/秒）。**这就是「缓进缓出」那个「缓」**。
         *
         * 规格 §3.1.2：面单进框的自动放大「**必须是缓进缓出**，**不得**表现为
         * 画面瞬间跳大、瞬间跳小」。3.0 ≈ 1×→2× 走约 0.33 秒。
         *
         * ⚠️ **这个数只能真机调**，与 iOS 的 `zoomRampRate` 取同一个值。
         */
        private const val ZOOM_RAMP_RATE = 3.0f

        /** 认为「已经很接近目标、不必再 ramp」的距离（倍）。 */
        private const val RAMP_MIN_DISTANCE = 0.005f

        /**
         * 支持的条码类型。**与 iOS 的 `barcodeSymbologies` 逐项对齐。**
         *
         * 只开了**一维码**：这类条码里装的就是单号本身。
         *
         * **刻意没开二维码（QR / DataMatrix / PDF417）**：电子面单上的二维码里
         * 装的往往是 URL 或一段结构化文本，直接当单号用会往单号字段里灌进
         * 一整条 URL。要用得先知道各家承运商的载荷格式、从里面抽出单号 ——
         * 那是另一件事，别在这里猜。
         */
        private val BARCODE_FORMATS = listOf(
            BarcodeFormat.CODE_128, // 快递面单上最常见
            BarcodeFormat.CODE_39,
            BarcodeFormat.CODE_93,
            BarcodeFormat.ITF,
            BarcodeFormat.EAN_13,
            BarcodeFormat.EAN_8,
            BarcodeFormat.UPC_E,
        )

        private val DECODE_HINTS = mapOf(
            DecodeHintType.POSSIBLE_FORMATS to BARCODE_FORMATS,
            // TRY_HARDER：手持画面里的条码常常是斜的、有点糊。
            // 分析那一路本来就只有几百像素，贵得起。
            DecodeHintType.TRY_HARDER to true,
        )
    }

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var analysisReader: ImageReader? = null

    /** 预览 Surface。相机可以开着而不录，那时它是**唯一**看得见的输出。 */
    private var previewTexture: SurfaceTexture? = null
    private var previewSurface: Surface? = null

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 取编码器输出的线程。
     *
     * **必须有它**：`drainEncoder` 只是「取一次」，没人循环调用的话
     * 编码器输出缓冲区很快会满，然后整个录制卡死 —— 表现是录了几秒就停住。
     */
    private var encoderThread: Thread? = null

    @Volatile
    private var encoderLoopRunning = false

    private var encoderFormat: MediaFormat? = null
    private var trackIndex = -1
    private var segmentSequence = -1
    private var segmentStartedAtMs = 0L
    private var sessionStartedAtMs = 0L

    /** 本段第一个样本的 PTS（微秒），写之前减掉 —— 见类注释「时间戳要重新定基准」。 */
    private var segmentPtsBaselineUs = 0L

    private var outputDirectory: File = File("/dev/null")
    private var segmentDurationMs = DEFAULT_SEGMENT_DURATION_MS

    private var videoSize: Size = Size(1280, 720)
    private var sensorOrientation = 0
    private var zoomRatio = 1.0f

    /** 录像那一路的长宽比。识码坐标换算要用（见 [analysisToDisplay]）。 */
    private var videoAspect = 16.0 / 9.0

    /** 分析那一路的长宽比。同上。 */
    private var analysisAspect = 4.0 / 3.0

    /** 传感器有效区的长宽比。两张画面都是它居中裁出来的。 */
    private var activeAspect = 4.0 / 3.0

    /**
     * 设备支持的变焦上限。规格 §3.1.2：倍率不得超过设备能力。
     *
     * 相机开起来之前是 1.0（还不知道设备能力）。
     */
    var maxZoomRatio = 1.0f
        private set

    /**
     * 设备支持的变焦**下限**。
     *
     * **在 Android 上它恒为 1.0**（相机没开时是 null）：本文件的变焦模型
     * 是 `coerceIn(1.0f, maxZoomRatio)`，压根没有超广角这条路 ——
     * 也就是表盘左半圈（比初始画面更广的那一半）在 Android 上不存在。
     *
     * **如实说明，不补空壳**：Dart 侧拿不到就按 1.0 处理，
     * 结果与「返回 1.0」完全一样（见 `RecorderGateway.minZoom`）。
     */
    val minZoomRatio: Float?
        get() = if (cameraOpen) 1.0f else null

    /** 预览视图要用它算缩放，[CameraPreviewView] 读。 */
    val currentVideoSize: Size get() = videoSize

    /** 预览视图要用它算旋转，[CameraPreviewView] 读。 */
    val currentSensorOrientation: Int get() = sensorOrientation

    private var cropRegion: android.graphics.Rect? = null

    private var lastAnalysisAtMs = 0L
    private var lastBarcodeScanAtMs = 0L
    private var previousLuma: ByteArray? = null
    private var lastReportedStatic: Boolean? = null

    /** ZXing 的解码器。**线程不安全**，只在相机线程的分析回调里用。 */
    private val barcodeReader = MultiFormatReader()

    /** 相机是否**已打开**（不等于正在录）。这两件事必须分开，见类注释。 */
    @Volatile
    var cameraOpen = false
        private set

    @Volatile
    private var running = false

    val isRecording: Boolean get() = running

    // ── 自动放大（面单进框）的三样状态 ──

    private var zoomAnimator: ValueAnimator? = null
    private var pendingZoomRestore: Runnable? = null
    private var savedZoomRatio: Float? = null

    /**
     * 打开相机并开始送预览。**不录。** 返回 false 表示相机打不开。
     *
     * 规格 §3.2.2：用户点「开始工作」→ 画面出现**可见的取景框**；
     * 那时还没扫码，不该录。所以相机开着送预览、等扫到面单才开始录。
     */
    fun openCamera(): Boolean {
        if (cameraOpen) return true

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            onEvent(RecorderEvent.Failed("没有相机权限"))
            return false
        }

        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = pickBackCamera(manager)
        if (cameraId == null) {
            onEvent(RecorderEvent.Failed("找不到可用的后置摄像头"))
            return false
        }

        val characteristics = manager.getCameraCharacteristics(cameraId)
        sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        cropRegion = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        cropRegion?.let { region ->
            if (region.width() > 0 && region.height() > 0) {
                activeAspect = region.width().toDouble() / region.height()
            }
        }
        maxZoomRatio = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.upper ?: 1.0f
        } else {
            characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1.0f
        }
        videoSize = pickVideoSize(characteristics) ?: Size(1280, 720)
        videoAspect = videoSize.width.toDouble() / videoSize.height

        startCameraThread()

        // 预览可能比相机先到（Flutter 建视图与 Dart 调 openCamera 的先后没有保证）。
        // 它的缓冲区尺寸要按**画面尺寸**设 —— 设错了相机输出会被拉伸。
        buildPreviewSurfaceIfPossible()

        cameraOpen = true

        return try {
            openDevice(manager, cameraId, characteristics)
            true
        } catch (error: Exception) {
            Log.e(TAG, "开相机失败", error)
            onEvent(RecorderEvent.Failed("开相机失败：${error.message}"))
            release()
            false
        }
    }

    /**
     * 开始录一段。[directory] 是这一段（= 一个会话）的落盘位置。
     *
     * 与 [openCamera] 分开是刻意的 —— 见类注释。
     * 返回 false 表示相机还没开、或已经在录了。
     */
    fun startRecording(directory: File, segmentDurationMs: Long): Boolean {
        if (!cameraOpen || running) return false

        outputDirectory = directory
        this.segmentDurationMs = segmentDurationMs
        outputDirectory.mkdirs()

        sessionStartedAtMs = SystemClock.elapsedRealtime()
        segmentSequence = -1
        segmentPtsBaselineUs = 0L
        previousLuma = null
        lastReportedStatic = null
        lastBarcodeScanAtMs = 0L

        running = true

        // 编码器从开相机就在跑，此刻到达的样本大概率是 P 帧 ——
        // 直接开段的话那个文件开头就是花屏（见类注释）。显式要一个同步帧，
        // [openSegmentIfNeeded] 会等到它才开段。
        requestSyncFrame()

        return true
    }

    /**
     * 停止录制。**相机保持开着**，取景框还在，下件包裹接着扫。
     *
     * 与 iOS 不同，这里是**同步**的：`MediaMuxer.stop()` 不走异步回调，
     * 所以在返回之前 [RecorderEvent.SegmentClosed] 已经投递出去了。
     * 调用方（[RecorderChannel]）在主线程上调，事件投递也是主线程 ——
     * 「先投递事件，再回结果」这个顺序天然成立。
     */
    fun stopRecording() {
        if (!running) return
        running = false

        // 封段要在会话还活着的时候做，顺序反了会丢最后几帧。
        closeCurrentSegment()
    }

    /** 关闭相机（结束工作）。会先把在录的那段收干净。 */
    fun closeCamera() {
        // 待回弹的自动放大要撤掉：会话马上就要拆了，那个回调会在两秒后
        // 去改一台已经关掉的设备（或更糟 —— 改到下一次开相机的新设备上）。
        cancelPendingAutoZoomRestore()

        stopRecording()
        release()
    }

    /**
     * 挂上 / 摘掉预览输出。
     *
     * ⚠️ 加预览目标**必须重建相机会话**（Camera2 不能在既有会话上换目标）。
     * 重建期间画面会顿一下，但**编码器与封装器不动** —— 录制不中断。
     *
     * 传 null 表示预览视图被销毁了。
     */
    fun setPreviewTexture(texture: SurfaceTexture?) {
        if (previewTexture === texture) return

        previewTexture = texture
        previewSurface?.release()
        previewSurface = null

        if (texture == null) {
            rebuildSessionIfOpen()
            return
        }

        if (cameraOpen) {
            buildPreviewSurfaceIfPossible()
            rebuildSessionIfOpen()
        }
    }

    /**
     * 设置缩放倍率（表盘拖动，**瞬时**）。
     *
     * 规格 §3.1.2：设备不支持光学变焦时退化为数字变焦，**倍率不得超过设备能力上限**。
     */
    fun setZoom(ratio: Float) {
        // 操作员自己拖了表盘 —— 那是他**此刻的意图**，要撤销待回弹的自动放大。
        // 不撤销的话，两秒后画面会从他刚调好的倍率跳回去，看起来像表盘失灵。
        cancelPendingAutoZoomRestore()
        applyZoomRatio(ratio)
    }

    /**
     * 立刻对焦到画面正中，**不动倍率**。
     *
     * 规格 §3.1.2：表盘滑动时「无论怎么滑都自动对焦」。
     *
     * **尽力而为，什么都不抛**：与 [setZoom] 一样，失败就当作没发生。
     */
    fun focusNow() {
        val session = captureSession ?: return
        val device = cameraDevice ?: return

        try {
            // 标准的「触发一次 AF」配方：先 START 再 CANCEL。
            // 少了 CANCEL 的话，会话会一直停在「正在对焦」上，
            // 之后连续对焦就不工作了。
            for (trigger in listOf(
                CaptureRequest.CONTROL_AF_TRIGGER_START,
                CaptureRequest.CONTROL_AF_TRIGGER_CANCEL,
            )) {
                val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                applyTargets(builder)
                builder.set(CaptureRequest.CONTROL_AF_TRIGGER, trigger)
                session.capture(builder.build(), null, cameraHandler)
            }
        } catch (error: Exception) {
            Log.w(TAG, "触发自动对焦失败", error)
        }
    }

    /**
     * 面单刚进框：对焦到画面正中 + 临时放大，两秒后回到原倍率。
     *
     * 计时**归原生**，不是 Dart —— 回弹必须落在**同一台相机设备**上。
     * 放 Dart 计时的话，中间一次关相机/开相机会让回调去改新会话的倍率。
     *
     * **尽力而为，什么都不抛。**
     */
    fun autoFocusAndZoom() {
        // 变速动画要 Looper 线程；调用方（通道）本来就在主线程，
        // 但这里不假设 —— 挪过去只是一行。
        mainHandler.post {
            if (!cameraOpen) return@post

            focusNow()

            // 棘轮式：`max(当前倍率, 2.0)` 再钳到上限 —— **绝不往回缩**。
            // 操作员自己拖到 3× 时，自动放大不该先把画面变小一下。
            val target = max(zoomRatio, AUTO_ZOOM_FACTOR).coerceAtMost(maxZoomRatio)

            // ⚠️ **只在「没有待回弹」时记原值。**
            // 连续扫每件都会触发一次；每次都记的话，记下的就是上一次放大后的值，
            // 倍率会一级一级往上爬，最后停在设备上限上再也回不来。
            if (pendingZoomRestore == null) savedZoomRatio = zoomRatio

            val seconds = rampSeconds(zoomRatio, target)
            rampZoomTo(target, seconds)

            // 保持时长是**到位之后**另加的 —— 推到位那 0.33 秒不该吃掉那两秒。
            scheduleZoomRestore(seconds + AUTO_ZOOM_HOLD_SECONDS)
        }
    }

    /** 由 [RecorderChannel] 在 `dispose` 时调用。 */
    fun release() {
        running = false
        closeCurrentSegment()

        try {
            captureSession?.close()
        } catch (error: Exception) {
            Log.w(TAG, "关会话失败", error)
        }
        captureSession = null

        try {
            cameraDevice?.close()
        } catch (error: Exception) {
            Log.w(TAG, "关相机失败", error)
        }
        cameraDevice = null

        encoderLoopRunning = false
        encoderThread?.let { thread ->
            try {
                thread.join(2_000)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        encoderThread = null

        try {
            encoder?.stop()
            encoder?.release()
        } catch (error: Exception) {
            // 编码器已经处于错误态时 stop() 会抛 —— 分段文件仍然有效，
            // 不能因为这一下把已经录好的东西当成失败。
            Log.w(TAG, "停编码器失败", error)
        }
        encoder = null

        inputSurface?.release()
        inputSurface = null

        analysisReader?.close()
        analysisReader = null

        previewSurface?.release()
        previewSurface = null
        // ⚠️ **不清 previewTexture。** 预览视图比一次录制会话活得久：
        // 「结束」再「开始工作」时那个 TextureView 还在，它的 SurfaceTexture
        // 也还有效。清掉的话第二次开始就没有画面了 —— 而用户看不出为什么。
        // 摘掉的责任在视图那边（`setPreviewTexture(null)`）。

        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null

        cameraOpen = false
    }

    // ─────────────────────────────────────────────
    // 相机
    // ─────────────────────────────────────────────

    private fun startCameraThread() {
        cameraThread?.quitSafely()
        cameraThread = HandlerThread("vidlog-camera").also { it.start() }
        cameraHandler = Handler(cameraThread!!.looper)
    }

    private fun pickBackCamera(manager: CameraManager): String? {
        val ids = manager.cameraIdList
        for (id in ids) {
            val facing = manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_BACK) return id
        }
        return ids.firstOrNull()
    }

    /**
     * 静止检测与识码用的尺寸。
     *
     * 挑相机**支持**的最小一档：分析用不上大图，越小越省。
     * 找不到任何支持尺寸时退回 320x240 并寄希望于它可用 ——
     * 那种情况下会话可能建不起来，但那属于相机本身异常。
     *
     * ⚠️ 这里**不要求**与录像同长宽比：两者取景范围本来就可能不同，
     * 那个差异由 [analysisToDisplay] 换算掉，而不是靠挑尺寸回避。
     */
    private fun pickAnalysisSize(characteristics: CameraCharacteristics): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return Size(320, 240)

        val sizes = map.getOutputSizes(ImageFormat.YUV_420_888)
            ?.filter { it.width <= 640 && it.height <= 480 }
            ?: return Size(320, 240)

        return sizes.minByOrNull { it.width.toLong() * it.height } ?: Size(320, 240)
    }

    private fun pickVideoSize(characteristics: CameraCharacteristics): Size? {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return null

        return map.getOutputSizes(MediaCodecInfo.CodecCapabilities::class.java)
            ?.filter { it.width <= MAX_WIDTH && it.height <= MAX_HEIGHT }
            // 取不超过上限里最大的那个 —— 越大越清楚，但不越过上面那两道线。
            ?.maxByOrNull { it.width.toLong() * it.height }
            ?: map.getOutputSizes(ImageFormat.YUV_420_888)
                ?.filter { it.width <= MAX_WIDTH && it.height <= MAX_HEIGHT }
                ?.maxByOrNull { it.width.toLong() * it.height }
    }

    private fun openDevice(
        manager: CameraManager,
        cameraId: String,
        characteristics: CameraCharacteristics,
    ) {
        // 先建编码器，拿到 input surface，再把它作为相机的输出目标。
        val codec = MediaCodec.createEncoderByType(MIME_TYPE)

        val format = MediaFormat.createVideoFormat(MIME_TYPE, videoSize.width, videoSize.height)
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
        // 1 秒一个关键帧：轮转只能落在关键帧上，所以这个值直接决定分段边界的精度。
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_SECONDS)

        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        codec.start()
        encoder = codec

        startEncoderLoop()

        // 静止检测与识码用一路单独的输出，不影响录制。
        //
        // ⚠️ 尺寸**必须从相机支持的列表里挑**：ImageReader 作为会话的一个目标时，
        // 尺寸不在 `getOutputSizes` 里会让整个 `createCaptureSession` 失败 ——
        // 连录制都起不来。硬编码一个 160x120 是很容易踩的坑。
        val analysisSize = pickAnalysisSize(characteristics)
        analysisAspect = analysisSize.width.toDouble() / analysisSize.height
        val reader = ImageReader.newInstance(
            analysisSize.width, analysisSize.height, ImageFormat.YUV_420_888, 2,
        )
        reader.setOnImageAvailableListener({ onAnalysisFrame(it) }, cameraHandler)
        analysisReader = reader

        @Suppress("MissingPermission")
        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                cameraDevice = device
                createSession(device)
            }

            override fun onDisconnected(device: CameraDevice) {
                device.close()
                cameraDevice = null
                onEvent(RecorderEvent.Failed("相机被抢占或断开"))
            }

            override fun onError(device: CameraDevice, error: Int) {
                device.close()
                cameraDevice = null

                // 规格 §8：录制中掉电/异常不得产生不可播放的半成品 ——
                // 相机错误时把当前分段封掉，让它成为一段完整可播的文件。
                closeCurrentSegment()
                onEvent(RecorderEvent.Failed("相机错误，代码 $error"))
            }
        }, cameraHandler)
    }

    /** 当前会话要喂哪几路输出。预览是可选的那一路。 */
    private fun sessionTargets(): List<Surface> {
        val targets = mutableListOf<Surface>()
        inputSurface?.let { targets.add(it) }
        analysisReader?.let { targets.add(it.surface) }
        previewSurface?.let { targets.add(it) }
        return targets
    }

    private fun createSession(device: CameraDevice) {
        val targets = sessionTargets()
        if (targets.isEmpty()) return

        // 每次 setRepeatingRequest 都要现建一个 request —— 会话只认目标集，
        // 不认某个特定的 builder。重复的那个（预览）存下来复用。
        val builder = buildRequest(device)

        device.createCaptureSession(
            targets,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    // 相机已经关了（拆到一半）就别再发请求了。
                    if (!cameraOpen) return
                    captureSession = session
                    try {
                        session.setRepeatingRequest(builder.build(), null, cameraHandler)
                    } catch (error: Exception) {
                        onEvent(RecorderEvent.Failed("启动预览失败：${error.message}"))
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    onEvent(RecorderEvent.Failed("相机会话配置失败"))
                }
            },
            cameraHandler,
        )
    }

    /** 目标集变了（预览挂上/摘掉）就重建会话。相机不停、编码器不停。 */
    private fun rebuildSessionIfOpen() {
        val device = cameraDevice ?: return

        try {
            captureSession?.close()
        } catch (error: Exception) {
            Log.w(TAG, "重建会话前关旧会话失败", error)
        }
        captureSession = null

        createSession(device)
    }

    private fun buildRequest(device: CameraDevice): CaptureRequest.Builder {
        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        applyTargets(builder)
        applyZoom(builder)
        return builder
    }

    private fun applyTargets(builder: CaptureRequest.Builder) {
        inputSurface?.let { builder.addTarget(it) }
        analysisReader?.let { builder.addTarget(it.surface) }
        previewSurface?.let { builder.addTarget(it) }
    }

    /** 预览的 Surface。缓冲区尺寸必须按**画面尺寸**设，否则相机输出会被拉伸。 */
    private fun buildPreviewSurfaceIfPossible() {
        val texture = previewTexture ?: return
        if (previewSurface != null) return

        texture.setDefaultBufferSize(videoSize.width, videoSize.height)
        previewSurface = Surface(texture)
    }

    /**
     * 应用缩放。
     *
     * API 30+ 有 `CONTROL_ZOOM_RATIO`；更早的版本只能裁 `SCALER_CROP_REGION`
     * —— 那就是数字变焦，画质会掉，但规格 §3.1.2 说了不支持光学变焦时退化即可。
     */
    private fun applyZoom(builder: CaptureRequest.Builder) {
        val active = cropRegion ?: return
        val ratio = zoomRatio.coerceIn(1.0f, maxZoomRatio)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, ratio)
            return
        }

        val width = (active.width() / ratio).toInt().coerceIn(1, active.width())
        val height = (active.height() / ratio).toInt().coerceIn(1, active.height())
        val left = active.left + (active.width() - width) / 2
        val top = active.top + (active.height() - height) / 2

        builder.set(
            CaptureRequest.SCALER_CROP_REGION,
            android.graphics.Rect(left, top, left + width, top + height),
        )
    }

    /** 真正把倍率送进重复请求。**所有**改倍率的路都走这里。 */
    private fun applyZoomRatio(ratio: Float) {
        zoomRatio = ratio.coerceIn(1.0f, maxZoomRatio)

        val session = captureSession ?: return
        val device = cameraDevice ?: return

        try {
            session.setRepeatingRequest(buildRequest(device).build(), null, cameraHandler)
        } catch (error: Exception) {
            Log.w(TAG, "设置缩放失败", error)
        }
    }

    // ─────────────────────────────────────────────
    // 自动放大（面单进框）
    // ─────────────────────────────────────────────

    /** 从 `from` 推到 `to` 要走多久（秒）。 */
    private fun rampSeconds(from: Float, to: Float): Double {
        val distance = abs(to - from)
        if (distance < RAMP_MIN_DISTANCE) return 0.0
        return (distance / ZOOM_RAMP_RATE).toDouble()
    }

    /**
     * 平滑地把倍率推到 `target`。**「缓进缓出」的实现就在这个动画里。**
     *
     * 为什么不是一次赋值：那是**瞬时跳变**，需求方 2026-09-22 明确否掉了
     * （「不要突然放大，突然缩小」）。
     *
     * 表盘**不走这里**：拖动要跟手，必须瞬时（见 [setZoom]）。
     *
     * ⚠️ 诚实说明：`ValueAnimator` 配线性插值是**匀速**，不是 S 曲线。
     * 需求方要的「不要突然放大 / 突然缩小」它完全满足；严格意义的「缓进缓出」
     * （起手慢、中间快、收尾慢）它没有。真机觉得硬再换插值器。
     */
    private fun rampZoomTo(target: Float, seconds: Double) {
        zoomAnimator?.cancel()
        zoomAnimator = null

        if (seconds <= 0.0) {
            applyZoomRatio(target)
            return
        }

        zoomAnimator = ValueAnimator.ofFloat(zoomRatio, target).apply {
            duration = (seconds * 1000).toLong()
            interpolator = LinearInterpolator()
            addUpdateListener { applyZoomRatio(it.animatedValue as Float) }
            start()
        }
    }

    private fun scheduleZoomRestore(delaySeconds: Double) {
        cancelZoomRestoreRunnable()

        val runnable = Runnable {
            pendingZoomRestore = null

            val saved = savedZoomRatio
            savedZoomRatio = null
            if (saved != null) rampZoomTo(saved, rampSeconds(zoomRatio, saved))
        }

        pendingZoomRestore = runnable
        mainHandler.postDelayed(runnable, (delaySeconds * 1000).toLong())
    }

    /**
     * 撤销待回弹的自动放大（操作员自己动了表盘、或相机会话要拆了）。
     *
     * 不撤销的话：前者表现为「表盘失灵」（画面从刚调好的倍率跳回去），
     * 后者表现为「回弹落在一个已经拆掉的会话上」。
     */
    private fun cancelPendingAutoZoomRestore() {
        cancelZoomRestoreRunnable()
        savedZoomRatio = null

        zoomAnimator?.cancel()
        zoomAnimator = null
    }

    private fun cancelZoomRestoreRunnable() {
        pendingZoomRestore?.let { mainHandler.removeCallbacks(it) }
        pendingZoomRestore = null
    }

    /**
     * 循环取编码器输出。
     *
     * 没有这个循环，编码器的输出缓冲区会一直积压，录制几秒后就卡死。
     * 这是写这段时最容易漏的一环 —— 漏了不会编译报错，只会「录一小段就停」。
     *
     * **从开相机起就一直在跑**（没在录的时候取出来的帧直接丢掉）：
     * 编码器一停，[startRecording] 就得重启它，那会丢掉好几帧。
     */
    private fun startEncoderLoop() {
        encoderLoopRunning = true

        encoderThread = Thread({
            while (encoderLoopRunning) {
                try {
                    drainEncoder()
                } catch (error: Exception) {
                    Log.e(TAG, "取编码输出失败", error)
                    onEvent(RecorderEvent.Failed("取编码输出失败：${error.message}"))
                    encoderLoopRunning = false
                }
            }
        }, "vidlog-encoder").also { it.start() }
    }

    /** 向编码器要一个同步帧（I 帧）。开录时用 —— 见 [startRecording]。 */
    private fun requestSyncFrame() {
        val codec = encoder ?: return

        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec.setParameters(params)
        } catch (error: Exception) {
            // 要不到也不致命：最多是等下一个自然关键帧（≤1 秒）。
            Log.w(TAG, "请求同步帧失败", error)
        }
    }

    // ─────────────────────────────────────────────
    // 静止检测与识码
    // ─────────────────────────────────────────────

    /**
     * 分析那一路的画面到达。
     *
     * 规格 §3.3.3：画面**连续无显著变化**即判定为静止。
     * 规格 §3.2.1：摄像头识码。
     *
     * 两件事共用这一路、共用这个 500ms 节拍 —— 与 iOS 的分工一致。
     */
    private fun onAnalysisFrame(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        try {
            val now = SystemClock.elapsedRealtime()
            if (now - lastAnalysisAtMs < ANALYSIS_INTERVAL_MS) return
            lastAnalysisAtMs = now

            detectStatic(image)
            detectBarcodes(image, now)
        } catch (error: Exception) {
            Log.w(TAG, "分析帧失败", error)
        } finally {
            image.close()
        }
    }

    /**
     * 相邻两帧亮度平面的平均绝对差。够用且极省电 ——
     * 真正的静止判定不该吃掉录制的算力。
     */
    private fun detectStatic(image: Image) {
        val plane = image.planes[0]
        val buffer: ByteBuffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride

        val width = image.width
        val height = image.height

        val sampleWidth = minOf(ANALYSIS_SAMPLE_WIDTH, width)
        val sampleHeight = minOf(ANALYSIS_SAMPLE_HEIGHT, height)
        if (sampleWidth <= 0 || sampleHeight <= 0) return

        // **在整个画面上按网格抽样**，不是只读左上角一块。
        // 只读一角的话，动作发生在别处、那个角落恰好不动时会被误判成「静止」。
        val stepX = maxOf(1, width / ANALYSIS_SAMPLE_WIDTH)
        val stepY = maxOf(1, height / ANALYSIS_SAMPLE_HEIGHT)

        val luma = ByteArray(sampleWidth * sampleHeight)
        for (y in 0 until sampleHeight) {
            val rowStart = (y * stepY) * rowStride
            for (x in 0 until sampleWidth) {
                luma[y * sampleWidth + x] = buffer.get(rowStart + x * stepX * pixelStride)
            }
        }

        val previous = previousLuma
        previousLuma = luma

        if (previous == null) return

        var total = 0L
        for (i in luma.indices) {
            total += abs((luma[i].toInt() and 0xFF) - (previous[i].toInt() and 0xFF))
        }

        val average = total.toDouble() / luma.size
        val isStatic = average < STATIC_DIFF_THRESHOLD

        // 只在状态**变化**时上报，别把通道刷爆。
        if (lastReportedStatic != isStatic) {
            lastReportedStatic = isStatic
            onEvent(RecorderEvent.SceneSampled(isStatic))
        }
    }

    /**
     * 用 ZXing 识码（规格 §3.2.1「摄像头识码」）。
     *
     * ## 为什么是 ZXing
     *
     * Android 平台**没有**自带的条码解码 API（iOS 有 Vision）。
     * `com.google.zxing:core` 是 Apache-2.0、纯 Java、只做解码不做相机 ——
     * 正合规格 §10 那条「第三方库要逐个核对许可证」的账。
     *
     * ## ⚠️ 坐标系（改这段之前先读类注释）
     *
     * ZXing 给的是**分析帧**里的像素坐标，而取景框判定用的是**录像帧**的
     * 归一化坐标。两者长宽比常常不同，中间要过 [analysisToDisplay]。
     * 直接把 `x/width` 当结果发出去，纵向会错开四分之一屏。
     *
     * ## ⚠️ 方向（真机上如果扫不到，先查这里）
     *
     * 分析帧是**传感器方向**（一般是横的），没有旋转过；
     * 旋转由 [analysisToDisplay] 里的 `sensorOrientation` 换算承担。
     */
    private fun detectBarcodes(image: Image, now: Long) {
        if (now - lastBarcodeScanAtMs < BARCODE_SCAN_INTERVAL_MS) return
        lastBarcodeScanAtMs = now

        val width = image.width
        val height = image.height
        if (width <= 0 || height <= 0) return

        val plane = image.planes[0]
        val luma = compactLuma(image, plane, width, height) ?: return

        val source = PlanarYUVLuminanceSource(luma, width, height, 0, 0, width, height, false)
        val bitmap = BinaryBitmap(HybridBinarizer(source))

        val result = try {
            barcodeReader.decode(bitmap, DECODE_HINTS)
        } catch (notFound: NotFoundException) {
            // 绝大多数帧都是这个结果 —— 画面里本来就没码。不是错误。
            return
        } catch (error: Exception) {
            Log.w(TAG, "识码失败", error)
            return
        } finally {
            barcodeReader.reset()
        }

        val text = result.text
        if (text.isNullOrEmpty()) return

        val points = result.resultPoints
        if (points == null || points.isEmpty()) {
            // 拿不到位置就没法判定它在不在取景框里。宁可不报，
            // 也不能拿画面中心去顶 —— 那会伪造出一次「框里的扫码」。
            return
        }

        var sumX = 0.0
        var sumY = 0.0
        for (point in points) {
            sumX += point.x
            sumY += point.y
        }

        val (centerX, centerY) = analysisToDisplay(
            sumX / points.size / width,
            sumY / points.size / height,
        )

        onEvent(
            RecorderEvent.BarcodeDetected(
                text = text,
                centerX = centerX,
                centerY = centerY,
                // ZXing 不给置信度，解出来了就是确定读到了。
                // Dart 侧只把它往下传，不做任何阈值判定（见 viewfinder.dart）。
                confidence = 1.0,
            ),
        )
    }

    /**
     * 把 YUV 图像的亮度平面抄成一段**紧凑**数组。
     *
     * ZXing 只认「每行就是 width 个字节」的排布，而相机给的 `rowStride`
     * 常常大于 `width`（行尾有填充）。直接把它交出去，画面会一条条斜着错开 ——
     * 那种错法在识码上的表现是「永远扫不出来」，很难查。
     */
    private fun compactLuma(image: Image, plane: android.media.Image.Plane, width: Int, height: Int): ByteArray? {
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val luma = ByteArray(width * height)

        if (pixelStride == 1 && rowStride == width) {
            buffer.position(0)
            buffer.get(luma)
            return luma
        }

        for (y in 0 until height) {
            val rowStart = y * rowStride
            for (x in 0 until width) {
                luma[y * width + x] = buffer.get(rowStart + x * pixelStride)
            }
        }

        return luma
    }

    // ─────────────────────────────────────────────
    // 坐标换算
    // ─────────────────────────────────────────────

    /**
     * 分析帧的归一化坐标 → **显示画面**的归一化坐标（原点左上，与 iOS 一致）。
     *
     * 三步，缺一不可：
     *
     * 1. 分析帧 → 传感器有效区（两者长宽比不同，是居中裁切的关系）
     * 2. 传感器有效区 → 录像帧（同上，反着来）
     * 3. 录像帧 → 显示画面（录像带 `setOrientationHint(sensorOrientation)`，
     *    也就是播放时要**顺时针转 `sensorOrientation` 度**）
     *
     * ⚠️ 第 1、2 步是这个文件里最容易做错、也最难在真机上看出来的一处：
     * 少了它们，判定会按纵向错开，表现是「看着框里却说不算」。
     */
    private fun analysisToDisplay(u: Double, v: Double): Pair<Double, Double> {
        val sensor = frameToSensor(u, v, analysisAspect)
        val video = sensorToFrame(sensor.first, sensor.second, videoAspect)

        return when (sensorOrientation) {
            // 顺时针转 90°：左边缘转到上边缘
            90 -> (1 - video.second) to video.first
            180 -> (1 - video.first) to (1 - video.second)
            270 -> video.second to (1 - video.first)
            else -> video.first to video.second
        }
    }

    /**
     * 某个**输出帧**的归一化坐标 → 传感器有效区的归一化坐标。
     *
     * 不同长宽比的输出是同一块有效区的**居中裁切**（不是拉伸）——
     * 这就是为什么 4:3 的输出能看到 16:9 看不到的那一条边。
     */
    private fun frameToSensor(x: Double, y: Double, frameAspect: Double): Pair<Double, Double> {
        if (!frameAspect.isFinite() || frameAspect <= 0) return x to y
        if (!activeAspect.isFinite() || activeAspect <= 0) return x to y

        return if (frameAspect >= activeAspect) {
            val fraction = activeAspect / frameAspect
            x to ((1 - fraction) / 2 + y * fraction)
        } else {
            val fraction = frameAspect / activeAspect
            ((1 - fraction) / 2 + x * fraction) to y
        }
    }

    /** [frameToSensor] 的反函数。 */
    private fun sensorToFrame(x: Double, y: Double, frameAspect: Double): Pair<Double, Double> {
        if (!frameAspect.isFinite() || frameAspect <= 0) return x to y
        if (!activeAspect.isFinite() || activeAspect <= 0) return x to y

        return if (frameAspect >= activeAspect) {
            val fraction = activeAspect / frameAspect
            x to (y - (1 - fraction) / 2) / fraction
        } else {
            val fraction = frameAspect / activeAspect
            ((x - (1 - fraction) / 2) / fraction) to y
        }
    }

    // ─────────────────────────────────────────────
    // 编码与分段轮转
    // ─────────────────────────────────────────────

    /** 编码器输出到达。由 `startEncoderLoop` 起的线程驱动。 */
    fun drainEncoder(endOfStream: Boolean = false) {
        val codec = encoder ?: return
        val info = MediaCodec.BufferInfo()

        while (true) {
            val index = codec.dequeueOutputBuffer(info, MUXER_TIMEOUT_US)

            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }

                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // 只在第一个分段时记下来；轮转时复用同一份配置。
                    if (encoderFormat == null) encoderFormat = codec.outputFormat
                }

                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)
                    val isKeyFrame =
                        (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                    if (buffer != null && info.size > 0 && running) {
                        // 没在录的时候**照样取出来、照样丢掉**（见 startEncoderLoop）。
                        if (muxer == null) {
                            openSegmentIfNeeded(isKeyFrame, info.presentationTimeUs)
                        } else {
                            // 先判轮转再写 —— 关键帧正好是新分段的开头。
                            maybeRotate(isKeyFrame, info.presentationTimeUs)
                        }

                        muxer?.let { muxer ->
                            if (trackIndex >= 0) {
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)

                                // 时间戳重新定基准：本段第一个样本归零。
                                // 不减的话，第一段会从「开相机到开录」那一刻起算。
                                info.presentationTimeUs -= segmentPtsBaselineUs

                                try {
                                    muxer.writeSampleData(trackIndex, buffer, info)
                                } catch (error: Exception) {
                                    Log.w(TAG, "写入封装器失败", error)
                                }
                            }
                        }
                    }

                    codec.releaseOutputBuffer(index, false)

                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    /**
     * 开录后的第一个关键帧到达 → 开第一段。
     *
     * 非关键帧直接跳过：那一段的开头会是花屏（见类注释）。
     * 编码器的关键帧间隔是 1 秒，所以最坏情况也就等 1 秒。
     */
    private fun openSegmentIfNeeded(isKeyFrame: Boolean, ptsUs: Long) {
        if (!isKeyFrame) return
        if (encoderFormat == null) return
        openNewSegment(ptsUs)
    }

    /**
     * 到点且当前是关键帧时轮转分段。
     *
     * **编码器不重启**，只换封装器 —— 这是「用户感知为一直在录」的落点。
     */
    private fun maybeRotate(isKeyFrame: Boolean, ptsUs: Long) {
        if (!isKeyFrame) return
        if (!running) return
        if (SystemClock.elapsedRealtime() - segmentStartedAtMs < segmentDurationMs) return

        closeCurrentSegment()
        // 新段的基准是**这一帧**的时间戳 —— 不能沿用上一段的基准，
        // 否则新段的第一个样本不是 0，播出来开头会是一段空白。
        openNewSegment(ptsUs)
    }

    private fun openNewSegment(ptsUs: Long) {
        val format = encoderFormat ?: return

        segmentSequence++
        segmentStartedAtMs = SystemClock.elapsedRealtime()
        segmentPtsBaselineUs = ptsUs

        val file = File(
            outputDirectory,
            "segment-${"%03d".format(segmentSequence)}.mp4",
        )

        try {
            val newMuxer = MediaMuxer(
                file.absolutePath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
            )
            newMuxer.setOrientationHint(sensorOrientation)
            trackIndex = newMuxer.addTrack(format)
            newMuxer.start()
            muxer = newMuxer
        } catch (error: Exception) {
            Log.e(TAG, "开新分段失败", error)
            onEvent(RecorderEvent.Failed("开新分段失败：${error.message}"))
        }
    }

    private fun closeCurrentSegment() {
        val current = muxer ?: return
        val sequence = segmentSequence
        val startedAt = segmentStartedAtMs - sessionStartedAtMs
        val endedAt = SystemClock.elapsedRealtime() - sessionStartedAtMs

        muxer = null
        trackIndex = -1

        // stop() 在「一个样本都没写」时会抛。那种分段本来也没有内容，忽略即可。
        var stopped = false
        try {
            current.stop()
            stopped = true
        } catch (error: Exception) {
            Log.w(TAG, "封装器 stop 失败（多半是本段没有样本）", error)
        } finally {
            try {
                current.release()
            } catch (error: Exception) {
                Log.w(TAG, "封装器 release 失败", error)
            }
        }

        if (!stopped) return

        val file = File(outputDirectory, "segment-${"%03d".format(sequence)}.mp4")
        if (!file.exists() || file.length() == 0L) return

        onEvent(
            RecorderEvent.SegmentClosed(
                ClosedSegment(
                    filePath = file.absolutePath,
                    sequence = sequence,
                    startedAtMs = startedAt,
                    endedAtMs = endedAt,
                ),
            ),
        )
    }
}
