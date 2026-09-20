import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../primitives.dart';
import '../recording/recorder_config.dart';
import '../recording/recorder_events.dart';
import '../recording/recorder_gateway.dart';
import '../recording/recording_coordinator.dart';
import '../recording/recording_index.dart';
import '../recording/recording_workspace.dart';
import '../recording/session_finalizer.dart';
import '../recording/work_mode.dart';

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

  RecordingCoordinator? _coordinator;
  Timer? _heartbeat;

  WorkMode _mode = WorkMode.sameWaybillStop;
  StaticStopSetting _staticStop = StaticStopSetting.fallback;

  /// 把时长兜底缩短，好让验收不必真的等 4 分钟。
  /// **只影响时长兜底**，静止档位保持真实值 —— 那一条本来就该按真实时长验。
  bool _accelerated = false;

  final _waybillController = TextEditingController();

  String _status = '正在准备…';
  final List<String> _events = [];
  bool _askingToContinue = false;
  bool _starting = false;

  /// 启动时收尾的孤儿。
  List<FinalizeOutcome> _recovered = const [];

  /// 当前会话已录时长。
  Duration _elapsed = Duration.zero;

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

  RecorderConfig get _config => _accelerated
      ? const RecorderConfig(
          staticStop: StaticStopSetting.fallback,
          durationPromptAfter: Duration(seconds: 20),
          durationPromptRepeatEvery: Duration(seconds: 30),
          durationPromptGrace: Duration(seconds: 10),
        )
      : RecorderConfig(staticStop: _staticStop);

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
      mode: _mode,
      config: _config,
      onAction: _onAction,
    );
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
        unawaited(_refreshIndex());

      case Speak(:final prompt):
        _log('🔊 ${_promptLabel(prompt)}');

      case ShowDurationPrompt():
        setState(() => _askingToContinue = true);

      case HideDurationPrompt():
        setState(() => _askingToContinue = false);

      case WarnResource(:final reason):
        _log('⚠️ $reason');
    }
  }

  // ─────────────────────────────────────────────
  // 操作
  // ─────────────────────────────────────────────

  Future<void> _start() async {
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

      final waybill = WaybillNumber.tryParse(_waybillController.text);
      if (waybill == null) {
        setState(() => _status = '先填一个单号再开始');
        return;
      }

      _buildCoordinator(); // 换模式下重建，配置跟着走
      await _coordinator!.start(waybill: waybill, sourceDeviceId: 'this-device');

      // 心跳驱动那些「时间到了就发生」的判定（静止、时长兜底）。
      // 没有它，画面完全不动时没有任何事件，超时永远不会触发。
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_coordinator?.handleHeartbeat());
        if (mounted) {
          // 时长从编排器取 —— 它用单调时钟，墙钟在这儿算不出正确的值。
          setState(() => _elapsed = _coordinator?.elapsed ?? Duration.zero);
        }
      });
    } on Object catch (error) {
      if (mounted) setState(() => _status = '开始失败：$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    await _coordinator?.onManualStop();
  }

  /// 模拟一次扫码。
  ///
  /// 真机上还没有条码识码（那需要额外的库与许可证核对），
  /// 但**错码保护验的是状态机**：首扫 A 开录、扫 B 只提示不停、扫回 A 才停。
  /// 用手输单号就能把这条链路验完整。
  Future<void> _simulateScan() async {
    final waybill = WaybillNumber.tryParse(_waybillController.text);
    if (waybill == null) {
      setState(() => _status = '单号无效');
      return;
    }

    await _coordinator?.onWaybillDetected(waybill);
  }

  Future<void> _refreshIndex() async {
    final entries = await _index.loadAll();
    if (!mounted) return;
    setState(() {
      _status = '已收尾 · 索引里共 ${entries.length} 条';
    });
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

    return Scaffold(
      appBar: AppBar(title: const Text('VidLog · 采集')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusCard(recording),
          const SizedBox(height: 12),
          if (_recovered.isNotEmpty) _recoveredCard(),
          const SizedBox(height: 12),
          _settingsCard(),
          const SizedBox(height: 12),
          _controlsCard(recording),
          const SizedBox(height: 12),
          _eventsCard(),
        ],
      ),
    );
  }

  Widget _statusCard(bool recording) {
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
                  recording ? Icons.fiber_manual_record : Icons.stop_circle_outlined,
                  color: recording ? Colors.red : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(_status, style: const TextStyle(fontSize: 16)),
              ],
            ),
            if (recording) ...[
              const SizedBox(height: 8),
              Text(
                '已录 ${_two(_elapsed.inMinutes)}:${_two(_elapsed.inSeconds % 60)}',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w300),
              ),
            ],
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
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _accelerated,
              onChanged: (value) => setState(() => _accelerated = value),
              title: const Text('时长兜底加速（验收用）'),
              subtitle: const Text('4 分钟 → 20 秒，1 分钟 → 10 秒。只影响时长兜底。'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlsCard(bool recording) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _waybillController,
              decoration: const InputDecoration(
                labelText: '单号',
                helperText: '首扫开录；复扫同码停止。换一个单号再扫可验错码保护。',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: recording || _starting ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始工作'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: recording ? _stop : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: recording ? _simulateScan : null,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('模拟扫码（复扫上面那个单号）'),
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

  Widget _eventsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('事件', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_events.isEmpty)
              const Text('（还没有事件）', style: TextStyle(fontSize: 12))
            else
              for (final line in _events)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(line, style: const TextStyle(fontSize: 12)),
                ),
          ],
        ),
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

  static String _promptLabel(VoicePrompt prompt) => switch (prompt) {
        VoicePrompt.differentWaybill => '面单不同',
        VoicePrompt.durationTimeout => '录制时间即将超时，是否需要停止录制？',
        VoicePrompt.resourceWarning => '设备资源告警',
      };
}
