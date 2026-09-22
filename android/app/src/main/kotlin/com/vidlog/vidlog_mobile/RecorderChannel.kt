package com.vidlog.vidlog_mobile

import android.Manifest
import android.content.pm.PackageManager
import android.speech.tts.TextToSpeech
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

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
 * | `speak` | Dart → 原生 | 语音播报（规格 §3.3.2 / §3.3.4） |
 * | `segmentClosed` | 原生 → Dart | 一个分段已封闭（**Dart 必须立刻写进 manifest**） |
 * | `sceneSampled` | 原生 → Dart | 画面是否静止 |
 * | `failed` | 原生 → Dart | 相机/编码出错 |
 *
 * ## ⚠️ 与 Dart 侧的方法名对不上（已知缺口，未修）
 *
 * Dart 的 `ChannelRecorderGateway` 调的是 `openCamera` / `startRecording` /
 * `stopRecording` / `closeCamera` / `autoFocusAndZoom` / `minZoom` /
 * `focusNow` / `playDetentSound`，而本类实现的是
 * `startSession` / `stopSession` —— 每次调用都会落到 `notImplemented`，
 * **Android 端目前整条链路是通的不了**。iOS 侧（`RecorderPlugin.swift`）是对的。
 *
 * `minZoom` / `focusNow` / `playDetentSound`（表盘改造，2026-09-22）同样
 * **不在这里补空壳**，理由与下一条相同。其中 `minZoom` 需要说明一句：
 * Android 那侧的变焦模型**下限本来就恒为 1.0**（`setZoom` 里是
 * `coerceIn(1.0f, maxZoomRatio)`，`applyZoom` 同）—— 也就是 Android 根本没有
 * 超广角这条路。所以补一个 `minZoom -> 1.0` 不算撒谎，但也没必要：
 * Dart 侧拿不到就按 1.0 处理，表盘左半圈自然是平的（规格 §3.1.2 的异常条款）。
 *
 * `autoFocusAndZoom`（面单进框对焦 + 临时放大两秒，2026-09-22）**故意不在这里
 * 补一个空壳**：补了会让人以为两端都做了。接上 Android 相机链路时，
 * 它要跟 `openCamera` / `startRecording` 一起补 —— 那需要的是
 * `CameraSegmentRecorder` 的生命周期拆分，不是在这里加一个 `result.success(null)`。
 * Dart 侧对它是尽力而为的（调用点吞掉异常），所以现在落到 `notImplemented`
 * 不会影响任何现有行为。
 *
 * 不能只把名字改过来完事：规格 §3.2.2 要的是「点开始工作 → 出现取景框（**不录**）
 * → 扫到面单才开录」，而 [CameraSegmentRecorder.start] 是**开相机与开录一起做**的，
 * `stop` 又把相机一起关掉。照现在的名字硬接，`openCamera` 会变成「一点按钮就在录」
 * —— 那正是 iOS 那边注释里记着的、已经犯过一次的错。
 *
 * 所以修它要先拆 [CameraSegmentRecorder] 的生命周期（相机常开、只换编码器与封装器），
 * 那是 Android 原生层的一件独立工作，不在 M4 的四项之内。
 * 见 `docs/实现决策.md`。
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

    /** 语音播报。规格 §3.3.2 / §3.3.4 的两句提示。 */
    private var tts: TextToSpeech? = null

    fun attach(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        recorder?.stop()
        recorder = null
        events = null

        // TTS 持有系统服务，不关会漏一路音频。
        tts?.shutdown()
        tts = null
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

            // 在**主线程**上停，并在同一线程回 result。
            //
            // 理由：stop() 会封闭当前分段并通过 runOnUiThread 投递 segmentClosed。
            // 如果在别的线程调用 stop() 再立刻 result.success，那一事件还在队列里，
            // Dart 拿到「已停止」就去做收尾 —— **最后一段会被漏掉**。
            // 都在主线程执行就能保证「先投递事件，再回结果」这个顺序。
            "stopSession" -> {
                activity.runOnUiThread {
                    recorder?.stop()
                    recorder = null
                    result.success(null)
                }
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

            // 相机没开时回 null（与 iOS 一致）—— Dart 侧据此用保守的默认值。
            "maxZoom" -> result.success(recorder?.maxZoomRatio?.toDouble())

            "speak" -> {
                val text = call.argument<String>("text")
                if (text.isNullOrBlank()) {
                    result.error("bad_args", "缺少 text", null)
                } else {
                    // QUEUE_FLUSH：新提示顶掉旧的那句。
                    // 两句提示本来就不会同时出现，而「面单不同」连着报两次时
                    // 叠着念比只念一遍更糟 —— 用户要先听完才知道是同一句。
                    //
                    // 引擎还没就绪时这次调用会静默失败，**这是可接受的**：
                    // 播报是尽力而为，Dart 侧也按成功处理（见 RecorderGateway.speak）。
                    tts().speak(text, TextToSpeech.QUEUE_FLUSH, null, "vidlog-prompt")
                    result.success(null)
                }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 拿到（必要时建好）TTS 引擎。
     *
     * 第一次调用时才建：用户可能整场都没扫错过一次码，那就一次都不用播报。
     * 引擎初始化是异步的，`onInit` 回调时 [tts] 已经赋好值。
     */
    private fun tts(): TextToSpeech {
        tts?.let { return it }

        val created = TextToSpeech(activity) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val chinese = Locale.SIMPLIFIED_CHINESE
                if (tts?.isLanguageAvailable(chinese) == TextToSpeech.LANG_AVAILABLE) {
                    tts?.language = chinese
                }
            }
        }

        tts = created
        return created
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
