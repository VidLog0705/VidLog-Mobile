import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../diagnostics/app_log.dart';
import 'lan_probe.dart' show defaultHostPort;
import 'recording_workspace.dart' show writeFileAtomically;

/// 本机名没设过时的默认值。
///
/// ⚠️ **「未命名1 / 未命名2」这个编号不在这里做** —— 手机端自己不知道自己是
/// 第几台，只有电脑端同时看得见多台。而且那个编号必须**在电脑端持久且稳定**
/// （需求方 2026-09-22：断联重连后电脑端要依然显示原机位名），否则重连一次
/// 编号就可能从「未命名2」变成「未命名1」，比不编号更乱。
///
/// 所以编号属于 M5 电脑端的设备表。手机端只如实报「我没改过名字」。
const defaultDeviceName = '未命名机位';

/// 本机名的宽度上限：**12 格，一个汉字算 2 格**。
///
/// 需求方 2026-09-23 原话：「机位名只允许12个字符内，一个汉字两个字符，
/// 一个字母1个字符，可以12个字母或者6个汉字」。
/// 所以上限是**显示宽度**，不是 `String.length`。
const maxDeviceNameWidth = 12;

/// [text] 占几格：汉字（含全角标点、假名、韩文、emoji）算 2，其余算 1。
///
/// ## 为什么不能直接用 `text.length`
///
/// Dart 的 `length` 数的是 UTF-16 code unit：「未命名机位」是 **5** 不是 10
/// （于是 6 个汉字的名字会被判成 6 —— 全部放行，正好放宽一倍）；
/// emoji 反过来算 **2**（代理对），一个 emoji 会吃掉两个字母的额度。
/// 哪个方向和需求方的意思都不一致。
///
/// 计数与界面用的是同一个口径，**界面上看着正好、代码说超了**这种
/// 两边对不上的事就不会发生。
int deviceNameWidth(String text) {
  var width = 0;
  for (final rune in text.runes) {
    width += _isWideRune(rune) ? 2 : 1;
  }
  return width;
}

/// East Asian Width 的 W/F 类（按常用 `wcwidth` 的区间近似，够用即可）。
///
/// 不查 Unicode 数据表是有意的：这里只关心「看着占两格」，而真正会出现的
/// 就是汉字、全角标点、假名、韩文、emoji 这几类。
bool _isWideRune(int rune) =>
    (rune >= 0x1100 && rune <= 0x115F) ||
    (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
    (rune >= 0xAC00 && rune <= 0xD7A3) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFE30 && rune <= 0xFE6F) ||
    (rune >= 0xFF00 && rune <= 0xFF60) ||
    (rune >= 0xFFE0 && rune <= 0xFFE6) ||
    (rune >= 0x1F300 && rune <= 0x1FAFF) ||
    (rune >= 0x20000 && rune <= 0x3FFFD);

