import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recorder_config.dart';
import 'package:vidlog_mobile/recording/recorder_events.dart';
import 'package:vidlog_mobile/recording/recorder_gateway.dart';
import 'package:vidlog_mobile/recording/recording_coordinator.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/recording_workspace.dart';
import 'package:vidlog_mobile/recording/session_finalizer.dart';
import 'package:vidlog_mobile/recording/work_mode.dart';

/// 编排层 —— 把原生录制器、停录状态机、会话工作区接起来。
///
/// 最容易写错的一件事是：**分段一封闭就必须立刻落盘**。
/// 它是「杀掉 App 后重启能收尾孤儿」的前提，所以这里重点验它。
void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-coord-');
    root = temp.path;
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  final waybill = WaybillNumber.parse('SF1000000001');
  final otherWaybill = WaybillNumber.parse('YT9999999999');

  /// 可控时钟 —— 测试要能随意推进时间。
  late int nowMs;
  int clock() => nowMs;

  late FakeGateway gateway;
  late RecordingWorkspace workspace;
  late JsonLinesRecordingIndex index;
  late List<RecorderAction> actions;

  RecordingCoordinator make({
    WorkMode mode = WorkMode.sameWaybillStop,
    RecorderConfig config = const RecorderConfig(staticStop: StaticStopSetting.off),
  }) {
    // 必须先建列表再构造 —— `actions.add` 是构造时就捕获的，
    // 之后再给 actions 赋值就捕获不到了。
    actions = <RecorderAction>[];

    gateway = FakeGateway();
    workspace = RecordingWorkspace('$root/work');
    index = JsonLinesRecordingIndex('$root/index.jsonl');

    return RecordingCoordinator(
      gateway: gateway,
      workspace: workspace,
      finalizer: SessionFinalizer(rootDirectory: root, index: index),
      mode: mode,
      config: config,
      clock: clock,
      onAction: actions.add,
    );
  }

  /// 造一个分段文件并上报「已封闭」。
  Future<void> closeSegment(
    RecordingCoordinator coordinator, {
    required String sessionId,
    required int sequence,
    required int startMs,
    required int endMs,
  }) async {
    final dir = Directory(workspace.sessionDirectory(sessionId))..createSync(recursive: true);
    final file = File('${dir.path}/segment-${sequence.toString().padLeft(3, '0')}.mp4')
      ..writeAsBytesSync(List<int>.generate(32, (i) => i + sequence));

    gateway.emit(SegmentClosedEvent(
      filePath: file.path,
      sequence: sequence,
      startedAtMs: startMs,
      endedAtMs: endMs,
    ));

    // 事件处理里有**真实文件 I/O**，必须等编排器把在途事件处理完。
    await coordinator.waitForPendingEvents();
  }

  // ─────────────────────────────────────────────
  // 开录
  // ─────────────────────────────────────────────

  group('开始录制', () {
    test('开录前先写 manifest', () async {
      // 顺序是刻意的：反过来的话，相机开成功、manifest 还没写就被杀，
      // 那段录像是彻底找不回来的。
      final coordinator = make();
      nowMs = 1000;

      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');

      final orphans = await workspace.listOrphans();
      // 此刻还没有分段，所以不算「可收尾的孤儿」；但 manifest 必须已存在。
      expect(orphans, isEmpty);

      final sessionDir = Directory(workspace.sessionDirectory(coordinator.sessionId!));
      expect(File('${sessionDir.path}/${RecordingWorkspace.manifestFileName}').existsSync(),
          isTrue);

      await coordinator.dispose();
    });

    test('把工作目录与分段时长交给原生层', () async {
      final coordinator = make();
      nowMs = 1000;

      await coordinator.start(
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segmentDuration: const Duration(minutes: 3),
      );

      expect(gateway.started, isTrue);
      expect(gateway.directory, contains(coordinator.sessionId!));
      expect(gateway.segmentDuration, const Duration(minutes: 3));

      await coordinator.dispose();
    });
  });

  // ─────────────────────────────────────────────
  // 分段落盘 —— 孤儿恢复的前提
  // ─────────────────────────────────────────────

  group('分段一封闭就落盘', () {
    test('分段事件立刻写进 manifest', () async {
      final coordinator = make();
      nowMs = 1000;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');
      final sessionId = coordinator.sessionId!;

      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      // 不做任何「停止」动作，直接把工作区当成「刚被杀死」来读
      final orphans = await workspace.listOrphans();

      expect(orphans, hasLength(1),
          reason: '分段封闭后立刻要有可收尾的会话 —— 进程随时可能被杀');
      expect(orphans.single.segments, hasLength(1));

      await coordinator.dispose();
    });

    test('多个分段都会累积进去', () async {
      final coordinator = make();
      nowMs = 1000;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');
      final sessionId = coordinator.sessionId!;

      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);
      await closeSegment(coordinator, sessionId: sessionId, sequence: 1, startMs: 30000, endMs: 60000);

      final orphans = await workspace.listOrphans();

      expect(orphans.single.segments, hasLength(2));
      expect(orphans.single.segments.map((s) => s.sequence), [0, 1]);

      await coordinator.dispose();
    });

    test('原生报错会被记下来并可读', () async {
      final coordinator = make();
      nowMs = 1000;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');

      gateway.emit(const RecorderFailedEvent('相机被抢占'));
      await pumpEventQueue();

      expect(coordinator.lastError, '相机被抢占');
      expect(actions.whereType<WarnResource>(), isNotEmpty,
          reason: '原生错误必须让用户看见，不能静默');

      await coordinator.dispose();
    });
  });

  // ─────────────────────────────────────────────
  // 停录 → 收尾
  // ─────────────────────────────────────────────

  group('停录与收尾', () {
    test('手动停止会收尾、写索引、打标记', () async {
      final coordinator = make();
      nowMs = 1000;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');
      final sessionId = coordinator.sessionId!;

      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);
      await coordinator.onManualStop();

      expect(gateway.stopped, isTrue);
      expect(coordinator.isRecording, isFalse);

      final entries = await index.loadAll();
      expect(entries, hasLength(1));
      expect(entries.single.waybill, waybill);

      // 收尾成功后不再是孤儿
      expect(await workspace.listOrphans(), isEmpty);

      await coordinator.dispose();
    });

    test('复扫同码停止（同码停模式）', () async {
      final coordinator = make(mode: WorkMode.sameWaybillStop);
      nowMs = 1000;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      nowMs = 2000;
      await coordinator.onWaybillDetected(waybill);

      expect(coordinator.isRecording, isFalse);
      expect((await index.loadAll()), hasLength(1));

      await coordinator.dispose();
    });

    test('错码保护：扫到别的单号不停，会提示', () async {
      final coordinator = make(mode: WorkMode.sameWaybillStop);
      nowMs = 1000;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      nowMs = 2000;
      await coordinator.onWaybillDetected(otherWaybill);

      expect(coordinator.isRecording, isTrue);
      expect(
        actions.whereType<Speak>().map((a) => a.prompt),
        contains(VoicePrompt.differentWaybill),
      );

      await coordinator.dispose();
    });

    test('画面静止到点会停（心跳驱动）', () async {
      final coordinator = make(
        mode: WorkMode.continuousScan,
        config: const RecorderConfig(staticStop: StaticStopSetting.minutes3),
      );
      nowMs = 0;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      nowMs = 3 * 60 * 1000;
      await coordinator.handleHeartbeat();

      expect(coordinator.isRecording, isFalse);
      expect(actions.whereType<StopRecording>().single.trigger, StopTrigger.sceneStatic);

      await coordinator.dispose();
    });

    test('收尾失败时不打标记，保持孤儿身份', () async {
      // 索引写不进去 —— 文件在盘上但检索不到，不算收尾成功。
      final coordinator = RecordingCoordinator(
        gateway: gateway = FakeGateway(),
        workspace: workspace = RecordingWorkspace('$root/work'),
        finalizer: SessionFinalizer(rootDirectory: root, index: _ThrowingIndex()),
        mode: WorkMode.sameWaybillStop,
        config: const RecorderConfig(staticStop: StaticStopSetting.off),
        clock: clock,
      );
      actions = [];

      nowMs = 1000;
      await coordinator.start(waybill: waybill, sourceDeviceId: 'device-1');
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      await coordinator.onManualStop();

      final orphans = await workspace.listOrphans();
      expect(orphans, hasLength(1), reason: '收尾失败的会话要留给下次启动重试');

      await coordinator.dispose();
    });

    test('空闲时重复调停止/心跳不会出事', () async {
      final coordinator = make();

      await coordinator.onManualStop();
      await coordinator.handleHeartbeat();
      await coordinator.onWaybillDetected(waybill);

      expect(coordinator.isRecording, isFalse);

      await coordinator.dispose();
    });
  });
}

class _ThrowingIndex implements RecordingIndex {
  @override
  Future<void> add(RecordingEntry entry) async => throw const FileSystemException('磁盘满了');

  @override
  Future<List<RecordingEntry>> loadAll() async => [];
}

/// 假的原生录制器 —— 测试里可以随意造事件，不用起引擎。
class FakeGateway implements RecorderGateway {
  final controller = StreamController<NativeRecorderEvent>.broadcast();

  bool started = false;
  bool stopped = false;
  String? directory;
  Duration? segmentDuration;

  @override
  Stream<NativeRecorderEvent> get events => controller.stream;

  void emit(NativeRecorderEvent event) => controller.add(event);

  @override
  Future<bool> hasCameraPermission() async => true;

  @override
  Future<bool> requestCameraPermission() async => true;

  @override
  Future<void> startSession({
    required String directory,
    required Duration segmentDuration,
  }) async {
    started = true;
    this.directory = directory;
    this.segmentDuration = segmentDuration;
  }

  @override
  Future<void> stopSession() async => stopped = true;

  @override
  Future<void> setZoom(double ratio) async {}
}
