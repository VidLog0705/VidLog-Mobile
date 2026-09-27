import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/cleanup_audit.dart';
import 'package:vidlog_mobile/recording/cleanup_executor.dart';
import 'package:vidlog_mobile/recording/lifecycle.dart';
import 'package:vidlog_mobile/recording/manual_delete.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';

/// 自动清理的**执行层**（规格 §3.5.4 / §3.5.5）。
///
/// 手机端一直缺这一层：设置能选、`planCleanup` 能算，**一个文件都不会删**。
///
/// 回查要联网（问电脑端在不在），所以它是**注入**的 —— 这一批用假回查 +
/// **真临时目录**把执行层验到底：「删了之后盘上真的没了」那半是真验的。
///
/// ⚠️ 有两条**不在这里**测，因为它们是复用来的、那些用例在别处：
/// - 「先写审计、再删文件」的顺序 → `manual_delete` 那一组
/// - 文件删不动时记 `failed` → 同上（这里只覆盖「索引没记路径」那条分支）
void main() {
  final now = DateTime(2026, 9, 27, 12);

  late Directory temp;
  late String root;
  late CleanupAuditLog audit;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('vidlog-cleanup-');
    root = temp.path;
    audit = CleanupAuditLog('$root/cleanup.jsonl');
  });

  tearDown(() {
    // 宽着接：清理失败不该让测试红（与其它测试文件同一个口径）。
    try {
      temp.deleteSync(recursive: true);
    } on Object catch (_) {
      // 删不掉就算了。
    }
  });

  RecordingEntry entry(String id) => RecordingEntry(
        evidenceId: id,
        sessionId: 'sess-$id',
        waybill: WaybillNumber.parse('SF1234567890'),
        startedAt: DateTime(2026, 9, 20),
        endedAt: DateTime(2026, 9, 20, 0, 5),
        duration: const Duration(minutes: 5),
        location: RelativePath.parse('2026/09/20/$id.mp4'),
        contentHash: ContentHash.parse('a' * 64),
        sourceDeviceId: 'dev-1',
      );

  /// 在盘上真造出那些文件，返回「evidenceId → 相对路径」。
  Map<String, String> makeFiles(List<String> ids) {
    final map = <String, String>{};

    for (final id in ids) {
      final relative = '2026/09/20/$id.mp4';
      final file = File('$root/$relative');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('x' * 16);
      map[id] = relative;
    }

    return map;
  }

  CleanupPlan planOf(List<String> ids) => CleanupPlan(
        [for (final id in ids) CleanupCandidate(entry(id), '超过保留期')],
        const [],
      );

  String auditText() =>
      File('$root/cleanup.jsonl').existsSync() ? File('$root/cleanup.jsonl').readAsStringSync() : '';

  group('回查通过才删（规格 §3.5.4 / I8）', () {
    test('回查说归档层上还在 ⇒ 删本机那一份，而且留下审计', () async {
      final locations = makeFiles(['e1']);

      final outcome = await runCleanup(
        plan: planOf(['e1']),
        locationByEvidenceId: locations,
        rootDirectory: root,
        audit: audit,
        now: now,
        verify: (id) async => VerifyOutcome.ok,
      );

      expect(outcome.deleted, ['e1']);
      expect(File('$root/2026/09/20/e1.mp4').existsSync(), isFalse,
          reason: '回查通过了，本机这份就该没了');

      // 规格 §3.5.5「禁止静默清理」：删了就得说得出为什么。
      expect(auditText(), contains('e1'));
      expect(auditText(), contains('deleted'));
    });

    test('★ 回查**查不了** ⇒ 一条都不删（I8）', () async {
      // ⚠️ 断网 / 电脑端没开时，把它当成「不在」的话，
      // 删掉的可能就是**最后一份**（I2）。
      final locations = makeFiles(['e1']);

      final outcome = await runCleanup(
        plan: planOf(['e1']),
        locationByEvidenceId: locations,
        rootDirectory: root,
        audit: audit,
        now: now,
        verify: (id) async =>
            const VerifyOutcome(exists: false, couldNotVerify: true, reason: '连不上电脑端'),
      );

      expect(outcome.deleted, isEmpty);
      expect(outcome.refused.single.evidenceId, 'e1');
      expect(outcome.refused.single.reason, contains('问不到电脑端'));

      // ★ 文件必须还在。
      expect(File('$root/2026/09/20/e1.mp4').existsSync(), isTrue);
    });

    test('回查说归档层上没了 ⇒ 不删，而且说法与「查不了」**不是同一句**', () async {
      // ⚠️ 两种都是不许删，但对用户是两句话：混成一句的话，
      // 用户会以为「电脑开着就能删了」，而其实可能是那份真没了。
      final locations = makeFiles(['e1']);

      final outcome = await runCleanup(
        plan: planOf(['e1']),
        locationByEvidenceId: locations,
        rootDirectory: root,
        audit: audit,
        now: now,
        verify: (id) async => VerifyOutcome.missing,
      );

      expect(outcome.deleted, isEmpty);
      expect(outcome.refused.single.reason, contains('唯一副本'));
      expect(outcome.refused.single.reason, isNot(contains('问不到电脑端')));
      expect(File('$root/2026/09/20/e1.mp4').existsSync(), isTrue);
    });

    test('逐条各自回查 —— 一条不许不拖垮后面那些', () async {
      final locations = makeFiles(['e1', 'e2']);

      final outcome = await runCleanup(
        plan: planOf(['e1', 'e2']),
        locationByEvidenceId: locations,
        rootDirectory: root,
        audit: audit,
        now: now,
        verify: (id) async => id == 'e1' ? VerifyOutcome.missing : VerifyOutcome.ok,
      );

      expect(outcome.deleted, ['e2']);
      expect(outcome.refused.single.evidenceId, 'e1');
      expect(File('$root/2026/09/20/e1.mp4').existsSync(), isTrue);
      expect(File('$root/2026/09/20/e2.mp4').existsSync(), isFalse);
    });
  });

  group('执行层只认 candidates', () {
    test('★ 该催上传的那些**一个都不碰**（规格 §3.5.2.1）', () async {
      // 「未备份那一列永不自动删」在判定层是**结构性**保证的
      // （它们落在 nudges 而不是 candidates）。这一条验执行层也照做 ——
      // 它**只**遍历 candidates，nudges 里那些连回查都不会发。
      final locations = makeFiles(['e1', 'e2']);
      var verifyCalls = <String>[];

      final plan = CleanupPlan(
        [CleanupCandidate(entry('e1'), '超过保留期')],
        const [],
        [NudgedEntry(entry('e2'), '还没备份成功，该催上传了')],
      );

      final outcome = await runCleanup(
        plan: plan,
        locationByEvidenceId: locations,
        rootDirectory: root,
        audit: audit,
        now: now,
        verify: (id) async {
          verifyCalls.add(id);
          return VerifyOutcome.ok;
        },
      );

      expect(outcome.deleted, ['e1']);
      expect(File('$root/2026/09/20/e2.mp4').existsSync(), isTrue,
          reason: '★ 未备份的那一条是唯一副本 —— 任何设置都不该删掉它');
      expect(verifyCalls, ['e1'], reason: 'nudges 里那些连回查都不该发');
    });

    test('没有候选时一次回查都不发', () async {
      var asked = 0;

      final outcome = await runCleanup(
        plan: const CleanupPlan([], []),
        locationByEvidenceId: const {},
        rootDirectory: root,
        audit: audit,
        now: now,
        verify: (id) async {
          asked++;
          return VerifyOutcome.ok;
        },
      );

      expect(asked, 0);
      expect(outcome.nothingDeleted, isTrue);
      expect(outcome.refused, isEmpty);
    });

    test('索引里没记相对路径 ⇒ 记 failed，不去猜路径', () async {
      // 老索引行可能没有 location。**猜**一个路径去删是最坏的做法
      // （猜错就是删了别人的东西）。
      final outcome = await runCleanup(
        plan: planOf(['e1']),
        locationByEvidenceId: const {}, // 没有位置
        rootDirectory: root,
        audit: audit,
        now: now,
        verify: (id) async => VerifyOutcome.ok,
      );

      expect(outcome.deleted, isEmpty);
      expect(outcome.failed.single.evidenceId, 'e1');
      expect(auditText(), contains('没有这一段的相对路径'));
    });
  });

  group('预告文案（规格 §3.5.5「禁止静默清理」）', () {
    // ⚠️ 这一组存在的理由：文案写在界面里就等于**没有测试** ——
    // `recorder_page.dart` 在 widget 测试里碰不到（`_sessions` 恒空）。
    test('说清「多少段」与「多少容量」', () {
      final text = cleanupPreviewText(planOf(['e1', 'e2']));

      expect(text, contains('2 段'));
      expect(text, contains('MB'));
      // 「删的是哪一份」也要说 —— 不说的话用户会以为电脑上那份也没了。
      expect(text, contains('电脑上那份不动'));
    });

    test('★ 未备份的那些要**另说一句**，而且点明「永不自动删」', () {
      // 规格 §3.5.2.1：未备份那一列**只催不删**。混在一起说的话，
      // 用户会以为下面这些也要被删掉 —— 而他手里那是唯一一份。
      final plan = CleanupPlan(
        [CleanupCandidate(entry('e1'), '超过保留期')],
        const [],
        [NudgedEntry(entry('e2'), '还没备份成功，该催上传了')],
      );

      final text = cleanupPreviewText(plan);

      expect(text, contains('1 段还没备份成功'));
      expect(text, contains('永不自动删'));
    });
  });
}
