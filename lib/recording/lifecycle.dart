/// §3.5 生命周期判定 —— 哪些本地副本够格被清、哪些不能，以及**为什么**。
///
/// 与电脑端 `VidLog.Desktop.Core/Cleanup/CleanupPolicy.cs` 的 `CleanupPlanner`
/// 是**同一套口径**（三段豁免、两条保留期、起算点），两端各算各的那份本地副本。
///
/// ## ⚠️ 这里只**判定**，不删任何东西
///
/// 一个文件都不碰：给定「有哪些录像、备份成功没有、锁没锁、策略、现在几点」，
/// 算出该清谁、不该清谁。真正删除要先过 §3.5.4 的回查（回查不通过**绝不删**，
/// 那是 I8），而那件事**还没做** —— 见文件末「执行层为什么还不存在」。
///
/// 不碰文件系统也是它可测的原因：不需要临时目录、不需要 mock 掉 `dart:io`。
///
/// ## 三段豁免一条都不能少（规格 §3.5.3，硬性、用户关不掉）
///
/// 1. **未成功归档的** —— 它是唯一副本（I2）
/// 2. **被标记为争议并锁定的** —— 锁可以无限期压住保留期，这是有意的
/// 3. **最近 24 小时内录的** —— 刚录完的东西往往还在被检查、被导出
///
/// ## 起算点是**归档成功时刻**，不是录完时刻（规格 §3.5.2.1）
///
/// 依据是 §4.3 的合取式「归档成功 **且** 超过保留期」。要是从录完起算，
/// 一台离线 35 天的机器会在**刚归档那一瞬间**就被删掉 ——
/// 那等于绕开了「至少一份副本」（I2）的意图。
/// 所以这里用的是回执里的 `TimeAnchor`（外部时间锚，用户改不了），
/// **不是** `RecordingEntry.endedAt`。
library;

import '../upload/archive_store.dart';
import 'business_type.dart';
import 'recording_index.dart';
import 'recording_spec.dart';
import 'retention_setting.dart';

/// 最近这段时间内录的，一律不清（规格 §3.5.3③）。
///
/// 与电脑端 `CleanupPlanner.FreshWindow` 同一个值、同一个单位。
/// 它也是「不保留」实际等于「备份成功后最快 24 小时清」的原因 ——
/// 界面上必须把这句话写出来（见设置页那块卡片）。
const Duration freshWindow = Duration(hours: 24);

/// 一条够格被清的录像。
class CleanupCandidate {
  const CleanupCandidate(this.entry, this.why);

  final RecordingEntry entry;

  /// 为什么够格。规格 §3.5.5 要求用户能查「这条为什么被删了」。
  final String why;
}

/// 一条**不**清的录像，以及为什么。
///
/// 与 [CleanupCandidate] 成对：只给候选不给豁免，用户就无从质疑 ——
/// 他看不到「我锁了的那条还在不在计划里」。
class ExemptedEntry {
  const ExemptedEntry(this.entry, this.why);

  final RecordingEntry entry;
  final String why;
}

/// 一次清理计划的完整结论。
class CleanupPlan {
  const CleanupPlan(this.candidates, this.exempted);

  final List<CleanupCandidate> candidates;
  final List<ExemptedEntry> exempted;

  /// 这个计划会腾出多少 —— 规格 §3.5.5 的「清理前必须给出预告」要的就是它。
  ///
  /// 按码率推算，**不去 stat 文件**：那会有「算的过程中文件被别的东西删了」
  /// 这类竞态。真实大小在执行阶段复核 —— 那里本来就要读一次文件。
  int get totalBytes =>
      candidates.fold(0, (sum, c) => sum + estimateBytes(c.entry));
}

/// 这条录像的成品大约占多大。
///
/// ⚠️ **系数按这条录像自己的录制规格算**（2026-09-27 改，规格 §3.5.5 的连带项）。
/// 原先两端都写死一个 160 KB/s（H.264 640×480 时代的数），4K 下错得离谱 ——
/// 而电脑端「按空间清理」**正是用它决定删到够为止**，估错就是「删了还不够」。
/// 现在两端读的是**同一张表**（`RecordingSpec.bytesPerSecondOf`）。
///
/// 老索引行没有编码 / 分辨率两个字段（2026-09-27 才加），它们走默认档那一格
/// （H.264 1080P = 1100 KB/s）—— 比原来的 160 KB/s 大 6 倍多，但那才是真相：
/// 这台手机本来就在录 720P/1080P，而不是 640×480。
///
/// 时长为负时返回 0 而不是负数：那个值只喂给「将腾出多少」这句预告，
/// 而负的容量是句废话。电脑端那边也是这么钳的。
int estimateBytes(RecordingEntry entry) => entry.duration.isNegative
    ? 0
    : (entry.duration.inMilliseconds *
            RecordingSpec.bytesPerSecondOf(entry.codec, entry.resolution) /
            1000)
        .round();

