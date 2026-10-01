import 'dart:convert';
import 'dart:io';

import '../diagnostics/app_log.dart';
import '../recording/recording_workspace.dart' show writeFileAtomically;

/// 电脑端借出来的那个百度网盘令牌。
///
/// ## ⚠️ 为什么是「借」
///
/// 换令牌那一步非要 `client_secret` 不可（百度文档 009 的第三步），而
/// `AGENTS.md` §2 写死「客户端**绝不内置** secret」—— 手机是发给工人随身带的，
/// 那正是这一条要防的东西。所以手机端**不自己登录**：它向**已经登着的电脑端**
/// 要一个现成的 `access_token`（`POST /api/v1/netdisk/token`，要设备凭据）。
///
/// 需求方 2026-10-01 裁决：手机端**不存 AppSecret**，走这条「借」的路。
class NetdiskGrant {
  const NetdiskGrant({
    required this.status,
    this.accessToken,
    this.appName,
    this.message,
    this.expiresAt,
  });

  /// 四档状态，与电脑端 `NetdiskGrant` 的常量一一对应。
  ///
  /// ⚠️ **四档分开**是为了能对用户说人话：一句笼统的「登录失败」会让人去查
  /// 自己手机的网络，而真正的原因在**另一台机器**上。
  final String status;

  /// 只有 [isOk] 时才非空。
  final String? accessToken;

  /// 开放平台后台填的那个「产品名称」——远端根是 `/apps/<它>/`。
  ///
  /// ⚠️ **由电脑端告诉手机端，手机端不写死**：换了应用只改一处；而拼错这个名字时
  /// 网盘回的是「目录不存在」，**查起来完全看不出是名字错了**。
  final String? appName;

  /// 给人看的一句话；成功时为空。
  final String? message;

  /// 令牌到手了。
  static const ok = 'ok';

  /// 电脑端有凭据，但**没登着**（或者授权已经失效）。
  static const notLoggedIn = 'not_logged_in';

  /// 电脑端那边网盘这一档压根没启用。
  static const unavailable = 'unavailable';

  /// 登着，但这次问不到（网断了、被限流了）。**下次再问可能就好了。**
  static const failed = 'failed';

  /// 能不能拿去调网盘。
  ///
  /// ⚠️ 三个字段**都要有**才算数：状态对但令牌是空的，是「回包少了一半」，
  /// 而拿着一个空令牌去调网盘只会换回一串看不懂的 `31045`。
  bool get isOk =>
      status == ok &&
      (accessToken?.trim().isNotEmpty ?? false) &&
      (appName?.trim().isNotEmpty ?? false);

  /// 读电脑端回的那一份（字段名 camelCase，与 `05-上传接口形状.md` 同一套）。
  factory NetdiskGrant.fromJson(Map<String, Object?> json) => NetdiskGrant(
        status: (json['status'] as String?)?.trim() ?? '',
        accessToken: _text(json['accessToken']),
        appName: _text(json['appName']),
        message: _text(json['message']),
        // 读不出来就当没有 —— 借来的那份本来就没有这个字段。
        expiresAt: DateTime.tryParse((json['expiresAt'] as String?) ?? ''),
      );

  Map<String, Object?> toJson() => {
        'status': status,
        'accessToken': accessToken,
        'appName': appName,
        'message': message,
        'expiresAt': expiresAt?.toIso8601String(),
      };

  /// 这串令牌什么时候作废。
  ///
  /// ⚠️ 只有**手机自己登录**（简化模式）那一份才有这个数 —— 它是跳转回来的
  /// 网址里 `expires_in` 算出来的（文档 004：那个模式**过期不能续期**，
  /// 用户得重新授权一次）。「借」来的那份没有，因为电脑端会自己续。
  final DateTime? expiresAt;

