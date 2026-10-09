import 'dart:async';

import 'package:flutter/material.dart';

import 'app/corners.dart';
import 'app/palette.dart';
import 'app/recorder_page.dart';
import 'app/text_scale.dart';
import 'diagnostics/app_log.dart';
import 'diagnostics/error_handlers.dart';

void main() {
  // ⚠️ 三层未捕获异常钩子里的**第三层**（前两层在 installFlutterErrorHandlers）。
  // 全局异常必须带堆栈落盘 —— 这个应用退到后台之后随时可能被杀，
  // 用户报「它自己没了」时，磁盘上那条是唯一可查的东西。
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      installFlutterErrorHandlers();
      runApp(const VidLogApp());
    },
    (error, stack) {
      AppLog.instance.error('界面', '未捕获异常（根 zone）', error: error, stackTrace: stack);
    },
  );
}

/// VidLog 手机端。
///
/// 现场采集：连续分段录像、扫码打点、停录机制。
/// 规格见母仓 `VidLog0705/VidLog` 的 `docs/01-行为规格书.md` §3.1–3.3。
///
/// 界面按**需求方口述的要求**实现（2026-09-21）：底部四栏
/// （备份 / 发货 / 退货 / 设置），按钮蓝色。
/// 配色照需求方自绘的备份页草图重新采样了一遍（2026-09-28，`实现决策.md` §47）。
class VidLogApp extends StatelessWidget {
  const VidLogApp({super.key});

  /// 全应用主题。
  ///
  /// ⚠️ **不再是 `ColorScheme.fromSeed`。** 那套是 M3 的色调算法算出来的，
  /// 它把种子色降饱和之后再摊到几十个角色上 —— 草图上的蓝是 `#1D6AEE`，
  /// 算出来是另一个蓝。
  ///
  /// 这里把**草图上有对应关系的角色逐个写死**；草图没画到的
  /// （`inverseSurface` / `scrim` / `tertiary`…）一个都不补，交给
  /// `ColorScheme` 自己的兜底（每个角色都是 `_x ?? 某个基色`，
  /// 见 `color_scheme.dart`）。补了就是没人读的第二份定义。
  ///
  /// 写成 `static final` 而不是在 `build` 里构造：守卫测试
  /// （`test/palette_test.dart`）直接读它，不必 pump 一个 widget。
  ///
  /// ⚠️ 2026-10-07（改造清单「暗色」）起，它**不再是常量**：改成 [_buildTheme]
  /// 按一份 [Palette] 现算 —— 同一个函数喂 [Palette.light] 就是这一份。
  /// **一份色盘只走一个函数**：两套主题各写一遍的话，「亮色改了、暗色忘了改」
  /// 是迟早的事，而且忘了改的那一处不会有任何测试喊。
  static final theme = _buildTheme(Palette.light);

  /// 暗色那一份。**同一个 [_buildTheme]**（见上：一份色盘只走一个函数）。
  ///
  /// ⚠️ 电脑端在**系统偏好读不到时按亮色走**（`ThemePalette.IsDark`：
  /// 只有注册表明确写着 `0` 才算深色）。手机端这一侧不需要那个判断 ——
  /// `ThemeMode.system` 是框架的，读不到平台亮度时它给的也是亮色
  /// （引擎源码写死的：`platform_dispatcher.dart:1240` 「If the platform has
  /// no preference, [platformBrightness] defaults to [Brightness.light].」）。
  static final darkTheme = _buildTheme(Palette.dark);

