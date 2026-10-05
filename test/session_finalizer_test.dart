import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/diagnostics/app_log.dart';
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

  (SessionFinalizer, JsonLinesRecordingIndex) makeFinalizer({
    String suffix = '',
    VerifyPlayable? verify,
  }) {
    final index = JsonLinesRecordingIndex('$root/index$suffix.jsonl');
    labels = LabelStore('$root/labels$suffix.jsonl');
    return (
      SessionFinalizer(
        rootDirectory: root,
        index: index,
        labels: labels,
        // 实际解码校验（规格 §3.1.4）。不传 = 不校验（大多数用例走这条）。
        verifyPlayable: verify,
      ),
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

    test('★ 成品校验失败 ⇒ 不入库为「正常」（规格 §3.1.4）', () async {
      // 规格原话：「停止录制后必须**实际解码校验**成品可播，
      // 校验失败**不得入库为「正常」**」。这一条就是那个落点。
      //
      // ⚠️ 在此之前手机端**没有这一层**（`session_finalizer.dart` 里原来写着
      // 「手机端没有 FFmpeg……这是一处已知的验证强度差异」）——
      // 后果是：编码器收尾异常产出一个不可播的 MP4，会被当**正常**写进索引、
      // 进上传队列，而用户要到需要证据那天才发现。
      final (finalizer, index) = makeFinalizer(
        suffix: '-verify-bad',
        verify: (_) async => false,
      );
      final segment = makeSegment('s1', 0);

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [segment],
        reason: StopTrigger.manual,
      );

      expect(outcome.state, RecordingSessionState.finalizeFailed);
      expect(await index.loadAll(), isEmpty, reason: '解不开的成品不得入库');
      expect(outcome.failureReason, contains('解不开'));

      // ★ 而且**文件留着** —— 校验失败只是「不当作正常」，
      // **绝不是删掉它**：它可能是用户唯一的一份，而「解不开」也可能是
      // 我们这一侧的问题（解码器不支持某个 profile）。
      expect(File(segment.filePath).existsSync(), isTrue,
          reason: '校验失败绝不删文件 —— 宁可留一条可能坏的，也不要删掉可能是好的');
    });

    test('★ 前提：同一个分段落，校验通过就照常入库', () async {
      // ⚠️ 少了这一条，上面那条可能**绿在一个巧合上**
      // （比如索引本来就写不进去、或者分段落本身有问题）。
      final (finalizer, index) = makeFinalizer(
        suffix: '-verify-ok',
        verify: (_) async => true,
      );
      final segment = makeSegment('s1', 0);

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [segment],
        reason: StopTrigger.manual,
      );

      expect(outcome.state, RecordingSessionState.indexed);
      expect(await index.loadAll(), hasLength(1));
    });

    test('不传校验时行为与从前一致', () async {
      // 老路径（测试里大量用到）不该被这条新闸牵连 ——
      // 「不传 = 不校验」是给那些不关心它的用例留的口子。
      final (finalizer, index) = makeFinalizer(suffix: '-verify-none');

      final outcome = await finalizer.finalize(
        sessionId: 's1',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        segments: [makeSegment('s1', 0)],
        reason: StopTrigger.manual,
      );

      expect(outcome.state, RecordingSessionState.indexed);
      expect(await index.loadAll(), hasLength(1));
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

  /// 造一个「录到一半被杀」的工作区：有分段、有清单、没有 finalized 标记。
  ///
  /// ⚠️ 放在 `main()` 这一层（不在某个 `group` 里）：孤儿恢复与 T21 两组都要用它。
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

  group('孤儿恢复', () {
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

  // ─────────────────────────────────────────────
  // T21：`work/` 里的东西不会越积越多
  // ─────────────────────────────────────────────

  group('T21 工作目录', () {
    /// 造一个「起录之后、第一段封闭之前被杀」的空会话目录。
    Future<RecordingWorkspace> emptySession(String sessionId,
        {Duration? manifestAge}) async {
      final workspace = RecordingWorkspace('$root/work');
      await workspace.writeManifest(SessionManifest(
        sessionId: sessionId,
        waybill: waybill,
        sourceDeviceId: 'device-1',
        startedAt: started,
        segments: const [],
      ));

      if (manifestAge != null) {
        final path = '${workspace.sessionDirectory(sessionId)}/'
            '${RecordingWorkspace.manifestFileName}';
        File(path).setLastModifiedSync(DateTime.now().subtract(manifestAge));
      }

      return workspace;
    }

    test('★ 孤儿收尾成功之后，work 里那份就丢掉了', () async {
      final workspace = await killedSession('s-killed');
      final (finalizer, _) = makeFinalizer();

      await OrphanRecovery(workspace: workspace, finalizer: finalizer).recover();

      // 成品已经落进本机归档 ⇒ 源分段只剩占地方。
      // 清理层只清归档里的成品、从来不碰 `work/`，留着它就是无界增长。
      expect(Directory(workspace.sessionDirectory('s-killed')).existsSync(), isFalse);
    });

    test('★ 收尾失败时工作目录留着（下次启动还要重试）', () async {
      final workspace = await killedSession('s-killed');
      final finalizer = SessionFinalizer(
          rootDirectory: root,
          index: _ThrowingIndex(),
          labels: LabelStore('$root/labels.jsonl'));

      await OrphanRecovery(workspace: workspace, finalizer: finalizer).recover();

      expect(Directory(workspace.sessionDirectory('s-killed')).existsSync(), isTrue,
          reason: '源文件是重试的唯一输入（I2），收尾失败就不许丢');
    });

    test('★ 空会话目录过了冷静期就被清掉，并且留一条日志', () async {
      await AppLog.instance.resetForTesting();
      final workspace = await emptySession('s-empty',
          manifestAge: const Duration(hours: 25));

      expect(await workspace.listOrphans(), isEmpty);

      // ⚠️ T21 之前：这种目录**收不了尾**（没有分段可收）⇒ 也永远写不上
      // finalized.json ⇒ 孤儿扫瞄每次都静默跳过它 ⇒ 谁都不会碰它一下。
      expect(Directory(workspace.sessionDirectory('s-empty')).existsSync(), isFalse);
      expect(
        AppLog.instance.tail.value.any((line) => line.contains('空会话目录')),
        isTrue,
        reason: '清掉也要留一条 —— 不能是静默的',
      );
    });

    test('★ 刚起录的空会话目录不会被清掉', () async {
      final workspace = await emptySession('s-fresh');

      expect(await workspace.listOrphans(), isEmpty);

      // ⚠️ 冷静期就是为这一刻留的：**刚起录时会话目录也是空的**
      // （第一段封闭之前不写任何分段）。立刻删等于把正在录的那一场连根拔了。
      expect(Directory(workspace.sessionDirectory('s-fresh')).existsSync(), isTrue);
    });

    test('★ 源分段一个都不在了要说一声，而不是静默跳过', () async {
      await AppLog.instance.resetForTesting();
      final workspace = RecordingWorkspace('$root/work');

      // manifest 里记着一段，但那个文件不在盘上（被手工删了 / 盘坏了）。
      await workspace.writeManifest(SessionManifest(
        sessionId: 's-gone',
        waybill: waybill,
        sourceDeviceId: 'device-1',
        startedAt: started,
        segments: [
          SegmentManifest(
            sequence: 0,
            fileName: 'segment-000.mp4',
            startedAt: started,
            endedAt: started.add(const Duration(seconds: 30)),
          ),
        ],
      ));

      expect(await workspace.listOrphans(), isEmpty);

      // ⚠️ 这不是「一条噪声」：它意味着**这一场再也收不了尾**（I2 的方向是丢证据），
      // 而 T21 之前这里是一个不声不响的 continue。
      expect(
        AppLog.instance.tail.value.any((line) => line.contains('一个都不在了')),
        isTrue,
      );
      expect(Directory(workspace.sessionDirectory('s-gone')).existsSync(), isTrue,
          reason: '没到冷静期 ⇒ 目录先留着');
    });
  });

  // ─────────────────────────────────────────────
  // T20：「正在写的那一段」
  // ─────────────────────────────────────────────

  group('T20 没登记的分段', () {
    /// 造一个「录到一半被杀」的会话：清单里只有第 0 段，盘上**多一个**没登记的第 1 段。
    Future<RecordingWorkspace> killedMidSegment(String sessionId,
        {int extraBytes = 4096}) async {
      final workspace = await killedSession(sessionId);

      File('${workspace.sessionDirectory(sessionId)}/segment-001.mp4')
          .writeAsBytesSync(List<int>.filled(extraBytes, 7));

      return workspace;
    }

    test('★ 没登记的那一段要说一声 —— 手机端救不回来，但不能不响', () async {
      await AppLog.instance.resetForTesting();
      final workspace = await killedMidSegment('s-killed');

      final orphans = await workspace.listOrphans();

      // ⚠️ 电脑端扫到它**会**捞回来（MKV 分段结构，remux 就活了）。
      // 手机端原生相机直接写最终的 MP4，moov 在文件末尾，进程被杀时那一段没写下去 ——
      // 那个文件根本打不开，列进收尾只会让**整场**收尾失败（规格 §4.1：
      // 一段不通过 ⇒ 全会话不作数）。所以这里只记不清单里那一段。
      expect(orphans.single.segments.map((s) => s.sequence), [0]);
      expect(
        AppLog.instance.tail.value.any((line) => line.contains('救不回来')),
        isTrue,
        reason: '最后那一段没了，用户有权知道 —— 不能是静默的（I3）',
      );
    });

    test('清单里记着的分段不算「没登记」', () async {
      await AppLog.instance.resetForTesting();
      final workspace = await killedSession('s-killed');

      await workspace.listOrphans();

      expect(
        AppLog.instance.tail.value.any((line) => line.contains('救不回来')),
        isFalse,
      );
    });

    test('0 字节的空壳不算 —— 那里本来就没画面', () async {
      await AppLog.instance.resetForTesting();
      final workspace = await killedMidSegment('s-killed', extraBytes: 0);

      await workspace.listOrphans();

      expect(
        AppLog.instance.tail.value.any((line) => line.contains('救不回来')),
        isFalse,
      );
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
