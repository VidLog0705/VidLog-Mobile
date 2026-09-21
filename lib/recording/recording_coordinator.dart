import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../primitives.dart';
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
    this.onAction,
  })  : _gateway = gateway,
        _workspace = workspace,
        _finalizer = finalizer,
        _stopController = StopController(mode: mode, config: config),
        _clock = clock ?? _defaultClock() {
    // 事件**串行**处理：链在同一个 Future 上。
    // 并发处理会让两个分段事件同时改 manifest，后写的覆盖先写的。
    _subscription = _gateway.events.listen((event) {
      _pending = _pending.then((_) => _onNativeEvent(event));
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

  /// 状态机要求宿主做的动作（语音提示、显示按钮、资源告警）。
  /// 界面层接这个。
  final void Function(RecorderAction action)? onAction;

  StreamSubscription<NativeRecorderEvent>? _subscription;

  /// 在途事件的处理链。
  Future<void> _pending = Future<void>.value();

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
  /// 刚 `emit` 完就 await 这条链，会读到「新事件还没接上」的旧链而立刻返回。
  /// 这个坑真踩过：测试读到的是上一步写的旧 manifest。
  Future<void> waitForPendingEvents() async {
    await Future<void>.delayed(Duration.zero);
    await _pending;
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

    await _dispatch([WaybillDetected(now, waybill)]);
  }

  /// 识别到一个单号（复扫）。
  ///
  /// 错码保护（规格 §3.3.2）就发生在状态机里：不同单号只提示、不停止。
  Future<void> onWaybillDetected(WaybillNumber waybill) async {
    if (!_stopController.isRecording) return;
    await _dispatch([WaybillDetected(_clock(), waybill)]);
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
  Future<FinalizeOutcome?> finish(StopTrigger trigger) async {
    if (_sessionId == null) return null;

    await _gateway.stopSession();

    // 原生层的契约是「停止返回时最后一段已经封完并投递」，
    // 但事件走的是另一条通道，这里再等一次在途事件。
    // 少了这一步，最后一段会被漏掉 —— 而它是刚刚录完的那段，最不该丢。
    await waitForPendingEvents();

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
  Future<void> _dispatch(List<RecorderEvent> events) async {
    for (final event in events) {
      for (final action in _stopController.handle(event)) {
        // 先告诉界面（停录要立刻有反馈），再去做收尾（收尾要落盘，慢）。
        onAction?.call(action);

        if (action is StopRecording) {
          await finish(action.trigger);
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
          await _dispatch([SceneSampled(_clock(), isStatic: event.isStatic)]);
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
