import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/palette.dart';
import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/cleanup_audit.dart';
import 'package:vidlog_mobile/recording/cleanup_log_view.dart';
import 'package:vidlog_mobile/recording/recording_totals.dart';

/// 清理流水那张表（T24）。
///
/// 这一层守的是**做错了用户也看不出来**的那几件事：时间格式、动作码翻人话、
/// 单号查不到时的兜底、读不动的行有没有被数出来。写错了界面上只是
/// 「看着有点怪」，不会有任何东西喊 —— 而规格 §6.2 要的正是
/// 「事后答得上来这条录像什么时候没的、为什么没的」。
///
/// 与电脑端 `CleanupLogViewTests` 同一个形状、同一批文案
/// （`cleanup-audit.jsonl` 是两端共用的同一份文件）。
void main() {
  CleanupAuditRecord record({
    String evidenceId = 'ev-1',
    String action = CleanupAction.deleted,
    String reason = '超过保留期',
    String? failureReason,
    DateTime? at,
    String? atRaw,
  }) =>
      CleanupAuditRecord(
        evidenceId: evidenceId,
        action: action,
        reason: reason,
        failureReason: failureReason,
        at: at ?? DateTime(2026, 10, 7, 12, 33, 4),
        atRaw: atRaw,
      );

  RecordingSession session({
    String sessionId = 'sess-1',
    String waybill = 'SF1000000001',
    List<String> evidenceIds = const ['ev-1'],
  }) =>
      RecordingSession(
        sessionId: sessionId,
        waybill: WaybillNumber.parse(waybill),
        startedAt: DateTime(2026, 10, 7, 10),
        duration: const Duration(minutes: 5),
        bytes: 1024,
        segmentCount: evidenceIds.length,
        evidenceIds: evidenceIds,
      );

  // ─────────────────────────────────────────────
  // 时间
  // ─────────────────────────────────────────────

  group('时间', () {
    test('★ 印成 年-月-日 时:分:秒，个位数补零', () {
      // ⚠️ 与电脑端 `yyyy-MM-dd HH:mm:ss` 逐字一致：两端看的是同一份文件，
      // 同一行印成两个样子会让人以为那是两次不同的动作。
      final row = CleanupLogView.build(
        [record(at: DateTime(2026, 1, 2, 3, 4, 5))],
        const [],
      ).single;

      expect(row.atText, '2026-01-02 03:04:05');
    });

    test('★ 时间读不动就原样印出来 —— 不许编也不许吞', () {
      // 反证：把 `describeAt` 里 `if (raw != null) return raw;` 那两行删掉，
      // 这一条立刻报 `1970-01-01 08:00:00` —— 那就是**编出来的一个时刻**，
      // 印在审计上是一句假话（`tryFromJson` 读不动时会落到 epoch）。
      final row = CleanupLogView.build(
        [
          record(
            at: DateTime.fromMillisecondsSinceEpoch(0),
            atRaw: '昨天下午',
          ),
        ],
        const [],
      ).single;

      expect(row.atText, '昨天下午');
    });
  });

  // ─────────────────────────────────────────────
  // 动作码
  // ─────────────────────────────────────────────

  group('动作码', () {
    test('★ 四个码都有人话', () {
      expect(CleanupLogView.describeAction('deleting'), '准备清理');
      expect(CleanupLogView.describeAction('deleted'), '已清理');
      expect(CleanupLogView.describeAction('refused'), '保留（没清）');
      expect(CleanupLogView.describeAction('failed'), '清理失败');
    });

    test('★ 准备清理与已清理不是同一句话', () {
      // 一次成功的清理在电脑端留**两条**（先写意图、再写结果）。都翻成「清理」
      // 的话，用户会以为同一条删了两遍。
      expect(
        CleanupLogView.describeAction('deleting'),
        isNot(CleanupLogView.describeAction('deleted')),
      );
    });

    test('★ 认不出的动作原样印出来 —— 不许吞', () {
      // 吞掉或者编一个中文，等于在这本「不能静默」的账上又静默了一次。
      expect(CleanupLogView.describeAction('someFutureCode'), 'someFutureCode');
    });
  });

  // ─────────────────────────────────────────────
  // 为什么
  // ─────────────────────────────────────────────

  group('为什么', () {
    test('★ 失败时把失败原因接在后面', () {
      final row = CleanupLogView.build(
        [record(action: 'failed', failureReason: '文件被占用')],
        const [],
      ).single;

      expect(row.reasonText, contains('超过保留期'));
      expect(row.reasonText, contains('文件被占用'));
    });

    test('没有失败原因时就只有原因', () {
      expect(CleanupLogView.build([record()], const []).single.reasonText,
          '超过保留期');
    });

    test('★ 只有失败原因时不许印出一个空的原因格', () {
      final row = CleanupLogView.build(
        [record(reason: '', action: 'failed', failureReason: '权限不对')],
        const [],
      ).single;

      expect(row.reasonText, '权限不对');
      expect(row.reasonText.startsWith(' —— '), isFalse);
    });
  });

  // ─────────────────────────────────────────────
  // 顺序与单号
  // ─────────────────────────────────────────────

  group('顺序与单号', () {
    test('★ 最近的排在最上面', () {
      final rows = CleanupLogView.build(
        [
          record(evidenceId: 'ev-old', at: DateTime(2026, 10, 1, 9)),
          record(evidenceId: 'ev-new', at: DateTime(2026, 10, 7, 9)),
        ],
        const [],
      );

      expect(rows.first.evidenceId, 'ev-new');
      expect(rows.last.evidenceId, 'ev-old');
    });

    test('★ 证据 id 换成用户认得的单号（一段录像多个分段都认）', () {
      final rows = CleanupLogView.build(
        [record(evidenceId: 'ev-2')],
        [session(waybill: 'SF1000000009', evidenceIds: ['ev-1', 'ev-2'])],
      );

      expect(rows.single.waybillText, 'SF1000000009');
    });

    // ⚠️ 「单号为空」在这儿**造不出来**，所以别指望有测试盖着：`waybillOf`
    // 交出来的是 `session.waybill.value`，而 `WaybillNumber` 的构造函数私有、
    // `parse` 空即抛 ⇒ 那个值永远非空（2026-10-07 已把原先三处「退回会话 id」
    // 的兜底删掉，理由与被删的检查见 `waybillOf`）。
    // 唯一还能到「（无单号）」的是**索引里查不到**这一条，见下一个用例。

    test('★ 索引里查不到那一份时写（无单号）', () {
      // 已经删掉的那些录像**正是流水存在的意义** —— 它们当然不在当前列表里。
      final rows = CleanupLogView.build([record(evidenceId: 'ev-gone')], const []);

      expect(rows.single.waybillText, '（无单号）');
    });

    test('★ 两条录像带着同一个证据 id 也不许把页面炸掉', () {
      // 用会抛的写法建对照表（`addAll` 之类）的话，这一页就**整个打不开**了
      // —— 比「单号显示得不够准」严重得多。
      final rows = CleanupLogView.build(
        [record(evidenceId: 'ev-1')],
        [
          session(sessionId: 'sess-a', waybill: 'SF1000000001', evidenceIds: ['ev-1']),
          session(sessionId: 'sess-b', waybill: 'SF1000000002', evidenceIds: ['ev-1']),
        ],
      );

      expect(rows.single.waybillText, isNotEmpty);
    });
  });

  // ─────────────────────────────────────────────
  // 坏行
  // ─────────────────────────────────────────────

  group('坏行', () {
    test('★ 读不动的行要被数出来 —— 而不是悄悄跳过', () async {
      final dir = await Directory.systemTemp.createTemp('vidlog-audit-');
      addTearDown(() => dir.delete(recursive: true));

      final audit = CleanupAuditLog.inRoot(dir.path);
      await audit.append(record());

      // 写一半就断电了的那一行。
      await File(audit.path).writeAsString(
        '{"EvidenceId":"ev-2","Act',
        mode: FileMode.append,
      );

      final page = await audit.loadPage();

      expect(page.records, hasLength(1));
      expect(page.unreadableLines, 1);

      // ⚠️ 老入口的行为一个字没变：半截的一行照样跳过，
      // 不能因为一行坏了就丢掉整份审计。
      expect(await audit.loadAll(), hasLength(1));

      expect(CleanupLogView.describeUnreadable(1), contains('1 行读不动'));
    });

    test('★ 流水文件还不存在时是一条空白流水', () async {
      final dir = await Directory.systemTemp.createTemp('vidlog-audit-');
      addTearDown(() => dir.delete(recursive: true));

      final page = await CleanupAuditLog.inRoot(dir.path).loadPage();

      expect(page.records, isEmpty);
      expect(page.unreadableLines, 0);
    });
  });

  // ─────────────────────────────────────────────
  // 验收：删一条 → 打开界面 → 看得见那条
  // ─────────────────────────────────────────────

  test('★ 删掉一条之后流水上看得见那一条', () async {
    final dir = await Directory.systemTemp.createTemp('vidlog-audit-');
    addTearDown(() => dir.delete(recursive: true));

    final audit = CleanupAuditLog.inRoot(dir.path);

    // ⚠️ 照电脑端真实的写入顺序：**先写意图、再写结果**。
    await audit.append(record(action: 'deleting', at: DateTime(2026, 10, 7, 9)));
    await audit.append(record(action: 'deleted', at: DateTime(2026, 10, 7, 9)));

    // 没清成的那条也要看得见 —— 「哪几条没清、为什么」与「清了什么」同样重要。
    await audit.append(record(
      evidenceId: 'ev-2',
      action: 'refused',
      reason: '归档层上找不到这一份，按 I8 不删',
      at: DateTime(2026, 10, 7, 10),
    ));

    final rows = CleanupLogView.build(
      (await audit.loadPage()).records,
      [session(evidenceIds: ['ev-1', 'ev-2'])],
    );

    expect(rows, hasLength(3));

    // 最新的一条（保留）在最上面。
    expect(rows[0].actionText, '保留（没清）');
    expect(rows[0].reasonText, contains('I8'));

    // 删掉的那条：意图与结果两条都在，且**看得出先后**。
    expect(rows[1].actionText, '已清理');
    expect(rows[2].actionText, '准备清理');
  });

  // ─────────────────────────────────────────────
  // 那个小标的颜色
  // ─────────────────────────────────────────────

  group('动作小标的颜色', () {
    test('★ 五种结局各有各的一对色', () {
      final pairs = [
        for (final action in ['deleted', 'refused', 'deleting', 'failed', '???'])
          cleanupActionLook(Palette.light, action),
      ];

      expect(pairs.map((p) => p.color).toSet(), hasLength(5));
    });

    test('★ 认不出的那支用的是正文灰，不是描边灰', () {
      // ⚠️ `Palette.faint` 是**描边色**（压 `hairline` 只有 3.08:1），
      // 拿它写字就掉到 4.5:1 以下 —— 而 `businessTypeLook` 里明写着同一条规矩。
      // 这条钉的就是「别照着那一支抄」。
      expect(cleanupActionLook(Palette.light, '???').color, Palette.light.muted);
      expect(
        cleanupActionLook(Palette.light, '???').color,
        isNot(Palette.light.faint),
      );
    });
  });
}
