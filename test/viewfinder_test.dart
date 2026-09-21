import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/scanning/viewfinder.dart';

/// 规格 §3.2.2：**只有框内的面单会被识别，框外一律忽略** ——
/// 防止扫到画面里其他包裹的面单。
void main() {
  // 一个居中的方框：左右各留 25%，也就是画面中间那一半
  const viewfinder = Viewfinder(
    rect: NormalizedRect(left: 0.25, top: 0.25, width: 0.5, height: 0.5),
  );

  BarcodeDetection box(double centerX, double centerY, {double size = 0.1, String text = 'SF1'}) =>
      BarcodeDetection(
        rect: NormalizedRect(
          left: centerX - size / 2,
          top: centerY - size / 2,
          width: size,
          height: size,
        ),
        text: text,
      );

  group('框内 / 框外', () {
    test('正中间的面单被接受', () {
      expect(viewfinder.accepts(box(0.5, 0.5)), isTrue);
    });

    test('画面角落的面单被忽略', () {
      // 这正是要防的场景：同一画面里另一个包裹的面单。
      expect(viewfinder.accepts(box(0.05, 0.05)), isFalse);
      expect(viewfinder.accepts(box(0.95, 0.95)), isFalse);
    });

    test('框的边缘内一点被接受', () {
      expect(viewfinder.accepts(box(0.26, 0.26, size: 0.01)), isTrue);
    });

    test('刚好压着边界被接受', () {
      expect(viewfinder.accepts(box(0.25, 0.5, size: 0.01)), isTrue);
      expect(viewfinder.accepts(box(0.75, 0.5, size: 0.01)), isTrue);
    });

    test('边界外一点被忽略', () {
      expect(viewfinder.accepts(box(0.24, 0.5, size: 0.01)), isFalse);
      expect(viewfinder.accepts(box(0.76, 0.5, size: 0.01)), isFalse);
    });

    test('中心在框外 → 忽略（此时至多一半重叠）', () {
      // 中心点判据其实隐含了「每个轴上至少一半重叠」。反过来说：
      // 中心在外时，重叠不可能过半 —— 所以这条断言的是中心判据的性质，
      // 不是随手挑的一个数。
      expect(viewfinder.accepts(box(0.20, 0.5, size: 0.3)), isFalse);
    });

    test('只露一角但中心在框内 → 接受', () {
      expect(viewfinder.accepts(box(0.5, 0.5, size: 0.8)), isTrue);
    });
  });

  group('预设档位', () {
    test('三档大小依次递增', () {
      expect(ViewfinderPreset.small.span, lessThan(ViewfinderPreset.medium.span));
      expect(ViewfinderPreset.medium.span, lessThan(ViewfinderPreset.large.span));
    });

    test('框是居中的', () {
      for (final preset in ViewfinderPreset.values) {
        final rect = preset.rectOn(aspectRatio: 16 / 9);

        expect(rect.centerX, closeTo(0.5, 1e-9));
        expect(rect.centerY, closeTo(0.5, 1e-9));
      }
    });

    test('宽屏下框仍然接近正方形（按像素算）', () {
      // 归一化坐标里宽高不等，乘回像素才该是正方形 —— 这正是
      // 用归一化坐标而不是像素坐标的原因：换设备不用改参数。
      const aspect = 16 / 9;
      final rect = ViewfinderPreset.medium.rectOn(aspectRatio: aspect);

      final pixelWidth = rect.width * aspect;
      final pixelHeight = rect.height;

      expect(pixelWidth, closeTo(pixelHeight, 1e-9));
    });

    test('非法宽高比不会算出负数或 NaN', () {
      for (final bad in <double>[0, -1, double.nan]) {
        final rect = ViewfinderPreset.medium.rectOn(aspectRatio: bad);

        expect(rect.width.isFinite, isTrue);
        expect(rect.width, greaterThan(0));
      }
    });

    test('大框比小框接受到更多位置的检测', () {
      final small = Viewfinder.forPreset(ViewfinderPreset.small, aspectRatio: 1);
      final large = Viewfinder.forPreset(ViewfinderPreset.large, aspectRatio: 1);

      // 靠近边缘的位置：小框不收，大框收
      final nearEdge = box(0.12, 0.5, size: 0.01);

      expect(small.accepts(nearEdge), isFalse);
      expect(large.accepts(nearEdge), isTrue);
    });
  });
}