  /// 过期了没有。没有 [expiresAt] 时一律当作**没过期** —— 借来的那份由电脑端管。
  bool expiredAt(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  static String? _text(Object? value) {
    final text = (value as String?)?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}

/// 这个应用的 AppKey（在百度网盘开放平台后台建应用时拿到的那一串）。
///
/// ## ⚠️ 为什么它可以内置，而 SecretKey 不行
///
/// `AGENTS.md` §2 列的是**密钥 / AppSecret / 签名私钥 / 证书密码** ——
/// AppKey **不在其中**，因为它本来就不是秘密：它在**每一个**授权链接里都明文
/// 出现（`client_id=…`），谁打开授权页都看得见。
///
/// 内置它的理由是**手机上必须离线可用**：人在局域网外、又是刚装好的手机时，
/// 拿不到电脑端给的那一份，而授权链接里必须有它。
///
/// ⚠️ **需求方 2026-10-01 裁决：内置。**已知的代价写在这里不藏着：这一串会进
/// 仓库历史，而两个代码仓现在是 public —— 也就是说它是公开的。那与「它本来就在
/// 授权链接里明文出现」是同一件事，所以不算把秘密漏出去。
/// ⚠️ **但别顺手把 SecretKey 照这个样子加进来** —— 那是另一回事，§2 写死禁止。
const baiduAppKey = 'RBMl6jg7Od6rV4tlUcUg3mASpw0RYIbh';

/// 走授权页时用的回调地址：**`oob`，而且后台那一栏留空**。
///
/// ⚠️ 依据是文档 010：「对于无 Web Server 的应用，其值可以是"oob"」——
/// 它被那条「redirect_uri 必须与配置的授权回调地址匹配 / 域名必须与站点地址匹配」
/// 的规则**明确豁免**，所以既不用有域名、也不用去后台填那一栏，
/// 更不用等 `005` 说的那 1 小时生效。
///
/// ⚠️ 代价：授权完成后百度把结果**显示在一个页面上**（`login_success`），
/// 用户得**自己复制**回 App。所以界面上那个粘贴框不是凑数，是这条路的一环。
const baiduOobRedirect = 'oob';

/// 用户在 `oob` 那一页上看到的东西 —— 一整条跳转网址、页面上抄下来的一行参数、
/// 或者只是那串令牌，**三种都要收**。
///
/// ⚠️ 为什么三种都可能：文档 010 只说 `oob` 时会「将 Authorization Code 直接显示
/// 在响应页面的页面中及页面 title 中」——**那说的是授权码**，简化模式下显示的是
/// 什么，文档没写。既然如此就别赌哪一种，都收下。
///
/// ⚠️ 只拿到一串令牌时，有效期按**文档写死的 30 天**算（004：「Access Token
/// 有效期30天」）。不这么算的话那一份会被当成**永不过期** —— 于是它真过期之后
/// App 还一直拿它去调网盘，报回来的错与「过期」毫无关系。
NetdiskGrant parsePastedCredential(
  String input, {
  required String appName,
  DateTime? now,
}) {
  final text = input.trim();
  if (text.isEmpty) {
    return const NetdiskGrant(status: NetdiskGrant.failed, message: '还没粘贴东西。');
  }

  // 判据用「有没有 access_token= 或 error=」，**不用「能不能 parse 成 Uri」**：
  // 一串令牌本身也能被 parse 成 Uri（`126.ee2c…` 看着就像个 scheme），
  // 拿那条当判据会把它当成网址、然后回一句「里面没有令牌」。
  if (text.contains('access_token=') || text.contains('error=')) {
    return parseImplicitRedirect(text, appName: appName, now: now);
  }

  return NetdiskGrant(
    status: NetdiskGrant.ok,
    accessToken: text,
    appName: appName,
    expiresAt: (now ?? DateTime.now()).add(const Duration(days: 30)),
  );
}

/// 手机端**自己**登录时打开的那个网址（百度「简化模式」，文档 008）。
///
/// ## ⚠️ 为什么手机端只能走这个模式
///
/// 另外两种都要**在换令牌那一步交出 `client_secret`**：设备码模式（009 第三步）
/// 与授权码模式（007）都是。而 `AGENTS.md` §2 写死「客户端**绝不内置** secret」——
/// 手机是发给工人随身带的。简化模式是唯一一种**只要 AppKey** 就能拿到令牌的
/// （文档 004：它「适用于**无 Server 端配合**的应用」）。
///
/// ## ⚠️ 它的代价，调用处该说给用户听
///
/// **这个模式不发 refresh_token**（文档 008 的跳转组成里只有 access_token /
/// expires_in / scope），而文档 004 明说它「过期后**不支持刷新**，
/// 用户需重新登录授权」。⚠️ 而且要命的是：**刷新那一步本身也要 `client_secret`**
/// （文档 007：「grant_type=refresh_token&…&client_secret=您应用的SecretKey」，
/// 且注明「仅给出了**必选参数**」）—— 所以就算想办法拿到了 refresh_token，
/// 手机端也续不了期。**手机自己登的这一份 30 天后必须重新授权一次**，
/// 这是平台给的约束，不是实现能绕过去的。
///
/// ⚠️ `redirectUri` 必须与**百度控制台里登记的那个逐字相同**（文档 005：
/// 「授权回调地址修改后在 1 小时内生效」）。对不上时报的是 `redirect_uri_mismatch`，
/// 而那句话完全看不出是「你控制台里填的不是这个」。
String buildImplicitAuthorizeUrl({
  required String appKey,
  required String redirectUri,
  String? state,
}) =>
    Uri.https('openapi.baidu.com', '/oauth/2.0/authorize', {
      'response_type': 'token',
      'client_id': appKey,
      'redirect_uri': redirectUri,
      'scope': 'basic,netdisk',
      if (state != null && state.isNotEmpty) 'state': state,
    }).toString();

/// 从**跳转回来的那个网址**里把令牌读出来。
///
/// ⚠️ 令牌在 **fragment**（`#` 后面）里，不在 query 里 —— 文档 008 的跳转组成是
/// `<回调地址>#access_token=xxx&expires_in=xxx&…`。只读 query 的话会**永远读不到**，
/// 而表现是「授权明明成功了，App 说没拿到」。
///
/// ⚠️ 用户点了【拒绝】时回的是 `error=access_denied`（文档 010 的 redirectUrl 说明），
/// 那**不是异常**，是一句要如实说给用户听的话 —— 所以这里回 [NetdiskGrant] 而不抛。
///
/// ⚠️ `appName` 由调用方给：简化模式**不回**这个东西，而远端根 `/apps/<应用名>/`
/// 处处都要用它。手机上那份来自上一次「借令牌」（见 `NetdiskSession`）。
NetdiskGrant parseImplicitRedirect(
  String url, {
  required String appName,
  DateTime? now,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return const NetdiskGrant(
      status: NetdiskGrant.failed,
      message: '这个跳转网址看不懂，拿不到令牌。',
    );
  }

  // 三种形状都要收：
  //   ① 一整条跳转网址        `…/login_success#access_token=…`
  //   ② 页面上抄下来的一行    `access_token=…&expires_in=…`（用户只选了那一行）
  //   ③ 只有一串令牌          `126.ee2c…EzfneA` —— 由 `parsePastedCredential` 兜，
  //                          它不会被送到这里（这一串里没有 `access_token=`）
  //
  // ⚠️ ②那条不是多虑：`oob` 这一路上百度是**把结果印在页面上**的，
  // 用户框选那一行复制、而不是复制整条地址栏，是很自然的动作。
  // 只认 fragment 的话，那种粘贴会回一句「跳转回来的网址里没有令牌」——
  // 而用户明明把令牌摆在眼前。
  final raw = uri.fragment.isNotEmpty
      ? uri.fragment
      : uri.query.isNotEmpty
          ? uri.query
          : (url.contains('=') ? url.trim() : '');
  if (raw.isEmpty) {
    return const NetdiskGrant(
      status: NetdiskGrant.failed,
      message: '跳转回来的网址里没有令牌。',
    );
  }

  Map<String, String> params;
  try {
    params = Uri.splitQueryString(raw);
  } on Object {
    return const NetdiskGrant(
      status: NetdiskGrant.failed,
      message: '跳转回来的网址解析不了。',
    );
  }

  final error = params['error'];
  if (error != null && error.isNotEmpty) {
    final description = params['error_description'] ?? error;
    return NetdiskGrant(
      status: NetdiskGrant.failed,
      // 用户自己点的取消，要说成「你取消了」，不是「出错了」——
      // 后者会让人以为是程序坏了，于是反复重试。
      message: error == 'access_denied' ? '你取消了授权，没有拿到令牌。' : '授权没成功：$description',
    );
  }

  final token = params['access_token']?.trim();
  if (token == null || token.isEmpty) {
    return const NetdiskGrant(
      status: NetdiskGrant.failed,
      message: '跳转回来了，但里面没有令牌。',
    );
  }

  final seconds = int.tryParse(params['expires_in'] ?? '');
  final issuedAt = now ?? DateTime.now();

  return NetdiskGrant(
    status: NetdiskGrant.ok,
    accessToken: token,
    appName: appName,
    // 读不出有效期就**不编一个**：编短了会逼着用户白白重新授权，
    // 编长了会在真过期之后继续拿它去调网盘（那时报的错与「过期」毫无关系）。
    expiresAt: seconds == null || seconds <= 0
        ? null
        : issuedAt.add(Duration(seconds: seconds)),
  );
}

/// 令牌**明文**落在应用数据目录里。
///
/// ## ⚠️ 这是需求方 2026-10-01 明说的裁决，不是顺手写的
///
/// 不落盘的代价是「每次开 App 都得能连回电脑端那个局域网」—— 而借用令牌
/// 这件事本身就是为了跨网用，不落盘等于白借。
///
/// 已知的代价，写在这里不藏着：**手机是工人随身带的**，能拿到这台手机的人
/// 就能拿到这个令牌，也就能读写这个店铺网盘 `/apps/<应用名>/` 里的全部录像。
/// 这一点**和电脑端不一样** —— 电脑端那份明文令牌的理由是「能读这台电脑的人
/// 本来就能读全部录像」（`VidLog.Desktop.Core` 的 `实现决策.md` §87.13），
/// 而那句话在手机上**不成立**。这个差额是需求方看过之后选的。
class NetdiskTokenStore {
  NetdiskTokenStore(this.path);

  /// 令牌文件的位置。
  final String path;

  /// 读回上次落盘的那一份；没有、读坏、或者少字段时返回 `null`。
  ///
  /// ⚠️ **读坏一律当没有**，不抛：令牌是**可以重新借**的东西，
  /// 为一份缓存把整页打不开，是拿能用的换不能用的。
  Future<NetdiskGrant?> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;

      final grant = NetdiskGrant.fromJson(decoded.cast<String, Object?>());
      return grant.isOk ? grant : null;
    } on Object catch (error) {
      // ⚠️ 读坏了要留痕：这意味着**用户得重新借一次**，而他自己不知道为什么。
      // 只在开 App 时读一次，所以不会灌日志。
      AppLog.instance.warn('网盘', '本机存的令牌读不出来，按没有处理', data: {'错误': '$error'});

      return null;
    }
  }

