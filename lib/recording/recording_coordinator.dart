import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../primitives.dart';
import '../scanning/scan_gate.dart';
import '../states.dart';
import 'recorder_config.dart';
import 'recorder_events.dart';
import 'recorder_gateway.dart';
import 'recording_workspace.dart';
import 'session_finalizer.dart';
import 'stop_controller.dart';
import 'work_mode.dart';

/// 单调时钟，返回毫秒。
///
/// 规格 §3.6.3 / 不变量 I11：**时长必须基于单调时钟**，
/// 用户改系统时间不得影响任何判定。所以这里不接受墙钟。
typedef MonotonicClock = int Function();

/// 把原生录制器、停录状态机、会话工作区接起来。
///
/// ## 职责
///
/// - 开录前**先写 manifest**，哪怕立刻被杀也留下可发现的会话
/// - 每个分段一封闭就**立刻**追加进 manifest —— 这是孤儿恢复的前提
/// - 原生事件转成状态机输入，状态机的动作转成原生调用与 UI 回调
///
/// ## 时钟
///
/// 状态机只吃**单调毫秒**。原生层上报的分段起止也是相对会话起点的单调偏移，
/// 两者用同一把尺子（[MonotonicClock]），不经过墙钟。
class RecordingCoordinator {
  RecordingCoordinator({
    required RecorderGateway gateway,
    required RecordingWorkspace workspace,
    required SessionFinalizer finalizer,
    required WorkMode mode,
    RecorderConfig config = RecorderConfig.hardFallback,
    MonotonicClock? clock,
    ScanGate? scanGate,
    this.onAction,
  })  : _gateway = gateway,
        _workspace = workspace,
        _finalizer = finalizer,
        _stopController = StopController(mode: mode, config: config),
        _clock = clock ?? _defaultClock(),
        _scanGate = scanGate ?? ScanGate() {
    // 事件**串行**处理：链在同一个 Future 上。
    // 并发处理会让两个分段事件同时改 manifest，后写的覆盖先写的。
    _subscription = _gateway.events.listen((event) {
      _queuedEvents++;
      _pending = _pending.then((_) async {
        try {
          await _onNativeEvent(event);
        } finally {
          _completedEvents++;
        }
      });
    });
  }

  /// 默认时钟：一个从构造时开始走的秒表。
  static MonotonicClock _defaultClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  final RecorderGateway _gateway;
  final RecordingWorkspace _workspace;
  final SessionFinalizer _finalizer;
  final StopController _stopController;
  final MonotonicClock _clock;

  /// 把相机的**连续识码**变成**离散的扫码**（框外忽略 + 去重）。
  final ScanGate _scanGate;

  /// 状态机要求宿主做的动作（语音提示、显示按钮、资源告警）。
  /// 界面层接这个。
  final void Function(RecorderAction action)? onAction;

  /// 相机扫到一个单号（**已经过取景框过滤与去重**）。
  ///
  /// 与 [onAction] 分开：那个是状态机往外的输出，这个是输入侧的观测。
  /// 界面拿它显示「扫到了什么」，人才能判断是没扫到还是扫到了没认。
  void Function(WaybillNumber waybill)? onBarcodeAccepted;

  StreamSubscription<NativeRecorderEvent>? _subscription;

  /// 在途事件的处理链。
  Future<void> _pending = Future<void>.value();

  /// 已入队 / 已处理完的事件数。用来判断「还有没有没处理完的事件」。
  int _queuedEvents = 0;
  int _completedEvents = 0;

  String? _sessionId;
  WaybillNumber? _waybill;
  String _sourceDeviceId = '';
  DateTime _sessionStartedWallClock = DateTime.now();
  final List<SegmentProduct> _segments = [];

  String? _lastError;

  StopController get stopController => _stopController;
  bool get isRecording => _stopController.isRecording;
  String? get sessionId => _sessionId;

