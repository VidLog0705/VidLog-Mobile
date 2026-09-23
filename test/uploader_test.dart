import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/primitives.dart';
import 'package:vidlog_mobile/recording/device_identity.dart';
import 'package:vidlog_mobile/recording/label_store.dart';
import 'package:vidlog_mobile/recording/punch_log.dart';
import 'package:vidlog_mobile/recording/recording_index.dart';
import 'package:vidlog_mobile/states.dart';
import 'package:vidlog_mobile/upload/archive_store.dart';
import 'package:vidlog_mobile/upload/upload_protocol.dart';
import 'package:vidlog_mobile/upload/uploader.dart';

/// 上传发送方的端到端测试 —— 对着一个**真的电脑端**跑。
///
/// 仿照电脑端 `PlaybackServerTests.cs` 立下的先例：「起真 HttpListener 打真
/// HTTP 请求 —— 路由、Range、JSON 这些只有真跑一遍才知道对不对，mock 掉就什么都没验。」
///
/// 上传这条链路上「mock 掉就什么都没验」的东西比回放那边还多：分片的边界算术、
/// 续传的 `have` 怎么算、规范串拼出来长什么样、签名用哪把密钥、报文里字段叫什么。
/// **这些在两端各自的单元测试里都是绿的**，只有一次真跑才能对上。
void main() {
  group('走通一遍', () {
    test('收到验过签的回执才进已归档_时间锚来自回执', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      final pass = await h.uploader.runOnce();

      expect(pass.outcomes.single.kind, UploadOutcomeKind.archived);
      expect(pass.archivedCount, 1);

      final record = (await h.archive.find(evidenceId))!;
      expect(record.state, UploadState.archived);
      expect(record.isArchived, isTrue);

      // ⚠️ 保留期从**接收方**的时刻起算，不是本机的钟（规格 §3.6.4）。
      expect(record.timeAnchor!.toUtc(),
          DateTime.utc(2026, 9, 23, 2, 31, 52, 117));
      expect(record.receiverDeviceName, '打包间-左');
      expect(record.location, '2026/09/23/SF1000000001/sess-1_000.mp4');

      // 成功之后不该留着「下次重试」—— 留着的话界面上会一直挂着一句
      // 永远不会发生的「下次重试」。
      expect(record.nextRetryAt, isNull);
      expect(record.lastError, isNull);
    });

    test('已经归档的不会再传一次', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      await h.uploader.runOnce();
      final after = h.fake.requestCount;
      expect(after, greaterThan(0));

      final second = await h.uploader.runOnce();

      expect(second.outcomes.single.kind, UploadOutcomeKind.skipped);
      // 一个包都没再发 —— 已经备份好的东西不该再占网络。
      expect(h.fake.requestCount, after);
    });

    test('打点与标签随提交一起交给电脑端', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      await h.uploader.runOnce();

      final body = h.fake.lastCommit!;
      expect(body['sessionId'], sessionId);
      expect(body['sequence'], 0);
      expect(body['waybill'], waybill);
      expect(body['contentHash'], h.payloadHash);
      expect(body['chunkHashes'], hasLength(3));
      // 报文的设备标识来自索引，不来自「本机现在叫什么」——
      // 老索引行没有这个字段时才回退到本机标识。
      expect(body['sourceDeviceId'], deviceId);
      // 时间在报文里与规范串是**同一套形态**：七位小数 + `+00:00`。
      expect(body['startedAt'], '2026-09-23T02:00:00.0000000+00:00');
      expect(body['endedAt'], '2026-09-23T02:05:00.0000000+00:00');

      expect((body['punches']! as List).single, {
        'punchId': 'p-1',
        'sessionId': sessionId,
        'waybillNumber': waybill,
        'punchedAt': '2026-09-23T02:00:01.2000000+00:00',
        'monotonicOffsetMilliseconds': 1200,
        'source': 'KeyboardScanner',
      });

      // 不带标签的话，电脑端网页上这一条会显示成 `unknown`（发货 / 退货分不出来）。
      expect((body['labels']! as List).single, {
        'evidenceId': evidenceId,
        'key': 'business-type',
        'value': 'outbound',
        'updatedAt': '2026-09-23T02:00:00.0000000+00:00',
      });
    });

    test('索引里同一条录像的多行_以最后一行为准', () async {
      // 索引是追加写且读取时不去重的，重放 / 重收尾都会留下多行。
      // 先写一行**落点已经失效的旧行**，再写当前那行。
      final h = await newHarness(staleRowFirst: true);
      addTearDown(h.dispose);

      await h.uploader.runOnce();

      // 旧行胜出的话会去找一个不存在的文件、当场失败 —— 所以「传上去了」
      // 本身就证明了是后面那一行赢。
      expect((await h.archive.find(evidenceId))!.isArchived, isTrue);
      expect(h.fake.lastCommit!['evidenceId'], evidenceId);
    });
  });

  group('分片与续传', () {
    test('接收方已经有的分片不重传', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      // 电脑端上已经有第 0 片了（上一次传到一半断在这儿）。
      h.fake.seedChunk(evidenceId, 0, h.payload.sublist(0, 100));

      await h.uploader.runOnce();

      expect(h.fake.chunkUploads.map((c) => c.index), [1, 2]);
    });

    test('传了一半的分片不算已有_否则续传永远卡住', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      // 只收到 37 个字节就断了。判成「已有」的话，整文件哈希永远对不上，
      // 而每一次续传都会跳过这一片 —— 表现是「永远差一点」。
      h.fake.seedChunk(evidenceId, 0, h.payload.sublist(0, 37));

      await h.uploader.runOnce();

      expect(h.fake.chunkUploads.map((c) => c.index), [0, 1, 2]);
      expect((await h.archive.find(evidenceId))!.isArchived, isTrue);
    });

    test('接收方回报的分片大小不一致时_按它的重切重探', () async {
      // 本地按生产默认的 4 MiB 切（250 字节 → 1 片），电脑端说它按 100 字节切。
      final h = await newHarness(localChunkSize: uploadChunkSize, hostChunkSize: 100);
      addTearDown(h.dispose);

      await h.uploader.runOnce();

      // 探了两次：第一次的分片数按本地的算，第二次按电脑端的算。
      // 文档 §2.4 要的就是这个 ——「不报错、不中断」。
      expect(h.fake.probes, hasLength(2));
      expect(h.fake.probes.first['chunkCount'], 1);
      expect(h.fake.probes.last['chunkCount'], 3);

      // 重切之后的算术必须与电脑端一致，否则最后一片的长度对不上。
      expect(h.fake.chunkUploads.map((c) => c.length), [100, 100, 50]);
      expect((await h.archive.find(evidenceId))!.isArchived, isTrue);
    });

    test('接收方算出来的分片哈希与我算的不一样_当场停', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      // 模拟「传过去的字节在途中变了」：接收方对第 1 片报一个别的哈希。
      h.fake.corruptChunkHashAt = 1;

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.record.state, UploadState.failed);
      expect(outcome.record.lastError, UploadErrorCodes.hashMismatch);
      // 当场停：继续传只会把一份内容对不上的东西拼起来，
      // 而接收方最后会以 hash_mismatch 拒掉 —— 那时离真正的原因已经很远了。
      expect(h.fake.chunkUploads.map((c) => c.index), [0, 1]);
    });
  });

  group('回执', () {
    test('验不过签就进终态_而且不标记已归档', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      // 回执内容原样、签名换成别的。局域网上的中间人伪造一份，或者两端对
      // 规范串的理解走岔了，长的都是这个样子。
      h.fake.signatureOverride = base64UrlNoPad(List<int>.filled(32, 0xAB));

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.kind, UploadOutcomeKind.failed);
      expect(outcome.record.state, UploadState.failed);
      expect(outcome.record.isArchived, isFalse);
      expect(outcome.record.lastError, UploadErrorCodes.badSignature);
      // ⚠️ 不能只说「上传失败」—— 这一种必须让用户看见（文档 §3）。
      expect(outcome.message, contains('签名'));
      expect(outcome.message, contains('别删'));
      // 不可重试：退避重试一份**看起来被篡改**的回执毫无意义。
      expect(outcome.record.attemptCount, 1);
      expect(outcome.record.nextRetryAt, isNull);
    });

    test('签名是真的_但回执说的不是这一条_一样拒', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      // 电脑端真的签了，只是签的是**另一条**录像的编号。
      // 签名只保证「这份回执没被改」，不保证「它是关于我这条录像的」。
      h.fake.receiptEvidenceIdOverride = 'sess-9-099';

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.record.state, UploadState.failed);
      expect(outcome.record.lastError, UploadErrorCodes.evidenceMismatch);
      expect(outcome.record.isArchived, isFalse);
    });
  });

  group('失败与重试', () {
    test('连不上就走退避_次数落盘_时间到了会再试', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      h.fake.probeFailures = 1; // 只失败这一次

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.kind, UploadOutcomeKind.retryLater);
      expect(outcome.record.state, UploadState.backoff);
      expect(outcome.record.attemptCount, 1);
      // 第 1 次失败等 1 秒（文档 §0：1 / 2 / 4 / 8 / 16）。
      expect(outcome.record.nextRetryAt,
          h.clock.value.add(const Duration(seconds: 1)));

      // 退避期没到就跳过 —— 不重复打网络。
      final before = h.fake.requestCount;
      final gated = await h.uploader.runOnce();
      expect(gated.outcomes.single.kind, UploadOutcomeKind.retryLater);
      expect(h.fake.requestCount, before);

      // 钟走到点上，这一趟就真的重试了，并且成功。
      h.clock.value = outcome.record.nextRetryAt!;
      final third = await h.uploader.runOnce();

      expect(third.outcomes.single.kind, UploadOutcomeKind.archived);
      expect((await h.archive.find(evidenceId))!.attemptCount, 2);
    });

    test('退避到顶变失败_用户看得见并且不再自动重试', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      h.fake.probeFailures = 999;

      final outcome = (await _driveUntilSettled(h.uploader, h.clock)).outcomes.single;

      expect(outcome.kind, UploadOutcomeKind.failed);
      expect(outcome.record.state, UploadState.failed);
      // 连首次在内 6 次（5 次重试），与文档 §0 的算术一致。
      expect(outcome.record.attemptCount, defaultMaxAttempts + 1);
      // **有限次**的落点：到顶之后不再排下一次。
      expect(outcome.record.nextRetryAt, isNull);
      // 不变量 I3：失败要有一句能给用户看的话。
      expect(outcome.message, contains('试了 ${defaultMaxAttempts + 1} 次'));

      // 再跑一趟也不会偷偷重试。
      final before = h.fake.requestCount;
      final again = await h.uploader.runOnce();
      expect(again.outcomes.single.kind, UploadOutcomeKind.failed);
      expect(h.fake.requestCount, before);
    });

    test('重启之后重试次数还在_不会变成无限重试', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      h.fake.probeFailures = 999;
      await _driveUntilSettled(h.uploader, h.clock);

      // 「重启」= 换一个实例读同一个文件（真机上就是进程被杀）。
      // 不落盘的话每次开 App 都从零开始，「有限次」就变成了无限次。
      final reread = ArchiveStore('${h.root}/archive.jsonl');
      final record = (await reread.find(evidenceId))!;

      expect(record.state, UploadState.failed);
      expect(record.attemptCount, defaultMaxAttempts + 1);
    });

    test('手动重试清零计数_并且不等退避', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      h.fake.probeFailures = 999;
      await _driveUntilSettled(h.uploader, h.clock);

      // 用户把电脑端打开了，然后点「重试」。**不能让他再等 31 秒。**
      h.fake.probeFailures = 0;
      final retried = await h.uploader.upload(h.entry, manual: true);

      expect(retried.kind, UploadOutcomeKind.archived);
      expect((await h.archive.find(evidenceId))!.attemptCount, 1);
    });

    test('内容类的失败一次就进终态_不退避', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      h.fake.commitFailsWith = UploadErrorCodes.hashMismatch;

      final outcome = (await _driveUntilSettled(h.uploader, h.clock)).outcomes.single;

      expect(outcome.kind, UploadOutcomeKind.failed);
      // 重试一份**内容对不上**的录像，重试多少次结果都一样 ——
      // 那只是拖 31 秒之后给出同一个答案，而用户以为它在努力。
      expect(outcome.record.attemptCount, 1);
      expect(outcome.record.nextRetryAt, isNull);
    });

    test('凭据被电脑端忘了_提示里要说明重新配对', () async {
      // 电脑端那边的设备表被清了（或者换了台机器），这把凭据不再认。
      final h = await newHarness(
          hostCredential: base64UrlNoPad(List<int>.filled(32, 7)));
      addTearDown(h.dispose);

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.record.state, UploadState.failed);
      expect(outcome.record.lastError, UploadErrorCodes.badCredential);
      expect(outcome.message, contains('重新配对'));
      // 重试一份已经不被认的凭据不会有别的结果。
      expect(outcome.record.nextRetryAt, isNull);
    });

    test('电脑端太旧_提示里要说明升级', () async {
      final h = await newHarness();
      addTearDown(h.dispose);

      // 老版本电脑端根本没有这几个路由：一个**没有报文体的** 404。
      h.fake.legacyHost = true;

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.record.state, UploadState.failed);
      expect(outcome.record.lastError, UploadErrorCodes.notFound);
      expect(outcome.message, contains('升级电脑端'));
    });

    test('还没配对就一个包都不发', () async {
      final h = await newHarness(enrolled: false);
      addTearDown(h.dispose);

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.kind, UploadOutcomeKind.failed);
      expect(outcome.record.lastError, UploadErrorCodes.badCredential);
      expect(outcome.message, contains('配对'));
      // 没凭据就把包发出去，等于把电脑端的设备表当成一张谁都能写的名单。
      expect(h.fake.requestCount, 0);
    });

    test('本地原文件找不到了_不能报成功', () async {
      final h = await newHarness(writeFile: false);
      addTearDown(h.dispose);

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.kind, UploadOutcomeKind.failed);
      expect(outcome.record.isArchived, isFalse);
      expect(outcome.message, contains('找不到'));
      expect(h.fake.requestCount, 0);
    });

    test('索引里的证据编号不合规_不猜一个序号填上去', () async {
      final h = await newHarness(evidenceIdOverride: 'sess-1-x');
      addTearDown(h.dispose);

      final outcome = (await h.uploader.runOnce()).outcomes.single;

      expect(outcome.record.lastError, UploadErrorCodes.evidenceMismatch);
      // 序号决定归档文件名。猜错了不会报错，只会让文件名与证据 id 对不上。
      expect(h.fake.chunkUploads, isEmpty);
    });
  });
}

