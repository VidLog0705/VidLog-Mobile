import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/business_type.dart';
import 'package:vidlog_mobile/recording/cleanup_audit.dart';
import 'package:vidlog_mobile/recording/cleanup_executor.dart';
import 'package:vidlog_mobile/recording/lifecycle.dart';
import 'package:vidlog_mobile/recording/manual_delete.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/recording/recording_totals.dart';
import 'package:vidlog_mobile/recording/retention_setting.dart';
import 'package:vidlog_mobile/states.dart';
import 'package:vidlog_mobile/upload/archive_store.dart';

/// I7：**交付副本不算归档层那份**（规格 §3.7）。
///
/// 手机端这边的交付副本就是 `_fetchFromArchive` 取回来的那一份，
/// 落在 `<root>/share/<单号>.mp4`（`recorder_view_records.dart:305`）。
/// 它取回来只有一个用途 —— **交出去**（存相册 + 弹分享），不该顺带变成一条录像。
///
/// ## 这个不变量长在哪儿
///
/// 列表、检索、清理**全都是从 `index.jsonl` 归并出来的**
/// （`loadAll()` → `dropGoneSegments` → `toSessions` → `filterSessions` / `planCleanup`）
/// —— 交付副本不在索引里，所以它们全都看不见它。
///
/// ⚠️ 这是一条**回归绊线**，不是「验一遍本来就对的东西」：哪天有人把上面任何
/// 一条改成「扫目录」，交付副本会立刻被当成一份录像 —— 进列表、被检索到、
/// 被清理删掉。那时候下面这几条会红。
///
/// ⚠️ **不在本文件范围里的**：备份页那个「实际存储到手机的视频大小总量」走的是
/// `videoBytesOnDisk`（`recording_totals.dart:253`），它**本来就是扫目录**，
/// 因此**会把 `<root>/share/` 下的交付副本算进去**。那是另一个口径、
/// 另一个问题，见 `test/recording_totals_test.dart`。
void main() {
  late Directory temp;
  late String root;

  final now = DateTime(2026, 9, 27, 12);

  /// 一条真录像：四十天前录的 —— 落在 §3.5.3③「最近 24 小时」那道豁免之外。
  RecordingEntry realEntry() => RecordingEntry(
        evidenceId: 'e1',
        sessionId: 's1',
        waybill: WaybillNumber.parse('SF1000000001'),
        startedAt: now.subtract(const Duration(days: 40)),
        endedAt: now.subtract(const Duration(days: 40)).add(const Duration(minutes: 5)),
        duration: const Duration(minutes: 5),
        location: RelativePath.parse('work/e1.mp4'),
        contentHash: ContentHash.parse(List.filled(64, 'a').join()),
        sourceDeviceId: 'device-1',
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-i7-');
    root = temp.path;

    // 归档层那一份真的在盘上。
    final real = File('$root/work/e1.mp4')..createSync(recursive: true);
    real.writeAsStringSync('evidence');

    // 交付副本：从电脑端取回来的那一份，落在 `<root>/share/`。
    File('$root/share/SF1000000001.mp4')
      ..createSync(recursive: true)
      ..writeAsStringSync('delivered');

    // 盘上还有一份**没进索引**的野文件（收尾没收上的孤儿片段）。
    File('$root/work/野.mp4')
      ..createSync(recursive: true)
      ..writeAsStringSync('orphan');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  // ─────────────────────────────────────────────
  // 列表 / 检索
  // ─────────────────────────────────────────────

  test('★ 盘上有三份 .mp4，列表上只有索引里那一条', () async {
    final index = JsonLinesRecordingIndex('$root/index.jsonl');
    await index.add(realEntry());

    final entries = await index.loadAll();

    // 「这条还在不在」问索引问不出来，只能问盘 —— 与生产代码同一口径。
    final gone = <String>{
      for (final entry in entries)
        if (!File('$root/${entry.location.value}').existsSync()) entry.evidenceId,
    };
    final present = dropGoneSegments(entries, gone);
    final sessions = toSessions(present, const {});

    expect(sessions, hasLength(1), reason: '交付副本和野文件都不在索引里');
    expect(sessions.single.evidenceIds, ['e1']);
    expect(sessions.single.waybill.value, 'SF1000000001');

    // 检索那一条：搜单号只会搜到索引里那一条。
    final hits = filterSessions(sessions, query: 'SF1000000001', typeOf: (_) => null);
    expect(hits, hasLength(1), reason: '交付副本不在列表里，自然也不在搜索结果里');
    expect(hits.single.sessionId, 's1');
  });

  // ─────────────────────────────────────────────
  // 清理
  // ─────────────────────────────────────────────

  test('★ 真清一遍：归档层那份没了，交付副本还在原地', () async {
    final index = JsonLinesRecordingIndex('$root/index.jsonl');
    await index.add(realEntry());
    final entries = await index.loadAll();

    final plan = planCleanup(
      entries: entries,
      labels: {
        'e1': {BusinessType.labelKey: BusinessType.outbound.wire},
      },
      archive: {
        'e1': ArchiveRecord(
          evidenceId: 'e1',
          state: UploadState.archived,
          timeAnchor: now.subtract(const Duration(days: 30)),
        ),
      },
      retentionArchivedOutbound: RetentionSetting.days7,
      retentionArchivedReturn: RetentionSetting.days7,
      now: now,
    );

    // 前提：这一条**确实**够格了，否则下面那句「删了」是空过的。
    expect(plan.candidates.map((c) => c.entry.evidenceId), ['e1']);

    final outcome = await runCleanup(
      plan: plan,
      locationByEvidenceId: {'e1': 'work/e1.mp4'},
      rootDirectory: root,
      audit: CleanupAuditLog.inRoot(root),
      now: now,
      // 回查说「归档层上还在」—— 只是为了让这一条真的过闸。
      verify: (_) async => VerifyOutcome.ok,
    );

    expect(outcome.deleted, ['e1']);
    expect(File('$root/work/e1.mp4').existsSync(), isFalse, reason: '本机那一份按计划该没了');
    expect(File('$root/share/SF1000000001.mp4').existsSync(), isTrue,
        reason: '交付副本不是归档层那份 —— 清理不该把它一起带走');
  });
}
