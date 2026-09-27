/// 手机端的上传发送方（M5）—— 把已收尾的录像交给电脑端。
///
/// 契约：母仓 `docs/05-上传接口形状.md`。形状那一半在 [upload_protocol]，
/// 这里管的是**怎么用**：分片、续传、退避、验签、落档。
///
/// ## 三条不可让步的
///
/// 1. **只有拿到并验过回执，才敢说这条备份好了**（不变量 I1）。
///    回执是电脑端签的 MAC，验签用的是入网时拿到的那把凭据。
/// 2. **「已有哪些分片」永远问接收方**（规格 §3.4.2 明文禁止自己记进度）。
///    本地不留任何「传到第几片」的状态 —— 留了就会与接收方漂移，
///    而漂移的表现是「永远在重传」。
/// 3. **失败必须看得见**（不变量 I3，规格 §3.4.3 ★ 来自一次真实故障：
///    原系统上传失败后进终态、永不重试，用户完全不知道数据没传上去）。
///    所以重试次数落盘、终态是显式状态、每一行都带一句「下一步干什么」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../diagnostics/app_log.dart';
import '../recording/device_identity.dart';
import '../recording/label_store.dart';
import '../recording/lan_probe.dart' show defaultHostPort;
import '../recording/manual_delete.dart' show VerifyOutcome;
import '../recording/punch_log.dart';
import '../recording/recording_index.dart';
import '../states.dart';
import 'archive_store.dart';
import 'upload_protocol.dart';

/// **重试**次数上限（首次那一次不算在里面）。
///
/// 文档 §0：「1s / 2s / 4s / 8s / 16s，上限 5 次，5 次约 31 秒」。
/// 所以连首次在内最多 6 次尝试，等待合计 1+2+4+8+16 = 31 秒。
/// 31 秒够跨过一次路由器重启；再长用户会以为它卡死了。
const defaultMaxAttempts = 5;

/// 第 [attempt] 次失败之后该等多久（[attempt] 从 1 起，即第 1 次失败等 1 秒）。
Duration backoffFor(int attempt) =>
    Duration(seconds: 1 << ((attempt - 1).clamp(0, 30)));

/// `GET /api/v1/health` 的答复。
class HostHealth {
  const HostHealth({required this.service, required this.apiVersion, required this.deviceName});

  final String service;
  final int apiVersion;
  final String deviceName;

  /// 是不是我们认得的那台电脑端。
  ///
  /// ⚠️ 这条判定是 `lan_probe.dart` 里那段自认的债的答复：旧判据是
  /// 「这端口上有 HTTP 响应」，同端口任何一个别的服务都会被当成电脑端在线。
  bool get isVidLog => service == 'vidlog-desktop';
}

/// 一次上传的结局。
enum UploadOutcomeKind {
  /// 已归档 —— 收到了**验过签**的回执。
  archived,

  /// 这一趟不用管它（已归档、还在退避期、或者已经到终态等用户处理）。
  skipped,

  /// 这次没成，但还会再试（退避期已记下）。
  retryLater,

  /// 到终态了 —— 用户在界面上要看得到，并且能手动重试。
  failed,
}

class UploadOutcome {
  const UploadOutcome({
    required this.evidenceId,
    required this.kind,
    required this.record,
    this.message,
  });

  final String evidenceId;
  final UploadOutcomeKind kind;
  final ArchiveRecord record;

  /// 给用户的一句话。**说得出下一步的必须说出来**（文档 §3）。
  final String? message;
}

/// 跑完一趟队列的结果。
class UploadPass {
  const UploadPass({required this.outcomes, this.nextRetryAt});

  final List<UploadOutcome> outcomes;

  /// 队列里最早的一个「下次该重试的时刻」。
  ///
  /// 界面拿它排一个定时器 —— 没有它，一条撞上退避期的录像会**永远停在退避期**：
  /// 没有任何东西会再来叫一次队列。这正是「一个改了没反应的开关」的另一种长相。
  final DateTime? nextRetryAt;

  int get archivedCount => outcomes.where((o) => o.kind == UploadOutcomeKind.archived).length;
  int get failedCount => outcomes.where((o) => o.kind == UploadOutcomeKind.failed).length;
}

// ─────────────────────────────────────────────
// HTTP
// ─────────────────────────────────────────────

/// 一条分片清单。
class ProbeResult {
  const ProbeResult({required this.chunkSize, required this.chunkCount, required this.have});

  /// ⚠️ **接收方说了算。** 与本地的不一致就按它重切（文档 §0）。
  final int chunkSize;
  final int chunkCount;
  final List<int> have;
}

