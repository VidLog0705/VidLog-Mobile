import 'package:flutter/material.dart';

import '../recording/business_type.dart';

/// 备份页那套配色。**逐格取自需求方那张草图 PNG**（2026-09-28 采样）。
///
/// 为什么要有这个文件：改版前全应用只有 `ColorScheme.fromSeed` 一处定义，
/// 而 M3 的色调算法会把种子色**降饱和**再摊到几十个角色上 ——
/// 草图上那支蓝是 `#1D6AEE`，生成出来是另一支蓝。页面「看着是这个色、
/// 又不是这个色」的根子在这里，不在某个控件上（`实现决策.md` §47）。
///
/// ⚠️ 这里**只有颜色**。不做设计令牌（间距 / 圆角 / 字阶各一层）——
/// 现在错的只有颜色，把错的修掉就是全部。
abstract final class Palette {
  /// 主蓝：主按钮、选中的那一栏、行上那道竖条、链接、发货。
  ///
  /// 草图上是 `#246EF0 → #1564E8` 的竖向渐变、纯色块是 `#1C69F8`。
  /// 取**一个实色**：渐变要多一层 widget，而这一版只修颜色（§47）。
  static const primary = Color(0xFF1D6AEE);

  /// 主蓝的浅底：胶囊 / 小标 / 图标底 / 选中的那一栏的指示器。
  static const blueTint = Color(0xFFE7F1FD);

  /// 已备份 / 在线 / 已配对。
  ///
  /// ⚠️ 当**文字**用时（胶囊里的字、`N 个都已经备份`那句）它对浅底只有
  /// 约 2.2~2.4:1，低于 WCAG AA 的 4.5:1。需求方 2026-09-28 明确选择
  /// **照草图原值**（外观以截图为准），所以这里不做深色变体。
  /// 真机上觉得浅就只改这一个常量 —— 但别改深了又去动胶囊的底。
  static const green = Color(0xFF1BBE6E);
  static const greenTint = Color(0xFFE7F8F3);

  /// 退货，以及「待重试」这类要提醒但不致命的状态。对浅琥珀底约 1.7:1，
  /// 同上：照草图原值。
  static const amber = Color(0xFFFBA012);
  static const amberTint = Color(0xFFFCE8C8);

  /// 总占用那一格的图标色。
  static const violet = Color(0xFF5A5CFC);

  /// ⚠️ **推导值，不是采样值** —— 草图上那一格只有图标是紫的，没有紫的浅底。
  /// 按另外三档同样的深浅比例推出来；真机上觉得不对再调（§47）。
  static const violetTint = Color(0xFFE8E8FE);

  /// 页面底色。
  static const page = Color(0xFFEEF5FD);

  /// 卡片底色。比页面白，卡片才浮得起来。
  static const card = Color(0xFFFBFDFF);

  /// 正文墨色。
  static const ink = Color(0xFF1E2738);

  /// 次要文字。改版前散在文件里的是 `Colors.black54`。
  static const muted = Color(0xFF8B94A2);

  /// 更淡的文字与图标。改版前散着 `black45` / `black38` / `black26` 三种。
  static const faint = Color(0xFFA9B2C0);

  /// 分隔线、浅灰底、缩略图占位。改版前是 `Colors.black12` 那种透明黑。
  ///
  /// 用**实色**：透明黑压在不同的底上会是不同的灰，而草图里这几块是同一个浅灰蓝。
  static const hairline = Color(0xFFE4EBF5);

  /// 语义红：删除 / 备份失败。
  ///
  /// ⚠️ **草图里没有红这一档**（图上画的是「一切正常」的样子）。
  /// 失效与删除是规格 §3.4.3 ★ / §3.5.6 要求必须看得见的，所以照 Material
  /// 的语义红定一个，全应用**只此一处** —— 改版前是 `Colors.red` 与
  /// `Colors.red.shade700` 两个值散在三处。
  static const danger = Color(0xFFD32F2F);
}

/// 业务类型 → **一支色 + 它的浅底**。
///
/// ⚠️ 必须是**一个**函数。行上那道竖条、那个小胶囊、详情页那颗胶囊是同一件事
/// 的三个画法；改版前三处各写各的（`record_detail_page.dart` 写的是
/// `type == returning ? Colors.deepOrange : Colors.blue`），于是列表上是一个橙、
/// 点进去是另一个橙 —— 用户会以为换了类别。
///
/// 放这里而不是放进 [BusinessType]：那个文件今天是**零 import** 的、
/// 与电脑端 `BusinessTypes.cs` 一一对应（§19.1），不值得为存一个颜色
/// 把 `material.dart` 拖进去。
///
/// 返回成对的两个色而不是一个色：草图上的浅底是**采样出来的一个值**
/// （`#E7F8F3` / `#FCE8C8`），不是「主色兑 12% 透明」兑出来的
/// （兑出来的绿比草图上更艳一点）。三处都要底，就一起给。
({Color color, Color tint}) businessTypeLook(BusinessType? type) => switch (type) {
      BusinessType.outbound => (color: Palette.primary, tint: Palette.blueTint),
      BusinessType.returning => (color: Palette.amber, tint: Palette.amberTint),
      // 判不出来：灰。**不是第三种业务类型**，是「不知道」。
      null => (color: Palette.faint, tint: Palette.hairline),
    };
