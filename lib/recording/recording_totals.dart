import 'dart:io';

import '../primitives.dart';
import 'business_type.dart';
import 'recording_index.dart';

/// 一次录制 —— 需求方口径的「一条」。
///
/// > 每一个单号从开始到结束为一条。（2026-09-22）
///
/// ## ⚠️ 这与索引里的一行**不是一回事**
///
/// 索引是**按分段**记的：一段 30 分钟的录制（5 分钟一段）会产生 **6 行**。
/// 按行数显示会比用户心里的数字大 5~6 倍，而且他数不出那个数字是哪来的 ——
/// 规格里「按已录时长封顶」等机制都是按分段落的，分段是实现细节，
/// 不该泄漏到界面上的计数里。
class RecordingSession {
  const RecordingSession({
    required this.sessionId,
    required this.waybill,
    required this.startedAt,
    required this.duration,
    required this.bytes,
    required this.segmentCount,
    required this.evidenceIds,
  });

  final String sessionId;
  final WaybillNumber waybill;

  /// **起录时间** = 各分段里最早的那个起点。
  ///
  /// 「今日」按它算（需求方 2026-09-22：起录时间当日 0 点到 23:59）。
  /// 用最早而不是最晚：跨零点录的那一段该算在**开始录的那天**，
  /// 否则一条录像会随着它自己录多久而在日历上跳来跳去。
  final DateTime startedAt;

  /// 各分段时长之和。
  final Duration duration;

  /// 盘上真实占用。文件不在了就是 0。
  final int bytes;

  final int segmentCount;

  /// 这条录像各分段在索引里的 `evidenceId`。
  ///
  /// ⚠️ **备份状态是按分段记的**（`archive.jsonl` 以 `evidenceId` 为键），
  /// 而界面上列的是「一次录制」。所以那条备份状态的小标得把各段**归并**
  /// 出来 —— 见 `upload/archive_store.dart` 的 `summarizeUploadState`。
  ///
  /// 归并这件事**必须只有一处**：各写一套的话迟早会出现「列表说已备份、
  /// 点进去说有条失败」。
  final List<String> evidenceIds;
}

/// 把索引里的分段条目归并成「一次录制」。
///
/// [bytesByEvidenceId] 是各分段在盘上的字节数（量不到的不放进来）。
/// 按 [RecordingSession.startedAt] **倒序**（新的在前）返回 —— 界面直接用。
List<RecordingSession> toSessions(
  List<RecordingEntry> entries,
  Map<String, int> bytesByEvidenceId,
) {
  final grouped = <String, List<RecordingEntry>>{};

  for (final entry in entries) {
    // 没有会话 id 的条目（老索引行且切不出前缀）**不归组**，各自算一条 ——
    // 宁可多算一条，也不要把两条不相干的录像并成一条。
    final key = entry.sessionId.isEmpty ? entry.evidenceId : entry.sessionId;
    grouped.putIfAbsent(key, () => []).add(entry);
  }

  final sessions = <RecordingSession>[];

  for (final group in grouped.values) {
    final ordered = [...group]
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

    var duration = Duration.zero;
    var bytes = 0;
    for (final entry in ordered) {
      duration += entry.duration;
      bytes += bytesByEvidenceId[entry.evidenceId] ?? 0;
    }

    sessions.add(RecordingSession(
      sessionId: ordered.first.sessionId,
      waybill: ordered.first.waybill,
      startedAt: ordered.first.startedAt,
      duration: duration,
      bytes: bytes,
      segmentCount: ordered.length,
      evidenceIds: [for (final entry in ordered) entry.evidenceId],
    ));
  }

  sessions.sort((a, b) => b.startedAt.compareTo(a.startedAt));
  return sessions;
}

/// 盘上**还在**的那部分索引条目。
///
/// ## 为什么必须有这一道
///
/// 索引是**追加写**的（`JsonLinesRecordingIndex`，规格 §6.2：不做整库重写，
/// 于是不存在「重写途中崩溃把整库写坏」这个失败模式）—— 它**只有 `add`，
/// 没有删除**。删掉一条录像时走的是 `deleteSessionFiles`，它删的是**文件**，
/// 一行索引都不碰。
///
/// 而列表、「本机全部」、「N 个未备份」全是从索引归并出来的
/// （`toSessions` → `_sessions`）。**所以不在这里滤一道的话，删掉的录像
/// 会永远留在列表上**：用户点了确认删除、文件真没了，而界面上什么都不变 ——
/// 列表还在、数字不变、详情页因为 `_sessions.length` 没少而不 pop。
/// 再点几次也一样。这就是需求方 2026-09-28 报的「删不掉」。
///
/// 「这条还在不在」**问索引问不出来，只能问盘** —— 与「总占用走盘、不走索引」
/// （`videoBytesOnDisk`）是同一条立场：索引只增不减，拿它求和永远降不下来，
/// 拿它数列也永远少不下去。
///
/// ## ⚠️ [gone] 只许装「确认真不在盘上」的
///
/// 「量不出大小」（文件在、但 `length()` 抛了）的那些**不许进来**。
/// 一个是「没了」，一个是「大小未知」—— 把后者当没了是**更坏**的事：
/// 一条录像会从界面上静默消失，而它其实好端端躺在盘上。
/// 这也是既有注释（`_refreshDiagnostics` 里那段「宁可少一个数字」）的意思。
///
/// 按分段滤：一次录制有几段，删掉的段不来，剩下的段照旧 ——
/// 于是列表上那一行的「N 段」跟着变小，而不是整条消失。
List<RecordingEntry> dropGoneSegments(
  List<RecordingEntry> entries,
  Set<String> gone,
) =>
    [for (final entry in entries) if (!gone.contains(entry.evidenceId)) entry];