  /// 把一份色盘铺成一份主题。
  ///
  /// ⚠️ 这里的 `const` 全去掉了（原来整棵主题是 `const`）—— 色盘的值是
  /// **实例字段**，不是编译期常量。这不是笔误，也别想用 `const` 塞回去。
  static ThemeData _buildTheme(Palette p) => ThemeData(
    colorScheme: ColorScheme(
      brightness: p.brightness,

      primary: p.primary,
      onPrimary: p.onAccent,
      primaryContainer: p.blueTint,
      onPrimaryContainer: p.primary,

      // secondary 这一族在现代 M3 里原本有三个读者：`FilledButton.tonal` 的底、
      // `NavigationBar` 选中态的指示器、`SegmentedButton` 选中项的底 ——
      // 三样在草图里都是**浅蓝底 + 蓝字**。
      // ⚠️ 现在只剩**一个**真的读它（`tonal` 那颗钮）：另外两处 2026-10-07 起
      // 各自点名 [Palette.selectedTint]（见上面那个底栏主题、下面那个分段选择器主题），
      // 因为「选中」那一类的底暗色下不能再用 `blueTint`（与卡片撞成 1.00:1）。
      // 这里**留着不动**：`blueTint` 就是 `tonal` 该有的那个浅蓝。
      secondary: p.primary,
      onSecondary: p.onAccent,
      secondaryContainer: p.blueTint,
      onSecondaryContainer: p.primary,

      error: p.danger,
      onError: p.onAccent,

      // 页面底色。`Scaffold` 与 `AppBar` 的默认底都取它。
      surface: p.page,
      onSurface: p.ink,

      // Card / Dialog / NavigationBar 各读一个 container 档
      // （`card.dart` / `dialog.dart` / `navigation_bar.dart`）——
      // 三样在草图里都是「近白浮在浅蓝页面上」，所以三档同值。
      // 钉在这里是**三行覆盖三样**；写成三个组件主题要写三遍。
      surfaceContainerLow: p.card,
      surfaceContainer: p.card,
      surfaceContainerHigh: p.card,
      // 设置页那两块说明底（`scheme.surfaceContainerHighest`）用浅蓝。
      surfaceContainerHighest: p.blueTint,

      onSurfaceVariant: p.muted,
      // 输入框的常态边框取 outline；Chip 的边框、Divider 取 outlineVariant。
      outline: p.faint,
      outlineVariant: p.hairline,

      // 卡片的投影色。草图上的卡片是「软投影」，不是硬边。
      shadow: Color(0x1A1E2738),
    ),

    // ⚠️ **把这一份色盘塞进主题。** 界面里 `context.palette` 取的就是它
    // （`palette.dart` 末尾的 `PaletteOf`）。漏了这一行不会有编译错 ——
    // 只会在第一次取色时抛「空值上的 `!`」。
    extensions: <ThemeExtension<dynamic>>[p],

    // ── 字号阶梯 ──
    //
    // ⚠️ **定义那份在 `app/text_scale.dart`，这里只是接线。** 2026-10-09 之前
    // 这里**没有 `textTheme`**：全应用字号 = Flutter 默认 M3，于是「说明句」
    // 就落在 M3 的 `bodySmall`(12)、「小标」落在 `labelSmall`(11) —— 档位是
    // 框架给的，不是有人选过的。改动的理由与只改哪三档，全在那一份的注释里。
    //
    // ⚠️ 这一句传进去的是**按字段合并**的部分表，没列的档照旧走默认。
    // 别在这里就地改字号：`test/wiring_test.dart` 冻结的是**本文件**（底栏那支
    // 标签样式），而档位值只许有一个定义处。
    textTheme: TextScale.theme,

    // ── 下面这几个是**色角色盖不住**的地方，逐个点名 ──

    // NavigationBar 的**选中标签**：M3 默认给的是 `onSurface`（墨色），
    // 而草图里「选中的那一栏」是蓝的。选中那颗**图标**走
    // `onSecondaryContainer`，已经在上面钉住了。
    //
    // ⚠️ **选中那颗胶囊的底单独点名**（`indicatorColor`）：
    // 不写它就落到 `secondaryContainer`（= `blueTint`，`navigation_bar.dart:1463`），
    // 而 `blueTint` 压底栏底在暗色下是 1.00:1 —— 看不出选的是哪一栏。
    // 值、以及它只载哪一支前景，全在 `palette.dart` 的 `selectedTint` 上。
    // （同一个角色还有一处：设置页那四个分段选择器，在下面那个主题里。）
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: p.selectedTint,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected) ? p.primary : p.muted,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
      // 抬起来会有一道横贯屏幕的投影，而这一页是平的。
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),

    // 设置页那四个分段选择器（工作模式 / 编码 / 分辨率 / 方向）。
    //
    // ⚠️ **选中的那一段单独点名底**：不写它就落到 `secondaryContainer`
    // （= `blueTint`，`segmented_button.dart:1214`，那个 M3 默认值的出处在
    // `_SegmentedButtonDefaultsM3` 里），
    // 而分段选择器是画在**卡片**上的 —— `blueTint` 与 `card` 在暗色下只差
    // 1.00:1，等于看不出选的是哪一段（与底栏那颗胶囊同一个毛病）。
    // 亮色下 `selectedTint` 与 `blueTint` **同值** ⇒ 亮色一个像素都没动。
    //
    // ⚠️ 这里**只给底色**，别的什么都不碰：`SegmentedButtonThemeData.style`
    // 是**部分** `ButtonStyle`，没写的属性照旧走 M3 默认
    // （选中那颗勾、描边、选中的字色都还是原来的）。
    // 未选中那一支返回 `null` —— M3 的默认本来就是「没有底」（透明）。
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? p.selectedTint : null,
        ),
      ),
    ),

    // 两个筛选胶囊（来源 / 日期）。它们**一个颜色字面量都没有**，全靠主题 ——
    // 不钉这里的话 Chip 的底会落到 `canvasColor`（= 页面底色），
    // 在页面背景上等于看不见（`chip.dart` 里 `_ChipDefaultsM3` 没有底）。
    chipTheme: ChipThemeData(
      backgroundColor: p.blueTint,
      // 有底就不要描边了 —— 浅蓝底 + 灰描边在草图上是两个东西叠在一起。
      side: BorderSide.none,
      labelStyle: TextStyle(color: p.primary),
      deleteIconColor: p.primary,
      iconTheme: IconThemeData(color: p.primary, size: 18),
      shape: RoundedRectangleBorder(
        // ⚠️ 用 `BorderRadius.all(...)` 而不是 `circular(...)`。原来这里写的
        // 理由是「整棵主题是 `const`，而 `circular` 不是 const 构造器」——
        // **那个前提 2026-10-07 已经不成立了**（主题改成按色盘现算，`const` 全去掉）。
        // 这里**没有跟着换成 `circular`**：两者同值（`circular` 内部就是 `all`），
        // 换了只是徒增一次改动。
        borderRadius: BorderRadius.all(Radius.circular(Corners.pill)),
      ),
    ),

    // AppBar 的底已经是 surface（页面色）、字已经是 onSurface，只有一处要改：
    // 内容滚到它下面时它会**抬起来**加一道投影，而这一页该是平的。
    appBarTheme: AppBarThemeData(
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),

    // 让没写颜色的图标也落在调色板上（默认是 `kDefaultIconDarkColor`，
    // 一个与配色无关的固定黑）。
    iconTheme: IconThemeData(color: p.ink),

    // ⚠️ **不写 `cardTheme`。** Card 的 M3 默认（面纱透明、elevation 1、
    // margin `EdgeInsets.all(4)`、圆角 12）**正是要的**，要换的只有颜色，
    // 而颜色已经在 `surfaceContainerLow` 上换掉了。
    // 一旦写了 `cardTheme`，就**别顺手写 margin** —— 这一页有的卡片传了
    // `margin: EdgeInsets.zero`（三张统计卡）、有的没传（电脑备份 / 视频记录），
    // 靠的就是这个默认值；主题里钉死一个 margin 会把没传的那几张一起改掉。
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VidLog',
      theme: theme,
      darkTheme: darkTheme,
      // ⚠️ **跟随系统**，不做应用内开关（需求方 2026-10-07 拍板）。
      // 写成 `ThemeMode.light` 就退回改版前的样子，而且暗色那 20 支值
      // 会变成一堆没人走的死代码 —— 但**不会**有测试喊（绊线量的是色值，
      // 不是「有没有被用上」）。改这一行之前先想清楚。
      themeMode: ThemeMode.system,
      // ⚠️ **主题切换是硬切。** 默认值（`kThemeAnimationDuration` = 200ms）会让
      // `ColorScheme` 与 `ThemeData` 那几百个属性在两种配色之间插值 ——
      // 而 `Palette` 的 `lerp` 是**过半才换**（见 `palette.dart`）⇒
      // 那 200ms 里界面是一半在飘、一半已经切完的**谁也没验过的中间态**。
      // 亮暗之间没有中间态；电脑端那份实现同样是硬切。
      themeAnimationDuration: Duration.zero,
      home: const RecorderPage(),
    );
  }
}
