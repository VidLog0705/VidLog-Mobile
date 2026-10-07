/// 把清理审计那本账翻成界面能直接画的几行（T24）。
///
/// 规格 §6.2 那句「禁止静默清理」是**两半**：清理前必须预告（那半早就做完了），
/// **且保留可查的清理记录**（这半）。审计从写下第一行起就落在
/// `<root>/cleanup-audit.jsonl` 里，而**一直没人能看** —— 文件在手机的
/// 应用目录底下，现场没有人会去翻它，于是「这条录像什么时候没的、为什么没的」
/// 仍然是答不上来的。
///
/// ⚠️ **翻账的逻辑放这儿、不放页面里**：这一端没有 App 层的测试工程，
/// 而格式恰恰是**会错的那种代码** —— 时间格式、动作码翻人话、单号查不到时的
/// 兜底，每一样写错了界面上都只是「看着有点怪」，不会有任何东西喊。
/// 与电脑端 `VidLog.Desktop.Core/Cleanup/CleanupLogView.cs` 同一个路数，
/// **文案逐字一致** —— 两端看的是同一份流水、说的是同一件事。
library;

import 'cleanup_audit.dart';
import 'recording_totals.dart';

/// 清理流水上的一行。
class CleanupLogRow {
  const CleanupLogRow({
    required this.atText,
    required this.waybillText,
    required this.action,
    required this.actionText,
    required this.reasonText,
    required this.evidenceId,
  });

  /// 什么时候。
  final String atText;

  /// 哪一条 —— 单号；查不到时见 [CleanupLogView.noWaybillText]。
  final String waybillText;

  /// 审计里的原值（`deleted` / `refused` / …）。界面拿它挑那个小标的颜色
  /// （`cleanupActionLook`）—— **`actionText` 是给人看的，判色不能靠它**。
  final String action;

  /// 干了什么（人话，见 [CleanupLogView.describeAction]）。
  final String actionText;

  /// 为什么。
  final String reasonText;

  /// 审计里的原值（哪一份录像）。
  final String evidenceId;
}

abstract final class CleanupLogView {
  /// 单号查不到时那一格写什么。
  ///
  /// ⚠️ 逐字与电脑端 `CleanupLogView.NoWaybillText` 一致 —— 两处写两个词的话，
  /// 同一件事在电脑上和手机上会是两个说法。
  static const noWaybillText = '（无单号）';

  /// 一条流水都没有时显示什么。
  static const emptyText =
      '还没有清理记录。清过哪一条、为什么清、哪几条按 I8 保留，都会记在这里。';

  /// 审计文件里那些读不动的行。
  static String describeUnreadable(int lines) =>
      '另有 $lines 行读不动（写了一半或内容坏了），它们不在上面的流水里。';

  /// 翻账。**最近的在上**（审计是追加写的，倒着走即可）。
  ///
  /// [sessions] 只用来把证据 id 换成用户认得的单号。
  static List<CleanupLogRow> build(
    List<CleanupAuditRecord> records,
    List<RecordingSession> sessions,
  ) {
    // ⚠️ 用 `[]=` 而不是 `addAll` 之类会抛的写法：这份对照表只是给界面看的，
    // 万一两条录像带着同一个 EvidenceId，**流水窗口整个打不开**比
    // 「单号显示得不够准」严重得多。
    final waybills = <String, String>{};
    for (final session in sessions) {
      for (final evidenceId in session.evidenceIds) {
        waybills[evidenceId] = waybillOf(session);
      }
    }

    final rows = <CleanupLogRow>[];

    for (var i = records.length - 1; i >= 0; i--) {
      final record = records[i];
      final waybill = waybills[record.evidenceId];

      rows.add(CleanupLogRow(
        atText: describeAt(record),
        // ⚠️ 只有「查不到」这一种 —— `waybillOf` 交出来的单号不可能为空
        // （它自己那一支兜底也删了，理由见那儿）。别在这儿再判一遍空串。
        waybillText: waybill ?? noWaybillText,
        action: record.action,
        actionText: describeAction(record.action),
        reasonText: describeReason(record),
        evidenceId: record.evidenceId,
      ));
    }

    return rows;
  }

  /// 把审计里的时刻写出来。
  ///
  /// 格式与电脑端**逐字一致**（`yyyy-MM-dd HH:mm:ss`）—— 两端看的是同一份文件，
  /// 同一行在两边印成两个样子只会让人以为那是两次不同的动作。
  /// （本机别的列表用的是 `MM-DD HH:mm`，那是在说「最近录的」，
  /// 归在这里不合适：审计里全是**旧**记录。）
  ///
  /// ⚠️ `At` 读不动时**原样印出来**：这是审计，宁可摆一串看不懂的东西，
  /// 也不能把这一行吃掉、更不能编一个时间 —— 那正是这本账存在的意义反面。
  /// 原串由 [CleanupAuditRecord.atRaw] 带着（那一格不是这儿能算出来的）。
  static String describeAt(CleanupAuditRecord record) {
    final raw = record.atRaw;
    if (raw != null) return raw;

    final at = record.at;
    return '${at.year.toString().padLeft(4, '0')}-'
        '${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
  }

  /// 动作码翻人话。
  ///
  /// ⚠️ 一次成功的清理在电脑端留**两条**（`deleting` + `deleted`），所以这里
  /// 刻意把它们翻成「准备清理」/「已清理」两个**看得出先后**的词，而不是都写成
  /// 「清理」—— 两行一模一样的话，用户会以为同一条删了两遍。
  /// ⚠️ 手机端自己目前只写 `deleted` / `refused` / `failed`，但**流水是两端共用
  /// 的同一份文件**（`cleanup-audit.jsonl`，同一套键名），所以 `deleting` 也得认。
  static String describeAction(String action) => switch (action) {
        'deleting' => '准备清理',
        'deleted' => '已清理',
        'refused' => '保留（没清）',
        'failed' => '清理失败',
        // ⚠️ 认不出的动作**原样印出来**。吞掉或者编一个中文，
        // 等于在这本「不能静默」的账上又静默了一次。
        _ => action,
      };

  /// 为什么。失败时把失败原因接在后面。
  static String describeReason(CleanupAuditRecord record) {
    final failure = record.failureReason;

    if (failure == null || failure.trim().isEmpty) {
      return record.reason;
    }

    return record.reason.trim().isEmpty ? failure : '${record.reason} —— $failure';
  }
}
