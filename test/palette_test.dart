import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/palette.dart';
import 'package:vidlog_mobile/diagnostics/app_log.dart';
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
///    （另加底栏那颗**选中胶囊**的底：接线钉住了、色值也量过两处 ——
///    见 `suites` 里那一条，与 `assertContrast` 末尾那一段）
/// 6. **媒体层那一族对纯黑够看** —— T3 加的那一档，门槛与理由都不同，见那条
///
/// 「`lib/` 里不许有裸色」那条不在这个文件，在 `wiring_test.dart` ——
/// 它要遍历整个 `lib/`，和那边「不许 print」是同一种写法。
///
/// ⚠️ 2026-10-07（改造清单「暗色」）起：`Palette` **不再是一组常量**
/// （见 `palette.dart`），而且**有两套**。所以
/// - 上面第 3~5 条**两套各跑一遍**（`suites` 那张表），亮色特有的
///   （`fromSeed`、卡片浮起来）仍是亮色一条；
/// - 每一处都要写明**量的是哪一套**。**漏写 `p.` / `Palette.light` 是编译错，
///   不是静默的**，所以这个改动不会让哪条断言悄悄量到另一套上去。
///
/// ⚠️ **两套跑同一段代码有个天坑**：若 `Palette.dark` 被写成亮色的副本，
/// 这两遍都会绿（亮色的值压在亮色的底上，当然达标）—— 一条永远绿的绊线。
/// 所以底下另有一条「暗色不是亮色的副本」专门堵它。
void main() {
  /// 两套主题各自的**主题对象 + 色盘**。下面每一条都跑两遍。
  final suites = <String, ({ThemeData theme, Palette palette})>{
    '亮色': (theme: VidLogApp.theme, palette: Palette.light),
    '暗色': (theme: VidLogApp.darkTheme, palette: Palette.dark),
  };

  test('★ 两套主题各挂各的色盘，亮暗跟着系统走', () {
    // ⚠️ 这一条挡的是「两个静态字段自己填错了」（`darkTheme` 里塞了亮色色盘、
    // 或者 `brightness` 忘了填）。**它挡不住「`MaterialApp` 上没挂」** ——
    // 那两个字段是直接从 `VidLogApp` 上读的，接线掉没掉它看不见。
    // 接线由下面那条 `testWidgets`（从**渲染出来的** `MaterialApp` 上读）。
    expect(VidLogApp.theme.extension<Palette>(), same(Palette.light));
    expect(VidLogApp.darkTheme.extension<Palette>(), same(Palette.dark));

    // `brightness` 漏填的话，暗色主题会配着一个 `Brightness.light` 跑 ——
    // 界面大部分是对的，坏的那几处全在 M3 内部（滚动条、输入框光标、
    // `Switch` 轨道、日期选择器），查起来毫无头绪。
    expect(VidLogApp.theme.colorScheme.brightness, Brightness.light);
    expect(VidLogApp.darkTheme.colorScheme.brightness, Brightness.dark);
  });

  testWidgets('★ 接到 MaterialApp 上的是两套、而且跟随系统', (WidgetTester tester) async {
    // ⚠️ **反证过一次**：把 `main.dart` 里 `darkTheme: darkTheme,` 改成
    // `darkTheme: theme,`（接线断掉最可能的形状）⇒ 上面那条**照样全绿**
    // （它读的是静态字段，不看接线），只有这一条会红。
    await tester.pumpWidget(const VidLogApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));

    expect(app.theme!.extension<Palette>(), same(Palette.light));
    expect(app.darkTheme!.extension<Palette>(), same(Palette.dark));
    expect(app.themeMode, ThemeMode.system);
  });

  testWidgets('★ 系统换配色时，日志里留下一条（§6.1 配置变更要记差量）',
      (WidgetTester tester) async {
    // ⚠️ **这条是给「暗色」这个功能配的日志的可失败检查。**
    // 「新增功能必须自带日志」这条规矩在本仓漏过三次，根因就是
    // **它没有能失败的检查** —— 这一条把它变成能红的。
    //
    // ⚠️ **故意不 `init`**（不落盘）：`AppLog` 的缓冲模式**照样进 `tail`**
    // （`app_log.dart` 里 `log()` 那段：`!isReady` 时 `_publishTail`），
    // 而 `init` 会排一个 200ms 的落盘防抖 `Timer`，widget 测试收尾会报
    // 「A Timer is still pending」；改成 `await flush()` 又会在假时钟里
    // **等真磁盘 IO 等到超时**（两条都实测撞过）。缓冲模式两样都没有。
    await AppLog.instance.resetForTesting();
    addTearDown(AppLog.instance.resetForTesting);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const VidLogApp());

    // 亮 → 暗。`didChangePlatformBrightness` 是框架回调，不是我们调的。
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();

    expect(
      AppLog.instance.tail.value.any((line) => line.contains('系统配色换了：暗色')),
      isTrue,
      reason: '系统换配色这件事没留痕 —— 用户报「暗色下看不清」时无从知道'
          '那一刻是哪一套。现有：${AppLog.instance.tail.value}',
    );
  });

  testWidgets('★ 系统是暗的时候，四栏都真的渲染得出来', (WidgetTester tester) async {
    // ⚠️ 暗色这套值**没有在任何真机上过过眼**（出包 + 真机是另一回事）。
    // 这一条能替掉的只有一件事：整棵界面在暗色下**建得出来、不抛**。
    // 它**证明不了**好看不好看 —— 那句话要真机说了才算。
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const VidLogApp());

    // 系统是暗的 ⇒ `ThemeMode.system` 挑出来那一套得是暗色。
    // 门面那一屏的 `Theme` 就是对的取样点（`Scaffold` 挂在它下面）。
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).colorScheme.brightness,
      Brightness.dark,
      reason: '系统是暗的，界面却拿到亮色 —— `themeMode` 或 `darkTheme` 没接上',
    );

    // 四栏逐个切过去。`takeException` 抓的是**建树时抛的那个** —— 比如
    // 某个控件在一棵没挂色盘的主题下面读 `context.palette`。
    for (final icon in const [
      Icons.cloud_upload_outlined, // 备份（默认就落在这一栏）
      Icons.local_shipping_outlined, // 发货
      Icons.assignment_return_outlined, // 退货
      Icons.settings_outlined, // 设置
    ]) {
      await tester.tap(find.byIcon(icon));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '切到 $icon 那一栏时抛了');
    }
  });

  test('★ 暗色不是亮色的副本', () {
    // ⚠️ 底下那几条是**同一段代码跑两遍**，所以「暗色那 20 支照抄亮色」
    // 这件事在那几条里是**看不出来的**（亮色的值压在亮色的底上，当然达标）。
    // 只有这一条会红。
    final light = {
      'primary': Palette.light.primary,
      'blueTint': Palette.light.blueTint,
      'navIndicator': Palette.light.navIndicator,
      'green': Palette.light.green,
      'greenTint': Palette.light.greenTint,
      'amber': Palette.light.amber,
      'amberTint': Palette.light.amberTint,
      'violet': Palette.light.violet,
      'violetTint': Palette.light.violetTint,
      'page': Palette.light.page,
      'card': Palette.light.card,
      'ink': Palette.light.ink,
      'muted': Palette.light.muted,
      'faint': Palette.light.faint,
      'hairline': Palette.light.hairline,
      'danger': Palette.light.danger,
      'primarySolid': Palette.light.primarySolid,
      'greenSolid': Palette.light.greenSolid,
      'dangerSolid': Palette.light.dangerSolid,
      'onAccent': Palette.light.onAccent,
    };
    final dark = {
      'primary': Palette.dark.primary,
      'blueTint': Palette.dark.blueTint,
      'navIndicator': Palette.dark.navIndicator,
      'green': Palette.dark.green,
      'greenTint': Palette.dark.greenTint,
      'amber': Palette.dark.amber,
      'amberTint': Palette.dark.amberTint,
      'violet': Palette.dark.violet,
      'violetTint': Palette.dark.violetTint,
      'page': Palette.dark.page,
      'card': Palette.dark.card,
      'ink': Palette.dark.ink,
      'muted': Palette.dark.muted,
      'faint': Palette.dark.faint,
      'hairline': Palette.dark.hairline,
      'danger': Palette.dark.danger,
      'primarySolid': Palette.dark.primarySolid,
      'greenSolid': Palette.dark.greenSolid,
      'dangerSolid': Palette.dark.dangerSolid,
      'onAccent': Palette.dark.onAccent,
    };

    expect(dark.keys, light.keys, reason: '两张表得一样长，不然下面的比对是漏的');

    final unchanged = [
      for (final key in light.keys)
        if (light[key] == dark[key]) key,
    ];

    // ⚠️ **只有这两支该同值**（压在它们上面的是白字，提亮两头都变差，
    // 见 `palette.dart` 暗色那段）。别的任何一支同值 ⇒ 那一支的暗色值没填。
    expect(
      unchanged,
      equals(<String>['greenSolid', 'dangerSolid']),
      reason: '同值的是 $unchanged —— 除那两支实心块外，暗色下每一支都该是另一个值',
    );
  });

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

  for (final entry in suites.entries) {
    final whose = entry.key; // 「亮色」/「暗色」
    final theme = entry.value.theme;
    final p = entry.value.palette;

    test('★ 底栏选中胶囊的底单独点名 —— 不钉就等于看不出选的是哪一栏（$whose）', () {
      // ⚠️ 这条挡的是**接线**，不是**色值**：`assertContrast` 里那一对量的是
      // `navIndicator` 这个值本身，把 `main.dart` 里的 `indicatorColor:` 那行
      // 删掉，那边照样全绿（指示器会静静落回 `secondaryContainer` = `blueTint`，
      // 暗色下与底栏底 1.00:1）。这就是 Chip 那条的同款坑。
      expect(theme.navigationBarTheme.indicatorColor, p.navIndicator);

      // ⚠️ 还有**第二半**：这个值本身得真的和底栏底分得开。
      // 底栏底 = `surfaceContainer`（`navigation_bar.dart:1440`）。
      // 门槛只有 1.05，**故意松**：非文字那档的 3:1 我们够不着
      // （暗色实测 1.41、亮色 1.12），而「选中的是哪一栏」不只靠这颗胶囊
      // —— 图标色（primary ↔ muted）、标签色、字重都在变。
      // 它挡的就是这一支**原地退回** `blueTint` / `card` 那件事（1.00:1，
      // 也就是这颗令牌当初被开出来的理由）。
      expect(
        contrastRatio(p.navIndicator, theme.colorScheme.surfaceContainer),
        greaterThan(1.05),
        reason: '选中胶囊与底栏底几乎同色 —— 看不出选的是哪一栏',
      );
    });

    test('★ Chip 的底必须单独钉住 —— 不钉就等于隐形（$whose）', () {
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
      // 底就是这一套的 `blueTint` —— 别让它随手漂到别处。
      expect(theme.chipTheme.backgroundColor, p.blueTint);
    });

    test('★ 发货 / 退货两支色走调色板，不是 Material 内置的那两个（$whose）', () {
      // ⚠️ 这一条同时钉住**「只有一处定义」**这件事：列表上的行首竖条、
      // 列表上的小标、详情页那颗胶囊读的都是这个函数。改版前详情页自己抄了
      // 一遍 `returning ? Colors.deepOrange : Colors.blue`，于是列表上是一个橙、
      // 点进去是另一个橙。`record_detail_page_test` 那边还有一条对着它。
      expect(businessTypeLook(p, BusinessType.outbound).color, p.primary);
      expect(businessTypeLook(p, BusinessType.returning).color, p.amber);
      expect(businessTypeLook(p, null).color, p.faint);

      expect(
        businessTypeLook(p, BusinessType.outbound).color,
        isNot(Colors.blue),
      );
      expect(
        businessTypeLook(p, BusinessType.returning).color,
        isNot(Colors.deepOrange),
      );
      expect(
        businessTypeLook(p, null).color,
        isNot(businessTypeLook(p, BusinessType.outbound).color),
        reason: '「判不出来」不能和某一类同色 —— 那等于给它猜了一个类别',
      );

      // 底也要是**成对给的那个**，不是「主色兑 12% 透明」兑出来的。
      expect(businessTypeLook(p, BusinessType.returning).tint, p.amberTint);
      expect(businessTypeLook(p, BusinessType.outbound).tint, p.blueTint);
    });

    test('★ 每个前景色对每个底色都达标 —— 文字 4.5:1、描边 3:1（$whose）', () {
      assertContrast(p, whose);
    });
  }
}