class CommitResult {
  const CommitResult({required this.receipt, required this.signature});

  final Receipt receipt;
  final String signature;
}

/// 电脑端上传接口的客户端。**一次一个请求，不做连接复用** ——
/// 一次上传最多几十个请求，而连接池带来的那点收益抵不上多一份状态。
class UploadClient {
  UploadClient({
    required this.address,
    this.port = defaultHostPort,
    this.credential = '',
    HttpClient Function()? httpFactory,
    this.connectTimeout = const Duration(seconds: 3),
    this.chunkTimeout = const Duration(seconds: 30),
    this.commitTimeout = const Duration(seconds: 60),
  }) : _httpFactory = httpFactory ?? HttpClient.new;

  final String address;
  final int port;

  /// 设备凭据。空 = 还没入网 —— 除健康检查与入网本身，别的都会 401。
  final String credential;

  final HttpClient Function() _httpFactory;
  final Duration connectTimeout;

  /// 单片超时。4 MiB 在局域网上是秒级，30 秒是给小水管留的余量。
  final Duration chunkTimeout;

  /// 提交超时。⚠️ 比别处长得多：接收方在这一次请求里要**逐片校验 + 拼装 +
  /// 整文件哈希 + 用 FFmpeg 真解一遍**，慢的是它，不是网络。
  final Duration commitTimeout;

  Uri _uri(String path) => Uri.parse('http://$address:$port/api/v1/$path');

  Future<HostHealth> health() async {
    final json = await _send('GET', 'health', timeout: connectTimeout);
    return HostHealth(
      service: (json['service'] as String?) ?? '',
      apiVersion: ((json['apiVersion'] as num?) ?? 0).toInt(),
      deviceName: (json['deviceName'] as String?) ?? '',
    );
  }

  /// 入网第一步：报上「我来了」，并**顺带问批没批**（规格 §3.4.5）。
  ///
  /// [token] 是**电脑端屏幕上那张二维码里的一串**（`EnrollQrPayload.token`）——
  /// 用户不再手输任何东西。
  ///
  /// ⚠️ **手机轮询的是这个接口，不是 [enrollClaim]**。它**只报警不发货**
  /// （一个字节的凭据都不产出），所以「我还在等」的那几轮反复调它没有副作用。
  /// 合成一个的话，每轮轮询都在调一个会发货的接口。
  ///
  /// 返回 [EnrollStatus.pending] 就继续调，直到 [EnrollStatus.approved]（去领凭据）
  /// 或 [EnrollStatus.rejected]（停住并告诉用户）。
  Future<EnrollOutcome> enrollRequest({
    required String deviceId,
    required String deviceName,
    required String token,
  }) async {
    final json = await _send(
      'POST',
      'enroll/request',
      body: {'deviceId': deviceId, 'deviceName': deviceName, 'token': token},
      authenticated: false,
    );

    return _outcomeOf(json);
  }

  /// 请求改名（规格 §3.4.5 ③：**二次改名要电脑端同意才能改**）。
  ///
  /// ⚠️ 它**要凭据**（`authenticated: true`）：改名发生在入网**之后**，那时手机
  /// 手上只有凭据。电脑端那边用凭据反查设备 —— 报文里**不送 deviceId**，
  /// 因为「身份从凭据来」，送 id 的话任何一台已入网设备都能改别人的名字。
  ///
  /// ⚠️ 手机**轮询**这个接口（与 [enrollRequest] 同形）：报上新名字，
  /// 顺便问批没批。三个状态都可能回来。
  Future<EnrollOutcome> requestRename({required String deviceName}) async {
    final json = await _send(
      'POST',
      'enroll/rename',
      body: {'deviceName': deviceName},
      authenticated: true,
    );

    return _outcomeOf(json);
  }

  /// 入网第二步：用**同一个令牌**换凭据。**只发一次** —— 领走之后整张码即作废。
  ///
  /// ⚠️ 「还没批」和「被拒了」**不是错误**：电脑端回的是 200 + `status`，
  /// 所以这里返回 [EnrollOutcome] 而不是抛（`05-上传接口形状.md` §2.3）。
  /// 回 4xx 的只有两种真错误：令牌不对（`bad_token`）、屏幕上那张码没了
  /// （`no_pending_request`）—— 那两种由 [_send] 变成 [UploadFailure] 抛出去。
  Future<EnrollOutcome> enrollClaim({
    required String deviceId,
    required String token,
  }) async {
    final json = await _send(
      'POST',
      'enroll/claim',
      body: {'deviceId': deviceId, 'token': token},
      authenticated: false,
    );

    return _outcomeOf(json);
  }

