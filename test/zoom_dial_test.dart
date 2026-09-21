import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/zoom_dial.dart';

/// 半圆刻度盘的触点 → 倍率换算（规格 §3.1.2）。
///
/// 圆心在**底边中点**、表盘是圆的上半部分：正左最小、正右最大、正上居中。
/// 这一段纯几何，真机上拿手指去验太贵，所以把它单独拿出来测。
void main() {
  // 表盘直径 120 → 半圆高 60。
  const size = Size(120, 60);
  const maxZoom = 4.0;

  double ratioAt(double x, double y) =>
      zoomRatioFor(Offset(x, y), size, maxZoom: maxZoom);

  group('★ 三个基准点', () {
    test('正左 = 1 倍', () {
      expect(ratioAt(0, 60), closeTo(1.0, 1e-9));
    });

    test('正右 = 设备上限', () {
      expect(ratioAt(120, 60), closeTo(maxZoom, 1e-9));
    });

    test('正上 = 正中间', () {
      expect(ratioAt(60, 0), closeTo(1 + (maxZoom - 1) / 2, 1e-9));
    });
  });

  group('边界', () {
    test('手指滑到表盘左右之外，钳在两端', () {
      expect(ratioAt(-200, 60), closeTo(1.0, 1e-9));
      expect(ratioAt(400, 60), closeTo(maxZoom, 1e-9));
    });

    test('手指落到直径下方，按左右归到最近的一端', () {
      // 规格没规定这个，但「滑出表盘」必须有确定行为 ——
      // 不然手指一沉到表盘下面，倍率就会乱跳。
      expect(ratioAt(-50, 200), closeTo(1.0, 1e-9));
      expect(ratioAt(200, 200), closeTo(maxZoom, 1e-9));
    });

    test('表盘高度为 0 不会算出 NaN', () {
      expect(zoomRatioFor(const Offset(10, 10), const Size(120, 0)), 1);
    });

    test('设备只能 1 倍时，划哪儿都是 1 倍', () {
      // 上限就是 1 —— 除 0 会算出 NaN，画出来的是一条飘在画面外的东西。
      for (final x in [0.0, 30.0, 60.0, 90.0, 120.0]) {
        expect(zoomRatioFor(Offset(x, 20), size, maxZoom: 1), 1);
      }
    });
  });

  test('★ 从左划到右是单调递增的', () {
    // 单调是「跟手」的前提：中间任何一处回跳，手感就是错的。
    var previous = 0.0;
    for (var x = 0.0; x <= 120; x += 6) {
      final ratio = ratioAt(x, 30);
      expect(ratio, greaterThanOrEqualTo(previous), reason: 'x=$x 处回跳了');
      previous = ratio;
    }
  });
}
