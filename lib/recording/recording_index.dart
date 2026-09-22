import 'dart:convert';
import 'dart:io';

import '../primitives.dart';

/// 索引里的一条录像记录。
///
/// 字段与电脑端 `VidLog.Desktop.Core/Index/RecordingIndex.cs` 的
/// `RecordingEntry` 对应，契约以母仓 `docs/02-数据模型.md` 为准。
class RecordingEntry {
  const RecordingEntry({
    required this.evidenceId,
    required this.sessionId,
    required this.waybill,
    required this.startedAt,
    required this.endedAt,
    required this.duration,
    required this.location,
    required this.contentHash,
    required this.sourceDeviceId,
  });

  final String evidenceId;

  /// 这个分段属于哪一次录制。
  ///
  /// **「一条录像」的口径就是这个** —— 索引是按分段记的，一次录制会有多条，
  /// 靠它归并（见 `recording_totals.dart`）。2026-09-22 加：在这之前只有
  /// `evidenceId`，会话 id 只能靠切字符串猜。
  ///
  /// 与电脑端 `RecordingEntry.cs` 的对应字段同名；这是**追加**字段，
  /// 老条目没有它会走 [sessionIdFromEvidenceId] 回退。
  final String sessionId;
  final WaybillNumber waybill;
  final DateTime startedAt;
  final DateTime endedAt;
  final Duration duration;

  /// 归档层里的**相对路径**（规格 §6.2：绝对路径在重装后必然失效）。
  final RelativePath location;

  final ContentHash contentHash;
  final String sourceDeviceId;

  Map<String, Object?> toJson() => {
        'evidenceId': evidenceId,
        'sessionId': sessionId,
        'waybill': waybill.value,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'endedAt': endedAt.toUtc().toIso8601String(),
        'durationSeconds': duration.inMilliseconds / 1000,
        'location': location.value,
        'contentHash': contentHash.value,
        'sourceDeviceId': sourceDeviceId,
      };

  static RecordingEntry fromJson(Map<String, Object?> json) {
    final evidenceId = json['evidenceId']! as String;

    return RecordingEntry(
      evidenceId: evidenceId,
      sessionId: (json['sessionId'] as String?)?.trim().isNotEmpty == true
          ? (json['sessionId']! as String).trim()
          : sessionIdFromEvidenceId(evidenceId),
      waybill: WaybillNumber.parse(json['waybill'] as String?),
      startedAt: DateTime.parse(json['startedAt']! as String).toLocal(),
      endedAt: DateTime.parse(json['endedAt']! as String).toLocal(),
      duration: Duration(
          milliseconds:
              (((json['durationSeconds'] as num?) ?? 0) * 1000).round()),
      location: RelativePath.parse(json['location'] as String?),
      contentHash: ContentHash.parse(json['contentHash'] as String?),
      sourceDeviceId: (json['sourceDeviceId'] as String?) ?? '',
    );
  }
}

/// 从 `evidenceId` 里切回会话 id —— 给**没有 `sessionId` 字段的老索引行**兜底。
///
/// `evidenceId` 的形态是 `<sessionId>-<三位序号>`（见 `SessionFinalizer`），
/// 而 `sessionId` 自己形如 `sess-<毫秒>-<随机>`，**本来就有横线** ——
/// 所以从**最后**一个横线切，并且要求尾段正好是三位数字。
///
/// 对不上就返回空串：**宁可这条归不进组（各自算一条），也不要把两条不相干的
/// 录像并成一条。** 计数少一条是小事，把证据合并不是。
String sessionIdFromEvidenceId(String evidenceId) {
  final dash = evidenceId.lastIndexOf('-');
  if (dash <= 0) return '';

  final tail = evidenceId.substring(dash + 1);
  if (tail.length != 3 || int.tryParse(tail) == null) return '';

  return evidenceId.substring(0, dash);
}

/// 录像索引。
abstract interface class RecordingIndex {
  Future<void> add(RecordingEntry entry);

  Future<List<RecordingEntry>> loadAll();
}

/// 按行追加的 JSON 索引（JSON Lines）。
///
/// 与电脑端同样的形态与理由：追加写不重写既有记录，因此不存在
/// 「重写过程中崩溃导致整库损坏」这个失败模式（规格 §6.2「数据删除必须极度克制」）。
class JsonLinesRecordingIndex implements RecordingIndex {
  JsonLinesRecordingIndex(this.path);

  final String path;

  @override
  Future<void> add(RecordingEntry entry) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  @override
  Future<List<RecordingEntry>> loadAll() async {
    final file = File(path);
    if (!await file.exists()) return [];

    final entries = <RecordingEntry>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;

      try {
        entries.add(
            RecordingEntry.fromJson(jsonDecode(line) as Map<String, Object?>));
      } on Object {
        // 半截 JSON（原子写要防的正是这种，但历史遗留文件可能长这样）。
        // 读不出来的行跳过，不能让一条坏行毁掉整个索引。
        continue;
      }
    }

    return entries;
  }
}