// ─────────────────────────────────────────────
// 夹具
// ─────────────────────────────────────────────

const evidenceId = 'sess-1-000';
const sessionId = 'sess-1';
const waybill = 'SF1000000001';
const deviceId = 'phone-1';
const location = '2026/09/23/SF1000000001/sess-1_000.mp4';

/// 与 `upload_protocol_test.dart` 里那条跨端向量**同一把**凭据（0x00..0x1F）。
/// 两端拿它签、验，对不上的话两边的测试至少红一边。
const testCredential = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

/// 一个**真的**电脑端：真 socket、真 HTTP、真分片校验、真签名。
class FakeDesktop {
  FakeDesktop._(this._server, this.chunkSize);

  /// 这台电脑端认哪把凭据。测试改它就是模拟「设备表被清了」。
  String hostCredential = testCredential;

  static Future<FakeDesktop> start({
    int chunkSize = 100,
    String? hostCredential,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeDesktop._(server, chunkSize);
    if (hostCredential != null) fake.hostCredential = hostCredential;
    server.listen(fake._handle);

    return fake;
  }

  final HttpServer _server;
  final int chunkSize;

  int get port => _server.port;

  /// 收过几个请求。用来问「它到底发了没有」——**验「不该发」比验「发出去了」重要**。
  int requestCount = 0;

  final List<Map<String, Object?>> probes = [];
  final List<({String evidenceId, int index, int length})> chunkUploads = [];
  Map<String, Object?>? lastCommit;

  /// 接下来这么多次 probe 一律回 503（验退避与耗尽用）。
  int probeFailures = 0;

  /// 模拟一台**版本太旧**的电脑端：路由不存在，回一个没有报文体的 404。
  bool legacyHost = false;

  /// commit 一律以这个协议码拒（验「内容类失败不退避」用）。
  String? commitFailsWith;

  /// 覆盖回执上的证据编号（签名仍然是真的）。
  String? receiptEvidenceIdOverride;

  /// 覆盖签名（回执内容仍然原样）。
  String? signatureOverride;

  /// 第几片回一个**错**的哈希（模拟传过去的字节在途中变了）。
  int? corruptChunkHashAt;

  final Map<String, Map<int, Uint8List>> _chunks = {};

  void seedChunk(String target, int index, List<int> bytes) {
    (_chunks[target] ??= {})[index] = Uint8List.fromList(bytes);
  }

  Future<void> dispose() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requestCount++;

    final path = request.uri.path;
    // 请求体一次读干净：分片是裸字节，其余是 JSON。
    final body = await _readAll(request);

    if (legacyHost) return _empty(request.response, HttpStatus.notFound);

    if (path == '/api/v1/health') {
      return _json(request.response, HttpStatus.ok, {
        'service': 'vidlog-desktop',
        'apiVersion': 1,
        'deviceName': '打包间-左',
      });
    }

    final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (auth != 'Bearer $hostCredential') {
      return _json(request.response, HttpStatus.unauthorized, {'error': 'bad_credential'});
    }

    if (path == '/api/v1/upload/probe') return _probe(request.response, body);
    if (path.startsWith('/api/v1/upload/chunk/')) {
      return _chunk(request.response, path, body);
    }
    if (path == '/api/v1/upload/commit') return _commit(request.response, body);

    return _json(request.response, HttpStatus.notFound, {'error': 'not_found'});
  }

