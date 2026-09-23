import 'dart:io';

/// 电脑端默认的回放服务端口（电脑端 `DesktopServices.DefaultPlaybackPort`）。
///
/// 探测复用它 —— M3 已经有一台活的 HTTP 服务在那儿，**手机端不必让电脑端
/// 先改点什么**就能试出「在不在线上」。
const defaultHostPort = 8720;

// ⚠️ 这里原来有一个 `isHostReachable`：发一个 GET，判据放宽到「有没有 HTTP
// 响应」。M5 把它删了，因为那个判据**同端口上任何一个别的 HTTP 服务都会给绿灯**，
// 而备份页现在拿它承诺的是「录像能传上去」。
// 现在的判据在 `uploader.dart` 的 `HostHealth.isVidLog`：真的调一次
// `GET /api/v1/health` 并核对 `service`。它当初就是作为这段注释里那条
// 「已知的弱」的答复而写的。

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