  /// 200 的报文 → 处置。
  ///
  /// **有凭据就等于批准**（`EnrollCredentialPayload` 只带 `credential`、不带 `status`），
  /// 没有凭据的报文里必有 `status`。两条都读，就不必让调用方知道它调的是哪一步。
  static EnrollOutcome _outcomeOf(Map<String, Object?> json) {
    final credential = (json['credential'] as String?)?.trim() ?? '';
    if (credential.isNotEmpty) {
      return EnrollOutcome(EnrollStatus.approved, credential: credential);
    }

    final raw = (json['status'] as String?)?.trim() ?? '';
    final status = EnrollStatus.tryParse(raw);
    if (status == null) {
      // 认不出的状态**不当成 pending** —— 那会让手机对着一个不会变的答复
      // 一直转下去，而用户看到的只是「连接中…」。
      throw UploadFailure(UploadErrorCodes.badRequest, detail: '电脑端回了个认不出的入网状态：$raw');
    }

    return EnrollOutcome(status);
  }

  /// 从电脑端**取回**某一段（规格 §3.7：「只在归档层就先取回本地，再分享」）。
  ///
  /// 走的是回放页那个 `/media/{evidenceId}` —— 它本来就在（网页回放用它），
  /// 所以**不必另开一个下载接口**。
  ///
  /// ⚠️ 那段录像是什么样，取回来就是什么样：**不转码、不压缩**（§3.7.1）。
  Future<void> downloadEvidence(String evidenceId, String targetPath) async {
    final client = _httpFactory();
    client.connectionTimeout = connectTimeout;

    try {
      final uri = Uri.parse(
          'http://$address:$port/media/${Uri.encodeComponent(evidenceId)}');

      final request = await client.getUrl(uri).timeout(connectTimeout);
      final response = await request.close().timeout(commitTimeout);

      if (response.statusCode != 200) {
        throw UploadFailure(
          UploadErrorCodes.badRequest,
          detail: '电脑端回了一个 ${response.statusCode} —— 那一段可能已经不在电脑上了',
        );
      }

      final file = File(targetPath);
      await file.parent.create(recursive: true);

      // 先写临时名再改名：取到一半断网留下的半截文件如果直接叫 .mp4，
      // 界面会把它当成一段完整的录像（而那正是要防的）。
      final temporary = '$targetPath.part';

      final sink = File(temporary).openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();

      await File(temporary).rename(targetPath);
    } finally {
      client.close(force: true);
    }
  }

  /// 回查归档层：这一份还在不在（规格 §3.5.4 / §3.5.6③）。
  ///
  /// 手动删除的**前置闸**：不能只看手机上那条「已备份」的记录 ——
  /// 用户可能已经把电脑端那份删掉了。
  ///
  /// ⚠️ **「查不了」与「不存在」是两件事**（`05-上传接口形状.md` §2.7）：
  /// 服务端把它们分成两个字段回，因为**两者都导致不删**，但说给用户的是两句话。
  /// 这里不把异常折成「不在」—— 抛出去，由调用方按「查不了」处理。
  Future<VerifyOutcome> verifyLocation(String location) async {
    final json = await _send('POST', 'archive/verify', body: {'location': location});

    return VerifyOutcome(
      exists: json['exists'] == true,
      couldNotVerify: json['couldNotVerify'] == true,
      reason: json['reason'] as String?,
    );
  }

