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

/// 表盘**兜底**下限：1 倍 = 广角镜头本来的视野。
///
/// **左半圈（比初始画面更广）只有设备有超广角镜头时才存在。**
/// 设备最小倍率就是 1 时报 1，此时左半圈滑了也是 1 倍 ——
/// 规格 §3.1.2 的异常条款：「不得低于设备能力下限」。
const zoomMinRatio = 1.0;

/// 刻度步长（倍率）。规格 §3.1.2：「每个刻度 0.1」。
const zoomTickStep = 0.1;

/// 触点落在表盘的哪个位置。**0 = 正左，0.5 = 正上，1 = 正右。**
///
/// 圆心在**底边中点**，表盘是圆的上半部分（规格 §3.1.2 的「半圆刻度盘」）。
/// 触点落在直径下方时按 x 归到最近的一端（规格没规定，但「手指滑出表盘」
/// 必须有确定的行为，不然一滑出就会跳变）。
double zoomFractionForTouch(Offset local, Size size) {
  final radius = size.height;
  if (radius <= 0) return 0.5;

  // 向上为正；落在直径下方时压成 0，于是 atan2 只会给出上半圆的角度。
  final dx = local.dx - size.width / 2;
  final dy = max(size.height - local.dy, 0.0);

  // atan2 在正右是 0、正上是 π/2、正左是 π，所以要翻过来。
  return ((pi - atan2(dy, dx)) / pi).clamp(0.0, 1.0);
}

/// 弧上的位置 → 倍率。**两段各自线性**，转折点在正上（1 倍）。
///
/// 为什么是两段而不是一根直线：规格 §3.1.2 同时要求
/// 「**正中为 0**（= 初始画面）」和「每个刻度 0.1」，
/// 而设备真实范围是**不对称**的（左半边只有 `下限→1`，右半边 `1→上限`）。
/// 一根直线满足不了「正上正好是 1 倍」。
///
/// 于是两半**各自**都是每 0.1 一格，但两半之间疏密不同：
/// 左半圈格数少（0.5→1 只有 5 格），看上去比右半圈稀。
/// **那是设备范围的形状，不是画错。**
double zoomRatioForFraction(
  double t, {
  double minZoom = zoomMinRatio,
  double maxZoom = zoomMaxRatio,
}) {
  final clamped = t.clamp(0.0, 1.0);

  // 左半圈：下限 → 1 倍。设备没有超广角时 minZoom 就是 1，这一半是平的。
  if (clamped <= 0.5) return minZoom + (clamped / 0.5) * (1 - minZoom);

  final k = (clamped - 0.5) / 0.5;
  return 1 + k * (maxZoom - 1);
}

/// 触点 → 倍率。给手势用。
double zoomRatioFor(
  Offset local,
  Size size, {
  double minZoom = zoomMinRatio,
  double maxZoom = zoomMaxRatio,
}) =>
    zoomRatioForFraction(
      zoomFractionForTouch(local, size),
      minZoom: minZoom,
      maxZoom: maxZoom,
    );

/// 倍率 → 弧上的位置（画指针用）。[zoomRatioForFraction] 的反函数。
double zoomFractionForRatio(
  double ratio, {
  double minZoom = zoomMinRatio,
  double maxZoom = zoomMaxRatio,
}) {
  if (ratio <= 1) {
    // 设备没有超广角（下限就是 1）：左半圈不存在，指针停在正上。
    if (minZoom >= 1) return 0.5;
    return 0.5 * ((ratio - minZoom) / (1 - minZoom)).clamp(0.0, 1.0);
  }

  if (maxZoom <= 1) return 0.5;
  return 0.5 + 0.5 * ((ratio - 1) / (maxZoom - 1)).clamp(0.0, 1.0);
}

/// 表盘上所有刻度的**倍率值**：从下限到上限，每 [zoomTickStep] 一根。
///
/// 用「十分之一」的整数算，避免 0.1 的浮点累积误差把最后一格算丢
/// （0.1 在二进制里是无限循环小数，累加 40 次能偏出一格）。
List<double> zoomTickValues({
  double minZoom = zoomMinRatio,
  double maxZoom = zoomMaxRatio,
}) {
  final lo = (minZoom * 10).round();
  final hi = (maxZoom * 10).round();
  if (hi <= lo) return [lo / 10];

  return [for (var tenth = lo; tenth <= hi; tenth++) tenth / 10];
}

