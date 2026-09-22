import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/zoom_dial.dart';

/// 半圆刻度盘的换算（规格 §3.1.2 · 2026-09-22 改造后）。
///
/// 圆心在**底边中点**、表盘是圆的上半部分。
/// 三个基准点：**正左 = 设备下限、正上 = 初始画面（1 倍）、正右 = 设备上限**。
///
/// ⚠️ 表盘的**两半各自线性、但两半之间跨度不同** —— 因为「正中为 0（= 1 倍）」
/// 和「每格 0.1」这两条要求，在设备范围本身不对称（左 0.5→1、右 1→上限）时
/// 没法用一根直线满足。这几条测试就是钉住这个形状。
///
/// 这一段纯几何，真机上拿手指去验太贵，所以单独拿出来测。
void main() {
  // 表盘直径 120 → 半圆高 60。
  const size = Size(120, 60);
  const maxZoom = 4.0;
  const minZoom = 0.5;

  double ratioAt(double x, double y) =>
      zoomRatioFor(Offset(x, y), size, minZoom: minZoom, maxZoom: maxZoom);

  group('★ 三个基准点', () {
    test('正左 = 设备下限（超广角）', () {
      expect(ratioAt(0, 60), closeTo(minZoom, 1e-9));
    });

    test('★ 正上 = 初始画面 1 倍（不是量程中点）', () {
      // 2026-09-22 之前这里是「量程中点」= (1+上限)/2。
      // 需求方要求「正中为 0，也就是初始大小画面」⇒ 正上必须**正好是 1 倍**。
      expect(ratioAt(60, 0), closeTo(1.0, 1e-9));

      // 顺手把「不是中点」也钉住：中点会是被 1 和上限夹着的那个数。
      expect(ratioAt(60, 0), isNot(closeTo((1 + maxZoom) / 2, 1e-3)));
    });

    test('正右 = 设备上限', () {
      expect(ratioAt(120, 60), closeTo(maxZoom, 1e-9));
    });
  });

  group('两段各自线性', () {
    test('左半圈：中点角度 = 下限与 1 倍的中点', () {
      expect(
        zoomRatioForFraction(0.25, minZoom: minZoom, maxZoom: maxZoom),
        closeTo(0.75, 1e-9),
      );
    });

    test('右半圈：中点角度 = 1 倍与上限的中点', () {
      expect(
        zoomRatioForFraction(0.75, minZoom: minZoom, maxZoom: maxZoom),
        closeTo(1 + (maxZoom - 1) / 2, 1e-9),
      );
    });
  });

  group('★ 倍率 → 弧上位置（画指针用，必须是反函数）', () {
    test('三个基准点来回走一遍不走样', () {
      for (final ratio in [minZoom, 1.0, 2.5, maxZoom]) {
        final fraction = zoomFractionForRatio(ratio,
            minZoom: minZoom, maxZoom: maxZoom);
        expect(
          zoomRatioForFraction(fraction, minZoom: minZoom, maxZoom: maxZoom),
          closeTo(ratio, 1e-9),
          reason: '$ratio 倍绕回来变了',
        );
      }
    });

    test('下限 → 正左，1 倍 → 正上，上限 → 正右', () {
      expect(zoomFractionForRatio(minZoom, minZoom: minZoom, maxZoom: maxZoom),
          closeTo(0.0, 1e-9));
      expect(zoomFractionForRatio(1.0, minZoom: minZoom, maxZoom: maxZoom),
          closeTo(0.5, 1e-9));
      expect(zoomFractionForRatio(maxZoom, minZoom: minZoom, maxZoom: maxZoom),
          closeTo(1.0, 1e-9));
    });

    test('超出范围的倍率钳在两端，不会把指针画到弧外', () {
      expect(zoomFractionForRatio(99, minZoom: minZoom, maxZoom: maxZoom),
          closeTo(1.0, 1e-9));
      expect(zoomFractionForRatio(0.01, minZoom: minZoom, maxZoom: maxZoom),
          closeTo(0.0, 1e-9));
    });
  });

  group('★ 刻度：每格 0.1', () {
    test('从下限到上限，首尾都对得上', () {
      final ticks = zoomTickValues(minZoom: minZoom, maxZoom: maxZoom);
      expect(ticks.first, closeTo(0.5, 1e-9));
      expect(ticks.last, closeTo(4.0, 1e-9));
      expect(ticks.length, 36, reason: '0.5→4.0 每 0.1 一根 = 36 根');
    });

    test('★ 相邻两根正好差 0.1', () {
      // 变红配方：把 zoomTickStep 那个 `* 10` 换成 `* 5`（步长 0.2），
      // 这条立刻红（长度也变）。
      final ticks = zoomTickValues(minZoom: minZoom, maxZoom: maxZoom);
      for (var i = 1; i < ticks.length; i++) {
        expect(
          (ticks[i] - ticks[i - 1]) * 10,
          closeTo(1.0, 1e-9),
          reason: '第 $i 根与前一根不是差 0.1',
        );
      }
    });

    test('★ 不因浮点累积丢最后一格', () {
      // 0.1 在二进制里是无限循环小数，`for (v = 1; v <= 10; v += 0.1)`
      // 会少走一格。这里用「十分之一」的整数算，所以要能正好收在 10.0。
      final ticks = zoomTickValues(minZoom: 1, maxZoom: 10);
      expect(ticks.length, 91);
      expect(ticks.last, 10.0);
    });

    test('设备不能变焦（上下限都是 1）时只有一根刻度', () {
      expect(zoomTickValues(minZoom: 1, maxZoom: 1), [1.0]);
    });

    test('上限比下限还小时不炸，只给下限那一根', () {
      expect(zoomTickValues(minZoom: 2, maxZoom: 1), [2.0]);
    });
  });

  group('边界', () {
    test('手指滑到表盘左右之外，钳在两端', () {
      expect(ratioAt(-200, 60), closeTo(minZoom, 1e-9));
      expect(ratioAt(400, 60), closeTo(maxZoom, 1e-9));
    });

    test('手指落到直径下方，按左右归到最近的一端', () {
      // 规格没规定这个，但「滑出表盘」必须有确定行为 ——
      // 不然手指一沉到表盘下面，倍率就会乱跳。
      expect(ratioAt(-50, 200), closeTo(minZoom, 1e-9));
      expect(ratioAt(200, 200), closeTo(maxZoom, 1e-9));
    });

    test('表盘高度为 0 不会算出 NaN', () {
      expect(zoomRatioFor(const Offset(10, 10), const Size(120, 0)), 1);
    });

    test('★ 设备没有超广角（下限 = 1）时，左半圈划哪儿都是 1 倍', () {
      // 规格 §3.1.2 异常条款：倍率不得低于设备能力下限。
      // 这一段以前是「除 0 出 NaN」的雷区，现在两段函数各自有守卫。
      for (final x in [0.0, 30.0, 60.0]) {
        expect(zoomRatioFor(Offset(x, 20), size, maxZoom: 4), 1);
      }
      // 指针也不能跑到正上左边去。
      expect(zoomFractionForRatio(1, maxZoom: 4), 0.5);
      expect(zoomFractionForRatio(0.4, maxZoom: 4), 0.5, reason: '左半圈不存在');
    });

    test('设备只能 1 倍时，划哪儿都是 1 倍', () {
      for (final x in [0.0, 30.0, 60.0, 90.0, 120.0]) {
        expect(zoomRatioFor(Offset(x, 20), size, maxZoom: 1), 1);
      }
    });
  });

  group('★ 设备报回来的范围 → 表盘两端', () {
    test('双镜头设备：0.5 → 上限', () {
      expect(zoomRangeFrom(0.5, 4.0), (0.5, 4.0));
    });

    test('只有广角镜头：下限 1.0，左半圈是平的', () {
      expect(zoomRangeFrom(1.0, 4.0), (1.0, 4.0));
    });

    test('问不到（通道没接、相机没开）时两端各自兜底', () {
      // 上限兜底是 zoomMaxRatio，下限兜底是 1.0 —— 两者不能互相顶替：
      // 一个问不到不代表另一个也问不到。
      expect(zoomRangeFrom(null, null), (zoomMinRatio, zoomMaxRatio));
      expect(zoomRangeFrom(null, 4.0), (zoomMinRatio, 4.0));
      expect(zoomRangeFrom(0.5, null), (0.5, zoomMaxRatio));
    });

    test('★ 报了个大于 1 的下限也不认 —— 左半圈会倒着走', () {
      // 原生层理论上不会这么报，但这是**外部数据**。认了 2 的话，
      // 表盘左半圈会变成「越往左画面越小」，而右半圈从 2 起 —— 两段接不上。
      expect(zoomRangeFrom(2.0, 4.0), (zoomMinRatio, 4.0));
    });

    test('报 0 / 负数 / 非数都不认', () {
      for (final bad in [0.0, -1.0, double.nan]) {
        expect(zoomRangeFrom(bad, 4.0), (zoomMinRatio, 4.0), reason: '下限 $bad');
      }
    });

    test('★ 上下限反了也不能让下限大于上限', () {
      // `num.clamp(下限, 上限)` 在下限大于上限时**会抛** —— 而表盘里就有
      // 一句 `ratio.clamp(minZoom, maxZoom)`（`ZoomDial.build`）。
      // 这条守的就是「别把一份能把自己搞崩的范围递给表盘」。
      final (lower, upper) = zoomRangeFrom(8.0, 0.5);
      expect(lower, zoomMinRatio);
      expect(upper, zoomMaxRatio);
      expect(lower, lessThanOrEqualTo(upper));
    });

    test('★ 任何输入下都不变量都成立：0 < 下限 ≤ 1 ≤ 上限', () {
      final inputs = <double?>[null, 0.0, 0.3, 0.5, 1.0, 1.5, 2.0, 8.0, -1.0, double.nan];

      for (final min in inputs) {
        for (final max in inputs) {
          final (lower, upper) = zoomRangeFrom(min, max);
          expect(lower, greaterThan(0), reason: 'min=$min max=$max');
          expect(lower, lessThanOrEqualTo(1), reason: 'min=$min max=$max');
          expect(upper, greaterThanOrEqualTo(1), reason: 'min=$min max=$max');
          expect(lower, lessThanOrEqualTo(upper), reason: 'min=$min max=$max');
        }
      }
    });

    test('表盘拿到任何一份范围都不会在 clamp 上抛', () {
      // 上面那条不变量的**用途**在这里：`clamp(下限, 上限)` 不抛。
      for (final min in [null, 0.0, 2.0, 8.0]) {
        for (final max in [null, 0.5, 1.0, 4.0]) {
          final (lower, upper) = zoomRangeFrom(min, max);
          expect(() => 3.0.clamp(lower, upper), returnsNormally,
              reason: 'min=$min max=$max → ($lower, $upper)');
        }
      }
    });
  });

  test('★ 从左划到右是单调递增的', () {
    // 单调是「跟手」的前提：中间任何一处回跳，手感就是错的。
    var previous = 0.0;
    for (var x = 0.0; x <= 120; x += 3) {
      final ratio = ratioAt(x, 30);
      expect(ratio, greaterThanOrEqualTo(previous), reason: 'x=$x 处回跳了');
      previous = ratio;
    }
  });
}
