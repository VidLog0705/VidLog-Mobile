package com.vidlog.vidlog_mobile

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.SoundEffectConstants
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
 * Dart 侧的对应实现在 `lib/recording/recorder_gateway.dart`：本类只负责**投递**，
 * 停录决策、会话收尾、索引写入全部由 Dart 完成。
 *
 * 这样切分的理由：那些逻辑是最容易写错的部分，放在 Dart 里才测得完整
 * （见 `docs/实现决策.md`）。原生层只做相机、编码、分段轮转、识码。
 *
 * | 方法 | 方向 | 语义 |
 * |---|---|---|
 * | `hasCameraPermission` | Dart → 原生 | 是否已授权 |
 * | `requestCameraPermission` | Dart → 原生 | 弹授权框（结果由系统回调，Dart 稍后重试） |
 * | `openCamera` | Dart → 原生 | 开相机送预览，**不录** |
 * | `startRecording` | Dart → 原生 | 开始录一段，参数含工作区目录、单段时长 |
 * | `stopRecording` | Dart → 原生 | 停止；**相机保持开着** |
 * | `closeCamera` | Dart → 原生 | 关相机（结束工作） |
 * | `setZoom` / `maxZoom` / `minZoom` | Dart → 原生 | 变焦与表盘刻度（规格 §3.1.2） |
 * | `focusNow` / `autoFocusAndZoom` | Dart → 原生 | 对焦；面单进框自动放大两秒 |
 * | `playDetentSound` | Dart → 原生 | 表盘拨轮声 |
 * | `speak` | Dart → 原生 | 语音播报，`beep` 为真时先滴一声（规格 §3.3.2 / §3.3.4 / §3.3.6） |
 * | `segmentClosed` | 原生 → Dart | 一个分段已封闭（**Dart 必须立刻写进 manifest**） |
 * | `sceneSampled` | 原生 → Dart | 画面是否静止 |
 * | `barcodeDetected` | 原生 → Dart | 识别到一个条码（**连续**上报，离散化是 Dart 侧的事） |
 * | `failed` | 原生 → Dart | 相机/编码出错 |
 *
 * 两端对 Dart 必须长得一样（`RecorderPlugin.swift` 是另一份），
 * 否则 `recorder_gateway.dart` 就得按平台分叉。
 *
 * ## ⚠️ `minZoom` 在 Android 上恒为 1.0（如实说明，不是没做）
 *
 * Android 那侧的变焦模型下限本来就是 1.0（`CameraSegmentRecorder` 里是
 * `coerceIn(1.0f, maxZoomRatio)`）—— 也就是 Android 根本没有超广角这条路。
 * 补一个假的 0.5 才算撒谎：Dart 会拿它把表盘左半圈画出来，
 * 而那一半划下去画面**不会变**。表盘左半圈是平的是对的。
 *
 * ## ⚠️ 未在真机上验证
 *
 * 见 `docs/实现决策.md`。本机是 Windows：没有摄像头、没有真机、不跑模拟器，
 * 相机时序、轮转、预览方向、识码都只验证到「能编译」。
 */
