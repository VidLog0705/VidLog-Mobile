import '../primitives.dart';

/// 喂给停录状态机的事件。
///
/// **所有事件都带单调时钟毫秒值**（规格 §3.6.3、不变量 I11）——
/// 用户改系统时间不得影响任何判定，所以这里不接受墙钟。
sealed class RecorderEvent {
  const RecorderEvent(this.monotonicMs);

  final int monotonicMs;
}

/// 心跳。用来驱动那些「时间到了就发生」的判定（静止、时长兜底）。
///
/// 没有它的话，画面完全不动时就没有任何事件，静止超时永远不会被触发。
final class Heartbeat extends RecorderEvent {
  const Heartbeat(super.monotonicMs);
}

/// 识别到一个单号（开录或复扫）。
final class WaybillDetected extends RecorderEvent {
  const WaybillDetected(super.monotonicMs, this.waybill);

  final WaybillNumber waybill;
}

/// 画面采样结果。原生层按固定间隔上报。
final class SceneSampled extends RecorderEvent {
  const SceneSampled(super.monotonicMs, {required this.isStatic});

  /// 画面是否「连续无显著变化」（规格 §1 术语表）。
  final bool isStatic;
}

/// 被追踪的包裹离开取景框。
///
/// 由 [PackageTracker] 产出（**在 Dart 里**，不由原生上报）——
/// 判据是「多久没再见到那个条码」，由心跳驱动。见 `package_tracker.dart`。
final class TrackedPackageLeft extends RecorderEvent {
  const TrackedPackageLeft(super.monotonicMs);
}

/// 被追踪的包裹重新进入取景框（同上，由 [PackageTracker] 产出）。
final class TrackedPackageEntered extends RecorderEvent {
  const TrackedPackageEntered(super.monotonicMs);
}

/// 用户对时长兜底的询问做了回应。
final class DurationPromptAnswered extends RecorderEvent {
  const DurationPromptAnswered(super.monotonicMs, {required this.continueRecording});

  /// true = 点「继续」；false = 点「停止」。
  final bool continueRecording;
}

/// 用户主动要求停止。
final class ManualStopRequested extends RecorderEvent {
  const ManualStopRequested(super.monotonicMs);
}

/// 停录的原因。与电脑端的 `StopReason` 对应（母仓 `docs/02-数据模型.md` §3.1）。
enum StopTrigger {
  /// 用户主动停止。
  manual,

  /// 复扫到同一单号（规格 §3.3.2）。
  sameWaybillRescan,

  /// 画面静止超时（规格 §3.3.3）。
  sceneStatic,

  /// 时长兜底（规格 §3.3.4）。
  durationFallback,

  /// 设备资源告警，主动安全收尾（规格 §3.1.1）。
  resourceCritical,

  /// 进程被杀 / 掉电后，重启时的孤儿收尾（规格 §3.1.1）。
  processKilled,

  /// 连续扫：扫到一个**别的**单号 = 换件（规格 §3.3.1 的 2026-09-22 需求变更）。
  /// 上一段到此为止（收尾入库），下一段紧接着以新单号开录。
  ///
  /// 追加在末尾而不是插在同码复扫旁边：**枚举顺序是别人读得懂的东西**，
  /// 中途插值会让「按序号存过的东西」静默错位。这里没有任何地方按序号存它
  /// （`reason` 只在 `FinalizeOutcome` 里走，从不落盘），但规矩照旧。
  nextWaybill,
}

/// 要播放的语音提示。
///
/// 措辞**直接来自规格原文**（§3.3.2 / §3.3.4），写在这里一处，
/// 播报与界面日志都取它 —— 两处各写一遍的话，改了一处就慢慢说岔了。
enum VoicePrompt {
  /// 规格 §3.3.2：扫到不同面单时提示「面单不同」。
  differentWaybill('面单不同'),

  /// 规格 §3.3.4：「录制时间即将超时，是否需要停止录制？」
  durationTimeout('录制时间即将超时，是否需要停止录制？');

  const VoicePrompt(this.spokenText);

  /// 读出来的原文。
  final String spokenText;
}

/// 状态机要宿主执行的动作。
sealed class RecorderAction {
  const RecorderAction();
}

final class StartRecording extends RecorderAction {
  const StartRecording();
}

final class StopRecording extends RecorderAction {
  const StopRecording(this.trigger);

  final StopTrigger trigger;
}

final class Speak extends RecorderAction {
  const Speak(this.prompt);

  final VoicePrompt prompt;
}

/// 显示时长兜底的两个按钮【停止】【继续】。
final class ShowDurationPrompt extends RecorderAction {
  const ShowDurationPrompt();
}

final class HideDurationPrompt extends RecorderAction {
  const HideDurationPrompt();
}

