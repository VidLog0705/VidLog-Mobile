import 'dart:convert';
import 'dart:io';

import '../primitives.dart';

/// 会话落盘元数据（`session.json` 的形状）。
class SessionManifest {
  const SessionManifest({
    required this.sessionId,
    required this.waybill,
    required this.sourceDeviceId,
    required this.startedAt,
    required this.segments,
  });

  final String sessionId;
  final WaybillNumber waybill;
  final String sourceDeviceId;
  final DateTime startedAt;
  final List<SegmentManifest> segments;

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'waybill': waybill.value,
        'sourceDeviceId': sourceDeviceId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'segments': segments.map((s) => s.toJson()).toList(),
      };

  static SessionManifest fromJson(Map<String, Object?> json) => SessionManifest(
        sessionId: json['sessionId']! as String,
        waybill: WaybillNumber.parse(json['waybill'] as String?),
        sourceDeviceId: (json['sourceDeviceId'] as String?) ?? '',
        startedAt: DateTime.parse(json['startedAt']! as String).toLocal(),
        segments: ((json['segments'] as List?) ?? const [])
            .map((e) => SegmentManifest.fromJson(e as Map<String, Object?>))
            .toList(),
      );
}

/// 一个分段的落盘元数据。
class SegmentManifest {
  const SegmentManifest({
    required this.sequence,
    required this.fileName,
    required this.startedAt,
    required this.endedAt,
  });

  final int sequence;
  final String fileName;
  final DateTime startedAt;
  final DateTime endedAt;

  Map<String, Object?> toJson() => {
        'sequence': sequence,
        'fileName': fileName,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'endedAt': endedAt.toUtc().toIso8601String(),
      };

  static SegmentManifest fromJson(Map<String, Object?> json) => SegmentManifest(
        sequence: (json['sequence'] as num).toInt(),
        fileName: json['fileName']! as String,
        startedAt: DateTime.parse(json['startedAt']! as String).toLocal(),
        endedAt: DateTime.parse(json['endedAt']! as String).toLocal(),
      );
}

/// 一个落盘的分段（收尾的输入）。
class SegmentProduct {
  const SegmentProduct({
    required this.sequence,
    required this.filePath,
    required this.startedAt,
    required this.endedAt,
  });

  final int sequence;
  final String filePath;
  final DateTime startedAt;
  final DateTime endedAt;
}

/// 重启后发现的、没有收尾的会话。
class OrphanSession {
  const OrphanSession({
    required this.sessionId,
    required this.waybill,
    required this.sourceDeviceId,
    required this.segments,
  });

  final String sessionId;
  final WaybillNumber waybill;
  final String sourceDeviceId;
  final List<SegmentProduct> segments;
}

/// 录制工作区 —— 会话落盘与孤儿发现。
///
/// 目录形态：`<root>/<sessionId>/session.json` + 各分段文件，
/// 收尾成功后另写一个 `finalized.json`。
///
/// **孤儿 = 有 `session.json` 但没有 `finalized.json`。**
/// 进程被杀时来不及写任何东西，所以「缺 finalized 标记」是唯一可靠、
/// 且无需推断（不用猜「文件能不能播」「进程还在不在」）的信号。
///
/// 与电脑端 `VidLog.Desktop.Core/Recording/RecordingWorkspace.cs` 行为一致。
class RecordingWorkspace {
  RecordingWorkspace(this.rootDirectory);

  static const manifestFileName = 'session.json';
  static const finalizedFileName = 'finalized.json';

  final String rootDirectory;

  String sessionDirectory(String sessionId) => '$rootDirectory/$sessionId';

  Future<void> writeManifest(SessionManifest manifest) async {
    final directory = Directory(sessionDirectory(manifest.sessionId));
    await directory.create(recursive: true);

    // 写临时文件再改名：改名之前被杀，留下的是完整的旧版本或完整的新版本，
    // 不会有半个 JSON。
    await _writeAtomically(
      '${directory.path}/$manifestFileName',
      jsonEncode(manifest.toJson()),
    );
  }

  Future<void> markFinalized(String sessionId) async {
    final directory = Directory(sessionDirectory(sessionId));
    await directory.create(recursive: true);

    await _writeAtomically(
      '${directory.path}/$finalizedFileName',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// 列出所有没走完收尾的会话。
  ///
  /// 分段文件已经不在了的会话会被跳过 —— 没有东西可以收尾，硬报一条只是噪声。
  Future<List<OrphanSession>> listOrphans() async {
    final root = Directory(rootDirectory);
    if (!await root.exists()) return [];

    final orphans = <OrphanSession>[];

    await for (final entity in root.list()) {
      if (entity is! Directory) continue;

      final sessionId = entity.path.split(Platform.pathSeparator).last;
      if (await File('${entity.path}/$finalizedFileName').exists()) continue;

      final manifestFile = File('${entity.path}/$manifestFileName');
      if (!await manifestFile.exists()) continue;

      SessionManifest manifest;
      try {
        manifest = SessionManifest.fromJson(
            jsonDecode(await manifestFile.readAsString()) as Map<String, Object?>);
      } on Object {
        // 半个 JSON 或字段缺失 —— 读不出来的会话没法收尾，跳过。
        continue;
      }

      final segments = <SegmentProduct>[];
      for (final segment in manifest.segments) {
        final path = '${entity.path}/${segment.fileName}';
        if (await File(path).exists()) {
          segments.add(SegmentProduct(
            sequence: segment.sequence,
            filePath: path,
            startedAt: segment.startedAt,
            endedAt: segment.endedAt,
          ));
        }
      }

      if (segments.isEmpty) continue;

      segments.sort((a, b) => a.sequence.compareTo(b.sequence));
      orphans.add(OrphanSession(
        sessionId: sessionId,
        waybill: manifest.waybill,
        sourceDeviceId: manifest.sourceDeviceId,
        segments: segments,
      ));
    }

    return orphans;
  }

  Future<void> _writeAtomically(String destination, String content) async {
    final temporary = File('$destination.tmp');
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(destination);
  }
}
