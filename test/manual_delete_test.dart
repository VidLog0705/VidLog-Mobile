import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/cleanup_audit.dart';
import 'package:vidlog_mobile/recording/manual_delete.dart';
import 'package:vidlog_mobile/recording/recording_totals.dart';
import 'package:vidlog_mobile/states.dart';
import 'package:vidlog_mobile/upload/archive_store.dart';

/// 手动删除（规格 §3.5.6）。
///
/// 判定层是纯函数（不碰文件系统），所以这一批能在本机验到底；
/// 「删了之后盘上真的没了」那半在最后两条里用真临时目录验。
void main() {
  final now = DateTime(2026, 9, 27, 12);

  RecordingSession session(List<String> ids, {String sessionId = 'sess-1'}) =>
      RecordingSession(
        sessionId: sessionId,
        waybill: WaybillNumber.parse('SF1000000001'),
        startedAt: now.subtract(const Duration(hours: 2)),
        duration: const Duration(minutes: 5),
        bytes: 1024,
        segmentCount: ids.length,
        evidenceIds: ids,
      );

  ArchiveRecord archived(String id) => ArchiveRecord(
        evidenceId: id,
        state: UploadState.archived,
        timeAnchor: now.subtract(const Duration(days: 3)),
      );

  ArchiveRecord pending(String id) =>
      ArchiveRecord(evidenceId: id, state: UploadState.pending);

  group('按「备份了没有」分两种弹窗（§3.5.6②）', () {
    test('已备份 → 两选一（确认 / 取消）', () {
      final plan = planManualDelete(
        session: session(['e1']),
        records: {'e1': archived('e1')},
        verify: {'e1': VerifyOutcome.ok},
      );

      expect(plan.decision, DeleteDecision.confirmArchived);
      expect(plan.deletionAllowed, isTrue);
      expect(plan.reason, contains('删除后无法恢复'));
    });

    test('★ 未备份 → 三选一，而且措辞必须说出「这是唯一一份」', () {
      // ⚠️ 这一条是规格点名的：「不许把两个弹窗合成一个」——
      // 「删除后无法恢复」对已备份的是「本机这份没了」，
      // 对未备份的是「**证据永久没了**」。这两句话对用户不是一回事。
      final plan = planManualDelete(
        session: session(['e1']),
        records: {'e1': pending('e1')},
        verify: const {}, // 没备份就没有那份可查
      );

      expect(plan.decision, DeleteDecision.confirmUnarchived);
      expect(plan.needsUploadChoice, isTrue);
      expect(plan.reason, contains('唯一一份'));
      expect(plan.deletionAllowed, isTrue, reason: '需求方追问后裁决：未备份的也给删');
    });

    test('一条里有一段没备份 → 也按「未备份」处理', () {
      // 一次录制多个分段，只要有一段没传上去，那一段就只在这一台手机上。
      final plan = planManualDelete(
        session: session(['e1', 'e2']),
        records: {'e1': archived('e1'), 'e2': pending('e2')},
        verify: {'e1': VerifyOutcome.ok},
      );

      expect(plan.decision, DeleteDecision.confirmUnarchived);
    });

    test('状态表里压根没有这一条 → 未备份', () {
      final plan = planManualDelete(
        session: session(['e1']),
        records: const {},
        verify: const {},
      );

      expect(plan.decision, DeleteDecision.confirmUnarchived);
    });
  });

  group('★ 删之前必须回查归档层（§3.5.6③）', () {
    test('回查说那份没了 → 不许删，并说明它现在是唯一副本', () {
      final plan = planManualDelete(
        session: session(['e1']),
        records: {'e1': archived('e1')},
        verify: {'e1': VerifyOutcome.missing},
      );

      expect(plan.decision, DeleteDecision.refusedMissingCopy);
      expect(plan.deletionAllowed, isFalse);
      expect(plan.evidenceIds, isEmpty, reason: '不许删的时候一个也不许删');
      expect(plan.reason, contains('唯一副本'));
    });

    test('★ 查不了 → 也不许删，而且与「没了」是两句话', () {
      // ⚠️ 把「查不了」当成「不存在」，删掉的可能就是最后一份（I2）。
      final plan = planManualDelete(
        session: session(['e1']),
        records: {'e1': archived('e1')},
        verify: {
          'e1': const VerifyOutcome(
              exists: false, couldNotVerify: true, reason: '连不上电脑端'),
        },
      );

      expect(plan.decision, DeleteDecision.refusedCouldNotVerify);
      expect(plan.deletionAllowed, isFalse);
      expect(plan.reason, contains('问不到'));
      expect(plan.reason, isNot(contains('唯一副本')),
          reason: '「查不了」不该说成「那份没了」—— 那是两句不同的话');
    });

    test('★ 有一段没问过 → 当「查不了」，绝不当成「在」', () {
      final plan = planManualDelete(
        session: session(['e1', 'e2']),
        records: {'e1': archived('e1'), 'e2': archived('e2')},
        verify: {'e1': VerifyOutcome.ok}, // e2 没问
      );

      expect(plan.decision, DeleteDecision.refusedCouldNotVerify);
      expect(plan.deletionAllowed, isFalse);
    });

    test('两段都查过而且都在 → 才允许删', () {
      final plan = planManualDelete(
        session: session(['e1', 'e2']),
        records: {'e1': archived('e1'), 'e2': archived('e2')},
        verify: {'e1': VerifyOutcome.ok, 'e2': VerifyOutcome.ok},
      );

      expect(plan.decision, DeleteDecision.confirmArchived);
      expect(plan.evidenceIds, ['e1', 'e2']);
    });
  });

  group('真删：先写审计，再删文件', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('vidlog-del-');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('★ 删掉的是这一条的各段文件，而且留着审计', () async {
      final dir = Directory('${temp.path}/2026/09/27/SF1000000001')
        ..createSync(recursive: true);
      final first = File('${dir.path}/e1.mp4')..writeAsStringSync('a');
      final second = File('${dir.path}/e2.mp4')..writeAsStringSync('b');

      final audit = CleanupAuditLog('${temp.path}/cleanup-audit.jsonl');

      final plan = planManualDelete(
        session: session(['e1', 'e2']),
        records: {'e1': archived('e1'), 'e2': archived('e2')},
        verify: {'e1': VerifyOutcome.ok, 'e2': VerifyOutcome.ok},
      );

      final deleted = await deleteSessionFiles(
        plan: plan,
        locationByEvidenceId: {
          'e1': '2026/09/27/SF1000000001/e1.mp4',
          'e2': '2026/09/27/SF1000000001/e2.mp4',
        },
        rootDirectory: temp.path,
        audit: audit,
        now: now,
      );

      expect(deleted, ['e1', 'e2']);
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isFalse);

      final records = await audit.loadAll();
      expect(records, hasLength(2));
      expect(records.every((r) => r.action == CleanupAction.deleted), isTrue);
      expect(records.first.evidenceId, 'e1');
    });

    test('索引里没有那一段的位置 → 记 failed，不去猜路径', () async {
      final audit = CleanupAuditLog('${temp.path}/cleanup-audit.jsonl');

      final plan = planManualDelete(
        session: session(['e1']),
        records: {'e1': archived('e1')},
        verify: {'e1': VerifyOutcome.ok},
      );

      final deleted = await deleteSessionFiles(
        plan: plan,
        locationByEvidenceId: const {},
        rootDirectory: temp.path,
        audit: audit,
        now: now,
      );

      expect(deleted, isEmpty);

      final records = await audit.loadAll();
      expect(records.any((r) => r.action == CleanupAction.failed), isTrue);
    });

    test('文件本来就不在了 → 不算失败（用户要的就是「它没了」）', () async {
      final audit = CleanupAuditLog('${temp.path}/cleanup-audit.jsonl');

      final plan = planManualDelete(
        session: session(['e1']),
        records: {'e1': archived('e1')},
        verify: {'e1': VerifyOutcome.ok},
      );

      final deleted = await deleteSessionFiles(
        plan: plan,
        locationByEvidenceId: const {'e1': '2026/09/27/SF1000000001/e1.mp4'},
        rootDirectory: temp.path,
        audit: audit,
        now: now,
      );

      expect(deleted, ['e1']);
    });
  });

  group('审计流水的形态（与电脑端同一套键名）', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('vidlog-audit-');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('★ 键名是 PascalCase —— 与电脑端逐字一致', () async {
      // 两端各写一套键名的话，把手机上的这份拿到电脑端打开会对不上，
      // 而那正是「出事时唯一有用的东西」。
      final path = '${temp.path}/cleanup-audit.jsonl';
      final log = CleanupAuditLog(path);

      await log.append(CleanupAuditRecord(
        evidenceId: 'e1',
        action: CleanupAction.deleted,
        reason: '用户手动删除',
        at: now,
      ));

      final line = File(path).readAsLinesSync().single;

      expect(line, contains('"EvidenceId":"e1"'));
      expect(line, contains('"Action":"deleted"'));
      expect(line, contains('"Reason"'));
      expect(line, contains('"At"'));
    });

    test('坏行跳过，不让一行毁掉整份流水', () async {
      final path = '${temp.path}/cleanup-audit.jsonl';
      File(path).writeAsStringSync(
        '{"EvidenceId":"e1","Action":"deleted","Reason":"x","At":"2026-09-27T12:00:00Z"}\n'
        '这不是 JSON\n'
        '{"EvidenceId":"e2","Action":"refused","Reason":"y","At":"2026-09-27T12:00:00Z"}\n',
      );

      final records = await CleanupAuditLog(path).loadAll();

      expect(records.map((r) => r.evidenceId), ['e1', 'e2']);
    });
  });
}
