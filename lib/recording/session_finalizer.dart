import 'dart:io';

import 'package:crypto/crypto.dart';

import '../primitives.dart';
import '../states.dart';
import 'business_type.dart';
import 'label_store.dart';
import 'recorder_events.dart' show StopTrigger;
import 'recording_index.dart';
import 'recording_spec.dart';
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

/// 实际解码校验：这一段成品**解不解得开**（规格 §3.1.4）。
///
/// 返回 `false` ⇒ **不得当成正常入库**。
///
/// ⚠️ 做成注入的函数而不是直接调原生：这一层要能在本机用假校验测到底
/// （与电脑端 `DecodeVerifier` 的处置同形）。
typedef VerifyPlayable = Future<bool> Function(String videoPath);

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
  SessionFinalizer({
    required this.rootDirectory,
    required this.index,
    required this.labels,
    // 实际解码校验（规格 §3.1.4）。
    //
    // ⚠️ **可选**：不传 = 不校验，那是给**不需要它的测试**留的口子
    // （与电脑端 `DecodeVerifier` 在测试里的处置同形）。生产路径由
    // `recorder_page` 传真那个（原生 `verifyPlayable`）。
    VerifyPlayable? verifyPlayable,
  }) : _verifyPlayable = verifyPlayable;

  /// 本机数据的根目录；索引里的相对路径相对它。
  final String rootDirectory;

  final RecordingIndex index;

  /// 标签表（`<root>/labels.jsonl`）。收尾时顺手把「发货 / 退货」写进去。
  final LabelStore labels;

  /// 实际解码校验（规格 §3.1.4）。`null` = 不校验（测试路径）。
  final VerifyPlayable? _verifyPlayable;

  Future<FinalizeOutcome> finalize({
    required String sessionId,
    required WaybillNumber waybill,
    required String sourceDeviceId,
    required List<SegmentProduct> segments,
    required StopTrigger reason,
    BusinessType? businessType,
    RecordingSpec? spec,
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
        businessType: businessType,
        spec: spec,
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
    BusinessType? businessType,
    RecordingSpec? spec,
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

    // ── 实际解码校验（规格 §3.1.4）──────────────────────────────────
    //
    // 规格原话：「停止录制后必须**实际解码校验**成品可播，校验失败**不得入库为
    // 「正常」**」。
    //
    // ⚠️ 2026-09-27 补：在此之前手机端**没有这一层** —— 这个文件里原来写着
    // 「手机端没有 FFmpeg，只能依赖原生录制器自己的收尾结果，**这是一处已知的
    // 验证强度差异**」。后果很具体：编码器收尾异常、产出一个不可播的 MP4 时，
    // 它会被当**正常**写进索引、进入上传队列 —— 而用户要到需要证据那天才发现。
    //
    // ⚠️ 手机端走**系统 API**（iOS `AVAssetImageGenerator` /
    // 安卓 `MediaMetadataRetriever`）—— 那两个本来就是「**真解一帧**」。
    // **能解出首尾两帧 ⇒ 容器与关键帧可读**。
    // ⚠️ 它**不是全解**：电脑端 `ffmpeg -f null -` 是逐帧解完，这里只解两处
    // —— 这个强度差别如实写在 `docs/实现决策.md` 里，不假装一样。
    //
    // ⚠️ 排在**写索引之前**：失败 ⇒ 这一段的 `isPublished` 为假 ⇒
    // 会话不会被标成 `indexed`（下面那句「有一个分段没走完就不得标正常入库」）。
    // 与「写索引失败」那条是同一个机制，不是新造一个。
    if (_verifyPlayable != null && !await _verifyPlayable(segment.filePath)) {
      return FinalizedSegment(
        source: segment,
        location: relativeLocation(segment.filePath),
        contentHash: contentHash,
        failureReason: '解不开这一段（成品校验失败）—— 不会被当成正常入库',
      );
    }

    final location = relativeLocation(segment.filePath);
    final evidenceId = '$sessionId-${segment.sequence.toString().padLeft(3, '0')}';

    try {
      await index.add(RecordingEntry(
        evidenceId: evidenceId,
        sessionId: sessionId,
        waybill: waybill,
        startedAt: segment.startedAt,
        endedAt: segment.endedAt,
        duration: segment.endedAt.difference(segment.startedAt),
        location: location,
        contentHash: contentHash,
        sourceDeviceId: sourceDeviceId,
        // 录制规格（规格 §3.1.7 的连带项）。**没给就不写那两个键** ——
        // 与老行长得一样，读端不会看出差别（它本来就允许缺）。
        codec: spec?.codec.name,
        resolution: spec?.resolution.name,
        orientation: spec?.orientation.name,
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

    await _writeBusinessTypeLabel(evidenceId, businessType);

    return FinalizedSegment(
      source: segment,
      location: location,
      contentHash: contentHash,
    );
  }

  /// 把「发货 / 退货」作为标签写进 `labels.jsonl`。
  ///
  /// 写在索引**之后**：标签指向一条索引里没有的证据，是纯粹的垃圾。
  ///
  /// ⚠️ **写标签失败不算收尾失败** —— 与写索引失败（上面那条）刻意区别对待。
  /// 索引决定「这段录像存不存在」，标签只是**可修正的备注**：为它把一段
  /// 已经算完哈希、文件也完好的录像判成「收尾失败」，等于让它保持孤儿身份、
  /// 每次启动重试，而用户其实什么都没损失。母仓 §6.2 那句话在这里的读法是
  /// **宁可少一个标签，也不能少一条录像**。
  ///
  /// 没给 [businessType] 就什么都不写（老清单 / 调用方没给）—— 标签宁可不写，
  /// 也不猜一个。
  Future<void> _writeBusinessTypeLabel(
    String evidenceId,
    BusinessType? businessType,
  ) async {
    if (businessType == null) return;

    try {
      await labels.append(RecordingLabel(
        evidenceId: evidenceId,
        key: BusinessType.labelKey,
        value: businessType.wire,
        updatedAt: DateTime.now(),
      ));
    } on Object {
      // 见上面的理由：标签丢了是小事，把录像判成失败是大事。
    }
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
        // 从清单里读回来的 —— 进程被杀之后，只有它还记着这一件是发货还是退货。
        businessType: orphan.businessType,
      );

      if (outcome.succeeded) {
        await workspace.markFinalized(orphan.sessionId);

        // ★ T21：与正常停录那边同一条判据 —— 否则这份源分段会一直留在
        // `work/` 里，再也没人碰它。
        await workspace.discardSessionDirectory(orphan.sessionId);
      }

      outcomes.add(outcome);
    }

    return outcomes;
  }
}
