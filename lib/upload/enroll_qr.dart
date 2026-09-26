/// 入网二维码里的那串（规格 §3.4.5；2026-09-24 决定：**配对码由二维码取代**）。
///
/// 形状由电脑端的 `EnrollQr.Payload` 写出来，两端**逐字对齐**：
///
/// ```
/// vidlog://connect?host=192.168.1.23&port=8720&token=<base64url>
/// ```
///
/// ## 为什么要有这个类型，而不是在扫码的地方现场拆字符串
///
/// 拆错了的表现是**「扫了没反应」**：码扫到了、字符串也拿到了，但某一步
/// 悄悄对不上，`host` 变成空串、`port` 变成 0，然后请求发去 `http://:0/`。
/// 那种失败没有任何一处会报错，用户只会以为「这个码不好使」。
///
/// 所以拆解与判定收在这一个地方，**用测试钉住**（`test/enroll_qr_test.dart`）。
///
/// ⚠️ **不是 VidLog 的码一律返回 null**，由调用方决定怎么提示。
/// 扫码界面会看到环境里各种二维码（面单上的、商品上的），
/// 每一种都弹一次「这不是 VidLog 的码」比不提示更烦。
class EnrollQrPayload {
  const EnrollQrPayload({required this.host, required this.port, required this.token});

  /// 电脑端在局域网里的地址（IPv4 字面量，电脑端挑出来的）。
  final String host;

  /// 电脑端回放／上传服务的端口。
  final int port;

  /// 一次性令牌。**不是凭据** —— 凭据只在 claim 那一步发放，且只发一次。
  final String token;

  /// 电脑端屏幕上同时也印着的那个地址。连不上时让用户照着它手填。
  String get address => '$host:$port';

  /// 解析二维码内容。**不是 VidLog 的码、或者缺了哪一段，都返回 null。**
  static EnrollQrPayload? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      // 扫码拿到的东西**不保证是个 URI** —— 一维码里就是一串单号。
      return null;
    }

    // Uri 会把 scheme 与 host 都小写化，所以这里不必自己 lower。
    if (uri.scheme != 'vidlog' || uri.host != 'connect') return null;

    // 形状**逐字对齐**电脑端写出来的那一串，多一段路径就不是这张码。
    // 放过去的话，一个长得像但不是我们格式的码会被当成有效的 —— 而它里面
    // 那个 host 是**码上写什么就是什么**。
    if (uri.path.isNotEmpty && uri.path != '/') return null;

    // queryParameters 会把重复的键收成**最后一个**，这没什么可抱怨的：
    // 一张码里出现两个 host 只能是坏码，而坏码不需要「聪明的」处理。
    final host = (uri.queryParameters['host'] ?? '').trim();
    final portText = (uri.queryParameters['port'] ?? '').trim();
    final token = (uri.queryParameters['token'] ?? '').trim();

    // ⚠️ 地址只收「字母数字点横线」。宁可在这里拒掉，也不要让一个带空格或
    // 斜杠的地址进到 Uri.parse('http://$address:$port/...') 里 ——
    // 那会拼出一个**看着能发、其实发错地方**的 URL。
    if (!_isPlausibleHost(host)) return null;
    if (token.isEmpty) return null;

    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) return null;

    return EnrollQrPayload(host: host, port: port, token: token);
  }

  /// 像个主机名的东西：IPv4 字面量或一个普通主机名。
  ///
  /// 电脑端现在写进去的是 IPv4，但**不写死成「必须是 IPv4」** ——
  /// 那样等电脑端哪天改成一个主机名，手机端会一声不响地拒掉每一张码。
  static bool _isPlausibleHost(String host) {
    if (host.isEmpty || host.length > 253) return false;

    return RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.\-]*[A-Za-z0-9])?$').hasMatch(host);
  }

  @override
  String toString() => 'EnrollQrPayload($address)';
}
