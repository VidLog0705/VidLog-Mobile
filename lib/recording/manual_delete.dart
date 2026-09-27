/// 手动删除：用户自己删一条录像（规格 §3.5.6）。
///
/// 规格里原本**没有**这个能力（只有按策略的自动清理）。它是**用户主动发起**的，
/// 所以规则与自动清理**部分不同** —— 最要紧的两条：
///
/// 1. **删之前必须回查归档层**（③）。不能只看本地那条「已备份」的记录：
///    用户可能已经把归档层上那份删掉了。**回查查不到（或查不了）⇒ 不许删。**
/// 2. **弹窗按「这条备份了没有」分两种**（②），而且**不许合并**——
///    未备份那条的措辞必须说出「**这是唯一一份**」：
///    「删除后无法恢复」对一条已备份的录像是「本机这份没了」，
///    对一条未备份的是「**证据永久没了**」。这两句话对用户不是一回事。
///
/// 这个文件只做**判定**，不碰文件系统 —— 于是它能在本机用假数据验到底。
library;

import 'dart:io';

import '../upload/archive_store.dart';
import 'cleanup_audit.dart';
import 'recording_totals.dart';

/// 用户点了删除之后，这一条到底能不能删、弹窗该长什么样。
enum DeleteDecision {
  /// 已备份，而且回查确认归档层上还有 —— 弹「确认 / 取消」两选一。
  confirmArchived,

  /// 未备份 —— 弹「重新上传 / 确认删除 / 取消删除」三选一。
  ///
  /// ⚠️ **未备份的也允许删**（需求方 2026-07-?? 追问后裁决的）——
  /// 但措辞必须说出「这是唯一一份」。
  confirmUnarchived,

  /// ⚠️ **不许删**：回查说归档层上找不到这一份了。
  ///
  /// 规格 §3.5.6③ 原话：「并告诉他『归档层上找不到这一份了，这条现在是唯一副本』」。
  refusedMissingCopy,

  /// ⚠️ **不许删**：回查**查不了**（断网、电脑端没开）。
  ///
  /// ⚠️ 它与 [refusedMissingCopy] **都是不许删**，但对用户是两句话 ——
  /// 混成一句的话，用户会以为「电脑开着就能删了」，而其实可能是那份真没了。
  /// 把「查不了」当成「不存在」，删掉的可能就是最后一份（I2）。
  refusedCouldNotVerify,

  /// 这条在归档层上有（也可能没有），而且**回查本身没必要做**的情况不存在 ——
  /// 保留这个值只为让 switch 穷尽，不参与任何判定。
  notApplicable,
}

/// 一次手动删除的判定结果。
class DeletePlan {
  const DeletePlan(this.decision, this.reason, this.evidenceIds);

  final DeleteDecision decision;

  /// 给用户看的那句话（弹窗正文或拒绝的原因）。
  final String reason;

  /// 真要删的话，删这些 `evidenceId` 对应的分段文件。
  ///
  /// ⚠️ **一次录制可能有多个分段**（索引按分段记），所以删的是**一组**文件 ——
  /// 只删第一个的话，用户看到「这条没了」而盘上还占着地方，
  /// 而且剩下的分段还会出现在列表里（归并规则把它们**又合成一条**）。
  final List<String> evidenceIds;

  /// 要不要弹三选一的那个窗（未备份那条）。
  bool get needsUploadChoice => decision == DeleteDecision.confirmUnarchived;

  /// 能不能删。**只有两种 confirm 能删** —— 拒绝那两种一律 false。
  bool get deletionAllowed =>
      decision == DeleteDecision.confirmArchived ||
      decision == DeleteDecision.confirmUnarchived;
}

/// 一次回查的结果（由调用方从归档层问来）。
class VerifyOutcome {
  const VerifyOutcome({required this.exists, required this.couldNotVerify, this.reason});

  /// 归档层上还有这一份。
  final bool exists;

  /// **查不了**（断网、电脑端没开、路径不合规）。
  final bool couldNotVerify;

  final String? reason;

  static const missing = VerifyOutcome(exists: false, couldNotVerify: false);
  static const ok = VerifyOutcome(exists: true, couldNotVerify: false);
}

