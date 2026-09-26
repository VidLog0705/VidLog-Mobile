import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/recording_totals.dart';

/// 备份页上那三个数字的口径（需求方 2026-09-22）。
///
/// 这里守的是一件很容易做错、而且做错了**用户也看不出来**的事：
/// 索引是按**分段**记的，而界面上说的「一条」是**一次录制**。
/// 一段 30 分钟的录制（5 分钟一段）在索引里是 6 行 —— 拿行数去显示，
/// 数字会比用户心里的大 5 倍，而他数不出那个数字是哪来的。
void main() {
  RecordingEntry entry({
    required String evidenceId,
    String? sessionId,
    String waybill = 'SF1000000001',
    DateTime? startedAt,
    int durationSeconds = 300,
  }) =>
      RecordingEntry(
        evidenceId: evidenceId,
        sessionId: sessionId ?? sessionIdFromEvidenceId(evidenceId),
        waybill: WaybillNumber.parse(waybill),
        startedAt: startedAt ?? DateTime(2026, 9, 22, 10),
        endedAt: (startedAt ?? DateTime(2026, 9, 22, 10))
            .add(Duration(seconds: durationSeconds)),
        duration: Duration(seconds: durationSeconds),
        location: RelativePath.parse('work/$evidenceId.mp4'),
        contentHash: ContentHash.parse(List.filled(64, '0').join()),
        sourceDeviceId: 'device-1',
      );

  group('一次录制 = 一条', () {
    test('★ 同一次录制的多个分段归成一条，时间和大小都求和', () {
      final entries = [
        entry(
          evidenceId: 'sess-1000-42-001',
          startedAt: DateTime(2026, 9, 22, 10, 0),
        ),
        entry(
          evidenceId: 'sess-1000-42-002',
          startedAt: DateTime(2026, 9, 22, 10, 5),
        ),
        entry(
          evidenceId: 'sess-1000-42-003',
          startedAt: DateTime(2026, 9, 22, 10, 10),
        ),
      ];
      final bytes = {
        'sess-1000-42-001': 100,
        'sess-1000-42-002': 100,
        'sess-1000-42-003': 100,
      };

      final sessions = toSessions(entries, bytes);

      expect(sessions, hasLength(1), reason: '三条索引行是**一次**录制');
      expect(sessions.single.segmentCount, 3);
      expect(sessions.single.duration, const Duration(seconds: 900));
      expect(sessions.single.bytes, 300);
    });

    test('★ 带上各分段的 evidenceId，按时间排 —— 备份状态要拿它去归并', () {
      // 界面上那一格备份状态是 `summarizeUploadState(session.evidenceIds, …)`
      // 算出来的（`archive.jsonl` 以 evidenceId 为键）。这个字段要是空的或者
      // 少一段，那一格就会把「传了一半」说成「已备份」。
      final entries = [
        entry(evidenceId: 'sess-1-002', startedAt: DateTime(2026, 9, 22, 10, 5)),
        entry(evidenceId: 'sess-1-001', startedAt: DateTime(2026, 9, 22, 10, 0)),
        entry(evidenceId: 'sess-1-003', startedAt: DateTime(2026, 9, 22, 10, 10)),
      ];

      final sessions = toSessions(entries, const {});

      // 顺序按**录制时间**，不是索引里或调用方给的那个顺序 ——
      // 将来要说「第 3 段没传上去」时，说的得是第 3 段。
      expect(sessions.single.evidenceIds,
          ['sess-1-001', 'sess-1-002', 'sess-1-003']);
      expect(sessions.single.evidenceIds, hasLength(sessions.single.segmentCount));
    });

    test('起录时间取最早的那一段 —— 跨零点的那条算开始录的那天', () {
      final entries = [
        entry(
          evidenceId: 'sess-1-001',
          sessionId: 'sess-1',
          startedAt: DateTime(2026, 9, 22, 23, 55),
        ),
        entry(
          evidenceId: 'sess-1-002',
          sessionId: 'sess-1',
          startedAt: DateTime(2026, 9, 23, 0, 0),
        ),
      ];

      final sessions = toSessions(entries, const {});

      expect(sessions.single.startedAt, DateTime(2026, 9, 22, 23, 55));
      expect(countToday(sessions, DateTime(2026, 9, 22, 12)), 1);
      expect(countToday(sessions, DateTime(2026, 9, 23, 12)), 0,
          reason: '同一条不能两天都算');
    });

    test('两条不相干的录像各自成条', () {
      final sessions = toSessions([
        entry(evidenceId: 'sess-a-001', sessionId: 'sess-a'),
        entry(evidenceId: 'sess-b-001', sessionId: 'sess-b'),
      ], const {});

      expect(sessions, hasLength(2));
    });

    test('没有 sessionId 的老条目：切不出前缀就各自算一条', () {
      // 宁可多算一条，也不要把两条不相干的录像并成一条 —— 计数少一条是小事，
      // 把证据合并不是。
      final sessions = toSessions([
        entry(evidenceId: '没有横线', sessionId: ''),
        entry(evidenceId: '尾段不是三位-01', sessionId: ''),
      ], const {});

      expect(sessions, hasLength(2));
    });

    test('新的在前', () {
      final sessions = toSessions([
        entry(evidenceId: 'sess-old-001', startedAt: DateTime(2026, 9, 20)),
        entry(evidenceId: 'sess-new-001', startedAt: DateTime(2026, 9, 22)),
      ], const {});

      expect(sessions.first.sessionId, 'sess-new');
    });

    test('量不到大小的分段按 0 加，不编一个数出来', () {
      final sessions = toSessions(
        [entry(evidenceId: 'sess-x-001')],
        const {},
      );

      expect(sessions.single.bytes, 0);
    });
  });

  group('证据 id 切会话 id', () {
    test('从**最后**一个横线切 —— 会话 id 自己带横线', () {
      expect(sessionIdFromEvidenceId('sess-1758500000000-42-007'),
          'sess-1758500000000-42');
    });

    test('尾段不是三位数字就不切', () {
      expect(sessionIdFromEvidenceId('sess-1-1'), isEmpty);
      expect(sessionIdFromEvidenceId('sess-1-abcd'), isEmpty);
      expect(sessionIdFromEvidenceId('sess-1-0001'), isEmpty);
      expect(sessionIdFromEvidenceId('没有横线'), isEmpty);
    });
  });

  group('索引里新加的 sessionId 字段', () {
    test('★ 存下来再读回去，值不变', () {
      final original = entry(evidenceId: 'sess-1-001', sessionId: 'sess-1');
      final restored = RecordingEntry.tryFromJson(original.toJson());

      expect(restored?.sessionId, 'sess-1');
    });

    test('老条目（没有这个字段）靠 evidenceId 兜底', () {
      final json = entry(evidenceId: 'sess-1-002', sessionId: 'sess-1').toJson()
        ..remove('sessionId');

      expect(RecordingEntry.tryFromJson(json)?.sessionId, 'sess-1');
    });
  });

  group('★ 宽容地读 —— 两端写的字段名不一样', () {
    test('电脑端写的 PascalCase 也读得回来', () {
      // 电脑端的 DTO 是 `Waybill` / `StartedAt` / `DurationSeconds`…（见
      // `VidLog.Desktop.Core/Index/RecordingIndex.cs` 的 `RecordingEntryDto`）。
      // 它对不上本仓的 camelCase，**也对不上母仓数据模型那张表**
      // （那张写的是 `WaybillNumber` / `RecordingStartedAt`）—— 三套名字。
      //
      // 两端的文件都已经在盘上了，所以读端必须宽容；写端维持原样。
      final json = <String, Object?>{
        'EvidenceId': 'sess-9-001',
        'SessionId': 'sess-9',
        'Waybill': 'SF1000000001',
        'StartedAt': '2026-09-27T02:00:00.0000000+00:00',
        'EndedAt': '2026-09-27T02:05:00.0000000+00:00',
        'DurationSeconds': 300,
        'Location': '2026/09/27/SF1000000001/sess-9_000.mp4',
        'ContentHash': 'a' * 64,
        'SourceDeviceId': 'desktop-1',
      };

      final restored = RecordingEntry.tryFromJson(json);

      expect(restored, isNotNull);
      expect(restored!.evidenceId, 'sess-9-001');
      expect(restored.waybill.value, 'SF1000000001');
      expect(restored.duration, const Duration(minutes: 5));
      expect(restored.sourceDeviceId, 'desktop-1');
    });

    test('★ 缺关键字段就丢掉这一条，不编一条出来', () {
      // 「读得宽容」指的是**字段名**，不是**内容**。少东西的记录宁可不要 ——
      // 编一条出来的话，一条不存在的录像会进检索、进清理判定。
      final json = entry(evidenceId: 'sess-1-003').toJson()..remove('waybill');

      expect(RecordingEntry.tryFromJson(json), isNull);
    });

    test('字段在但内容不合法，同样丢掉', () {
      final json = entry(evidenceId: 'sess-1-004').toJson()
        ..['startedAt'] = '不是时间';

      expect(RecordingEntry.tryFromJson(json), isNull);
    });
  });

  group('总占用走盘', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('vidlog-totals-');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    void write(String relative, int bytes) {
      final file = File('${temp.path}/$relative');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(List<int>.filled(bytes, 0));
    }

    test('★ 只数 .mp4，别的东西不算视频', () async {
      write('work/a.mp4', 1000);
      write('media/b.mp4', 500);
      write('index.jsonl', 9999);
      write('punches.jsonl', 9999);
      write('work/session.json', 9999);

      expect(await videoBytesOnDisk(temp.path), 1500);
    });

    test('目录不存在 → 0，不抛异常', () async {
      expect(await videoBytesOnDisk('${temp.path}/不存在'), 0);
    });
  });

  /// 视频记录那一页的搜索框（需求方 2026-09-23 照界面草图加）。
  ///
  /// 这里守的是**匹配的字就是屏幕上真有的字**：列表副标题上写着 `09-23`，
  /// 那么敲 `09-23` 就必须搜得到。两处各写一套格式的话，
  /// 屏幕上明明有却搜不出来 —— 用户只会以为搜索坏了（踩坑 #13）。
  group('按单号或日期搜（纯本地，不走许可）', () {
    RecordingSession session({
      String waybill = 'SF1000000001',
      String sessionId = 'sess-1',
      required DateTime startedAt,
    }) =>
        RecordingSession(
          sessionId: sessionId,
          waybill: WaybillNumber.parse(waybill),
          startedAt: startedAt,
          duration: const Duration(minutes: 5),
          bytes: 0,
          segmentCount: 1,
          evidenceIds: const ['e1'],
        );

    final target = session(startedAt: DateTime(2026, 9, 23, 14, 5));

    test('★ 副标题上那一段日期，敲进去搜得到', () {
      // 列表上显示的就是 `09-23`（见 `dayStamp`）。它必须能搜。
      expect(dayStamp(target.startedAt), '09-23');
      expect(matchesQuery(target, '09-23'), isTrue);
    });

    test('⚠️ 敲完整日期也搜得到 —— 只认 MM-DD 的话会「一条都搜不到」', () {
      // 用户更可能敲这种形式。搜不到和搜索坏了在用户眼里是同一件事。
      expect(matchesQuery(target, '2026-09-23'), isTrue);
    });

    test('单号按**模糊**匹配（规格 §3.8：精确 / 前缀 / 模糊）', () {
      expect(matchesQuery(target, 'SF1000000001'), isTrue, reason: '精确');
      expect(matchesQuery(target, 'SF100'), isTrue, reason: '前缀');
      expect(matchesQuery(target, '000001'), isTrue, reason: '模糊');
    });

    test('别的单号、别的日子都搜不到', () {
      expect(matchesQuery(target, 'SF999'), isFalse);
      expect(matchesQuery(target, '09-24'), isFalse);
      expect(matchesQuery(target, '2026-09-24'), isFalse);
    });

    test('空搜索词 = 不过滤（不是「什么都搜不到」）', () {
      // 这一条是**最容易写反**的：空串当匹配失败的话，搜索框一空整页就空了。
      expect(matchesQuery(target, ''), isTrue);
      expect(matchesQuery(target, '   '), isTrue);
    });

    test('大小写不敏感', () {
      expect(matchesQuery(target, 'sf100'), isTrue);
    });

    test('会话 id 那一支也得算数', () {
      // 列表上「单号为空就显示会话 id」（见 `_recordsCard`），所以那一串
      // 也算「界面上真有的字」。这条钉的是 `matchesQuery` 里会话 id 那一支 ——
      // 去掉它这条就红。
      // （构造不出「单号为空」的会话：`WaybillNumber.parse` 空串直接抛，
      //  所以这里用一条有单号的会话来钉那一支。）
      expect(matchesQuery(target, 'sess-1'), isTrue);
    });
  });
}
