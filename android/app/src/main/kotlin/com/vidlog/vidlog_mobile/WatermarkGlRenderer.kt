package com.vidlog.vidlog_mobile

import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * 把相机画面 + 水印合成后送进编码器（规格 §3.6.2）。
 *
 * ## 为什么必须有一条 GL 通路
 *
 * 原来相机是**直接**写进编码器的输入 Surface 的（`MediaCodec.createInputSurface()`），
 * 那样**没有任何地方能改像素**。要叠字就得在中间插一层 GL：
 *
 * ```
 * 相机 → SurfaceTexture（外部纹理）→ GL（画画面 + 贴水印）→ 编码器输入 Surface
 * ```
 *
 * ⚠️ 这是安卓这一端**唯一**能做到「烧进视频」的路 —— 手机上没有 ffmpeg，
 * 导出时再叠是做不到的；而录下来的就是最终成品（原生直接写 MP4）。
 *
 * ## ⚠️ 这段代码没有在真机上跑过
 *
 * 开发机是 Windows、不跑模拟器，所以只过了 CI 的编译。**相机 + GL + 编码器
 * 三方协作出问题时，症状通常是一块黑屏或一帧不出**（与预览那条路同一个坑）。
 * 真机验收见 `docs/真机验收清单.md` §1.26。
 *
 * ⚠️ **失败必须降级到「无水印」而不是「录不了」**：建不起来时调用方会退回
 * 原来的直连通路（见 `CameraSegmentRecorder.openDevice`）。没有水印是遗憾，
 * 录不出来是事故（I2 的同一条精神）。
 *
 * ## 水印为什么要**反向转一次**（规格 §3.6.2 + §3.1.7 ②）
 *
 * 规格原话：「成片（无论横竖）里，水印**始终在视觉上的顶部中间**，且**文字正向
 * 可读** —— 横屏时**不得**跑到侧边，也**不得**跟着旋转 90°。这意味着**水印的
 * 绘制坐标要按方向做一次变换**。」
 *
 * 为什么这里非做不可：**成片的像素永远是传感器方向（横向）的**，
 * 竖屏那件事只是 `MediaMuxer.setOrientationHint` 写了一个标记
 * （`CameraSegmentRecorder.spec.size` 的注释：「相机这边的输出尺寸始终是
 * 传感器方向的那一个」）。播放器读到那个标记，把**整帧**转正 ——
 * 而水印是**烧进像素**的，会跟着一起转。
 *
 * 结果就是（不修的话）：竖屏时水印落在**显示画面的左边**，而且**文字躺倒 90°** ——
 * 正对着 §3.6.2 那两句「不得跑到侧边」「不得跟着旋转 90°」。
 *
 * 做法：照规格说的「按方向做一次变换」—— 先在传感器坐标系里按**顶部居中**摆好
 * （`uploadBitmap` 里那四个点），再**绕画面中心反向转 `displayRotation` 度**。
 * 播放器顺时针转多少，这里就先逆时针转多少，转完正好落回视觉上的顶部中间、
 * 文字也正。
 *
 * ### 一张对照（竖屏、`displayRotation = 90`）
 *
 * | | 传感器坐标系 | 播放器转 90° 之后 |
 * |---|---|---|
 * | 顶部中间 | 左边中点 | **顶部中间** ✅ |
 * | 文字正向 | 逆时针躺 90° | **正向** ✅ |
 *
 * ⚠️ **方向没在真机上验过**（开发机是 Windows、不跑模拟器）。真机上若发现水印
 * 落在**别的边**上，要动的是 [rotatedAboutCenter] 那个角度的**正负号**
 * —— 与 `CameraSegmentRecorder.spec.orientationHint` 里那句
 * 「两个方向反了就调换 `-90` 与 `+90`」同一个性质：**只改这一处，别去动别的地方**。
 *
 * ## ⚠️ iOS **不做**这一转，两边形状本来就不同
 *
 * iOS 的旋转加在 `AVCaptureConnection` 上（`videoRotationAngle`），交付出来的像素
 * **本身就是正的**，也没有 writer 的 `transform` —— 所以那边画在顶部居中即正确。
 * 这不是谁漏了一段：两个平台交付像素的方式不同。细节见
 * `CameraSegmentRecorder.swift` 里 `originX` 那一段的说明。
 */
