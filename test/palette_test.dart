import 'dart:math' as math;

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
/// 这里五条，各挡一种「改回去」：
/// 1. 主色是草图采样那支蓝，**不是 `fromSeed` 算出来的**
/// 2. 卡片与页面是**两个**色（同一档的话卡片就浮不起来）
/// 3. 发货 / 退货那两支色是调色板给的，**不是 Material 内置的那两个**
/// 4. Chip 的底单独钉住（不钉就等于隐形）
/// 5. **每个前景色对每个底色都达标** —— 改造清单 T2 的那条绊线
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

  test('★ Chip 的底必须单独钉住 —— 不钉就等于隐形', () {
    final theme = VidLogApp.theme;

    // ⚠️ `_ChipDefaultsM3` **完全没有底色**（`_getBackgroundColor` 返回 null），
    // Chip 于是落到 `canvasColor`（= `colorScheme.surface` = **页面底色**）。
    // 两个筛选胶囊就贴在页面背景上 —— 同色 = 看不见。
    // 这是这一版最容易漏的一处：它不报错、不溢出，只是**没了**。
    expect(theme.chipTheme.backgroundColor, isNotNull);
    expect(
      theme.chipTheme.backgroundColor,
      isNot(theme.colorScheme.surface),
      reason: '胶囊的底和页面底同色的话，它在屏幕上就等于没有',
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

  test('★ 每个前景色对每个底色都达标 —— 文字 4.5:1、描边 3:1', () {
    // WCAG 2.x 的相对亮度：sRGB 分量先线性化，再加权。
    double linear(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

    double luminance(Color c) =>
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);

    double ratio(Color a, Color b) {
      final x = luminance(a), y = luminance(b);
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    // ⚠️ 先用两个已知值校准**公式本身**。公式写错了，下面那个循环会一路
    // 「全绿」地放过所有颜色 —— 一条永远绿的绊线比没有绊线更糟。
    expect(
      ratio(const Color(0xFFFFFFFF), const Color(0xFF000000)),
      closeTo(21, 0.01),
      reason: '纯白压纯黑必须是 21:1 —— 不是的话下面这条公式就是错的',
    );

    // 画**字**的：正文 AA，4.5:1。
    const textColors = <String, Color>{
      'primary': Palette.primary,
      'green': Palette.green,
      'amber': Palette.amber,
      'violet': Palette.violet,
      'ink': Palette.ink,
      'muted': Palette.muted,
      'danger': Palette.danger,
    };

    // 画**线 / 图标**的：非文字 AA（WCAG 1.4.11），3:1。
    //
    // ⚠️ 只有这一支，而且**它就该在这一档** —— 它是 `ColorScheme.outline`，
    // 也就是全应用输入框的常态边框。把它按 4.5:1 压下去的话，每一道边框都会
    // 变成深灰线，而且会和 `muted` 撞成同一个色（两者都要对最亮的底达标 ⇒
    // 明度被钉死在同一处，色相再怎么分也分不出层次）。
    const strokeColors = <String, Color>{'faint': Palette.faint};

    // 会被垫在字底下的那些。`hairline` 也在内 —— 缩略图占位那块就是它。
    const backgrounds = <String, Color>{
      'page': Palette.page,
      'card': Palette.card,
      'blueTint': Palette.blueTint,
      'greenTint': Palette.greenTint,
      'amberTint': Palette.amberTint,
      'violetTint': Palette.violetTint,
      'hairline': Palette.hairline,
    };

    // 量的是**全组合**，不是「实际用到的那几对」。后者要在测试里维护一张
    // 配对表，而哪天有人把某个色挪到一个新底上，那张表不会跟着动 ——
    // 绊线就恰好在这时候瞎掉。全组合偏严一点，代价只是明度再低几个点。
    final failures = <String>[];

    void check(Map<String, Color> colors, double floor, String kind) {
      for (final fg in colors.entries) {
        for (final bg in backgrounds.entries) {
          final r = ratio(fg.value, bg.value);
          if (r < floor) {
            failures.add('$kind ${fg.key} 压在 ${bg.key} 上只有 '
                '${r.toStringAsFixed(2)}:1，要求 $floor:1');
          }
        }
      }
    }

    check(textColors, 4.5, '文字');
    check(strokeColors, 3.0, '描边');

    expect(
      failures,
      isEmpty,
      reason: '对比度不够（WCAG AA）。请改 `palette.dart` 里的**色值**，'
          '不要改这条断言的门槛 —— 门槛调低了这条绊线就白写了：\n  '
          '${failures.join('\n  ')}',
    );
  });
}
