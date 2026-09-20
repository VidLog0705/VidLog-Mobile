import 'dart:io';

import 'package:crypto/crypto.dart';

import '../primitives.dart';
import '../states.dart';
import 'recorder_events.dart' show StopTrigger;
import 'recording_index.dart';
import 'recording_workspace.dart';

/// 单个分段的收尾结果。
class FinalizedSegment {
  const FinalizedSegment({
    required this.source,
    this.location,
    this.contentHash,
    this.failureReason,
  });

  final SegmentProduct source;

  /// 归档层里的相对路径；失败时为 null。
  final RelativePath? location;

  final ContentHash? contentHash;
  final String? failureReason;

  /// 这个分段是否**完整走完了收尾**：算过哈希 + 已写入索引 + 无失败原因。
  ///
  /// 三个条件缺一不可。特别地，**写索引失败也算失败**：
  /// 文件在盘上、哈希也对，但用户检索不到 —— 那对「找得到自己的证据」
  /// 这个承诺等于没入库。电脑端踩过这个坑（测试抓到的），这里从一开始就带上。
  bool get isPublished => location != null && contentHash != null && failureReason == null;
}

/// 一次收尾的结果。
class FinalizeOutcome {
  const FinalizeOutcome({
    required this.state,
    required this.reason,
    required this.segments,
    this.failureReason,
  });

  final RecordingSessionState state;
  final StopTrigger reason;
  final List<FinalizedSegment> segments;
  final String? failureReason;

  bool get succeeded => state == RecordingSessionState.indexed;
}

/// 算文件的内容哈希（规格 §3.6.1：指纹 = 内容哈希 + 单号 + 录制时间）。
Future<ContentHash> hashFile(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return ContentHash.parse(digest.toString());
}

/// 录制收尾 —— **不变量 I9 的唯一落点**。
///
/// 规格 §4.1：任何进入「收尾中」的路径，都必须走**同一套收尾逻辑**
/// （封文件、算哈希、写索引），**不得有旁路**。
///
/// 所以它只有一个公开入口 [finalize]，且**不接收**「为什么停」以外的任何分支信息 ——
/// [StopTrigger] 只被原样带进结果，不参与任何 if。
///
/// ## 与电脑端的差异（刻意的）
///
/// 电脑端录制期写 MKV 中间容器，停下来再 remux 成 MP4。**手机端没有这一步** ——
/// 原生相机（MediaCodec / AVAssetWriter）直接写最终的 MP4，分段本身就是成品。
/// 少一次 remux 就少一次「收尾到一半磁盘满了」的机会。
///
/// ## ⚠️ 手机端没有「实际解码校验」
///
/// 电脑端用 FFmpeg 真解一遍成品来确认可播（规格 §3.1.4）。手机端没有 FFmpeg，
/// 这里只能依赖原生录制器自己的收尾结果。**这是一处已知的验证强度差异**，
/// 需要真机回归来补 —— 见 `docs/` 的未完成清单。
class SessionFinalizer {
  SessionFinalizer({required this.rootDirectory, required this.index});

  /// 本机数据的根目录；索引里的相对路径相对它。
  final String rootDirectory;

  final RecordingIndex index;

  Future<FinalizeOutcome> finalize({
    required String sessionId,
    required WaybillNumber waybill,
    required String sourceDeviceId,
    required List<SegmentProduct> segments,
    required StopTrigger reason,
  }) async {
    if (segments.isEmpty) {
      return FinalizeOutcome(
        state: RecordingSessionState.finalizeFailed,
        reason: reason,
        segments: const [],
        failureReason: '会话没有任何分段可收尾',
      );
    }

    final finalized = <FinalizedSegment>[];
    String? firstFailure;

    final ordered = [...segments]..sort((a, b) => a.sequence.compareTo(b.sequence));

    for (final segment in ordered) {
      final result = await _finalizeSegment(
        sessionId: sessionId,
        waybill: waybill,
        sourceDeviceId: sourceDeviceId,
        segment: segment,
      );

      firstFailure ??= result.isPublished ? null : (result.failureReason ?? '收尾失败（未给出原因）');
      finalized.add(result);
    }

    final allPublished = finalized.every((s) => s.isPublished);

    // 只要有一个分段没走完，整个会话就**不得**标记为正常入库（规格 §4.1）。
    return FinalizeOutcome(
      state: allPublished
          ? RecordingSessionState.indexed
          : RecordingSessionState.finalizeFailed,
      reason: reason,
      segments: finalized,
      failureReason: allPublished ? null : firstFailure,
    );
  }

