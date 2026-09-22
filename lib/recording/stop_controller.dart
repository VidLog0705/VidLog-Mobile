import '../primitives.dart';
import 'recorder_config.dart';
import 'recorder_events.dart';
import 'work_mode.dart';

/// 停录决策状态机。
///
/// 规格 §3.3 是「本系统**行为最复杂、也最容易出错**的部分」，所以它被单独实现成
/// 一个对事件流的纯状态机 —— 不碰相机、不碰 UI、不碰网络。
///
/// ## 它只吃本地可观测的事实
///
/// 规格 §3.3.5：
/// > 任何自动停录机制都不得因为网络、配置、服务端异常而提前触发。
/// > 停录判断只依赖本地可观测的事实（画面、时长、扫码）。
///
/// 本类的输入只有 [RecorderEvent]（扫码、画面、追踪、心跳），
/// **没有任何一个事件来自网络** —— 这是结构上的保证，不是约定。
///
/// ## 三种停录机制
///
/// | 机制 | 规格 | 在哪些模式下生效 |
/// |---|---|---|
/// | 同码复扫 | §3.3.2 | 同码停、扫码静止停录 |
/// | 画面静止 | §3.3.3 | 全部（可设为「关闭」） |
/// | 时长兜底 | §3.3.4 | 全部（**可设为「关闭」**） |
///
/// **两项防忘停录各自独立可选**：静止档位关掉不会连带关掉时长兜底，反之亦然。
/// （规格原文写的是时长兜底「对所有档位生效（含关闭）」，后来改成可选 ——
/// 因为它会在每次录制超过设定分钟数时打断正常的长录制。）
///
/// 「扫码静止停录」比其余模式多一个门槛：静止计时只在
/// **同码包裹离场、再入场之后**才开始（[WorkMode.staticStopRequiresPackageReturn]）。
class StopController {
  StopController({
    required this.mode,
    this.config = RecorderConfig.hardFallback,
  });

  final WorkMode mode;
  final RecorderConfig config;

  bool _recording = false;
  WaybillNumber? _waybill;
  int _startedAtMs = 0;

  /// 画面最近一次**有活动**的时刻。静止时长 = now - 这个值（且不早于开录时刻）。
  int _lastMotionAtMs = 0;
  bool _packageLeft = false;
  bool _packageReturned = false;

  /// 正在等用户回应时长兜底的询问；null 表示没在问。
  int? _promptShownAtMs;

  /// 下一次该问的时刻；null 表示不用问了。
  int? _nextPromptAtMs;

  bool get isRecording => _recording;

  /// 本次录音的开启单号（规格 §3.3.2 的「首扫面单」）。
  WaybillNumber? get currentWaybill => _waybill;

  /// 已录时长。基于**单调时钟**（规格 §3.6.3），不受用户改系统时间影响。
  int elapsedMs(int nowMs) => _recording ? nowMs - _startedAtMs : 0;

  /// 处理一个事件，返回宿主应当执行的动作。
  List<RecorderAction> handle(RecorderEvent event) {
    final actions = <RecorderAction>[];

    switch (event) {
      case WaybillDetected(:final waybill, :final monotonicMs):
        if (_recording) {
          actions.addAll(_onRescan(monotonicMs, waybill));
        } else {
          _start(monotonicMs, waybill);
          // 规格 §3.3.6：滴一声 + 播「开始录像」。
          // **换段开下一段走的也是这一条**（连续扫扫到别的单号时，编排器
          // 收掉上一段后会带着新单号再进来一次）—— 于是「换段只播开始录像」
          // 是白拿的，不必在 `_stop` 那边为换段再补一句。
          actions.add(const Speak(VoicePrompt.startRecording, beep: true));
          actions.add(const StartRecording());
        }

      case ManualStopRequested():
        if (_recording) {
          actions.addAll(_stop(StopTrigger.manual));
        }

      case TrackedPackageLeft():
        if (_recording) {
          _packageLeft = true;
        }

      case TrackedPackageEntered(:final monotonicMs):
        if (_recording) {
          _packageReturned = true;

          // 入场本身是一次画面活动 —— 静止时钟从这里**重新计**。
          // 规格 §3.3.1 要的是「离场后再入场**并**静止达设定时长」，
          // 静止是从入场之后开始算的，不是从离场前那次活动算的。
          _lastMotionAtMs = monotonicMs;
        }

      case SceneSampled(:final isStatic, :final monotonicMs):
        if (_recording && !isStatic) {
          _lastMotionAtMs = monotonicMs;
        }

      case DurationPromptAnswered(:final continueRecording, :final monotonicMs):
        if (_recording && _promptShownAtMs != null) {
          actions.add(const HideDurationPrompt());
          _promptShownAtMs = null;

          if (continueRecording) {
            // 规格 §3.3.4：点「继续」→ 取消本轮上限，进入下一轮。
            _nextPromptAtMs = monotonicMs + config.durationPromptRepeatEvery.inMilliseconds;
          } else {
            actions.addAll(_stop(StopTrigger.durationFallback));
          }
        }

      case Heartbeat():
        break;
    }

    // 时间驱动的判定放在最后：前面刚停下来的话这里不会再跑（_recording 已为 false）。
    if (_recording) {
      actions.addAll(_evaluateTimers(event.monotonicMs));
    }

    return actions;
  }

  // ─────────────────────────────────────────────
  // 内部
  // ─────────────────────────────────────────────

