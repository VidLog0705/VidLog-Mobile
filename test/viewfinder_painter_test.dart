import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/camera_preview.dart';
import 'package:vidlog_mobile/scanning/viewfinder.dart';

/// 只记「画了什么」，不真画。
///
/// 取景框是 `CustomPainter` 画出来的，**没有 widget 能断言它**：
/// 宿主平台（跑测试的 Windows）没有相机，`CameraPreview` 渲染的是
/// `_PreviewUnavailable`，那棵子树根本不在树上。所以直接调 `paint`。
class _SpyCanvas implements Canvas {
  final calls = <(String, List<Object?>)>[];

  @override
  void noSuchMethod(Invocation invocation) {
    // memberName 长这样：Symbol("drawLine")
    final name = RegExp(r'"([^"]+)"')
        .firstMatch(invocation.memberName.toString())
        ?.group(1);
    if (name != null) calls.add((name, invocation.positionalArguments));
  }

  List<(String, List<Object?>)> get _lines =>
      calls.where((c) => c.$1 == 'drawLine').toList();
}

/// 一次调用里那个 [Paint]（`drawLine(from, to, paint)` 的第三个实参）。
Paint _paintOf((String, List<Object?>) call) =>
    call.$2.whereType<Paint>().single;

void main() {
  const size = Size(400, 800);
  const rect = NormalizedRect(left: 0.15, top: 0.25, width: 0.7, height: 0.4);

  _SpyCanvas paintIt() {
    final canvas = _SpyCanvas();
    const ViewfinderPainter(rect).paint(canvas, size);
    return canvas;
  }

  test('★ 取景框只有四角：不画整圈框线、也不画框外压暗（需求方 2026-09-23 裁决）',
      () {
    final canvas = paintIt();

    // 这两条挡的是「顺手把旧版加回来」—— 旧注释里压暗的理由写得挺像回事
    // （「让框内框外一眼可辨」），很容易被当成误删。
    expect(canvas.calls.where((c) => c.$1 == 'drawPath'), isEmpty,
        reason: '框外压暗是 drawPath（even-odd 挖洞）—— 照草图删掉了');
    expect(canvas.calls.where((c) => c.$1 == 'drawRect'), isEmpty,
        reason: '整圈框线是 drawRect —— 照草图删掉了');

    // 8 段 × 2 层（深色描边 + 白线）= 16
    expect(canvas.calls.where((c) => c.$1 == 'drawLine'), hasLength(16),
        reason: '四个角、每个角一横一竖，画两层');
  });

  test('★ 四角画两层，且深色那层更粗 —— 没有压暗之后，白线得自己衬自己', () {
    final lines = paintIt()._lines;

    final widths = lines.map((c) => _paintOf(c).strokeWidth).toSet();
    expect(widths, hasLength(2), reason: '两层各一个线宽');

    final white = lines
        .where((c) => _paintOf(c).color == Colors.white)
        .toList();
    final dark = lines
        .where((c) => _paintOf(c).color != Colors.white)
        .toList();
    expect(white, hasLength(8));
    expect(dark, hasLength(8));

    final whiteWidth = _paintOf(white.first).strokeWidth;
    final darkWidth = _paintOf(dark.first).strokeWidth;
    expect(darkWidth, greaterThan(whiteWidth),
        reason: '描边层不比白线粗，白线就会从描边边缘溢出去');
    expect(_paintOf(dark.first).color.computeLuminance(),
        lessThan(_paintOf(white.first).color.computeLuminance()),
        reason: '衬底那层要比白线暗，否则等于没画');

    // ⚠️ **顺序也是行为**：先描边后白线，反了白线会被盖掉一半。
    // 这里断言第一段（下标 0）是深色那层。
    expect(_paintOf(lines.first).color, isNot(Colors.white));
  });

  test('★ 四角的线段锚在框的四个角上，长度就是 armLength', () {
    final lines = paintIt()._lines;
    final frame = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );

    // 只验白线那 8 段，两层几何相同。
    final segments = lines
        .where((c) => _paintOf(c).color == Colors.white)
        .map((c) => (c.$2[0] as Offset, c.$2[1] as Offset))
        .toList();

    for (final (from, to) in segments) {
      expect((to - from).distance, closeTo(ViewfinderPainter.armLength, 0.01),
          reason: '每段都该是一根角臂');
    }

    // 八个起点两两成对地落在四个角上 —— 少一个角，框就缺一块。
    final corners = [frame.topLeft, frame.topRight, frame.bottomLeft, frame.bottomRight];
    for (final corner in corners) {
      expect(segments.where((s) => s.$1 == corner), hasLength(2),
          reason: '$corner 这个角不是一横一竖两段');
    }
  });
}
