import 'dart:math';

import 'package:flutter/material.dart';

/// 表盘的**兜底**上限。
///
/// 真正的上限是设备能力（iOS 的 `maxAvailableVideoZoomFactor`、
/// Android 的 `CONTROL_ZOOM_RATIO_RANGE`），由 `RecorderGateway.maxZoom`
/// 在相机开起来之后问出来 —— 这个常量只在问不到时用。
///
/// 兜底值是 8 而不是 2：问不到时（设备还没报能力、通道没接上）
/// 表盘划不到头比划得过头更烦人，而**过头也不会有实际后果** ——
/// 两端原生的 `setZoom` 都自己钳过（规格 §3.1.2 要的正是那一道）。
const zoomMaxRatio = 8.0;

/// 把一个触点在表盘里的位置换成倍率。
///
/// 圆心在**底边中点**，表盘是圆的上半部分：
/// 正左 = 最小倍率，正上 = 中间，正右 = 最大倍率。
///
/// 触点落在直径下方时按 x 归到最近的一端（规格没规定，但「手指滑出表盘」
/// 必须有确定的行为，不然一滑出就会跳变）。
double zoomRatioFor(Offset local, Size size, {double maxZoom = zoomMaxRatio}) {
  final centerX = size.width / 2;
  final radius = size.height;

  if (radius <= 0) return 1;

  // 向上为正；落在直径下方时压成 0，于是 atan2 只会给出上半圆的角度。
  final dx = local.dx - centerX;
  final dy = max(size.height - local.dy, 0.0);

  // atan2 在正右是 0、正上是 π/2、正左是 π，所以要翻过来。
  final t = ((pi - atan2(dy, dx)) / pi).clamp(0.0, 1.0);

  return 1 + t * (maxZoom - 1);
}

/// 半圆刻度盘（规格 §3.1.2）。
///
/// 「屏幕边缘的半圆刻度盘」—— 手指沿弧滑动调倍率。
/// 值本身由调用方持有（规格要的是「在本次工作期间保持」）。
class ZoomDial extends StatelessWidget {
  const ZoomDial({
    super.key,
    required this.ratio,
    required this.onChanged,
    this.maxZoom = zoomMaxRatio,
    this.width = 120,
  });

  final double ratio;
  final ValueChanged<double> onChanged;
  final double maxZoom;

  /// 表盘直径。高度是它的一半（半圆）。
  final double width;

  @override
  Widget build(BuildContext context) {
    final size = Size(width, width / 2);
    final clamped = ratio.clamp(1.0, maxZoom).toDouble();

    return SizedBox(
      width: size.width,
      height: size.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) =>
            onChanged(zoomRatioFor(details.localPosition, size, maxZoom: maxZoom)),
        onPanUpdate: (details) =>
            onChanged(zoomRatioFor(details.localPosition, size, maxZoom: maxZoom)),
        child: CustomPaint(
          painter: _ZoomDialPainter(
            ratio: clamped,
            maxZoom: maxZoom,
            color: Theme.of(context).colorScheme.primary,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${clamped.toStringAsFixed(1)}x',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomDialPainter extends CustomPainter {
  _ZoomDialPainter({
    required this.ratio,
    required this.maxZoom,
    required this.color,
  });

  final double ratio;
  final double maxZoom;
  final Color color;

  /// 每 1 倍一根刻度。至少一根 —— 设备报「不能变焦」时会是 1。
  int get _steps => maxZoom.floor().clamp(1, 64);

  /// 刻度覆盖的倍率跨度。设备只能 1 倍时是 0。
  double get _span => maxZoom - 1;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height);
    final radius = size.height;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color.withValues(alpha: 0.25);

    // canvas 的角度从 +x 起、顺时针为正（y 轴向下），
    // 所以「圆的上半部分」是 π 到 2π。
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      pi,
      pi,
      false,
      track,
    );

    // 设备不支持变焦（上限就是 1）。只画那道弧 —— 不再画指针：
    // 除以 0 会算出 NaN，画出来的是一条飘在画面外的东西。
    if (_span <= 0) return;

    final tick = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.35);

    for (var i = 0; i <= _steps; i++) {
      final angle = pi + pi * i / _steps;
      final direction = Offset(cos(angle), sin(angle));
      canvas.drawLine(
        center + direction * (radius - 6),
        center + direction * radius,
        tick,
      );
    }

    // 当前倍率的那一根：画粗、上色。
    final t = ((ratio - 1) / _span).clamp(0.0, 1.0);
    final angle = pi + pi * t;
    final direction = Offset(cos(angle), sin(angle));

    canvas.drawLine(
      center + direction * (radius - 12),
      center + direction * radius,
      Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ZoomDialPainter old) =>
      old.ratio != ratio || old.maxZoom != maxZoom || old.color != color;
}
