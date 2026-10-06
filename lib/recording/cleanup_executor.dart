/// 自动清理的**执行层**（规格 §3.5.4 / §3.5.5）。
///
/// 手机端一直缺的就是这一层：设置能选、`planCleanup` 能算，但**一个文件都不会删**
/// （`lifecycle.dart` 末尾那段说明写着「故意还没写」）。2026-09-27 补上。
///
/// ⚠️ 那段说明里「要等 M6 的归档层客户端」这个理由**已经不成立**了 ——
/// 手动删除（§3.5.6）做完之后，手机端已经有回查那条路（`/api/v1/archive/verify`）。
///
/// ## 它与手动删除（`manual_delete.dart`）的关系
///
/// 两者**共用同一批原语**，刻意不各写一份：
///
/// | 原语 | 在哪 |
/// |---|---|
/// | 回查的三态（在 / 不在 / **查不了**） | `VerifyOutcome` |
/// | **先写审计、再删文件**的顺序 | `deleteSessionFiles` |
/// | 「查不了 ⇒ 不许删」 | 本文件与 `planManualDelete` 各判一次，判据同一个 |
///
/// 差别只在**谁发起**：手动是用户点的那一条；这里是**判定层挑出来的候选**。
///
/// ## 三条不能忘的约束
///
/// 1. **未备份的那些永远不会出现在候选里**（`lifecycle.dart` 是**结构性**保证的：
///    它们落在 `nudges` 而不是 `candidates`）。所以这一层根本不需要为「未备份」
///    写分支 —— 写了反而会让人以为它有可能被删。
/// 2. **删之前必须逐条回查**（§3.5.4）；**查不到或查不了 ⇒ 不删**（I8）。
///    回查的对象是**归档层**，也就是**要联网**的 —— 所以这一层把回查做成**注入**的
///    函数，纯逻辑照样能在本机测到底。
/// 3. **禁止静默清理**（§3.5.5）：所以这一层与调用方是**两步** ——
///    调用方先拿 `planCleanup` 的产出给用户看（条数 + 容量），用户点了才调这里。
library;

import 'cleanup_audit.dart';
import 'lifecycle.dart';
import 'manual_delete.dart';

/// 一次自动清理跑下来的结果。
class CleanupOutcome {
  const CleanupOutcome({
    required this.deleted,
    required this.refused,
    required this.failed,
  });

  /// 真删掉的 `evidenceId`。
  final List<String> deleted;

  /// **回查没通过、因此保留**的那些（附原因）。
  ///
  /// ⚠️ 它**不是**「出错了」：这是 I8 在正常工作。界面上要说清
  /// 「这几条因为归档层上查不到（或查不了）而**没有删**」——
  /// 不说的话用户会以为漏清了。
  final List<RefusedCleanup> refused;

  /// 回查通过了、但**文件删失败**的那些（被占用、权限不对）。
  final List<RefusedCleanup> failed;

  /// 一条都没删成。
  bool get nothingDeleted => deleted.isEmpty;
}

/// 一条没能删掉的（附原因）。
class RefusedCleanup {
  const RefusedCleanup(this.evidenceId, this.reason);

  final String evidenceId;
  final String reason;
}

/// 回查一条录像在归档层上还在不在。
///
/// ⚠️ **注入**而不是在这里直接发请求：这一层要能在本机用假回查测到底，
/// 而真那条路（问电脑端）已经在手动删除那边铺好了 —— 复用同一个调用。
typedef ArchiveVerify = Future<VerifyOutcome> Function(String evidenceId);

/// 给用户看的预告文案（规格 §3.5.5「禁止静默清理」）。
///
/// 规格原话：清理前必须给出预告（**将删除多少条、多少容量**）。
///
/// ⚠️ **放在这里而不是界面里**，因为它有明确的措辞要求，而界面那一层
/// （`recorder_page.dart`）在 widget 测试里是**碰不到**的
/// （`_sessions` 恒空，见 `docs/真机验收清单.md` §1.19）——
/// 措辞写在界面里就等于没有测试。
///
/// ⚠️ 顺带把**未备份那一列**说清楚（§3.5.2.1）：那句「N 个未备份」是
/// **只催不删**的意思，不说明的话用户会以为它也要被删掉。
String cleanupPreviewText(CleanupPlan plan) {
  final megabytes = plan.totalBytes / 1024 / 1024;
  final lines = <String>[
    '保留期到了的录像有 ${plan.candidates.length} 段，约 ${megabytes.toStringAsFixed(0)} MB。',
    '',
    '要现在清理吗？',
    '· 清理前会逐条问电脑端，归档层上没有（或问不到）的那条不会删；',
    '· 删掉的是手机上这一份，电脑上那份不动；',
    '· 已锁定与最近 24 小时内录的一条都不会动。',
  ];

  if (plan.nudges.isNotEmpty) {
    // ⚠️ 「催上传」与「要删」必须分开说 —— 混在一起用户会以为下面这些也要被删。
    lines.add('· 另有 ${plan.nudges.length} 段还没备份成功，它们只在列表里标红催上传，永不自动删。');
  }

  return lines.join('\n');
}

/// 真去清一遍。
///
/// ⚠️ **调用方必须先把计划给用户看过**（规格 §3.5.5「禁止静默清理」）。
/// 这个函数不检查那件事 —— 它检查不了；那是调用方的责任，写在界面上。
///
/// 逐条走：**回查 → 通过才删**。删那一步复用 `deleteSessionFiles`，
/// 因为「先审计再删」那个顺序只该有一处实现（§3.5.5「禁止静默清理」）。
Future<CleanupOutcome> runCleanup({
  required CleanupPlan plan,
  required Map<String, String> locationByEvidenceId,
  required String rootDirectory,
  required CleanupAuditLog audit,
  required DateTime now,
  required ArchiveVerify verify,
}) async {
  final deleted = <String>[];
  final refused = <RefusedCleanup>[];
  final failed = <RefusedCleanup>[];

  for (final candidate in plan.candidates) {
    final evidenceId = candidate.entry.evidenceId;

    final outcome = await verify(evidenceId);

    if (outcome.couldNotVerify) {
      // ⚠️ **查不了**与「不在」都是不删，但对用户是两句话 —— 分别记，
      // 免得界面上把「电脑端没开」说成「归档层上那份没了」。
      refused.add(RefusedCleanup(
        evidenceId,
        '现在问不到电脑端（${outcome.reason ?? '原因未知'}），这一条没删',
      ));
      continue;
    }

    if (!outcome.exists) {
      refused.add(RefusedCleanup(
        evidenceId,
        '归档层上找不到这一份了，它现在是唯一副本，所以没删',
      ));
      continue;
    }

    // 回查通过 ⇒ 删。**复用**手动删除那条链：它已经保证了
    // 「先写审计、再删文件，删不动记 failed 并继续」。
    final removed = await deleteSessionFiles(
      plan: DeletePlan(
        DeleteDecision.confirmArchived,
        // ⚠️ `why` 是判定层给的理由（「为什么够格」），直接透传给审计 ——
        // 规格 §3.5.5 要求用户查得到「这条为什么被删了」。
        candidate.why,
        [evidenceId],
      ),
      locationByEvidenceId: locationByEvidenceId,
      rootDirectory: rootDirectory,
      audit: audit,
      now: now,
    );

    if (removed.isEmpty) {
      failed.add(RefusedCleanup(evidenceId, '文件删不掉（可能正被占用）'));
    } else {
      deleted.addAll(removed);
    }
  }

  return CleanupOutcome(deleted: deleted, refused: refused, failed: failed);
}
