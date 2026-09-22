import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    this.hostName = '',
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

  /// 手填的电脑端名字。只用来显示 —— 真连没连上由探测决定，不由它决定。
  String hostName;

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
            deviceName: (json['deviceName'] as String?)?.trim().isNotEmpty == true
                ? (json['deviceName']! as String).trim()
                : defaultDeviceName,
            hostAddress: (json['hostAddress'] as String?)?.trim() ?? '',
            hostName: (json['hostName'] as String?)?.trim() ?? '',
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
        'hostName': hostName,
      }),
    );
  }

  /// 改本机名并落盘。空名退回 [defaultDeviceName] ——
  /// 名字是电脑端用来区分设备的，允许它变空等于允许一台手机在电脑端消失。
  Future<void> rename(String name) async {
    deviceName = name.trim().isEmpty ? defaultDeviceName : name.trim();
    await save();
  }

  /// 记下电脑端地址与名字并落盘。
  Future<void> setHost({required String address, required String name}) async {
    hostAddress = address.trim();
    hostName = name.trim();
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