/// 算一次清理计划（规格 §3.5.2.1 / §3.5.3 / §3.5.4）。
///
/// [entries] 是索引里的全部录像；[labels] 是 `evidenceId → 标签键 → 值`；
/// [archive] 是本机的归档状态表（`ArchiveStore.loadAll()` 的结果）。
///
/// 发货与退货**各算一遍再合起来** —— 分开算顺手保证了两份互不串
/// （改发货的档位不可能碰到退货的判断）。
CleanupPlan planCleanup({
  required List<RecordingEntry> entries,
  required Map<String, Map<String, String>> labels,
  required Map<String, ArchiveRecord> archive,
  required RetentionSetting retentionOutbound,
  required RetentionSetting retentionReturn,
  required DateTime now,
}) {
  final candidates = <CleanupCandidate>[];
  final exempted = <ExemptedEntry>[];

  // 按业务类型分组。**没有业务类型标签的一律不清**，见下面那条注释。
  final byType = <BusinessType?, List<RecordingEntry>>{};
  for (final entry in entries) {
    byType.putIfAbsent(_businessTypeOf(entry, labels), () => []).add(entry);
  }

  for (final group in byType.entries) {
    final type = group.key;

    if (type == null) {
      // 判不出它是发货还是退货，就说不出它该用哪一份保留期。
      // **猜错的代价是删掉证据，猜不出的代价只是占地方** ——
      // 而后者是看得见的（就在豁免列表里，用户查得到「这条为什么没删」）。
      exempted.addAll(group.value.map((e) =>
          ExemptedEntry(e, '没有业务类型标签，判不出该用哪一份保留期，按「全部保留」处理')));
      continue;
    }

    final setting =
        type == BusinessType.returning ? retentionReturn : retentionOutbound;

    // 策略是「全部保留」时，谁都别动。
    if (setting.days == null) {
      exempted.addAll(
          group.value.map((e) => ExemptedEntry(e, '保留策略是「全部保留」')));
      continue;
    }

    for (final entry in group.value) {
      final why = _exemptReason(entry, labels, archive, now);
      if (why != null) {
        exempted.add(ExemptedEntry(entry, why));
        continue;
      }

      // 走到这儿说明它在归档层上有一份、没被锁、也过了 24 小时。
      final anchor = archive[entry.evidenceId]!.timeAnchor!;
      final days = setting.days!;
      if (anchor.isBefore(now.subtract(Duration(days: days)))) {
        candidates.add(CleanupCandidate(
            entry, '备份于 ${_stamp(anchor)}，超过 $days 天'));
      } else {
        exempted.add(ExemptedEntry(entry, '还在 $days 天保留期内'));
      }
    }
  }

  return CleanupPlan(candidates, exempted);
}

/// 三段硬豁免，按规格 §3.5.3 **自己的编号顺序**判 —— 一条都不少。
///
/// 返回 `null` 表示三段都没拦住它。返回的文字是给用户看的，
/// 所以要说得具体（「录完还不到 24 小时」比「未到期」有用）。
String? _exemptReason(
  RecordingEntry entry,
  Map<String, Map<String, String>> labels,
  Map<String, ArchiveRecord> archive,
  DateTime now,
) {
  // ① 未成功归档的 —— 唯一副本（I2）。
  final record = archive[entry.evidenceId];
  if (record == null || !record.isArchived) {
    return '还没成功备份到电脑端，这是唯一副本';
  }

  // 拿到了回执但里面没有时间锚：**算不出起算点，就不清**。
  // 朝着少删的那头落 —— 与 `RetentionSetting.fromConfig` 解析失败回落
  // 「全部保留」、`ArchiveRecord._stateFromWire` 认不出当 `pending` 同一条规矩。
  if (record.timeAnchor == null) {
    return '备份回执里没有时间锚，算不出保留期从哪天起算';
  }

  // ② 被锁定 —— 可以无限期压住保留期（规格 §3.6.5）。
  if (_isLocked(entry, labels)) {
    return '已被用户锁定，永不被自动清理';
  }

  // ③ 最近 24 小时内**录**的（不是备份的）。
  final sinceRecorded = now.difference(entry.endedAt);
  if (sinceRecorded < freshWindow) {
    return '录完还不到 ${freshWindow.inHours} 小时';
  }

  return null;
}