/// 判定这一条能不能删。
///
/// [records] 是这条录像各分段在 `archive.jsonl` 里的记录；
/// [verify] 是**逐段回查归档层**的结果（`evidenceId → 结果`）。
/// 未备份的那些不需要回查（没有那份可查）。
DeletePlan planManualDelete({
  required RecordingSession session,
  required Map<String, ArchiveRecord> records,
  required Map<String, VerifyOutcome> verify,
}) {
  final archived = session.evidenceIds.every((id) {
    final record = records[id];
    return record != null && record.isArchived;
  });

  if (!archived) {
    return DeletePlan(
      DeleteDecision.confirmUnarchived,
      '这条还没备份到电脑端，它是唯一一份，删了就无法恢复。',
      List.of(session.evidenceIds),
    );
  }

  // 已备份 ⇒ **逐段回查**（规格 §3.5.6③）。
  for (final id in session.evidenceIds) {
    final outcome = verify[id];

    if (outcome == null) {
      // 没问过就当「查不了」—— 绝不把它当成「在」。
      return DeletePlan(
        DeleteDecision.refusedCouldNotVerify,
        '还没能跟电脑端核对这一份在不在。现在不能删 —— 万一电脑上那份也没了，'
            '删掉的就是最后一份了。等电脑端开着、网络通着再试。',
        const [],
      );
    }

    if (outcome.couldNotVerify) {
      return DeletePlan(
        DeleteDecision.refusedCouldNotVerify,
        '现在问不到电脑端（${outcome.reason ?? '原因未知'}）。这条先不能删 —— '
            '查不了的时候当成「不在」，删掉的可能就是最后一份。',
        const [],
      );
    }

    if (!outcome.exists) {
      return DeletePlan(
        DeleteDecision.refusedMissingCopy,
        '归档层上找不到这一份了，这条现在是唯一副本 —— 不能删。',
        const [],
      );
    }
  }

  return DeletePlan(
    DeleteDecision.confirmArchived,
    '删除后无法恢复，是否确认要删除？',
    List.of(session.evidenceIds),
  );
}

// ─────────────────────────────────────────────
// 批量删除 —— 备份页那个【管理】的后半（需求方 2026-09-27）
// ─────────────────────────────────────────────

/// 批量里的一条：这一条录像 + 它的判定。
class BatchItem {
  const BatchItem(this.session, this.plan);

  final RecordingSession session;
  final DeletePlan plan;
}

/// 一次批量删除的判定。
///
/// ## ⚠️ 规则：**只要有一条不能删，整批一条都不删**
///
/// 这是刻意的，也是这一批里最要紧的一条。两个理由：
///
/// 1. 「查不了 ⇒ 不许删」是**逐条**算的（§3.5.6③），但批量下「删了 7 条、
///    跳掉 3 条」这个结果用户很难核对 —— 他记住的是「我删了 10 条」，
///    而留在盘上那几条会变成他以为早就没了的东西。
/// 2. 与保留期那条既有取舍**同向**：朝少删的那头落
///    （`retention_setting` 的非法值回落「全部保留」是同一个方向）。
///
/// 所以界面上不该出现「部分删除」：要删就一次删干净，删不成一条都不动。
class BatchDeletePlan {
  const BatchDeletePlan(this.items);

  /// 每一条的判定，顺序与调用方传进来的一致。
  final List<BatchItem> items;

  /// 判定为可删的那些。
  List<BatchItem> get deletable =>
      [for (final item in items) if (item.plan.deletionAllowed) item];

  /// 判定为不能删的那些 —— **非空就整批不删**。
  List<BatchItem> get blocked =>
      [for (final item in items) if (!item.plan.deletionAllowed) item];

  /// 现在能不能删。**空选也不行** —— 没有「删 0 条」这种事。
  bool get canDelete => items.isNotEmpty && blocked.isEmpty;

  int get count => items.length;

  /// 里面有几条**还没备份**。弹窗必须把这件事说出来：
  /// 那几条在手机上的这份是**唯一一份**。
  int get unarchivedCount =>
      [for (final item in items) if (item.plan.needsUploadChoice) item].length;

  /// 这一批在手机上占多少（盘上真实大小之和）。
  int get bytes => items.fold(0, (sum, item) => sum + item.session.bytes);
}

/// 判定一批能不能删。
///
/// [verifyBySession] 是**逐段回查归档层**的结果，按 `sessionId` 分。
/// 未备份的那些不需要回查（没有那份可查）。**没问过的当「查不了」** ——
/// 那条判据落在 [planManualDelete] 里，这里不重复判，也不该判。
BatchDeletePlan planBatchDelete({
  required List<RecordingSession> sessions,
  required Map<String, ArchiveRecord> records,
  required Map<String, Map<String, VerifyOutcome>> verifyBySession,
}) {
  return BatchDeletePlan([
    for (final session in sessions)
      BatchItem(
        session,
        planManualDelete(
          session: session,
          records: records,
          verify: verifyBySession[session.sessionId] ?? const {},
        ),
      ),
  ]);
}