  /// 本次录制已录时长。
  ///
  /// 用的是**编排器自己的单调时钟**，不是墙钟（规格 §3.6.3 / I11）。
  /// 界面拿墙钟去算会得到没意义的数 —— 两把尺子不一样。
  Duration get elapsed => Duration(milliseconds: _stopController.elapsedMs(_clock()));

  /// 原生层最近一次报的错；没有则为 null。
  String? get lastError => _lastError;

  /// 等所有**已派发**的原生事件处理完。
  ///
  /// 用途有两个：界面层在「确保分段落盘了」之后才做下一步；
  /// 测试里拿到确定性的时序（事件处理里有真实文件 I/O，靠 sleep 等不准）。
  ///
  /// **为什么内部要先让出一轮事件循环**：[StreamController] 的派发是异步的，
  /// 刚 `emit` 完就检查，会读到「事件还没接上」的旧状态而立刻返回。
  /// 这个坑真踩过：测试读到的是上一步写的旧 manifest。
  ///
  /// **为什么不是直接 `await _pending`**：`finish()` 会被事件处理器
  /// **从链内部**调用（扫码复扫、画面静止这两条停录路径都走事件链）。
  /// 从链内部 await 整条链，等于等自己 —— 死锁，表现为「一扫码就卡住」。
  /// 所以这里等的是**除当前处理器之外**的那些。
  Future<void> waitForPendingEvents() => _settleEventQueue(excludeSelf: false);

