/// 归一化的矩形。坐标是 0~1 的画面比例，**不是像素** ——
/// 这样取景框不会因为设备分辨率或预览尺寸变化而失准。
class NormalizedRect {
  const NormalizedRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;

  /// 点是否落在矩形内（含边界）。
  bool containsPoint(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  /// 与另一个矩形是否完全不相交。
  bool isDisjointFrom(NormalizedRect other) =>
      right <= other.left || other.right <= left || bottom <= other.top || other.bottom <= top;
}

/// 取景框预设档位。规格 §3.2.2：框的大小可由用户调整（至少提供预设档位）。
enum ViewfinderPreset {
  small(0.50),
  medium(0.70),
  large(0.88);

  const ViewfinderPreset(this.span);

  /// 框占画面短边的比例。
  final double span;

  static const fallback = ViewfinderPreset.medium;

  /// 居中、**像素上是正方形**的框。
  ///
  /// [aspectRatio] 是画面宽 / 画面高。
  ///
  /// ⚠️ **横竖屏要分开算**，这是踩过的坑：
  /// 归一化坐标里「正方形」的宽高并不相等 —— 边长 S 像素的框，
  /// 归一化宽 = S/画面宽，归一化高 = S/画面高，两者差一个 [aspectRatio]。
  ///
  /// 只按「高 = span、宽 = span/aspect」算的话，**竖屏（aspect &lt; 1）时宽会超过 1**，
  /// 框比画面还宽 —— 表现是「框外忽略」形同虚设，画面里的码全被认。
  /// 而手机正是竖着拿的。
  NormalizedRect rectOn({required double aspectRatio}) {
    // 用**正向**判断而不是 `<= 0`：后者对 NaN 是 false，会把 NaN 一路传下去
    // 算出 NaN 宽高（测试抓到的）。
    final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1.0;

    // 让**较长的那一边**占 span，较短的按比例缩 —— 这样两个归一化值都不超过 span ≤ 1。
    final double width;
    final double height;

    if (ratio >= 1) {
      // 横屏：宽是长边
      height = span;
      width = span / ratio;
    } else {
      // 竖屏：高是长边
      width = span;
      height = span * ratio;
    }

    return NormalizedRect(
      left: (1 - width) / 2,
      top: (1 - height) / 2,
      width: width,
      height: height,
    );
  }
}

/// 一次识码结果（原生层产出）。
class BarcodeDetection {
  const BarcodeDetection({
    required this.rect,
    required this.text,
    this.confidence = 1.0,
  });

  /// 面单在画面里的位置。
  final NormalizedRect rect;

  /// 条码内容原文。
  final String text;

  /// 识码置信度，0~1。
  final double confidence;
}

/// 取景框判定。
///
/// 规格 §3.2.2：
/// > 画面出现**可见的取景框**；**只有框内的面单会被识别，框外一律忽略**。
/// > 结果：防止扫到画面里其他包裹的面单。
///
/// ## 判据
///
/// **检测框的中心点落在取景框内**即接受。
///
/// 为什么是中心点而不是「整框都在里面」：面单举得离镜头近时，边角常常探出框外，
/// 要求整框在内会让用户反复调整距离 —— 那正是这个功能最不该造成的负担。
/// 而规格要防的是「画面里**其他包裹**的面单」，那些的中心点天然在框外，中心判据足够。
///
/// 为什么不是「重叠面积过半」：面积判据在面单只露出一角时行为不稳定，
/// 而中心点在几何上更好解释、也更好测。
class Viewfinder {
  const Viewfinder({required this.rect});

  /// 按预设档位构造一个居中的框。
  factory Viewfinder.forPreset(ViewfinderPreset preset, {required double aspectRatio}) =>
      Viewfinder(rect: preset.rectOn(aspectRatio: aspectRatio));

  final NormalizedRect rect;

  /// 这次识码是否应当被采纳。
  bool accepts(BarcodeDetection detection) => acceptsRect(detection.rect);

  bool acceptsRect(NormalizedRect detection) =>
      rect.containsPoint(detection.centerX, detection.centerY);

  /// 过滤一批识码结果，只留下框内的。
  List<BarcodeDetection> filter(Iterable<BarcodeDetection> detections) =>
      detections.where(accepts).toList(growable: false);
}
