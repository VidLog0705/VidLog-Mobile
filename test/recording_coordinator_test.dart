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

  /// 开始工作 + 扫到面单开录。
  ///
  /// 原来是 `coordinator.start(waybill:)` 一步做完，现在拆成两步：
  /// 规格 §3.2.2 的流程是「点开始工作 → 画面出现取景框 → 扫到面单才开录」。
  Future<void> begin(RecordingCoordinator coordinator, {WaybillNumber? bill}) async {
    await coordinator.startWorking(sourceDeviceId: 'device-1');
    await coordinator.onWaybillDetected(bill ?? waybill);
    await coordinator.waitForPendingEvents();
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
    test('★ manifest 必须**先于**开录落盘', () async {
      // 顺序是刻意的：反过来的话，录到一半被杀、manifest 还没写，
      // 那段录像是彻底找不回来的。
      //
      // 光看「最后 manifest 存在」验不出顺序 —— 所以这里挂在
      // **原生层开始录的那一刻**去查文件。
      final coordinator = make();
      nowMs = 1000;

      var manifestExistedWhenRecordingStarted = false;
      gateway.onStartRecording = () async {
        final dir = workspace.sessionDirectory(coordinator.sessionId!);
        manifestExistedWhenRecordingStarted =
            File('$dir/${RecordingWorkspace.manifestFileName}').existsSync();
      };

      await begin(coordinator);

      expect(manifestExistedWhenRecordingStarted, isTrue,
          reason: '开录时 manifest 必须已经在盘上了');

      await coordinator.dispose();
    });

    test('★ 默认单段时长的上限是 2 分钟', () async {
      // 这个值直接决定「崩溃最多丢多少录像」—— 在写的那一段救不回来
      // （MP4 没有 moov 就是播不了），只能靠缩短分段把损失窗口压小。
      //
      // 真机上踩过：默认 5 分钟时录了 1 分多钟就杀掉 App，
      // **一段都还没封**，重启后毫不知情，那一分钟全丢。
      // 所以这里断言的是「不许调大」，不是「正好等于某个值」。
      expect(
        RecordingCoordinator.defaultSegmentDuration,
        lessThanOrEqualTo(const Duration(minutes: 2)),
        reason: '分段太长会让一次崩溃丢掉整单的证据',
      );

      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      expect(gateway.segmentDuration, RecordingCoordinator.defaultSegmentDuration);

      await coordinator.dispose();
    });

    test('把工作目录与分段时长交给原生层', () async {
      final coordinator = make();
      nowMs = 1000;

      await coordinator.startWorking(
        sourceDeviceId: 'device-1',
        segmentDuration: const Duration(minutes: 3),
      );
      await coordinator.onWaybillDetected(waybill);
      await coordinator.waitForPendingEvents();

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
      await begin(coordinator);
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
      await begin(coordinator);
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
      await begin(coordinator);

      final failures = <String>[];
      coordinator.onNativeFailure = failures.add;

      gateway.emit(const RecorderFailedEvent('相机被抢占'));
      await pumpEventQueue();

      expect(coordinator.lastError, '相机被抢占');
      expect(failures, ['相机被抢占'],
          reason: '原生错误必须让用户看见，不能静默');

      await coordinator.dispose();
    });
  });

  // ─────────────────────────────────────────────
  // 开始工作 / 开录 是两件事（规格 §3.2.2）
  // ─────────────────────────────────────────────

  group('开始工作与开录分开', () {
    test('★ 开始工作只开相机，不录', () async {
      // 规格 §3.2.2：点「开始工作」→ 画面出现**可见的取景框**。
      // 那时还没扫码，所以不该录。
      //
      // 之前把这两件事合成一步，表现是「点了按钮屏幕上什么都没有、
      // 但其实已经在录」—— 用户既看不到画面、也没法把面单对准。
      final coordinator = make();
      nowMs = 1000;

      await coordinator.startWorking(sourceDeviceId: 'device-1');

      expect(gateway.cameraOpened, isTrue, reason: '相机要开');
      expect(gateway.started, isFalse, reason: '但还不该开始录');
      expect(coordinator.isWorking, isTrue);
      expect(coordinator.isRecording, isFalse);

      await coordinator.dispose();
    });

    test('扫到面单才开录', () async {
      final coordinator = make();
      nowMs = 1000;
      await coordinator.startWorking(sourceDeviceId: 'device-1');

      nowMs = 2000;
      await coordinator.onWaybillDetected(waybill);
      await coordinator.waitForPendingEvents();

      expect(gateway.started, isTrue);
      expect(coordinator.isRecording, isTrue);
      expect(coordinator.sessionId, isNotNull);

      await coordinator.dispose();
    });

    test('没开始工作时扫码什么都不做', () async {
      final coordinator = make();
      nowMs = 1000;

      await coordinator.onWaybillDetected(waybill);

      expect(gateway.started, isFalse);
      expect(coordinator.isRecording, isFalse);

      await coordinator.dispose();
    });

    test('★ 停掉一件之后相机还开着，可以接着扫下一件', () async {
      // 打包是一连串的：扫一件、录、复扫停、再扫下一件。
      // 每件都重开一次相机会让取景框中段、用户没法对准。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      final firstSession = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: firstSession, sequence: 0, startMs: 0, endMs: 30000);

      await coordinator.onManualStop();

      expect(coordinator.isRecording, isFalse);
      expect(gateway.cameraOpened, isTrue, reason: '相机不该被关掉');
      expect(coordinator.isWorking, isTrue, reason: '还在工作状态');

      // 扫下一件
      nowMs = 2000;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      expect(coordinator.isRecording, isTrue);
      expect(coordinator.sessionId, isNot(firstSession), reason: '这是新的一段录制');

      await coordinator.dispose();
    });

    test('结束工作会关相机', () async {
      final coordinator = make();
      nowMs = 1000;
      await coordinator.startWorking(sourceDeviceId: 'device-1');

      await coordinator.stopWorking();

      expect(coordinator.isWorking, isFalse);
      expect(gateway.cameraOpened, isFalse);

      await coordinator.dispose();
    });

    test('结束工作时正在录 → 先收尾再关相机', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      await coordinator.stopWorking();

      expect(gateway.stopped, isTrue);
      expect(gateway.cameraOpened, isFalse);
      expect(await index.loadAll(), hasLength(1), reason: '那段要收尾入库');

      await coordinator.dispose();
    });
  });

  // ─────────────────────────────────────────────
  // 相机识码（原生连续识码 → 离散扫码）
  // ─────────────────────────────────────────────

  group('相机识码', () {
    Future<RecordingCoordinator> recording() async {
      final coordinator = make(mode: WorkMode.sameWaybillStop);
      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);
      return coordinator;
    }

    void sight(String text, {double x = 0.5, double y = 0.5}) {
      gateway.emit(BarcodeDetectedEvent(text: text, centerX: x, centerY: y));
    }

    test('★ 持续识到同一单号，不会把录制停掉', () async {
      // 条码一接通最容易坏的地方：包裹就在画面里，相机会一直报它。
      // 开录时没把它标记成「刚见过」的话，第一次报就会停录 ——
      // 表现是「一扫就停，一秒都录不到」。
      final coordinator = await recording();

      for (var i = 1; i <= 10; i++) {
        nowMs = 1000 + i * 300;
        sight(waybill.value);

        // **每报一次就等处理器跑完再推进时间。**
        // 不然十个事件会挤在一起，处理器跑时读到的是同一个最终时间 ——
        // 去重阈值被一次性跨过去，包裹「一直在画面里」这个前提就不成立了。
        await coordinator.waitForPendingEvents();
      }

      expect(coordinator.isRecording, isTrue, reason: '包裹一直在画面里，不该被停');

      await coordinator.dispose();
    });

    test('拿开一会儿再放回来 → 算复扫，停录', () async {
      final coordinator = await recording();

      nowMs = 1000 + 300;
      sight(waybill.value); // 还在画面里
      await coordinator.waitForPendingEvents();
      expect(coordinator.isRecording, isTrue);

      nowMs = 1000 + 5000; // 隔了 5 秒，相当于拿开过
      sight(waybill.value);
      await coordinator.waitForPendingEvents();

      expect(coordinator.isRecording, isFalse);

      await coordinator.dispose();
    });

    test('框外的识码一律忽略', () async {
      final coordinator = await recording();

      nowMs = 1000 + 5000;
      sight(waybill.value, x: 0.02, y: 0.5); // 画面左上角，框外
      await coordinator.waitForPendingEvents();

      expect(coordinator.isRecording, isTrue, reason: '规格 §3.2.2：框外一律忽略');

      await coordinator.dispose();
    });

    test('扫到别的单号 → 走错码保护：不停、只提示', () async {
      final coordinator = await recording();

      nowMs = 1000 + 300;
      sight(otherWaybill.value);
      await coordinator.waitForPendingEvents();

      expect(coordinator.isRecording, isTrue);
      expect(
        actions.whereType<Speak>().map((a) => a.prompt),
        contains(VoicePrompt.differentWaybill),
      );

      await coordinator.dispose();
    });

    test('被采纳的识码会回调给界面，供人判断是没扫到还是没认', () async {
      final coordinator = await recording();
      final accepted = <String>[];
      coordinator.onBarcodeAccepted = (w) => accepted.add(w.value);

      nowMs = 1000 + 300;
      sight(otherWaybill.value);
      await coordinator.waitForPendingEvents();

      expect(accepted, [otherWaybill.value]);

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
      await begin(coordinator);
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
      await begin(coordinator);
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
      await begin(coordinator);
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

    test('★ 画面静止从**事件链**触发停录，也必须收得了尾', () async {
      // 真机上踩到的：静止停录成功了，但一直卡在「正在收尾」。
      // 原因是最后一段的 segmentClosed 排在「正在收尾的那个处理器」后面 ——
      // 收尾等它、它等收尾，互相等。
      //
      // 所以这条**必须由场景事件触发**，不能走心跳 ——
      // 心跳不在事件链里，走心跳验不出这个死锁（这正是当初漏掉它的原因）。
      final coordinator = make(
        config: const RecorderConfig(
          staticStop: StaticStopSetting.minutes3,
          durationFallback: DurationFallbackSetting.off,
        ),
      );
      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      // 原生层停录时会把最后一段补投出来 —— 模拟这个行为。
      gateway.emitOnStop = SegmentClosedEvent(
        filePath: '${workspace.sessionDirectory(sessionId)}/segment-001.mp4',
        sequence: 1,
        startedAtMs: 30000,
        endedAtMs: 60000,
      );
      File('${workspace.sessionDirectory(sessionId)}/segment-001.mp4')
          .writeAsBytesSync([4, 5, 6]);

      // 关键：从**场景事件**触发停录（走事件链）
      nowMs = 1000 + 3 * 60 * 1000;
      gateway.emit(const SceneSampledEvent(isStatic: true));
      await coordinator.waitForPendingEvents();

      expect(coordinator.isRecording, isFalse, reason: '该停下来');

      final entries = await index.loadAll();
      expect(entries, hasLength(2),
          reason: '两段都要入库 —— 尤其最后那段，它就是被死锁吃掉的那一段');

      await coordinator.dispose();
    });

    test('画面静止到点会停（心跳驱动）', () async {
      final coordinator = make(
        mode: WorkMode.continuousScan,
        config: const RecorderConfig(staticStop: StaticStopSetting.minutes3),
      );
      nowMs = 0;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator, sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      nowMs = 3 * 60 * 1000;
      await coordinator.handleHeartbeat();

      expect(coordinator.isRecording, isFalse);
      expect(actions.whereType<StopRecording>().single.trigger, StopTrigger.sceneStatic);

      await coordinator.dispose();
    });

    test('停止时最后一段也要被收尾', () async {
      // 原生层的契约是「stopSession 返回前最后一段已封闭并投递」，
      // 但事件走另一条通道、异步到达。少了那一步等待，
      // 最后一段 —— 刚刚录完、最不该丢的那段 —— 会被漏掉。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;

      // 停止的**那一刻**原生层才把最后一段封完
      gateway.emitOnStop = SegmentClosedEvent(
        filePath: '${workspace.sessionDirectory(sessionId)}/segment-000.mp4',
        sequence: 0,
        startedAtMs: 0,
        endedAtMs: 30_000,
      );
      Directory(workspace.sessionDirectory(sessionId)).createSync(recursive: true);
      File('${workspace.sessionDirectory(sessionId)}/segment-000.mp4')
          .writeAsBytesSync([1, 2, 3]);

      await coordinator.onManualStop();

      final entries = await index.loadAll();
      expect(entries, hasLength(1), reason: '最后一段不能被漏掉');
      expect(entries.single.evidenceId, '$sessionId-000');

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
      await begin(coordinator);
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
  Future<void> openCamera() async => cameraOpened = true;

  bool cameraOpened = false;

  /// 原生层**开始录的那一刻**的回调。
  ///
  /// 用来验证「manifest 先于开录落盘」这个顺序 —— 那是「录到一半被杀
  /// 也能找回那段录像」的前提，光看结果验不出来。
  Future<void> Function()? onStartRecording;

  @override
  Future<void> startRecording({
    required String directory,
    required Duration segmentDuration,
  }) async {
    if (onStartRecording != null) await onStartRecording!();

    started = true;
    this.directory = directory;
    this.segmentDuration = segmentDuration;
  }

  /// 停止时补投一个分段事件 —— 模拟原生层「停止时才封完最后一段」的行为。
  SegmentClosedEvent? emitOnStop;

  @override
  Future<void> stopRecording() async {
    stopped = true;
    if (emitOnStop != null) emit(emitOnStop!);
  }

  @override
  Future<void> closeCamera() async => cameraOpened = false;

  @override
  Future<void> setZoom(double ratio) async {}
}
