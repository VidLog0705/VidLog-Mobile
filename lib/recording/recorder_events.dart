import '../primitives.dart';
import 'recorder_config.dart';

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

/// 设备资源状况上报（规格 §3.1.1）。
///
/// 三个量**都可空**：原生那边可能只读得出其中几个（比如模拟器没有电池、
/// 某些设备读不到热状态）。**缺的那个不参与判定** —— 不是「当成 0」，
/// 那会让「读不到」变成「告警」或「永远不告警」。
///
/// ⚠️ 它 2026-09-21 被删过（「原生从没上报过电量/温度/存储」，整条链不可达），
/// 2026-09-27 连同原生生产者一起恢复 —— 见 `实现决策.md` §44。
final class ResourceReported extends RecorderEvent {
  const ResourceReported(
    super.monotonicMs, {
    this.freeStorageBytes,
    this.batteryPercent,
    this.thermal,
  });

  final int? freeStorageBytes;
  final int? batteryPercent;
  final ThermalLevel? thermal;
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
  /// 规格 §3.3.2：扫到不同面单时提示。
  ///
  /// 措辞是需求方 2026-09-22 晚些给的原话（原来是「面单不同」）——
  /// 他要的是**告诉操作员下一步该干什么**，不是陈述「这两张不一样」。
  differentWaybill('面单错误，请扫描正确面单'),

  /// 规格 §3.3.4：「录制时间即将超时，是否需要停止录制？」
  durationTimeout('录制时间即将超时，是否需要停止录制？'),

  /// 规格 §3.1.1：存储将满 / 低电量 / 过热（提前告警，并主动安全收尾）。
  ///
  /// ⚠️ 措辞说「已停止」而不是「即将停止」：这一句是在**收尾动作之后**播的
  /// （见 `StopController._onResource` 那个动作序列），说「即将」会让操作员
  /// 以为还有时间去看一眼屏幕 —— 而那时已经在收了。
  resourceWarning('设备资源告警，已停止录像'),

  /// 规格 §3.3.6：识别到单号开录、以及连续扫换段时开下一段。
  ///
  /// ⚠️ 换段**只播这一句**，不播上一段的「停止录像」——
  /// 换件是正常路径，一句「停止」接着一句「开始」只会让人以为录断了。
  startRecording('开始录像'),

  /// 规格 §3.3.6：复扫到同一单号、停录。
  ///
  /// ⚠️ **只有这一条停录会出声**。画面静止（§3.3.3）与时长兜底（§3.3.4）
  /// 两条自动停是刻意不播的（规格 §3.3.6 的约束）—— 那两条收尾时
  /// 用户多半已经走开，补一句只会像设备在自言自语。
  stopRecording('停止录像'),

  /// 规格 §3.3.6：用户点了【开始】。
  ///
  /// ⚠️ 这两句用的是「**工作**」不是「录像」，是刻意的：点【开始】之后
  /// 相机只是开着，**还没扫到面单、还没在录**。说「开始录像」是假话。
  startWorking('开始工作'),

  /// 规格 §3.3.6：用户点了【结束】（同上）。
  stopWorking('停止工作'),

  /// 进发货栏时播报（需求方 2026-09-22）。
  ///
  /// ⚠️ 这一条**不由状态机产出** —— 它的起因是「用户切了栏」，
  /// 那不是一个录制事件。走 `RecordingCoordinator.speak()` 直接发。
  shippingModeOn('发货模式开启'),

  /// 进退货栏时播报（同上）。
  returnModeOn('退货模式开启');

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
  const Speak(this.prompt, {this.beep = false});

  final VoicePrompt prompt;

  /// 开口之前先「滴」一声（规格 §3.3.6）。
  ///
  /// 做成**可选标记**而不是「所有播报都滴」：规格那张表里六行有三行要滴、
  /// 三行不要（手动开始/结束、时长兜底、两条自动停）。写死成默认值
  /// 就得在每处再关一遍，「关」比「开」更容易漏。
  ///
  /// 滴声与语音是**两个不同的音**（同一个音分不出「系统认了」和「系统在说话」），
  /// 且都必须来自系统内置 —— 规格 §3.3.6 禁止引入任何音频素材文件。
  final bool beep;
}

/// 显示时长兜底的两个按钮【停止】【继续】。
final class ShowDurationPrompt extends RecorderAction {
  const ShowDurationPrompt();
}

final class HideDurationPrompt extends RecorderAction {
  const HideDurationPrompt();
}

/// 设备资源告警（规格 §3.1.1）：让用户看见「为什么突然停了」。
///
/// ⚠️ 它与 [Speak] 是**两件事**：语音说过就没了，而这一条要在**屏幕上留着**
/// —— 操作员错过那一句语音时，至少能从界面上看出「刚才是因为过热停的」。
///
/// ⚠️ 它原来叫 `WarnResource`（2026-09-21 那次审计里被 `onNativeFailure` 取代，
/// 而 `onNativeFailure` 是给**原生失败**用的另一件事）。2026-09-27 恢复资源告警
/// 时按原样重建 —— 名字、字段（`reason`）都与当初一致。
final class WarnResource extends RecorderAction {
  const WarnResource(this.reason);

  /// 「存储将满 / 电量过低 / 设备过热」里命中的那几个，用「、」连起来。
  final String reason;
}

