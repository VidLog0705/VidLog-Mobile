import '../primitives.dart';
import 'recorder_events.dart';

/// 跟踪「开录用的那件包裹」还在不在取景框里（规格 §3.3.1 扫码静止停录）。
///
/// 产出 [TrackedPackageLeft] / [TrackedPackageEntered] 两个事件，
/// 停录状态机只消费事件 —— 所以「离场 → 入场 → 静止 → 停」这条链
/// 在 Dart 里能完整测到，不用真机。
///
/// ## 为什么跟踪的是「那个条码还在不在」而不是像素
///
/// 规格原文是「同码**离场**后再入场」。这里要的是**认出离开的是哪个东西**，
/// 而像素差分给不出这个 —— 画面里换一个包裹、或者有人走过，差分都会说「变了」。
/// 条码的同一性天然就是「哪个东西」的答案，而相机本来就在持续识码。
///
/// 代价：面单被挡住（比如翻面、手压住）也算「离场」。这是可接受的 ——
/// 用户要停录本来就得把包裹放下、让面单朝上；而认错的后果只是
/// 「多等一次入场」，不是误停。
///
/// ## 离场判据用的是「多久没见到」
///
/// 相机只报「见到了什么」，不报「没见到什么」，所以离场只能靠
/// **时间上的缺席**推出来（见 [onTick]，由心跳驱动）。
/// 阈值取得与 `ScanGate` 的复扫阈值一样：两者其实是同一件物理事实
/// （「包裹拿开了一会儿」），用两个数只会让它们慢慢走岔。
class PackageTracker {
  PackageTracker({this.absenceThreshold = defaultAbsenceThreshold});

  /// 多久没见到就算离场。
  ///
  /// 不能太短：相机偶尔会漏一帧（抖动、反光），漏一帧就报离场的话，
  /// 静止时钟会被反复重置，**这个模式就永远停不下来** ——
  /// 那不是「更安全」，是把功能弄没了。
  static const defaultAbsenceThreshold = Duration(seconds: 2);

  final Duration absenceThreshold;

  WaybillNumber? _tracked;
  int? _lastSeenAtMs;
  bool _left = false;

  /// 当前在跟踪的单号；没在录时为 null。
  WaybillNumber? get tracked => _tracked;

  /// 是否已经报过「离场」（还没等到入场）。
  bool get hasLeft => _left;

  /// 开录时指定要跟踪的那件包裹。
  ///
  /// **开录那一刻必须调**：不调的话第一次识码会被当成「入场」，
  /// 而状态机那边还没发生过离场 —— 事件顺序错了，静止门槛就永远开着。
  void track(WaybillNumber waybill, int monotonicMs) {
    _tracked = waybill;
    _lastSeenAtMs = monotonicMs;
    _left = false;
  }

  void reset() {
    _tracked = null;
    _lastSeenAtMs = null;
    _left = false;
  }

  /// 看到一次识码。返回这次识码产生的跟踪事件（没有就是 null）。
  ///
  /// **必须每次识码都调**，不能只调 `ScanGate` 放行的那几次 ——
  /// 闸要的是「离散的一次扫码」（持续识码会被抑制掉），
  /// 而跟踪要的是「这一刻它还在不在画面里」。
  ///
  /// 别的单号一概不影响：错码保护下扫到 B 时，A 的离场时钟不能被重置。
  RecorderEvent? onSighting(WaybillNumber? waybill, int monotonicMs) {
    final tracked = _tracked;
    if (tracked == null || waybill == null || waybill != tracked) return null;

    _lastSeenAtMs = monotonicMs;

    if (!_left) return null;

    // 离场之后又见到了 —— 这才是「入场」。
    _left = false;
    return TrackedPackageEntered(monotonicMs);
  }

  /// 时间推进一次（心跳驱动）。返回「离场」事件（没有就是 null）。
  RecorderEvent? onTick(int monotonicMs) {
    final lastSeen = _lastSeenAtMs;
    if (_tracked == null || lastSeen == null || _left) return null;

    if (monotonicMs - lastSeen < absenceThreshold.inMilliseconds) return null;

    _left = true;
    return TrackedPackageLeft(monotonicMs);
  }
}