/// 「今日」录了几条 —— 起录时间落在 [now] 那一天的会话数。
///
/// 判据是**本地日历日**（0:00:00 ~ 23:59:59.999）。
///
/// ⚠️ 与不变量 I11 的关系：录像自己用的是单调时钟 + UTC 墙钟（改系统时间伪造
/// 不了时间）。但**「今日」天生是个日历概念**，只能读本地时间 —— 所以用户改系统
/// 时间会让这**一个统计数字**跟着变。这是可接受的：它不参与任何证据判定。
int countToday(List<RecordingSession> sessions, DateTime now) =>
    sessions.where((session) => isSameDay(session.startedAt, now)).length;

/// 两个时刻是不是同一个**本地日历日**（0:00:00 ~ 23:59:59.999）。
///
/// 筛「今日」的那个列表和上面那个计数必须是**同一个判据** ——
/// 否则会出现「上面写今日 3 条、下面只列出 2 条」，而用户没有任何办法
/// 判断哪个才是对的。
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// `9月23日` —— 列表副标题里那一段日期。
///
/// ⚠️ 2026-09-27 从 `09-23` 改成这个（需求方自绘草图）。
/// **显示与匹配必须走同一个函数**：两处各写一套的话，屏幕上明明写着
/// `9月23日` 却搜不出来，用户只会以为搜索坏了（踩坑 #13 的同一条）。
String dayStamp(DateTime at) => '${at.month}月${at.day}日';

String _two(int value) => value.toString().padLeft(2, '0');

/// 一条录像要不要出现在搜索结果里（规格 §3.8 的两个维度：单号、日期）。
///
/// 匹配的是**那一行界面上真有的字**：单号（没有单号时列表显示会话 id）+ 时间。
///
/// 日期收**三种**写法，一种都不能少：
///
/// | 写法 | 为什么得认 |
/// |---|---|
/// | `9月23日` | **屏幕上真有的那种**（[dayStamp]）。不认它就等于搜索坏了 |
/// | `09-23` | 2026-09-27 之前屏幕上的写法 —— 用户的习惯还在这儿 |
/// | `2026-09-23` | 用户最可能敲的完整日期 |
///
/// ⚠️ 这是**纯本地筛选**，不查网、不查许可（文档 §04 的 L8：未激活 /
/// 试用到期 / 校验失败都不得挡住检索与回放）。这里加任何许可判断都是越线。
bool matchesQuery(RecordingSession session, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;

  final at = session.startedAt;
  final dates = [
    dayStamp(at),
    '${_two(at.month)}-${_two(at.day)}',
    '${at.year}-${_two(at.month)}-${_two(at.day)}',
  ];

  return session.waybill.value.toLowerCase().contains(q) ||
      session.sessionId.toLowerCase().contains(q) ||
      dates.any((date) => date.contains(q));
}

/// 录像列表的三条筛选：**来源**（发货 / 退货）、**日期**、**搜索词**。
///
/// 抽成纯函数是为了**能测**：界面那一层在 widget 测试里 `_sessions` 恒空
/// （要读 `index.jsonl`，而那是平台通道），筛选逻辑放在页面里等于没有覆盖。
///
/// 三条判据都与页面上别处**共用同一个函数**，不另写一套：
/// - 日期 → [isSameDay]，与「本机今日」那个统计同一个（否则会出现
///   「上面写 3 条、下面列 2 条」而用户无从判断谁对）；
/// - 搜索 → [matchesQuery]；
/// - 来源 → 调用方传进来的 [typeOf]。业务类型**不在** `RecordingSession` 里
///   （它按分段存在标签里），所以只能由调用方查了给我们。
///
/// [day] 为 null = 不按日期筛（「全部日期」）；[source] 为 null = 全部来源。
///
/// ⚠️ 这仍然是**纯本地筛选**，不查网、不查许可（L8）。
List<RecordingSession> filterSessions(
  List<RecordingSession> sessions, {
  DateTime? day,
  BusinessType? source,
  String query = '',
  required BusinessType? Function(RecordingSession) typeOf,
}) {
  final trimmed = query.trim();

  return [
    for (final session in sessions)
      if ((day == null || isSameDay(session.startedAt, day)) &&
          (source == null || typeOf(session) == source) &&
          matchesQuery(session, trimmed))
        session,
  ];
}

/// 盘上视频的实际占用。
///
/// 需求方 2026-09-22 定的口径：**「按实际存储到手机的视频大小总量计算，
/// 如果上传到电脑后删除手机上的视频，那么就按删除后的体积显示。」**
///
/// 所以它**必须走盘，不能拿索引求和** —— 索引只增不减（母仓 §6.2
/// 「数据删除必须极度克制」），拿它求和永远只会涨，删了东西也降不下来。
///
/// 只数 `.mp4`：`session.json` / `finalized.json` / 索引 / 打点日志都不是视频，
/// 混进去会让这个数字对不上用户在系统设置里看到的占用。
///
/// **推论：这个数包含未收尾的孤儿片段**（它们也是盘上真有的视频），
/// 因此可能比「各条录像大小之和」大。这是对的，不是 bug。
Future<int> videoBytesOnDisk(String rootDirectory) async {
  final root = Directory(rootDirectory);
  if (!await root.exists()) return 0;

  var total = 0;

  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.toLowerCase().endsWith('.mp4')) continue;

    try {
      total += await entity.length();
    } on Object {
      // 单个文件量不到（正被录制器持有、刚好被删）就跳过它，不让整页数字失败。
      continue;
    }
  }

  return total;
}
