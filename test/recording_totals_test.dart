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
      final restored = RecordingEntry.fromJson(original.toJson());

      expect(restored.sessionId, 'sess-1');
    });

    test('老条目（没有这个字段）靠 evidenceId 兜底', () {
      final json = entry(evidenceId: 'sess-1-002', sessionId: 'sess-1').toJson()
        ..remove('sessionId');

      expect(RecordingEntry.fromJson(json).sessionId, 'sess-1');
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
}