  Future<void> _probe(HttpResponse response, Uint8List body) async {
    if (probeFailures > 0) {
      probeFailures--;
      return _empty(response, HttpStatus.serviceUnavailable);
    }

    final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    probes.add(json);

    final target = json['evidenceId']! as String;
    final total = (json['totalBytes']! as num).toInt();
    final count = chunkCountFor(total, chunkSize);
    final stored = _chunks[target] ?? const <int, Uint8List>{};

    // ⚠️ 「哪一片已经有了」的判据是**长度正好对上**，不是「这块存在」。
    // 传了一半就断了的那一片必须判成没有，否则续传会永远卡在同一个地方。
    final have = <int>[];
    for (var i = 0; i < count; i++) {
      if (stored[i]?.length == _expectedLength(total, i)) have.add(i);
    }

    return _json(response, HttpStatus.ok, {
      'chunkSize': chunkSize,
      'chunkCount': count,
      'have': have,
    });
  }

  int _expectedLength(int total, int index) {
    final start = index * chunkSize;
    if (start >= total) return 0;

    final rest = total - start;
    return rest < chunkSize ? rest : chunkSize;
  }

  Future<void> _chunk(HttpResponse response, String path, Uint8List body) async {
    final parts =
        path.substring('/api/v1/upload/chunk/'.length).split('/');
    final target = parts[0];
    final index = int.parse(parts[1]);

    chunkUploads.add((evidenceId: target, index: index, length: body.length));
    (_chunks[target] ??= {})[index] = body;

    final digest = corruptChunkHashAt == index
        ? sha256.convert(body.reversed.toList()).toString()
        : sha256.convert(body).toString();

    return _json(response, HttpStatus.ok, {'index': index, 'sha256': digest});
  }

