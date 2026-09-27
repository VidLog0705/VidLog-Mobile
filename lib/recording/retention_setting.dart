/// 归档成功后本地留多久（规格 §3.5.2.1）。
///
/// 需求方 2026-09-24 把口径从「发货 / 退货各一份」扩成**四个数**：
/// 发货 / 退货 × **已备份 / 未备份**。选项 9 项（不保留 / 3 / 5 / 7 / 10 / 15 / 30 /
/// **自定义** / 全部保留），默认「全部保留」。
///
/// ⚠️ **两列的语义完全相反**（这一节最要紧的一句话）：
/// - **已备份**：到期**真删本地副本**（先过回查），起算点 = 归档成功时刻；
/// - **未备份**：到期**只标红、只催上传，永不自动删**，起算点 = 录完时刻。
///   那是唯一副本，删了就永久没了（I2）。
///
/// 与电脑端 `VidLog.Desktop.Core/Cleanup/RetentionSettings.cs` 是**同一份规格的两半**：
/// 档位、上限、回落方向都**逐个对齐**。
library;

/// 保留期档位。
///
/// ⚠️ 存盘存的是 [days]（天数），**不是名字也不是序号** ——
/// 与两个兜底档位同一个理由：`fromConfig` 认的就是天数。
/// 存名字的话 `int.tryParse('days7')` 会失败，然后**静默回落成默认档位**。
///
/// ⚠️ 2026-09-27 起它从 `enum` 变成 `class` —— 因为规格的 9 项里有一项是
/// 「**自定义**」，而枚举表达不了「列表之外的任意正整数天」。
/// 静态常量名与原来的枚举值**逐字相同**，所以调用点没变。
class RetentionSetting {
  const RetentionSetting(this.days);

  /// 保留天数。[keepAll] 为 `null`，[none] 为 0。
  ///
  /// 这两者的区别是**真实存在**的：`null` = 永远不删；`0` = 归档后最快 24 小时能删。
  /// 所以类型是 `int?` 而不是拿 0 或 -1 去兼职表示「不删」。
  final int? days;

  /// 全部保留（默认）。规格 §3.5.2.1。
  ///
  /// ⚠️ **选项列表里「不保留」排在最前面、「全部保留」排在最后，
  /// 而默认值仍然是它** —— 绝不能因为「不保留」排第一就当默认（规格特意提醒过）：
  /// 那会在 24 小时后开始删东西。
  static const keepAll = RetentionSetting(null);

  /// 「不保留」。
  ///
  /// ⚠️ **不等于立刻删。** 规格 §3.5.3③「最近 24 小时内产生的」是
  /// **硬性豁免、用户关不掉**，所以它实际生效是「归档后最快 24 小时清」。
  /// 界面上必须把这句话写出来（踩坑 #13：改了没反应的开关）。
  static const none = RetentionSetting(0);

  static const days3 = RetentionSetting(3);
  static const days5 = RetentionSetting(5);
  static const days7 = RetentionSetting(7);
  static const days10 = RetentionSetting(10);
  static const days15 = RetentionSetting(15);
  static const days30 = RetentionSetting(30);

  /// 下拉里那 8 个**具体档位**（第 9 项「自定义」是个输入框，不是一个值）。
  ///
  /// 顺序即需求方给的顺序（规格 §3.5.2.1）。
  static const standard = <RetentionSetting>[
    none,
    days3,
    days5,
    days7,
    days10,
    days15,
    days30,
    keepAll,
  ];

  /// 天数上限。**规格明说这类阈值由实现标定**（§3.5.2.1），
  /// 本仓与电脑端取同一个值：**10 年** —— 远大于任何真实工位的保留期，
  /// 而小于「手抖多打几个 9」那种值。
  static const maxDays = 3650;

  /// 配置坏掉、或者读不出来时用的值。
  static const fallback = keepAll;

  /// 档位是不是「列表里那 8 个之一」；不是就是用户自己填的天数。
  bool get isCustom => !standard.contains(this);

  /// 界面上显示的名字（也就下拉里那一列）。
  String get label => switch (this) {
        RetentionSetting.keepAll => '全部保留',
        RetentionSetting.none => '不保留',
        _ => '$days 天',
      };

  /// 从配置解析，**任何非法输入都回落到 [fallback]**。
  ///
  /// 回落到「全部保留」而不是「不保留」是刻意的：解析失败时朝**少删**的那头落。
  ///
  /// ⚠️ 落在 [standard] 之外的正整数**不再是回落** —— 那是「自定义」，
  /// 是规格点名要的第 9 项。超过 [maxDays]（或负数）才算越界，才回落。
  /// 电脑端 `RetentionSetting.FromConfig` 同一条口径。
  static RetentionSetting fromConfig(Object? raw) {
    if (raw is RetentionSetting) return raw;

    final days = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value.trim()),
      _ => null,
    };

    if (days == null) return fallback;

    // 越界（负数、或超过上限）回落，**不夹取** —— 夹取会悄悄改变用户配置的语义
    // （把 99999 变成 3650 天），而回落至少是「这个值不认，用默认的」。
    if (days < 0 || days > maxDays) return fallback;

    for (final setting in standard) {
      if (setting.days == days) return setting;
    }

    return RetentionSetting(days);
  }

  @override
  bool operator ==(Object other) =>
      other is RetentionSetting && other.days == days;

  @override
  int get hashCode => days.hashCode;

  @override
  String toString() => label;
}
