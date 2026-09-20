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

/// 录制相关阈值。
class RecorderConfig {
  const RecorderConfig({
    this.staticStop = StaticStopSetting.fallback,
    this.durationPromptAfter = const Duration(minutes: 4),
    this.durationPromptRepeatEvery = const Duration(minutes: 5),
    this.durationPromptGrace = const Duration(minutes: 1),
    this.storageFreeWarningBytes = 2 * 1024 * 1024 * 1024,
    this.batteryWarningPercent = 15,
    this.thermalWarning = ThermalLevel.severe,
  });

  /// 静止停录档位（§3.3.3）。
  final StaticStopSetting staticStop;

  /// 录制满多久开始问「是否停止」（§3.3.4 的 4 分钟）。
  final Duration durationPromptAfter;

  /// 点了「继续」之后，隔多久再问一次。
  final Duration durationPromptRepeatEvery;

  /// 问了之后多久没操作就默认继续（并随即停止）。
  final Duration durationPromptGrace;

  /// 剩余存储低于此值就告警并主动收尾。
  final int storageFreeWarningBytes;

  /// 电量低于此百分比就告警并主动收尾。
  final int batteryWarningPercent;

  /// 温度达到此级别就告警并主动收尾。
  final ThermalLevel thermalWarning;

  /// 全部回落到硬兜底值。
  static const hardFallback = RecorderConfig();
}

/// 设备热度等级。
///
/// 顺序**必须**由轻到重 —— [reaches] 靠 [index] 比较。
/// 档位对齐 Android 的 `PowerManager.THERMAL_STATUS_*`。
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
