package com.vidlog.vidlog_mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.core.content.ContextCompat
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs

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

    data class Failed(val message: String) : RecorderEvent
}

/**
 * 连续分段录制。
 *
 * 规格 §3.1.1：
 * > 连续录制，**不因单次时长、文件大小、切分而中断用户体验**
 * > （用户感知为「一直在录」）；落盘为若干分段，每段可独立播放。
 *
 * ## 实现要点
 *
 * 相机 → 编码器 → 封装器：
 *
 * ```
 * Camera2 ──(Surface)──> MediaCodec ──(编码后的帧)──> MediaMuxer ──> segment-000.mp4
 *                                                        └──轮转──> segment-001.mp4
 * ```
 *
 * **编码器全程不停**，只换封装器。这是「不因切分而中断」的落点 ——
 * 如果每次切分都重启编码器，中间会丢掉若干帧，用户看到的就是画面跳一下。
 *
 * ## ⚠️ 轮转必须落在关键帧上
 *
 * 新分段的第一个样本**必须**是 I 帧，否则那个文件从头就是花屏/解不开 ——
 * 正是规格 §8 点名要防的「无法播放的半成品」。
 * 所以 [maybeRotate] 只在 `BUFFER_FLAG_KEY_FRAME` 上动手，
 * 且把 `KEY_I_FRAME_INTERVAL` 设成 1 秒，让轮转的粒度不至于太粗。
 *
 * ## ⚠️ 这个文件没有在真机上跑过
 *
 * 见 `docs/实现决策.md`：本机没有摄像头、没有真机、不跑模拟器，
 * 所以下面这些代码只验证到「能编译」。真机行为（尤其是轮转与掉电收尾）
 * **必须**走一遍回归才能算数。
 */
