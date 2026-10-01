import 'dart:convert';
import 'dart:io';

import '../diagnostics/app_log.dart';

/// 网盘上的一条文件（`listall` 回的 `list[]`）。
class NetdiskFile {
  const NetdiskFile({
    required this.path,
    required this.name,
    required this.size,
    required this.fsId,
    required this.isDir,
  });

  /// 网盘上的绝对路径（`/apps/<应用名>/...`）。
  final String path;

  /// 文件名（不含目录）。
  final String name;

  /// 字节数。
  final int size;

  /// 网盘里的唯一 ID。
  final int fsId;

  final bool isDir;

  factory NetdiskFile.fromJson(Map<String, Object?> json) => NetdiskFile(
        path: (json['path'] as String?) ?? '',
        name: (json['server_filename'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        fsId: (json['fs_id'] as num?)?.toInt() ?? 0,
        isDir: (json['isdir'] as num?)?.toInt() == 1,
      );
}

/// 网盘容量（`GET /api/quota` 回的那三个数）。
///
/// ⚠️ 「剩余」用接口回的 `free`，**不自己拿 `total - used` 算** ——
/// 两者现在确实相等（文档 060 的响应示例里就是），但那是它的口径，
/// 我们跟着它走，不在这一层替它做减法。
class NetdiskQuota {
  const NetdiskQuota({required this.total, required this.used, required this.free});

  final int total;
  final int used;
  final int free;

  /// 已用百分比（0~1）。总量为 0 时给 0，不做除零。
  double get usedRatio => total <= 0 ? 0 : (used / total).clamp(0, 1).toDouble();
}

/// 网盘那边出错（业务码非 0、或回包缺字段）。
class NetdiskFailure implements Exception {
  const NetdiskFailure(this.message, {this.errno});

  final String message;
  final int? errno;

  @override
  String toString() => message;
}

/// 文件名里那一段**单号**。
///
/// 电脑端的落点是 `<单号>_<会话>_<序号>.mp4`（`BaiduPanLayout`），
/// 所以第一段就是单号。
String waybillOf(String fileName) {
  final cut = fileName.indexOf('_');
  return cut < 0 ? fileName : fileName.substring(0, cut);
}

/// 用户输的那几位数字，匹配不匹配这一条。
///
/// ⚠️ **比的是「单号那一段」的末尾，不是整个文件名包含它。**
/// 整个文件名里还有会话号与序号，纯 `contains` 会让「123456」命中到会话号上 ——
/// 搜一个单号出来一堆。而用户说的是「单号的**后** 6 位」。
bool tailMatches(String fileName, String digits) {
  final wanted = digits.trim();
  if (wanted.isEmpty) return false;
  return waybillOf(fileName).endsWith(wanted);
}

/// 扫到的整串单号 → 查询要用的那 6 位。
///
/// ⚠️ 口径照需求原话「单号的**后 6 位**」：先取末尾 6 个字符，再把里面
/// **不是数字的滤掉**。
///
/// 为什么不能只取「末尾那段数字」：那是另一种口径，遇到 `SF1234AB` 这种
/// 结尾带字母的号会一个数字都取不到（正则要求结尾就是数字），
/// 于是**扫了却查不到**。而按「后 6 位滤掉非数字」走，同一串能取到 `1234`，
/// 与文件名里那段单号仍然对得上。
///
/// 不足 6 位就原样给（用户可能只扫到一半，让他自己看着补）。
/// 一个数字都没有时返回空串 —— 调用方会当成「没扫到」。
String lastSixDigits(String scanned) {
  final text = scanned.trim();
  if (text.isEmpty) return '';

  final tail = text.length <= 6 ? text : text.substring(text.length - 6);
  return tail.replaceAll(RegExp(r'\D'), '');
}

/// `listall` 的一页。
class NetdiskPage {
  const NetdiskPage({required this.files, required this.cursor, required this.hasMore});

  final List<NetdiskFile> files;

  /// 下一页的起点。⚠️ 下一次要把**这个**当作 `start` 传回去，不是 `start + limit`。
  final int cursor;

  final bool hasMore;
}

int _errnoOf(Map<String, Object?> json) => (json['errno'] as num?)?.toInt() ?? -1;

/// 读 `listall` 的一页（文档 057）。
///
/// ⚠️ 分页口径：响应里 `has_more=1` 时，**下一页的起点是它回的那个 `cursor`**，
/// 不是「本页起点 + 本页条数」。文档 057 的请求参数表白纸黑字写着这一条；
/// 按另一种口径翻页会在某个目录大小上**静默漏掉中间那一段**，
/// 而表现是「搜不到某条明明传上去了的录像」。
NetdiskPage parseListAll(String body) {
  final json = _decode(body);
  final errno = _errnoOf(json);

  if (errno != 0) {
    throw NetdiskFailure(
      '网盘不让列目录（errno $errno${_errmsg(json)}）',
      errno: errno,
    );
  }

  final raw = json['list'];
  final files = <NetdiskFile>[
    if (raw is List)
      for (final item in raw)
        if (item is Map) NetdiskFile.fromJson(item.cast<String, Object?>()),
  ];

  final hasMore = ((json['has_more'] as num?)?.toInt() ?? 0) == 1;

  return NetdiskPage(
    files: files,
    cursor: (json['cursor'] as num?)?.toInt() ?? 0,
    hasMore: hasMore,
  );
}

/// 读容量（文档 060）。
NetdiskQuota parseQuota(String body) {
  final json = _decode(body);
  final errno = _errnoOf(json);

  if (errno != 0) {
    throw NetdiskFailure('问不到网盘容量（errno $errno${_errmsg(json)}）', errno: errno);
  }

  return NetdiskQuota(
    total: (json['total'] as num?)?.toInt() ?? 0,
    used: (json['used'] as num?)?.toInt() ?? 0,
    free: (json['free'] as num?)?.toInt() ?? 0,
  );
}

/// 从 `method=meta` 的答复里取下载直链（文档 047）。
String parseDlink(String body) {
  final json = _decode(body);
  final errno = _errnoOf(json);

  if (errno != 0) {
    throw NetdiskFailure('取不到下载地址（errno $errno${_errmsg(json)}）', errno: errno);
  }

  final list = json['list'];
  if (list is! List || list.isEmpty || list.first is! Map) {
    throw const NetdiskFailure('取不到下载地址：答复里没有这一条文件');
  }

  final item = (list.first as Map).cast<String, Object?>();
  final link = (item['dlink'] as String?)?.trim();

  // ⚠️ 单文件那条列表里，**某一条自己也可能带 errno**（文档 047 的 `list[].errno`）。
  // 顶层 0、这一条非 0 时直链是空的 —— 只看顶层就会拿着空串去下载。
  final itemErrno = (item['errno'] as num?)?.toInt() ?? 0;
  if (itemErrno != 0) {
    throw NetdiskFailure('这一条文件取不到下载地址（errno $itemErrno）', errno: itemErrno);
  }

  if (link == null || link.isEmpty) {
    throw const NetdiskFailure('答复里没有下载地址（dlink 是空的）');
  }

  return link;
}

Map<String, Object?> _decode(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const NetdiskFailure('网盘回的不是一个 JSON 对象');
  }
  return decoded.cast<String, Object?>();
}

String _errmsg(Map<String, Object?> json) {
  final text = (json['errmsg'] as String?)?.trim();
  return text == null || text.isEmpty || text == 'succ' ? '' : '，$text';
}

/// 百度网盘那一层。**只做「翻译」，不做决定**（与电脑端 `IBaiduPanApi` 同一条规矩）：
/// 不带重试、不带并发控制、不带「该不该下」的判断。
class BaiduPanClient {
  BaiduPanClient({
    required this.accessToken,
    required this.appName,
    Future<String> Function(Uri uri)? fetch,
    HttpClient Function()? httpFactory,
  })  : _fetch = fetch ?? _httpGet,
        _httpFactory = httpFactory ?? HttpClient.new;

