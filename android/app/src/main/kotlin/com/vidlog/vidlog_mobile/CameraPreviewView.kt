package com.vidlog.vidlog_mobile

import android.content.Context
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.view.TextureView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.max

/**
 * 相机预览视图（Android 侧）。
 *
 * 规格 §3.2.2 要求点「开始工作」后**画面出现可见的取景框** ——
 * 没有预览就没有取景框可言，用户也没法把面单对准框。
 *
 * ## 为什么是 `TextureView` 而不是 `SurfaceView`
 *
 * 这个视图要活在 Flutter 的视图树里（混合合成）。`SurfaceView` 走的是
 * 一块独立的窗口层，跟 Flutter 的合成顺序对不上；`TextureView` 是普通 View、
 * 由系统转成纹理画出来，能跟 Dart 侧画在它**上面**的取景框正确叠在一起。
 *
 * ## 为什么共用同一个相机会话
 *
 * 预览 Surface 是**加到录制那个会话上**的第三路输出（见
 * `CameraSegmentRecorder.sessionTargets`），不是另开一个会话。
 * 分成两个会互相抢相机；而且更根本的是 —— **用户看到的画面必须就是
 * 录下来的画面**，否则取景框画的框和实际裁剪的范围会对不上，取证就成了笑话。
 *
 * ## ⚠️ 旋转 + 撑满（`applyTransform`）
 *
 * 相机给的是**传感器方向**的画面（竖着拿手机时它是横的 1920x1080），
 * 而预览框是竖的。要显示的正好是「转 90° 再撑满」，缺了它画面是躺着的 ——
 * 用户对着一个转了 90°、还被拉伸变形的画面根本没法对准面单。
 *
 * ⚠️ **这段矩阵本机验不了**（没有真机）。真机上如果画面是**躺着的**或者
 * **被拉伸变形**，问题一定在这一段 —— 不在相机那边。
 */
class CameraPreviewView(
    context: Context,
    private val channel: RecorderChannel,
) : PlatformView {

    private val textureView = TextureView(context)

    init {
        textureView.setBackgroundColor(android.graphics.Color.BLACK)

        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(
                texture: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                channel.setPreviewTexture(texture)
                applyTransform()
            }

            override fun onSurfaceTextureSizeChanged(
                texture: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                applyTransform()
            }

            override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                // 先把 Surface 收回来再让它释放 —— 反过来的话相机那边
                // 会拿着一块已经没了的 Surface 继续送帧。
                channel.setPreviewTexture(null)
                return true
            }

            override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
        }

        // 视图尺寸变了要重算（撑满的比例是按视图大小定的）。
        textureView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> applyTransform() }
    }

    override fun getView(): View = textureView

    override fun dispose() {
        channel.setPreviewTexture(null)
        channel.onPreviewGeometryChanged = null
        textureView.surfaceTextureListener = null
    }

    /**
     * 让画面**转正并撑满**这个视图。
     *
     * 基线：`TextureView` 默认把缓冲整个**拉伸**到视图大小。所以变换要
     * 先把那层拉伸抵掉（把画面还原成它真实的长宽比），再旋转，再撑满。
     *
     * ⚠️ 中间一旦空了一段（比如 [TextureView.setTransform] 的语义理解错了），
     * 表现就是画面**比例不对**：人看得出脸被拉长。真机上先看这一点。
     */
    private fun applyTransform() {
        // 回调要**先**挂上：预览视图可能比相机先建出来，那时拿不到几何参数；
        // 相机开好之后靠这个回调再算一次，否则预览会一直是没转过的样子。
        channel.onPreviewGeometryChanged = { textureView.post { applyTransform() } }

        val recorder = channel.currentRecorder ?: return

        val viewWidth = textureView.width.toFloat()
        val viewHeight = textureView.height.toFloat()
        if (viewWidth <= 0f || viewHeight <= 0f) return

        val bufferWidth = recorder.currentVideoSize.width.toFloat()
        val bufferHeight = recorder.currentVideoSize.height.toFloat()
        if (bufferWidth <= 0f || bufferHeight <= 0f) return

        val rotation = recorder.currentSensorOrientation
        val swapped = rotation == 90 || rotation == 270

        // 转过之后画面占的外框尺寸 —— 撑满的比例要按它算。
        val shownWidth = if (swapped) bufferHeight else bufferWidth
        val shownHeight = if (swapped) bufferWidth else bufferHeight

        // 取大的那个比例 = 撑满（允许裁掉溢出部分），与 iOS 的 `.resizeAspectFill` 一致。
        // 取小的那个就变成「装进去」，两边会留黑边，而取景框是按画面铺满算的。
        val fill = max(viewWidth / shownWidth, viewHeight / shownHeight)

        val centerX = viewWidth / 2f
        val centerY = viewHeight / 2f

        val matrix = Matrix()
        // post 的顺序是「先缩放、后旋转」。反过来会绕着一个还没对上的中心转。
        matrix.postScale(
            fill * bufferWidth / viewWidth,
            fill * bufferHeight / viewHeight,
            centerX,
            centerY,
        )
        matrix.postRotate(rotation.toFloat(), centerX, centerY)

        textureView.setTransform(matrix)
    }
}

/**
 * Flutter 侧的视图工厂。
 *
 * ⚠️ 渲染模式（混合合成 / 虚拟显示）在**注册时选不了**，由 Dart 侧决定；
 * 这个视图要求混合合成，见 `MainActivity` 与 `camera_preview.dart` 的说明。
 */
class CameraPreviewFactory(
    private val channel: RecorderChannel,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPreviewView(context, channel)
}