  Future<ProbeResult> probe({
    required String evidenceId,
    required int chunkCount,
    required int totalBytes,
    required String contentHash,
  }) async {
    final json = await _send('POST', 'upload/probe', body: {
      'evidenceId': evidenceId,
      'chunkCount': chunkCount,
      'totalBytes': totalBytes,
      'contentHash': contentHash,
    });

    return ProbeResult(
      chunkSize: ((json['chunkSize'] as num?) ?? uploadChunkSize).toInt(),
      chunkCount: ((json['chunkCount'] as num?) ?? chunkCount).toInt(),
      have: ((json['have'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
    );
  }

  /// 传一片。**请求体是裸字节**，不是 JSON（文档 §2.5）。返回接收方算出的哈希。
  Future<String> uploadChunk(String evidenceId, int index, Uint8List bytes) async {
    final json = await _send(
      'POST',
      'upload/chunk/$evidenceId/$index',
      raw: bytes,
      timeout: chunkTimeout,
    );

    return (json['sha256'] as String?) ?? '';
  }

  Future<CommitResult> commit(Map<String, Object?> body) async {
    final json = await _send('POST', 'upload/commit', body: body, timeout: commitTimeout);
    final receipt = json['receipt'];

    if (receipt is! Map<String, Object?>) {
      throw const UploadFailure(UploadErrorCodes.badRequest, detail: '提交成功但没带回执');
    }

    return CommitResult(
      receipt: Receipt.fromJson(receipt),
      signature: (json['signature'] as String?) ?? '',
    );
  }

  /// 发一个请求并解出 JSON。**所有失败都变成 [UploadFailure]** ——
  /// 调用方只需要看协议码，不必去认 SocketException / TimeoutException /
  /// HttpException 这一堆。
  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Uint8List? raw,
    Duration? timeout,
    bool authenticated = true,
  }) async {
    final client = _httpFactory()..connectionTimeout = connectTimeout;
    final limit = timeout ?? commitTimeout;
    final startedAt = DateTime.now();

    try {
      final request = method == 'GET'
          ? await client.getUrl(_uri(path)).timeout(limit)
          : await client.postUrl(_uri(path)).timeout(limit);

      if (authenticated && credential.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $credential');
      }

      if (raw != null) {
        request.headers.contentType = ContentType.binary;
        request.contentLength = raw.length;
        request.add(raw);
      } else if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
        request.contentLength = encoded.length;
        request.add(encoded);
      }

      final response = await request.close().timeout(limit);
      final text = await utf8.decoder.bind(response).join().timeout(limit);

      if (response.statusCode == HttpStatus.ok) {
        _trace(method, path, response.statusCode, startedAt);
        return _decode(text, response.statusCode);
      }

      throw _failureFrom(response.statusCode, text);
    } on UploadFailure catch (failure) {
      // 失败**一定要看得见**：一次上传有几十个请求，只有失败那几条能定位问题。
      AppLog.instance.warn('上传', '${failure.code}（$method /$path）', data: {
        'status': failure.status,
        '耗时ms': _elapsed(startedAt),
        if (failure.detail != null) 'detail': failure.detail,
      });

      rethrow;
    } on Object catch (error) {
      // 拒绝连接 / 超时 / DNS 失败 / 半路断开 —— 对用户都是同一件事：连不上。
      // ⚠️ 归成**可重试**：这一类比任何别的都更可能只是「电脑端刚好没开」。
      AppLog.instance.warn('上传', '连不上电脑端（$method /$path）', data: {
        '耗时ms': _elapsed(startedAt),
        '错误': '$error',
      });

      throw UploadFailure(UploadErrorCodes.network, detail: '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 成功那一条记 **debug**：一次上传几十个请求，全都记 info 的话
  /// 正常流量会把日志淹掉（而淹掉的日志等于没有日志）。
  void _trace(String method, String path, int status, DateTime startedAt) =>
      AppLog.instance.debug('上传', '$method /$path → $status', data: {
        'status': status,
        '耗时ms': _elapsed(startedAt),
      });

  static int _elapsed(DateTime startedAt) =>
      DateTime.now().difference(startedAt).inMilliseconds;

  // ⚠️ **这个类里绝不把 `credential` 写进日志**：它在 `Authorization` 头上，
  // 而诊断包是把日志整个发回去的。上面那几条只记方法、路径、状态与耗时 ——
  // 路径里也没有密钥（入网那两个接口的令牌在**报文体**里，同样不记）。

  Map<String, Object?> _decode(String text, int status) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) return decoded;
    } on Object {
      // 落到下面。
    }

    throw UploadFailure(UploadErrorCodes.server, detail: '电脑端回的不是 JSON', status: status);
  }

  /// 错误响应 → [UploadFailure]。**优先看报文里的协议码** ——
  /// 那是接收方明确说的「为什么」，比从状态码猜准得多。
  UploadFailure _failureFrom(int status, String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        final code = (decoded['error'] as String?)?.trim() ?? '';
        if (code.isNotEmpty) {
          return UploadFailure(code, detail: decoded['detail'] as String?, status: status);
        }
      }
    } on Object {
      // 不是 JSON —— 按状态码兜底。
    }

    return switch (status) {
      HttpStatus.unauthorized => UploadFailure(UploadErrorCodes.badCredential, status: status),
      HttpStatus.notFound => UploadFailure(UploadErrorCodes.notFound, status: status),
      >= 500 => UploadFailure(UploadErrorCodes.server, status: status),
      _ => UploadFailure(UploadErrorCodes.badRequest, status: status),
    };
  }
}

// ─────────────────────────────────────────────
// 分片计划
// ─────────────────────────────────────────────

