/// 清理与删除的**审计流水**（规格 §3.5.5 / §3.5.6④）。
///
/// 规格原话：「必须保留清理记录，用户可查『这条为什么被删了』」，
/// 而手动删除「**与自动清理同一份流水**……事后要能回答『这条录像是什么时候没的、
/// 为什么没的』。用户自己删的，同样要答得上来。」
///
/// ## 与电脑端**同一个文件名、同一套键名**
///
/// `<root>/cleanup-audit.jsonl`，PascalCase（`EvidenceId` / `Action` / `Reason` /
/// `FailureReason` / `At`）—— 与电脑端
/// `VidLog.Desktop.Core/Cleanup/CleanupExecutor.cs` 的 `CleanupAuditRecord` 逐字一致。
/// 两端各写一套键名的话，把手机上的这份拿到电脑端打开会对不上，
/// 而那正是「出事时唯一有用的东西」。
library;

import 'dart:convert';
import 'dart:io';

/// 一次删除动作的结局。
///
/// 与电脑端同一套取值（`deleted` / `refused` / `failed`）。
class CleanupAction {
  /// 真删掉了。
  static const deleted = 'deleted';

  /// 回查不通过（查不到 / 查不了）—— **没删**。
  static const refused = 'refused';

  /// 删的过程中出错（文件被占用、权限）—— **可能没删干净**。
  static const failed = 'failed';
}

/// 流水里的一行。
class CleanupAuditRecord {
  const CleanupAuditRecord({
    required this.evidenceId,
    required this.action,
    required this.reason,
    this.failureReason,
    required this.at,
  });

  final String evidenceId;

  /// [CleanupAction] 里的一个。
  final String action;

  /// 为什么删 / 为什么没删（给用户看的那句话）。
  final String reason;

  /// 出错时的细节（`failed` 才有）。
  final String? failureReason;

  final DateTime at;

  Map<String, Object?> toJson() => {
        'EvidenceId': evidenceId,
        'Action': action,
        'Reason': reason,
        'FailureReason': failureReason,
        'At': at.toUtc().toIso8601String(),
      };

  static CleanupAuditRecord? tryFromJson(Map<String, Object?> json) {
    final evidenceId = json['EvidenceId'];
    final action = json['Action'];
    final reason = json['Reason'];

    if (evidenceId is! String || action is! String || reason is! String) {
      return null;
    }

    final at = DateTime.tryParse(json['At'] as String? ?? '');

    return CleanupAuditRecord(
      evidenceId: evidenceId,
      action: action,
      reason: reason,
      failureReason: json['FailureReason'] as String?,
      at: at?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 按行追加的审计流水。
///
/// ⚠️ **与索引、打点、标签同一个形态**（JSON Lines、追加写、坏行跳过）——
/// 理由也一样：追加写不重写既有记录，所以不存在「重写过程中崩溃导致整份流水损坏」
/// 这个失败模式（规格 §6.2「数据删除必须极度克制」）。
class CleanupAuditLog {
  CleanupAuditLog(this.path);

  final String path;

  /// 写一行。
  ///
  /// ⚠️ **写不进去要抛**：规格 §6.2 禁止静默清理，而没有记录就等于静默。
  /// 调用方（`deleteSession`）据此**中止这次删除** —— 宁可少删一条，
  /// 也不能出现「东西没了、却说不出为什么」。
  Future<void> append(CleanupAuditRecord record) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    // 追加写 + flush —— 与 `ArchiveStore.record` 逐字相同的理由：
    // 这不是缓存，是「这条录像什么时候没的、为什么没的」的唯一凭据。
    await file.writeAsString(
      '${jsonEncode(record.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<List<CleanupAuditRecord>> loadAll() async {
    final file = File(path);
    if (!await file.exists()) return const [];

    final records = <CleanupAuditRecord>[];

    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;

      try {
        final record = CleanupAuditRecord.tryFromJson(
            jsonDecode(line) as Map<String, Object?>);

        // 认不出来的行跳过 —— 不让一行坏数据毁掉整份流水。
        if (record != null) records.add(record);
      } on Object {
        continue;
      }
    }

    return records;
  }
}