  Future<void> _commit(HttpResponse response, Uint8List body) async {
    final json = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
    lastCommit = json;

    final target = json['evidenceId']! as String;

    if (commitFailsWith != null) {
      return _json(response, HttpStatus.conflict, {'error': commitFailsWith});
    }

    final stored = _chunks[target] ?? const <int, Uint8List>{};
    final count = (json['chunkCount']! as num).toInt();
    final assembled = BytesBuilder(copy: false);

    for (var i = 0; i < count; i++) {
      final piece = stored[i];
      if (piece == null) {
        return _json(response, HttpStatus.conflict, {'error': 'chunk_missing'});
      }
      assembled.add(piece);
    }

    if (sha256.convert(assembled.takeBytes()).toString() != json['contentHash']) {
      return _json(response, HttpStatus.conflict, {'error': 'hash_mismatch'});
    }

    final sequence = (json['sequence']! as num).toInt();
    final receipt = Receipt(
      evidenceId: receiptEvidenceIdOverride ?? target,
      contentHash: json['contentHash']! as String,
      publishedAt: DateTime.utc(2026, 9, 23, 2, 31, 52, 117),
      timeAnchor: DateTime.utc(2026, 9, 23, 2, 31, 52, 117),
      receiverDeviceId: 'host-1',
      receiverDeviceName: '打包间-左',
      location: '2026/09/23/$waybill/'
          '${json['sessionId']}_${sequence.toString().padLeft(3, '0')}.mp4',
    );

    return _json(response, HttpStatus.ok, {
      'receipt': receipt.toJson(),
      'signature': signatureOverride ?? receiptMac(hostCredential, receipt),
    });
  }

