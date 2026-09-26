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
    this.codec,
    this.resolution,
    this.orientation,
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

  /// 这条录像的录制规格（规格 §3.1.7 的连带项）。
  ///
  /// **可空**，而且是刻意的：2026-09-27 之前录的那些行里没有这三个字段，
  /// 而索引是追加写的 —— 老行永远长这样。所以：
  ///
  /// - 容量估算对它们走默认档那一格（见 `lifecycle.estimateBytes`）；
  /// - 电脑端那半边的同名字段也是可空的（`RecordingEntry.Codec`）。
  ///
  /// ⚠️ **方向只有手机端写得出来** —— 电脑端写的是 `null`。这不是缺字段，
  /// 是「电脑端没有方向这一项」（规格 §3.1.7 ② 原话「仅手机端」）。
  final String? codec;
  final String? resolution;
  final String? orientation;

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
        // 值为 null 时**不写这个键**：写 `"codec": null` 与不写是两回事，
        // 而不写的那个才与老行长得一样（读端只认「有没有这个键」）。
        if (codec != null) 'codec': codec,
        if (resolution != null) 'resolution': resolution,
        if (orientation != null) 'orientation': orientation,
      };

  /// 宽容地读一行 —— **字段名按候选表逐个试，大小写不敏感**。
  ///
  /// ⚠️ 为什么不能直接 `json['evidenceId']`：两端写的**字段名不一样**
  /// （2026-09-27 核过）—— 本仓写 camelCase（`waybill`/`startedAt`…），
  /// 电脑端写它自己 DTO 的名字（`Waybill`/`StartedAt`…，PascalCase），
  /// 而母仓 `docs/02-数据模型.md` §1.1 那张表用的又是第三套
  /// （`WaybillNumber`/`RecordingStartedAt`）—— **两端的落盘名都不是它**。
  ///
  /// 两端的文件都已经在盘上了（手机上装的是 19/21/22 号包），所以**读端必须宽容**，
  /// 写端维持原样。真要对齐字段名，得挑一次版本一起改。
  ///
  /// 关键字段少一个就返回 null（**不编一条出来**）。
  static RecordingEntry? tryFromJson(Map<String, Object?> json) {
    final evidenceId = _text(json, ['evidenceId']);
    final waybill = _text(json, ['waybill', 'waybillNumber']);
    final startedAt = _text(json, ['startedAt', 'recordingStartedAt']);
    final endedAt = _text(json, ['endedAt', 'recordingEndedAt']);
    final location = _text(json, ['location']);

    if (evidenceId == null || waybill == null || startedAt == null ||
        endedAt == null || location == null) {
      return null;
    }

    try {
      final sessionId = _text(json, ['sessionId']);

      return RecordingEntry(
        evidenceId: evidenceId,
        sessionId: sessionId ?? sessionIdFromEvidenceId(evidenceId),
        waybill: WaybillNumber.parse(waybill),
        startedAt: DateTime.parse(startedAt).toLocal(),
        endedAt: DateTime.parse(endedAt).toLocal(),
        duration: Duration(
            milliseconds:
                ((_number(json, ['durationSeconds', 'duration']) ?? 0) * 1000).round()),
        location: RelativePath.parse(location),
        contentHash: ContentHash.parse(_text(json, ['contentHash']) ?? ''),
        sourceDeviceId: _text(json, ['sourceDeviceId']) ?? '',
        // 三个都**允许缺**（老行就没有）。取到原样存，**不在这里归一成枚举名** ——
        // 索引是「录的时候是什么就记什么」，把读端变成写端会让同一份文件在不同
        // 版本里读出不同的值。归一留给用它的人（`RecordingSpec.fromConfig` 认得动）。
        codec: _text(json, ['codec']),
        resolution: _text(json, ['resolution']),
        orientation: _text(json, ['orientation']),
      );
    } on Object {
      // 字段在、内容不合法（单号格式、时间格式、哈希长度…）——
      // 与「缺字段」同样处理：丢掉这一条，不编。
      return null;
    }
  }

  /// 按候选名取字符串，**大小写不敏感**。
  static String? _text(Map<String, Object?> json, List<String> names) {
    for (final entry in json.entries) {
      for (final name in names) {
        if (entry.key.toLowerCase() != name.toLowerCase()) continue;
        final value = entry.value;
        if (value is String && value.trim().isNotEmpty) return value;
      }
    }
    return null;
  }

  /// 按候选名取数字（数字或能当数字的字符串）。
  static double? _number(Map<String, Object?> json, List<String> names) {
    for (final entry in json.entries) {
      for (final name in names) {
        if (entry.key.toLowerCase() != name.toLowerCase()) continue;
        final value = entry.value;
        if (value is num) return value.toDouble();
        if (value is String) {
          final parsed = double.tryParse(value);
          if (parsed != null) return parsed;
        }
      }
    }
    return null;
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
        final entry = RecordingEntry.tryFromJson(
            jsonDecode(line) as Map<String, Object?>);

        // 认不出来（缺关键字段/字段不合法）就丢掉这一条 —— **不编一条出来**。
        // 半截 JSON（原子写要防的正是这种，但历史遗留文件可能长这样）。
        // 读不出来的行跳过，不能让一条坏行毁掉整个索引。
        if (entry != null) entries.add(entry);
      } on Object {
        continue;
      }
    }

    return entries;
  }
}
