import 'dart:convert';
import 'dart:io';

import '../diagnostics/app_log.dart';
import '../primitives.dart';
import 'business_type.dart';

/// 会话落盘元数据（`session.json` 的形状）。
class SessionManifest {
  const SessionManifest({
    required this.sessionId,
    required this.waybill,
    required this.sourceDeviceId,
    required this.startedAt,
    required this.segments,
    this.businessType,
  });

  final String sessionId;
  final WaybillNumber waybill;
  final String sourceDeviceId;
  final DateTime startedAt;
  final List<SegmentManifest> segments;

  /// 这一件是发货还是退货。
  ///
  /// **它不是标签本身** —— 标签表（`labels.jsonl`）才是，见 [LabelStore]。
  /// 这份清单里记它，是为了让**进程被杀之后**的孤儿收尾也补得上标签：
  /// 那时内存里的东西全没了，只剩盘上这几份文件。
  ///
  /// `null` = 没记（老版本写的清单、或调用方没给）。**不猜**，那种会话
  /// 收尾时就不写标签 —— 检索时显示 `unknown`，比猜错一个强。
  final BusinessType? businessType;

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'waybill': waybill.value,
        'sourceDeviceId': sourceDeviceId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'segments': segments.map((s) => s.toJson()).toList(),
        // 追加字段（只加不改）：老版本读新文件只是忽略它。
        'businessType': businessType?.wire,
      };

  static SessionManifest fromJson(Map<String, Object?> json) => SessionManifest(
        sessionId: json['sessionId']! as String,
        waybill: WaybillNumber.parse(json['waybill'] as String?),
        sourceDeviceId: (json['sourceDeviceId'] as String?) ?? '',
        startedAt: DateTime.parse(json['startedAt']! as String).toLocal(),
        segments: ((json['segments'] as List?) ?? const [])
            .map((e) => SegmentManifest.fromJson(e as Map<String, Object?>))
            .toList(),
        businessType: BusinessType.tryParse(json['businessType']),
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

/// 写临时文件再改名。
///
/// **Windows 上「改名覆盖已存在的文件」会被拒绝**（`errno = 5 拒绝访问`）——
/// 实测：Defender 扫新写的文件时会短暂持有句柄，而开录写一次 manifest、
/// 每个分段封闭再写一次，正好每次都撞上。
///
/// 所以重试几次；仍不行就**退化成直接写**。宁可失去「原子替换」这一层保护，
/// 也不能把内容整个丢掉 —— 对 manifest 来说那会让这段录像重启后没法被收尾，
/// 对设备配置来说那会让本机在电脑端变成一台新设备（名字全丢）。
Future<void> writeFileAtomically(String destination, String content) async {
  final temporary = File('$destination.tmp');
  await temporary.writeAsString(content, flush: true);

  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await temporary.rename(destination);
      return;
    } on FileSystemException {
      if (attempt == 4) break;
      await Future<void>.delayed(Duration(milliseconds: 20 * (attempt + 1)));
    }
  }

  await File(destination).writeAsString(content, flush: true);

  try {
    await temporary.delete();
  } on FileSystemException {
    // 删不掉只是留个 .tmp 垃圾，不影响正确性。
  }
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
    this.businessType,
  });

  final String sessionId;
  final WaybillNumber waybill;
  final String sourceDeviceId;
  final List<SegmentProduct> segments;

  /// 从清单里读回来的「发货 / 退货」。收尾时靠它补标签 ——
  /// 孤儿那条路上没有别的地方还记得这件事。
  final BusinessType? businessType;
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

  /// manifest 写入的**内部串行闸**。
  ///
  /// 为什么需要它：调用方那边，「开录时写 manifest」与「每个分段封闭时写 manifest」
  /// 现在跑在**两条不同的链**上（原因是收尾时的一条死锁，见
  /// `RecordingCoordinator` 里监听处的说明）。两条链会并发写同一个文件，
  /// 而原子写用的临时文件名是固定的 —— 并发时两个写会撞在同一个 `.tmp` 上。
  ///
  /// 把串行化放进 workspace 而不是靠调用方排队，是因为「同一个文件别被并发写」
  /// 是这个类自己的不变式，不该指望每个调用方都记得。
  Future<void> _writeGate = Future<void>.value();

  String sessionDirectory(String sessionId) => '$rootDirectory/$sessionId';

  Future<void> writeManifest(SessionManifest manifest) {
    final result = _writeGate.then((_) => _writeManifestNow(manifest));

    // 闸门要吞掉异常继续放行，否则一次失败会把后续所有写入都堵死。
    _writeGate = result.then((_) {}, onError: (_) {});

    return result;
  }

  Future<void> _writeManifestNow(SessionManifest manifest) async {
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

  /// 丢掉一个会话的工作目录（T21）。
  ///
  /// 收尾成功之后，`work/` 里那些源分段只剩一个身份 —— **占地方**。
  /// 清理层只清归档里的成品，从来不碰 `work/`，留着它就是无界增长。
  ///
  /// ⚠️ 手机端**没有**电脑端那道「归档层那一份发上去没有」的判据：
  /// 这里的归档层就是本机（`<root>/archive`），送到电脑端那条路由
  /// **持久化的上传队列**负责（I2），跟这几个源分段无关。
  /// 所以判据只有一条：收尾成功。
  ///
  /// ⚠️ 删不掉**不是事故**：留点垃圾而已。真抛出去会把一次**成功的**收尾报成失败，
  /// 那比多占几兆坏得多。
  Future<void> discardSessionDirectory(String sessionId) async {
    try {
      final directory = Directory(sessionDirectory(sessionId));
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException catch (e) {
      AppLog.instance
          .warn('录制', '会话工作目录没删掉，源分段还占着地方（$sessionId）：${e.message}');
    }
  }

  /// 空会话目录的冷静期（T21）：`session.json` 静了这么久、又一段都没留下，
  /// 就认定它不会再长出分段来了。
  static const emptySessionCoolDown = Duration(hours: 24);

  /// 没有任何分段留在盘上的会话目录：记一条，过了冷静期就删掉（T21）。
  ///
  /// ⚠️ 冷静期是给「正在录的那一场」留的：**刚起录时会话目录也是空的**
  /// （第一段封闭之前不写任何分段）。立刻删等于把正在录的那一场连根拔了。
  Future<void> _sweepSegmentsGoneSession(
      String sessionId, File manifestFile, SessionManifest manifest) async {
    final counted = manifest.segments.length;
    final cooled =
        DateTime.now().difference((await manifestFile.stat()).modified) >= emptySessionCoolDown;

    if (counted > 0) {
      // ⚠️ 记过的东西现在一个都不在了 —— 那是**丢证据**（I2）的方向，
      // 不是「一条噪声」。删不删都要喊这一声。
      AppLog.instance.warn(
        '录制',
        '${manifest.waybill.value} 的源分段一个都不在了，这一场收不了尾（$sessionId）：'
        'session.json 里记着 $counted 段',
      );
    }

    if (!cooled) return;

    await discardSessionDirectory(sessionId);

    if (counted == 0) {
      // 空的壳：收不了尾（没有分段可收）⇒ 也永远写不上 finalized.json
      // ⇒ 孤儿扫瞄每次都跳过它。T21 之前它会一直待在那儿。
      AppLog.instance.info('录制', '清掉一个空会话目录（$sessionId）：里面一段都没录到');
    }
  }

  /// 列出所有没走完收尾的会话。
  ///
  /// 分段文件已经不在了的会话不会被列出来 —— 没有东西可以收尾，硬报一条只是噪声。
  /// **但不再静默**（T21）：没有任何分段的会话目录收不了尾、也就永远写不上
  /// `finalized.json`，于是原来每次启动都跳过它、谁都不会碰它一下。
  /// 现在过冷静期就删掉，没到就记一条。
  ///
  /// ⚠️ 所以这个方法**有副作用**（会删陈年的空会话目录），只在启动扫瞄时调。
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

      if (segments.isEmpty) {
        await _sweepSegmentsGoneSession(sessionId, manifestFile, manifest);
        continue;
      }

      segments.sort((a, b) => a.sequence.compareTo(b.sequence));
      orphans.add(OrphanSession(
        sessionId: sessionId,
        waybill: manifest.waybill,
        sourceDeviceId: manifest.sourceDeviceId,
        segments: segments,
        businessType: manifest.businessType,
      ));
    }

    return orphans;
  }

  /// 写临时文件再改名。实现见文件顶部的 [writeFileAtomically] ——
  /// 提到外面是因为设备配置也要用同一套（写坏一次就等于换了一台设备）。
  Future<void> _writeAtomically(String destination, String content) =>
      writeFileAtomically(destination, content);
}
