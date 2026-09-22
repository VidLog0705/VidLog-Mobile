import 'dart:io';

/// 电脑端默认的回放服务端口（电脑端 `DesktopServices.DefaultPlaybackPort`）。
///
/// 探测复用它 —— M3 已经有一台活的 HTTP 服务在那儿，**手机端不必让电脑端
/// 先改点什么**就能试出「在不在线上」。
const defaultHostPort = 8720;

/// 探一次电脑端在不在。
///
/// **只发一个 GET，不引任何依赖。** 判据刻意放宽到「有没有 HTTP 响应」：
/// 连上并被应答 → 在线；拒绝连接 / 超时 / DNS 失败 → 离线。
///
/// ## ⚠️ 两处已知的弱（都是刻意的，不是漏了）
///
/// 1. **同一个端口上任何别的 HTTP 服务都会被判成「在线」。** 要根治得让电脑端
///    提供一个 `/health` 端点，那属于 M5 做配网时一起做的事。
/// 2. **电脑端默认只绑 `localhost`。** 要让局域网可达，得在电脑上跑一次
///    `netsh http add urlacl url=http://+:8720/ user=Everyone`（电脑端文档已写明）。
///    绑不上时这里就是真「离线」—— 那是**真话，不是故障**，界面上照实显示。
///
/// 超时给 2 秒：这一趟是**界面等着的**，不能因为电脑端不在就卡住整个备份页。
Future<bool> isHostReachable(
  String address, {
  int port = defaultHostPort,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (address.trim().isEmpty) return false;

  final client = HttpClient()..connectionTimeout = timeout;

  try {
    final request = await client
        .getUrl(Uri.parse('http://${address.trim()}:$port/'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>();
    return true;
  } on Object {
    // 拒绝连接、超时、解析不了地址 —— 对界面来说都是同一件事：连不上。
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 本机的局域网 IPv4；没有就返回 null。
///
/// 用标准库的 `NetworkInterface.list()`，**不引任何包**。
///
/// ## 为什么不能拿「第一个非回环地址」了事
///
/// 手机上同时会有好几个接口：iOS 的 `pdp_ip0`（蜂窝）、`utun*`（VPN）、
/// Android 的 `rmnet*` —— 随便挑一个会挑到蜂窝或 VPN 的地址，而那个地址
/// **同一个局域网里的电脑根本连不上**，用户照着填进电脑端只会连不通。
/// 所以优先挑 Wi-Fi 的接口名（iOS `en0` / Android `wlan*`）。
///
/// 找不到就返回 null，界面显示「未连局域网」—— **不显示 0.0.0.0**：
/// 那个地址看起来像个正经地址，但它连不上任何东西。
Future<String?> lanAddress() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );

    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4) continue;
        if (address.isLoopback) continue;

        final name = interface.name.toLowerCase();
        if (name == 'en0' || name.startsWith('wlan')) return address.address;

        fallback ??= address.address;
      }
    }

    // 没认出 Wi-Fi 的接口名（厂商定制系统会改名字）—— 退到第一个可用的，
    // 总比显示「未连局域网」而其实连着要好。
    return fallback;
  } on Object {
    return null;
  }
}
