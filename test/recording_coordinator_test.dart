import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/business_type.dart';
import 'package:vidlog_mobile/recording/label_store.dart';
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
  late LabelStore labels;
  late List<RecorderAction> actions;

  RecordingCoordinator make({
    WorkMode mode = WorkMode.sameWaybillStop,
    RecorderConfig config = const RecorderConfig(staticStop: StaticStopSetting.off),
    bool cameraAlreadyOpen = false,
  }) {
    // 必须先建列表再构造 —— `actions.add` 是构造时就捕获的，
    // 之后再给 actions 赋值就捕获不到了。
    actions = <RecorderAction>[];

    gateway = FakeGateway();
    workspace = RecordingWorkspace('$root/work');
    index = JsonLinesRecordingIndex('$root/index.jsonl');
    punchLog = PunchLog('$root/punches.jsonl');
    tracker = PackageTracker();
    labels = LabelStore('$root/labels.jsonl');

    return RecordingCoordinator(
      gateway: gateway,
      workspace: workspace,
      finalizer:
          SessionFinalizer(rootDirectory: root, index: index, labels: labels),
      punchLog: punchLog,
      mode: mode,
      config: config,
      clock: clock,
      packageTracker: tracker,
      cameraAlreadyOpen: cameraAlreadyOpen,
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

    test('结束工作**不关**相机（需求方 2026-09-22 定的）', () async {
      // 采集页上那个【结束】回到的是**进栏时那个状态**：
      // 相机开着、没在工作 —— 下一件包裹可以直接接着扫，表盘也一直看得见。
      final coordinator = make();
      nowMs = 1000;
      await coordinator.startWorking(sourceDeviceId: 'device-1');

      await coordinator.stopWorking();

      expect(coordinator.isWorking, isFalse);
      expect(coordinator.isCameraOpen, isTrue, reason: '相机要留着');
      expect(gateway.cameraOpened, isTrue);

      await coordinator.dispose();
    });

    test('结束工作时正在录 → 先收尾，相机留着', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      await coordinator.stopWorking();

      expect(gateway.stopped, isTrue);
      expect(coordinator.isRecording, isFalse);
      expect(coordinator.isCameraOpen, isTrue);
      expect(await index.loadAll(), hasLength(1), reason: '那段要收尾入库');

      await coordinator.dispose();
    });

    test('openCamera() 只开相机，不进工作状态、扫了也不开录', () async {
      // 需求方 2026-09-22：进发货 / 退货栏就自动开相机，但**不开始工作**。
      final coordinator = make();
      nowMs = 1000;

      await coordinator.openCamera();

      expect(coordinator.isCameraOpen, isTrue);
      expect(gateway.cameraOpened, isTrue);
      expect(coordinator.isWorking, isFalse, reason: '还没按【开始】');
      expect(coordinator.isRecording, isFalse);

      // 没在工作时扫到面单**不该**开录 —— 这正是把「开相机」与「开始工作」
      // 分开的全部意义。合在一起的话，进栏那一下就自己录起来了。
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      expect(gateway.started, isFalse);
      expect(coordinator.isRecording, isFalse);

      await coordinator.dispose();
    });

    test('closeCamera() 关掉相机；已经关了就不再关', () async {
      final coordinator = make();
      nowMs = 1000;
      await coordinator.openCamera();

      await coordinator.closeCamera();

      expect(coordinator.isCameraOpen, isFalse);
      expect(gateway.cameraOpened, isFalse);

      // 变红配方：去掉 `closeCamera` 里的 `if (!_cameraOpen) return;`
      // —— 计数变成 2（关两遍），原生会话与 Dart 的记忆就此错位。
      await coordinator.closeCamera();
      expect(gateway.cameraCloseCount, 1);

      await coordinator.dispose();
    });

    test('★ dispose() 会关掉「进栏时自动开的那台」相机', () async {
      // 回归测试：`dispose` 以前判的是 `_armed`（工作过才关相机），
      // 而进栏自动开相机之后「相机开着、却没在工作」是常态 ——
      // 照旧判法这台相机会被漏掉、指示灯一直亮。
      // 变红配方：把 `dispose` 里的 `closeCamera()` 换回 `if (_armed) …`。
      final coordinator = make();
      nowMs = 1000;

      await coordinator.openCamera(); // 只开相机，**不** startWorking

      expect(coordinator.isWorking, isFalse, reason: '确实没在工作');
      await coordinator.dispose();

      expect(gateway.cameraOpened, isFalse, reason: '这台相机不该被漏掉');
    });

    test('★ 换编排器时相机不跟着关，由新的接管', () async {
      // `recorder_page._buildCoordinator` 重建编排器时传
      // `releaseCamera: false`：相机是**进程级的同一个原生会话**，
      // 跟不换不换编排器无关。关掉再开一次只会让取景画面闪一下、
      // 让原生白重建一次捕获会话，没有任何好处。
      //
      // 变红配方：让 `dispose` 忽略 `releaseCamera`（恒关相机）→
      // `cameraOpened` 变 false，新编排器继承到的「开着」就是谎话。
      final first = make();
      nowMs = 1000;
      await first.openCamera();
      final shared = gateway; // `make()` 会换一个新 gateway，先抓住这一个

      await first.dispose(releaseCamera: false);

      // 旧编排器**仍然认这台相机开着** —— 这不是漏改：相机确实还开着，
      // 这个字段说的是原生世界的事实，不是「我还活着」。
      expect(first.isCameraOpen, isTrue);
      expect(shared.cameraOpened, isTrue, reason: '原生那台没被关掉');

      // 新编排器继承这个事实 —— 这是按【开始】时取景画面不闪的依据。
      final replacement = make(cameraAlreadyOpen: shared.cameraOpened);
      expect(replacement.isCameraOpen, isTrue);

      await replacement.dispose(); // 由它来收尾
      expect(gateway.cameraOpened, isFalse);
    });

    test('★ 换编排器时旧的事件订阅必须断掉', () async {
      // 只把字段覆盖掉的话，旧编排器还订阅着 `gateway.events` ——
      // 从此每来一条原生事件，两个编排器都会各自反应一次：各写一遍 manifest、
      // 各落一条打点、各收一次尾。按第二次【开始】就会这样，画面上看不出来。
      //
      // 变红配方：把 `dispose(releaseCamera: false)` 换成不调 dispose。
      final old = make();
      nowMs = 1000;
      await begin(old);

      final oldSawScene = <bool>[];
      old.onSceneChanged = oldSawScene.add;

      await old.dispose(releaseCamera: false);

      // 换人之后原生照旧上报 —— 旧编排器不许再听见。
      gateway.emit(SceneSampledEvent(isStatic: true));
      await old.waitForPendingEvents();

      expect(oldSawScene, isEmpty, reason: '旧订阅必须已经断掉');
      expect(gateway.cameraOpened, isTrue, reason: '相机交给下一个了');
    });
  });

  // ─────────────────────────────────────────────
  // 事件链的健壮性
  // ─────────────────────────────────────────────

  group('事件链', () {
    test('★ 一条事件出错不能毒死整条事件链', () async {
      // 回归测试：`_pending` 是用 `.then` 串起来的，一个未捕获的异常会让它
      // 变成 rejected，**后面所有事件的处理回调被整段跳过、永不恢复**。
      // 真机表现是「出一次错之后相机再也扫不动了」，日志里只有一条报错。
      // 换段式连续扫把停录从一次/班变成一次/件，这条护栏是必须的。
      //
      // 变红配方：去掉 `_enqueue` 里的 `on Object catch`。
      final coordinator = make();
      nowMs = 1000;
      await coordinator.startWorking(sourceDeviceId: 'device-1');

      // 第一条事件：开录时原生报错（相机 / 编码器起不来是真实会发生的）。
      gateway.onStartRecording = () async => throw StateError('开录失败（测试故意）');
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      expect(coordinator.lastError, isNotNull, reason: '失败必须被记下来，不能静默');
      expect(coordinator.isRecording, isFalse);

      // 关键：链还活着 —— 后面的事件照旧被处理。
      gateway.onStartRecording = null;
      nowMs = 2000;
      await coordinator.onWaybillDetected(waybill);
      await coordinator.waitForPendingEvents();

      expect(gateway.started, isTrue, reason: '后续事件必须还能被处理');
      expect(coordinator.isRecording, isTrue);

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
        finalizer: SessionFinalizer(
            rootDirectory: root,
            index: _ThrowingIndex(),
            labels: labels = LabelStore('$root/labels.jsonl')),
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

    test('★ 关掉播报：不出声，但提示照旧发出来', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);
      coordinator.voiceEnabled = false;

      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      expect(gateway.spoken, isEmpty, reason: '关了播报就不该再调原生 speak');

      // ⚠️ **这一条才是重点**：`onAction` 必须照旧发 Speak。
      // 关掉的只是声音 —— 屏幕上的提示与事件日志一条都不能少。
      // 若哪天有人图省事把这段改成「voiceEnabled 为 false 就 return」，
      // 错码保护的提示会连同声音一起消失，而界面上看不出少了什么。
      expect(
        actions.whereType<Speak>().map((a) => a.prompt),
        [VoicePrompt.differentWaybill],
      );
      expect(coordinator.isRecording, isTrue, reason: '扫错码只提示不停');

      await coordinator.dispose();
    });

    test('⚠️ 播报开关能中途改 —— 不必等下次「开始工作」', () async {
      // 这个可变字段是编排器里**唯一**一个能中途改的配置。
      // 关它的场景是「现在太吵」，让用户先结束工作再开始是荒谬的。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      coordinator.voiceEnabled = false;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();
      expect(gateway.spoken, isEmpty);

      // 再打开 —— 下一次就该出声了（不用重建编排器）。
      coordinator.voiceEnabled = true;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();
      expect(gateway.spoken, ['面单不同']);

      await coordinator.dispose();
    });

    test('★ speak() 不经状态机也能播报 —— 不必先开录', () async {
      // 需求方 2026-09-22：进发货 / 退货栏就播报模式。那一刻**还没开始工作**，
      // 状态机是空转的 —— 所以播报必须有一个不经状态机的入口。
      final coordinator = make();
      nowMs = 1000;

      await coordinator.speak(VoicePrompt.shippingModeOn);

      expect(gateway.spoken, ['发货模式开启']);
      expect(coordinator.isRecording, isFalse, reason: '播报不该顺手把录制开起来');

      await coordinator.dispose();
    });

    test('★ speak() 走的是同一道播报闸', () async {
      // 闸有两道、通路有两条的话，「关掉播报」迟早会有一半失灵 ——
      // 用户关了声音，进栏那一下还是响，会以为开关坏了。
      final coordinator = make();
      nowMs = 1000;
      coordinator.voiceEnabled = false;

      await coordinator.speak(VoicePrompt.returnModeOn);

      expect(gateway.spoken, isEmpty, reason: '关了播报就不该出声');
      // 关掉的只是声音：屏幕上的提示与事件日志照旧。
      expect(actions.whereType<Speak>().map((a) => a.prompt),
          [VoicePrompt.returnModeOn]);

      await coordinator.dispose();
    });

    test('speak() 出错不会把调用方带崩', () async {
      final coordinator = make();
      nowMs = 1000;
      gateway.speakThrows = true;

      await coordinator.speak(VoicePrompt.shippingModeOn); // 不抛就算过

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
        finalizer: SessionFinalizer(
            rootDirectory: root,
            index: _ThrowingIndex(),
            labels: labels = LabelStore('$root/labels.jsonl')),
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

  // ─────────────────────────────────────────────
  // 面单进框：自动对焦 + 临时放大（需求方 2026-09-22）
  // ─────────────────────────────────────────────

  group('自动对焦', () {
    test('★ 每次**采纳的**识码调一次', () async {
      // 「采纳」= 过了 `ScanGate`（框内、且不是同一张面单一直摆在那儿）。
      // 挂在闸之后不是为了省钱：闸已经保证「同一张面单只算一次」，
      // 所以那里天然就是「新面单进框」。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      expect(gateway.autoFocusCalls, 0, reason: '开录那一下是手输兜底路径，不调');

      // 包裹一直在画面里 → 闸压掉，不该反复对焦。
      gateway.emit(const BarcodeDetectedEvent(
          text: 'SF1000000001', centerX: 0.5, centerY: 0.5));
      gateway.emit(const BarcodeDetectedEvent(
          text: 'SF1000000001', centerX: 0.5, centerY: 0.5));
      await coordinator.waitForPendingEvents();
      expect(gateway.autoFocusCalls, 0, reason: '同一张面单反复上报不算「进框」');

      // 换一张面单进框 → 调一次。
      nowMs += 5000;
      gateway.emit(const BarcodeDetectedEvent(
          text: 'YT9999999999', centerX: 0.5, centerY: 0.5));
      await coordinator.waitForPendingEvents();
      expect(gateway.autoFocusCalls, 1);

      await coordinator.dispose();
    });

    test('手输兜底**不**调自动对焦', () async {
      // 画面里没有面单，放大一下只会让人以为相机坏了。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      await coordinator.onWaybillDetected(otherWaybill,
          source: PunchSource.manualEntry);
      await coordinator.waitForPendingEvents();

      expect(gateway.autoFocusCalls, 0);

      await coordinator.dispose();
    });

    test('自动对焦失败不能拖垮识码', () async {
      // 安卓那条通道整个还没接，这里必定失败（I4 的精神：能力缺失
      // 不许把录制搞坏）。
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      gateway.autoFocusThrows = true;
      // 复扫**同一个**单号（`make()` 默认同码停）：这才是会停录的那一下。
      // 扫别的单号在本模式下只提示不停，验不出「后续有没有被吞掉」。
      nowMs += 5000;
      gateway.emit(const BarcodeDetectedEvent(
          text: 'SF1000000001', centerX: 0.5, centerY: 0.5));
      await coordinator.waitForPendingEvents();

      // 停录照旧发生 —— 失败的那一下没有被吞掉后续。
      expect(coordinator.isRecording, isFalse, reason: '同码停模式该照常停');

      await coordinator.dispose();
    });
  });

  // ─────────────────────────────────────────────
  // 换段式连续扫（§3.3.1，2026-09-22 需求变更）
  // ─────────────────────────────────────────────

  group('换段式连续扫', () {
    RecordingCoordinator makeScan() => make(mode: WorkMode.continuousScan);

    test('★ 扫到新面单：上一段立刻入库，下一段紧接着开录', () async {
      final coordinator = makeScan();
      nowMs = 1000;
      await begin(coordinator);
      final firstSession = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: firstSession, sequence: 0, startMs: 0, endMs: 30000);

      nowMs = 1000 + 90 * 1000;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      // 上一段：收尾了、入库了、不再是当前会话。
      final entries = await index.loadAll();
      expect(entries, hasLength(1), reason: '上一段要入库，**一条**，不能多');
      expect(entries.single.sessionId, firstSession);

      // 下一段：立刻在录，而且是新的会话、新的单号。
      expect(coordinator.isRecording, isTrue, reason: '换段要无缝接上，不能停下来等人');
      expect(coordinator.currentWaybill, otherWaybill);
      expect(coordinator.sessionId, isNotNull);
      expect(coordinator.sessionId, isNot(firstSession));

      // 盘上两个会话目录 —— 一件包裹一段录像，不是一个会话装两件。
      final dirs = Directory('$root/work')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(RegExp(r'[\\/]')).last)
          .toSet();
      expect(dirs, containsAll([firstSession, coordinator.sessionId!]));

      await coordinator.dispose();
    });

    test('★ 换件那一下不打在本段上，而是落在新段的第一条', () async {
      // 打点按会话归属。把「下一件的号」记进上一段的打点里，回放时
      // 那件录像上会多出一个不属于它的跳转点（§3.2.4 的脏数据）。
      // 两条都打又会把操作员的一次动作算成两次打点。
      final coordinator = makeScan();
      nowMs = 1000;
      await begin(coordinator);
      final firstSession = coordinator.sessionId!;

      nowMs = 1000 + 90 * 1000;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();

      final first = await punchLog.forSession(firstSession);
      expect(first.map((p) => p.waybill.value), [waybill.value],
          reason: '上一段只该有它自己的号，不该有下一件的');

      final second = await punchLog.forSession(coordinator.sessionId!);
      expect(second, hasLength(1));
      expect(second.single.waybill, otherWaybill);
      expect(second.single.monotonicOffsetMilliseconds, 0,
          reason: '换件那一下就是新段的起点，偏移必须是 0');

      await coordinator.dispose();
    });

    test('换件之后静止停录与时长兜底照样生效', () async {
      // 换段让「停录」从一次/班变成一次/件。心跳要是没跟着重起
      // （recorder_page 的 `StartRecording` 那一臂），换完第一件之后
      // 这两个兜底就**再也不会触发**，而画面上一切正常。
      // 这里验的是编排层：新段的心跳确实被处理。
      final coordinator = makeScan();
      nowMs = 1000;
      await begin(coordinator);
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();
      final secondSession = coordinator.sessionId!;

      nowMs += 60 * 1000;
      await coordinator.handleHeartbeat();
      await coordinator.waitForPendingEvents();

      expect(coordinator.elapsed, const Duration(minutes: 1),
          reason: '新段的已录时长要从新段起点算，不能继承上一段');
      expect(coordinator.sessionId, secondSession, reason: '心跳不该把新段弄没了');

      await coordinator.dispose();
    });

    test('★ 换段的空档里手输兜底不许插队', () async {
      // 这是 [`onWaybillDetected`] 必须排进 `_enqueue` 的理由。
      //
      // 收尾是异步的，中间有一段「状态机已不在录、`_sessionId` 却还在」
      // 的空档 —— 而这段空档**只有换段式才会出现**。手输兜底是从界面按钮
      // 直接进来的，正好落在里面的话：它会当「首次识别」另开一段，
      // `_beginRecording` 把 `_segments` 清空，等收尾回来按**已清空的**分段列表
      // 去入库 —— 于是上一段被判成「会话没有任何分段可收尾」，
      // 索引里**一条都不写**（收尾器见 `session_finalizer.dart:93`）。
      //
      // 变红配方：把 `onWaybillDetected` 的 `_enqueue(...)` 换回直接调
      // `_handleWaybill(...)` —— 下面的 `index.loadAll()` 会变成空。
      final coordinator = makeScan();
      nowMs = 1000;
      await begin(coordinator);
      final firstSession = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: firstSession, sequence: 0, startMs: 0, endMs: 30000);

      // 把收尾卡在「原生停录」这一步，制造出那个空档。
      final gate = Completer<void>();
      gateway.onStopRecording = () => gate.future;

      nowMs += 90 * 1000;
      // ⚠️ **不 await** —— 就是要让它停在收尾中间。
      final rotating = coordinator.onWaybillDetected(otherWaybill);

      // 就在这个空档里手输第三张面单。
      final third = WaybillNumber.parse('JD8888888888');
      final manual =
          coordinator.onWaybillDetected(third, source: PunchSource.manualEntry);

      gate.complete();
      await rotating;
      await manual;
      await coordinator.waitForPendingEvents();

      final entries = await index.loadAll();
      expect(entries, hasLength(1), reason: '上一段必须照常入库（一条）');
      expect(entries.single.sessionId, firstSession);
      expect(entries.single.duration, const Duration(seconds: 30),
          reason: '入库的必须是**它自己的**那一段，不是被清空后的空列表');

      // 手输那张照旧按换件处理：收掉 otherWaybill 那段，为 third 开新段。
      expect(coordinator.currentWaybill, third);
      expect(coordinator.isRecording, isTrue);
      expect(coordinator.sessionId, isNot(firstSession));

      await coordinator.dispose();
    });

    test('另两个模式扫到别的单号照旧只提示、不换段', () async {
      for (final mode in [WorkMode.sameWaybillStop, WorkMode.scanThenStaticStop]) {
        final coordinator = make(mode: mode);
        nowMs = 1000;
        await begin(coordinator);
        final session = coordinator.sessionId!;

        nowMs += 30 * 1000;
        await coordinator.onWaybillDetected(otherWaybill);
        await coordinator.waitForPendingEvents();

        expect(coordinator.isRecording, isTrue, reason: '$mode 必须继续录');
        expect(coordinator.sessionId, session, reason: '$mode 不该换会话');
        expect(gateway.spoken, contains(VoicePrompt.differentWaybill.spokenText),
            reason: '$mode 必须照旧提示「面单不同」');

        await coordinator.dispose();
      }
    });
  });

  // ─────────────────────────────────────────────
  // 发货 / 退货落盘（母仓 §6.2 / I5）
  // ─────────────────────────────────────────────

  group('发货 / 退货写进标签表', () {
    /// 标签表只写不读（`LabelStore` 自己的注释里写了理由），测试直接读文件。
    List<Map<String, Object?>> readLabels() {
      final file = File(labels.path);
      if (!file.existsSync()) return const [];
      return file
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
    }

    test('★ 收尾时把当前模式写到每个证据上', () async {
      final coordinator = make();
      // 与 `voiceEnabled` 同形：中途改的字段，不进构造函数。
      coordinator.businessType = BusinessType.returning;

      nowMs = 1000;
      await begin(coordinator);
      final sessionId = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: sessionId, sequence: 0, startMs: 0, endMs: 30000);

      await coordinator.onManualStop();
      await coordinator.waitForPendingEvents();

      final label = readLabels().single;
      expect(label['EvidenceId'], '$sessionId-000');
      expect(label['Key'], 'business-type');
      expect(label['Value'], 'return');

      await coordinator.dispose();
    });

    test('★ 换段：每一段各得一条，挂在自己的 evidenceId 上', () async {
      // 电脑端按 evidenceId 查标签。一个会话 N 段就 N 个 evidenceId，
      // 只给最后一段写，前面那些在电脑端就是「不知道是发货还是退货」。
      final coordinator = make(mode: WorkMode.continuousScan);
      coordinator.businessType = BusinessType.outbound;

      nowMs = 1000;
      await begin(coordinator);
      final firstSession = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: firstSession, sequence: 0, startMs: 0, endMs: 30000);

      nowMs += 90 * 1000;
      await coordinator.onWaybillDetected(otherWaybill);
      await coordinator.waitForPendingEvents();
      final secondSession = coordinator.sessionId!;
      await closeSegment(coordinator,
          sessionId: secondSession, sequence: 0, startMs: 0, endMs: 30000);

      await coordinator.onManualStop();
      await coordinator.waitForPendingEvents();

      expect(readLabels().map((j) => j['EvidenceId']),
          ['$firstSession-000', '$secondSession-000']);
      expect(readLabels().map((j) => j['Value']), ['outbound', 'outbound']);

      await coordinator.dispose();
    });

    test('没设 businessType 就什么都不写', () async {
      final coordinator = make();
      nowMs = 1000;
      await begin(coordinator);

      await coordinator.onManualStop();
      await coordinator.waitForPendingEvents();

      expect(readLabels(), isEmpty);
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

  /// 卡住 `stopRecording`，用来把收尾停在中间 —— 换段那个空档只有这么造得出来。
  Future<void> Function()? onStopRecording;

  @override
  Future<void> stopRecording() async {
    stopped = true;
    if (onStopRecording != null) await onStopRecording!();
    if (emitOnStop != null) emit(emitOnStop!);
  }

  @override
  Future<void> closeCamera() async {
    cameraCloseCount++;
    cameraOpened = false;
  }

  /// 关了几次。**「已经关了就不再关」是要验的** ——
  /// 不判状态就重复关，会让原生的会话与 Dart 的记忆错位。
  int cameraCloseCount = 0;

  @override
  Future<void> setZoom(double ratio) async => zoomRatio = ratio;

  double? zoomRatio;

  @override
  Future<double?> maxZoom() async => 4.0;

  @override
  Future<void> autoFocusAndZoom() async {
    autoFocusCalls++;
    if (autoFocusThrows) throw Exception('这台设备不支持对焦');
  }

  /// 自动对焦被调了几次。**「接线到底没到底」那条测试的立足点** ——
  /// 这个抽象成员存在的主要理由就是逼测试把它记下来。
  int autoFocusCalls = 0;

  /// 让自动对焦抛 —— 验「能力缺失不许把录制搞坏」。
  bool autoFocusThrows = false;

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
