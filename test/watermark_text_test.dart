import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/recording/watermark_text.dart';

/// 水印那两行文字（规格 §3.6.2）。
///
/// ⚠️ 这里验的是**排版**（格式、时区、补零）。「字有没有真的画进帧里」
/// 只有真机能验 —— 那一条在 `docs/真机验收清单.md` §1.26。
void main() {
  group('第一行：年/月/日 时:分:秒', () {
    test('★ 是北京时间，与设备时区无关', () {
      // 规格：「时区固定为 UTC+8（北京时间），与设备本地时区无关」。
      // ⚠️ 所以**不能**用 `toLocal()`：那条路会跟着设备的时区跑。
      final utc = DateTime.utc(2026, 9, 27, 4, 0, 0);

      expect(watermarkClockLine(utc), '2026/09/27 12:00:00');
    });

    test('补零 —— 个位数也要写成两位', () {
      final moment = DateTime.utc(2026, 1, 2, 0, 0, 0);   // 北京时间 08:00:00

      expect(watermarkClockLine(moment), '2026/01/02 08:00:00');
    });

    test('跨日边界：UTC 的夜里是北京的次日上午', () {
      expect(watermarkClockLine(DateTime.utc(2026, 9, 26, 20, 0, 0)),
          '2026/09/27 04:00:00');
      expect(watermarkClockLine(DateTime.utc(2026, 9, 26, 15, 59, 59)),
          '2026/09/26 23:59:59');
    });

    test('按秒走 —— 相邻两秒给出不同的字', () {
      // 规格：「水印里的时间是**按秒走的**」。
      final base = DateTime.utc(2026, 9, 27, 4, 0, 0);

      expect(watermarkClockLine(base.add(const Duration(seconds: 1))),
          '2026/09/27 12:00:01');
      expect(watermarkClockLine(base.add(const Duration(seconds: 59))),
          '2026/09/27 12:00:59');
    });

    test('传入的时刻带别的偏移量也照样是北京时间', () {
      // 同一个瞬间用不同偏移量表达（比如从原生拿回来的时刻带本机偏移），
      // 结果必须一样 —— 否则「与设备时区无关」那句就是假的。
      final beijing = DateTime.utc(2026, 9, 27, 4, 0, 0);

      expect(watermarkClockLine(beijing), watermarkClockLine(beijing.toLocal()));
    });
  });

  group('第二行：完整单号', () {
    test('一个字都不许省', () {
      const long = 'SF1234567890123456789012';

      expect(watermarkWaybillLine(long), long);
      expect(watermarkWaybillLine('  $long  '), long);
    });

    test('空单号就是空串（没在录时不出现）', () {
      expect(watermarkWaybillLine(''), isEmpty);
      expect(watermarkWaybillLine('   '), isEmpty);
    });
  });

  group('覆盖时长', () {
    test('★ 比段时长多留一点余量', () {
      // 段会按时长滚动，但最后一段可能超出一点；
      // **少了余量就会出现「最后几秒没有水印」** —— 而部分缺失比全都没有更难发现。
      expect(watermarkCoverage(const Duration(minutes: 1)),
          const Duration(minutes: 3));
      expect(watermarkCoverage(const Duration(minutes: 5)),
          const Duration(minutes: 7));
    });
  });
}
