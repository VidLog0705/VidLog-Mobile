import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/business_type.dart';
import 'package:vidlog_mobile/recording/label_store.dart';
import 'package:vidlog_mobile/recording/recorder_events.dart' show StopTrigger;
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/recording_spec.dart';
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

  /// 最后一次 [makeFinalizer] 用到的标签表 —— 收尾写标签的测试靠它读回结果。
  /// 每个 suffix 一份独立的 `labels.jsonl`（理由同索引）。
  late LabelStore labels;

  /// 读回标签表。
  ///
  /// [LabelStore] **只写不读**（界面上还没有要显示它的地方，理由写在它自己的
  /// 注释里），所以测试直接读文件 —— 正好也把「落盘形态」验在字节这一层。
  List<Map<String, Object?>> readLabels(String path) {
    final file = File(path);
    if (!file.existsSync()) return const [];

    return file
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
  }

  (SessionFinalizer, JsonLinesRecordingIndex) makeFinalizer({String suffix = ''}) {
    final index = JsonLinesRecordingIndex('$root/index$suffix.jsonl');
    labels = LabelStore('$root/labels$suffix.jsonl');
    return (
      SessionFinalizer(rootDirectory: root, index: index, labels: labels),
      index,
    );
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
  // 标签表（发货 / 退货）—— 母仓 §6.2 / I5
  // ─────────────────────────────────────────────

  group('发货 / 退货写进标签表', () {
    Future<FinalizeOutcome> finalizeWith(
      BusinessType? type, {
      List<SegmentProduct>? segments,
      String sessionId = 's1',
    }) async {
      final (finalizer, _) = makeFinalizer(suffix: '-labels');
      return finalizer.finalize(
        sessionId: sessionId,
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: segments ?? [makeSegment(sessionId, 0)],
        reason: StopTrigger.manual,
        businessType: type,
      );
    }

    test('★ 落盘形态与电脑端逐字一致', () async {
      // 电脑端 `LabelDto` 的 4 个属性名就是这 4 个键（PascalCase），
      // 标签键是 `LabelKeys.BusinessType = "business-type"`，取值
      // `BusinessTypes.OutboundValue = "outbound"` / `ReturnValue = "return"`。
      // 改了这里，两端的标签表就不是同一份格式了 —— 那正是这个测试要拦的。
      await finalizeWith(BusinessType.returning);

      final json = readLabels(labels.path).single;

      expect(json.keys, ['EvidenceId', 'Key', 'Value', 'UpdatedAt']);
      expect(json['EvidenceId'], 's1-000');
      expect(json['Key'], 'business-type');
      expect(json['Value'], 'return');
      expect(DateTime.parse(json['UpdatedAt']! as String).isUtc, isTrue,
          reason: '墙钟时刻落盘必须带时区');
    });

    test('枚举的拼法就是电脑端的字面量', () {
      expect(BusinessType.outbound.wire, 'outbound');
      expect(BusinessType.returning.wire, 'return');
      expect(BusinessType.labelKey, 'business-type');
    });

    test('认不出来的取值不猜', () {
      // 电脑端 `LabelStore` 解析不出来时**默认发货**；手机端刻意不跟 ——
      // 标签宁可不写，也不写错的。
      expect(BusinessType.tryParse('outbound'), BusinessType.outbound);
      expect(BusinessType.tryParse('return'), BusinessType.returning);
      expect(BusinessType.tryParse('shipment'), isNull);
      expect(BusinessType.tryParse(null), isNull);
      expect(BusinessType.tryParse(42), isNull);

      // 大小写敏感，与电脑端一致（`Enum.TryParse` 默认如此）。
      // 这里**不**做「宽容一点」的处理：两端对「什么算合法取值」必须同一套，
      // 否则手机端认了、电脑端不认，那条标签就是个死值。
      expect(BusinessType.tryParse('RETURN'), isNull);
    });

    test('清单里的 businessType 往返；老清单没有这个字段 → null', () {
      final manifest = SessionManifest(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        startedAt: started,
        segments: const [],
        businessType: BusinessType.returning,
      );

      expect(manifest.toJson()['businessType'], 'return');
      expect(SessionManifest.fromJson(manifest.toJson()).businessType,
          BusinessType.returning);

      // 老版本写的清单：整个键都不在（新增字段只加不改）。
      final old = manifest.toJson()..remove('businessType');
      expect(SessionManifest.fromJson(old).businessType, isNull);

      // 认不出来的取值也是 null，不是电脑端那种「默认发货」。
      final alien = manifest.toJson()..['businessType'] = 'shipment';
      expect(SessionManifest.fromJson(alien).businessType, isNull);
    });

    test('★ 每个分段各写一条', () async {
      // 一个会话 N 个分段 = N 个 evidenceId，电脑端按 evidenceId 查标签 ——
      // 只给第一个分段写，后面那些在电脑端就是「不知道是发货还是退货」。
      await finalizeWith(
        BusinessType.outbound,
        segments: [makeSegment('s1', 0), makeSegment('s1', 1)],
      );

      final written = readLabels(labels.path);
      expect(written.map((j) => j['EvidenceId']), ['s1-000', 's1-001']);
      expect(written.map((j) => j['Value']), ['outbound', 'outbound']);
    });

    test('没给 businessType 就什么都不写', () async {
      // 老清单 / 调用方没给 —— 不猜一个。
      await finalizeWith(null);

      expect(readLabels(labels.path), isEmpty);
    });

    test('★ 写标签失败不算收尾失败', () async {
      // 与「写索引失败」刻意区别对待：索引决定这段录像存不存在，
      // 标签只是可修正的备注。为它把一段文件完好、哈希也算完的录像判成失败，
      // 等于让它保持孤儿身份、每次启动重试，而用户其实什么都没损失。
      //
      // 造一个必失败的标签表：路径落在**目录**上（写文件时必然被拒）。
      Directory('$root/labels-is-a-dir').createSync(recursive: true);
      final broken = LabelStore('$root/labels-is-a-dir');

      final index = JsonLinesRecordingIndex('$root/index-broken-labels.jsonl');
      final finalizer =
          SessionFinalizer(rootDirectory: root, index: index, labels: broken);

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.manual,
        businessType: BusinessType.outbound,
      );

      expect(outcome.succeeded, isTrue, reason: '录像入库了就是入库了');
      expect((await index.loadAll()), hasLength(1));
    });

    test('标签写在索引之后 —— 索引失败时不写标签', () async {
      // 标签指向一条索引里没有的证据，是纯粹的垃圾。
      final index = _ThrowingIndex();
      final finalizer = SessionFinalizer(
          rootDirectory: root,
          index: index,
          labels: labels = LabelStore('$root/labels-after-index.jsonl'));

      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.manual,
        businessType: BusinessType.outbound,
      );

      expect(readLabels(labels.path), isEmpty);
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
      expect(entry.evidenceId, 's1-000');
      expect(entry.duration, const Duration(seconds: 30));
      expect(entry.sourceDeviceId, 'device-1');
    });

    test('★ 录制规格写进索引（规格 §3.1.7 的连带项）', () async {
      // 记它有两个用处：容量估算按它算（§3.5.5），以及「这条是 4K 还是 720P」
      // 这件事以后还能回答 —— 索引一旦漏记，事后只能靠文件大小猜。
      final (finalizer, index) = makeFinalizer();

      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.manual,
        spec: const RecordingSpec(
          codec: VideoCodec.h265,
          resolution: VideoResolution.uhd4K,
          orientation: RecordingOrientation.landscapeLeft,
        ),
      );

      final entry = (await index.loadAll()).single;
      expect(entry.codec, 'h265');
      expect(entry.resolution, 'uhd4K');
      expect(entry.orientation, 'landscapeLeft');
    });

    test('⚠️ 没有规格时**不写这三个键** —— 与老行长得一样', () async {
      // 索引是追加写的，2026-09-27 之前的行里没有这三个字段。
      // 写 `"codec": null` 与不写是两回事：读端只认「有没有这个键」，
      // 而我们要的是那些老行看起来毫无变化。
      final (finalizer, index) = makeFinalizer();

      await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.manual,
      );

      final raw = File(index.path).readAsLinesSync().single;
      final json = jsonDecode(raw) as Map<String, Object?>;

      expect(json.containsKey('codec'), isFalse);
      expect(json.containsKey('resolution'), isFalse);
      expect(json.containsKey('orientation'), isFalse);

      final entry = (await index.loadAll()).single;
      expect(entry.codec, isNull);
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
        {bool finalized = false,
        bool writeSegment = true,
        BusinessType? businessType}) async {
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
        businessType: businessType,
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

    test('★ 进程被杀之后，孤儿收尾照样补得上标签', () async {
      // 这时内存里的东西全没了，只剩盘上这几份文件 ——
      // `session.json` 里的 businessType 就是「这一件是发货还是退货」的唯一依据。
      final workspace = await killedSession('s-killed',
          businessType: BusinessType.returning);
      final (finalizer, index) = makeFinalizer(suffix: '-orphan-labels');

      await OrphanRecovery(workspace: workspace, finalizer: finalizer).recover();

      expect((await index.loadAll()), hasLength(1));
      expect(readLabels(labels.path).single['Value'], 'return');
    });

    test('清单里没记 businessType 就不写标签（不猜）', () async {
      // 老版本写的清单没有这个字段。猜一个「发货」比留空更糟：
      // 电脑端会拿它去算保留期。
      final workspace = await killedSession('s-killed');
      final (finalizer, _) = makeFinalizer(suffix: '-orphan-none');

      await OrphanRecovery(workspace: workspace, finalizer: finalizer).recover();

      expect(readLabels(labels.path), isEmpty);
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
      final finalizer = SessionFinalizer(
          rootDirectory: root,
          index: brokenIndex,
          labels: labels = LabelStore('$root/labels.jsonl'));

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