/// WCAG 2.x 的相对亮度：sRGB 分量先线性化，再加权。
double _linear(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _linear(c.r) + 0.7152 * _linear(c.g) + 0.0722 * _linear(c.b);

/// 两个色的对比度。**提到顶层**是因为两处要用（全组合那条、底栏胶囊那条）——
/// 各写一份的话，两处会渐渐不是一个公式。
double contrastRatio(Color a, Color b) {
  final x = _luminance(a), y = _luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// 量**一整套**色盘：每一个前景色压每一个底色。
///
/// ⚠️ 抽成函数是为了**两套各跑一遍**（`main` 里那个循环）。抽的时候留意一件事：
/// 这段代码跑两遍并不能证明暗色那 20 支填对了 —— 见 `main` 里
/// 「暗色不是亮色的副本」那一条。
void assertContrast(Palette p, String whose) {
  // ⚠️ 先用两个已知值校准**公式本身**。公式写错了，下面那个循环会一路
  // 「全绿」地放过所有颜色 —— 一条永远绿的绊线比没有绊线更糟。
  expect(
    contrastRatio(const Color(0xFFFFFFFF), const Color(0xFF000000)),
    closeTo(21, 0.01),
    reason: '纯白压纯黑必须是 21:1 —— 不是的话下面这条公式就是错的',
  );

  // 画**字**的：正文 AA，4.5:1。
  final textColors = <String, Color>{
    'primary': p.primary,
    'green': p.green,
    'amber': p.amber,
    'violet': p.violet,
    'ink': p.ink,
    'muted': p.muted,
    'danger': p.danger,
  };

  // 画**线 / 图标**的：非文字 AA（WCAG 1.4.11），3:1。
  //
  // ⚠️ 只有这一支，而且**它就该在这一档** —— 它是 `ColorScheme.outline`，
  // 也就是全应用输入框的常态边框。把它按 4.5:1 压下去的话，每一道边框都会
  // 变成深灰线，而且会和 `muted` 撞成同一个色（两者都要对最亮的底达标 ⇒
  // 明度被钉死在同一处，色相再怎么分也分不出层次）。
  final strokeColors = <String, Color>{'faint': p.faint};

  // 会被垫在字底下的那些。`hairline` 也在内 —— 缩略图占位、`_hostPill` /
  // `_pairedPill` 的底、清理流水「失败 / 认不出」那两对的底，都是它。
  //
  // ⚠️ **暗色下 `hairline` 是每一支字最紧的那块底**（`muted` 9.85 → 6.97、
  // `danger` 9.41 → 5.46、`faint` 6.96 → 4.04…）—— 它是「跟 `card` 只差
  // 一档」的那块底，字要够亮才压得住它。这正是暗色那五支**没跟电脑端逐字
  // 对齐**的原因（电脑端那张表里没有这么一块既当指示器底、又当分隔线底的档），
  // 量出来的账记在 `palette.dart` 暗色那段。
  // 两套各自最紧的一对：亮色 `danger` 压 `violetTint` 4.52、暗色 `violet` 压
  // `hairline` 5.19。（亮色最紧的那一对不在 `hairline` 上，别照抄过来。）
  final backgrounds = <String, Color>{
    'page': p.page,
    'card': p.card,
    'blueTint': p.blueTint,
    'greenTint': p.greenTint,
    'amberTint': p.amberTint,
    'violetTint': p.violetTint,
    'hairline': p.hairline,
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
        final r = contrastRatio(fg.value, bg.value);
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
  // 亮色下照样绿（两组同值），**暗色那一半才是它会响的地方**
  // （`primary` 换成 blue-300 之后白字只有 1.80:1）。
  check(
    const <String, Color>{'onDark': Palette.onDark},
    4.5,
    '压实心按钮',
    on: <String, Color>{
      'primarySolid': p.primarySolid,
      'greenSolid': p.greenSolid,
      'dangerSolid': p.dangerSolid,
    },
  );

  // `ColorScheme` 那三个实心角色（`primary` / `secondary` / `error`）上面压的
  // 是 `onAccent`，**不是** `onDark` —— 它们的底跟主题走，暗色下是**浅色**。
  // `secondary` 与 `primary` 同值，量一次就够。
  check(
    <String, Color>{'onAccent': p.onAccent},
    4.5,
    '压主题实心',
    on: <String, Color>{'primary': p.primary, 'danger': p.danger},
  );

  // 底栏那颗**选中胶囊**的底（[Palette.navIndicator]）。它进不了上面那张
  // 全组合的表，因为它**只载一支前景**：选中那颗图标
  // （`navigation_bar.dart:1456`，selected 读 `onSecondaryContainer` = `primary`）。
  // 选中那栏的**字**在底栏底上、不在胶囊上（指示器只包住图标），
  // 所以那支字已经在 7×7 里了，不在这儿再量一遍。
  check(
    <String, Color>{'primary': p.primary},
    4.5,
    '压底栏胶囊',
    on: <String, Color>{'navIndicator': p.navIndicator},
  );

  // ⚠️ **扫了多少对也要断言。** 上面那几张名单哪天被谁清空或改名，循环
  // 一次都不跑，这条绊线会一声不响地全绿 —— 与「先 commit 再跑预检 = 扫个空集」
  // 是同一个坑（`precheck-ps1-vacuous-green` 那次）。
  // 7 字 × 7 底 = 49，1 描边 × 7 = 7，6 媒体 × 1 = 6，3 实心，2 主题实心，
  // 1 底栏胶囊，共 68。
  expect(
    pairs,
    greaterThanOrEqualTo(68),
    reason: '$whose 只量了 $pairs 对 —— 颜色或底色的名单八成被动过，这条绊线正在空转',
  );

  expect(
    failures,
    isEmpty,
    reason: '$whose 对比度不够（WCAG AA）。请改 `palette.dart` 里的**色值**，'
        '不要改这条断言的门槛 —— 门槛调低了这条绊线就白写了：\n  '
        '${failures.join('\n  ')}',
  );
}