  Future<Uint8List> _readAll(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final block in request) {
      builder.add(block);
    }
    return builder.takeBytes();
  }

  Future<void> _json(HttpResponse response, int status, Object body) async {
    response.statusCode = status;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    response.write(jsonEncode(body));
    await response.close();
  }

  /// 没有报文体的响应 —— 真实世界里一个不认识这个路由的服务器就长这样。
  Future<void> _empty(HttpResponse response, int status) async {
    response.statusCode = status;
    await response.close();
  }
}

/// 可拨的钟。退避是**时间**触发的，用真 `Future.delayed` 等 31 秒
/// 只会让整套测试慢到没人愿意跑。
class Clock {
  Clock(this.value);

  DateTime value;

  void advance(Duration by) => value = value.add(by);
}

class Harness {
  Harness({
    required this.root,
    required this.fake,
    required this.archive,
    required this.uploader,
    required this.clock,
    required this.entry,
    required this.payload,
    required this.payloadHash,
  });

  final String root;
  final FakeDesktop fake;
  final ArchiveStore archive;
  final Uploader uploader;
  final Clock clock;
  final RecordingEntry entry;
  final List<int> payload;
  final String payloadHash;

  Future<void> dispose() async {
    await fake.dispose();
    await Directory(root).delete(recursive: true);
  }
}