  final String accessToken;

  /// 开放平台后台填的那个「产品名称」——远端根是 `/apps/<它>/`。
  final String appName;

  /// 取一段 JSON 那一步。**抽成可替换的函数**（与 `NetdiskSession.fetchFromHost`
  /// 同一手法，也与电脑端那个 `IBaiduPanApi` 同一条理由）：翻页、按单号筛、
  /// 容量解析这些**真逻辑**全在 HTTP 后面，不抽出来就只能靠肉眼看完。
  final Future<String> Function(Uri uri) _fetch;

  /// 字节流那一步（下载）。与上面分开是因为它要的不是一段字符串，
  /// 而是一条能边下边报进度的流 —— 两件事，两个缝隙。
  final HttpClient Function() _httpFactory;

  /// 文档里每个示例都带它；而 `31326 命中防盗链` 的排查方向写的就是
  /// 「确认请求 Header 中 User-Agent 为 pan.baidu.com」。
  static const userAgent = 'pan.baidu.com';

  /// 应用自己的目录。⚠️ 只能碰它 —— 网盘那侧也这么判（文档 012《应用目录权限细则》）。
  String get root => '/apps/$appName';

  Uri _listAllUri({required int start}) => Uri.https('pan.baidu.com', '/rest/2.0/xpan/multimedia', {
        'method': 'listall',
        'access_token': accessToken,
        'path': root,
        // ⚠️ 必须递归：落点是 `<年>/<月>/<日>/<发货|退货>/`，深四层。
        'recursion': '1',
        'order': 'time',
        'desc': '1',
        'limit': '1000',
        'start': '$start',
      });

  Uri _quotaUri() => Uri.https('pan.baidu.com', '/api/quota', {
        'access_token': accessToken,
        'checkfree': '1',
        'checkexpire': '1',
      });

