import 'dart:convert';
import 'dart:io';

import '../primitives.dart';

/// 索引里的一条录像记录。
///
/// 字段与电脑端 `VidLog.Desktop.Core/Index/RecordingIndex.cs` 的
/// `RecordingEntry` **一一对应**，契约以母仓 `docs/02-数据模型.md` 为准。
///
/// 注意 [sessionId] 是必需的：打点记的是**会话内偏移**，而一次打包可能横跨
/// 多个分段文件，没有它就拼不出时间轴（母仓 §5.4）。
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
      // 早期记录可能没有这个字段 —— 退化成「自己是自己的会话」，
      // 至少不会把不同会话错并到一起。
      sessionId: (json['sessionId'] as String?) ?? evidenceId,
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