class WatermarkGlRenderer(
    private val outputSurface: Surface,
    private val videoWidth: Int,
    private val videoHeight: Int,
    /**
     * 成片要**顺时针**转多少度才是正的（= `setOrientationHint` 那个值）。
     *
     * ⚠️ 水印必须知道这个数 —— 见类文档「水印为什么要反向转一次」。
     */
    private val displayRotation: Int,
    private val onFrame: (SurfaceTexture) -> Unit,
) {
    companion object {
        private const val TAG = "VidLogWatermark"

        // 画面：外部纹理（相机）+ 一个把纹理坐标翻正的矩阵。
        private const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * aTexCoord).xy;
            }
        """

        private const val OES_FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES uTexture;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
        """

        private const val BITMAP_FRAGMENT_SHADER = """
            precision mediump float;
            varying vec2 vTexCoord;
            uniform sampler2D uTexture;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
        """

        private const val FLOAT_SIZE = 4
    }

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var oesProgram = 0
    private var bitmapProgram = 0

    private var oesTexture = 0
    private var watermarkTexture = 0

    private var surfaceTexture: SurfaceTexture? = null

    /** 完整画面（两个三角形）的顶点。 */
    private val fullQuad: FloatBuffer = ByteBuffer
        .allocateDirect(4 * 4 * FLOAT_SIZE)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
            position(0)
        }

    private val fullTexCoord: FloatBuffer = ByteBuffer
        .allocateDirect(4 * 4 * FLOAT_SIZE)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))
            position(0)
        }

    private var watermarkQuad: FloatBuffer? = null
    private var watermarkTexCoord: FloatBuffer? = null

    /** 已经贴上去的那一秒（缓存键）。 */
    private var uploadedSecond: Long = Long.MIN_VALUE
    private var uploadedWaybill: String = ""
    private var watermarkAspect = 1f

    /** 建好 EGL 与着色器。**失败时抛**，由调用方决定降级。 */
    fun setup() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)

        if (display == EGL14.EGL_NO_DISPLAY) {
            throw IllegalStateException("拿不到 EGL display")
        }

        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
            throw IllegalStateException("eglInitialize 失败")
        }

        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_NONE,
        )

        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)

        if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) ||
            count[0] == 0
        ) {
            throw IllegalStateException("挑不到 EGL 配置")
        }

        context = EGL14.eglCreateContext(
            display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )

        if (context == EGL14.EGL_NO_CONTEXT) {
            throw IllegalStateException("建不出 EGL context")
        }

        // ⚠️ 目标就是**编码器的输入 Surface** —— 画面与文字合成完直接喂给它。
        eglSurface = EGL14.eglCreateWindowSurface(
            display, configs[0], outputSurface, intArrayOf(EGL14.EGL_NONE), 0,
        )

        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            throw IllegalStateException("包不住编码器的输入 Surface")
        }

        if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
            throw IllegalStateException("eglMakeCurrent 失败")
        }

        oesProgram = buildProgram(VERTEX_SHADER, OES_FRAGMENT_SHADER)
        bitmapProgram = buildProgram(VERTEX_SHADER, BITMAP_FRAGMENT_SHADER)

        oesTexture = createExternalTexture()
        watermarkTexture = createBitmapTexture()

        surfaceTexture = SurfaceTexture(oesTexture).apply {
            setDefaultBufferSize(videoWidth, videoHeight)
            setOnFrameAvailableListener(
                { texture -> onFrame(texture) },
                android.os.Handler(android.os.Looper.getMainLooper()),
            )
        }

        GLES20.glViewport(0, 0, videoWidth, videoHeight)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
    }

    /** 相机该往哪个 Surface 写 —— GL 那条路的入口。 */
    fun inputSurface(): Surface = Surface(surfaceTexture)

    /**
     * 画一帧。
     *
     * [epochMs] 与 [waybill] 是水印那两行要用到的；[epochMs] 由调用方从
     * **可信时钟**推出来（规范 §3.6.3：不得取自墙钟）。
     */
    fun drawFrame(epochMs: Long, waybill: String) {
        val texture = surfaceTexture ?: return

        texture.updateTexImage()

        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        drawCamera(texture)
        drawWatermark(epochMs, waybill)

        EGL14.eglSwapBuffers(display, eglSurface)
    }

    private fun drawCamera(texture: SurfaceTexture) {
        val matrix = FloatArray(16)
        texture.getTransformMatrix(matrix)

        GLES20.glUseProgram(oesProgram)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(oesProgram, "uTexture"), 0)
        GLES20.glUniformMatrix4fv(
            GLES20.glGetUniformLocation(oesProgram, "uTexMatrix"), 1, false, matrix, 0)

        bindAttribute(oesProgram, "aPosition", fullQuad, 2)
        bindAttribute(oesProgram, "aTexCoord", fullTexCoord, 2)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun drawWatermark(epochMs: Long, waybill: String) {
        val second = epochMs / 1000

        if (uploadedSecond != second || uploadedWaybill != waybill) {
            val bitmap = WatermarkOverlay.render(
                epochMs, waybill, videoWidth, videoHeight) ?: return

            uploadBitmap(bitmap)
            bitmap.recycle()

            uploadedSecond = second
            uploadedWaybill = waybill
        }

        val quad = watermarkQuad ?: return
        val texCoord = watermarkTexCoord ?: return

        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)

        GLES20.glUseProgram(bitmapProgram)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTexture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(bitmapProgram, "uTexture"), 0)
        GLES20.glUniformMatrix4fv(
            GLES20.glGetUniformLocation(bitmapProgram, "uTexMatrix"),
            1, false, identityMatrix(), 0)

        bindAttribute(bitmapProgram, "aPosition", quad, 2)
        bindAttribute(bitmapProgram, "aTexCoord", texCoord, 2)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisable(GLES20.GL_BLEND)
    }

    /**
     * 水印贴在**顶部居中**，按图片自身的宽高比换算成 NDC 的矩形。
     *
     * ⚠️ NDC 是 -1..1，而且 y 轴朝**上** —— 顶部是 y≈1 那一侧。
     */
    private fun uploadBitmap(bitmap: Bitmap) {
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTexture)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)

        val width = 2f * bitmap.width / videoWidth
        val height = 2f * bitmap.height / videoHeight

        // 上边距取画面高度的 2%（与文字那一层的口径一致）。
        val top = 1f - 2f * 0.02f

        watermarkAspect = bitmap.width.toFloat() / bitmap.height

        // ① 先在**传感器坐标系**里按「顶部居中」摆好。
        val base = floatArrayOf(
            -width / 2f, top - height,
            width / 2f, top - height,
            -width / 2f, top,
            width / 2f, top,
        )

        // ② 再绕画面中心**反向**转回去 —— 播放器会按 `setOrientationHint`
        // 顺时针转整帧，水印得先把那一转抵消掉，转完才落在视觉上的顶部中间。
        // 完整的理由与没验过的部分见类文档「水印为什么要反向转一次」。
        watermarkQuad = rotatedAboutCenter(base, displayRotation)

        // 纹理坐标要**上下翻**：Bitmap 的第一行是图像顶部，而 GL 的 v=0 在底部。
        watermarkTexCoord = floatBufferOf(
            0f, 1f,
            1f, 1f,
            0f, 0f,
            1f, 0f,
        )
    }

    fun release() {
        surfaceTexture?.setOnFrameAvailableListener(null)
        surfaceTexture?.release()
        surfaceTexture = null

        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(
                display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)

            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)

            EGL14.eglTerminate(display)
        }

        eglSurface = EGL14.EGL_NO_SURFACE
        context = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
    }

    // ── 小工具 ─────────────────────────────────────

    private fun bindAttribute(program: Int, name: String, buffer: FloatBuffer, size: Int) {
        val location = GLES20.glGetAttribLocation(program, name)
        if (location < 0) return

        buffer.position(0)
        GLES20.glEnableVertexAttribArray(location)
        GLES20.glVertexAttribPointer(location, size, GLES20.GL_FLOAT, false, 0, buffer)
    }

    private fun identityMatrix(): FloatArray = FloatArray(16).also {
        android.opengl.Matrix.setIdentityM(it, 0)
    }

    /**
     * 把一组 NDC 顶点（两两一组）**绕画面中心逆时针**转 [degrees] 度。
     *
     * ⚠️ NDC 是 -1..1、**y 轴朝上**，而屏幕坐标 y 朝下 —— 所以「屏幕上顺时针转 θ」
     * 换算到 NDC 里就是**逆时针 θ**，这里因此直接按逆时针公式算，
     * 传入的仍然是那个「顺时针」的 `displayRotation`。
     *
     * ⚠️ **正负号没在真机上验过**。真机上若水印落在别的边上，改的就是这里
     * （把 `displayRotation` 取负，或者调换 sin 的两处符号），别去动摆放那一段。
     */
    private fun rotatedAboutCenter(corners: FloatArray, degrees: Int): FloatBuffer {
        val radians = Math.toRadians(degrees.toDouble())
        val cos = kotlin.math.cos(radians).toFloat()
        val sin = kotlin.math.sin(radians).toFloat()

        val out = FloatArray(corners.size)
        for (i in corners.indices step 2) {
            val x = corners[i]
            val y = corners[i + 1]
            out[i] = x * cos - y * sin
            out[i + 1] = x * sin + y * cos
        }

        return floatBufferOf(*out)
    }

    private fun floatBufferOf(vararg values: Float): FloatBuffer = ByteBuffer
        .allocateDirect(values.size * FLOAT_SIZE)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(values)
            position(0)
        }

    private fun createExternalTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)

        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        return textures[0]
    }

    private fun createBitmapTexture(): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        return textures[0]
    }

    private fun buildProgram(vertexSource: String, fragmentSource: String): Int {
        val vertex = compile(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragment = compile(GLES20.GL_FRAGMENT_SHADER, fragmentSource)

        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertex)
        GLES20.glAttachShader(program, fragment)
        GLES20.glLinkProgram(program)

        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)

        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("着色器链接失败：$log")
        }

        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)

        return program
    }

    private fun compile(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)

        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)

        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("着色器编译失败：$log")
        }

        return shader
    }

    /** 出问题时把 GL 的话原样留下来（诊断用）。 */
    fun describe(): String = "GL 水印通路（${videoWidth}x$videoHeight）"
}

/** 记一条 GL 相关的日志（失败不抛）。 */
internal fun logGlFailure(message: String, error: Throwable? = null) {
    Log.w("VidLogWatermark", message, error)
}