  Uri _metaUri(String path) => Uri.https('pan.baidu.com', '/rest/2.0/xpan/multimedia', {
        'method': 'meta',
        'access_token': accessToken,
        'path': path,
        'dlink': '1',
      });

  /// 把应用目录下的文件**全列出来**（跟着 `cursor` 翻完所有页）。
  ///
  /// ⚠️ 网盘那边建议这个接口**每分钟不超过 8~10 次**（文档 057 的 `31034` 那一行），
  /// 所以调用方别把它放进循环里。
  Future<List<NetdiskFile>> listAll({int maxPages = 20}) async {
    final all = <NetdiskFile>[];
    var start = 0;

    for (var page = 0; page < maxPages; page++) {
      final body = await _get(_listAllUri(start: start));
      final parsed = parseListAll(body);

      all.addAll(parsed.files.where((f) => !f.isDir));

      if (!parsed.hasMore) return all;
      start = parsed.cursor;
    }

    // 页数到顶还没完 —— 如实说，别回一个「看起来列全了」的半截列表。
    throw const NetdiskFailure('网盘上的文件太多，一次列不完');
  }

  /// 按单号那几位数字找。
  Future<List<NetdiskFile>> findByWaybillTail(String digits) async {
    final wanted = digits.trim();
    if (wanted.isEmpty) return const [];

    final all = await listAll();
    return all.where((f) => tailMatches(f.name, wanted)).toList();
  }

  /// 容量。
  Future<NetdiskQuota> quota() async => parseQuota(await _get(_quotaUri()));

  /// 一条文件的下载直链。
  Future<String> dlink(String path) async => parseDlink(await _get(_metaUri(path)));

  /// 下载到本地文件，边下边报进度。
  ///
  /// 进度是**按字节**算的（`已收 / 总大小`），不是按分片数 ——
  /// 用户看到的是「下了多少」，而分片大小是内部的事。
  Future<void> download(
    String link,
    String destination, {
    void Function(int received, int total)? onProgress,
  }) async {
    // ⚠️ 直链要**拼上 access_token**，而且要带 User-Agent（文档 047 的注意事项）。
    final url = link.contains('?') ? '$link&access_token=$accessToken' : '$link?access_token=$accessToken';

    final client = _httpFactory()..connectionTimeout = const Duration(seconds: 20);
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);

    final response = await request.close();
    if (response.statusCode != 200) {
      throw NetdiskFailure('下载失败：网盘回了 HTTP ${response.statusCode}');
    }

    final total = response.contentLength;
    final file = File(destination);
    await file.parent.create(recursive: true);

    final sink = file.openWrite();
    final started = DateTime.now();
    var received = 0;

    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      AppLog.instance.info('网盘', '下好了一条', data: {
        '字节': received,
        '耗时ms': DateTime.now().difference(started).inMilliseconds,
      });
    } on Object catch (error) {
      // ⚠️ 下到一半失败**要记下已经收了多少** —— 「下了 90% 断了」和
      // 「一开始就断」是两种完全不同的毛病，而用户看到的都只是「下载失败」。
      AppLog.instance.warn('网盘', '下载断了', data: {
        '已收字节': received,
        '应该多少': total,
        '耗时ms': DateTime.now().difference(started).inMilliseconds,
        '错误': '$error',
      });

      rethrow;
    } finally {
      await sink.close();
      client.close(force: true);
    }
  }

  /// 取一段 JSON，**带耗时与成败留痕**（§6.1：外部依赖调用要记目标/耗时/成败）。
  ///
  /// ⚠️ <b>绝不记整条 URL。</b>`access_token` 就在查询串里，而诊断包会把
  /// `logs/` 整个打包外发 —— 记一条 URL 等于把凭据写进要发出去的文件。
  /// 所以只记**接口名**（`method` 参数）与路径；token 一个字都不碰。
  Future<String> _get(Uri uri) async {
    final method = uri.queryParameters['method'] ?? uri.path;
    final started = DateTime.now();

    try {
      final body = await _fetch(uri);

      AppLog.instance.debug('网盘', '问了一次 $method', data: {
        '耗时ms': DateTime.now().difference(started).inMilliseconds,
        '字节': body.length,
      });

      return body;
    } on Object catch (error) {
      // ⚠️ 失败也要记，而且**带耗时** —— 「被拒了」和「慢得超时」是两回事，
      // 只有成功那条记的话，这两者都看不到。
      AppLog.instance.warn('网盘', '问 $method 失败', data: {
        '耗时ms': DateTime.now().difference(started).inMilliseconds,
        '错误': '$error',
      });

      rethrow;
    }
  }

  /// 真正走网络的那一次 GET（默认那个 [BaiduPanClient] 的 `fetch`）。
  static Future<String> _httpGet(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw NetdiskFailure('网盘回了 HTTP ${response.statusCode}');
      }

      return body;
    } finally {
      client.close(force: true);
    }
  }
}
