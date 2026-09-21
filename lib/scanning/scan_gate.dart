import '../primitives.dart';
import 'viewfinder.dart';

/// 原生层报来的一次识码。
///
/// 坐标是**归一化**的（0~1）、**原点在左上** —— 与 [Viewfinder] 的约定一致。
/// 原生层负责把各自框架的坐标系换算过来（iOS 的 Vision 原点在左下，要翻 y）。
class BarcodeSighting {
  const BarcodeSighting({
    required this.text,
    required this.centerX,
    required this.centerY,
    this.confidence = 1.0,
  });

  final String text;
  final double centerX;
  final double centerY;
  final double confidence;

  @override
  String toString() => 'BarcodeSighting($text @ $centerX,$centerY)';
}

/// 把「连续识码」变成「一次次扫码」。
///
/// ## 为什么需要这一层
///
/// 相机是**连续**识码的：包裹一直摆在取景框里，同一单号每秒会被识别好几次。
/// 而「同码停」模式的规则是**复扫**到同一单号才停（规格 §3.3.1）。
/// 照字面把每一次识码都当成一次「扫码」，会出现两个后果：
///
/// - 包裹一放上去，开录后**立刻被自己的持续识别停掉**
/// - 错码保护会对着同一个包裹反复播「面单不同」
///
/// 所以「连续识码」必须先变成「离散的扫码事件」。这个转换有确定的规则，
/// 所以它是一层**可测的纯逻辑**，而不是散在原生回调里的 if。
///
/// ## 判定规则
///
/// 一次识码被当作「新的扫码」，当且仅当：
///
/// 1. **它的中心点落在取景框内**（规格 §3.2.2：框外一律忽略）
/// 2. **同一个单号已经[消失][absenceThreshold]了足够久**
///
/// 第 2 条的实现要点：**每次看见都要刷新「最后见到」的时刻，包括被抑制的那些**。
/// 否则持续摆在画面里的包裹会每过一个阈值就被重新报一次。
///
/// 换句话说：**「复扫」= 拿开一会儿再放回来**。这与规格里
/// 「同码离场后再入场」的描述是同一件事。
class ScanGate {
  ScanGate({
    Viewfinder? viewfinder,
    this.absenceThreshold = const Duration(seconds: 2),
  }) : viewfinder = viewfinder ?? Viewfinder.forPreset(
          ViewfinderPreset.medium,
          aspectRatio: 3 / 4, // 竖屏持机
        );

  /// 取景框：只有中心点在它里面的识码才会被采纳。
  final Viewfinder viewfinder;

  /// 同一单号要「消失」多久，才把下一次看见算作新的扫码。
  ///
  /// 取 2 秒：比人手拿开再放回短，比相机一帧的间隔长得多。
  /// 太短会在包裹抖动、识别短暂丢失时误判成复扫；太长则复扫要等。
  final Duration absenceThreshold;

  /// 每个单号最后一次被看见的单调毫秒时刻。
  final Map<String, int> _lastSeenAtMs = {};

  /// 喂一次识码；算作「新的扫码」时返回归一化后的单号，否则返回 null。
  WaybillNumber? accept(BarcodeSighting sighting, int monotonicMs) {
    // 规格 §3.2.2：框外一律忽略，防止扫到画面里其他包裹的面单。
    final inFrame = viewfinder.rect.containsPoint(sighting.centerX, sighting.centerY);
    if (!inFrame) {
      return null;
    }

    final waybill = WaybillNumber.tryParse(sighting.text);
    if (waybill == null) {
      return null;
    }

    final key = waybill.value;
    final lastSeen = _lastSeenAtMs[key];

    // **无论是否上报，都要刷新「最后见到」** —— 这是这个类最容易写错的一行。
    // 不刷新的话，持续摆在画面里的包裹会每过一个阈值被重新报一次。
    _lastSeenAtMs[key] = monotonicMs;

    if (lastSeen != null && monotonicMs - lastSeen < absenceThreshold.inMilliseconds) {
      return null; // 还在画面里，不是复扫
    }

    return waybill;
  }

  /// 把某个单号标记为「刚刚见过」。
  ///
  /// **开录时必须调。** 开录用的那个单号此刻就在操作员手上、就在画面里；
  /// 不标记的话，相机会把它报成一次「复扫」，**录制当场被停掉** ——
  /// 表现是「一扫就停，一秒都录不到」。
  ///
  /// 触发这条的路径有两条：手输单号点开始、以及首次扫到单号。
  void markSeen(WaybillNumber waybill, int monotonicMs) {
    _lastSeenAtMs[waybill.value] = monotonicMs;
  }

  /// 清空「最后见到」记录。换会话 / 换模式时调。
  void reset() => _lastSeenAtMs.clear();

  /// 某个单号当前是否还在画面上（按阈值判断）。
  bool isStillVisible(String waybill, int monotonicMs) {
    final lastSeen = _lastSeenAtMs[waybill];
    if (lastSeen == null) return false;
    return monotonicMs - lastSeen < absenceThreshold.inMilliseconds;
  }
}
