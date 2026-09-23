import 'dart:io';

import '../primitives.dart';
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
