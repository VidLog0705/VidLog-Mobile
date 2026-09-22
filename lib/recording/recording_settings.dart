import 'dart:convert';
import 'dart:io';

import 'recorder_config.dart';
import 'recording_workspace.dart' show writeFileAtomically;
import 'work_mode.dart';

/// 用户选的录制设置（`<root>/settings.json`）。
///
/// 落盘的四项：工作模式、静止停录档位、时长兜底档位、语音播报开关。
///
/// ## 为什么单独一个文件，不并进 `device.json`
///
/// `device.json` 装的是**本机身份**，而它读坏的代价不可逆：读不出 `deviceId`
/// 就只能重新生成，这台手机在电脑端**变成一台新设备**，之前的机位名再也对不上。
///
/// 设置是**每改一次开关就写一次**的东西。混进同一个文件，等于让一条高频、
/// 无关的写路径反复去碰身份 —— 把那个不可逆故障的出错面白白放大几十倍。
///
/// ## ⚠️ `accelerated` 故意不在这里
///
/// 它是**真机验收用的**（把时长兜底的首次询问压到 20 秒）。
/// 一旦落盘，验收完忘了关，**真实录制**就会在开录 20 秒后被问一次
/// 「是否停止录制」—— 一个调试开关就此变成产品行为，而且用户看着它像是
/// 正常功能。所以它每次启动都归 false，只活在内存里。
///
/// ## ⚠️ 读坏了**不抛异常**
///
/// 这是 I4 的落点：**任何配置的缺失 / 格式错误 / 值超范围都不得导致录制失败**。
/// 所以 [load] 把「文件不存在」和「文件是垃圾」当成同一件事 —— 一律走硬兜底，
/// 照常返回一份可用的设置。
///
/// 与 `device.json` 的另一个区别：**这里不主动建文件**。没有文件 = 用户从没改过，
/// 默认值就是对的，没必要为一个从没发生过的事写一次盘。等用户真改了再写。
class RecordingSettings {
  RecordingSettings({
    required this.path,
    required this.mode,
    required this.staticStop,
    required this.durationFallback,
    required this.voiceEnabled,
  });

  final String path;

  /// 工作模式（规格 §3.3.1）。
  WorkMode mode;

  /// 静止停录档位（规格 §3.3.3）。
  StaticStopSetting staticStop;

  /// 时长兜底档位（规格 §3.3.4）。
  DurationFallbackSetting durationFallback;

  /// 语音播报开关。
  ///
  /// ⚠️ **默认开，而且读不出来也回落到开。** 理由与别的项相反，值得写下来：
  /// 规格 §3.3.2 的错码保护**就是靠播报**告诉用户「扫的不是同一件」。
  /// 这一项静默变成「关」（比如字段丢了、被人手改成字符串），用户不会发现 ——
  /// 他只会以为「这个功能没做」，然后把错的包裹录进去。
  /// **静默关掉一个提示功能，比静默开着吵一点严重得多。**
  bool voiceEnabled;

  /// 读设置。**任何读取失败都回落到硬兜底值，绝不抛。**
  static Future<RecordingSettings> load(String path) async {
    var json = const <String, Object?>{};

    final file = File(path);
    if (await file.exists()) {
      try {
        json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      } on Object {
        // 半个 JSON / 顶层不是对象 / 编码坏了 → 全走兜底。
        // **不 rethrow**：设置读不出来不能拦住录制（I4）。
      }
    }

    return RecordingSettings(
      path: path,
      mode: WorkMode.fromConfig(json['mode']),
      staticStop: StaticStopSetting.fromConfig(json['staticStop']),
      durationFallback: DurationFallbackSetting.fromConfig(json['durationFallback']),
      // 只认真正的 bool。**不认字符串 'false'** —— 认它就得在这里开始猜
      // 各种写法（'0' / 'no' / '' 算不算），而每多认一种就多一种把
      // 「本来是关」读成「开」或反之的机会。这个文件是我们自己写的。
      voiceEnabled: switch (json['voiceEnabled']) {
        final bool value => value,
        _ => true,
      },
    );
  }

  /// 写回盘。走原子写：掉电时要么是旧的、要么是新的，不会留半个文件。
  Future<void> save() async {
    final file = File(path);
    await file.parent.create(recursive: true);

    await writeFileAtomically(
      path,
      const JsonEncoder.withIndent('  ').convert({
        // 模式存**名字**不存序号：序号看着短，但枚举一旦重排，
        // 老文件会被**静默**解析成另一个模式 —— 录制行为当场变了而没人知道。
        'mode': mode.name,

        // 两个档位存**分钟数**不存名字，因为 `fromConfig` 认的就是分钟数
        // （它是给远端配置写的，那边传过来的就是个数）。
        // 存名字的话 `int.tryParse('minutes3')` 会失败，然后**静默回落成默认档位**。
        'staticStop': staticStop.minutes,
        'durationFallback': durationFallback.minutes,

        'voiceEnabled': voiceEnabled,
      }),
    );
  }
}
