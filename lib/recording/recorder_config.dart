/// 录制行为的可配置项 —— 以及**它们各自的硬兜底值**。
///
/// 规格 §3.1.1 与 §5.2 的硬约束：
/// **任何远端配置的缺失 / 格式错误 / 值超范围，都不得导致录制失败**，
/// 一律回落到本地硬编码的安全值（不变量 I4）。
///
/// 所以这个文件里的每个 `fromConfig` 都**必须**接受任意垃圾输入并给出可用值 ——
/// 它们是录制链路上唯一允许说「随便给什么都行」的地方，而正是因此才安全。
library;

/// 静止停录档位。规格 §3.3.3：可选 关闭 / 2 / 3 / 4 / 5 分钟，**默认 3**。
enum StaticStopSetting {
  off(0),
  minutes2(2),
  minutes3(3),
  minutes4(4),
  minutes5(5);

  const StaticStopSetting(this.minutes);

  /// 分钟数；[off] 为 0。
  final int minutes;

  bool get isEnabled => minutes > 0;

  Duration get duration => Duration(minutes: minutes);

  /// 下拉里显示的那一行字。
  ///
  /// ⚠️ [off] 显示成「关闭」而不是「0 分钟」—— 摆一个写着 0 的档位，
  /// 用户得自己翻译「0 分钟是什么意思」。
  String get label => isEnabled ? '$minutes 分钟' : '关闭';

  /// 配置坏掉时用的值。
  static const fallback = StaticStopSetting.minutes3;

  /// 从远端配置解析，**任何非法输入都回落到 [fallback]**。
  static StaticStopSetting fromConfig(Object? raw) {
    if (raw is StaticStopSetting) return raw;

    final minutes = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value.trim()),
      _ => null,
    };

    if (minutes == null) return fallback;

    for (final setting in StaticStopSetting.values) {
      if (setting.minutes == minutes) return setting;
    }

    // 超范围（比如配了 999）也回落，不夹取 —— 夹取会悄悄改变用户配置的语义。
    return fallback;
  }
}

/// 时长兜底档位。规格 §3.3.4。
///
/// 规格原文写的是「**对所有档位生效（含"关闭"）**」——
/// 也就是静止设为关闭时时长兜底照样触发。**这一条后来改了**：
/// 需求方要求把时长兜底也做成可选档位，让用户自己决定，
/// 因为它会在每次录制超过设定分钟数时打断正常的长录制。
///
/// 所以现在的语义是：**两项防忘停录各自独立可选**。
enum DurationFallbackSetting {
  off(0),
  minutes4(4),
  minutes5(5),
  minutes6(6);

  const DurationFallbackSetting(this.minutes);

  /// 录制满多少分钟开始询问；[off] 为 0。
  final int minutes;

  bool get isEnabled => minutes > 0;

  Duration get duration => Duration(minutes: minutes);

  /// 下拉里显示的那一行字。见 [StaticStopSetting.label]。
  String get label => isEnabled ? '$minutes 分钟' : '关闭';

  /// 配置坏掉时用的值。沿用规格原本的 4 分钟。
  static const fallback = DurationFallbackSetting.minutes4;

  /// 从远端配置解析，**任何非法输入都回落到 [fallback]**。
  static DurationFallbackSetting fromConfig(Object? raw) {
    if (raw is DurationFallbackSetting) return raw;

    final minutes = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value.trim()),
      _ => null,
    };

    if (minutes == null) return fallback;

    for (final setting in DurationFallbackSetting.values) {
      if (setting.minutes == minutes) return setting;
    }

    return fallback;
  }
}

