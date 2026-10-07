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
/// 这里六条，各挡一种「改回去」：
/// 1. 主色是草图采样那支蓝，**不是 `fromSeed` 算出来的**
/// 2. 卡片与页面是**两个**色（同一档的话卡片就浮不起来）
/// 3. 发货 / 退货那两支色是调色板给的，**不是 Material 内置的那两个**
/// 4. Chip 的底单独钉住（不钉就等于隐形）
/// 5. **每个前景色对每个底色都达标** —— 改造清单 T2 的那条绊线
/// 6. **媒体层那一族对纯黑够看** —— T3 加的那一档，门槛与理由都不同，见那条
///
/// ⚠️ 2026-10-07（改造清单「暗色」）起，`Palette` **不再是一组常量**
/// （见 `palette.dart`）⇒ 这里每一处都要写明**量的是哪一套**（`Palette.light`）。
/// **漏写 `Palette.light` 是编译错，不是静默的**，所以这个改动不会让哪条断言
/// 悄悄量到另一套上去。
///
/// 「`lib/` 里不许有裸色」那条不在这个文件，在 `wiring_test.dart` ——
/// 它要遍历整个 `lib/`，和那边「不许 print」是同一种写法。
void main() {
  test('★ 主题主色是草图采样那支蓝，不是 fromSeed 算出来的', () {
    final scheme = VidLogApp.theme.colorScheme;

    expect(scheme.primary, Palette.light.primary);

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

    expect(scheme.surface, Palette.light.page);
    expect(
      scheme.surfaceContainerLow,
      Palette.light.card,
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
    expect(
      businessTypeLook(Palette.light, BusinessType.outbound).color,
      Palette.light.primary,
    );
    expect(
      businessTypeLook(Palette.light, BusinessType.returning).color,
      Palette.light.amber,
    );
    expect(businessTypeLook(Palette.light, null).color, Palette.light.faint);

    expect(
      businessTypeLook(Palette.light, BusinessType.outbound).color,
      isNot(Colors.blue),
    );
    expect(
      businessTypeLook(Palette.light, BusinessType.returning).color,
      isNot(Colors.deepOrange),
    );
    expect(
      businessTypeLook(Palette.light, null).color,
      isNot(businessTypeLook(Palette.light, BusinessType.outbound).color),
      reason: '「判不出来」不能和某一类同色 —— 那等于给它猜了一个类别',
    );

    // 底也要是**成对给的那个**，不是「主色兑 12% 透明」兑出来的。
    expect(
      businessTypeLook(Palette.light, BusinessType.returning).tint,
      Palette.light.amberTint,
    );
    expect(
      businessTypeLook(Palette.light, BusinessType.outbound).tint,
      Palette.light.blueTint,
    );
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
    final textColors = <String, Color>{
      'primary': Palette.light.primary,
      'green': Palette.light.green,
      'amber': Palette.light.amber,
      'violet': Palette.light.violet,
      'ink': Palette.light.ink,
      'muted': Palette.light.muted,
      'danger': Palette.light.danger,
    };

    // 画**线 / 图标**的：非文字 AA（WCAG 1.4.11），3:1。
    //
    // ⚠️ 只有这一支，而且**它就该在这一档** —— 它是 `ColorScheme.outline`，
    // 也就是全应用输入框的常态边框。把它按 4.5:1 压下去的话，每一道边框都会
    // 变成深灰线，而且会和 `muted` 撞成同一个色（两者都要对最亮的底达标 ⇒
    // 明度被钉死在同一处，色相再怎么分也分不出层次）。
    final strokeColors = <String, Color>{'faint': Palette.light.faint};

    // 会被垫在字底下的那些。`hairline` 也在内 —— 缩略图占位、`_hostPill` /
    // `_pairedPill` 的底、清理流水「失败 / 认不出」那两对的底，都是它。
    final backgrounds = <String, Color>{
      'page': Palette.light.page,
      'card': Palette.light.card,
      'blueTint': Palette.light.blueTint,
      'greenTint': Palette.light.greenTint,
      'amberTint': Palette.light.amberTint,
      'violetTint': Palette.light.violetTint,
      'hairline': Palette.light.hairline,
    };

    // 量的是**全组合**，不是「实际用到的那几对」。后者要在测试里维护一张
    // 配对表，而哪天有人把某个色挪到一个新底上，那张表不会跟着动 ——
    // 绊线就恰好在这时候瞎掉。全组合偏严一点，代价只是明度再低几个点。
    final failures = <String>[];
    var pairs = 0;

    void check(Map<String, Color> colors, double floor, String kind,
        {Map<String, Color>? on}) {
      for (final fg in colors.entries) {
        for (final bg in (on ?? backgrounds).entries) {
          pairs++;
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

    // ⚠️ **媒体层另起一档，门槛是「对纯黑够看」而不是「对每个浅底够看」。**
    //
    // 上面那两档量的底是 [page] / [card] 这类**我们定的**浅底，所以能量全组合；
    // 这一族的底是**实时画面**（取景、播放中的视频、一张缩略图）——
    // 白墙、仓库顶灯、白面单，整片白的时候纯白字就是看不见。
    // 这**不能靠调颜色解决**，靠的是遮罩与描边（`_strokedText` 那两层字）。
    //
    // 所以这一条只守住一个下限：黑画面的那一头要够看。
    // 真机上遇到亮画面看不清时，出路是**加厚遮罩**，不是把这几个色调深 ——
    // 调深了在黑画面上反而是自杀，而黑画面比白画面常见得多。
    check(
      const <String, Color>{
        'onDark': Palette.onDark,
        'onDarkSoft': Palette.onDarkSoft,
        'onDarkFaint': Palette.onDarkFaint,
        'mediaWarn': Palette.mediaWarn,
        'mediaRecord': Palette.mediaRecord,
        'mediaPick': Palette.mediaPick,
      },
      4.5,
      '压深底',
      on: const {'backdrop': Palette.backdrop},
    );

    // `onDark` 另外还压在**本仓自己画的实心色块**上：设置页那两个齿轮方块、
    // 备份页「电脑备份」那颗圆、以及【开始】/【结束】那两个按钮。
    //
    // ⚠️ 这三支读的是 `*Solid`，**不是** `primary` / `green` / `danger` ——
    // 后者是「暗底上的字」，暗色下会变浅，白字压上去根本看不见。
    // 这条断言就是那次拆分的凭据：把 `*Solid` 换回 `primary` 那一组，
    // 亮色下照样绿（两组同值），**暗色那一半才是它会响的地方**。
    check(
      const <String, Color>{'onDark': Palette.onDark},
      4.5,
      '压实心按钮',
      on: <String, Color>{
        'primarySolid': Palette.light.primarySolid,
        'greenSolid': Palette.light.greenSolid,
        'dangerSolid': Palette.light.dangerSolid,
      },
    );

    // `ColorScheme` 那三个实心角色（`primary` / `secondary` / `error`）上面压的
    // 是 `onAccent`，**不是** `onDark` —— 它们的底跟主题走，暗色下是**浅色**。
    // `secondary` 与 `primary` 同值，量一次就够。
    check(
      <String, Color>{'onAccent': Palette.light.onAccent},
      4.5,
      '压主题实心',
      on: <String, Color>{
        'primary': Palette.light.primary,
        'danger': Palette.light.danger,
      },
    );

    // ⚠️ **扫了多少对也要断言。** 上面那几张名单哪天被谁清空或改名，循环
    // 一次都不跑，这条绊线会一声不响地全绿 —— 与「先 commit 再跑预检 = 扫个空集」
    // 是同一个坑（`precheck-ps1-vacuous-green` 那次）。
    // 7 字 × 7 底 = 49，1 描边 × 7 = 7，6 媒体 × 1 = 6，3 实心，2 主题实心，共 67。
    expect(
      pairs,
      greaterThanOrEqualTo(67),
      reason: '只量了 $pairs 对 —— 颜色或底色的名单八成被动过，这条绊线正在空转',
    );

    expect(
      failures,
      isEmpty,
      reason: '对比度不够（WCAG AA）。请改 `palette.dart` 里的**色值**，'
          '不要改这条断言的门槛 —— 门槛调低了这条绊线就白写了：\n  '
          '${failures.join('\n  ')}',
    );
  });
}