/// 把 [name] 截到 [maxDeviceNameWidth] 格以内。
///
/// 按 **rune** 走而不是按 code unit，所以**不会把字劈成半个**
/// （`substring` 砍在代理对中间会留下一个孤零零的半字符）。
/// 超出部分直接丢掉 —— 界面上打字时是被拦住的（见 `_editDeviceName`），
/// 这里兜的是「有人手改过 `device.json`」和「旧版本存下的长名字」。
String clampDeviceName(String name) {
  var width = 0;
  final buffer = StringBuffer();
  for (final rune in name.runes) {
    final next = width + (_isWideRune(rune) ? 2 : 1);
    if (next > maxDeviceNameWidth) break;
    width = next;
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

/// 本机身份与本地配置（`device.json`）。
///
/// ## 为什么「设备标识」与「本机名」是两个字段，不能合一
///
/// 母仓 `docs/03-端间契约.md` §1.1 步骤 2 原文：
/// **「手机端发起入网请求，携带设备标识与人类可读的设备名」** —— 契约本来就
/// 要求两样东西：
///
/// | | [deviceId] | [deviceName] |
/// |---|---|---|
/// | 能不能改 | **不能**，装完生成一次定终身 | **能改**，随时 |
/// | 干什么用 | 电脑端靠它**认设备** | 电脑端靠它**显示** |
///
/// 分开的好处：**改了名字，电脑端上历史录像也跟着显示新名字** —— 电脑端是拿
/// 标识去查「当前名字」，所以不必去改任何一条历史记录。合成一个字段就做不到：
/// 要么改名字会篡改历史（证据产品的大忌），要么改完电脑端认不出是同一台。
///
/// ## ⚠️ [deviceId] 必须持久，丢了就等于换了台设备
///
/// 它存在这个文件里，**不是每次启动现生成的**。现生成的话每次开 App 在电脑端
/// 都是台新手机，名字永远记不住 —— 而「断联重连后依然显示原机位名」正是需求方
/// 明确要的。清除 App 数据 / 重装会重新生成，这与契约 §1.1 步骤 4
/// 「凭据丢失 → 重新走一遍入网」是同一个性子，可接受。
class DeviceIdentity {
  DeviceIdentity({
    required this.path,
    required this.deviceId,
    required this.deviceName,
    this.hostAddress = '',
    this.hostPort = defaultHostPort,
    this.hostName = '',
    this.credential = '',
  });

  final String path;

  /// 设备标识。**不可改**。写进每条录像索引的 `sourceDeviceId`。
  final String deviceId;

  /// 人类可读的本机名。可改，只给人看。
  String deviceName;

  /// 手填的电脑端地址（局域网 IPv4 或主机名）。空 = 还没配对。
  ///
  /// 手填是契约 §1.1 步骤 1 认可的路径（原文：「发现不到 → 允许手动填地址」）。
  /// 自动发现是 M5 的事。
  String hostAddress;

  /// 电脑端服务的端口。默认 [defaultHostPort]（8720）。
  ///
  /// 它来自**二维码里那一串** —— 扫进来的那台电脑端不必用默认端口。
  /// 收下却不存的话，入网那一次是对的（当场就用码里的端口），
  /// 而之后每一次上传都会打到 8720 上，用户看到的是「连不上电脑端」——
  /// 一个与真实原因（端口不对）看不出任何关系的提示。
  int hostPort;

  /// 手填的电脑端名字。只用来显示 —— 真连没连上由探测决定，不由它决定。
  String hostName;

  /// 入网换来的设备凭据（base64url 的 32 字节）。空 = 还没入网。
  ///
  /// ## ⚠️ 它不是「密码」，但它丢失的后果是一样的
  ///
  /// 契约 §1.1 步骤 4：**凭据丢失 → 重新走一遍入网，不得降级为免凭据。**
  /// 所以这里丢了不是灾难（重新配对即可），但**绝不能**因此把上传做成不要凭据 ——
  /// 那等于把电脑端的设备表变成一张谁都能往里写的名单。
  ///
  /// 它同时是回执验签的 HMAC 密钥（文档 §2.7），所以「有没有入网」与
  /// 「能不能确认回执是电脑端发的」是同一件事。
  ///
  /// 与 [deviceId] 一起落在 `device.json` 里 —— 那是 App 私有目录，
  /// 不进版本库（`IMPLEMENTATION.md` §1.3：密钥绝不入库、客户端不内置 secret）。
  String credential;

  /// 读配置；没有就建一份。
  ///
  /// 缺字段一律补默认值，**只有 [deviceId] 是「有就必须原样用」的**。
  ///
  /// ## ⚠️ 文件读坏是一次真正的损失
  ///
  /// 文件坏掉时读不出 id，只能重新生成 —— 代价是**这台手机在电脑端变成一台
  /// 新设备，之前的机位名再也对不上**。没有第二份可退（存两份就得处理
  /// 「两份不一致时听谁的」，为一个几乎不会发生的场景不值得）。
  ///
  /// 所以写这一份配置走的是 [writeFileAtomically]：**掉电时要么是旧的、要么是
  /// 新的，不会留半个文件**。上面的失败分支是给「有人手改过 / 磁盘出坏块」
  /// 留的，不是给掉电留的。
  static Future<DeviceIdentity> load(String path) async {
    final file = File(path);

    if (await file.exists()) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        final id = (json['deviceId'] as String?)?.trim() ?? '';

        // 只有 id 是「有就必须用」的；其余字段缺了就用默认值。
        if (id.isNotEmpty) {
          return DeviceIdentity(
            path: path,
            deviceId: id,
            // 截断只在「手改过文件 / 旧版本存下长名字」时才起作用。
            // 不在这里掐掉的话，一个 30 格的名字会一路带到电脑端的设备表里。
            deviceName: (json['deviceName'] as String?)?.trim().isNotEmpty == true
                ? clampDeviceName(
                    (json['deviceName']! as String).trim(),
                  )
                : defaultDeviceName,
            hostAddress: (json['hostAddress'] as String?)?.trim() ?? '',
            hostPort: _portFrom(json['hostPort']),
            hostName: (json['hostName'] as String?)?.trim() ?? '',
            credential: (json['credential'] as String?)?.trim() ?? '',
          );
        }
      } on Object {
        // 半个 JSON / 字段类型不对 → 落到下面重新生成 id。
        // 这是最后手段：见上面「文件读坏是一次真正的损失」。
      }
    }

    final created = DeviceIdentity(
      path: path,
      deviceId: newDeviceId(),
      deviceName: defaultDeviceName,
    );
    await created.save();
    return created;
  }

  Future<void> save() async {
    final file = File(path);
    await file.parent.create(recursive: true);

    await writeFileAtomically(
      path,
      const JsonEncoder.withIndent('  ').convert({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'hostAddress': hostAddress,
        'hostPort': hostPort,
        'hostName': hostName,
        'credential': credential,
      }),
    );
  }

  /// 改本机名并落盘。空名退回 [defaultDeviceName] ——
  /// 名字是电脑端用来区分设备的，允许它变空等于允许一台手机在电脑端消失。
  ///
  /// 超长按 [maxDeviceNameWidth] 截断（见 [clampDeviceName]）。这里再截一次
  /// 不是多余：**上限是这个字段的属性，不是那个输入框的属性** ——
  /// 以后从别处写名字（扫码带入、电脑端下发）也自动受同一个上限管。
  Future<void> rename(String name) async {
    final trimmed = clampDeviceName(name.trim());
    deviceName = trimmed.isEmpty ? defaultDeviceName : trimmed;
    await save();
  }

  /// 记下电脑端地址与名字并落盘。
  ///
  /// ⚠️ **换了地址就把凭据丢掉。** 凭据是**某一台电脑端**签发的，换一台
  /// 它认不出来。留着的话每次上传都会撞 401，而用户看到的是「连不上」——
  /// 他刚改完地址，最自然的结论是「地址填错了」，于是接着改地址，
  /// 真正的原因（该重新配对）永远浮现不出来。丢掉它，界面就会明说「请重新配对」。
  /// [port] 不传就沿用现在的（手填地址那条路走的就是这个默认）。
  Future<void> setHost({
    required String address,
    required String name,
    int? port,
  }) async {
    final next = address.trim();
    final nextPort = port ?? hostPort;

    // 端口变了也算换了台电脑端 —— 同一个地址上可能是两台不同的服务。
    if (next != hostAddress || nextPort != hostPort) credential = '';

    hostAddress = next;
    hostPort = nextPort;
    hostName = name.trim();
    await save();
  }

  /// 端口：认不出的值一律回 [defaultHostPort]。
  ///
  /// 不这么做的话，`device.json` 里一个被手改坏的 `hostPort: 0` 会让每一次
  /// 上传都发去 `http://192.168.1.10:0/` —— 界面只会说「连不上电脑端」，
  /// 而真正的原因在文件里，谁也看不出来。
  static int _portFrom(Object? value) {
    final port = switch (value) {
      final int v => v,
      // 12.0 收，12.5 不收 —— 小数端口是坏值，不是「四舍五入一下」。
      final double v when v == v.roundToDouble() => v.toInt(),
      final String v => int.tryParse(v.trim()) ?? 0,
      _ => 0,
    };

    return port >= 1 && port <= 65535 ? port : defaultHostPort;
  }

  /// 入网成功后把凭据记下来。**落盘** —— 只在内存里留着的凭据，
  /// 重启一次就等于没入过网，每次开 App 都要重新配对。
  ///
  /// ⚠️ 顺手**登记给日志脱敏层**（与电脑端 `DeviceRegistry.NewCredential`
  /// 同一套规矩：谁生成密钥谁登记）。放在这里而不是调用点 ——
  /// 调用点将来会变多，而**漏一处的表现是凭据静默落进日志**。
  Future<void> setCredential(String value) async {
    credential = value.trim();
    AppLog.instance.registerSecret(credential);
    await save();
  }
}

/// 生成一个设备标识。
///
/// **不引 `uuid` 包** —— `dart:math` 的 `Random.secure()` 够了，而且这里要的
/// 不是标准 UUID 格式，是一个「够长、不撞、不被猜到」的串。16 字节 = 32 个
/// 十六进制字符，两个设备随机撞上的概率可以忽略。
String newDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
