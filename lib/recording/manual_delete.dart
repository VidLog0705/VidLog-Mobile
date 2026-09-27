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