  /// 落盘。**只落能用的那一份** —— 把「没登着」也存下来，下次开 App 会先
  /// 显示一个假状态，而它下一秒就要被推翻。
  Future<void> save(NetdiskGrant grant) async {
    if (!grant.isOk) return;
    await writeFileAtomically(path, const JsonEncoder.withIndent('  ').convert(grant.toJson()));
  }

  /// 抹掉。**不作废云端**：借来的令牌不归我们吊销（那要去电脑端退出登录）。
  Future<void> clear() async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object catch (error) {
      // 删不掉不是错：下一次 [save] 会覆盖它。这里抛的话，退出登录会失败在半路。
      // ⚠️ 但**不静默**（§6.1）—— 记 debug 就够：它没有后果，只是不该没有痕迹。
      AppLog.instance.debug('网盘', '令牌文件删不掉（下一次会覆盖它）', data: {'错误': '$error'});
    }
  }
}

/// 「手上要有一个能用的网盘令牌」这件事本身。
///
/// ## 取令牌的顺序（**先问电脑端，问不到才用落盘那份**）
///
/// 1. 能连上电脑端 ⇒ 用**刚借到的**。哪怕本地那份还没过期 —— 电脑端可能自己
///    续过期，续期之后旧的那串未必还算数，**用新的是唯一稳妥的**。
/// 2. 连不上（不在那个局域网、电脑端关了）⇒ 退回落盘的那一份接着用。
/// 3. 两边都没有 ⇒ 把电脑端**为什么给不出来**如实带出去。
class NetdiskSession {
  NetdiskSession({required this.fetchFromHost, required this.store});

