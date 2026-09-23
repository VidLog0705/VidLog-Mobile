package com.vidlog.vidlog_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 应用入口。
 *
 * 只做一件事：把原生录制器的通道与预览视图接上。所有逻辑都在
 * [CameraSegmentRecorder]（相机/编码/分段/识码）与 Dart 侧的 `lib/recording/`。
 */
class MainActivity : FlutterActivity() {

    private var recorderChannel: RecorderChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = RecorderChannel(this)
        channel.attach(flutterEngine.dartExecutor.binaryMessenger)

        // 预览视图（规格 §3.2.2：取景框要看得见）。
        //
        // ⚠️ 这里**只能**注册视图类型，选不了渲染模式 —— 混合合成还是虚拟显示
        // 由 Dart 侧建视图的方式决定（`camera_preview.dart` 用的是
        // `initExpensiveAndroidView`，即混合合成）。
        //
        // 预览是相机直接写进去的一路 Surface，**虚拟显示渲染不出它**：
        // 那边选错的表现是**一块黑屏**，而且不会有任何报错。
        // 真机上看到黑屏、取景框却画得好好的，先查 Dart 那一处。
        flutterEngine.platformViewsController.registry.registerViewFactory(
            RecorderChannel.PREVIEW_VIEW_TYPE,
            CameraPreviewFactory(channel),
        )

        recorderChannel = channel
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        // 相机授权是异步的，Dart 侧的 result 一直挂着等这个回调。
        recorderChannel?.let { channel ->
            if (channel.handlesRequest(requestCode)) {
                channel.onPermissionResult(requestCode, grantResults)
            }
        }
    }

    override fun onDestroy() {
        recorderChannel?.dispose()
        recorderChannel = null
        super.onDestroy()
    }
}