/// 一片的落点与指纹。
class PlannedChunk {
  const PlannedChunk({required this.index, required this.start, required this.end, required this.sha256});

  final int index;
  final int start;
  final int end;

  /// 64 位小写十六进制。
  final String sha256;

  int get length => end - start;
}

/// 一次上传的分片计划。
///
/// ## 为什么不把分片缓存在内存里
///
/// 计划里只有指纹与区间，字节**每次现读**。一条 30 分钟的录像切出来有几十片、
/// 几百 MB，全留在内存里在手机上会被系统直接杀掉 —— 而那发生在**上传途中**，
/// 比慢一点糟得多。读两遍（一遍算哈希、一遍发出去）在闪存上是毫秒级的事，
/// 而操作系统还会把刚读过的那段留在页缓存里。
class ChunkPlan {
  const ChunkPlan({required this.chunkSize, required this.totalBytes, required this.chunks});

  final int chunkSize;
  final int totalBytes;
  final List<PlannedChunk> chunks;

  int get chunkCount => chunks.length;
  List<String> get hashes => chunks.map((c) => c.sha256).toList();
}

/// 按固定分片大小切开并逐片算哈希。
///
/// ⚠️ 分片算法必须与电脑端 `UploadReceiver.ExpectedChunkLength` **逐字一致**
/// （固定切片，偏移 = `index * chunkSize`）。两边算得不一样的表现是：
/// 接收方永远报「这一片没有」，于是**每次续传都从头开始**，不报错。
Future<ChunkPlan> planChunks(String path, int chunkSize) async {
  final total = await File(path).length();
  final count = chunkCountFor(total, chunkSize);
  final chunks = <PlannedChunk>[];

  for (var i = 0; i < count; i++) {
    final (start, end) = chunkRange(total, i, chunkSize);
    final digest = await sha256.bind(File(path).openRead(start, end)).first;

    chunks.add(PlannedChunk(index: i, start: start, end: end, sha256: digest.toString()));
  }

  return ChunkPlan(chunkSize: chunkSize, totalBytes: total, chunks: chunks);
}

// ─────────────────────────────────────────────
// 编排
// ─────────────────────────────────────────────

/// 把本机已收尾的录像送上电脑端。
class Uploader {
  Uploader({
    required this.rootPath,
    required this.identity,
    required this.index,
    required this.punchLog,
    required this.labels,
    required this.archive,
    required this.client,
    this.chunkSize = uploadChunkSize,
    this.maxAttempts = defaultMaxAttempts,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 本机数据根目录。索引里的 `location` 相对它。
  final String rootPath;

  final DeviceIdentity identity;
  final RecordingIndex index;
  final PunchLog punchLog;
  final LabelStore labels;
  final ArchiveStore archive;
  final UploadClient client;

  /// 第一次探问时用的分片大小。**权威在接收方**（文档 §0）——
  /// 它对不上就会按接收方回报的重切重探。可注入是为了不必在测试里
  /// 真切 4 MiB 的片。
  final int chunkSize;

  final int maxAttempts;
  final DateTime Function() _now;

  /// 跑一趟队列。
  ///
  /// **不等退避**：撞上退避期的条目直接跳过，把「最早下次重试时刻」回报给界面。
  /// 在这里 `await Future.delayed(16s)` 会把整页卡住 —— 而这是一趟
  /// 用户点了按钮就在等的操作。
  Future<UploadPass> runOnce({bool manual = false}) async {
    final records = await archive.loadAll();
    final entries = await _latestEntries();

    final outcomes = <UploadOutcome>[];
    DateTime? nextRetryAt;

    for (final entry in entries) {
      final record = records[entry.evidenceId];

      final outcome = await upload(entry, record: record, manual: manual);
      outcomes.add(outcome);

      final next = outcome.record.nextRetryAt;
      if (outcome.kind == UploadOutcomeKind.retryLater && next != null) {
        if (nextRetryAt == null || next.isBefore(nextRetryAt)) nextRetryAt = next;
      }
    }

    // 一趟队列的进出各一条。**一趟一条**，不是一条录像一条 ——
    // 队列里几十条时逐条记 info，日志会被正常流量淹掉。
    AppLog.instance.info('上传', '备份队列跑完', data: {
      'manual': manual,
      '待传条数': entries.length,
      '已归档': outcomes.where((o) => o.kind == UploadOutcomeKind.archived).length,
      '还会再试': outcomes.where((o) => o.kind == UploadOutcomeKind.retryLater).length,
      '已失败': outcomes.where((o) => o.kind == UploadOutcomeKind.failed).length,
    });

    return UploadPass(outcomes: outcomes, nextRetryAt: nextRetryAt);
  }

  /// 上传一条。已经归档的直接返回，不会重复传。
  ///
  /// [manual] = 用户点了「重试」：**计数清零**、状态回待传，并忽略退避期。
  /// 规格 §3.4.3 要的正是这个入口 —— 没有它，一条耗尽重试的录像就再也救不回来了。
  Future<UploadOutcome> upload(
    RecordingEntry entry, {
    ArchiveRecord? record,
    bool manual = false,
  }) async {
    // 每次都要重新读一遍：`record` 可能是几秒前的快照，而这一趟里
    // 别的调用（或另一个界面）可能已经把它推进了。
    var current = await archive.find(entry.evidenceId) ?? record ?? _fresh(entry.evidenceId);

    if (manual) {
      current = current.copyWith(
        state: UploadState.pending,
        attemptCount: 0,
        clearRetry: true,
        clearError: true,
      );
    }

    if (current.isArchived) {
      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: UploadOutcomeKind.skipped,
        record: current,
      );
    }

    // 终态：用户没让重试就不要动它。**这是「有限次」真正落地的地方** ——
    // 少了这一句，一条永远传不上去的录像会让手机一直重试下去，
    // 而界面上什么都看不出来。
    if (!manual && current.state == UploadState.failed) {
      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: UploadOutcomeKind.failed,
        record: current,
        message: current.lastErrorDetail,
      );
    }

    // 退避期没到就跳过。**不在这里等**（见 [runOnce]）。
    final retryAt = current.nextRetryAt;
    if (!manual && retryAt != null && retryAt.isAfter(_now())) {
      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: UploadOutcomeKind.retryLater,
        record: current,
      );
    }

