import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../primitives.dart';
import '../recording/device_identity.dart';
import '../recording/lan_probe.dart';
import '../recording/punch_log.dart';
import '../recording/recorder_config.dart';
import '../recording/recorder_events.dart';
import '../recording/recorder_gateway.dart';
import '../recording/recording_coordinator.dart';
import '../recording/recording_index.dart';
import '../recording/recording_settings.dart';
import '../recording/recording_totals.dart';
import '../recording/recording_workspace.dart';
import '../recording/session_finalizer.dart';
import '../recording/work_mode.dart';
import 'camera_preview.dart';
import 'zoom_dial.dart';

/// 采集页底部抽屉里正在展开哪一块。`null` = 三块都收着。
///
/// 需求方 2026-09-22 定的布局：**取景铺满整页**，控件是压在上面的浮层；
/// 「手动输入」与「事件」收进抽屉，点开才占屏。
///
/// ⚠️ 这是**页面本地的界面状态**，不是业务状态 —— 它不参与任何判定，
/// 也不落盘。切栏、停录都不需要动它。
enum _WorkSheet { manual, events, diagnostics }

/// 采集页。
///
/// ## 它为什么长这样
///
/// M4 的六条验收（连续录 30 分钟、杀进程后收尾孤儿、静止停录、封顶修正、
/// 错码保护、时长兜底）**全部要在真机上跑**。这个页面的每一个控件都为其中
/// 某一条服务 —— 不是演示界面，是**验收工具**。
///
/// **界面层不做任何判定。** 停录、收尾、索引全部走 `lib/recording/` 里那些
/// 带测试的代码；这里只做三件事：把事件喂进去、把动作放出来、把状态显示出来。
class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  final _gateway = ChannelRecorderGateway();

  late RecordingWorkspace _workspace;
  late SessionFinalizer _finalizer;
  late RecordingIndex _index;
  late PunchLog _punchLog;

  RecordingCoordinator? _coordinator;
  Timer? _heartbeat;

  /// 当前在哪一栏：0 = 备份，1 = 发货，2 = 退货，3 = 设置（需求方 2026-09-21 定的四栏）。
  ///
  /// **发货与退货共用同一个录制页** —— 两栏只是同一套采集流程的两个入口，
  /// 差别在于「这一件是发货还是退货」。做成两份页面会让相机开两次，
  /// 也不符合「同一时刻只有一段录制」的前提。
  int _tab = 0;

  /// 录制页属于哪一栏 —— 只影响标题与后续的上报归类，不影响采集流程本身。
  ///
  /// ⚠️ 「发货 / 退货」目前**只是一个标签**，还没有落到数据上
  /// （不影响落盘、打点、清理策略）。它具体要影响什么，等需求方定。
  bool get _isReturn => _tab == 2;

  /// 用户选的设置（工作模式 + 两个档位）。落盘在 `<root>/settings.json`。
  ///
  /// **`null` = 还没读出来**（`_bootstrap` 是异步的，文件没读完之前改设置
  /// 会被随后读出来的盘上值覆盖掉，等于改了没反应）。所以设置页的控件
  /// 在它为 `null` 时是禁用的 —— 见 `_updateSettings`。
  RecordingSettings? _settings;

  WorkMode _mode = WorkMode.fallback;
  StaticStopSetting _staticStop = StaticStopSetting.fallback;

  /// 时长兜底档位。**与静止档位互相独立** —— 关一个不影响另一个。
  DurationFallbackSetting _durationFallback = DurationFallbackSetting.fallback;

  /// 把时长兜底的首次询问时机缩短，好让验收不必真的等 4 分钟。
  /// **只压首次询问时机**，不动档位本身，也不碰静止档位。
  ///
  /// ⚠️ **故意不落盘。** 它是验收工具，不是产品设置：一旦存下来，验收完
  /// 忘了关，真实录制就会在开录 20 秒后被问「是否停止」，而用户看着它像正常功能。
  bool _accelerated = false;

  final _waybillController = TextEditingController();

  String _status = '正在准备…';
  final List<String> _events = [];
  bool _askingToContinue = false;
  bool _starting = false;

  /// 启动时收尾的孤儿。
  List<FinalizeOutcome> _recovered = const [];

  /// 当前变焦倍率（规格 §3.1.2）。
  ///
  /// 只在内存里 —— 规格要的是「在本次工作期间保持」，
  /// 「按设备记忆」是**建议**（原文如此），要做得先有个按设备存的配置区，
  /// 而 M4 的配置区还没到那一步。
  double _zoom = 1;

  /// 表盘刻度画到哪 —— 设备的真实上限，问不到时用 [zoomMaxRatio]。
  double _maxZoom = zoomMaxRatio;

  /// 当前会话已录时长。
  ///
  /// 曾经用 `ValueNotifier` 想省掉每秒重建 —— **那是白费**：
  /// 卡顿的真因是「原生预览视图在可滚动容器里」（见下方 `_previewArea` 的说明），
  /// 省掉重建治不了它。而多一层 notifier 反而让「已录一直是 00:00」多了一个可疑点。
  /// 秒数就老老实实 `setState`。
  Duration _elapsed = Duration.zero;

  /// 盘上的实况：工作区有几个会话、其中几个还没收尾、索引里几条。
  ///
  /// 真机验收时**失败必须是可见的** —— 上一次拿不到孤儿卡片时，
  /// 光看界面分不清「没录成」还是「录了但没收尾」，只能靠猜。
  int _sessionCount = 0;
  int _pendingCount = 0;
  int _entryCount = 0;

  /// 打点日志累积了多少条。
  ///
  /// 与上面几个同理：打点是**独立于收尾**的一条链（收尾失败不该吞掉打点，
  /// 反过来也一样），所以它得单独有个数字可看。
  /// 打点是「产生即持久化」的，这一条就等于盘上真有的条数。
  int _punchCount = 0;

  /// 本机数据根目录。索引里的 `location` 相对它 —— 备份页靠它把相对路径
  /// 还原成能 stat 的绝对路径（收尾端算这个相对路径时用的就是这个根）。
  late String _rootPath;

  /// 本机身份与本地配置（设备标识 / 本机名 / 电脑端地址）。
  DeviceIdentity? _identity;

  /// 本机的局域网 IPv4；null = 没连上局域网。
  ///
  /// **null 与「0.0.0.0」是两回事**：后者看起来像个正经地址却连不上任何东西。
  String? _lanIp;

  /// 电脑端探测结果（探的是电脑端那台机器，不是本机）。
  bool _hostOnline = false;
  bool _probingHost = false;

  /// 索引归并出来的「一次录制」——需求方口径的「一条」。
  List<RecordingSession> _sessions = const [];

  /// 起录时间落在今天的条数。
  int _todayCount = 0;

  /// 盘上视频的实际占用（含未收尾的片段）。
  int _videoBytes = 0;

  /// 录像记录列表：筛选 / 每页条数 / 当前页（0 起）。
  bool _recordsTodayOnly = false;
  int _recordsPageSize = 5;
  int _recordsPage = 0;

  /// 采集页底部抽屉展开的是哪一块；null = 都收着。
  ///
  /// **默认收着**：取景画面必须尽量完整，而这两块都不是每时每刻要看的东西。
  _WorkSheet? _workSheet;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    unawaited(_coordinator?.dispose() ?? Future<void>.value());
    _waybillController.dispose();
    super.dispose();
  }

  RecorderConfig get _config => RecorderConfig(
        // 两个档位都**原样保留用户的选择** —— 加速只压时长兜底的首次询问时机。
        staticStop: _staticStop,
        durationFallback: _durationFallback,
        promptAfterOverride: _accelerated ? const Duration(seconds: 20) : null,
        durationPromptRepeatEvery:
            _accelerated ? const Duration(seconds: 30) : const Duration(minutes: 5),
        durationPromptGrace:
            _accelerated ? const Duration(seconds: 10) : const Duration(minutes: 1),
      );

  // ─────────────────────────────────────────────
  // 启动
  // ─────────────────────────────────────────────

  Future<void> _bootstrap() async {
    try {
      // 用**持久**目录，不用临时目录 ——「重启后收尾孤儿」靠的就是文件还在原处。
      final documents = await getApplicationDocumentsDirectory();
      final root = Directory('${documents.path}/vidlog')..createSync(recursive: true);
      _rootPath = root.path;

      _workspace = RecordingWorkspace('${root.path}/work');
      _index = JsonLinesRecordingIndex('${root.path}/index.jsonl');
      _finalizer = SessionFinalizer(rootDirectory: root.path, index: _index);
      // 与电脑端同一个位置（`<root>/punches.jsonl`），键名也逐字相同 ——
      // 两端的打点日志是同一份形态。
      _punchLog = PunchLog('${root.path}/punches.jsonl');

      // 本机身份要在 `_buildCoordinator` **之前**读出来 ——
      // 编排器建的时候就要把设备标识接进去（它写进每条录像索引的 sourceDeviceId）。
      _identity = await DeviceIdentity.load('${root.path}/device.json');

      // 用户设置也要在 `_buildCoordinator` **之前**读出来 —— 编排器建的时候
      // 就把模式和两个档位接进去了（`RecordingCoordinator` 只认构造参数，
      // 没有 setter，建完再改是改不动的）。
      _settings = await RecordingSettings.load('${root.path}/settings.json');
      _mode = _settings!.mode;
      _staticStop = _settings!.staticStop;
      _durationFallback = _settings!.durationFallback;

      _buildCoordinator();

      // 规格 §3.1.1：重启后必须能自动收尾孤儿分段。
      final recovered = await OrphanRecovery(
        workspace: _workspace,
        finalizer: _finalizer,
      ).recover();

      if (!mounted) return;
      setState(() {
        _recovered = recovered;
        _status = recovered.isEmpty
            ? '就绪'
            : '就绪 · 上次有 ${recovered.length} 段没录完，已自动收尾';
      });

      if (recovered.isNotEmpty) {
        _log('启动时收尾了 ${recovered.length} 段孤儿');
      }

      await _refreshBackup();
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '初始化失败：$error');
    }
  }

  /// 刷新备份页要的东西：本机 IP、索引汇总、电脑端探测。
  ///
  /// 三件事一起做，是因为它们在界面上是**同一屏**：分开刷新会出现
  /// 「IP 已经变了、统计还是旧的」这种半新半旧的画面。
  Future<void> _refreshBackup() async {
    final ip = await lanAddress();
    if (mounted) setState(() => _lanIp = ip);

    await _refreshDiagnostics();
    if (!mounted) return;

    await _probeHost();
  }

  /// 探一次电脑端在不在线上。
  ///
  /// **没配对就不探** —— 没有地址可探，也不该显示一个探测出来的状态。
  Future<void> _probeHost() async {
    final address = _identity?.hostAddress ?? '';
    if (address.isEmpty) {
      if (mounted) setState(() => _hostOnline = false);
      return;
    }

    if (mounted) setState(() => _probingHost = true);

    final online = await isHostReachable(address);
    if (!mounted) return;

    setState(() {
      _hostOnline = online;
      _probingHost = false;
    });
  }

  void _buildCoordinator() {
    _coordinator = RecordingCoordinator(
      gateway: _gateway,
      workspace: _workspace,
      finalizer: _finalizer,
      punchLog: _punchLog,
      mode: _mode,
      config: _config,
      onAction: _onAction,
    )..onBarcodeAccepted = _onBarcodeAccepted;
    _coordinator!.onFinalized = _onFinalized;
    _coordinator!.onSceneChanged = _onSceneChanged;
    _coordinator!.onPackageTrackingChanged = (left) =>
        _log(left ? '📦 包裹离开取景框' : '📦 包裹回到取景框');
    _coordinator!.onNativeFailure = (message) => _log('⚠️ $message');
  }

  /// 画面静下来 / 又动起来。
  ///
  /// 这条观测是给「静止停录」那两条验收用的：**静止计时从画面静下来那一刻起算**，
  /// 不是从开录起算。扫码时手机在手上、画面在动，所以「开录后 4 分钟才停」
  /// 完全可能是正确的（扫码 2 分钟 + 静止 2 分钟）。没有这条日志就分不清
  /// 它和「封顶失效」。
  void _onSceneChanged(bool isStatic) {
    // ⚠️ **静止档位关掉时不要记这条。** 那时静止计时根本没在计，
    // 打一行「静止计时从现在起算」是误导 —— 真机上就是这么被误会的。
    if (!_staticStop.isEnabled) return;

    _log(isStatic ? '👁 画面静止 —— 静止计时从现在起算' : '👁 画面恢复活动 —— 静止计时重置');
  }

  /// 一段录制收尾完成。
  ///
  /// **必须接这个**：停录时界面只来得及显示「正在收尾」，而收尾是异步的。
  /// 不接的话界面会**永远停在「正在收尾」**—— 看起来像卡住了，其实早就收完了。
  /// 真机上就是这么被误会的。
  Future<void> _onFinalized(FinalizeOutcome outcome) async {
    if (!mounted) return;

    _log(outcome.succeeded ? '✓ 已收尾入库' : '✗ 收尾失败：${outcome.failureReason}');

    await _refreshDiagnostics();
    if (!mounted) return;

    setState(() {
      _status = outcome.succeeded
          ? '已收尾 · 索引里共 $_entryCount 条'
          : '收尾失败：${outcome.failureReason}';
    });
  }

  // ─────────────────────────────────────────────
  // 状态机要的动作
  // ─────────────────────────────────────────────

  void _onAction(RecorderAction action) {
    if (!mounted) return;

    switch (action) {
      case StartRecording():
        setState(() {
          _status = '录制中';
          _askingToContinue = false;
        });
        _log('开录 · 模式 ${_modeLabel(_mode)}');

      case StopRecording(:final trigger):
        _heartbeat?.cancel();
        _heartbeat = null;
        setState(() {
          _status = '已停止（${_triggerLabel(trigger)}）· 正在收尾';
          _askingToContinue = false;
          _elapsed = Duration.zero;
        });
        _log('停录 · ${_triggerLabel(trigger)}');
        unawaited(_refreshDiagnostics());

      case Speak(:final prompt):
        // 播报本身在编排层里发给原生（`VoicePrompt.spokenText` 是唯一措辞来源），
        // 这里只留一条可见的日志。
        _log('🔊 ${prompt.spokenText}');

      case ShowDurationPrompt():
        setState(() => _askingToContinue = true);

      case HideDurationPrompt():
        setState(() => _askingToContinue = false);
    }
  }

  /// 原生层报来一次识码时记一行 —— 但**只记被采纳的**，
  /// 否则相机每秒报好几次会把事件列表刷爆。
  ///
  /// 这里不重复判定，只是把「Dart 层认了哪一次」显示出来：
  /// 真正决定采纳与否的是 `ScanGate`（框外忽略 + 去重），那层有测试。
  void _onBarcodeAccepted(WaybillNumber waybill) {
    _log('📷 扫到 $waybill');
  }

  // ─────────────────────────────────────────────
  // 操作
  // ─────────────────────────────────────────────

  /// 开始工作：**开相机、送预览、显示取景框。不录。**
  ///
  /// 规格 §3.2.2 的流程是「点开始工作 → 出现取景框 → 扫到面单才开录」。
  /// 之前把「开相机」和「开录」合成一步，表现是点了按钮屏幕上什么都没有、
  /// 但其实已经在录 —— 用户既看不到画面、也没法把面单对准。
  Future<void> _startWorking() async {
    if (_starting) return;
    setState(() => _starting = true);

    try {
      if (!await _gateway.hasCameraPermission()) {
        final granted = await _gateway.requestCameraPermission();
        if (!granted) {
          setState(() => _status = '没有相机权限');
          return;
        }
      }

      _buildCoordinator(); // 换模式下重建，配置跟着走

      // ⚠️ 这里传的必须是**设备标识**，不是本机名（契约 §1.1 步骤 2 把两者分开：
      // 标识用来认设备，名字用来给人看）。以前这里写死 `'this-device'` ——
      // 结果**所有手机在电脑端都叫同一个名字**，根本分不开是哪台录的。
      // 标识是不变的，所以改名不会篡改历史录像的来源。
      await _coordinator!.startWorking(sourceDeviceId: _identity!.deviceId);

      _log('开始工作 · 模式 ${_modeLabel(_mode)}');
      _startHeartbeat();

      // 相机开起来之后才问得到设备上限（规格 §3.1.2）——
      // 表盘的刻度要画到设备的真实上限，不然划到底是 8 倍、画面却停在 2 倍。
      await _readDeviceMaxZoom();

      if (mounted) {
        setState(() => _status = '把面单放进取景框');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _status = '开始失败：$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// 问一次设备支持的变焦上限，用来定表盘刻度（规格 §3.1.2）。
  ///
  /// **拿不到就用默认值**：问了不代表问得到（Android 端的通道还没接上、
  /// 或者相机刚开、设备还没报能力）。为这个把「开始工作」弄失败是本末倒置。
  Future<void> _readDeviceMaxZoom() async {
    double? max;
    try {
      max = await _gateway.maxZoom();
    } on Object {
      max = null;
    }

    // `>= 1` 而不是 `> 1`：设备报 1.0 就是「不能变焦」，那也是实话，
    // 表盘会画成划不动 —— 比骗用户「能划到 8 倍」强。
    if (!mounted) return;
    setState(() => _maxZoom = (max != null && max >= 1) ? max : zoomMaxRatio);
  }

  /// 用户滑动半圆刻度盘。
  Future<void> _onZoomChanged(double ratio) async {
    // 先更新表盘再发命令：原生变焦是异步的，等它回来再画会明显跟手不上。
    setState(() => _zoom = ratio);

    try {
      await _gateway.setZoom(ratio);
    } on Object catch (error) {
      // 变焦失败不该中断录制（原生层也是这个态度），只留一条日志。
      _log('⚠️ 变焦失败：$error');
    }
  }

  /// 结束工作：停掉在录的那段、关相机。
  Future<void> _stopWorking() async {
    _heartbeat?.cancel();
    _heartbeat = null;

    try {
      await _coordinator?.stopWorking();
    } on Object catch (error) {
      if (mounted) setState(() => _status = '结束失败：$error');
    }

    if (mounted) {
      setState(() {
        _status = '已结束工作';
        _askingToContinue = false;
        _elapsed = Duration.zero;
      });
    }
    await _refreshDiagnostics();
  }

  /// 心跳驱动那些「时间到了就发生」的判定（静止、时长兜底）。
  /// 没有它，画面完全不动时没有任何事件，超时永远不会触发。
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_coordinator?.handleHeartbeat());

      final elapsed = _coordinator?.elapsed ?? Duration.zero;

      if (mounted) {
        // 时长从编排器取 —— 它用单调时钟，墙钟在这儿算不出正确的值。
        setState(() => _elapsed = elapsed);
      }
    });
  }

  /// 停掉当前这一件包裹的录制（相机保持开着，接着扫下一件）。
  Future<void> _stopCurrentRecording() async {
    await _coordinator?.onManualStop();
  }

  /// 模拟一次扫码。
  ///
  /// **摄像头识码已经接上了**（iOS 用系统自带的 Vision），但这个按钮仍然有用：
  /// 它走的是[PunchSource.manualEntry]，且不经过 [ScanGate] 的框内判定 ——
  /// 验状态机时不必去凑一张恰好落在取景框里的面单。
  /// 错码保护验的是状态机：首扫 A 开录、扫 B 只提示不停、扫回 A 才停。
  Future<void> _simulateScan() async {
    final waybill = WaybillNumber.tryParse(_waybillController.text);
    if (waybill == null) {
      setState(() => _status = '单号无效');
      return;
    }

    await _coordinator?.onWaybillDetected(waybill,
        source: PunchSource.manualEntry);
  }

  /// 重新读一遍盘上的实况。
  Future<void> _refreshDiagnostics() async {
    try {
      final root = Directory(_workspace.rootDirectory);
      final sessions = root.existsSync()
          ? root.listSync().whereType<Directory>().length
          : 0;
      final pending = (await _workspace.listOrphans()).length;
      final entries = await _index.loadAll();
      final punches = (await _punchLog.loadAll()).length;

      // 每条录像在盘上的字节数，按 evidenceId 索引。逐条 stat —— 条数以十计，
      // 而且本来就要读一遍索引，不值得为它加缓存或后台扫描。
      //
      // 量不出来（文件不在了、读不动）的**不放进来**，那一条就写「大小未知」。
      // 宁可少一个数字，也不要显示一个算不出来、但看起来很像真的的值 ——
      // 这个项目已经因为「界面上的假数字被当成真的」吃过一次亏。
      final bytes = <String, int>{};
      for (final entry in entries) {
        final file = File('$_rootPath/${entry.location.value}');
        try {
          if (await file.exists()) bytes[entry.evidenceId] = await file.length();
        } on Object {
          continue;
        }
      }

      // 归并成「一次录制」（需求方 2026-09-22 的口径：一个单号从开始到结束为一条）。
      final merged = toSessions(entries, bytes);

      // 总占用走盘，不走索引 —— 需求方要的是「实际存储到手机的视频大小总量，
      // 上传后删掉就按删除后的算」。索引只增不减，拿它求和永远降不下来。
      final videoBytes = await videoBytesOnDisk(_rootPath);

      if (!mounted) return;
      setState(() {
        _sessionCount = sessions;
        _pendingCount = pending;
        _entryCount = entries.length;
        _punchCount = punches;
        _sessions = merged;
        _todayCount = countToday(merged, DateTime.now());
        _videoBytes = videoBytes;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _status = '读取工作区失败：$error');
    }
  }

  void _log(String line) {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _events.insert(
        0,
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}  $line',
      );
      if (_events.length > 60) _events.removeLast();
    });
  }

  // ─────────────────────────────────────────────
  // 界面
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final recording = _coordinator?.isRecording ?? false;
    final working = _coordinator?.isWorking ?? false;

    return Scaffold(
      // 发货 / 退货两栏**没有 AppBar** —— 取景要一直铺到状态栏底下（需求方
      // 2026-09-22：页面全屏显示摄像头画面）。标题与状态改由画面上的浮层承担。
      //
      // 备份 / 设置两栏照旧留着 AppBar：那两页是**读**的页面，不是瞄面单用的，
      // 没有理由让内容顶到状态栏上。
      appBar: _tab == 1 || _tab == 2 ? null : AppBar(title: Text(_tabTitle)),
      // 用 IndexedStack 而不是 TabBarView：切走时**不销毁预览视图**，
      // 切回来不会闪一下。预览层本来就有「布局时重新挂会话」的自愈逻辑，
      // 但能不重建就别重建。
      //
      // ⚠️ **栈里只有三个孩子，不是四个**：发货与退货指向同一个录制页实例。
      // 放两份进去就会有两个 `UiKitView`、两次开相机 —— 而相机同时只能开一个。
      body: IndexedStack(
        index: switch (_tab) {
          0 => 0, // 备份
          3 => 1, // 设置
          _ => 2, // 发货 / 退货 —— 同一个录制页
        },
        children: [_backupPage(), _settingsPage(), _workPage(recording, working)],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) {
          setState(() => _tab = index);

          // 切回备份页就重读一遍：用户多半是刚录完回来看的，
          // 摆着切走之前的旧数字等于白看。
          //
          // `_identity != null` 兼作「启动已完成」的判据 —— 它是在 `_workspace`
          // 之后设的，早于启动完成就切过来会踩到未初始化的 `late` 字段。
          if (index == 0 && _identity != null) unawaited(_refreshBackup());
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.cloud_upload_outlined),
            selectedIcon: Icon(Icons.cloud_upload),
            label: '备份',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            selectedIcon: Icon(Icons.local_shipping),
            label: '发货',
          ),
          NavigationDestination(
            icon: Icon(Icons.assignment_return_outlined),
            selectedIcon: Icon(Icons.assignment_return),
            label: '退货',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: '设置',
          ),
        ],
      ),
    );
  }

  String get _tabTitle => switch (_tab) {
        0 => '备份',
        1 => '发货',
        2 => '退货',
        _ => '设置',
      };

  /// 备份页：本机身份 → 三个统计 → 电脑备份 → 录像记录。
  ///
  /// ## 为什么这一页先做，而且今天只能做成这样
  ///
  /// 规格 §3.4.3 标着 ★，原文写明它来自一次**真实故障**：原系统上传失败后
  /// 进入终态、永不重试，用户完全不知道数据没传上去。那类故障的第一道防线
  /// 不是重试次数，是**看得见**。
  ///
  /// 而手机端今天**一行上传代码都没有** —— 没有队列、没有网络层、没有配网。
  /// 所以「东西没备份，而且用户不知道」是眼下唯一确定会发生的事。
  /// 这一页先把它变成看得见的。
  ///
  /// ⚠️ **只显示盘上真有的东西**：已收尾的录像、盘上的实际占用、探测得到的
  /// 连通性。不放剩余空间、不放上传进度条 —— 那些今天一个都测不出来，
  /// 而假数字在真机上会被当成真的（这个项目吃过一次亏）。
  Widget _backupPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _identityCard(),
        const SizedBox(height: 12),
        _totalsCard(),
        const SizedBox(height: 12),
        _hostCard(),
        const SizedBox(height: 12),
        _recordsCard(),
      ],
    );
  }

  // ── ① 本机身份 ───────────────────────────────

  /// 本机名 + 局域网 IP。
  ///
  /// 本机名是给**电脑端**区分机位用的（需求方 2026-09-22），所以它得可改，
  /// 而且改完必须落盘 —— 只在内存里留着的名字，断联重连一次就没了，
  /// 电脑端那台机位就变成一个没人认得的新设备。
  Widget _identityCard() {
    final identity = _identity;

    return Card(
      child: ListTile(
        leading: const Icon(Icons.smartphone),
        title: Text(identity?.deviceName ?? defaultDeviceName),
        subtitle: Text(
          _lanIp == null ? '未连局域网' : '局域网 $_lanIp',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: IconButton(
          tooltip: '改本机名',
          icon: const Icon(Icons.edit_outlined),
          onPressed: identity == null ? null : _editDeviceName,
        ),
      ),
    );
  }

  // ── ② 今日 / 全部 / 总占用 ─────────────────────

  /// 三个数字并排。
  ///
  /// 三个口径都是**需求方 2026-09-22 定的**，不是这里随手挑的：
  /// - **今日** = 起录时间落在今天 0:00~23:59 的条数
  /// - **全部** = 录到的总条数，**一个单号从开始到结束算一条**（不是索引行数）
  /// - **总占用** = 盘上视频的**实际**大小；传到电脑后删掉手机上的，就按删后的算
  ///
  /// ⚠️ 总占用可能**大于**上面那些条的大小之和 —— 它含还没走完收尾的孤儿片段。
  /// 它答的是「这些视频在手机上占了多少地方」，不是「已入库的占了多少」。
  /// 所以那块底下写着「手机上现存」。
  Widget _totalsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            _statCell('今日', '$_todayCount 条'),
            _thinDivider(),
            _statCell('全部', '${_sessions.length} 条'),
            _thinDivider(),
            _statCell('总占用', _sizeLabel(_videoBytes), note: '手机上现存'),
          ],
        ),
      ),
    );
  }

  Widget _statCell(String label, String value, {String? note}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(note, style: const TextStyle(fontSize: 11, color: Colors.black45)),
          ],
        ],
      ),
    );
  }

  /// 三块之间的细分隔线。
  ///
  /// **不用 `VerticalDivider`** —— 它要父级有确定高度（得再套一层
  /// `IntrinsicHeight`），为一个 1 像素的线多一层布局不划算。
  Widget _thinDivider() => Container(
        width: 1,
        height: 40,
        color: Theme.of(context).dividerColor,
      );

  // ── ③ 电脑备份 ───────────────────────────────

  /// 配对电脑 + 连通性。
  ///
  /// ⚠️ 「连接 / 离线」探的是**电脑端那台机器**（M3 已经在 8720 端口上开着的
  /// HTTP 服务），既不代表本机有网，也不代表「备份通道建好了」——
  /// 手机端还没有一行上传代码。所以卡里同时留着一句实话（见下方
  /// 「手机端还没有上传功能」），免得那个绿色小字被读成「我的数据已经在电脑上了」。
  Widget _hostCard() {
    final identity = _identity;
    final name = identity?.hostName ?? '';
    final address = identity?.hostAddress ?? '';
    final hasHost = address.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '电脑备份',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: identity == null ? null : _editHost,
                  child: Text(hasHost ? '重新配对' : '配对电脑'),
                ),
              ],
            ),
            _kv('电脑端名字', name.isEmpty ? '未填' : name),
            _kv(
              '局域网 IP',
              hasHost ? address : '未填',
              trailing: _hostBadge(hasHost),
            ),
            const SizedBox(height: 8),
            const Text(
              '手机端还没有上传功能 —— 下面这些录像现在只在这台手机上，'
              '手机丢了就没了。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 「连接 / 离线」小标，贴在 IP 那一行的右端。
  ///
  /// **没配对就什么也不显示。** 显示「离线」会让人以为「配对过、只是没连上」，
  /// 而真实情况是**根本没配过对** —— 这两件事要修的东西不一样。
  Widget _hostBadge(bool hasHost) {
    if (!hasHost) return const SizedBox.shrink();

    if (_probingHost) {
      return const Text('探测中…', style: TextStyle(fontSize: 12, color: Colors.black45));
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _hostOnline ? Icons.link : Icons.link_off,
          size: 14,
          color: _hostOnline ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 4),
        Text(
          _hostOnline ? '连接' : '离线',
          style: TextStyle(
            fontSize: 12,
            color: _hostOnline ? Colors.green : Colors.grey,
          ),
        ),
      ],
    );
  }

  // ── ④ 录像记录 ───────────────────────────────

  /// 录像记录列表：筛选 + 分页。
  ///
  /// 分页是需求方 2026-09-22 定的（每页 5/10/15，左右箭头换页）——
  /// 不是为了性能，是因为手机一屏放不下，而**总页数得看得见**。
  ///
  /// 列的是 `_sessions`（一次录制一条），**不是索引行** —— 索引是按分段记的，
  /// 一段 30 分钟的录制会列出 6 行来，用户数不出那个数字是哪来的。
  Widget _recordsCard() {
    // 「今日」的判据与上面那个统计**共用 `isSameDay`** —— 两处各写一套，
    // 迟早会出现「上面写 3 条、下面列 2 条」而用户无从判断谁对。
    final filtered = _recordsTodayOnly
        ? _sessions.where((s) => isSameDay(s.startedAt, DateTime.now())).toList()
        : _sessions;

    final pageCount = filtered.isEmpty
        ? 1
        : (filtered.length + _recordsPageSize - 1) ~/ _recordsPageSize;

    // 夹在**本地变量**里、不改状态：条数变少（换了筛选、删了录像）时
    // `_recordsPage` 可能越界，而在 build 里改状态 Flutter 会直接报错。
    final page = _recordsPage.clamp(0, pageCount - 1);
    final rows = filtered
        .skip(page * _recordsPageSize)
        .take(_recordsPageSize)
        .toList();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '录像记录（共 ${filtered.length} 条）',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('全部')),
                    ButtonSegment(value: true, label: Text('今日')),
                  ],
                  selected: {_recordsTodayOnly},
                  onSelectionChanged: (selection) => setState(() {
                    _recordsTodayOnly = selection.first;
                    // 换了筛选就必须回第一页 —— 停在第 7 页上多半是空的，
                    // 看起来像「今天什么都没录」。
                    _recordsPage = 0;
                  }),
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                _recordsTodayOnly ? '今天还没有录完的录像。' : '本机还没有收尾入库的录像。',
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
            )
          else
            for (final session in rows) ...[
              const Divider(height: 1),
              ListTile(
                dense: true,
                title: Text(
                  session.waybill.value.isEmpty
                      ? session.sessionId
                      : session.waybill.value,
                ),
                subtitle: Text(
                  '${_stamp(session.startedAt)} · '
                  '${_durationLabel(session.duration)} · '
                  '${session.bytes > 0 ? _sizeLabel(session.bytes) : '大小未知'}',
                ),
                trailing: const Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('未备份'),
                ),
              ),
            ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Text('每页', style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _recordsPageSize,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5')),
                    DropdownMenuItem(value: 10, child: Text('10')),
                    DropdownMenuItem(value: 15, child: Text('15')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _recordsPageSize = value;
                      // 每页条数变了，原来的页码对应的内容已经不是同一批了。
                      _recordsPage = 0;
                    });
                  },
                ),
                const Spacer(),
                IconButton(
                  tooltip: '上一页',
                  icon: const Icon(Icons.chevron_left),
                  onPressed:
                      page > 0 ? () => setState(() => _recordsPage = page - 1) : null,
                ),
                Text('${page + 1}/$pageCount', style: const TextStyle(fontSize: 13)),
                IconButton(
                  tooltip: '下一页',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: page < pageCount - 1
                      ? () => setState(() => _recordsPage = page + 1)
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 标签 + 值的一行。用固定宽度的标签列，几行数字才对得齐。
  ///
  /// [trailing] 贴右端（「连接 / 离线」那个小标在 IP 那一行）。
  Widget _kv(String label, String value, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // 84 而不是 72：「局域网 IP」「电脑端名字」在 72 里会折行。
            width: 84,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          Expanded(child: Text(value)),
          ?trailing,
        ],
      ),
    );
  }

  // ── 两处编辑弹窗 ──────────────────────────────

  /// 改本机名。**落盘** —— 只在内存里留着的名字，重连一次就没了。
  Future<void> _editDeviceName() async {
    final identity = _identity;
    if (identity == null) return;

    final controller = TextEditingController(text: identity.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本机名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '电脑端用这个名字区分机位',
            hintText: defaultDeviceName,
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null) return;

    // 空名会退回默认名（见 `DeviceIdentity.rename`）—— 允许名字变空
    // 等于允许这台手机在电脑端消失。
    await identity.rename(name);
    if (mounted) setState(() {});
  }

  /// 填 / 改电脑端的地址与名字。
  ///
  /// 地址眼下**只用于探测**（M5 做真正的配网时才会拿它去入网）；
  /// 名字只用于显示 —— 真连没连上由探测决定，不由名字决定。
  Future<void> _editHost() async {
    final identity = _identity;
    if (identity == null) return;

    final nameController = TextEditingController(text: identity.hostName);
    final addressController = TextEditingController(text: identity.hostAddress);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('电脑端'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '电脑端名字',
                hintText: '打包间电脑',
              ),
            ),
            TextField(
              controller: addressController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '局域网 IP',
                hintText: '192.168.1.10',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '填电脑端那台机器的局域网 IP。手机端还没有上传功能，'
              '这里只用来试它在不在线上。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    final address = addressController.text;
    final hostName = nameController.text;
    nameController.dispose();
    addressController.dispose();

    if (saved != true) return;

    await identity.setHost(address: address, name: hostName);
    if (!mounted) return;

    setState(() {});
    await _probeHost(); // 存完立刻探一次：改了地址却还显示旧状态最误导人
  }

  /// 采集页：**取景铺满整页**，状态与操作是压在上面的浮层。
  ///
  /// ## 为什么从「取景钉住 + 其余滚动」改成全屏
  ///
  /// 需求方 2026-09-22：**页面全屏显示手机摄像头画面**。
  ///
  /// 改完全屏，原来那套 `CustomScrollView` + pinned 头**反而可以扔掉了** ——
  /// 它是为了绕开一个坑才存在的：「原生预览视图（`UiKitView`）不能放进滚动容器，
  /// iOS 上平台视图会逐帧重组，真机上的表现就是上下滑发卡」。
  /// 全屏之后取景是**底层铺满**、控件叠在上面（`Stack`），
  /// 滚动容器里压根没有平台视图了，那个坑自动消失。
  ///
  /// ## 三层，从下往上
  ///
  /// 1. **画面** —— 黑底 + 居中按 9:16 摆的预览
  /// 2. **顶部浮层** —— 状态、单号、已录时长、发货/退货标签、诊断计数
  /// 3. **底部浮层** —— 刻度盘、时长兜底询问、抽屉面板、操作按钮、抽屉入口
  ///
  /// ## ⚠️ 黑边是**故意留的**，不是没铺满
  ///
  /// 录像是 720×1280（9:16）。`CameraPreview` 按这个比例摆，用的是
  /// `Center` + `AspectRatio`，**不是 `BoxFit.cover`** ——
  /// 因为框的判定范围与画出来的框**共用同一份归一化坐标**（见 `camera_preview.dart`）。
  /// 裁掉两边会让「框内 / 框外」的口径跟着变，而用户看到的框会**骗人**。
  /// 需求方 2026-09-22 选了「保留黑边，不动判定」。
  ///
  /// 长屏（20:9）上下各约 75px 黑边；黑边本来就是黑的，远看就是满屏。
  Widget _workPage(bool recording, bool working) {
    final gate = _coordinator?.scanGate;
    final showPreview = working && gate != null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 全屏取景是黑底，状态栏默认的深色字压在上面看不见。
      value: SystemUiOverlayStyle.light,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── ① 画面：铺满整页 ──
          ColoredBox(
            color: Colors.black,
            child: showPreview
                ? CameraPreview(viewfinder: gate.viewfinder)
                : _idleScreen(),
          ),

          // ── ② 顶部浮层：状态与诊断计数 ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _statusOverlay(recording, working),
          ),

          // ── ③ 底部浮层：刻度盘 + 询问 + 抽屉 + 操作 ──
          //
          // ⚠️ **不能写成 `Positioned(bottom: 0)`**，虽然只差这一层 `Align`。
          //
          // 只给 `bottom` 的 `Positioned` 传下来的是**无界高度**
          // （`RenderStack` 只在 top/bottom 都给、或给了 height 时才约束高度）。
          // 无界高度下 `RenderFlex` 走不到弹性分支 —— 于是列里的 `Flexible`
          // **完全不生效**，`_sheetBody()` 那个 `Flexible` 就是个摆设，
          // 键盘弹起来时面板顶部依旧从屏幕顶上冒出去（实测 y = -38）。
          //
          // `Positioned.fill` + `Align(bottomCenter)` 先把高度**框死在正文高度**内，
          // 再由 `Align` 松约束给孩子，`Flexible` 才真的能把面板压扁。
          Positioned.fill(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _actionOverlay(recording, working, showPreview),
            ),
          ),
        ],
      ),
    );
  }

  /// 相机还没开时铺在底层的提示。
  ///
  /// **不画一块假的取景框**：没开相机就没有画面，画个框在那儿等于告诉用户
  /// 「把面单放进去」，而他放进去什么都不会发生。
  Widget _idleScreen() => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '相机还没开。\n点下面的「开始工作」开相机。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.6),
          ),
        ),
      );

  /// 顶部浮层：谁在这儿、在录什么、录了多久、盘上什么情况。
  ///
  /// 前三项给操作员看，最后那行**诊断计数给真机验收看** ——
  /// 「打点 N 条」是打点那条验收唯一的当场凭据（打点与收尾是两条独立的链，
  /// 各要各的数字），所以它必须**不用点开任何东西**就能看见。
  Widget _statusOverlay(bool recording, bool working) {
    return _scrim(
      top: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  recording
                      ? Icons.fiber_manual_record
                      : (working ? Icons.photo_camera : Icons.stop_circle_outlined),
                  color: recording ? Colors.redAccent : Colors.white70,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // 「在工作（相机开着）」和「在录」是两回事，界面上要分得清。
                    recording
                        ? '录制中 · ${_coordinator?.currentWaybill ?? ""}'
                        : _status,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (recording) ...[
                  const SizedBox(width: 8),
                  Text(
                    '已录 ${_two(_elapsed.inMinutes)}:${_two(_elapsed.inSeconds % 60)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                // 这一件是发货还是退货。两栏的采集流程一模一样，
                // 操作员得能一眼看出自己在哪一栏 —— 否则录完了才发现归类错了。
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_isReturn ? '退货' : '发货'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '工作区 $_sessionCount（未收尾 $_pendingCount）'
              ' · 索引 $_entryCount · 打点 $_punchCount',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部浮层：刻度盘 → 时长兜底询问 → 抽屉面板 → 操作按钮 → 抽屉入口。
  ///
  /// ## 为什么刻度盘在**这一列里**、而不是 `Positioned` 贴边
  ///
  /// 这一列的高度是变的（抽屉开合、询问弹不弹）。刻度盘如果按固定 `bottom`
  /// 贴边，迟早会被某个高度的抽屉盖住 —— 而「盖住」在真机上表现为
  /// **表盘突然消失**，看起来像坏了。
  /// 放进这一列就永远不会重叠，它自己会被推上去。
  ///
  /// 位置仍然在**右下、贴右缘**，与规格 §3.1.2 的「屏幕边缘的半圆刻度盘」一致：
  /// 右手拇指从边缘划过来顺手，也不挡取景框中心（面单必须放进中心框才认）。
  Widget _actionOverlay(bool recording, bool working, bool showPreview) {
    return _scrim(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showPreview)
              Align(
                alignment: Alignment.centerRight,
                child: ZoomDial(
                  ratio: _zoom,
                  maxZoom: _maxZoom,
                  onChanged: _onZoomChanged,
                ),
              ),

            // 时长兜底询问。**放在抽屉面板上面**，这样抽屉开着它也看得见 ——
            // 一个会被抽屉挡住的「是否停止」问询，用户会当它不存在。
            if (_askingToContinue) _durationPrompt(),

            // `Flexible` 是为了小屏 / 键盘弹起来时**面板先让位**，而不是整列溢出。
            // 下面那排按钮和抽屉入口必须一直够得着 —— 它们一没，页面上就没有
            // 任何出口了（`mainAxisSize: min` 的列溢出时是直接从底部裁掉）。
            if (_workSheet != null) Flexible(child: _sheetBody()),

            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: working || _starting ? null : _startWorking,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始工作'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: working ? _stopWorking : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('结束工作'),
                    style: _onScrim,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: recording ? _stopCurrentRecording : null,
                icon: const Icon(Icons.crop_free),
                label: const Text('停止当前录制（相机继续开着）'),
                style: _onScrim,
              ),
            ),
            _sheetTabs(),
          ],
        ),
      ),
    );
  }

  /// 压在画面上的一层：上/下两端深、中间透明。
  ///
  /// 用渐变而不是整块纯色，是为了**中间那段取景尽可能干净** ——
  /// 操作员是透过这块屏看面单的。
  ///
  /// [top] 为真时方向反过来（顶部浮层用）。
  Widget _scrim({required Widget child, bool top = false}) {
    const solid = 0.72;
    const clear = 0.0;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.bottomCenter : Alignment.topCenter,
          end: top ? Alignment.topCenter : Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: clear),
            Colors.black.withValues(alpha: solid),
          ],
        ),
      ),
      child: SafeArea(top: top, bottom: !top, child: child),
    );
  }

  /// 深色底上的次要按钮：默认配色是深蓝字 + 浅灰边，压在画面上根本看不清。
  static final _onScrim = OutlinedButton.styleFrom(
    foregroundColor: Colors.white,
    side: const BorderSide(color: Colors.white70),
  );

  /// 时长兜底询问（规格 §3.3.4）。
  Widget _durationPrompt() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Text(
            '录制时间即将超时，是否需要停止录制？',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FilledButton(
                onPressed: () =>
                    _coordinator?.onDurationPromptAnswered(continueRecording: false),
                child: const Text('停止'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _coordinator?.onDurationPromptAnswered(continueRecording: true),
                child: const Text('继续'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 抽屉入口。展开的那一块显示 `▾`，其余显示 `▸`。
  ///
  /// 每个入口带 `Key`：面板标题里也含「手动输入」这四个字，按下之后
  /// `find.textContaining` 会同时命中入口和面板，测试没法点。
  Widget _sheetTabs() {
    Widget tab(_WorkSheet sheet, String label) => Expanded(
          child: TextButton(
            key: Key('work-sheet-${sheet.name}'),
            onPressed: () => setState(
              () => _workSheet = _workSheet == sheet ? null : sheet,
            ),
            child: Text(
              '$label ${_workSheet == sheet ? '▾' : '▸'}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        );

    return Row(
      children: [
        tab(_WorkSheet.manual, '手动输入'),
        tab(_WorkSheet.events, '事件 ${_events.length}'),
        tab(_WorkSheet.diagnostics, '诊断'),
      ],
    );
  }

  Widget _sheetBody() {
    return _panel(
      switch (_workSheet!) {
        _WorkSheet.manual => _manualEntrySheet(),
        // 固定高度 + 内部自滚：这块**不能**用 `SingleChildScrollView` 包，
        // 里面是 `ListView`，两个都可滚会直接报「高度无界」。
        _WorkSheet.events => SizedBox(height: 140, child: _eventsList()),
        _WorkSheet.diagnostics => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(child: _diagnosticsBody()),
          ),
      },
    );
  }

  /// 抽屉面板：**不透明**的浅色卡片。
  ///
  /// 操作条可以半透明（那是按钮，认得形状就行），**正文不行** ——
  /// 12 号字压在一幅画面很乱的取景上根本读不出来。
  Widget _panel(Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  /// 「手动输入单号」—— 规格 §3.2.2 要求的兜底。
  ///
  /// > 框内始终识别不到时，用户必须能手动输入单号兜底，**且不打断当前录制**。
  ///
  /// 「不打断」指的是**不经过停录**：这个面板是叠在画面上的，录制一直在跑。
  Widget _manualEntrySheet() {
    // 自己可滚：外面那层 `Flexible` 会给它一个上界，内容超过就内部滚，
    // 而不是把下面那排按钮顶出屏幕。
    return SingleChildScrollView(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('手动输入（扫码失灵时的兜底）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          '规格 §3.2.2：框内始终识别不到时，用户必须能手动输入单号兜底，'
          '且不打断当前录制。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _waybillController,
          decoration: const InputDecoration(
            labelText: '单号',
            helperText: '在录时输入并点下面按钮 = 复扫；未录时 = 开一段新的。',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _coordinator?.isWorking == true ? _simulateScan : null,
          icon: const Icon(Icons.keyboard),
          label: const Text('当作扫到了这个单号'),
        ),
      ],
      ),
    );
  }

  /// 事件列表。
  ///
  /// **它内部没有平台视图，滚起来是顺的** —— 这也是它敢放在取景画面上的原因。
  Widget _eventsList() {
    if (_events.isEmpty) {
      return const Center(child: Text('（还没有事件）', style: TextStyle(fontSize: 12)));
    }

    return ListView.builder(
      itemCount: _events.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(_events[index], style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  /// 诊断：盘上的实况与收尾结果。
  ///
  /// 这些数字真机验收时**要盯着看**，所以给它们一个固定的去处，
  /// 而不是散在各处等人找。
  Widget _diagnosticsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('工作区 $_sessionCount 个会话（未收尾 $_pendingCount）'),
        Text('索引 $_entryCount 条 · 打点 $_punchCount 条'),
        const SizedBox(height: 8),
        Text(
          '单段时长 ${RecordingCoordinator.defaultSegmentDuration.inMinutes} 分钟 —— '
          '崩溃最多丢这一段，所以每录满一段就自动封一个文件',
          style: const TextStyle(fontSize: 12),
        ),
        if (_recovered.isNotEmpty) ...[
          const Divider(height: 20),
          _recoveredBody(),
        ],
      ],
    );
  }


  /// 改设置：**先落盘，再刷界面**。
  ///
  /// [RecordingSettings] 只在 `_bootstrap` 里读过一次，之后每次改动都由这里
  /// 同步进去并写回盘。
  ///
  /// `_settings == null` 表示盘上的设置还没读出来。这时**直接不动** ——
  /// 改了也会被随后读出来的盘上值覆盖，等于改了没反应还看不出来。
  /// 设置页的控件在这一小段时间里是禁用的，见 [_settingsReady]。
  void _updateSettings({
    WorkMode? mode,
    StaticStopSetting? staticStop,
    DurationFallbackSetting? durationFallback,
  }) {
    final settings = _settings;
    if (settings == null) return;

    setState(() {
      if (mode != null) _mode = mode;
      if (staticStop != null) _staticStop = staticStop;
      if (durationFallback != null) _durationFallback = durationFallback;

      settings.mode = _mode;
      settings.staticStop = _staticStop;
      settings.durationFallback = _durationFallback;
    });

    // **不等它写完。** 写盘是几十毫秒的 I/O，而这是点一下开关就要走的路；
    // 失败了也不该拦住任何事 —— 设置读不出来/写不进去都不影响录制（I4）。
    unawaited(settings.save());
  }

  /// 盘上的设置读出来了没有。没读出来时设置页的控件全部禁用。
  bool get _settingsReady => _settings != null;

  /// 设置页：工作模式 → 两个兜底档位 → 验收工具。
  ///
  /// ## 这一页的两条规矩
  ///
  /// ① **改了立刻落盘。** 落盘之前这些值只活在内存里，重启就回默认档位 ——
  ///    而「时长兜底档位交给用户自己选」是需求方 2026-09-21 特意要的，
  ///    每次开 App 都抹掉等于没做。
  ///
  /// ② **验收工具必须长得不像产品设置。** 「时长兜底加速」会把**真实录制**的
  ///    首次询问压到 20 秒。它要是和别的开关长一样，验收完忘了关，
  ///    正常录 4 分钟的活 20 秒就被问一次「是否停止」。
  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _modeCard(),
        const SizedBox(height: 12),
        _fallbackCard(),
        const SizedBox(height: 12),
        _acceptanceCard(),
        const SizedBox(height: 12),
        _whenCard(),
      ],
    );
  }

  // ── ① 工作模式 ───────────────────────────────

  Widget _modeCard() {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('工作模式', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('决定这一件什么时候算录完（规格 §3.3.1）。',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            SegmentedButton<WorkMode>(
              segments: const [
                ButtonSegment(value: WorkMode.continuousScan, label: Text('连续扫')),
                ButtonSegment(value: WorkMode.sameWaybillStop, label: Text('同码停')),
                ButtonSegment(
                    value: WorkMode.scanThenStaticStop, label: Text('扫码静止')),
              ],
              selected: {_mode},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(mode: value.first)
                  : null,
            ),
            const SizedBox(height: 12),

            // 只讲**选中的那一个**。三个模式的说明同时铺出来，用户得先自己
            // 对号入座；而人真正要回答的问题是「我现在这个会怎么停」。
            Container(
              key: const Key('settings-mode-blurb'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_modeTitle(_mode),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_modeBlurb(_mode), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '三个模式都一样：扫到别的单号不会停 —— 二次扫描只有单号相同才停'
              '（§3.3.2 错码保护）。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  static String _modeTitle(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan => '连续扫 —— 手动停',
        WorkMode.sameWaybillStop => '同码停 —— 复扫同码就停',
        WorkMode.scanThenStaticStop => '扫码静止 —— 静止够时长才停',
      };

  static String _modeBlurb(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan =>
          '识别到单号就开录。停只能靠手动按「停止当前录制」，或者下面两个兜底机制。',
        WorkMode.sameWaybillStop =>
          '识别到单号就开录，复扫到同一个单号就停。'
              '三个模式里只有它不用人额外做什么就能自己停。',
        WorkMode.scanThenStaticStop =>
          '识别到单号就开录。包裹要先离开画面、再回到画面，'
              '并且静止够下面设的时长才停。\n'
              '注意：这个模式下复扫同码不停，只认静止 —— '
              '这就是它和「同码停」的区别。',
      };

  // ── ② 两个兜底档位 ───────────────────────────

  Widget _fallbackCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('防忘停录', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              '两个兜底互相独立：关掉一个不影响另一个。任何一个到点，录制就停。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),

            _settingTitle('静止停录', '画面一直不动、够这个时长就停（§3.3.3）。'),
            const SizedBox(height: 8),
            SegmentedButton<StaticStopSetting>(
              segments: const [
                ButtonSegment(value: StaticStopSetting.off, label: Text('关闭')),
                ButtonSegment(value: StaticStopSetting.minutes2, label: Text('2 分')),
                ButtonSegment(value: StaticStopSetting.minutes3, label: Text('3 分')),
                ButtonSegment(value: StaticStopSetting.minutes4, label: Text('4 分')),
                ButtonSegment(value: StaticStopSetting.minutes5, label: Text('5 分')),
              ],
              selected: {_staticStop},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(staticStop: value.first)
                  : null,
            ),

            const Divider(height: 28),

            _settingTitle(
              '时长兜底',
              '不管画面动不动，录满这个分钟数就弹一次「是否停止」；'
                  '不操作 1 分钟后自动停（§3.3.4）。',
            ),
            const SizedBox(height: 8),
            SegmentedButton<DurationFallbackSetting>(
              segments: const [
                ButtonSegment(value: DurationFallbackSetting.off, label: Text('关闭')),
                ButtonSegment(value: DurationFallbackSetting.minutes4, label: Text('4 分')),
                ButtonSegment(value: DurationFallbackSetting.minutes5, label: Text('5 分')),
                ButtonSegment(value: DurationFallbackSetting.minutes6, label: Text('6 分')),
              ],
              selected: {_durationFallback},
              onSelectionChanged: _settingsReady
                  ? (value) => _updateSettings(durationFallback: value.first)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingTitle(String title, String blurb) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(blurb, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  // ── ③ 验收工具 ───────────────────────────────

  /// 真机验收用的开关。**故意做成一眼能看出不是产品设置的样子**：
  /// 琥珀底 + ⚠️ 标题 + 明说「不落盘」。
  ///
  /// 它不落盘这件事要在界面上说出来 —— 否则验收的人会以为「我上次开了」
  /// 而这次没开，或者反过来以为「我关了它就永久关了」。
  Widget _acceptanceCard() {
    return Card(
      color: Colors.amber.withValues(alpha: 0.18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _accelerated,
              onChanged: (value) => setState(() => _accelerated = value),
              title: const Text('⚠️ 时长兜底加速（验收用，不是产品设置）'),
              subtitle: const Text(
                '把时长兜底的首次询问压到 20 秒、宽限 10 秒，免得验收真的等 4 分钟。'
                '只压询问时机，不动档位本身，也不碰静止停录。',
              ),
            ),
            const Text(
              '重启 App 自动归位（关）—— 它不写进配置。'
              '所以做完验收记得自己也关掉：开着它，真实录制会在开录 20 秒后就被问一次。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // ── ④ 什么时候生效 ───────────────────────────

  /// 说清「现在改的东西什么时候起作用」。
  ///
  /// ⚠️ **这不是一句客套提示，是在补一个真实的静默。** 模式与档位是
  /// [RecordingCoordinator] 的**构造参数**（没有 setter），编排器只在
  /// 「开始工作」时重建（`_startWorking` 里的 `_buildCoordinator`）。
  /// 所以在工作中改设置，当前这一段仍然按旧设置走 —— 界面不说明的话，
  /// 用户改完看到没反应，只会以为开关坏了。
  ///
  /// **不改成「立刻生效」是有意的**：工作途中换编排器会把相机会话和界面状态
  /// 拆开（新编排器的 `isWorking` 是 false，而相机是真开着的），
  /// 那个态下「结束工作」也关不掉相机 —— 用一次模式切换换一个相机泄漏不值。
  Widget _whenCard() {
    final working = _coordinator?.isWorking ?? false;

    return Card(
      color: working ? Colors.amber.withValues(alpha: 0.18) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          working
              ? '⚠️ 正在工作中。现在改的设置这一段不生效 —— '
                  '等下次「开始工作」重建编排器时才按新设置走。'
              : '这些设置在点「开始工作」时生效。改完直接去发货栏开始工作就行，'
                  '不用退出去重进。',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  /// 孤儿收尾结果的正文，收进「诊断」抽屉里。
  ///
  /// 原来它是一张常驻的琥珀色卡片。改成抽屉之后**没有降级**：
  /// 抽屉入口上的「诊断」两个字是常驻的，展开就在；而这张卡片的出现是
  /// 小概率事件（只有上次被杀过才有），常驻占着取景画面不值得。
  Widget _recoveredBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('启动时收尾的孤儿分段', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          '这些是上次没录完就被中断的会话。它们已经封文件、算哈希、写进索引。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        for (final outcome in _recovered)
          Text(
            '· ${outcome.succeeded ? "已收尾" : "失败"} · '
            '${outcome.segments.length} 段 · ${_triggerLabel(outcome.reason)}',
          ),
      ],
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// `MM-DD HH:mm`。备份页一行里塞得下，且不需要年份 —— 手机上的东西都是最近的。
  static String _stamp(DateTime at) =>
      '${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}';

  /// `mm:ss`（超过一小时就是三位数的分钟，不折成小时 —— 一段录像不会是几小时）。
  static String _durationLabel(Duration d) =>
      '${_two(d.inMinutes)}:${_two(d.inSeconds % 60)}';

  static String _sizeLabel(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;

    if (bytes < kb) return '$bytes B';
    if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / gb).toStringAsFixed(2)} GB';
  }

  static String _modeLabel(WorkMode mode) => switch (mode) {
        WorkMode.continuousScan => '连续扫',
        WorkMode.sameWaybillStop => '同码停',
        WorkMode.scanThenStaticStop => '扫码静止停录',
      };

  static String _triggerLabel(StopTrigger trigger) => switch (trigger) {
        StopTrigger.manual => '手动',
        StopTrigger.sameWaybillRescan => '同码复扫',
        StopTrigger.sceneStatic => '画面静止',
        StopTrigger.durationFallback => '时长兜底',
        StopTrigger.resourceCritical => '资源告警',
        StopTrigger.processKilled => '进程被杀',
      };
}