  void _start(int nowMs, WaybillNumber waybill) {
    _recording = true;
    _startedAtMs = nowMs;
    _waybill = waybill;
    _packageLeft = false;
    _packageReturned = false;
    _promptShownAtMs = null;

    // 时长兜底是**可选档位**（关闭 / 4 / 5 / 6 分钟）：
    // 关掉时把下次询问的时刻置空，那样一圈定时判定里就不会再问、也不会停。
    _nextPromptAtMs = config.durationFallback.isEnabled
        ? nowMs + config.effectivePromptAfter.inMilliseconds
        : null;

    // 静止时钟从**开录这一刻**起算 —— 这就是不变量 I12 的落点。
    //
    // 若不加这个封顶，架机 30 分钟无人后再开录，采样一进来就会看到
    // 「画面已经静止了 30 分钟」而当场把录制停掉。规格 §3.3.3 点名了这个后果。
    _lastMotionAtMs = nowMs;
  }

  /// 这一下识码会不会触发「换件」。**纯查询，不改任何状态。**
  ///
  /// 编排器必须在把事件派发给状态机**之前**问它 —— 那一下识码算不算本段的
  /// 复扫打点，取决于它会不会把本段收掉。与 [_onRescan] 共用同一个判据，
  /// 两处不会各自漂移。
  bool rotatesOn(WaybillNumber scanned) =>
      _recording && mode.rotatesOnNewWaybill && scanned != _waybill;

  List<RecorderAction> _onRescan(int nowMs, WaybillNumber scanned) {
    // 连续扫：扫到**别的**单号 = 换件（规格 §3.3.1 的 2026-09-22 需求变更）。
    // 收掉这一段，编排器接到 `StopRecording(nextWaybill)` 之后**紧接着**
    // 为新单号开下一段。
    //
    // ⚠️ 这里**刻意不播**「面单不同」：换件在连续扫里是正常路径，每件都报
    // 一句是错的，而且会盖过下一件的开录播报。
    if (rotatesOn(scanned)) return _stop(StopTrigger.nextWaybill);

    if (scanned != _waybill) {
      // 规格 §3.3.2 错码保护（**只有**同码停 / 扫码静止停录两个模式还启用）：
      // **不停录**，只语音提示，直到扫到正确面单才停。
      //
      // 这一条也要滴（规格 §3.3.6）：它和「开录」一样是**系统认了这一下**的
      // 回执。只出声不滴的话，操作员在嘈杂的仓库里分不清是系统在说
      // 「面单错误」还是旁边那台设备在念时间。
      return const [Speak(VoicePrompt.differentWaybill, beep: true)];
    }

    return mode.stopsOnSameWaybillRescan
        ? _stop(StopTrigger.sameWaybillRescan)
        : const [];
  }

  List<RecorderAction> _evaluateTimers(int nowMs) {
    // 1. 画面静止停录（§3.3.3）
    if (config.staticStop.isEnabled && _staticGateOpen) {
      if (nowMs - _lastMotionAtMs >= config.staticStop.duration.inMilliseconds) {
        return _stop(StopTrigger.sceneStatic);
      }
    }

    // 2. 时长兜底（§3.3.4）—— **独立的可选档位**，与静止档位互不影响。
    //    `_nextPromptAtMs` 为 null 就表示它被关掉了，这里整段跳过。
    final shownAt = _promptShownAtMs;
    if (shownAt != null) {
      // 问了没人理 → 视为用户不在场 → 默认继续，随后按上限停止。
      if (nowMs - shownAt >= config.durationPromptGrace.inMilliseconds) {
        return _stop(StopTrigger.durationFallback);
      }

      return const [];
    }

    final promptAt = _nextPromptAtMs;
    if (promptAt != null && nowMs >= promptAt) {
      _promptShownAtMs = nowMs;
      _nextPromptAtMs = null;

      return const [
        Speak(VoicePrompt.durationTimeout),
        ShowDurationPrompt(),
      ];
    }

    return const [];
  }

  /// 静止判定的门槛是否已满足。
  bool get _staticGateOpen =>
      !mode.staticStopRequiresPackageReturn || (_packageLeft && _packageReturned);

  List<RecorderAction> _stop(StopTrigger trigger) {
    final actions = <RecorderAction>[];

    if (_promptShownAtMs != null) {
      actions.add(const HideDurationPrompt());
    }

    _recording = false;
    _waybill = null;
    _packageLeft = false;
    _packageReturned = false;
    _promptShownAtMs = null;
    _nextPromptAtMs = null;

    // 规格 §3.3.6：**只有复扫同码这一条停录出声**（滴 + 播「停止录像」）。
    //
    // 另外四种停录刻意一声不响，逐条都有理由：
    // - `manual`（点【结束】）—— 由 `startWorking`/`stopWorking` 那边播
    //   「停止工作」，在这里再播一句是同一件事说两遍；
    // - `nextWaybill`（连续扫换段）—— 换件是正常路径，紧接着就有「开始录像」，
    //   中间插一句「停止」会让人以为录断了；
    // - `sceneStatic` / `durationFallback`—— 用户多半已经走开，
    //   补一句只会像设备在自言自语；而且这两条收尾时相机还开着、
    //   下一件包裹随时会来，多说一句就盖住了下一句「开始录像」。
    if (trigger == StopTrigger.sameWaybillRescan) {
      actions.add(const Speak(VoicePrompt.stopRecording, beep: true));
    }

    actions.add(StopRecording(trigger));
    return actions;
  }
}
