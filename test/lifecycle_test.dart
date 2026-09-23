import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/business_type.dart';
import 'package:vidlog_mobile/recording/lifecycle.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/retention_setting.dart';
import 'package:vidlog_mobile/states.dart';
import 'package:vidlog_mobile/upload/archive_store.dart';

/// §3.5 生命周期判定 —— 谁够格被清、谁不能，以及**为什么**。
///
/// 这一层只判定、不删（执行层要等 M6，见 `lifecycle.dart` 文件末）。所以
/// 这里钉的是**口径**：三段硬豁免、两条保留期、以及那个最容易写错的起算点。
///
/// 口径错了的代价是**不可逆**的：删掉的是证据。
void main() {
  // 固定一个「现在」。用真实时钟的话，跨零点那一刻用例会自己变红。
  final now = DateTime(2026, 9, 23, 12);

  RecordingEntry entry(String id, {required Duration ago}) =>
      RecordingEntry(
        evidenceId: id,
        sessionId: 'sess-$id',
        waybill: WaybillNumber.parse('SF1234567890'),
        startedAt: now.subtract(ago),
        endedAt: now.subtract(ago),
        duration: const Duration(minutes: 5),
        location: RelativePath.parse('2026/09/23/$id.mp4'),
        contentHash: ContentHash.parse('a' * 64),
        sourceDeviceId: 'dev-1',
      );

  /// 归档状态：默认「九天前备份成功的」—— 已经出了 3 天保留期，
  /// 所以默认的结论是**该清**，要验豁免的用例自己把时间调近。
  ArchiveRecord archived(String id, {Duration since = const Duration(days: 9)}) =>
      ArchiveRecord(
        evidenceId: id,
        state: UploadState.archived,
        timeAnchor: now.subtract(since),
      );

  Map<String, Map<String, String>> labels(
    String id, {
    BusinessType? type = BusinessType.outbound,
    String? locked,
  }) =>
      {
        id: {
          if (type != null) BusinessType.labelKey: type.wire,
          lockedLabelKey: ?locked,
        }
      };

  CleanupPlan plan(
    List<RecordingEntry> entries, {
    Map<String, Map<String, String>>? labelTable,
    Map<String, ArchiveRecord>? archive,
    RetentionSetting outbound = RetentionSetting.days3,
    RetentionSetting returning = RetentionSetting.days3,
  }) =>
      planCleanup(
        entries: entries,
        labels: labelTable ??
            {
              for (final e in entries)
                e.evidenceId: {BusinessType.labelKey: BusinessType.outbound.wire}
            },
        archive: archive ??
            {for (final e in entries) e.evidenceId: archived(e.evidenceId)},
        retentionOutbound: outbound,
        retentionReturn: returning,
        now: now,
      );

  // ─────────────────────────────────────────────
  // 三段硬豁免（规格 §3.5.3，用户关不掉）
  // ─────────────────────────────────────────────

  group('三段硬豁免', () {
    test('★ 没备份上去的绝不删 —— 它是唯一副本（I2）', () {
      // 状态表里压根没有这条记录 = 还没传上去。
      final e = entry('a', ago: const Duration(days: 400));

      final result = plan([e], archive: const {});

      expect(result.candidates, isEmpty);
      expect(result.exempted.single.why, contains('唯一副本'));
    });

    test('传到一半失败的那条也不删 —— 只有 archived 才算数', () {
      final e = entry('a', ago: const Duration(days: 400));

      final result = plan([e], archive: {
        'a': ArchiveRecord(evidenceId: 'a', state: UploadState.failed),
      });

      expect(result.candidates, isEmpty);
      expect(result.exempted.single.why, contains('唯一副本'));
    });

    test('锁着的一条永远不清，解锁之后才轮到它', () {
      // 规格 §3.6.5：锁定后**永不被自动清理**，可以无限期压住保留期 ——
      // 这是有意的，所以这里特意让它在保留期外很久。
      final e = entry('a', ago: const Duration(days: 400));

      final locked = plan([e], labelTable: labels('a', locked: 'true'));
      expect(locked.candidates, isEmpty);
      expect(locked.exempted.single.why, contains('锁定'));

      // 解锁 = 再追加一条 false（标签表是后者胜出），不是原地改。
      final unlocked = plan([e], labelTable: labels('a', locked: 'false'));
      expect(unlocked.candidates.single.entry.evidenceId, 'a');
    });

    test('★ 认不出来的锁值一律当锁着 —— 朝少删的那头落', () {
      // 把锁读丢了的代价是**删掉用户锁上的证据**；反过来只是少清一条，
      // 而且它在豁免列表里看得见。与 `RetentionSetting.fromConfig` 解析失败
      // 回落到「全部保留」、归档状态认不出当 pending 是同一条规矩。
      final e = entry('a', ago: const Duration(days: 400));

      for (final raw in ['1', 'yes', '', 'TRUE ', '被人手改坏了']) {
        final result = plan([e], labelTable: labels('a', locked: raw));
        expect(result.candidates, isEmpty, reason: '锁值写成「$raw」时不该被清');
      }
    });

    test('没打过锁标签 = 没锁 —— 少了这一条整个库会被永久锁死', () {
      final e = entry('a', ago: const Duration(days: 400));

      expect(plan([e]).candidates, hasLength(1));
    });

    test('刚录完 24 小时内一律不动 —— 连「不保留」也动不了它', () {
      // 规格 §3.5.3③ 是**硬性**的：§3.5.2.1 里任何选项都不能关掉它。
      // 这也是「不保留」实际不等于立刻删的原因。
      final e = entry('a', ago: const Duration(hours: 3));

      final result = plan([e], outbound: RetentionSetting.none);

      expect(result.candidates, isEmpty);
      expect(result.exempted.single.why, contains('24 小时'));
    });
  });

  // ─────────────────────────────────────────────
  // 起算点（规格 §3.5.2.1）
  // ─────────────────────────────────────────────

  group('保留期从「备份成功那一刻」起算', () {
    test('★ 录完很久、但刚备份成功 —— 不清', () {
      // 依据是 §4.3 的合取式「归档成功 **且** 超过保留期」。要是从录完起算，
      // 一台离线 40 天的机器会在**刚归档那一瞬间**就被删掉 ——
      // 那等于绕开了「至少一份副本」（I2）的意图。
      final e = entry('a', ago: const Duration(days: 40));

      final result = plan([e], archive: {'a': archived('a', since: const Duration(hours: 1))});

      expect(result.candidates, isEmpty);
      expect(result.exempted.single.why, contains('还在 3 天保留期内'));
    });

    test('录完 40 天、备份成功 4 天 —— 这一条才该清', () {
      final e = entry('a', ago: const Duration(days: 40));

      final result = plan([e], archive: {'a': archived('a', since: const Duration(days: 4))});

      expect(result.candidates.single.entry.evidenceId, 'a');
      expect(result.candidates.single.why, contains('3 天'));
    });

    test('回执里没有时间锚时不清 —— 算不出起算点', () {
      final e = entry('a', ago: const Duration(days: 400));

      final result = plan([e], archive: {
        'a': const ArchiveRecord(evidenceId: 'a', state: UploadState.archived),
      });

      expect(result.candidates, isEmpty);
      expect(result.exempted.single.why, contains('时间锚'));
    });
  });

  // ─────────────────────────────────────────────
  // 发货 / 退货各一份（规格 §3.5.2.1）
  // ─────────────────────────────────────────────

  group('发货与退货各用各的那一份', () {
    test('★ 改一份不动另一份', () {
      // 同一时刻录的两条，只有业务类型不同。发货留 30 天、退货设「不保留」——
      // 退货那条该进候选，发货那条该原封不动。
      final a = entry('a', ago: const Duration(days: 10));
      final b = entry('b', ago: const Duration(days: 10));

      final result = plan(
        [a, b],
        labelTable: {
          'a': {BusinessType.labelKey: BusinessType.outbound.wire},
          'b': {BusinessType.labelKey: BusinessType.returning.wire},
        },
        outbound: RetentionSetting.days30,
        returning: RetentionSetting.none,
      );

      expect(result.candidates.single.entry.evidenceId, 'b');
      expect(result.exempted.single.entry.evidenceId, 'a');
    });

    test('没有业务类型标签的按「全部保留」处理 —— 不猜', () {
      // 判不出它是发货还是退货，就说不出它该用哪一份保留期。
      // 猜错的代价是删掉证据，猜不出的代价只是占地方 —— 而后者看得见。
      final e = entry('a', ago: const Duration(days: 400));

      final result = plan([e], labelTable: const {});

      expect(result.candidates, isEmpty);
      expect(result.exempted.single.why, contains('业务类型'));
    });

    test('业务类型的值认不出来也只当没标签 —— 与两端同一套合法取值', () {
      final e = entry('a', ago: const Duration(days: 400));

      final result = plan([e], labelTable: {
        'a': {BusinessType.labelKey: 'Outbound'}, // 大小写不对
      });

      expect(result.candidates, isEmpty);
    });
  });

  // ─────────────────────────────────────────────
  // 策略与预告（规格 §3.5.2 / §3.5.5）
  // ─────────────────────────────────────────────

  group('策略与预告', () {
    test('「全部保留」时谁都别动，而且逐条说明是策略挡的', () {
      final a = entry('a', ago: const Duration(days: 400));
      final b = entry('b', ago: const Duration(days: 400));

      final result = plan([a, b],
          outbound: RetentionSetting.keepAll, returning: RetentionSetting.keepAll);

      expect(result.candidates, isEmpty);
      expect(result.exempted, hasLength(2));
      expect(result.exempted.every((e) => e.why.contains('全部保留')), isTrue);
    });

    test('★ 每一条没被清的都说得出为什么（§3.5.5：用户要能查）', () {
      // 只给候选不给豁免，用户就无从质疑 —— 他看不到「我锁了的那条还在不在计划里」。
      final a = entry('a', ago: const Duration(days: 400));
      final b = entry('b', ago: const Duration(hours: 2));
      final c = entry('c', ago: const Duration(days: 400));

      final result = plan([a, b, c], labelTable: {
        'a': {BusinessType.labelKey: 'outbound', lockedLabelKey: 'true'},
        'b': {BusinessType.labelKey: 'outbound'},
        'c': const {},
      });

      expect(result.exempted, hasLength(3));
      for (final e in result.exempted) {
        expect(e.why.trim(), isNotEmpty);
      }
    });

    test('预告的容量按时长推算 —— 与电脑端同一个系数', () {
      // 640x480@30 的 H.264 实测约 160 KB/s（= 163 840 B/s）。两端的预告数字
      // 要对得上，所以系数不能各写各的。
      final e = entry('a', ago: const Duration(days: 400));

      final result = plan([e]);

      // 5 分钟 = 300 秒 → 300 × 163 840 = 49 152 000 字节（约 49 MB）
      expect(estimateBytes(e), 49152000);
      expect(result.totalBytes, 49152000);
    });

    test('时长为负时预告 0，不给负数', () {
      // 那个值只喂给「将腾出多少」这句预告，负的容量是句废话。
      final bad = RecordingEntry(
        evidenceId: 'a',
        sessionId: 'sess-a',
        waybill: WaybillNumber.parse('SF1234567890'),
        startedAt: now,
        endedAt: now,
        // 手改坏的 index.jsonl 会长这样。
        duration: const Duration(seconds: -1),
        location: RelativePath.parse('2026/09/23/a.mp4'),
        contentHash: ContentHash.parse('a' * 64),
        sourceDeviceId: 'dev-1',
      );

      expect(estimateBytes(bad), 0);
    });
  });
}