class RecorderChannel(private val activity: FlutterActivity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "vidlog/recorder"
        const val EVENT_CHANNEL = "vidlog/recorder/events"

        /** 预览视图的类型名，须与 Dart 侧 `camera_preview.dart` 一致。 */
        const val PREVIEW_VIEW_TYPE = "vidlog/camera_preview"

        private const val TAG = "VidLogRecorder"

        private const val REQUEST_CAMERA = 7301

        /** 滴声的音量（0~100）。与语音的音量不挂钩，取一个「听得清但不吵」的值。 */
        private const val BEEP_VOLUME = 80

        private const val BEEP_DURATION_MS = 150

        /**
         * 滴完之后隔多久开口。
         *
         * 系统提示音是**异步**播的，紧接着念的话两个音会叠在一起，
         * 听起来像「滴」被咬了半口。让出一小段，用户听到的才是
         * 规格 §3.3.6 要的顺序：先滴、再播。（与 iOS 的 `beepLeadIn` 同值。）
         */
        private const val BEEP_LEAD_IN_MS = 300L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var recorder: CameraSegmentRecorder? = null
    private var events: EventChannel.EventSink? = null

    /**
     * 预览视图挂上来的 SurfaceTexture。
     *
     * **可能比相机先到**：Flutter 建视图与 Dart 调 `openCamera` 的先后没有保证。
     * 所以存在这里，等相机开起来再交给它 —— 丢了的话预览会一直是黑的。
     */
    private var previewTexture: SurfaceTexture? = null

    /**
     * 相机几何（画面尺寸 / 传感器方向）变了，通知预览视图重算。
     *
     * 同样是因为那个先后没有保证：视图先建好时它拿到的还是默认值，
     * 得等相机开好后再算一次，否则画面是躺着的。
     */
    var onPreviewGeometryChanged: (() -> Unit)? = null

    /** 预览视图要用它。 */
    val currentRecorder: CameraSegmentRecorder? get() = recorder

    /** 等待授权结果的 Dart 回调。授权框是异步的，只能存下来等系统回调。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    /** 语音播报。规格 §3.3.2 / §3.3.4 的两句提示。 */
    private var tts: TextToSpeech? = null

    /** 滴声。**系统内置音**，零音频素材（洁净室 + 规格 §10）。 */
    private var tone: ToneGenerator? = null

    /** 排着队还没开口的那一次播报。新提示要能把它顶掉。 */
    private var pendingSpeech: Runnable? = null

    fun attach(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        recorder?.closeCamera()
        recorder = null
        events = null
        previewTexture = null
        onPreviewGeometryChanged = null

        pendingSpeech?.let { mainHandler.removeCallbacks(it) }
        pendingSpeech = null

        // TTS 与滴声都持有系统服务，不关会漏一路音频。
        tts?.shutdown()
        tts = null

        tone?.release()
        tone = null
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

            // ── 相机与录制是**两件事**（规格 §3.2.2）──
            // 点「开始工作」→ 出现可见的取景框（开相机，不录）；
            // 扫到面单 → 开录。合成一个「startSession」是之前的错，
            // 表现是「点了按钮屏幕上什么都没有，但其实在录」。

            "openCamera" -> openCamera(call, result)

            // 录制前那次**真实的可用性检查**（规格 §3.1.7）。
            //
            // **不需要相机权限、也不开会话** —— 只读 `CameraCharacteristics`。
            // 一个都跑不通 / 没有相机时给 null：那是「问不出来」，与「都不行」
            // 在 Dart 那边走同一条路（照用户选的走）—— 那里刻意不把 null 当成
            // 「降到底档」，否则一次问不出来就会静默改掉用户的画质。
            "firstUsableSpec" -> {
                val candidates = RecorderSpec.parseList(call.argument<Any>("candidates"))
                result.success(
                    CameraSegmentRecorder.firstUsableIndex(activity, candidates),
                )
            }
            "startRecording" -> startRecording(call, result)
            "stopRecording" -> stopRecording(result)
            "closeCamera" -> closeCamera(result)

            "setZoom" -> {
                val ratio = call.argument<Double>("ratio")?.toFloat()
                if (ratio == null) {
                    result.error("bad_args", "缺少 ratio", null)
                } else {
                    // 尽力而为：相机没开时是空操作，不是错误（与 iOS 一致）。
                    recorder?.setZoom(ratio)
                    result.success(null)
                }
            }

            // 相机没开时回 null（与 iOS 一致）—— Dart 侧据此用保守的默认值。
            "maxZoom" -> result.success(recorder?.maxZoomRatio?.toDouble())

            // Android 的变焦下限恒为 1.0（见类注释），相机没开时同样是 null。
            "minZoom" -> result.success(recorder?.minZoomRatio?.toDouble())

            "focusNow" -> {
                // 表盘滑动时重新对焦（规格 §3.1.2）。
                // 刻意**不给 FlutterError 分支**：相机没开、设备不支持对焦
                // 都不是错误，是尽力而为。
                recorder?.focusNow()
                result.success(null)
            }

            "playDetentSound" -> {
                // 拨轮声。同样尽力而为 —— 用户关掉系统「触感/提示音」时就该没声，
                // 那不是失败，是用户自己的选择。
                playDetentSound()
                result.success(null)
            }

            "autoFocusAndZoom" -> {
                // 面单进框：对焦 + 临时放大两秒（需求方 2026-09-22）。
                // 两秒后自动回弹的那笔账**由 recorder 自己记**，这里只管递进去。
                recorder?.autoFocusAndZoom()
                result.success(null)
            }

            "speak" -> speak(call, result)

            else -> result.notImplemented()
        }
    }

    // ─────────────────────────────────────────────
    // 相机
    // ─────────────────────────────────────────────

    /**
     * 开相机、开始送预览。**不录。**
     *
     * 规格 §3.2.2：点「开始工作」→ 出现可见的取景框。那时还没扫码。
     */
    private fun openCamera(call: MethodCall, result: MethodChannel.Result) {
        if (!hasCameraPermission()) {
            result.error("permission_denied", "没有相机权限", null)
            return
        }

        // 只认二维码 —— 只有「扫码连接」那个界面会打开它（规格 §3.4.5 ④）。
        // 缺参数 = false：老版本 Dart 不带这个参数时行为一个字都不变。
        val qrOnly = call.argument<Boolean>("qrOnly") ?: false

        // 录制规格。**缺参数 = 默认档**：老版本 Dart 不带它时行为与从前一致。
        val spec = RecorderSpec.parse(call.argument<Any>("spec"))

        // 已经开着（相机 + 预览都在跑）就直接回成功，与 iOS 一致。
        // ⚠️ 但**识码范围要顺手换掉**：就这么返回的话，录制页把相机开着、
        // 用户切到扫码连接那一下，屏幕上是一维码的白名单在扫一张二维码 ——
        // 表现是**扫了没反应**。
        // ⚠️ **规格换不了**（分辨率与编码是开会话时定死的）。Dart 那边知道
        // 这件事：规格一变它会先 `closeCamera` 再开（见
        // `RecordingCoordinator.openCamera`），所以走到这里还带着不同的规格，
        // 说明那是「顺手带上的默认值」，不是真想改档。
        recorder?.let { existing ->
            if (existing.cameraOpen) {
                existing.qrOnly = qrOnly
                result.success(null)
                return
            }
        }

        val created = CameraSegmentRecorder(
            context = activity,
            onEvent = ::emit,
        )
        created.qrOnly = qrOnly

        if (!created.openCamera(spec)) {
            result.error("camera_failed", "相机未能打开", null)
            return
        }

        // 预览可能比相机先到 —— 这时候才交得出去。
        created.setPreviewTexture(previewTexture)

        recorder = created

        // 画面尺寸 / 传感器方向刚刚才知道，让预览视图重算一次。
        onPreviewGeometryChanged?.invoke()

        result.success(null)
    }

    /** 开始录一段。[directory] 是这一段（= 一个会话）的落盘位置。 */
    private fun startRecording(call: MethodCall, result: MethodChannel.Result) {
        val current = recorder
        if (current == null) {
            result.error("no_camera", "相机还没打开", null)
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

        val started = current.startRecording(File(directory), segmentDurationMs)
        if (started) {
            result.success(null)
        } else {
            result.error("record_failed", "未能开始录制", null)
        }
    }

    /**
     * 停止录制。**相机保持开着**，取景框还在，下件包裹接着扫。
     *
     * 在**主线程**上停，并在同一线程回 result。
     *
     * 理由：`stopRecording` 会封闭当前分段并投递 `segmentClosed`，
     * 而投递走的是 `runOnUiThread`。都在主线程执行就能保证
     * 「先投递事件，再回结果」这个顺序 —— 反过来的话 Dart 会以为录完了
     * 而立刻收尾，**最后一段会被漏掉**。
     */
    private fun stopRecording(result: MethodChannel.Result) {
        activity.runOnUiThread {
            recorder?.stopRecording()
            result.success(null)
        }
    }

    /** 关闭相机（结束工作）。 */
    private fun closeCamera(result: MethodChannel.Result) {
        activity.runOnUiThread {
            recorder?.closeCamera()
            recorder = null
            result.success(null)
        }
    }

    /** 预览视图挂上 / 摘掉时调用（见 [setPreviewTexture] 的说明）。 */
    fun setPreviewTexture(texture: SurfaceTexture?) {
        previewTexture = texture
        recorder?.setPreviewTexture(texture)
    }

    // ─────────────────────────────────────────────
    // 提示音
    // ─────────────────────────────────────────────

    /**
     * 拨一下齿轮的模拟声（表盘滑过一个刻度）。规格 §3.1.2。
     *
     * 用系统的**按键音**（`View.playSoundEffect`）：不带任何音频资源 ——
     * 洁净室与许可证（规格 §10）的账上就少一笔，与 TTS 走系统是同一个理由。
     *
     * 音量与开关**跟随系统**的「触感与提示音」：用户把它关掉时不响是**正常的**，
     * 不是 bug。（iOS 那边对应的是 `UIDevice.playInputClick()`。）
     *
     * **尽力而为，什么都不抛。**
     */
    private fun playDetentSound() {
        try {
            activity.window.decorView.playSoundEffect(SoundEffectConstants.CLICK)
        } catch (error: Exception) {
            Log.w(TAG, "拨轮声失败", error)
        }
    }

    /**
     * 「滴」一声（规格 §3.3.6）。
     *
     * 用 `ToneGenerator` 生成的**系统内置音**：零音频素材，理由是上面那条。
     *
     * ⚠️ 与拨轮声**刻意走两条路**：拨轮声跟着系统的按键音开关走是对的
     * （它本来就该跟着用户的选择），但这一声「滴」是操作员判断
     * 「系统认了这一下」的反馈 —— 用户关掉按键音时它会一起消失，
     * 那个消失会被当成 bug。`ToneGenerator` 不受那个开关影响。
     *
     * ⚠️ 音色**本机不可验**（开发机是 Windows、没有真机）。要换就改
     * `TONE_PROP_BEEP` 这一个常量。
     */
    private fun beep() {
        try {
            val generator = tone ?: ToneGenerator(AudioManager.STREAM_MUSIC, BEEP_VOLUME)
                .also { tone = it }
            generator.startTone(ToneGenerator.TONE_PROP_BEEP, BEEP_DURATION_MS)
        } catch (error: Exception) {
            Log.w(TAG, "滴声失败", error)
        }
    }

    /**
     * 读出一句提示。`beep` 为真时**先滴一声再开口**（规格 §3.3.6）。
     *
     * 引擎没装中文语音时**不能因此判定失败**：那时系统会退化成默认语音，
     * 用户至少还听得见有提示。播报是尽力而为的，Dart 侧也按成功处理
     * （见 `RecorderGateway.speak`）。
     *
     * **不等念完就回结果**：TTS 是异步的，等它等于让 Dart 侧那条事件链
     * 干等一两秒。Dart 只关心「递出去了没有」。
     */
    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")
        if (text.isNullOrBlank()) {
            result.error("bad_args", "缺少 text", null)
            return
        }

        // 新提示顶掉旧的那句。两句提示本来就不会同时出现，
        // 而「面单错误，请扫描正确面单」连着报两次时，叠着念比只念一遍更糟 ——
        // 用户要先听完才知道是同一句。
        //
        // ⚠️ 排队等着开口的那一次也要顶掉（连续扫时两句提示可能只隔几百毫秒，
        // 三百毫秒前那句此刻还没出声）。少了这一步，后面那句会跟着一起念出来。
        pendingSpeech?.let { mainHandler.removeCallbacks(it) }
        pendingSpeech = null

        // 已经在念的那句也要掐掉。QUEUE_FLUSH 管得到「还没开始的」，
        // 但连报两次同一句时，用户听到的是前一句被打断 —— 那是想要的。
        ttsEngine()?.stop()

        val speakNow = Runnable {
            pendingSpeech = null
            // 引擎还没就绪时这次调用会静默失败，**这是可接受的**：
            // 播报是尽力而为的。
            ttsEngine()?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "vidlog-prompt")
        }

        if (call.argument<Boolean>("beep") != true) {
            speakNow.run()
            result.success(null)
            return
        }

        // 顺序是规格 §3.3.6 的原话：「滴一声**然后**播报」。
        beep()
        pendingSpeech = speakNow
        mainHandler.postDelayed(speakNow, BEEP_LEAD_IN_MS)

        result.success(null)
    }

    /**
     * 拿到（必要时建好）TTS 引擎。
     *
     * 第一次调用时才建：用户可能整场都没扫错过一次码，那就一次都不用播报。
     * 引擎初始化是异步的，`onInit` 回调时 [tts] 已经赋好值。
     */
    private fun ttsEngine(): TextToSpeech? {
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

    // ─────────────────────────────────────────────
    // 事件投递
    // ─────────────────────────────────────────────

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

                is RecorderEvent.BarcodeDetected -> sink.success(
                    mapOf(
                        "type" to "barcodeDetected",
                        "text" to event.text,
                        "centerX" to event.centerX,
                        "centerY" to event.centerY,
                        "confidence" to event.confidence,
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
