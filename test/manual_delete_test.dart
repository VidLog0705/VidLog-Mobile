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

  /// ★ 需求方 2026-09-28 裁决的那条出路。
  ///
  /// 起因：试用到期后电脑端不再接受接入，那些**已经备份过**的录像会因为
  /// 「回查查不了」而一律不许删 —— 手机空间一点都腾不出来。
  /// 所以留一条出口。但**只给「查不了」**，而且默认方向仍然是拒绝。
  ///
  /// ⚠️ 这是对规格 §3.5.6③ 原话（「回查查不到（或查不了）⇒ 不许删」）的
  /// 一次**需求变更**，不是把那条读松了：改判必须由用户明确确认，
  /// 而且审计要留痕（§3.5.6④）。
  group('★ 「我确认电脑上有，仍然删除」—— 只给「查不了」那一种', () {
    DeletePlan couldNotVerify() => planManualDelete(
          session: session(['e1', 'e2']),
          records: {'e1': archived('e1'), 'e2': archived('e2')},
          verify: {
            'e1': VerifyOutcome.ok,
            'e2': const VerifyOutcome(
                exists: false, couldNotVerify: true, reason: '连不上电脑端'),
          },
        );

    test('★ 「查不了」给这条路', () {
      expect(couldNotVerify().canOverrideUnverified, isTrue);
    });

    test('★ 「归档层上找不到这一份」**不给** —— 那是问到了的答案', () {
      // ⚠️ 这一条是这一组的重点。`refusedMissingCopy` 是电脑端**明确回答**
      // 「没有这一份」——那种情况下手机上这条就真是最后一份，
      // 让用户凭一句「我确认」跨过去，删掉的就是 I2 里那个不可逆的损失。
      // 与「查不了」的差别不是措辞，是**知不知道**。
      final plan = planManualDelete(
        session: session(['e1']),
        records: {'e1': archived('e1')},
        verify: {'e1': VerifyOutcome.missing},
      );

      expect(plan.decision, DeleteDecision.refusedMissingCopy);
      expect(plan.canOverrideUnverified, isFalse);
      expect(
        overrideUnverifiedRefusal(session: session(['e1']), plan: plan),
        isNull,
        reason: '不给改判 —— 返回 null 才是「这条路不存在」',
      );
    });

    test('两种 confirm 也不给（它们本来就能删，用不着这条路）', () {
      final unarchived = planManualDelete(
        session: session(['e1']),
        records: {'e1': pending('e1')},
        verify: const {},
      );
      final ok = planManualDelete(
        session: session(['e1']),
        records: {'e1': archived('e1')},
        verify: {'e1': VerifyOutcome.ok},
      );

      expect(unarchived.canOverrideUnverified, isFalse);
      expect(ok.canOverrideUnverified, isFalse);
    });

    test('★ 改判之后能删，而且删的是 **session 的那几段**', () {
      // ⚠️ 拒绝那两颗 plan 的 `evidenceIds` 是**空的**（`const []`）。
      // 照抄它的话 `deleteSessionFiles` 一段都删不着，而界面上却走完了
      // 「删除成功」的整条路 —— 用户以为删了，文件还在盘上。
      final target = session(['e1', 'e2']);
      final forced = overrideUnverifiedRefusal(
        session: target,
        plan: couldNotVerify(),
      );

      expect(forced, isNotNull);
      expect(forced!.deletionAllowed, isTrue);
      expect(forced.evidenceIds, ['e1', 'e2'],
          reason: '必须从 session 重新取 —— 拒绝那颗 plan 的 evidenceIds 是空的');
    });

    test('★ 改判的理由要写明「是用户自己确认的」', () {
      // §3.5.5/④：事后要答得出「这条录像是什么时候没的、为什么没的」。
      // 理由里不写这件事的话，审计看上去就是一次**普通的**删除 ——
      // 而它其实是一次**没核对上**的删除，两者的性质不一样。
      final forced = overrideUnverifiedRefusal(
        session: session(['e1']),
        plan: couldNotVerify(),
      );

      expect(forced!.reason, contains('用户确认'));
      expect(forced.reason, contains('没能回查'),
          reason: '要留下「当时没核对上」这个事实');
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

  /// 批量删除（需求方 2026-09-27 照备份页草图定的【管理】那半）。
  ///
  /// ⚠️ 这一层最要紧的一条规矩：**只要有一条不能删，整批一条都不删**。
  /// 它跟「查不了 ⇒ 不许删」是同一个方向 —— 朝少删的那头落。
  group('★ 批量删除：一条不行就一条都不删', () {
    RecordingSession one(String id) => session([id], sessionId: id);

    BatchDeletePlan planFor(
      List<RecordingSession> sessions,
      Map<String, ArchiveRecord> records,
      Map<String, Map<String, VerifyOutcome>> verify,
    ) =>
        planBatchDelete(
          sessions: sessions,
          records: records,
          verifyBySession: verify,
        );

    test('三条都备份了、都回查得到 → 能删', () {
      final plan = planFor(
        [one('a'), one('b'), one('c')],
        {for (final id in ['a', 'b', 'c']) id: archived(id)},
        {
          for (final id in ['a', 'b', 'c']) id: {id: VerifyOutcome.ok},
        },
      );

      expect(plan.canDelete, isTrue);
      expect(plan.count, 3);
      expect(plan.deletable.length, 3);
      expect(plan.blocked, isEmpty);
      expect(plan.unarchivedCount, 0);
    });

    test('★ 里面有一条回查不到 → **整批一条都不删**', () {
      final plan = planFor(
        [one('a'), one('b')],
        {'a': archived('a'), 'b': archived('b')},
        {
          'a': {'a': VerifyOutcome.ok},
          'b': {'b': VerifyOutcome.missing},
        },
      );

      expect(plan.canDelete, isFalse);
      expect(plan.blocked.map((i) => i.session.sessionId), ['b']);
      // 可删的那条**照样算「可删」**，但 `canDelete` 不给过 ——
      // 卡的是整批，不是那一条。
      expect(plan.deletable.map((i) => i.session.sessionId), ['a']);
    });

    test('★ 里面有一条查不了（断网）→ 也整批不删', () {
      final plan = planFor(
        [one('a'), one('b')],
        {'a': archived('a'), 'b': archived('b')},
        {
          'a': {'a': VerifyOutcome.ok},
          'b': {
            'b': const VerifyOutcome(
              exists: false,
              couldNotVerify: true,
              reason: '电脑端没开',
            ),
          },
        },
      );

      expect(plan.canDelete, isFalse);
      expect(plan.blocked.single.plan.decision, DeleteDecision.refusedCouldNotVerify);
    });

    test('★ 里面有一条**没问过**（没回查）→ 当「查不了」，整批不删', () {
      // 少问一条就当「在」的话，删掉的可能是最后一份（I8）。
      final plan = planFor(
        [one('a'), one('b')],
        {'a': archived('a'), 'b': archived('b')},
        {
          'a': {'a': VerifyOutcome.ok},
          // 'b' 那一格压根没给
        },
      );

      expect(plan.canDelete, isFalse);
      expect(plan.blocked.single.plan.decision, DeleteDecision.refusedCouldNotVerify);
    });

    test('未备份的那些**不用回查**，可以直接删（但弹窗要说出「唯一一份」）', () {
      final plan = planFor(
        [one('a'), one('b')],
        {'a': archived('a'), 'b': pending('b')},
        {
          'a': {'a': VerifyOutcome.ok},
        },
      );

      expect(plan.canDelete, isTrue);
      expect(plan.unarchivedCount, 1);
      expect(batchDeletePreviewText(plan), contains('唯一一份'));
      expect(batchDeletePreviewText(plan), contains('1 条'));
    });

    test('空选不是「删 0 条」，是不给删', () {
      expect(planFor(const [], const {}, const {}).canDelete, isFalse);
    });

    test('一条里面**有一段**没备份 → 那一条按未备份算', () {
      final plan = planFor(
        [session(['e1', 'e2'], sessionId: 'a')],
        {'e1': archived('e1'), 'e2': pending('e2')},
        const {},
      );

      expect(plan.unarchivedCount, 1);
      expect(plan.canDelete, isTrue);
    });

    test('占多少是按**每条的字节数之和**算的，编不出一个数来', () {
      final plan = planFor([one('a'), one('b')], const {}, const {});
      expect(plan.bytes, 2048, reason: '构造器里每条 1024');
    });
  });

  group('批量删除那个弹窗的措辞', () {
    test('★ 不能删时，**逐条**说清是哪一条、为什么', () {
      // ⚠️ 一句笼统的「有几条不能删」等于让用户自己去猜是哪几条 ——
      // 而他猜不出来，只能一条条试（踩坑 #13）。
      final plan = planBatchDelete(
        sessions: [
          RecordingSession(
            sessionId: 'a',
            waybill: WaybillNumber.parse('SF1000000001'),
            startedAt: now,
            duration: const Duration(minutes: 5),
            bytes: 0,
            segmentCount: 1,
            evidenceIds: const ['a'],
          ),
          RecordingSession(
            sessionId: 'b',
            waybill: WaybillNumber.parse('SF2000000002'),
            startedAt: now,
            duration: const Duration(minutes: 5),
            bytes: 0,
            segmentCount: 1,
            evidenceIds: const ['b'],
          ),
        ],
        records: {'a': archived('a'), 'b': archived('b')},
        verifyBySession: {
          'a': {'a': VerifyOutcome.ok},
          'b': {'b': VerifyOutcome.missing},
        },
      );

      final text = batchDeletePreviewText(plan);

      // 单号是**这一层**取的（用户认单号，不认会话 id）。
      expect(text, contains('SF2000000002'));
      expect(text, contains('归档层上找不到这一份'), reason: '不许把它笼统说成「不能删」');
      // 而且必须说清「一条都不会删」—— 否则用户以为删了一部分。
      expect(text, contains('一条都不会删'));
    });

    test('能删时，正文说清**删多少条、多大**，并点明「电脑端那份不动」', () {
      final plan = planBatchDelete(
        sessions: [
          RecordingSession(
            sessionId: 'a',
            waybill: WaybillNumber.parse('SF1000000001'),
            startedAt: now,
            duration: const Duration(minutes: 5),
            bytes: 3 * 1024 * 1024,
            segmentCount: 1,
            evidenceIds: const ['a'],
          ),
        ],
        records: {'a': archived('a')},
        verifyBySession: {
          'a': {'a': VerifyOutcome.ok},
        },
      );

      final text = batchDeletePreviewText(plan);

      expect(text, contains('这 1 条'));
      expect(text, contains('3 MB'));
      expect(text, contains('电脑端那份不动'), reason: '用户最怕的是「两边都没了」');
      expect(text, contains('删除后无法恢复'));
    });
  });
}