  /// 向电脑端要一份新的。抽成函数而不是直接调 HTTP：这一层要被测到。
  final Future<NetdiskGrant> Function() fetchFromHost;

  final NetdiskTokenStore store;

  NetdiskGrant? _cached;

  /// 上一次是不是**在吃落盘的兜底**（用来把重复的兜底**去重成两条**：开始吃一条、恢复一条）。
  ///
  /// ⚠️ 离线时每一次网盘操作都会走兜底，逐次记的话一分钟能刷几十条 ——
  /// 而被灌满的日志等于没有日志（§6.1 的配套要求：重复的问题只在「变了」时记）。
  var _fallingBack = false;

  /// 手上那份（可能来自落盘，也可能来自上一次借）。没有就是 `null`。
  NetdiskGrant? get cached => _cached;

  /// 开 App 时读一次落盘的。
  Future<void> restore() async {
    _cached = await store.load();
  }

  /// 要一个令牌。
  ///
  /// ⚠️ 电脑端回了「没登着 / 这一档没启用」时**要如实报出去**，不能悄悄退回
  /// 落盘那份：那是**确定性的**「给不了」，接着用旧令牌只会让用户对着一堆
  /// 网盘错误码猜。只有「这次问不到」（[NetdiskGrant.failed]，以及压根连不上）
  /// 才退回落盘那份 —— 那种是暂时的。
  Future<NetdiskGrant> token() async {
    NetdiskGrant fetched;

    try {
      fetched = await fetchFromHost();
    } on Object catch (error) {
      // 连不上电脑端（不在那个局域网、它没开）。这不是错 —— 落盘那份接着用。
      final fallback = _cached;
      if (fallback != null) return _noteFallback('连不上电脑端（$error）');

      AppLog.instance.warn('网盘', '借不到令牌，本机也没有', data: {'错误': '$error'});

      return NetdiskGrant(
        status: NetdiskGrant.failed,
        message: '连不上电脑端（$error），而且本机也没存着可用的令牌。'
            '回到电脑端所在的局域网里再试一次。',
      );
    }

    if (fetched.isOk) {
      _cached = fetched;
      await store.save(fetched);

      if (_fallingBack) {
        _fallingBack = false;
        AppLog.instance.info('网盘', '又能借到令牌了');
      }

      return fetched;
    }

    if (fetched.status == NetdiskGrant.failed) {
      final fallback = _cached;
      if (fallback != null) return _noteFallback('这次问不到：${fetched.message}');
    }

    // 确定性的「给不了」（没登着 / 这一档没启用）：如实报，并且**把落盘那份抹掉** ——
    // 它已经骗人了。留着的话，下一次连不上电脑端时又会拿它出来用。
    AppLog.instance.warn('网盘', '电脑端给不出令牌，把本机那份作废了', data: {
      '状态': fetched.status,
    });

    _cached = null;
    await store.clear();
    return fetched;
  }

  /// 吃落盘兜底时**只说第一条**（理由见 [_fallingBack]）。
  NetdiskGrant _noteFallback(String why) {
    if (!_fallingBack) {
      _fallingBack = true;
      AppLog.instance.warn('网盘', '借不到令牌，先用本机存着的那份顶上', data: {'原因': why});
    }

    return _cached!;
  }
}
