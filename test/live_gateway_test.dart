import 'package:flutter_test/flutter_test.dart';
import 'package:vidlog_mobile/live/live_gateway.dart';

/// 这一层只钉一件事：**「这一路用的是软编还是硬编」判得对不对**（T16 取证）。
///
/// ⚠️ 判错了的后果是**方向性的**：软编被当成硬编，那就只有等到现场反应
/// 「一开录就卡」，而日志里那条线索看着一切正常 —— 于是又去查 WiFi。
void main() {
  group('编码器名 → 软编还是硬编', () {
    test('AOSP 那颗是软编', () {
      expect(looksSoftwareEncoder('c2.android.avc.encoder'), isTrue);
    });

    test('厂商的硬编名别误判成软编', () {
      // 硬编名单列不全（高通、联发科、三星各一套命名）—— 所以不列，
      // 认「不是 c2.android」就是硬编。
      for (final name in [
        'OMX.qcom.video.encoder.avc',
        'c2.qti.avc.encoder',
        'OMX.MTK.VIDEO.ENCODER.AVC',
        'c2.exynos.h264.encoder',
      ]) {
        expect(looksSoftwareEncoder(name), isFalse, reason: name);
      }
    });
  });

  group('原生回的那点事实 → 日志那一行', () {
    test('认得出软编，并且名字照抄不翻', () {
      expect(
        codecNotice({'codec': 'c2.android.avc.encoder'}),
        '这一路的编码器是 c2.android.avc.encoder（软编）',
      );
    });

    test('⚠️ 键对不上时不许瞎记一条', () {
      // 原生改了键名而这边没跟着改 —— 静静地不记，比记一条「编码器是 null」好。
      expect(codecNotice({'编码器': 'c2.android.avc.encoder'}), isNull);
      expect(codecNotice({'codec': ''}), isNull);
    });

    test('iOS 与老版本原生回别的东西，不记', () {
      expect(codecNotice(null), isNull);
      expect(codecNotice('ok'), isNull);
    });
  });
}
