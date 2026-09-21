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

/// 录制相关阈值。
class RecorderConfig {
  const RecorderConfig({
    this.staticStop = StaticStopSetting.fallback,
    this.durationFallback = DurationFallbackSetting.fallback,
    this.promptAfterOverride,
    this.durationPromptRepeatEvery = const Duration(minutes: 5),
    this.durationPromptGrace = const Duration(minutes: 1),
  });

  /// 静止停录档位（§3.3.3）。
  final StaticStopSetting staticStop;

  /// 时长兜底档位（§3.3.4）。
  final DurationFallbackSetting durationFallback;

  /// 首次询问时机的**覆盖值**。
  ///
  /// **只给真机验收用** —— 真的等 4 分钟会让「时长兜底」那条验收变成苦差事。
  /// 非 null 且 [durationFallback] 已启用时，它取代档位里配的分钟数。
  /// 产品行为由 [durationFallback] 决定，这里只是让验收跑得动。
  final Duration? promptAfterOverride;

  /// 首次询问的时机。
  Duration get effectivePromptAfter =>
      promptAfterOverride ?? durationFallback.duration;

  /// 点了「继续」之后，隔多久再问一次。
  final Duration durationPromptRepeatEvery;

  /// 问了之后多久没操作就默认继续（并随即停止）。
  final Duration durationPromptGrace;

  /// 全部回落到硬兜底值。
  static const hardFallback = RecorderConfig();
}
