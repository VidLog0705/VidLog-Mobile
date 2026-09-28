import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/palette.dart';
import 'package:vidlog_mobile/main.dart';
import 'package:vidlog_mobile/recording/business_type.dart';

/// 备份页那套配色（`docs/实现决策.md` §47）。
///
/// ## 为什么要有这一条
///
/// 改版前这一页**一条颜色断言都没有** —— `viewfinder_painter_test` 验的是
/// 取景框那支画笔（那次没动它），`record_detail_page_test` 只是把
/// `Colors.green` 当夹具传进去。整套主题被改回去，没有一条会红。
///
/// 这里三条，各挡一种「改回去」：
/// 1. 主色是草图采样那支蓝，**不是 `fromSeed` 算出来的**
/// 2. 卡片与页面是**两个**色（同一档的话卡片就浮不起来）
/// 3. 发货 / 退货那两支色是调色板给的，**不是 Material 内置的那两个**
void main() {
  test('★ 主题主色是草图采样那支蓝，不是 fromSeed 算出来的', () {
    final scheme = VidLogApp.theme.colorScheme;

    expect(scheme.primary, Palette.primary);

    // ⚠️ 这条挡的是「把 `ThemeData(colorScheme: ColorScheme.fromSeed(...))`
    // 写回来」。fromSeed 从种子跑出来的 primary 与**种子本身不相等**
    // （先降饱和、再摊到色调板上），所以拿它算一遍来比是最直接的判据。
    expect(
      scheme.primary,
      isNot(ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)).primary),
      reason: '又用回 fromSeed 了 —— 那套算法会把草图上那支蓝降饱和成另一支',
    );
  });

  test('★ 卡片是近白、页面是浅蓝 —— 两个不能是同一个色', () {
    final scheme = VidLogApp.theme.colorScheme;

    expect(scheme.surface, Palette.page);
    expect(
      scheme.surfaceContainerLow,
      Palette.card,
      reason: 'Card 的底取的就是 surfaceContainerLow（card.dart）',
    );
    expect(
      scheme.surface,
      isNot(scheme.surfaceContainerLow),
      reason: '卡片和页面同色的话，卡片就浮不起来了 —— 草图上是有投影的',
    );
  });

  test('★ 发货 / 退货两支色走调色板，不是 Material 内置的那两个', () {
    // ⚠️ 这一条同时钉住**「只有一处定义」**这件事：列表上的行首竖条、
    // 列表上的小标、详情页那颗胶囊读的都是这个函数。改版前详情页自己抄了
    // 一遍 `returning ? Colors.deepOrange : Colors.blue`，于是列表上是一个橙、
    // 点进去是另一个橙。`record_detail_page_test` 那边还有一条对着它。
    expect(businessTypeLook(BusinessType.outbound).color, Palette.primary);
    expect(businessTypeLook(BusinessType.returning).color, Palette.amber);
    expect(businessTypeLook(null).color, Palette.faint);

    expect(businessTypeLook(BusinessType.outbound).color, isNot(Colors.blue));
    expect(businessTypeLook(BusinessType.returning).color, isNot(Colors.deepOrange));
    expect(
      businessTypeLook(null).color,
      isNot(businessTypeLook(BusinessType.outbound).color),
      reason: '「判不出来」不能和某一类同色 —— 那等于给它猜了一个类别',
    );

    // 底也要是**成对给的那个**，不是「主色兑 12% 透明」兑出来的。
    expect(businessTypeLook(BusinessType.returning).tint, Palette.amberTint);
    expect(businessTypeLook(BusinessType.outbound).tint, Palette.blueTint);
  });
}
