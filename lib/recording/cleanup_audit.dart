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
    this.atRaw,
  });

  final String evidenceId;

  /// [CleanupAction] 里的一个。
  final String action;

  /// 为什么删 / 为什么没删（给用户看的那句话）。
  final String reason;

  /// 出错时的细节（`failed` 才有）。
  final String? failureReason;

  final DateTime at;

  /// 从盘上读回来时 `At` **读不动**的**原串**（读得动就是 null）。
  ///
  /// ⚠️ 有它是因为下面那个兜底：读不动时 [at] 会落在 **epoch**（1970-01-01），
  /// 而那个时刻是**编出来的** —— 印在流水上就是一句假话。留着原串，
  /// 界面上就能照电脑端那条规矩「原样印出来」（见 `CleanupLogView.describeAt`）。
  /// 自己新写的记录（走 [toJson] 那条路）恒为 null。
  final String? atRaw;

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

    final raw = json['At'] as String? ?? '';
    final at = DateTime.tryParse(raw);

    return CleanupAuditRecord(
      evidenceId: evidenceId,
      action: action,
      reason: reason,
      failureReason: json['FailureReason'] as String?,
      at: at?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
      atRaw: at == null ? raw : null,
    );
  }
}

/// 一次读盘的结果：记录 + **读不动的行数**。
///
/// ⚠️ 有那一格是因为禁止静默清理的另一面：这份流水是「这条录像什么时候没的、
/// 为什么没的」的**唯一凭据**，而读不动的行原先是被**悄悄跳过**的
/// （见下面 [CleanupAuditLog.loadAll] 的说明）—— 界面照样显示得干干净净，
/// 用户不会知道有东西没摆上来。与电脑端 `CleanupAuditPage` 同一件事。
class CleanupAuditPage {
  const CleanupAuditPage(this.records, this.unreadableLines);

  final List<CleanupAuditRecord> records;

  /// 有几行没能读成一条记录（写了一半、内容坏了）。
  final int unreadableLines;
}

/// 按行追加的审计流水。
///
/// ⚠️ **与索引、打点、标签同一个形态**（JSON Lines、追加写、坏行跳过）——
/// 理由也一样：追加写不重写既有记录，所以不存在「重写过程中崩溃导致整份流水损坏」
/// 这个失败模式（规格 §6.2「数据删除必须极度克制」）。
class CleanupAuditLog {
  CleanupAuditLog(this.path);

  /// 录像根目录下那一份 —— 录制、清理、删除、以及看流水的那一页都从此处取。
  ///
  /// ⚠️ **文件名只写这一遍**。此前 `'$root/cleanup-audit.jsonl'` 在
  /// `recorder_records_ops.dart` 里抄了三遍，T24 的流水页还要用第四次 ——
  /// 那时只要有一处拼错，用户看到的就是「清完了、流水上是空的」
  /// （而那本账存在的意义正是「这条什么时候没的」）。
  CleanupAuditLog.inRoot(String rootPath) : this('$rootPath/cleanup-audit.jsonl');

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

  /// 读流水，**连读不动的行数一起**（T24）。界面走这一支。
  Future<CleanupAuditPage> loadPage() async {
    final file = File(path);
    if (!await file.exists()) return const CleanupAuditPage([], 0);

    final records = <CleanupAuditRecord>[];
    var unreadable = 0;

    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;

      try {
        final record = CleanupAuditRecord.tryFromJson(
            jsonDecode(line) as Map<String, Object?>);

        // 认不出来的行跳过 —— 不让一行坏数据毁掉整份流水。
        if (record == null) {
          unreadable++;
        } else {
          records.add(record);
        }
      } on Object {
        unreadable++;
      }
    }

    return CleanupAuditPage(records, unreadable);
  }

  /// 老入口：只要记录。
  ///
  /// ⚠️ 行为**一个字没变**（半截的一行照样跳过，不能因为一行坏了就丢掉整份审计）
  /// —— 变的是它现在说得出自己跳了几行，而那件事由 [loadPage] 说。
  Future<List<CleanupAuditRecord>> loadAll() async =>
      (await loadPage()).records;
}
