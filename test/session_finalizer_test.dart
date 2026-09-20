import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recorder_events.dart' show StopTrigger;
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/recording_workspace.dart';
import 'package:vidlog_mobile/recording/session_finalizer.dart';
import 'package:vidlog_mobile/states.dart';

/// 不变量 I9：录制收尾只有一条路径（规格 §4.1）；
/// 以及规格 §3.1.1：重启后必须能自动收尾孤儿分段。
void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-m4-');
    root = temp.path;
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  final waybill = WaybillNumber.parse('SF1000000001');
  final started = DateTime(2026, 9, 20, 10, 30);

  /// 造一个分段文件并返回它的元数据。
  SegmentProduct makeSegment(String sessionId, int sequence,
      {List<int>? bytes, DateTime? at}) {
    final dir = Directory('$root/$sessionId')..createSync(recursive: true);
    final file = File('${dir.path}/segment-${sequence.toString().padLeft(3, '0')}.mp4');
    file.writeAsBytesSync(bytes ?? List<int>.generate(64, (i) => i + sequence));

    final start = at ?? started.add(Duration(minutes: sequence));
    return SegmentProduct(
      sequence: sequence,
      filePath: file.path,
      startedAt: start,
      endedAt: start.add(const Duration(seconds: 30)),
    );
  }

  (SessionFinalizer, JsonLinesRecordingIndex) makeFinalizer({String suffix = ''}) {
    final index = JsonLinesRecordingIndex('$root/index$suffix.jsonl');
    return (SessionFinalizer(rootDirectory: root, index: index), index);
  }

  // ─────────────────────────────────────────────
  // I9：收尾只有一条路径
  // ─────────────────────────────────────────────

  group('I9 收尾只有一条路径', () {
    test('所有停录原因产出完全相同的索引条目', () async {
      final results = <String>[];

      for (final trigger in StopTrigger.values) {
        // 每个触发器用**独立的索引文件** —— 共用的话会累积，
        // 比到的就不是「这一次收尾做了什么」。
        final (finalizer, index) = makeFinalizer(suffix: '-${trigger.name}');
        final segment = makeSegment('s-${trigger.name}', 0);

        final outcome = await finalizer.finalize(
          sessionId: 's-${trigger.name}',
          waybill: waybill,
          sourceDeviceId: 'device-1',
          segments: [segment],
          reason: trigger,
        );

        expect(outcome.state, RecordingSessionState.indexed,
            reason: '$trigger 应当收尾成功');
        expect(outcome.reason, trigger);

        // 把会话 id 抹掉再比 —— 比的是「收尾做了什么」，不是「哪个会话」
        results.add(jsonEncode(
            (await index.loadAll()).map((e) => e.toJson()).toList()).replaceAll(trigger.name, 'X'));
      }

      expect(results.toSet(), hasLength(1),
          reason: '不同停录原因必须走完全相同的收尾逻辑，不能有旁路');
    });

    test('结果里带回了停录原因，供审计用', () async {
      final (finalizer, _) = makeFinalizer();

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.sceneStatic,
      );

      expect(outcome.reason, StopTrigger.sceneStatic);
    });
  });

  // ─────────────────────────────────────────────
  // 成功路径
  // ─────────────────────────────────────────────

  group('成功收尾', () {
    test('进入已入库并写入索引', () async {
      final (finalizer, index) = makeFinalizer();

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.sameWaybillRescan,
      );

      expect(outcome.state, RecordingSessionState.indexed);
      expect(outcome.failureReason, isNull);

      final entry = (await index.loadAll()).single;
      expect(entry.waybill, waybill);
      expect(entry.sessionId, 's1');
      expect(entry.duration, const Duration(seconds: 30));
      expect(entry.sourceDeviceId, 'device-1');
    });

    test('索引里只有相对路径', () async {
      final (finalizer, index) = makeFinalizer();

      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.manual,
      );

      final location = (await index.loadAll()).single.location.value;

      expect(location.contains(root), isFalse);
      expect(location.startsWith('/'), isFalse);
      expect(location, contains('s1'));
    });

    test('哈希与落盘文件内容一致', () async {
      final (finalizer, index) = makeFinalizer();
      final bytes = List<int>.generate(256, (i) => i % 251);
      final segment = makeSegment('s1', 0, bytes: bytes);

      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [segment],
        reason: StopTrigger.manual,
      );

      final entry = (await index.loadAll()).single;
      final expected = (await hashFile(segment.filePath)).value;

      expect(entry.contentHash.value, expected);
      expect(entry.contentHash.value, hasLength(64));
    });

    test('多分段各自一条索引记录，且共用同一个会话 id', () async {
      final (finalizer, index) = makeFinalizer();

      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0), makeSegment('s1', 1), makeSegment('s1', 2)],
        reason: StopTrigger.manual,
      );

      final entries = await index.loadAll();
      expect(entries, hasLength(3));
      expect(entries.map((e) => e.sessionId).toSet(), {'s1'});
      expect(entries.map((e) => e.evidenceId).toSet(), {'s1-000', 's1-001', 's1-002'});
    });
  });

  // ─────────────────────────────────────────────
  // 失败路径
  // ─────────────────────────────────────────────

  group('失败路径', () {
    test('分段文件不存在 → 收尾失败', () async {
      final (finalizer, index) = makeFinalizer();
      final missing = SegmentProduct(
        sequence: 0,
        filePath: '$root/s1/never-written.mp4',
        startedAt: started,
        endedAt: started.add(const Duration(seconds: 30)),
      );

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [missing],
        reason: StopTrigger.processKilled,
      );

      expect(outcome.state, RecordingSessionState.finalizeFailed);
      expect(await index.loadAll(), isEmpty);
    });

    test('没有分段 → 收尾失败', () async {
      final (finalizer, _) = makeFinalizer();

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: const [],
        reason: StopTrigger.manual,
      );

      expect(outcome.state, RecordingSessionState.finalizeFailed);
      expect(outcome.failureReason, isNotNull);
    });

    test('多分段里有一个坏的 → 整体不算成功', () async {
      final (finalizer, _) = makeFinalizer();
      final good = makeSegment('s1', 0);
      final missing = SegmentProduct(
        sequence: 1,
        filePath: '$root/s1/gone.mp4',
        startedAt: started,
        endedAt: started.add(const Duration(seconds: 30)),
      );

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [good, missing],
        reason: StopTrigger.manual,
      );

      expect(outcome.state, RecordingSessionState.finalizeFailed);
      // 好的那条仍然入库了 —— 部分成功也要保留，不能因为一条坏就全丢（I2）
      expect(outcome.segments.where((s) => s.isPublished), hasLength(1));
    });

    test('源文件保留 —— 收尾器不负责删任何东西', () async {
      final (finalizer, _) = makeFinalizer();
      final good = makeSegment('s1', 0);
      final missing = SegmentProduct(
        sequence: 1,
        filePath: '$root/s1/gone.mp4',
        startedAt: started,
        endedAt: started.add(const Duration(seconds: 30)),
      );

      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [good, missing],
        reason: StopTrigger.manual,
      );

      expect(File(good.filePath).existsSync(), isTrue);
    });
  });

  // ─────────────────────────────────────────────
  // 索引的健壮性
  // ─────────────────────────────────────────────

  group('索引', () {
    test('索引文件不存在时返回空而不是抛', () async {
      final index = JsonLinesRecordingIndex('$root/never.jsonl');

      expect(await index.loadAll(), isEmpty);
    });

    test('坏行不会毁掉整个索引', () async {
      final (finalizer, index) = makeFinalizer();
      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.manual,
      );

      // 混进一行半截 JSON
      File(index.path).writeAsStringSync('{"evidenceId": "half', mode: FileMode.append);

      expect(await index.loadAll(), hasLength(1));
    });
  });

  // ─────────────────────────────────────────────
  // 孤儿恢复（规格 §3.1.1 / §8）
  // ─────────────────────────────────────────────

  group('孤儿恢复', () {
    Future<RecordingWorkspace> killedSession(String sessionId,
        {bool finalized = false, bool writeSegment = true}) async {
      final workspace = RecordingWorkspace('$root/work');

      final segments = <SegmentManifest>[];
      if (writeSegment) {
        final dir = Directory(workspace.sessionDirectory(sessionId))
          ..createSync(recursive: true);
        File('${dir.path}/segment-000.mp4').writeAsBytesSync([1, 2, 3, 4]);

        segments.add(SegmentManifest(
          sequence: 0,
          fileName: 'segment-000.mp4',
          startedAt: started,
          endedAt: started.add(const Duration(seconds: 30)),
        ));
      }

      await workspace.writeManifest(SessionManifest(
        sessionId: sessionId,
        waybill: waybill,
        sourceDeviceId: 'device-1',
        startedAt: started,
        segments: segments,
      ));

      if (finalized) await workspace.markFinalized(sessionId);

      return workspace;
    }

    test('没打收尾标记的会话被认作孤儿', () async {
      final workspace = await killedSession('s-killed');

      final orphans = await workspace.listOrphans();

      expect(orphans, hasLength(1));
      expect(orphans.single.sessionId, 's-killed');
      expect(orphans.single.waybill, waybill);
      expect(orphans.single.segments, hasLength(1));
    });

    test('已收尾的会话不是孤儿', () async {
      final workspace = await killedSession('s-done', finalized: true);

      expect(await workspace.listOrphans(), isEmpty);
    });

    test('分段文件已消失的会话不是孤儿', () async {
      final workspace = await killedSession('s-gone', writeSegment: false);

      expect(await workspace.listOrphans(), isEmpty);
    });

    test('坏 manifest 不会让发现流程崩掉', () async {
      final workspace = RecordingWorkspace('$root/work');
      final dir = Directory(workspace.sessionDirectory('s-broken'))
        ..createSync(recursive: true);
      File('${dir.path}/${RecordingWorkspace.manifestFileName}')
          .writeAsStringSync('{"sessionId": "half');

      expect(await workspace.listOrphans(), isEmpty);
    });

    test('孤儿收尾走的是同一个收尾器，原因是「进程被杀」', () async {
      final workspace = await killedSession('s-killed');
      final (finalizer, index) = makeFinalizer();
      final recovery = OrphanRecovery(workspace: workspace, finalizer: finalizer);

      final outcomes = await recovery.recover();

      final outcome = outcomes.single;
      expect(outcome.succeeded, isTrue);
      expect(outcome.reason, StopTrigger.processKilled);
      expect(await index.loadAll(), hasLength(1));
    });

    test('收尾成功后打标记，下次启动不再重复收尾', () async {
      final workspace = await killedSession('s-killed');
      final (finalizer, _) = makeFinalizer();

      await OrphanRecovery(workspace: workspace, finalizer: finalizer).recover();

      expect(await workspace.listOrphans(), isEmpty);
    });

    test('收尾失败不打标记，下次启动重试', () async {
      // 源文件一定还在（I2），所以失败可能只是瞬时故障 ——
      // 不能当成不可恢复丢掉。
      final workspace = await killedSession('s-killed');
      final brokenIndex = _ThrowingIndex();
      final finalizer =
          SessionFinalizer(rootDirectory: root, index: brokenIndex);

      final outcomes =
          await OrphanRecovery(workspace: workspace, finalizer: finalizer).recover();

      expect(outcomes.single.succeeded, isFalse);
      expect(await workspace.listOrphans(), hasLength(1),
          reason: '失败的孤儿要保持孤儿身份，下次启动再试');
    });

    test('多次孤儿一次全部收尾', () async {
      final workspace = await killedSession('s-a');
      await killedSession('s-b');
      final (finalizer, index) = makeFinalizer();

      final outcomes =
          await OrphanRecovery(workspace: workspace, finalizer: finalizer).recover();

      expect(outcomes, hasLength(2));
      expect(outcomes.every((o) => o.succeeded), isTrue);
      expect(await index.loadAll(), hasLength(2));
    });
  });
}

/// 写索引必失败的假索引 —— 用来验证「索引写不进去不算收尾成功」。
class _ThrowingIndex implements RecordingIndex {
  @override
  Future<void> add(RecordingEntry entry) async => throw const FileSystemException('磁盘满了');

  @override
  Future<List<RecordingEntry>> loadAll() async => [];
}
