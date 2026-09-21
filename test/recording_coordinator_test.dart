import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/package_tracker.dart';
import 'package:vidlog_mobile/recording/punch_log.dart';
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
  late PunchLog punchLog;
  late PackageTracker tracker;
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
    punchLog = PunchLog('$root/punches.jsonl');
    tracker = PackageTracker();

    return RecordingCoordinator(
      gateway: gateway,
      workspace: workspace,
      finalizer: SessionFinalizer(rootDirectory: root, index: index),
      punchLog: punchLog,
      mode: mode,
      config: config,
      clock: clock,
      packageTracker: tracker,
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

    test('★ 已录时长要随心跳往上走', () async {
      // 真机报的：录着，但「已录」一直是 00:00。
      // 界面那一行读的是 coordinator.elapsed，所以先在这里问清楚它到底涨不涨。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      expect(coordinator.elapsed, Duration.zero, reason: '刚开录应当是 0');

      nowMs = 1000 + 65 * 1000;
      expect(coordinator.elapsed, const Duration(seconds: 65),
          reason: '65 秒后应当是 1 分 05 秒 —— 界面显示的就是这个值');

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
        punchLog: punchLog = PunchLog('$root/punches.jsonl'),
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

  // ─────────────────────────────────────────────
  // 目标跟踪（§3.3.1 扫码静止停录）
  // ─────────────────────────────────────────────

  group('目标跟踪', () {
    /// 扫码静止停录 + 只留静止这一条停录路径。
    ///
    /// 时长兜底必须关掉：它将在这几条测试的时间轴里先触发，
    /// 那时测到的就是它、不是静止门槛了。
    RecordingCoordinator staticOnly() => make(
          mode: WorkMode.scanThenStaticStop,
          config: const RecorderConfig(
            staticStop: StaticStopSetting.minutes3,
            durationFallback: DurationFallbackSetting.off,
          ),
        );

    /// 造一次识码，走的是与相机同一条路（取景框正中，不会被框滤掉）。
    void sighting(WaybillNumber bill) {
      gateway.emit(BarcodeDetectedEvent(
        text: bill.value,
        centerX: 0.5,
        centerY: 0.5,
      ));
    }

    test('★ 包裹离场 → 入场 → 静止到设定时长才停', () async {
      // 这是「扫码静止停录」与「同码停」的区别所在：
      // 复扫同码**不停**（2026-09-21 裁定），只有这条链才停。
      final coordinator = staticOnly();
      nowMs = 1000;
      await begin(coordinator);
      expect(coordinator.isRecording, isTrue);

      // 包裹离开取景框 —— 相机不会报「没见到」，所以靠心跳推出来。
      nowMs += 3 * 1000;
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();

      // 包裹回到画面：静止时钟从这一刻重新计。
      nowMs += 1000;
      sighting(waybill);
      await coordinator.waitForPendingEvents();

      // 入场后只静止 2 分钟：不够。
      nowMs += 2 * 60 * 1000;
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();
      expect(coordinator.isRecording, isTrue, reason: '入场后只静止了 2 分钟');

      // 满 3 分钟：停。
      nowMs += 61 * 1000;
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();
      expect(coordinator.isRecording, isFalse);

      await coordinator.dispose();
    });

    test('★ 包裹一直没离场，静止再久也不停', () async {
      // 这个模式的停止条件是「离场后再入场」，不是「画面静了」——
      // 后者是「画面静止停录」那一档的事。
      final coordinator = staticOnly();
      nowMs = 1000;
      await begin(coordinator);

      // 每 10 秒见到一次 = 包裹一直摆在画面里，累计 5 分钟。
      for (var i = 0; i < 30; i++) {
        nowMs += 10 * 1000;
        sighting(waybill);
        await coordinator.handleHeartbeat();
        await coordinator.waitForPendingEvents();
      }

      expect(coordinator.isRecording, isTrue, reason: '没离场过就不该被静止停掉');
      await coordinator.dispose();
    });

    test('★ 扫到别的单号，不取消被跟踪那件的离场', () async {
      // 错码保护：B 出现时 A 还在。若 B 的识码被算成「A 还在画面里」，
      // 离场就永远报不出来 —— 这个模式再也停不下来。
      final coordinator = staticOnly();
      nowMs = 1000;
      await begin(coordinator);

      nowMs += 3 * 1000;
      sighting(otherWaybill);
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();

      // A 回来 —— 只有在「A 确实被判过离场」的前提下，静止时钟才会
      // 从这一刻重新计（`TrackedPackageEntered` 会把时钟推到现在）。
      // 没推开的话，下面这 3 分钟里静止早该满了。
      nowMs += 1000;
      sighting(waybill);
      await coordinator.waitForPendingEvents();

      nowMs += 2 * 60 * 1000;
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();
      expect(coordinator.isRecording, isTrue, reason: '静止时钟必须从入场重新计');

      nowMs += 61 * 1000;
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();
      expect(coordinator.isRecording, isFalse);

      await coordinator.dispose();
    });

    test('★ 收尾之后不再跟踪上一件', () async {
      // 不收干净的话，上一件的离场会算到下一段头上 —— 而下一段
      // 是另一件包裹，那个「离场」根本不存在。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      expect(tracker.tracked, waybill);

      await coordinator.onManualStop();
      await coordinator.waitForPendingEvents();
      expect(tracker.tracked, isNull, reason: '这一件已经收了尾');

      // 下件包裹：跟踪对象换成它，而不是接着跟上一件。
      nowMs += 1000;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();
      expect(tracker.tracked, otherWaybill);

      await coordinator.dispose();
    });

    test('离场 / 入场都报给界面（验收时靠它分辨是哪种坏）', () async {
      // 没有这条观测，「扫码静止停录没停」在真机上是**分不清原因**的：
      // 可能是跟踪没认出离场，也可能是跟踪认出来了而静止判定坏了。
      final coordinator = staticOnly();
      final seen = <bool>[];
      coordinator.onPackageTrackingChanged = seen.add;

      nowMs = 1000;
      await begin(coordinator);

      nowMs += 3 * 1000;
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();

      nowMs += 1000;
      sighting(waybill);
      await coordinator.waitForPendingEvents();

      expect(seen, [true, false], reason: '先离场，后入场');

      await coordinator.dispose();
    });
  });

  // ─────────────────────────────────────────────
  // 语音播报（§3.3.2 / §3.3.4）
  // ─────────────────────────────────────────────

  group('语音播报', () {
    test('扫到不同面单 → 读出规格里那句话', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      expect(gateway.spoken, ['面单不同']);
      await coordinator.dispose();
    });

    test('★ 播报失败不拖垮停录 —— 提示丢了是小事', () async {
      // 设备没装中文语音包时，通道会抛。抛上去的话「扫回正确面单」这条
      // 停录路径会整个失败 —— 那一下本该只是提示一下就接着录。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      gateway.speakThrows = true;

      // 扫错码：只提示不停。这一步不能因为播报抛了就出事。
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();
      expect(coordinator.isRecording, isTrue);

      // 扫回正确面单：靠的就是这条路径停录，播报仍然在抛。
      await coordinator.onWaybillDetected(waybill);
      await coordinator.waitForPendingEvents();

      expect(coordinator.isRecording, isFalse, reason: '播报坏了也必须停得下来');

      await coordinator.dispose();
    });

    test('没扫错时不播报', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      expect(gateway.spoken, isEmpty);
      await coordinator.dispose();
    });
  });

  // ─────────────────────────────────────────────
  // 打点持久化（§3.2.4）
  // ─────────────────────────────────────────────

  group('打点', () {
    test('★ 开录取到单号那一刻就落盘，偏移为 0', () async {
      // 规格 §3.2.4 要的是**立即**持久化，不是会话结束时批量写 ——
      // 所以这里不等收尾，开录之后就查盘。
      final coordinator = make();
      nowMs = 1000;

      await begin(coordinator);
      final sessionId = coordinator.sessionId!;

      final punches = await punchLog.forSession(sessionId);
      expect(punches, hasLength(1));
      expect(punches.single.waybill, waybill);
      expect(punches.single.monotonicOffsetMilliseconds, 0,
          reason: '第一条打点就是会话起点，偏移必须是 0（回放跳转按它定位）');
      expect(punches.single.source, PunchSource.cameraDecoder);

      await coordinator.dispose();
    });

    test('★ 落盘不依赖收尾 —— 收尾失败也照样在盘上', () async {
      // 「打点丢了」和「录像没收尾」是两个独立的坏结果，不能绑在一起。
      final coordinator = RecordingCoordinator(
        gateway: gateway = FakeGateway(),
        workspace: workspace = RecordingWorkspace('$root/work'),
        finalizer: SessionFinalizer(rootDirectory: root, index: _ThrowingIndex()),
        punchLog: punchLog = PunchLog('$root/punches.jsonl'),
        mode: WorkMode.sameWaybillStop,
        config: const RecorderConfig(staticStop: StaticStopSetting.off),
        clock: clock,
      );
      nowMs = 1000;
      await begin(coordinator);

      await coordinator.onManualStop();

      expect(await punchLog.loadAll(), hasLength(1));
      await coordinator.dispose();
    });

    test('复扫再落一条，偏移按会话起点算', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;

      nowMs = 1000 + 90 * 1000;
      await coordinator.onWaybillDetected(waybill);
      await coordinator.waitForPendingEvents();

      final punches = await punchLog.forSession(sessionId);
      expect(punches.map((p) => p.monotonicOffsetMilliseconds), [0, 90 * 1000]);

      await coordinator.dispose();
    });

    test('★ 扫错码也打点 —— 那一刻扫到了什么必须留痕', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;

      nowMs = 1000 + 30 * 1000;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      final punches = await punchLog.forSession(sessionId);
      expect(punches.map((p) => p.waybill.value), [waybill.value, otherWaybill.value]);

      await coordinator.dispose();
    });

    test('手动输入的单号，来源标成手动', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      final sessionId = coordinator.sessionId!;
      // 同一单号 = 复扫，这个模式（同码停）会就此停录并清空 sessionId，
      // 所以要在调它之前把会话号记下来。
      await coordinator.onWaybillDetected(waybill, source: PunchSource.manualEntry);
      await coordinator.waitForPendingEvents();

      final punches = await punchLog.forSession(sessionId);
      expect(punches.map((p) => p.source),
          [PunchSource.cameraDecoder, PunchSource.manualEntry]);
      await coordinator.dispose();
    });

    test('收尾之后再扫不会挂到刚结束的那个会话上', () async {
      // 会话一收尾就该断开关系。否则下件包裹的第一条打点会被写进
      // 上一件录像里，回放时那件录像上会多出一个不属于它的跳转点。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      final first = coordinator.sessionId!;

      await coordinator.onManualStop();
      await coordinator.onWaybillDetected(waybill);
      final second = coordinator.sessionId!;

      expect(second, isNot(first));
      expect(await punchLog.forSession(first), hasLength(1));
      expect(await punchLog.forSession(second), hasLength(1));

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
  Future<void> setZoom(double ratio) async => zoomRatio = ratio;

  double? zoomRatio;

  @override
  Future<double?> maxZoom() async => 4.0;

  /// 读出来的提示，按顺序记下。
  final spoken = <String>[];

  /// 让下一次 `speak` 抛异常 —— 验「播报失败不能拖垮停录」。
  bool speakThrows = false;

  @override
  Future<void> speak(String text) async {
    if (speakThrows) throw Exception('这台设备没有 TTS');
    spoken.add(text);
  }
}