class CameraSegmentRecorder(
    private val context: Context,
    private val outputDirectory: File,
    private val segmentDurationMs: Long = DEFAULT_SEGMENT_DURATION_MS,
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

        private const val MUXER_TIMEOUT_US = 10_000L
    }

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var analysisReader: ImageReader? = null

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

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

    private var videoSize: Size = Size(1280, 720)
    private var sensorOrientation = 0
    private var zoomRatio = 1.0f

    /** 设备支持的变焦上限。规格 §3.1.2：倍率不得超过设备能力。 */
    private var maxZoomRatio = 1.0f

    private var cropRegion: android.graphics.Rect? = null

    private var lastAnalysisAtMs = 0L
    private var previousLuma: ByteArray? = null
    private var lastReportedStatic: Boolean? = null

    @Volatile
    private var running = false

    val isRecording: Boolean get() = running

    /** 开始录制。返回 false 表示相机打不开（权限、被占用、无可用设备）。 */
    fun start(): Boolean {
        if (running) return false

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
        maxZoomRatio = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.upper ?: 1.0f
        } else {
            characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1.0f
        }
        videoSize = pickVideoSize(characteristics) ?: Size(1280, 720)

        outputDirectory.mkdirs()

        cameraThread = HandlerThread("vidlog-camera").also { it.start() }
        cameraHandler = Handler(cameraThread!!.looper)

        sessionStartedAtMs = SystemClock.elapsedRealtime()
        running = true

        return try {
            openCamera(manager, cameraId, characteristics)
            true
        } catch (error: Exception) {
            Log.e(TAG, "开相机失败", error)
            onEvent(RecorderEvent.Failed("开相机失败：${error.message}"))
            release()
            false
        }
    }

    /** 停止录制。会封掉当前分段并上报。 */
    fun stop() {
        if (!running) return
        running = false

        // 先停编码取数据循环，再关会话 —— 顺序反了会在关会话时丢最后几帧。
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

        closeCurrentSegment()

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

        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }

    /**
     * 设置缩放倍率。
     *
     * 规格 §3.1.2：设备不支持光学变焦时退化为数字变焦，**倍率不得超过设备能力上限**。
     */
    fun setZoom(ratio: Float) {
        // 规格 §3.1.2：倍率不得超过设备能力上限。
        zoomRatio = ratio.coerceIn(1.0f, maxZoomRatio)

        val session = captureSession ?: return
        val device = cameraDevice ?: return

        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            applyTargets(builder)
            applyZoom(builder)
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (error: Exception) {
            Log.w(TAG, "设置缩放失败", error)
        }
    }

    // ─────────────────────────────────────────────
    // 相机
    // ─────────────────────────────────────────────

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
     * 静止检测用的尺寸。
     *
     * 挑相机**支持**的最小一档：分析用不上大图，越小越省。
     * 找不到任何支持尺寸时退回 320x240 并寄希望于它可用 ——
     * 那种情况下会话可能建不起来，但那属于相机本身异常。
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

    private fun openCamera(
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

        // 静止检测用一路单独的输出，不影响录制。
        //
        // ⚠️ 尺寸**必须从相机支持的列表里挑**：ImageReader 作为会话的一个目标时，
        // 尺寸不在 `getOutputSizes` 里会让整个 `createCaptureSession` 失败 ——
        // 连录制都起不来。硬编码一个 160x120 是很容易踩的坑。
        val analysisSize = pickAnalysisSize(characteristics)
        val reader = ImageReader.newInstance(
            analysisSize.width, analysisSize.height, ImageFormat.YUV_420_888, 2,
        )
        reader.setOnImageAvailableListener({ onAnalysisFrame(it) }, cameraHandler)
        analysisReader = reader

        @Suppress("MissingPermission")
        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                cameraDevice = device
                createSession(device, reader)
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

    private fun createSession(device: CameraDevice, reader: ImageReader) {
        val surface = inputSurface ?: return

        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        applyTargets(builder, reader)
        applyZoom(builder)

        device.createCaptureSession(
            listOf(surface, reader.surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    if (!running) return
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

    private fun applyTargets(
        builder: CaptureRequest.Builder,
        reader: ImageReader? = analysisReader,
    ) {
        inputSurface?.let { builder.addTarget(it) }
        reader?.let { builder.addTarget(it.surface) }
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

    /**
     * 循环取编码器输出。
     *
     * 没有这个循环，编码器的输出缓冲区会一直积压，录制几秒后就卡死。
     * 这是写这段时最容易漏的一环 —— 漏了不会编译报错，只会「录一小段就停」。
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

    // ─────────────────────────────────────────────
    // 静止检测
    // ─────────────────────────────────────────────

    /**
     * 规格 §3.3.3：画面**连续无显著变化**即判定为静止。
     *
     * 实现是相邻两帧亮度平面的平均绝对差。够用且极省电 ——
     * 真正的静止判定不该吃掉录制的算力。
     */
    private fun onAnalysisFrame(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        try {
            val now = SystemClock.elapsedRealtime()
            if (now - lastAnalysisAtMs < ANALYSIS_INTERVAL_MS) return
            lastAnalysisAtMs = now

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
        } catch (error: Exception) {
            Log.w(TAG, "静止检测失败", error)
        } finally {
            image.close()
        }
    }

    // ─────────────────────────────────────────────
    // 编码与分段轮转
    // ─────────────────────────────────────────────

    /** 编码器输出到达。由 [createSession] 之后注册的循环驱动。 */
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
                    if (encoderFormat == null) {
                        encoderFormat = codec.outputFormat
                        openNewSegment()
                    }
                }

                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)
                    val isKeyFrame =
                        (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                    if (buffer != null && info.size > 0) {
                        // 先判轮转再写 —— 关键帧正好是新分段的开头。
                        maybeRotate(isKeyFrame)

                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)

                        muxer?.let { muxer ->
                            if (trackIndex >= 0) {
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
     * 到点且当前是关键帧时轮转分段。
     *
     * **编码器不重启**，只换封装器 —— 这是「用户感知为一直在录」的落点。
     */
    private fun maybeRotate(isKeyFrame: Boolean) {
        if (!isKeyFrame) return
        if (!running) return
        if (SystemClock.elapsedRealtime() - segmentStartedAtMs < segmentDurationMs) return

        closeCurrentSegment()
        openNewSegment()
    }

    private fun openNewSegment() {
        val format = encoderFormat ?: return

        segmentSequence++
        segmentStartedAtMs = SystemClock.elapsedRealtime()

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

    private fun release() {
        running = false
        closeCurrentSegment()

        try {
            encoder?.release()
        } catch (error: Exception) {
            Log.w(TAG, "释放编码器失败", error)
        }

        encoder = null
        inputSurface?.release()
        inputSurface = null
        analysisReader?.close()
        analysisReader = null
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }
}
