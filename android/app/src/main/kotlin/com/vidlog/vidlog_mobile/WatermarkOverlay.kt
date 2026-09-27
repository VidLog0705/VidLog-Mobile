package com.vidlog.vidlog_mobile

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * 水印（规格 §3.6.2）—— 文字那一半。
 *
 * 规格原话（2026-09-24 需求变更）：「自动在视频打水印，**年/月/日/时/分/秒**水印在进入
 * 发货或者退货模式页面时，顶部常驻。在开始工作扫描到快递单号时，对视频添加**完整
 * 快递单号**水印。」追问后补充：「水印里的时间是**按秒走的**，参照……**北京时间**」。
 *
 * ## 与另外两端是同一份规格的三半
 *
 * 格式、时区、补零规则**逐个对齐**：
 * - 电脑端 `VidLog.Desktop.Core/Media/Watermark.cs`
 * - 手机端 Dart `lib/recording/watermark_text.dart`（**有单测**，三端的格式以它为准）
 *
 * ⚠️ **时间是 UTC+8，与设备时区无关**（规格：「用户改时区不影响水印，两端显示也一致」）。
 * 所以这里用 `TimeZone.getTimeZone("GMT+08:00")`，**不用**默认时区。
 *
 * ⚠️ **起算点是可信时钟给的开录时刻**（规格 §3.6.3：「水印与时长都不得取自墙钟」），
 * 帧时间只用来加偏移。
 *
 * ⚠️ **这段代码没有在真机上跑过**（开发机是 Windows、不跑模拟器），只过了 CI 编译。
 * 真机验收见 `docs/真机验收清单.md` §1.26。
 */
object WatermarkOverlay {

    /** 北京时间。 */
    private val beijing: TimeZone = TimeZone.getTimeZone("GMT+08:00")

    /**
     * 线程私有 —— `SimpleDateFormat` 不是线程安全的。
     *
     * 水印在**采集线程**上算，而它只有一条；用 ThreadLocal 是为了将来有人
     * 从别处调它时不会踩到并发（这种 bug 在真机上表现为「偶尔某个字是乱的」）。
     */
    private val formatter = ThreadLocal.withInitial {
        SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.US).apply {
            timeZone = beijing
        }
    }

    /** 第一行：`年/月/日 时:分:秒`（与 Dart 侧 `watermarkClockLine` 逐字相同）。 */
    fun clockLine(epochMs: Long): String = formatter.get().format(Date(epochMs))

    /** 第二行：**完整**单号（规格：不截断）。空串 = 不画那一行。 */
    fun waybillLine(waybill: String): String = waybill.trim()

    /**
     * 把两行字画成一张位图（交给 GL 贴上去）。
     *
     * 尺寸与位置与另外两端同一个口径：**顶部居中**、字号按画面高度的比例，
     * 单号那行在时间那行**下面**。
     *
     * ⚠️ **黑描边**：白字压在**白面单**上时没有它就完全看不见 ——
     * 与界面上那四角括号同一个理由（规格 §3.2.2）。
     */
    fun render(epochMs: Long, waybill: String, videoWidth: Int, videoHeight: Int): Bitmap? {
        val clockSize = maxOf(12f, videoHeight * 0.040f)
        val waybillSize = maxOf(12f, videoHeight * 0.050f)
        val margin = maxOf(6f, videoHeight * 0.02f)

        val clockText = clockLine(epochMs)
        val waybillText = waybillLine(waybill)

        val clockPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = clockSize
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            // 描边：先画粗黑边，再填白字（下同）。负值会被忽略，所以用 stroke 两次画。
            style = Paint.Style.STROKE
            strokeWidth = maxOf(2f, clockSize * 0.12f)
            strokeJoin = Paint.Join.ROUND
        }

        val clockFill = Paint(clockPaint).apply { style = Paint.Style.FILL }

        val waybillPaint = Paint(clockPaint).apply {
            color = Color.RED
            textSize = waybillSize
            strokeWidth = maxOf(2f, waybillSize * 0.12f)
        }

        val waybillFill = Paint(waybillPaint).apply { style = Paint.Style.FILL }

        val stripWidth = maxOf(
            clockPaint.measureText(clockText),
            if (waybillText.isEmpty()) 0f else waybillPaint.measureText(waybillText),
        )

        val lineHeight = clockSize + waybillSize
        val stripHeight = lineHeight + (if (waybillText.isEmpty()) 0f else 4f) + 8f

        if (stripWidth <= 0f) return null

        val bitmap = Bitmap.createBitmap(
            stripWidth.toInt() + 8,
            stripHeight.toInt(),
            Bitmap.Config.ARGB_8888,
        )

        val canvas = Canvas(bitmap)

        var y = margin * 0.5f + clockSize

        // 先描边后填充 —— 反过来的话描边会盖住字。
        for (paint in listOf(clockPaint, clockFill)) {
            canvas.drawText(clockText, 4f, y, paint)
        }

        if (waybillText.isNotEmpty()) {
            y += waybillSize + 4f

            for (paint in listOf(waybillPaint, waybillFill)) {
                canvas.drawText(waybillText, 4f, y, paint)
            }
        }

        return bitmap
    }
}
