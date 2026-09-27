/// 水印那两行文字（规格 §3.6.2）。
///
/// 规格原话（2026-09-24 需求变更）：「自动在视频打水印，**年/月/日/时/分/秒**水印在
/// 进入发货或者退货模式页面时，顶部常驻。在开始工作扫描到快递单号时，对视频添加
/// **完整快递单号**水印。」追问后补充：「水印里的时间是**按秒走的**，参照……**北京时间**」。
///
/// ## 与电脑端同一份规格的两半
///
/// 电脑端的同名实现在 `VidLog.Desktop.Core/Media/Watermark.cs`（`WatermarkText`）。
/// 格式、时区、补零规则**逐个对齐** —— 两端的水印长得不一样的话，
/// 同一批货的两段录像放在一起就没法解释。
///
/// ⚠️ **时间是 UTC+8，与设备时区无关**（规格：「用户改时区不影响水印，
/// 两端显示也一致」）。所以这里**不用** `toLocal()`。
///
/// ⚠️ **时刻来自可信时钟**（规格 §3.6.3：「水印与时长都不得取自墙钟」）——
/// 这个文件只负责**排版**，时刻由调用方从 `TrustedClock.now` 取。
library;

/// 水印固定用北京时间（UTC+8）。
const Duration beijingOffset = Duration(hours: 8);

/// 第一行：`年/月/日 时:分:秒`。
///
/// [moment] 是**可信时刻**（`TrustedClock.now`），不是墙钟。
String watermarkClockLine(DateTime moment) {
  final beijing = moment.toUtc().add(beijingOffset);

  return '${_four(beijing.year)}/${_two(beijing.month)}/${_two(beijing.day)} '
      '${_two(beijing.hour)}:${_two(beijing.minute)}:${_two(beijing.second)}';
}

/// 第二行：**完整**单号（规格 §3.6.2：不截断）。
///
/// ⚠️ **一个字都不许省**。界面上别处可能做过省略号处理，
/// 但水印是**唯一**随证据离开系统的自证载体 —— 截断了就等于没有。
String watermarkWaybillLine(String waybill) => waybill.trim();

/// 这一段水印要覆盖多久。
///
/// = 单段时长 + 余量。段会按时长滚动，但最后一段可能超出一点 ——
/// **少了余量就会出现「最后几秒没有水印」**，而部分缺失比全都没有更难发现。
/// 与电脑端同一个口径（那边是 `+ 2 分钟`）。
Duration watermarkCoverage(Duration segmentDuration) =>
    segmentDuration + const Duration(minutes: 2);

String _two(int value) => value.toString().padLeft(2, '0');

String _four(int value) => value.toString().padLeft(4, '0');