Future<Harness> newHarness({
  int hostChunkSize = 100,
  int localChunkSize = 100,
  int maxAttempts = defaultMaxAttempts,
  bool writeFile = true,
  bool enrolled = true,
  bool staleRowFirst = false,
  String? hostCredential,
  String? evidenceIdOverride,
  List<int>? bytes,
}) async {
  final dir = await Directory.systemTemp.createTemp('vidlog-mobile-upload-');
  final root = dir.path;

  final payload = bytes ?? List<int>.generate(250, (i) => (i * 7) % 251);
  final hash = sha256.convert(payload).toString();

  if (writeFile) {
    final file = File('$root/$location');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(payload);
  }

  final id = evidenceIdOverride ?? evidenceId;
  final entry = RecordingEntry(
    evidenceId: id,
    sessionId: sessionId,
    waybill: WaybillNumber.parse(waybill),
    startedAt: DateTime.utc(2026, 9, 23, 2, 0),
    endedAt: DateTime.utc(2026, 9, 23, 2, 5),
    duration: const Duration(minutes: 5),
    location: RelativePath.parse(location),
    contentHash: ContentHash.parse(hash),
    sourceDeviceId: deviceId,
  );

  final index = JsonLinesRecordingIndex('$root/index.jsonl');

  if (staleRowFirst) {
    // 同一条录像的一行旧记录：落点早就不存在了。读取时**后者胜出**，
    // 所以它必须排在当前那行前面，测试才有意义。
    await index.add(RecordingEntry(
      evidenceId: entry.evidenceId,
      sessionId: entry.sessionId,
      waybill: entry.waybill,
      startedAt: entry.startedAt,
      endedAt: entry.endedAt,
      duration: entry.duration,
      location: RelativePath.parse('2026/09/22/旧单号/旧路径.mp4'),
      contentHash: entry.contentHash,
      sourceDeviceId: entry.sourceDeviceId,
    ));
  }

  await index.add(entry);

  final punchLog = PunchLog('$root/punches.jsonl');
  await punchLog.append(Punch(
    punchId: 'p-1',
    sessionId: sessionId,
    waybill: WaybillNumber.parse(waybill),
    punchedAt: DateTime.utc(2026, 9, 23, 2, 0, 1, 200),
    monotonicOffsetMilliseconds: 1200,
    source: PunchSource.keyboardScanner,
  ));

  final labels = LabelStore('$root/labels.jsonl');
  await labels.append(RecordingLabel(
    evidenceId: id,
    key: 'business-type',
    value: 'outbound',
    updatedAt: DateTime.utc(2026, 9, 23, 2, 0),
  ));

  final fake = await FakeDesktop.start(
    chunkSize: hostChunkSize,
    hostCredential: hostCredential,
  );
  final clock = Clock(DateTime.utc(2026, 9, 23, 10, 0, 0));

  final identity = DeviceIdentity(
    path: '$root/device.json',
    deviceId: deviceId,
    deviceName: '打包手机-1',
    hostAddress: '127.0.0.1',
    hostName: '打包间-左',
    credential: enrolled ? testCredential : '',
  );

  final archive = ArchiveStore('$root/archive.jsonl');

  return Harness(
    root: root,
    fake: fake,
    archive: archive,
    clock: clock,
    entry: entry,
    payload: payload,
    payloadHash: hash,
    uploader: Uploader(
      rootPath: root,
      identity: identity,
      index: index,
      punchLog: punchLog,
      labels: labels,
      archive: archive,
      client: UploadClient(
        address: '127.0.0.1',
        port: fake.port,
        credential: enrolled ? testCredential : '',
      ),
      chunkSize: localChunkSize,
      maxAttempts: maxAttempts,
      now: () => clock.value,
    ),
  );
}

/// 把队列一路推到「不再有下一次」为止（每趟把钟拨到 `nextRetryAt`）。
///
/// 上界保底：退避是有限的，转不出来说明有东西在无限重试 —— 那正是 §3.4.3
/// 要防的。与其挂住，不如让测试红掉。
Future<UploadPass> _driveUntilSettled(Uploader uploader, Clock clock) async {
  var pass = await uploader.runOnce();

  for (var round = 0; round < 32 && pass.nextRetryAt != null; round++) {
    clock.value = pass.nextRetryAt!;
    pass = await uploader.runOnce();
  }

  return pass;
}