    if (identity.credential.isEmpty) {
      final unsigned = current.copyWith(
        state: UploadState.failed,
        lastError: UploadErrorCodes.badCredential,
        lastErrorDetail: '这台手机还没有配对电脑端。',
        clearRetry: true,
      );
      await archive.record(unsigned);
      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: UploadOutcomeKind.failed,
        record: unsigned,
        message: unsigned.lastErrorDetail,
      );
    }

    final path = '$rootPath/${entry.location.value}';
    if (!await File(path).exists()) {
      // 归档回查失败在手机侧的近亲：**本地那份没了**。不删任何东西，
      // 也不能报成功 —— 报成功就等于承认「备份好了」而这没有依据。
      final missing = current.copyWith(
        state: UploadState.failed,
        lastError: UploadErrorCodes.badRequest,
        lastErrorDetail: '手机上的原文件找不到了：${entry.location.value}',
        clearRetry: true,
      );
      await archive.record(missing);
      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: UploadOutcomeKind.failed,
        record: missing,
        message: missing.lastErrorDetail,
      );
    }

    await archive.record(current.copyWith(state: UploadState.uploading));

    try {
      final receipt = await _transfer(entry, path);
      final done = current.copyWith(
        state: UploadState.archived,
        attemptCount: current.attemptCount + 1,
        archivedAt: _now(),
        timeAnchor: receipt.timeAnchor,
        location: receipt.location,
        receiverDeviceName: receipt.receiverDeviceName,
        clearRetry: true,
        clearError: true,
      );
      await archive.record(done);

      // 一条录像走完收尾 → 传上去 → 验过回执，是**要留痕的里程碑**：
      // 「这条到底备份好了没有」事后只有这一条能回答。
      AppLog.instance.info('上传', '一条录像已归档', data: {
        'evidenceId': entry.evidenceId,
        '单号': entry.waybill.value,
        '电脑端': done.receiverDeviceName,
      });

      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: UploadOutcomeKind.archived,
        record: done,
      );
    } on UploadFailure catch (failure) {
      final attempt = current.attemptCount + 1;

      // 不可重试的（含「要重新入网」「电脑端太旧」）直接进终态。
      // ⚠️ 退避重试一条**内容对不上**的录像，重试多少次结果都一样 ——
      // 那只是在拖 31 秒之后给出同一个答案。
      final terminal = !failure.isRetryable || attempt > maxAttempts;

      // ⚠️ 「试了 N 次」只在**试完 N 次**的时候说。对一条本来就不该重试的
      // 失败（内容的对不上、凭据不认了）这么说，用户会以为它在努力。
      final detail = terminal && failure.isRetryable
          ? '试了 $attempt 次都没成功。${failure.userHint}'
          : failure.userHint;

      final next = current.copyWith(
        state: terminal ? UploadState.failed : UploadState.backoff,
        attemptCount: attempt,
        nextRetryAt: terminal ? null : _now().add(backoffFor(attempt)),
        lastError: failure.code,
        lastErrorDetail: detail,
        clearRetry: terminal,
      );
      await archive.record(next);

      // **到顶变失败**那一条是 I3 的核心（规格 §3.4.3 ★ 来自一次真实故障：
      // 原系统上传失败后进终态、永不重试，用户完全不知道数据没传上去）。
      // 退避中的那些不记 —— 它们还会自己再试，记了只是噪声。
      if (terminal) {
        AppLog.instance.error('上传', '这一条传不上去了', data: {
          'evidenceId': entry.evidenceId,
          '单号': entry.waybill.value,
          '码': failure.code,
          '试了几次': attempt,
        });
      }

      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: terminal ? UploadOutcomeKind.failed : UploadOutcomeKind.retryLater,
        record: next,
        message: detail,
      );
    } on Object catch (error) {
      // 走到这里的是**没预料到**的错误（解析不了的时间、磁盘坏了……）。
      // 归成可重试而不是吞掉：吞掉的话这一条会永远停在「上传中」。
      final attempt = current.attemptCount + 1;
      final terminal = attempt > maxAttempts;

      final next = current.copyWith(
        state: terminal ? UploadState.failed : UploadState.backoff,
        attemptCount: attempt,
        nextRetryAt: terminal ? null : _now().add(backoffFor(attempt)),
        lastError: UploadErrorCodes.badRequest,
        lastErrorDetail: '上传时出错：$error',
        clearRetry: terminal,
      );
      await archive.record(next);

      return UploadOutcome(
        evidenceId: entry.evidenceId,
        kind: terminal ? UploadOutcomeKind.failed : UploadOutcomeKind.retryLater,
        record: next,
        message: next.lastErrorDetail,
      );
    }
  }

  /// 探 → 传缺的 → 提交 → 验签。**只有验签通过才返回**。
  Future<Receipt> _transfer(RecordingEntry entry, String path) async {
    final evidenceId = entry.evidenceId;
    final sequence = sequenceFromEvidenceId(evidenceId);

    if (sequence < 0) {
      // evidenceId 是在收尾时按 `<会话>-<三位序号>` 拼出来的，切不出来说明
      // 索引被人改过。**不猜一个序号填上去** —— 序号决定归档文件名，
      // 猜错了不会报错，只会让文件名与证据 id 对不上。
      throw const UploadFailure(
        UploadErrorCodes.evidenceMismatch,
        detail: '索引里的证据编号不合规',
      );
    }

    var plan = await planChunks(path, chunkSize);

    var probe = await client.probe(
      evidenceId: evidenceId,
      chunkCount: plan.chunkCount,
      totalBytes: plan.totalBytes,
      contentHash: entry.contentHash.value,
    );

    // 分片大小由接收方定（文档 §0）。对不上就按它的重切、重探一次 ——
    // 「不报错、不中断」，见 §2.4。第一份 `have` 作废。
    if (probe.chunkSize != plan.chunkSize && probe.chunkSize > 0) {
      plan = await planChunks(path, probe.chunkSize);
      probe = await client.probe(
        evidenceId: evidenceId,
        chunkCount: plan.chunkCount,
        totalBytes: plan.totalBytes,
        contentHash: entry.contentHash.value,
      );
    }

    final have = probe.have.toSet();

    for (final chunk in plan.chunks) {
      // ⚠️ 只信接收方报的 `have`，本地不留进度（规格 §3.4.2 明文禁止）。
      if (have.contains(chunk.index)) continue;

      final accepted = await client.uploadChunk(evidenceId, chunk.index, await _readRange(path, chunk));

      // 接收方算出来的这一片哈希与我算的不一样 —— 传过去的字节在途中变了，
      // 或者两端的哈希算法不一致。**当场停**：继续传下去只会把一份
      // 内容对不上的东西拼起来，而接收方最后会以 `hash_mismatch` 拒掉，
      // 那时报错的地方离真正的原因已经很远了。
      if (accepted.isNotEmpty && accepted != chunk.sha256) {
        throw UploadFailure(
          UploadErrorCodes.hashMismatch,
          detail: '第 ${chunk.index} 片在途中变了',
        );
      }
    }

    final result = await client.commit({
      'evidenceId': evidenceId,
      'sessionId': entry.sessionId,
      'sequence': sequence,
      'waybill': entry.waybill.value,
      'startedAt': formatUtcIso7(entry.startedAt),
      'endedAt': formatUtcIso7(entry.endedAt),
      // 全链路只有裸的 64 位小写十六进制这一种形态（文档 §2.7）。
      'contentHash': entry.contentHash.value,
      'sourceDeviceId': _sourceDeviceId(entry),
      'chunkCount': plan.chunkCount,
      'chunkHashes': plan.hashes,
      'punches': await _punches(entry),
      'labels': await _labels(entry),
    });

    // ⚠️ **验签必须在标记「已归档」之前。** 收下一个没验过的回执就当作备份成功，
    // 等于把「电脑端说它收到了」交给局域网上的任何一个人去说。
    if (!verifyReceipt(client.credential, result.receipt, result.signature)) {
      throw const UploadFailure(
        UploadErrorCodes.badSignature,
        detail: '回执的签名对不上 —— 它不是这台电脑端签的，或内容被改过',
      );
    }

    // 回执里的证据编号必须是我要传的那一条。签名只保证「这份回执没被改」，
    // 不保证「它是关于我这条录像的」。
    if (result.receipt.evidenceId != evidenceId) {
      throw UploadFailure(
        UploadErrorCodes.evidenceMismatch,
        detail: '回执说的不是这一条：${result.receipt.evidenceId}',
      );
    }

    return result.receipt;
  }

  /// 现读这一片的字节。见 [ChunkPlan] 的说明：不缓存分片。
  Future<Uint8List> _readRange(String path, PlannedChunk chunk) async {
    final builder = BytesBuilder(copy: false);
    await for (final block in File(path).openRead(chunk.start, chunk.end)) {
      builder.add(block);
    }
    return builder.takeBytes();
  }

  /// 报文里的设备身份。
  ///
  /// 接收方**不拿它当身份用**（身份从凭据来），它只用来比对，对不上就拒。
  /// 老索引行（M5 之前写的）可能没有这个字段，那就用本机当前的标识 ——
  /// 索引是本机自己的，里面的每一条都录在这台机器上，这个替换是实话。
  String _sourceDeviceId(RecordingEntry entry) =>
      entry.sourceDeviceId.trim().isEmpty ? identity.deviceId : entry.sourceDeviceId;

  /// 这一次会话的打点。字段名在报文里是 camelCase，落盘是 PascalCase ——
  /// 这里就是文档 §2.6 说的「两端都要转一次名」的那一次。
  Future<List<Map<String, Object?>>> _punches(RecordingEntry entry) async {
    final punches = await punchLog.forSession(entry.sessionId);

    return [
      for (final punch in punches)
        {
          'punchId': punch.punchId,
          'sessionId': punch.sessionId,
          'waybillNumber': punch.waybill.value,
          'punchedAt': formatUtcIso7(punch.punchedAt),
          'monotonicOffsetMilliseconds': punch.monotonicOffsetMilliseconds,
          'source': punch.source.wire,
        },
    ];
  }

  Future<List<Map<String, Object?>>> _labels(RecordingEntry entry) async {
    final labels = await this.labels.forEvidence(entry.evidenceId);

    return [
      for (final label in labels)
        {
          'evidenceId': label.evidenceId,
          'key': label.key,
          'value': label.value,
          'updatedAt': formatUtcIso7(label.updatedAt),
        },
    ];
  }

  /// 索引里同一 `evidenceId` 的最后一行。
  ///
  /// 索引是追加写且读取时不去重的，重放/重收尾可能留下多行；后写的才是当前事实。
  Future<List<RecordingEntry>> _latestEntries() async {
    final latest = <String, RecordingEntry>{};
    for (final entry in await index.loadAll()) {
      latest[entry.evidenceId] = entry;
    }
    return latest.values.toList();
  }

  ArchiveRecord _fresh(String evidenceId) =>
      ArchiveRecord(evidenceId: evidenceId, state: UploadState.pending);
}

/// 从 `evidenceId` 里切回三位序号。切不出来返回 -1。
///
/// `evidenceId` 的形态是 `<sessionId>-<三位序号>`，而 `sessionId` 自己带 `-`，
/// 所以从**最后**一个横线切，并且要求尾段正好是三位数字 ——
/// 与 `sessionIdFromEvidenceId` 用的是同一套判据，两者必须同时改。
int sequenceFromEvidenceId(String evidenceId) {
  final dash = evidenceId.lastIndexOf('-');
  if (dash <= 0) return -1;

  final tail = evidenceId.substring(dash + 1);
  if (tail.length != 3) return -1;

  return int.tryParse(tail) ?? -1;
}
