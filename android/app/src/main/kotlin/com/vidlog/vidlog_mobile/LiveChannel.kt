package com.vidlog.vidlog_mobile

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 实时推流那条通道（规格 §3.8，需求方 2026-10-01 定的方案）。
 *
 * ## ⚠️ 为什么**另开一条通道**，不并进 `vidlog/recorder`
 *
 * 规格第 2 条（不许传染）：两条通道的失败面分开之后，推流起不来
 * **不会**让录制那条通道上的任何一次调用跟着进错误分支 ——
 * 并进去的话，`RecorderGateway` 的每一个调用点都要开始考虑
 * 「这次失败是不是推流引起的」。
 *
 * 与 iOS 侧的 `LiveChannel` **逐字一致**（方法名、事件形状、错误口径）。
 *
 * | 通道 | 给什么 |
 * |---|---|
 * | `vidlog/live`（方法） | `startLive(height)` / `stopLive()` / `setLiveQuality(height)` |
 * | `vidlog/live/frames`（事件） | `{type:"frame", key:是否关键帧, data:字节}` 与 `{type:"failed", message}` |
 *
 * ⚠️ **失败回 `result.error`，不能回 `success(字符串)`** —— Dart 那边
 * `invokeMethod<void>` 会把成功的返回值丢掉，回一个字符串等于
 * 「这边失败了、那边以为成了」。
 */
class LiveChannel(private val recorderProvider: () -> CameraSegmentRecorder?) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "vidlog/live"
        const val EVENT_CHANNEL = "vidlog/live/frames"

        private const val TAG = "VidLogLive"

        /** 没写档位时用哪一档（格子那一档，与 Dart 的 `LiveQuality.tile` 一致）。 */
        private const val DEFAULT_LINES = LiveStreamer.TILE_LINES
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 事件出口。**没有它的时候一帧都不发**（见 [emitFrame]）。 */
    private var events: EventChannel.EventSink? = null

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun dispose() {
        events = null
        recorderProvider()?.stopLive()
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
        val recorder = recorderProvider()

        when (call.method) {
            "startLive" -> {
                if (recorder == null) {
                    result.error("live_failed", "相机还没开，推流起不来", null)
                    return
                }

                val lines = call.argument<Int>("height") ?: DEFAULT_LINES

                val failure = recorder.startLive(
                    lines = lines,
                    onFrame = { bytes, isKey -> emitFrame(bytes, isKey) },
                    onFailure = { message -> emitFailure(message) },
                )

                if (failure != null) {
                    result.error("live_failed", failure, null)
                } else {
                    result.success(null)
                }
            }

            "stopLive" -> {
                recorder?.stopLive()
                result.success(null)
            }

            "setLiveQuality" -> {
                val lines = call.argument<Int>("height") ?: DEFAULT_LINES
                val refusal = recorder?.setLiveLines(lines)

                if (refusal != null) {
                    // ⚠️ 安卓这边**尺寸是开会话时钉死的**，所以这条真的会响。
                    // 回成功的话电脑端会按新尺寸重开解码，而画面还是老的。
                    result.error("live_failed", refusal, null)
                } else {
                    result.success(null)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ─────────────────────────────────────────────
    // 事件投递
    // ─────────────────────────────────────────────

    /**
     * 推一块出去。
     *
     * ⚠️ **没有订阅者时一个字节都不发**：这条路每帧都要拷一次内存
     * （30fps × 几万字节），没人看的时候那些拷贝是白花的。
     */
    private fun emitFrame(bytes: ByteArray, isKey: Boolean) {
        if (events == null) return

        mainHandler.post {
            events?.success(
                mapOf(
                    "type" to "frame",
                    "key" to isKey,
                    "data" to bytes,
                ),
            )
        }
    }

    private fun emitFailure(message: String) {
        mainHandler.post {
            events?.success(mapOf("type" to "failed", "message" to message))
        }
    }
}
