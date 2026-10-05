package com.vidlog.vidlog_mobile

import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.util.Log
import android.util.Size
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 实时推流那一路的编码器（规格 §3.8，需求方 2026-10-01 定的方案）。
 *
 * 相机会话里多挂一路 `ImageReader`（YUV），在这一路自己的线程上转成 NV12
 * 喂给第二个 `MediaCodec`，编出 H.264 裸流（Annex-B），交给 Dart 那边的
 * `LiveServer` 出去。电脑端拉的就是这一路。
 *
 * ## ⚠️ 三条隔离规则（规格 §3.8 的硬约束，缺一不可）
 *
 * 1. **不许阻塞** —— 相机的 `onImageAvailable` 只做一件事：往这一路自己的
 *    单线程池上丢一个任务。图像转换与编码全在**那个线程**上，绝不占用
 *    相机与渲染那条线程。上一帧还没处理完时**直接丢新帧**（[busy] 那道闸），
 *    编不进去也**不等**（`dequeueInputBuffer(0)`）。
 * 2. **不许传染** —— 这一路的任何异常都只走 [onFailure]（一条日志）。
 *    它自己的 `MediaCodec` 与录制那个完全无关；[close] 只收自己这一套。
 * 3. **该让就让** —— 由 Dart 那边的 `LiveService.notifyRecordingPressure`
 *    落实（录制报压力 ⇒ 调 `CameraSegmentRecorder.stopLive`）。
 *
 * ## ⚠️ 为什么不是「在 GL 里多渲一个 surface」（更省 CPU 的那条路）
 *
 * 那条路要把推流那个编码器的输入 surface 也塞进 [WatermarkGlRenderer] 的
 * EGL 上下文，两个 surface 在**同一条渲染线程**上 `eglSwapBuffers` ——
 * 而编码器输入缓冲满的时候，`eglSwapBuffers` **会阻塞**。
 * 那等于把推流的背压接到录制上：录制掉帧是**证据缺失**，推流掉帧只是顿一下。
 * 所以宁可多花一份 CPU 转码，把两条路彻底分开。
 *
 * ## ⚠️ 档位这条路是有限的
 *
 * 这一路的目标尺寸是**开会话那一刻钉死的**（相机的 target 尺寸要重建会话才能改，
 * 而重建会话会打断正在录的那一段）。所以：
 *
 * - 挂上去时按**格子那一档（480P）**挑尺寸；
 * - 电脑端要 720P / 1080P 时[setLines] **如实拒绝**，由 Dart 那边回 4xx
 *   —— 绝不假装换了（那样电脑端会按新尺寸重开解码，而画面还是老的）。
 *
 * ⚠️ **本机跑不了真机**：这一套只有 `flutter build apk` 编译过一次，
 * 相机 target 上限、YUV 布局、编码时序都要真机验（见 `真机验收清单.md`）。
 */
