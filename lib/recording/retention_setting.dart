/// 归档成功后本地留多久 —— 发货与退货各一份（规格 §3.5.2.1）。
///
/// 需求方 2026-09-23 原话：「已备份后的本地保留期用户可自行选择，用下拉式选择
/// 不保留/3/5/7/10/15/30/，发货和退货视频同样。」追问后裁决两点：
/// 设置做在两端都要；**发货与退货各自一份，不共用**。
///
/// 与 `StaticStopSetting` / `DurationFallbackSetting` 同一副骨架
/// （`fromConfig` 认任意垃圾输入、超范围回落不夹取），因为它们是同一类东西：
/// 都是**用户选的档位**，都得扛住 I4「配置坏掉不得导致录制失败」。
library;

/// 保留期档位。
///
/// ⚠️ 存盘存的是 [days]（天数），**不是枚举名也不是序号** ——
/// 与两个兜底档位同一个理由：`fromConfig` 认的就是天数。
/// 存名字的话 `int.tryParse('days7')` 会失败，然后**静默回落成默认档位**。
enum RetentionSetting {
  /// 全部保留（默认）。规格 §3.5.2 表格第一行。
  ///
  /// ⚠️ **这一项是规格原有、需求方口头列举时没提的。** 不能去掉：
  /// 它就是规格规定的默认值，也必须是默认值 —— 装完就自动开始删东西
  /// 是不可接受的（§6.2「数据删除必须极度克制」）。
  keepAll(null),

  /// 「不保留」。
  ///
  /// ⚠️ **不等于立刻删。** 规格 §3.5.3③「最近 24 小时内产生的」是
  /// **硬性豁免、用户关不掉**，所以它实际生效是「归档后最快 24 小时清」。
  /// 界面上必须把这句话写出来（踩坑 #13：改了没反应的开关）。
  none(0),

  days3(3),
  days5(5),
  days7(7),
  days10(10),
  days15(15),
  days30(30);

  const RetentionSetting(this.days);

  /// 保留天数。[keepAll] 为 `null`，[none] 为 0。
  ///
  /// 这两者的区别是**真实存在**的：`null` = 永远不删；`0` = 归档后第二天就能删。
  /// 所以类型是 `int?` 而不是拿 0 或 -1 去兼职表示「不删」。
  final int? days;

  /// 配置坏掉、或者读不出来时用的值。
  static const fallback = RetentionSetting.keepAll;

  /// 界面上显示的名字（也就下拉里那一列）。
  String get label => switch (this) {
        RetentionSetting.keepAll => '全部保留',
        RetentionSetting.none => '不保留',
        _ => '$days 天',
      };

  /// 从配置解析，**任何非法输入都回落到 [fallback]**。
  ///
  /// 回落到「全部保留」而不是「不保留」是刻意的：解析失败时朝**少删**的那头落。
  static RetentionSetting fromConfig(Object? raw) {
    if (raw is RetentionSetting) return raw;

    final days = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value.trim()),
      _ => null,
    };

    if (days == null) return fallback;

    for (final setting in RetentionSetting.values) {
      if (setting.days == days) return setting;
    }

    // 超范围（比如配了 999）也回落，不夹取 —— 夹取会悄悄改变用户配置的语义。
    return fallback;
  }
}