/// 这条录像的业务类型；标签里没有、或者认不出来就返回 `null`。
///
/// **不猜**：`BusinessType.tryParse` 认不出来时给出的是 `null`，
/// 这一点很关键 —— 见 [planCleanup] 里那条注释。
BusinessType? _businessTypeOf(
  RecordingEntry entry,
  Map<String, Map<String, String>> labels,
) =>
    BusinessType.tryParse(labels[entry.evidenceId]?[BusinessType.labelKey]);

/// 锁标记走标签表，键名与电脑端 `LabelKeys.Locked` **逐字一致**。
///
/// 与电脑端同一条理由：标签是追加写、后者胜出，正好表达
/// 「解锁 = 再追加一条 false」，不必为此再造一套锁存储。
bool _isLocked(
  RecordingEntry entry,
  Map<String, Map<String, String>> labels,
) {
  final raw = labels[entry.evidenceId]?[lockedLabelKey];

  // 没打过这个标签 = 没锁。**这一条必须单独判**：它是绝大多数证据的常态，
  // 少了它，「认不出来就当锁着」会把整个库永久锁死、永远清不掉任何东西。
  if (raw == null) return false;

  // 认不出来的写法（`'1'` / `''` / 被人手改坏的值）**一律当锁着** ——
  // 朝**少删**的那头落。与 `RetentionSetting.fromConfig` 解析失败回落到
  // 「全部保留」、`ArchiveRecord._stateFromWire` 认不出当 `pending`
  // 同一条规矩，理由也一样：**把锁读丢了的代价是删掉用户锁上的证据**，
  // 而反过来只是少清一条、占点地方（而且它在豁免列表里看得见）。
  //
  // ⚠️ 电脑端 `CleanupPlanner.IsLocked` 必须与这里**同向**，
  // 否则两端对同一条录像的锁判定会不一致。
  return bool.tryParse(raw.trim()) ?? true;
}

/// 锁定标记的标签键。与电脑端 `LabelKeys.Locked` 逐字一致。
///
/// ⚠️ 写错的代价**是静默的**：电脑端按 `locked` 去查，查不到就当「没打过这个
/// 标签」—— 一条锁好的证据会被当成没锁。与 `BusinessType.labelKey` 同一个坑。
const String lockedLabelKey = 'locked';

String _stamp(DateTime time) =>
    '${time.year}-${_two(time.month)}-${_two(time.day)}';

String _two(int value) => value.toString().padLeft(2, '0');

// ────────────────────────────────────────────────────────────
// 执行层为什么还不存在（写给下一个接棒的人，别把它当成漏做）
// ────────────────────────────────────────────────────────────
//
// 删文件的那一层（电脑端叫 `CleanupExecutor`）**故意还没写**，两个理由：
//
// 1. **§3.5.4 的回查还没得可查**。删除前必须回查归档层确认那一份真的还在，
//    回查不通过（不存在 **或查不了**）绝不删本地副本 —— 那是 I8。
//    「查不了」必须算不通过：网络断了时把它当成「不存在」，
//    删的可能是最后一份副本（I2）。这件事要等 M6 的归档层客户端。
// 2. **没有触发点可接**。M6 之前不存在「什么时候该清一次」这件事，
//    现在写出来的执行层会是一段**没人调用、也没法验证**的代码 ——
//    电脑端刚因为「写完了、测过了、没插电」吃过一次亏
//    （母仓 `HANDOFF.md` §6 第 19 条）。宁可晚写，不要写一段没插电的。
//
// 到时候要接的是：本文件 → §3.5.4 回查 → 删除 → `CleanupAuditLog` 流水
// （规格 §3.5.5「禁止静默清理」）。审计**写不进去就不许删** —— 没有记录
// 等于静默清理。