/// 半圆刻度盘（规格 §3.1.2）。
///
/// 手指沿弧滑动调倍率。值本身由调用方持有（规格要的是「在本次工作期间保持」）。
///
/// [onEnd] 在手指抬起时触发 —— 调用方用它补一次对焦
/// （滑动过程中是节流着对焦的，抬起来那一下才是最终位置）。
class ZoomDial extends StatelessWidget {
  const ZoomDial({
    super.key,
    required this.ratio,
    required this.onChanged,
    this.onEnd,
    this.minZoom = zoomMinRatio,
    this.maxZoom = zoomMaxRatio,
    this.width = 240,
  });

  final double ratio;
  final ValueChanged<double> onChanged;
  final VoidCallback? onEnd;
  final double minZoom;
  final double maxZoom;

  /// 表盘直径。高度是它的一半（半圆）。
  final double width;

  @override
  Widget build(BuildContext context) {
    final size = Size(width, width / 2);
    final clamped = ratio.clamp(minZoom, maxZoom).toDouble();

    return SizedBox(
      width: size.width,
      height: size.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => onChanged(
          zoomRatioFor(details.localPosition, size,
              minZoom: minZoom, maxZoom: maxZoom),
        ),
        onPanUpdate: (details) => onChanged(
          zoomRatioFor(details.localPosition, size,
              minZoom: minZoom, maxZoom: maxZoom),
        ),
        onPanEnd: (_) => onEnd?.call(),
        child: CustomPaint(
          painter: _ZoomDialPainter(
            ratio: clamped,
            minZoom: minZoom,
            maxZoom: maxZoom,
            color: Theme.of(context).colorScheme.primary,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              // 显示的是**绝对倍率**，不是刻度上那个相对值 ——
              // 那是相机真正在做的事，用户问「现在多少倍」时问的也是它。
              // 刻度是相对的（正中 0 = 初始），两者分工不同。
              child: Text(
                '${clamped.toStringAsFixed(1)}x',
                // 颜色写死不跟主题：表盘压在**取景画面**上（页面那层深色遮罩），
                // 跟主题走的话浅色主题下会是一行黑字压在暗画面上，看不见。
                // ⚠️ 整块表盘此前**一次都没上过真机**（widget 测试里相机起不来），
                // 这里按「深色遮罩」这个已知前提定死，真机上看不清再改。
                style: const TextStyle(fontSize: 12, color: Colors.white70),
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
    required this.minZoom,
    required this.maxZoom,
    required this.color,
  });

  final double ratio;
  final double minZoom;
  final double maxZoom;
  final Color color;

  static const _minorLength = 5.0;
  static const _majorLength = 10.0;

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

    final minor = Paint()
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.3);

    final major = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55);

    for (final value in zoomTickValues(minZoom: minZoom, maxZoom: maxZoom)) {
      final fraction = zoomFractionForRatio(value, minZoom: minZoom, maxZoom: maxZoom);
      final angle = pi + pi * fraction;
      final direction = Offset(cos(angle), sin(angle));

      // 整倍数的刻度画长一点 —— 一眼能看出「现在大概在哪一档」。
      // 判据用「乘以 10 是不是整十」，躲开浮点误差。
      final isMajor = (value * 10).round() % 10 == 0;
      final length = isMajor ? _majorLength : _minorLength;

      canvas.drawLine(
        center + direction * (radius - length),
        center + direction * radius,
        isMajor ? major : minor,
      );
    }

    // 正上方那根：**刻度 0 = 初始画面**（规格 §3.1.2）。
    // 没有它，用户没法知道「中间是哪个数」—— 光看一根弧看不出来。
    _paintZeroLabel(canvas, center, radius);

    // 当前倍率的那一根：画粗、上色。
    final markerAngle = pi + pi * zoomFractionForRatio(
      ratio,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
    final markerDirection = Offset(cos(markerAngle), sin(markerAngle));

    canvas.drawLine(
      center + markerDirection * (radius - 14),
      center + markerDirection * radius,
      Paint()
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  void _paintZeroLabel(Canvas canvas, Offset center, double radius) {
    final painter = TextPainter(
      text: const TextSpan(
        text: '0',
        style: TextStyle(fontSize: 11, color: Colors.white70),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // 正上方，往圆心方向让开刻度线。
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - radius + _majorLength + 2),
    );
  }

  @override
  bool shouldRepaint(_ZoomDialPainter old) =>
      old.ratio != ratio ||
      old.minZoom != minZoom ||
      old.maxZoom != maxZoom ||
      old.color != color;
}
