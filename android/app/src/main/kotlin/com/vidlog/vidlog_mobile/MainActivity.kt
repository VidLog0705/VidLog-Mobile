package com.vidlog.vidlog_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 应用入口。
 *
 * 只做一件事：把原生录制器的通道接上。所有逻辑都在
 * [CameraSegmentRecorder]（相机/编码/分段）与 Dart 侧的 `lib/recording/`。
 */
class MainActivity : FlutterActivity() {

    private var recorderChannel: RecorderChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = RecorderChannel(this)
        channel.attach(flutterEngine.dartExecutor.binaryMessenger)
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