  Future<FinalizedSegment> _finalizeSegment({
    required String sessionId,
    required WaybillNumber waybill,
    required String sourceDeviceId,
    required SegmentProduct segment,
  }) async {
    final file = File(segment.filePath);
    if (!await file.exists()) {
      return FinalizedSegment(
          source: segment, failureReason: '分段文件不存在：${segment.filePath}');
    }

    ContentHash contentHash;
    try {
      contentHash = await hashFile(segment.filePath);
    } on Object catch (error) {
      return FinalizedSegment(source: segment, failureReason: '算哈希失败：$error');
    }

    final location = relativeLocation(segment.filePath);

    try {
      await index.add(RecordingEntry(
        evidenceId: '$sessionId-${segment.sequence.toString().padLeft(3, '0')}',
        sessionId: sessionId,
        waybill: waybill,
        startedAt: segment.startedAt,
        endedAt: segment.endedAt,
        duration: segment.endedAt.difference(segment.startedAt),
        location: location,
        contentHash: contentHash,
        sourceDeviceId: sourceDeviceId,
      ));
    } on Object catch (error) {
      // 文件在盘上、哈希也对，但检索不到 —— 不算收尾成功。
      return FinalizedSegment(
        source: segment,
        location: location,
        contentHash: contentHash,
        failureReason: '写索引失败：$error',
      );
    }

    return FinalizedSegment(
      source: segment,
      location: location,
      contentHash: contentHash,
    );
  }

  /// 把绝对路径转成相对根目录的路径（规格 §6.2：只存相对路径）。
  RelativePath relativeLocation(String filePath) {
    var normalized = filePath;
    if (normalized.startsWith(rootDirectory)) {
      normalized = normalized.substring(rootDirectory.length);
    }

    while (normalized.startsWith('/') || normalized.startsWith(r'\')) {
      normalized = normalized.substring(1);
    }

    return RelativePath.parse(normalized);
  }
}

/// 启动时收尾孤儿分段。
///
/// 规格 §3.1.1 / §8：进程被系统杀死或掉电后，**重启后必须能自动收尾孤儿分段**
/// （封闭文件、写入索引），不产生无法播放的半成品。
///
/// **这个类的全部意义在于「它没有自己的收尾逻辑」** ——
/// 孤儿收尾不是特例，只是 [StopTrigger.processKilled] 这个停法，
/// 走的是同一个 [SessionFinalizer]。这就是 I9 在重启路径上的落点。
class OrphanRecovery {
  OrphanRecovery({required this.workspace, required this.finalizer});

  final RecordingWorkspace workspace;
  final SessionFinalizer finalizer;

  /// 只有成功的才打上 finalized 标记。失败的保持孤儿身份，下次启动重试 ——
  /// 源文件一定还在（I2），可能只是碰上了瞬时故障。
  Future<List<FinalizeOutcome>> recover() async {
    final orphans = await workspace.listOrphans();
    final outcomes = <FinalizeOutcome>[];

    for (final orphan in orphans) {
      final outcome = await finalizer.finalize(
        sessionId: orphan.sessionId,
        waybill: orphan.waybill,
        sourceDeviceId: orphan.sourceDeviceId,
        segments: orphan.segments,
        reason: StopTrigger.processKilled,
      );

      if (outcome.succeeded) {
        await workspace.markFinalized(orphan.sessionId);
      }

      outcomes.add(outcome);
    }

    return outcomes;
  }
}