/// 面单条码最短长度。**规格里原本没有这一项**，是需求方 2026-09-28
/// 对着自绘的设置界面新加的（见 `实现决策.md` 对应那一节）。
///
/// ## 它拦的是「印在面单上的码」，不是「人敲进去的单号」
///
/// 相机识码是**连续**的，画面里飘过一个短条码就会触发一次识别。真实面单的
/// 单号都有十几位，短码几乎一定是**误识**（货架条码、包装上的其他码、
/// 甚至是别家快递的面单）。这一项让相机侧把短的挡掉，免得录出一堆
/// 挂着垃圾单号的片段。
///
/// ⚠️ **手工输入那条路不走这个判据**（`_simulateScan`）。那是人明确敲的，
/// 拦它等于「短单号根本录不了」，而设置的名字本身就限定了「**面单**条码」。
///
/// ## 为什么是「位数」而不是正则
///
/// 承运转单号的形态按承运商而异，规格 §3.2.3 连校验位都还没定
/// （见 `WaybillNumber` 的「已知缺口」）。在拿到具体规则之前，
/// 位数是这个系统**唯一能诚实测量**的东西（§13.1）。
enum WaybillMinLength {
  /// 不设下限 —— 相机侧来什么认什么（老行为）。
  unlimited(0),
  d8(8),
  d9(9),
  d10(10),
  d11(11),
  d12(12),
  d13(13),
  d14(14),
  d15(15);

  const WaybillMinLength(this.length);

  /// 最少几位；[unlimited] 为 0。
  ///
  /// ⚠️ **数的是归一化之后的长度**（去掉空白、统一大写），不是原始字节数。
  /// 按原样数的话，一个带空格的 11 位单号会被算成 12 位。
  final int length;

  bool get isEnabled => length > 0;

  String get label => length == 0 ? '不限' : '$length 位';

  /// 配置坏掉时用的值。**需求方指定的默认档：11 位。**
  static const fallback = WaybillMinLength.d11;

  /// 从远端配置解析，**任何非法输入都回落到 [fallback]**（不变量 I4）。
  ///
  /// ⚠️ 与其他几个档位同一条规矩：**超范围也回落，不夹取** ——
  /// 夹取会把「配错了」悄悄变成一个用户没选过的档位。
  static WaybillMinLength fromConfig(Object? raw) {
    if (raw is WaybillMinLength) return raw;

    final length = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value.trim()),
      _ => null,
    };

    if (length == null) return fallback;

    for (final setting in WaybillMinLength.values) {
      if (setting.length == length) return setting;
    }

    return fallback;
  }
}

/// 录制相关阈值。
class RecorderConfig {
  const RecorderConfig({
    this.staticStop = StaticStopSetting.fallback,
    this.durationFallback = DurationFallbackSetting.fallback,
    this.waybillMinLength = WaybillMinLength.fallback,
    this.recordAudio = true,
    this.liveShare = false,
    this.durationPromptRepeatEvery = const Duration(minutes: 5),
    this.durationPromptGrace = const Duration(minutes: 1),
    // 资源告警的三个阈值（规格 §3.1.1）。⚠️ **这是本地硬兜底值** ——
    // 规格说这类阈值「由配置下发，**且必须有本地硬兜底值**」，
    // 而配置下发（M6）还没做，所以今天走的就是这三个。
    //
    // ⚠️ 这三个数是**照历史恢复的**（2026-09-21 那次审计删掉了整条链，
    // 2026-09-27 恢复），不是重新拍的 —— 原值见 `实现决策.md` §7.2 与 §44。
    this.storageFreeWarningBytes = 2 * 1024 * 1024 * 1024,
    this.batteryWarningPercent = 15,
    this.thermalWarning = ThermalLevel.severe,
  });

  /// 静止停录档位（§3.3.3）。
  final StaticStopSetting staticStop;

  /// 时长兜底档位（§3.3.4）。
  final DurationFallbackSetting durationFallback;

  /// 面单条码最短长度（需求方 2026-09-28 新增，见 [WaybillMinLength]）。
  ///
  /// 它由 `ScanGate` 执行，也就是**只作用于相机识码**。
  final WaybillMinLength waybillMinLength;

  /// 录像文件里带不带声音（需求方 2026-09-28 加）。
  ///
  /// ⚠️ 它**不改变这台手机出不出声** —— 那是 `voiceEnabled`。
  /// 这个只决定写进 mp4 的那条音轨。两者可以同时开（那时播报会被录进去）。
  final bool recordAudio;