  /// [excludeSelf] 表示调用者**自己就是正在跑的那个处理器** ——
  /// 这时要等的是排在它后面的那些，不能把自己算进去。
  ///
  /// 这个参数**必须由调用者显式给**，不能靠「有没有处理器在跑」这种全局状态去猜：
  /// 外部调用时处理器同样可能在跑（正卡在文件 I/O 上），
  /// 用全局状态判断会把外部调用误认成内部调用、直接跳过等待。
  /// 这个错误踩过——表现是「测试读到上一步写的旧 manifest」。
  Future<void> _settleEventQueue({required bool excludeSelf}) async {
    // 先让几轮：StreamController 的派发要走微任务队列，
    // 刚 emit 完就检查会读到「事件还没接上」的旧计数。
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    final expected = excludeSelf ? _queuedEvents - 1 : _queuedEvents;

    // 上界只是防止逻辑写错时无限等下去；正常情况几轮就够。
    var guard = 0;
    while (_completedEvents < expected && guard++ < 500) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 单段默认时长。
  ///
  /// **这个值直接决定「崩溃时最多丢多少录像」** —— 在写的那一段是救不回来的
  /// （MP4 没有 moov 就是播不了，这不是能靠代码补救的事），
  /// 所以只能靠缩短分段把损失窗口压小。
  ///
  /// 取 1 分钟的理由：打包一件通常 1~3 分钟，1 分钟的分段让一次崩溃
  /// **最多丢一件包裹的过程**；再长就会丢掉整单的证据。
  /// 代价只是文件数变多（30 分钟录像 = 30 个文件），而分段本身几乎不丢帧
  /// （iOS 那边是先开新 writer 再收旧的，Android 那边编码器全程不停）。
  static const defaultSegmentDuration = Duration(minutes: 1);

  /// 开始一次录制。
  ///
  /// 顺序是刻意的：**先落 manifest 再开相机**。要是反过来，
  /// 相机开成功、manifest 还没写就被杀，那段录像是彻底找不回来的。
  Future<void> start({
    required WaybillNumber waybill,
    required String sourceDeviceId,
    Duration? segmentDuration,
  }) async {
    if (_stopController.isRecording) return;

    _waybill = waybill;
    _sourceDeviceId = sourceDeviceId;
    _segments.clear();
    _lastError = null;

    final now = _clock();
    _sessionStartedWallClock = DateTime.now();
    _sessionId = 'sess-${_sessionStartedWallClock.millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

    await _workspace.writeManifest(SessionManifest(
      sessionId: _sessionId!,
      waybill: waybill,
      sourceDeviceId: sourceDeviceId,
      startedAt: _sessionStartedWallClock,
      segments: const [],
    ));

    await _gateway.startSession(
      directory: _workspace.sessionDirectory(_sessionId!),
      segmentDuration: segmentDuration ?? defaultSegmentDuration,
    );

    // 开录用的这个单号此刻就在画面里/操作员手上。**必须标记成「刚见过」**，
    // 否则相机的第一次识码就会把它报成复扫，录制当场被停 —— 一秒都录不到。
    _scanGate.markSeen(waybill, now);

    await _dispatch([WaybillDetected(now, waybill)]);
  }

  /// 识别到一个单号（复扫）。
  ///
  /// 错码保护（规格 §3.3.2）就发生在状态机里：不同单号只提示、不停止。
  Future<void> onWaybillDetected(WaybillNumber waybill) =>
      _handleWaybill(waybill, fromEventChain: false);

  Future<void> _handleWaybill(
    WaybillNumber waybill, {
    required bool fromEventChain,
  }) async {
    if (!_stopController.isRecording) return;
    await _dispatch(
      [WaybillDetected(_clock(), waybill)],
      fromEventChain: fromEventChain,
    );
  }

  /// 被追踪的包裹离开取景框。
  Future<void> onPackageLeft() async {
    if (!_stopController.isRecording) return;
    await _dispatch([TrackedPackageLeft(_clock())]);
  }

  /// 被追踪的包裹重新进入取景框。
  Future<void> onPackageEntered() async {
    if (!_stopController.isRecording) return;
    await _dispatch([TrackedPackageEntered(_clock())]);
  }

  /// 用户点了时长兜底里的【继续】或【停止】。
  Future<void> onDurationPromptAnswered({required bool continueRecording}) async {
    if (!_stopController.isRecording) return;
    await _dispatch(
        [DurationPromptAnswered(_clock(), continueRecording: continueRecording)]);
  }

  /// 用户主动停止。
  Future<void> onManualStop() async {
    if (!_stopController.isRecording) return;
    await _dispatch([ManualStopRequested(_clock())]);
  }

  /// 上报资源状况（存储、电量、热度）。
  Future<void> onResourceReported({
    int? freeStorageBytes,
    int? batteryPercent,
    ThermalLevel? thermal,
  }) async {
    if (!_stopController.isRecording) return;
    await _dispatch([
      ResourceReported(
        _clock(),
        freeStorageBytes: freeStorageBytes,
        batteryPercent: batteryPercent,
        thermal: thermal,
      ),
    ]);
  }

  /// 时间驱动的心跳。
  ///
  /// **必须由界面层按固定间隔调用**（建议 1 秒）。没有它，画面完全不动时
  /// 就没有任何事件，静止超时与时长兜底永远不会触发。
  Future<void> handleHeartbeat() async {
    if (!_stopController.isRecording) return;
    await _dispatch([Heartbeat(_clock())]);
  }

  /// 收尾并返回结果；没在录时返回 null。
  ///
  /// [fromEventChain] 由 `_dispatch` 传入：从事件处理器里触发停录时（扫码复扫、
  /// 画面静止都走这条路），等待队列时**不能把自己算进去**，否则死锁。
  Future<FinalizeOutcome?> finish(
    StopTrigger trigger, {
    bool fromEventChain = false,
  }) async {
    if (_sessionId == null) return null;

    await _gateway.stopSession();

    // 原生层的契约是「停止返回时最后一段已经封完并投递」，
    // 但事件走的是另一条通道，这里再等一次队列。
    // 少了这一步，最后一段会被漏掉 —— 而它是刚刚录完的那段，最不该丢。
    await _settleEventQueue(excludeSelf: fromEventChain);

    final outcome = await _finalizer.finalize(
      sessionId: _sessionId!,
      waybill: _waybill!,
      sourceDeviceId: _sourceDeviceId,
      segments: List.of(_segments),
      reason: trigger,
    );

    if (outcome.succeeded) {
      // 只有成功的才打标记；失败的保持孤儿身份，下次启动重试。
      await _workspace.markFinalized(_sessionId!);
    }

    _sessionId = null;

    return outcome;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  // ─────────────────────────────────────────────
  // 内部
  // ─────────────────────────────────────────────

  /// 把事件喂给状态机，并把它的动作落到界面与原生层。
  ///
  /// 返回的 Future 会等到「收尾完成」—— 调用方可以 await 它来确保落盘结束。
  Future<void> _dispatch(
    List<RecorderEvent> events, {
    bool fromEventChain = false,
  }) async {
    for (final event in events) {
      for (final action in _stopController.handle(event)) {
        // 先告诉界面（停录要立刻有反馈），再去做收尾（收尾要落盘，慢）。
        onAction?.call(action);

        if (action is StopRecording) {
          await finish(action.trigger, fromEventChain: fromEventChain);
        }
      }
    }
  }

  Future<void> _onNativeEvent(NativeRecorderEvent event) async {
    switch (event) {
      case SegmentClosedEvent():
        await _onSegmentClosed(event);

      case SceneSampledEvent():
        if (_stopController.isRecording) {
          await _dispatch(
            [SceneSampled(_clock(), isStatic: event.isStatic)],
            fromEventChain: true,
          );
        }

      case BarcodeDetectedEvent():
        // 相机是连续识码的，先过一道闸：框外的忽略、还在画面里的同一单号也忽略。
        // 不走这一步的话，包裹一放上去就会被自己的持续识别停掉。
        final waybill = _scanGate.accept(
          BarcodeSighting(
            text: event.text,
            centerX: event.centerX,
            centerY: event.centerY,
            confidence: event.confidence,
          ),
          _clock(),
        );

        if (waybill != null) {
          onBarcodeAccepted?.call(waybill);
          await _handleWaybill(waybill, fromEventChain: true);
        }

      case RecorderFailedEvent():
        _lastError = event.message;
        onAction?.call(WarnResource(event.message));
    }
  }

  /// 分段一封闭就落盘。
  ///
  /// **这里必须是「立刻」**：进程被杀时来不及做任何事，
  /// 所以已封闭的分段只有在封闭那一刻就写进 manifest，重启后才能被收尾。
  /// 晚一步（比如等停止时批量写）就会出现「文件在盘上但没人知道它属于谁」。
  Future<void> _onSegmentClosed(SegmentClosedEvent event) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;

    _segments
      ..removeWhere((s) => s.sequence == event.sequence)
      ..add(SegmentProduct(
        sequence: event.sequence,
        filePath: event.filePath,
        startedAt: _sessionStartedWallClock.add(Duration(milliseconds: event.startedAtMs)),
        endedAt: _sessionStartedWallClock.add(Duration(milliseconds: event.endedAtMs)),
      ));

    await _workspace.writeManifest(SessionManifest(
      sessionId: sessionId,
      waybill: _waybill!,
      sourceDeviceId: _sourceDeviceId,
      startedAt: _sessionStartedWallClock,
      segments: _segments
          .map((s) => SegmentManifest(
                sequence: s.sequence,
                fileName: _fileNameOf(s.filePath),
                startedAt: s.startedAt,
                endedAt: s.endedAt,
              ))
          .toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence)),
    ));
  }

  /// 取路径里的文件名。
  ///
  /// **两种分隔符都要认。** 只用 [Platform.pathSeparator] 是不够的：
  /// 原生层与 Dart 层各自拼路径时混用 `/` 与 `\` 是常态，
  /// 一旦混了就切不出文件名（会得到一整段路径），
  /// 而后果是孤儿恢复找不到分段文件、静默跳过 —— 录像就收不了尾了。
  static String _fileNameOf(String path) => path.split(_separators).last;

  static final _separators = RegExp(r'[/\\]');
}

/// 会话状态机的状态名，供界面显示。
String describeState(RecordingSessionState state) => switch (state) {
      RecordingSessionState.idle => '空闲',
      RecordingSessionState.recording => '录制中',
      RecordingSessionState.finalizing => '收尾中',
      RecordingSessionState.indexed => '已入库',
      RecordingSessionState.finalizeFailed => '收尾失败',
    };
