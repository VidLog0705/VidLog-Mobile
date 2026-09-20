package com.vidlog.vidlog_mobile

import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 原生录制器 ↔ Dart 的桥。
 *
 * ## 契约
 *
 * Dart 侧的对应实现在 `lib/recording/`：本类只负责**投递**，
 * 停录决策、会话收尾、索引写入全部由 Dart 完成。
 *
 * 这样切分的理由：那些逻辑是最容易写错的部分，放在 Dart 里才测得完整
 * （见 `docs/实现决策.md`）。原生层只做相机、编码、分段轮转。
 *
 * | 方法 | 方向 | 语义 |
 * |---|---|---|
 * | `hasCameraPermission` | Dart → 原生 | 是否已授权 |
 * | `requestCameraPermission` | Dart → 原生 | 弹授权框（结果由系统回调，Dart 稍后重试） |
 * | `startSession` | Dart → 原生 | 开始录制，参数含工作区目录、单号、单段时长 |
 * | `stopSession` | Dart → 原生 | 停止并封掉当前分段 |
 * | `setZoom` | Dart → 原生 | 变焦 |
 * | `segmentClosed` | 原生 → Dart | 一个分段已封闭（**Dart 必须立刻写进 manifest**） |
 * | `sceneSampled` | 原生 → Dart | 画面是否静止 |
 * | `failed` | 原生 → Dart | 相机/编码出错 |
 *
 * ⚠️ **未在真机上验证。** 见 `docs/实现决策.md`。
 */
class RecorderChannel(private val activity: FlutterActivity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "vidlog/recorder"
        const val EVENT_CHANNEL = "vidlog/recorder/events"

        private const val REQUEST_CAMERA = 7301
    }

    private var recorder: CameraSegmentRecorder? = null
    private var events: EventChannel.EventSink? = null

    /** 等待授权结果的 Dart 回调。授权框是异步的，只能存下来等系统回调。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun attach(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        recorder?.stop()
        recorder = null
        events = null
    }

    // ─────────────────────────────────────────────
    // EventChannel
    // ─────────────────────────────────────────────

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    // ─────────────────────────────────────────────
    // MethodChannel
    // ─────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasCameraPermission" -> result.success(hasCameraPermission())

            "requestCameraPermission" -> {
                if (hasCameraPermission()) {
                    result.success(true)
                } else {
                    // 结果要等系统回调，先把 result 存下来。
                    pendingPermissionResult = result
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(Manifest.permission.CAMERA),
                        REQUEST_CAMERA,
                    )
                }
            }

            "startSession" -> startSession(call, result)

            "stopSession" -> {
                recorder?.stop()
                recorder = null
                result.success(null)
            }

            "setZoom" -> {
                val ratio = call.argument<Double>("ratio")?.toFloat()
                if (ratio == null) {
                    result.error("bad_args", "缺少 ratio", null)
                } else {
                    recorder?.setZoom(ratio)
                    result.success(null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun startSession(call: MethodCall, result: MethodChannel.Result) {
        if (!hasCameraPermission()) {
            result.error("permission_denied", "没有相机权限", null)
            return
        }

        val directory = call.argument<String>("directory")
        if (directory.isNullOrBlank()) {
            result.error("bad_args", "缺少 directory", null)
            return
        }

        val segmentDurationMs =
            call.argument<Number>("segmentDurationMs")?.toLong()
                ?: CameraSegmentRecorder.DEFAULT_SEGMENT_DURATION_MS

        recorder?.stop()

        val sessionDirectory = File(directory)
        sessionDirectory.mkdirs()

        val created = CameraSegmentRecorder(
            context = activity,
            outputDirectory = sessionDirectory,
            segmentDurationMs = segmentDurationMs,
            onEvent = ::emit,
        )

        if (!created.start()) {
            result.error("start_failed", "相机未能启动", null)
            return
        }

        recorder = created
        result.success(null)
    }

    private fun emit(event: RecorderEvent) {
        // 事件回调来自相机线程 / 编码线程，而 EventSink **必须在主线程**用。
        activity.runOnUiThread {
            val sink = events ?: return@runOnUiThread

            when (event) {
                is RecorderEvent.SegmentClosed -> sink.success(
                    mapOf(
                        "type" to "segmentClosed",
                        "filePath" to event.segment.filePath,
                        "sequence" to event.segment.sequence,
                        "startedAtMs" to event.segment.startedAtMs,
                        "endedAtMs" to event.segment.endedAtMs,
                    ),
                )

                is RecorderEvent.SceneSampled -> sink.success(
                    mapOf(
                        "type" to "sceneSampled",
                        "isStatic" to event.isStatic,
                    ),
                )

                is RecorderEvent.Failed -> sink.success(
                    mapOf(
                        "type" to "failed",
                        "message" to event.message,
                    ),
                )
            }
        }
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    /** 由 [MainActivity.onRequestPermissionsResult] 转发过来。 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_CAMERA) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED

        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    /** 供 [MainActivity] 判断要不要处理。 */
    fun handlesRequest(requestCode: Int): Boolean = requestCode == REQUEST_CAMERA
}