  /// 实时共享：把相机画面推给电脑端（规格 §3.8）。
  ///
  /// ## ⚠️ 与 [recordAudio] 同一类：**开会话时就定死的**
  ///
  /// 推流那一路上挂的是**相机会话的第二路输出**，而往一个正在跑的会话里
  /// 加输出要让会话重新配置 —— 那一下帧会断一小截，断的是**正在录的证据**。
  /// 规格 §3.8 写死了「录制是证据，推流是便利，两者冲突时无条件舍推流」，
  /// 所以这里**不搞中途热插拔**：与录音、与录制规格同一条规矩，
  /// **改了等下次「开始工作」**（设置页那张「什么时候生效」的卡上点着名）。
  final bool liveShare;

  /// 首次询问的时机 —— **就是用户选的那一档**。
  ///
  /// ⚠️ 2026-10-09 之前这里还能被一个「验收加速」覆盖（`promptAfterOverride`
  /// 把 4 分钟压到 20 秒，好让真机验收不必干等）。那个开关只在设置页上露过面，
  /// 需求方 2026-10-09 要求把给需求方看/开发测试用的东西去掉，就随卡片一起删了。
  /// 现在没有第二条路径能改它。
  Duration get effectivePromptAfter => durationFallback.duration;

  /// 点了「继续」之后，隔多久再问一次。
  final Duration durationPromptRepeatEvery;

  /// 问了之后多久没操作就默认继续（并随即停止）。
  final Duration durationPromptGrace;

  /// 剩余存储低于此值就告警并主动收尾（规格 §3.1.1）。
  ///
  /// **2 GB**：一段 1080P 录像约 8 Mbps ≈ 1 MB/s，2 GB 够录半个多小时 ——
  /// 留这些余量是为了「**主动安全收尾**」那一半真的做得完
  /// （收尾要写索引、算哈希、可能还要 remux，都得占地方）。
  final int storageFreeWarningBytes;

  /// 电量低于此百分比就告警并主动收尾（规格 §3.1.1）。
  ///
  /// **15%**：够跑完一次收尾加一次上传重试，又不至于等到系统自己关机
  /// —— 那才会留下不可播的半截文件（规格那句「而不是等崩溃」）。
  final int batteryWarningPercent;

  /// 温度达到此级别就告警并主动收尾（规格 §3.1.1）。
  final ThermalLevel thermalWarning;

  /// 全部回落到硬兜底值。
  static const hardFallback = RecorderConfig();
}

/// 设备热度等级（规格 §3.1.1）。
///
/// ⚠️ 顺序**必须**由轻到重 —— [reaches] 靠 [index] 比较。
/// 档位与 Android 的 `PowerManager.THERMAL_STATUS_*` **一一对齐**，
/// 原生报上来的就是那个整数。
///
/// ⚠️ iOS 那边只有四档（`ProcessInfo.ThermalState`），映射见
/// `RecorderPlugin.swift` 的 `readResources` —— 两端的档位是**同一套**，
/// 这样判定层不必知道报告的是哪个平台。
enum ThermalLevel {
  nominal,
  light,
  moderate,
  severe,
  critical,
  emergency;

  /// 是否达到或超过 [limit]。
  bool reaches(ThermalLevel limit) => index >= limit.index;

  /// 从远端配置解析，非法输入回落到 [nominal]（即「不因此告警」）。
  ///
  /// ⚠️ 往**轻**的那头落，与别处「朝少删/朝保守落」相反 —— 这里是对的：
  /// 认不出的热度当成「过热」会让每一台机器都停录，而那是**误停**。
  /// （与 §3.1.1 的意图也不冲突：热到真有危险时原生一定会报得出一个**合法**档。）
  static ThermalLevel fromConfig(Object? raw) {
    if (raw is ThermalLevel) return raw;

    if (raw is int && raw >= 0 && raw < ThermalLevel.values.length) {
      return ThermalLevel.values[raw];
    }

    if (raw is String) {
      final name = raw.trim().toLowerCase();
      for (final level in ThermalLevel.values) {
        if (level.name == name) return level;
      }
    }

    return ThermalLevel.nominal;
  }
}