class LiveStreamer private constructor(
    /** 这一路自己的输出。**挂到相机会话上**（见 `CameraSegmentRecorder`）。 */
    val imageReader: ImageReader,
    private val frameRate: Int,
) {
    companion object {
        private const val TAG = "VidLogLive"

        /** 挂上去时用的那一档（规格 §3.8：格子里就是 480P）。 */
        const val TILE_LINES = 480

        /** 三档各自多少行 —— 与 Dart 的 `LiveQuality` 同一套数字。 */
        private fun bitRateFor(lines: Int): Int = when (lines) {
            1080 -> 4_500_000
            720 -> 2_500_000
            else -> 1_200_000
        }

        /**
         * 建一路推流。**建不起来就返回 null**（调用方继续开相机、照常录制）。
         *
         * @param lines 目标短边行数（今天只支持 [TILE_LINES]，见类注释）。
         */
        fun create(characteristics: CameraCharacteristics, lines: Int = TILE_LINES): LiveStreamer? {
            val size = pickTargetSize(characteristics, lines) ?: run {
                Log.w(TAG, "相机报不出可用的 YUV 尺寸，实时共享不可用")
                return null
            }

            return try {
                // ⚠️ `maxImages = 2`：一路是正在处理的、一路是相机正在写的。
                // 再大只是缓冲更多帧 —— 而实时画面宁可丢帧也不要延迟。
                val reader = ImageReader.newInstance(
                    size.width, size.height, ImageFormat.YUV_420_888, 2,
                )

                LiveStreamer(reader, frameRate = 15)
            } catch (error: Throwable) {
                Log.w(TAG, "推流用的 ImageReader 建不起来", error)
                null
            }
        }

        /**
         * 挑一路**相机支持**的目标尺寸。
         *
         * ⚠️ 尺寸必须来自 `getOutputSizes` —— 随便给一个会让整个
         * `createCaptureSession` 失败，**连录制都起不来**（与识码那一路
         * 同一个坑，见 `pickAnalysisSize`）。
         *
         * 规则：短边**不小于**目标里最小的那个（宁可大一点也不要糊），
         * 都不到就取最大的（设备就这么大）。
         */
        private fun pickTargetSize(
            characteristics: CameraCharacteristics,
            lines: Int,
        ): Size? {
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?: return null

            val sizes = map.getOutputSizes(ImageFormat.YUV_420_888) ?: return null

            val shortSide = { size: Size -> minOf(size.width, size.height) }

            return sizes.filter { shortSide(it) >= lines }.minByOrNull { shortSide(it) }
                ?: sizes.maxByOrNull { it.width.toLong() * it.height }
        }
    }

    /** 编好的一块往哪儿送。`isKey` 为真时**已经前置了 SPS/PPS**。 */
    private var onFrame: ((ByteArray, Boolean) -> Unit)? = null

    /** 出事了（编码器建不起来、编码报错）。**只用来记一条日志**。 */
    private var onFailure: ((String) -> Unit)? = null

    /**
     * 这一路自己的单线程池。
     *
     * ⚠️ **单线程是刻意的**：转换与编码在这一条线上排队，而相机的回调
     * 只负责往这里丢任务、绝不等待它。
     */
    private var worker: ExecutorService? = null

    /** 上一帧还在处理 —— 新帧直接丢（第 1 条规则）。 */
    private val busy = AtomicBoolean(false)

    private var codec: MediaCodec? = null

    /** 编出来的尺寸（= 相机会话上钉死的那个尺寸）。 */
    private var width = 0
    private var height = 0

    /** NV12 那一块复用，不每帧新分配（30fps 下那是白给 GC 找活干）。 */
    private var nv12: ByteArray = ByteArray(0)

    /** 参数集（`csd-0` / `csd-1`），关键帧前要前置。 */
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null

    private var closed = false

    /** 现在能不能往外送（接上 [attach] 之后才行）。 */
    val isAttached: Boolean get() = onFrame != null

    /** 这一路编出来的尺寸（给日志与诊断用）。 */
    val encodedSize: Size get() = Size(width, height)

    /**
     * 这一路**实际选中**的编码器名（诊断用）。
     *
     * ⚠️ 名字里带 `c2.android.` 的就是**软编**（AOSP 那个，跑在 CPU 上）——
     * 而「一开录就卡、不录就顺」这个形态的判别点只有它（T16 取证）。
     * 同一个型号上选到哪个是**设备说了算**的，代码里看不出来，只能从日志看。
     */
    val codecName: String? get() = codec?.name

    /**
     * 开始往外送（用户打开了实时共享）。
     *
     * ⚠️ **不碰相机会话**：`ImageReader` 早在开会话时就挂上去了，
     * 这里只是把回调接上、把编码器起起来。所以起停推流不会打断录制。
     */
    fun attach(
        onFrame: (ByteArray, Boolean) -> Unit,
        onFailure: (String) -> Unit,
        handler: Handler,
    ): Boolean {
        if (closed) return false

        if (isAttached) {
            // 已经开着：只换回调（重连、报错出口变了）。
            this.onFrame = onFrame
            this.onFailure = onFailure
            return true
        }

        val reader = imageReader

        if (!startCodec(reader.width, reader.height)) return false

        this.onFrame = onFrame
        this.onFailure = onFailure

        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "vidlog-live-encode")
        }
        worker = executor

        // ⚠️ 相机的回调在**相机那条线程**上 —— 这里只丢一个任务，绝不干活。
        reader.setOnImageAvailableListener({ source ->
            // 上一帧还没弄完就丢掉这一帧（第 1 条规则）。
            if (!busy.compareAndSet(false, true)) return@setOnImageAvailableListener

            val pool = worker
            if (pool == null) {
                busy.set(false)
                return@setOnImageAvailableListener
            }

            try {
                pool.execute {
                    try {
                        drainLatest(source)
                    } finally {
                        busy.set(false)
                    }
                }
            } catch (error: Throwable) {
                // 池子已经关了（正在停）—— 这一帧不要了。
                busy.set(false)
            }
        }, handler)

        return true
    }

    /** 停止往外送。**`ImageReader` 仍留在会话上**（摘掉它要重建会话）。 */
    fun detach() {
        imageReader.setOnImageAvailableListener(null, null)

        onFrame = null
        onFailure = null

        worker?.shutdown()
        worker = null

        stopCodec()
    }

    /**
     * 换档。**只有格子那一档能换成功**（见类注释），别的如实拒绝。
     */
    fun setLines(lines: Int): String? {
        if (lines == TILE_LINES) return null

        return "安卓端的推流尺寸是开会话时定死的，只能推 ${TILE_LINES}P"
    }

    /** 关掉这一路。幂等。**相机拆掉时调**。 */
    fun close() {
        if (closed) return
        closed = true

        detach()

        try {
            imageReader.close()
        } catch (error: Throwable) {
            Log.w(TAG, "关推流用的 ImageReader 失败", error)
        }
    }

    // ── 编码 ────────────────────────────────────────────────

    private fun startCodec(targetWidth: Int, targetHeight: Int): Boolean {
        val codec = try {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        } catch (error: Throwable) {
            onFailure?.invoke("推流编码器建不起来：${error.message}")
            return false
        }

        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC, targetWidth, targetHeight,
        )
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRateFor(TILE_LINES))
        format.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
        // ⚠️ 这个值直接决定「电脑端中途接入要等多久才有画面」：
        // 裸流没有容器，客户端必须从关键帧开始才解得出来。2 秒一个。
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)

        return try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()

            this.codec = codec
            width = targetWidth
            height = targetHeight
            nv12 = ByteArray(targetWidth * targetHeight * 3 / 2)

            true
        } catch (error: Throwable) {
            // ⚠️ 只报一条：这一路起不来**不影响录制**（第 2 条规则）。
            Log.w(TAG, "推流编码器配置失败", error)
            onFailure?.invoke("推流编码器配置失败：${error.message}")

            try {
                codec.release()
            } catch (ignored: Throwable) {
                // 释放失败也没什么可做的。
            }

            false
        }
    }

    private fun stopCodec() {
        val codec = this.codec ?: return
        this.codec = null

        try {
            codec.stop()
        } catch (error: Throwable) {
            Log.w(TAG, "停推流编码器失败", error)
        }

        try {
            codec.release()
        } catch (error: Throwable) {
            Log.w(TAG, "释放推流编码器失败", error)
        }

        sps = null
        pps = null
    }

    /**
     * 取**最新那一帧**处理。
     *
     * ⚠️ `acquireLatestImage` 而不是 `acquireNextImage`：积压的旧帧没有价值
     * —— 实时画面要的是「现在」。取到最新那帧时，比它旧的那些会被自动关掉。
     */
    private fun drainLatest(reader: ImageReader) {
        val image = try {
            reader.acquireLatestImage()
        } catch (error: Throwable) {
            Log.w(TAG, "取推流用的相机帧失败", error)
            return
        } ?: return

        try {
            encode(image)
        } catch (error: Throwable) {
            // 单帧出错不该把整条路停掉（下一帧还会来）。
            Log.w(TAG, "推流这一帧编不动", error)
        } finally {
            try {
                image.close()
            } catch (error: Throwable) {
                Log.w(TAG, "关掉推流那帧失败", error)
            }
        }
    }

    private fun encode(image: Image) {
        val codec = this.codec ?: return
        if (width <= 0 || height <= 0) return

        toNv12(image)

        // ⚠️ **0 超时**：没有输入缓冲就丢这一帧，绝不等待（第 1 条规则）。
        val index = try {
            codec.dequeueInputBuffer(0)
        } catch (error: Throwable) {
            return
        }

        if (index < 0) return

        val buffer = codec.getInputBuffer(index) ?: return
        buffer.clear()
        buffer.put(nv12, 0, nv12.size)

        try {
            codec.queueInputBuffer(index, 0, nv12.size, image.timestamp / 1_000, 0)
        } catch (error: Throwable) {
            Log.w(TAG, "推流这一帧排不进编码器", error)
            return
        }

        drainOutput(codec)
    }

    /** 把编好的块取出来、转成 Annex-B 交出去。 */
    private fun drainOutput(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()

        while (true) {
            val index = try {
                codec.dequeueOutputBuffer(info, 0)
            } catch (error: Throwable) {
                return
            }

            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return

            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                captureParameterSets(codec.outputFormat)
                continue
            }

            if (index < 0) continue

            try {
                if (info.size > 0) {
                    val buffer = codec.getOutputBuffer(index)
                    if (buffer != null) {
                        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        val annexB = toAnnexB(buffer, info, isKey)
                        if (annexB.isNotEmpty()) onFrame?.invoke(annexB, isKey)
                    }
                }
            } finally {
                try {
                    codec.releaseOutputBuffer(index, false)
                } catch (error: Throwable) {
                    Log.w(TAG, "归还推流输出缓冲失败", error)
                }
            }
        }
    }

    /** 记下 SPS / PPS（编码器在格式变化时把它们放在 `csd-0` / `csd-1` 里）。 */
    private fun captureParameterSets(format: MediaFormat) {
        try {
            format.getByteBuffer("csd-0")?.let { sps = it.toByteArray() }
            format.getByteBuffer("csd-1")?.let { pps = it.toByteArray() }
        } catch (error: Throwable) {
            Log.w(TAG, "读推流参数集失败", error)
        }
    }

    /**
     * 把一块编码成品转成 Annex-B。
     *
     * ⚠️ 为什么非要转：`MediaCodec` 出来的每一块前面是**长度前缀**，
     * 而裸流要的是 `00 00 00 01` 起始码。不转的话电脑端那边 ffmpeg 收进去
     * 是一堆解不开的字节 —— 表现是「连上了、一直在收、一个画面都没有」。
     *
     * ⚠️ 关键帧**必须前置 SPS/PPS**：裸流没有容器，
     * 中途接入的客户端只能靠关键帧那一块里带的参数集建解码器。
     */
    private fun toAnnexB(buffer: ByteBuffer, info: MediaCodec.BufferInfo, isKey: Boolean): ByteArray {
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)

        val out = ByteArrayOutputStream(info.size + 64)

        if (isKey) {
            sps?.let { out.write(it); }
            pps?.let { out.write(it); }
        }

        val lengths = buffer.order(ByteOrder.BIG_ENDIAN)

        while (lengths.remaining() >= 4) {
            val size = lengths.getInt()

            if (size <= 0 || size > lengths.remaining()) break

            out.write(byteArrayOf(0, 0, 0, 1))
            out.write(lengths.array(), lengths.arrayOffset() + lengths.position(), size)
            lengths.position(lengths.position() + size)
        }

        return out.toByteArray()
    }

    // ── YUV_420_888 → NV12 ──────────────────────────────────

    /**
     * 把相机给的 YUV 转成**紧密排列**的 NV12。
     *
     * ⚠️ 必须自己转，不能直接把 plane 的字节丢给编码器：
     * `ImageReader` 给的每一行后面可能有**行距填充**（`rowStride > width`），
     * 而且 U / V 两个 plane 的 `pixelStride` 各设备不同（1 或 2）。
     * 直接丢过去的话，画面会「斜着花掉」或者颜色整个错位 —— 而编码器
     * 不会报任何错，它只是照着字节编。
     */
    private fun toNv12(image: Image) {
        val target = nv12
        val planes = image.planes

        val yPlane = planes[0]
        val uPlane = planes[1]
        val vPlane = planes[2]

        val yBuffer = yPlane.buffer
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer

        var offset = 0

        // ── Y ──
        val yRowStride = yPlane.rowStride
        val yPixelStride = yPlane.pixelStride

        for (row in 0 until height) {
            val rowStart = row * yRowStride

            for (column in 0 until width) {
                target[offset++] = yBuffer.get(rowStart + column * yPixelStride)
            }
        }

        // ── UV（交错成 NV12）──
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride

        val halfWidth = width / 2
        val halfHeight = height / 2

        for (row in 0 until halfHeight) {
            val rowStart = row * uvRowStride

            for (column in 0 until halfWidth) {
                val at = rowStart + column * uvPixelStride
                target[offset++] = uBuffer.get(at)
                target[offset++] = vBuffer.get(at)
            }
        }
    }

    private fun ByteBuffer.toByteArray(): ByteArray {
        val copy = duplicate()
        val bytes = ByteArray(copy.remaining())
        copy.get(bytes)
        return bytes
    }
}
