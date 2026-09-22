import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../primitives.dart';
import '../scanning/scan_gate.dart';
import 'package_tracker.dart';
import 'punch_log.dart';
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
/// - 每次识别到单号就**立刻**落一条打点（§3.2.4），不等会话结束批量写
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
    required PunchLog punchLog,
    required WorkMode mode,
    RecorderConfig config = RecorderConfig.hardFallback,
    MonotonicClock? clock,
    ScanGate? scanGate,
    PackageTracker? packageTracker,
    this.onAction,
    bool cameraAlreadyOpen = false,
  })  : _gateway = gateway,
        _workspace = workspace,
        _finalizer = finalizer,
        _punchLog = punchLog,
        _stopController = StopController(mode: mode, config: config),
        _clock = clock ?? _defaultClock(),
        _scanGate = scanGate ?? ScanGate(),
        _packageTracker = packageTracker ?? PackageTracker() {
    // 相机是**进程级的同一个原生会话**，跟 Dart 换不换编排器无关 ——
    // 重建编排器时要把「它已经开着」这个事实继承过来，否则按下【开始】
    // 那一瞬间界面会以为相机没了，把取景画面换回「相机还没开」那块提示。
    _cameraOpen = cameraAlreadyOpen;

    _subscription = _gateway.events.listen((event) {
      // ⚠️ **分段落盘走单独一条链**，不跟别的事件挤在一起。
      //
      // 理由是死锁：画面静止 / 扫码复扫触发停录时，处理它的那个处理器
      // 正卡在事件链里等「最后一段封完」；而最后一段的 segmentClosed
      // **排在这个处理器后面**，要等它跑完才能跑 —— 互相等，永远收不了尾。
      // 真机上表现为「停了，但一直卡在『正在收尾』」。
      //
      // 分段落盘只需要在**自己的**几条之间保序（别让两个写 manifest 撞车），
      // 不需要跟开录 / 复扫 / 画面事件串行。
      if (event is SegmentClosedEvent) {
        // ⚠️ **单条失败不能毒死整条链**（2026-09-22 加）。`_segmentWrites` 是用
        // `.then` 串起来的：一个未捕获的异常会把它变成 rejected，而 `finish()`
        // **每一次收尾都 `await` 它** —— 于是从坏掉那一条起，
        // 后面每一条会话都收不了尾（`await` 一个 rejected future 每次都抛）。
        _segmentWrites = _segmentWrites.then((_) async {
          try {
            await _onSegmentClosed(event);
          } on Object catch (error) {
            _lastError = '$error';
            onNativeFailure?.call('分段落盘失败：$error');
          }
        });
        return;
      }

      // 其余事件串行处理：并发会让它们同时改 manifest，后写的覆盖先写的。
      unawaited(_enqueue(() => _onNativeEvent(event)));
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

  /// 打点日志（规格 §3.2.4：识别到就立刻落盘，不等会话结束）。
  final PunchLog _punchLog;

  final StopController _stopController;
  final MonotonicClock _clock;

  /// 把相机的**连续识码**变成**离散的扫码**（框外忽略 + 去重）。
  final ScanGate _scanGate;

  /// 跟踪开录那件包裹的离场 / 入场（规格 §3.3.1 扫码静止停录）。
  final PackageTracker _packageTracker;

  /// 状态机要求宿主做的动作（语音提示、显示按钮、资源告警）。
  /// 界面层接这个。
  final void Function(RecorderAction action)? onAction;

  /// 语音播报开关。默认开（规格 §3.3.2 的错码保护就靠它提示「单号不同」）。
  ///
  /// ⚠️ **这是这里唯一一个可以中途改的配置**，所以是可变字段而不是构造参数。
  ///
  /// 其余那些（工作模式、两个档位）都是构造参数，改了要等下次「开始工作」重建
  /// 编排器 —— 因为它们决定**这一段录制怎么算停**，中途换会让同一段录制前后
  /// 两套判据。而播报不参与任何判定，它只是提示：**人在仓库里嫌吵、想立刻安静
  /// 下来**，这时候跟他说「先结束工作再开始」是荒谬的。
  ///
  /// **关掉的只是声音。** `onAction` 照旧回调，界面上的提示与事件日志一条不少
  /// （见 `_dispatch`）—— 关播报不等于关提示，「单号不同，请核对」那类提示
  /// 在屏幕上仍然要看得到。
  bool voiceEnabled = true;

  /// 相机扫到一个单号（**已经过取景框过滤与去重**）。
  ///
  /// 与 [onAction] 分开：那个是状态机往外的输出，这个是输入侧的观测。
  /// 界面拿它显示「扫到了什么」，人才能判断是没扫到还是扫到了没认。
  void Function(WaybillNumber waybill)? onBarcodeAccepted;

  /// 画面静止状态发生变化（规格 §3.3.3）。
  ///
  /// 界面要靠它才看得懂「静止停录」：**停的是从「画面真的静下来」起算的
  /// 那几分钟，不是从开录起算的。** 用户在扫码时画面是动的，
  /// 所以「开录后 4 分钟才停」完全可能是「扫码折腾了 2 分钟 + 静止 2 分钟」——
  /// 那是正确的，但没有这条观测就没法区分它和「封顶失效」。
  void Function(bool isStatic)? onSceneChanged;

  /// 被跟踪的那件包裹离开了 / 回到了取景框（规格 §3.3.1 扫码静止停录）。
  ///
  /// 界面拿它显示「包裹离场 / 回到画面」。这条观测是为了**把一次失败的验收
  /// 拆成两个可分辨的原因**：「扫码静止停录没停」既可能是跟踪没认出离场，
  /// 也可能是跟踪认出来了而静止判定坏了 —— 没有这条日志，
  /// 真机上只能等满一个档位才知道没停，而且分不清是哪个。
  void Function(bool left)? onPackageTrackingChanged;

  /// 原生层报错（相机打不开、编码出错等）。
  void Function(String message)? onNativeFailure;

  /// 一段录制**收尾完成**（已入库或失败）。
  ///
  /// 界面必须接这个来更新状态 —— 停录时界面只来得及显示「正在收尾」，
  /// 而收尾是异步的。不接的话界面会**永远停在「正在收尾」**，
  /// 看起来像卡住了，其实早就收完了。真机上就是这么被误会的。
  void Function(FinalizeOutcome outcome)? onFinalized;

  StreamSubscription<NativeRecorderEvent>? _subscription;

  /// 在途事件的处理链。
  Future<void> _pending = Future<void>.value();

  /// **分段落盘**的处理链，与 [_pending] 分开 —— 见监听处的说明。
  ///
  /// 收尾时等的是这一条（`await _segmentWrites`），而不是事件链：
  /// 事件链里排着「正在收尾」的那个处理器，等它等于等自己。
  Future<void> _segmentWrites = Future<void>.value();

  /// 已入队 / 已处理完的事件数。用来判断「还有没有没处理完的事件」。
  int _queuedEvents = 0;
  int _completedEvents = 0;

  /// 是否处在「工作状态」：相机开着、取景框显示着，但未必在录。
  ///
  /// 规格 §3.2.2 的流程是「点开始工作 → 出现取景框 → 扫到面单才开录」，
  /// 所以「在工作」和「在录」是两个状态。
  bool _armed = false;

  /// 相机是否开着（**Dart 侧的记忆**，与原生会话对应）。
  ///
  /// ⚠️ 与 [_armed] **不是一回事**，这是 2026-09-22 才分开的：需求方要
  /// 「进发货 / 退货栏就自动开相机，但不开始工作」，于是出现了
  /// **「相机开着、却没在工作」**这个以前不存在的状态。
  /// 从此 [_armed] 不能再当「相机开着」用 —— 关相机一律看这个字段，
  /// 否则进栏自动开的那台相机会在销毁编排器时被漏掉、一直亮着。
  bool _cameraOpen = false;

  Duration _segmentDuration = defaultSegmentDuration;

  String? _sessionId;
  WaybillNumber? _waybill;

  /// 会话起点的**单调**刻度。打点的 `MonotonicOffset` 相对它算，
  /// 所以用的必须与状态机同一个时钟 —— 两把尺子混用算出来的位置是错的。
  int? _sessionStartedMs;
  String _sourceDeviceId = '';
  DateTime _sessionStartedWallClock = DateTime.now();
  final List<SegmentProduct> _segments = [];

  String? _lastError;

  /// 收尾是否在飞。**防同一条会话被收尾两次**（2026-09-22 加）。
  ///
  /// 换段式连续扫下「收尾」与「开下一段」几乎同时，收尾还在飞的时候
  /// 用户按【结束】就会把**同一个会话收尾两遍** ——
  /// 用户看到的是「索引里多出一条」，而且多出来那条哈希一样。
  bool _finalizing = false;

  StopController get stopController => _stopController;
  bool get isRecording => _stopController.isRecording;
  String? get sessionId => _sessionId;

  /// 是否处在工作状态（相机开着、取景框显示着）。
  bool get isWorking => _armed;

  /// 相机是否开着。**与 [isWorking] 不是一回事** ——
  /// 进栏自动开相机时，相机开着、却还没开始工作（两者都为真的只有工作那一段）。
  bool get isCameraOpen => _cameraOpen;

  /// 当前这一段录制对应的单号；没在录时为 null。
  WaybillNumber? get currentWaybill => _stopController.currentWaybill;

  /// 正在生效的扫码闸。
  ///
  /// 界面要读它的 [ScanGate.viewfinder] 来**画那个框** ——
  /// 画的和判的必须是同一份数据，否则用户看着框把面单放进去、系统却说不算。
  ScanGate get scanGate => _scanGate;

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
  Future<void> waitForPendingEvents() async {
    await _settleEventQueue(excludeSelf: false);
    // 分段落盘走的是另一条链，也要等。
    await _segmentWrites;
  }

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

  /// 打开相机、显示取景框 —— **不进入工作状态、不开录**。
  ///
  /// 与 [startWorking] 分开，是因为需求方 2026-09-22 要「进页面就自动开相机」：
  /// 进栏就开相机，但没按【开始】时相机不该自己开始工作。
  ///
  /// ⚠️ **重复调用是安全的，所以这里不做 Dart 侧去重**：原生 `openCamera`
  /// 对已经在跑的会话直接早退；而会话被系统中断（来电、后台）之后再调一次，
  /// 是唯一的恢复机会 —— 去重反而会把恢复的路堵死。
  Future<void> openCamera() async {
    await _gateway.openCamera();
    _cameraOpen = true; // 上面失败会抛；抛了就不记成开着
    _scanGate.reset();
    _packageTracker.reset();
  }

  /// 关相机。**不碰录制** —— 要停录请先 [finish]。
  ///
  /// 先翻标志再 `await`：否则两次调用会在 `await` 处交错，把相机关两遍。
  Future<void> closeCamera() async {
    if (!_cameraOpen) return;
    _cameraOpen = false;
    await _gateway.closeCamera();
  }

  /// 开始工作：把相机端出来（如果还没开）并进入可扫状态。
  ///
  /// 相机可能**已经开着**（进栏时自动开的那台，见 [openCamera]）——
  /// 那次调用不会重复开。
  ///
  /// ⚠️ 注意这里**不落 manifest**：manifest 要等真的要录了才写
  /// （在 [_beginRecording] 里），到这一步为止还没有会话。
  Future<void> startWorking({
    required String sourceDeviceId,
    Duration? segmentDuration,
  }) async {
    _sourceDeviceId = sourceDeviceId;
    _segmentDuration = segmentDuration ?? defaultSegmentDuration;

    // 规格 §3.2.2：点「开始工作」→ 画面出现**可见的取景框**。
    // 到这一步为止**不录** —— 那时还没扫码。
    await openCamera();

    _armed = true;
  }

  /// 停止工作：停录（如果在录）并退出工作状态。
  ///
  /// ⚠️ **相机不关。** 需求方 2026-09-22 定的：采集页上那个【结束】
  /// 回到的是**进栏时那个状态**（相机开着、没开始工作），
  /// 这样下一件包裹可以直接接着扫，表盘也一直看得见。
  /// 要连相机一起收，用 [closeCamera]（离开采集栏、以及 [dispose] 走的就是它）。
  Future<void> stopWorking() async {
    // ⚠️ 走 [onManualStop]（**进状态机**），不能直接调 [finish]。
    //
    // [finish] 只是「收尾」这个动作，**它不改状态机** —— 直接调它的话，
    // 会话收完了、状态机却还以为在录（`isRecording` 仍为 true）而
    // `_sessionId` 已经是 null。后果有两个：界面据此画的「录制中」是假的；
    // 下一件包裹扫进来时走的是**复扫**那条路，不是「首次识别开录」。
    // 这是 2026-09-22 补的，之前那条 `finish` 直调一直没人验过。
    await onManualStop();
    _armed = false;
  }

  /// 扫到面单 → 开一段录制。
  ///
  /// 每件包裹是**一段独立的录制**（= 一个会话、一个目录、一条证据），
  /// 收尾之后相机还开着，下件包裹接着扫。
  Future<void> _beginRecording(WaybillNumber waybill, PunchSource source) async {
    if (!_armed || _stopController.isRecording) return;

    _waybill = waybill;
    _segments.clear();
    _lastError = null;

    final now = _clock();
    _sessionStartedMs = now;
    _sessionStartedWallClock = DateTime.now();
    _sessionId =
        'sess-${_sessionStartedWallClock.millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

    // 顺序是刻意的：**先落 manifest 再开录**。反过来的话，
    // 录到一半被杀、manifest 还没写，那段录像是彻底找不回来的。
    await _workspace.writeManifest(SessionManifest(
      sessionId: _sessionId!,
      waybill: waybill,
      sourceDeviceId: _sourceDeviceId,
      startedAt: _sessionStartedWallClock,
      segments: const [],
    ));

    await _gateway.startRecording(
      directory: _workspace.sessionDirectory(_sessionId!),
      segmentDuration: _segmentDuration,
    );

    // 开录用的这个单号此刻就在画面里/操作员手上。**必须标记成「刚见过」**，
    // 否则相机的第一次识码就会把它报成复扫，录制当场被停 —— 一秒都录不到。
    _scanGate.markSeen(waybill, now);
    _packageTracker.track(waybill, now);

    // 落在开录之后：会话此刻才存在，打点必须挂在它上面。
    // 偏移按 `now` 算，所以这次打点的偏移正好是 0。
    await _recordPunch(waybill, source, atMs: now);

    await _dispatch([WaybillDetected(now, waybill)]);
  }

  /// 识别到一个单号（复扫）。
  ///
  /// 错码保护（规格 §3.3.2）就发生在状态机里：不同单号只提示、不停止。
  ///
  /// ⚠️ **必须排进事件链**，不能直接调 [_handleWaybill]（2026-09-22 改）：
  /// 手输兜底是从界面按钮直接进来的，它可能落在某次收尾的**中间** ——
  /// 那一刻 `_sessionId` 还在、状态机却已经不在录了，直接进去会当
  /// 「首次识别」开一段新的，等收尾回来再把新段的会话号抹掉，
  /// 那段正在录的视频就永久成了孤儿。
  Future<void> onWaybillDetected(
    WaybillNumber waybill, {
    PunchSource source = PunchSource.cameraDecoder,
  }) =>
      _enqueue(() => _handleWaybill(waybill, source));

  Future<void> _handleWaybill(WaybillNumber waybill, PunchSource source) async {
    if (!_armed) return;

    // 还没在录 → 这是「首次识别到单号」，开一段。
    // 规格 §3.3.1：三种工作模式的开始录制都是「首次识别到单号」。
    if (!_stopController.isRecording) {
      await _beginRecording(waybill, source);
      return;
    }

    // 已经在录 → 走复扫路径（同码停 / 换件 / 错码保护都在状态机里判）。
    //
    // 换件（连续扫扫到**别的**单号）要在派发**之前**问出来：这一下算不算
    // 本段的复扫打点，取决于它会不会把本段收掉。
    final rotates = _stopController.rotatesOn(waybill);

    // **扫错码也要打点**：规格 §3.2.4 说的是「识别到单号 → 记录该时刻与该单号的
    // 关联」，没把「认出来的正好是本件」当条件。而且扫错的那一下恰恰是
    // 最需要留痕的 —— 事后看不出操作员那一刻扫到了什么，就没法解释录像里的动作。
    //
    // 但**换件那一下不打在本段上**：它属于下一段，由下面那次 [_beginRecording]
    // 以偏移 0 落在**新会话**上。打在本段上会把「下一件的号」记进上一段的打点里
    // （打点按会话归属，事后看就是脏数据）；两条都打又会把操作员的一次动作
    // 算成两次打点。
    if (!rotates) await _recordPunch(waybill, source);

    await _dispatch([WaybillDetected(_clock(), waybill)]);

    // 上一条事件把本段收掉了（换件 / 同码 / 静止…）。
    //
    // 换件要**紧接着**起下一段，而且必须等收尾真的结束才开：会话号、分段列表、
    // 包裹跟踪器都是 `finish` 里重置的，抢在它前面开新段会让新段继承上一段的账；
    // `_packageTracker.reset()` 更是会把刚扫的这件直接抹掉，随后立刻被判成
    // 「包裹离场」。
    if (rotates && _armed && !_stopController.isRecording) {
      await _beginRecording(waybill, source);
    }
  }

  /// 落一条打点（规格 §3.2.4：**产生即持久化**，不能等会话结束批量写）。
  ///
  /// [atMs] 是调用方已经取好的单调刻度；不给就现取。
  /// 为什么要能传进来：开录那条打点的偏移必须是 0，而再取一次时钟
  /// 会得到几毫秒之后的值 —— 一次打包的第一条打点不在 0 上，
  /// 回放跳转就会偏离它该在的位置。
  Future<void> _recordPunch(
    WaybillNumber waybill,
    PunchSource source, {
    int? atMs,
  }) async {
    final sessionId = _sessionId;
    final startedMs = _sessionStartedMs;
    if (sessionId == null || startedMs == null) return;

    final wallClock = DateTime.now();
    await _punchLog.append(Punch(
      punchId: 'punch-${wallClock.millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}',
      sessionId: sessionId,
      waybill: waybill,
      punchedAt: wallClock,
      monotonicOffsetMilliseconds: (atMs ?? _clock()) - startedMs,
      source: source,
    ));
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

  /// 时间驱动的心跳。
  ///
  /// **必须由界面层按固定间隔调用**（建议 1 秒）。没有它，画面完全不动时
  /// 就没有任何事件，静止超时与时长兜底永远不会触发。
  Future<void> handleHeartbeat() async {
    if (!_stopController.isRecording) return;

    final now = _clock();

    // 相机只报「见到了什么」，不报「没见到什么」——
    // 所以「包裹离场」只能靠心跳推出来（多久没再见到它）。
    final left = _packageTracker.onTick(now);
    if (left != null) {
      onPackageTrackingChanged?.call(true);
      await _dispatch([left]);
    }

    await _dispatch([Heartbeat(now)]);
  }

  /// 收尾并返回结果；没在录时返回 null。
  Future<FinalizeOutcome?> finish(StopTrigger trigger) async {
    // 收尾互斥：同一会话不许收两遍（见 [_finalizing]）。
    if (_finalizing) return null;
    if (_sessionId == null) return null;

    _finalizing = true;
    try {
      // 先把会话号**抓在手里**：下面全程用它，结尾也只在它还没被换掉时才清空。
      final sessionId = _sessionId!;

      // 只停这一段录制 —— **相机保持开着**，取景框还在，下件包裹接着扫。
      await _gateway.stopRecording();

      // 等**分段落盘那条链**（不是事件链）。
      //
      // 原生层的契约是「停止返回时最后一段已经封完并投递」，
      // 所以此刻最后一段的 segmentClosed 已经排在 `_segmentWrites` 上了。
      // 少了这一步，最后一段会被漏掉 —— 而它是刚录完的那段，最不该丢。
      //
      // **不能等事件链**：停录可能是从事件处理器里触发的（画面静止、扫码复扫），
      // 而那个处理器本身就排在事件链上、正在等这里 —— 等事件链就是等自己。
      await _segmentWrites;

      final outcome = await _finalizer.finalize(
        sessionId: sessionId,
        waybill: _waybill!,
        sourceDeviceId: _sourceDeviceId,
        segments: List.of(_segments),
        reason: trigger,
      );

      if (outcome.succeeded) {
        // 只有成功的才打标记；失败的保持孤儿身份，下次启动重试。
        await _workspace.markFinalized(sessionId);
      }

      // ⚠️ **只在会话号还是我们收的那一个时才清**（2026-09-22 加）。
      // 换段式连续扫下，收尾期间下一位的会话可能已经开起来了 ——
      // 无条件 `_sessionId = null` 会抹掉**新开的那一段**的号，
      // 那段正在录的视频就永久成了孤儿。跟踪器同理：
      // 新段的 `track()` 已经跑过，这时 `reset()` 会把新件抹掉。
      if (_sessionId == sessionId) {
        _sessionId = null;
        _sessionStartedMs = null;
        _packageTracker.reset();
      }

      // 通知界面 —— 停录时界面只显示了「正在收尾」，到这里才算真的完了。
      onFinalized?.call(outcome);

      return outcome;
    } finally {
      _finalizing = false;
    }
  }

  Future<void> dispose() async {
    if (_stopController.isRecording) {
      await finish(StopTrigger.manual);
    }

    _armed = false;
    // ⚠️ **判的是 `_cameraOpen`，不是 `_armed`**（2026-09-22 改）。
    // 进栏自动开相机之后，「相机开着、没在工作」是常态 ——
    // 沿用 `if (_armed)` 的话，这台相机会被漏掉、指示灯一直亮，
    // 而且下个页面开相机时原生可能拒绝（会话已在跑）。
    await closeCamera();

    await _subscription?.cancel();
    _subscription = null;
  }

  // ─────────────────────────────────────────────
  // 内部
  // ─────────────────────────────────────────────

  /// 把一件事排进事件链，串行处理。
  ///
  /// **两条链都靠它，是因为「一条失败毒死整条链」这件事**：
  /// `_pending` 是用 `.then` 串起来的，一个未捕获的异常会让它变成 rejected，
  /// **后面所有事件的回调被整段跳过、永不恢复**。真机表现是
  /// 「换一次件之后相机再也扫不动了」，而日志里只有一条报错。
  /// 换段式连续扫把「一次停录」从一次/班变成一次/件，
  /// 一次抖动的代价就从可以忽略变成当班报废 —— 所以这条护栏是必须的。
  ///
  /// 计数器**同步自增**（不是等 body 跑起来才加），
  /// 否则 [waitForPendingEvents] 会数不到刚排进来的这一条。
  Future<void> _enqueue(Future<void> Function() body) {
    _queuedEvents++;

    _pending = _pending.then((_) async {
      try {
        await body();
      } on Object catch (error) {
        _lastError = '$error';
        onNativeFailure?.call('事件处理失败：$error');
      } finally {
        _completedEvents++;
      }
    });

    return _pending;
  }

  /// 把事件喂给状态机，并把它的动作落到界面与原生层。
  ///
  /// 返回的 Future 会等到「收尾完成」—— 调用方可以 await 它来确保落盘结束。
  Future<void> _dispatch(List<RecorderEvent> events) async {
    for (final event in events) {
      for (final action in _stopController.handle(event)) {
        // 先告诉界面（停录要立刻有反馈），再去做收尾（收尾要落盘，慢）。
        onAction?.call(action);

        // 播报关掉时**只是不出声**：`onAction` 上面已经调用过了，
        // 界面上的提示与日志照旧（关播报不等于关提示）。
        if (action is Speak && voiceEnabled) {
          // 播报是**尽力而为**的：设备可能没装中文语音包、通道可能没接上。
          // 提示丢一句是小事，把它抛上去会让「错码保护」这条路径整个失败 ——
          // 而那一下本该只是提示一下、继续录。所以这里吞掉异常。
          // 界面上的日志照旧（onAction 已经先调用过了），用户仍然看得到提示。
          try {
            await _gateway.speak(action.prompt.spokenText);
          } on Object {
            // 忽略。
          }
        }

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
        // 原生层只在状态**变化**时上报，所以这条不会刷屏。
        onSceneChanged?.call(event.isStatic);

        if (_stopController.isRecording) {
          await _dispatch([SceneSampled(_clock(), isStatic: event.isStatic)]);
        }

      case BarcodeDetectedEvent():
        // 跟踪吃**每一次**识码，与下面那道闸无关：闸要的是「离散的一次扫码」
        // （持续识码会被它抑制掉），而跟踪要的是「这一刻它还在不在画面里」。
        // 用闸的输出喂跟踪的话，包裹一直摆在画面里反而永远等不到「还在」的信号。
        final entered = _packageTracker.onSighting(
          WaybillNumber.tryParse(event.text),
          _clock(),
        );
        if (entered != null) {
          onPackageTrackingChanged?.call(false);
          await _dispatch([entered]);
        }

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
          // 摄像头识码 —— 来源写实，回放时能看出这一下是机器认的还是人敲的。
          await _handleWaybill(waybill, PunchSource.cameraDecoder);
        }

      case RecorderFailedEvent():
        _lastError = event.message;
        // 原生层报错**必须让用户看见** —— 静默失败是规格明确禁止的。
        onNativeFailure?.call(event.message);
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