/// 批量删除那个弹窗的正文。
///
/// ⚠️ **放在这一层是为了能测**（与 `cleanupPreviewText` 同一个理由）：
/// 措辞是安全的一部分 —— 它决定用户知不知道自己在删什么。
/// 界面那一层在 widget 测试里碰不到（`_sessions` 恒空）。
String batchDeletePreviewText(BatchDeletePlan plan) {
  if (!plan.canDelete) {
    if (plan.count == 1) {
      return '这一条现在不能删。\n\n${plan.blocked.single.plan.reason}';
    }

    final lines = [
      for (final item in plan.blocked)
        '· ${_waybillOf(item.session)}：${item.plan.reason}',
    ];

    return '选中的 ${plan.count} 条里有 ${plan.blocked.length} 条现在不能删，'
        '所以这一批**一条都不会删**。\n\n${lines.join('\n')}';
  }

  final buffer = StringBuffer()
    ..write('要删掉这 ${plan.count} 条录像在**手机上的**副本'
        '（共 ${_megabytes(plan.bytes)}）。电脑端那份不动。');

  if (plan.unarchivedCount > 0) {
    // ⚠️ 这一句不能省：那几条删了就真没了（§3.5.6 的措辞要求，
    // 单条那条路上也是这么说的）。
    buffer
      ..write('\n\n')
      ..write('⚠️ 其中 ${plan.unarchivedCount} 条**还没备份**，'
          '手机上这份是唯一一份，删了就无法恢复。');
  }

  buffer.write('\n\n删除后无法恢复，是否确认？');
  return buffer.toString();
}

/// 界面上认得出是哪一条用的。单号为空时退回会话 id ——
/// 与列表上「单号为空就显示会话 id」同一个口径。
String _waybillOf(RecordingSession session) =>
    session.waybill.value.isEmpty ? session.sessionId : session.waybill.value;

/// 容量按 MB 说。**与 `cleanupPreviewText` 同一个口径** ——
/// 两处弹窗说的是同一件事（要删多少、多大），一个说 MB 一个说 GB 会让人
/// 以为是两种不同的量。
String _megabytes(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';

/// 真去删一条录像的本地副本。**归档层那份不动**（规格 §3.5.6①）。
///
/// ⚠️ 顺序是刻意的：**先写审计，再删文件**。
/// 反过来的话，删到一半断电就成了一条「没了、却没有任何记录」的录像 ——
/// 而那正是规格 §3.5.5「禁止静默清理」要防的事。
/// 审计写不进去 ⇒ 抛 ⇒ **这一条不删**（宁可少删一条，也不能说不出为什么）。
///
/// 返回真删掉的 `evidenceId`。删不动的（文件被占、权限不对）记 `failed`
/// 并继续删下一个 —— 一条删不掉不该让整批停下。
Future<List<String>> deleteSessionFiles({
  required DeletePlan plan,
  required Map<String, String> locationByEvidenceId,
  required String rootDirectory,
  required CleanupAuditLog audit,
  required DateTime now,
}) async {
  final deleted = <String>[];

  for (final evidenceId in plan.evidenceIds) {
    // 先落审计 —— 见上面那段说明。
    await audit.append(CleanupAuditRecord(
      evidenceId: evidenceId,
      action: CleanupAction.deleted,
      reason: plan.reason,
      at: now,
    ));

    final location = locationByEvidenceId[evidenceId];
    if (location == null || location.isEmpty) {
      // 索引里没记位置（老行）—— 记一条 failed，不去猜路径。
      await audit.append(CleanupAuditRecord(
        evidenceId: evidenceId,
        action: CleanupAction.failed,
        reason: plan.reason,
        failureReason: '索引里没有这一段的相对路径',
        at: now,
      ));
      continue;
    }

    try {
      final file = File('$rootDirectory/$location');
      if (await file.exists()) {
        await file.delete();
      }

      deleted.add(evidenceId);
    } on Object catch (error) {
      await audit.append(CleanupAuditRecord(
        evidenceId: evidenceId,
        action: CleanupAction.failed,
        reason: plan.reason,
        failureReason: '$error',
        at: now,
      ));
    }
  }

  return deleted;
}
