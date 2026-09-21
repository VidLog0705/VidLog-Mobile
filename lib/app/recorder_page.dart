import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../primitives.dart';
import '../recording/punch_log.dart';
import '../recording/recorder_config.dart';
import '../recording/recorder_events.dart';
import '../recording/recorder_gateway.dart';
import '../recording/recording_coordinator.dart';
import '../recording/recording_index.dart';
import '../recording/recording_workspace.dart';
import '../recording/session_finalizer.dart';
import '../recording/work_mode.dart';
import 'camera_preview.dart';
import 'zoom_dial.dart';

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

  /// 当前在哪一页：0 = 采集，1 = 设置。
  int _tab = 0;

  WorkMode _mode = WorkMode.sameWaybillStop;
  StaticStopSetting _staticStop = StaticStopSetting.fallback;

  /// 时长兜底档位。**与静止档位互相独立** —— 关一个不影响另一个。
  DurationFallbackSetting _durationFallback = DurationFallbackSetting.fallback;

  /// 把时长兜底的首次询问时机缩短，好让验收不必真的等 4 分钟。
  /// **只压首次询问时机**，不动档位本身，也不碰静止档位。
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

      _workspace = RecordingWorkspace('${root.path}/work');
      _index = JsonLinesRecordingIndex('${root.path}/index.jsonl');
      _finalizer = SessionFinalizer(rootDirectory: root.path, index: _index);
      // 与电脑端同一个位置（`<root>/punches.jsonl`），键名也逐字相同 ——
      // 两端的打点日志是同一份形态。
      _punchLog = PunchLog('${root.path}/punches.jsonl');

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

      await _refreshDiagnostics();
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '初始化失败：$error');
    }
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
      await _coordinator!.startWorking(sourceDeviceId: 'this-device');

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
      final entries = (await _index.loadAll()).length;
      final punches = (await _punchLog.loadAll()).length;

      if (!mounted) return;
      setState(() {
        _sessionCount = sessions;
        _pendingCount = pending;
        _entryCount = entries;
        _punchCount = punches;
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
      appBar: AppBar(title: const Text('VidLog · 采集')),
      // 用 IndexedStack 而不是 TabBarView：切到设置页时**不销毁预览视图**，
      // 切回来不会闪一下。预览层本来就有「布局时重新挂会话」的自愈逻辑，
      // 但能不重建就别重建。
      body: IndexedStack(
        index: _tab,
        children: [_workPage(recording, working), _settingsPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.videocam_outlined), label: '采集'),
          NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
        ],
      ),
    );
  }

  /// 采集页：取景、状态、操作、事件。
  ///
  /// ## 为什么是「取景钉住 + 其余滚动」
  ///
  /// 这三件事互相顶着，只能这样解：
  ///
  /// 1. **取景画面必须一直看得见** —— 那是这个页面存在的意义（要对着面单瞄）
  /// 2. **其余内容必须能滚** —— 不滚的话小屏直接溢出（真被测试抓到过：
  ///    800×600 的视口里溢出 237 像素），键盘一弹出来更是必然溢出
  /// 3. **原生预览视图（`UiKitView`）不能跟着滚** —— iOS 上平台视图在滚动容器里
  ///    会逐帧重组，真机上的表现就是上下滑动发卡
  ///
  /// `CustomScrollView` + **pinned 的 `SliverPersistentHeader`** 同时满足三条：
  /// 取景钉在顶部不参与滚动，下面的内容正常滚。
  Widget _workPage(bool recording, bool working) {
    final gate = _coordinator?.scanGate;
    final showPreview = working && gate != null;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _statusCard(recording, working),
              if (_recovered.isNotEmpty) ...[
                const SizedBox(height: 12),
                _recoveredCard(),
              ],
            ]),
          ),
        ),
        if (showPreview)
          SliverPersistentHeader(
            pinned: true,
            delegate: _PreviewHeader(
              height: MediaQuery.sizeOf(context).height * 0.36,
              child: Stack(
                children: [
                  CameraPreview(viewfinder: gate.viewfinder),

                  // 半圆刻度盘（规格 §3.1.2「屏幕边缘的半圆刻度盘」）。
                  // 贴右边缘、靠下放 —— 手指从边缘划过来顺手，也不挡住取景框中心，
                  // 而面单必须放进中心框才认（§3.2.2）。
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: ZoomDial(
                      ratio: _zoom,
                      maxZoom: _maxZoom,
                      onChanged: _onZoomChanged,
                    ),
                  ),
                ],
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _controlsCard(recording, working),
              const SizedBox(height: 12),
              _eventsCard(),
            ]),
          ),
        ),
      ],
    );
  }

  /// 设置页：工作模式与两个档位。
  ///
  /// 都是**开始工作之前**要定的东西，操作中途不会去动它们，
  /// 所以单独一页，不占采集页的地方。
  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _settingsCard(),
        const SizedBox(height: 12),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '这些设置**开始工作之前**改好。中途改了要重新开始工作才会生效 —— '
              '模式与档位是在开录时定下来的。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusCard(bool recording, bool working) {
    return Card(
      color: recording ? Colors.red.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  recording
                      ? Icons.fiber_manual_record
                      : (working ? Icons.photo_camera : Icons.stop_circle_outlined),
                  color: recording
                      ? Colors.red
                      : (working ? Colors.blueGrey : Colors.grey),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // 「在工作（相机开着）」和「在录」是两回事，界面上要分得清。
                    recording
                        ? '录制中 · ${_coordinator?.currentWaybill ?? ""}'
                        : _status,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                if (working && !recording)
                  const Text('取景中', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            if (recording) ...[
              const SizedBox(height: 8),
              Text(
                '已录 ${_two(_elapsed.inMinutes)}:${_two(_elapsed.inSeconds % 60)}',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w300),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '工作区 ${_sessionCount} 个会话'
              '（未收尾 $_pendingCount）· 索引 $_entryCount 条'
              ' · 打点 $_punchCount 条\n'
              '单段时长 ${RecordingCoordinator.defaultSegmentDuration.inMinutes} 分钟 —— '
              '崩溃最多丢这一段，所以每录满一段就自动封一个文件',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recoveredCard() {
    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
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
        ),
      ),
    );
  }

  Widget _settingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('工作模式', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<WorkMode>(
              segments: const [
                ButtonSegment(value: WorkMode.continuousScan, label: Text('连续扫')),
                ButtonSegment(value: WorkMode.sameWaybillStop, label: Text('同码停')),
                ButtonSegment(value: WorkMode.scanThenStaticStop, label: Text('扫码静止')),
              ],
              selected: {_mode},
              onSelectionChanged: (value) => setState(() => _mode = value.first),
            ),
            const SizedBox(height: 16),
            const Text('静止停录档位（§3.3.3）', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<StaticStopSetting>(
              segments: const [
                ButtonSegment(value: StaticStopSetting.off, label: Text('关闭')),
                ButtonSegment(value: StaticStopSetting.minutes2, label: Text('2')),
                ButtonSegment(value: StaticStopSetting.minutes3, label: Text('3')),
                ButtonSegment(value: StaticStopSetting.minutes4, label: Text('4')),
                ButtonSegment(value: StaticStopSetting.minutes5, label: Text('5')),
              ],
              selected: {_staticStop},
              onSelectionChanged: (value) => setState(() => _staticStop = value.first),
            ),
            const SizedBox(height: 16),
            const Text('时长兜底档位（§3.3.4）', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text(
              '与上面的静止档位**互相独立**：关一个不影响另一个。'
              '录制满设定分钟数会问一次「是否停止」，不操作 1 分钟后自动停。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            SegmentedButton<DurationFallbackSetting>(
              segments: const [
                ButtonSegment(value: DurationFallbackSetting.off, label: Text('关闭')),
                ButtonSegment(value: DurationFallbackSetting.minutes4, label: Text('4')),
                ButtonSegment(value: DurationFallbackSetting.minutes5, label: Text('5')),
                ButtonSegment(value: DurationFallbackSetting.minutes6, label: Text('6')),
              ],
              selected: {_durationFallback},
              onSelectionChanged: (value) =>
                  setState(() => _durationFallback = value.first),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _accelerated,
              onChanged: (value) => setState(() => _accelerated = value),
              title: const Text('时长兜底加速（验收用）'),
              subtitle: const Text('首次询问压到 20 秒、宽限 10 秒。只压时长兜底，不动档位。'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlsCard(bool recording, bool working) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: recording ? _stopCurrentRecording : null,
              icon: const Icon(Icons.crop_free),
              label: const Text('停止当前录制（相机继续开着）'),
            ),
            const SizedBox(height: 16),
            const Text(
              '手动输入（扫码失灵时的兜底）',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
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
              onPressed: working ? _simulateScan : null,
              icon: const Icon(Icons.keyboard),
              label: const Text('当作扫到了这个单号'),
            ),
            if (_askingToContinue) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    const Text('录制时间即将超时，是否需要停止录制？'),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        FilledButton(
                          onPressed: () => _coordinator?.onDurationPromptAnswered(
                              continueRecording: false),
                          child: const Text('停止'),
                        ),
                        OutlinedButton(
                          onPressed: () => _coordinator?.onDurationPromptAnswered(
                              continueRecording: true),
                          child: const Text('继续'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 事件列表。
  ///
  /// **可折叠、内部限高自滚。**
  /// 收录在 `Column` 里（整页不滚），所以它必须有确定的边界；
  /// 而它内部没有平台视图，滚起来是顺的。
  /// 折叠起来能把纵向空间让给取景画面 —— 平时不需要盯着事件看。
  Widget _eventsCard() {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text(
          '事件（${_events.length}）',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        children: [
          SizedBox(
            height: 140,
            child: _events.isEmpty
                ? const Center(
                    child: Text('（还没有事件）', style: TextStyle(fontSize: 12)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: _events.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(_events[index],
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

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

/// 采集页里那个**钉住不滚**的取景头。
///
/// `pinned: true` 的 `SliverPersistentHeader` 要求 min == max（整块固定高度），
/// 所以高度由调用方算好传进来。
///
/// 这么做是为了让原生预览视图**不进入滚动**：iOS 上平台视图在滚动容器里
/// 会逐帧重组，真机上就是上下滑动发卡。钉住之后它不动，滚动的是它下面的内容。
class _PreviewHeader extends SliverPersistentHeaderDelegate {
  const _PreviewHeader({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
    );
  }

  // 只比高度：取景框在同一个工作会话里不会变，没必要因为 widget 实例不同就重建。
  @override
  bool shouldRebuild(_PreviewHeader oldDelegate) => oldDelegate.height != height;
}
