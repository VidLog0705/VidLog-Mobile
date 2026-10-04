import 'dart:async';

import 'package:flutter/material.dart';

import 'app/palette.dart';
import 'app/recorder_page.dart';
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
  static final theme = ThemeData(
    colorScheme: const ColorScheme(
      brightness: Brightness.light,

      primary: Palette.primary,
      onPrimary: Palette.onDark,
      primaryContainer: Palette.blueTint,
      onPrimaryContainer: Palette.primary,

      // secondary 这一族在现代 M3 里只剩三个读者：`FilledButton.tonal` 的底、
      // `NavigationBar` 选中态的指示器、`SegmentedButton` 选中项的底 ——
      // 三样在草图里都是**浅蓝底 + 蓝字**。
      secondary: Palette.primary,
      onSecondary: Palette.onDark,
      secondaryContainer: Palette.blueTint,
      onSecondaryContainer: Palette.primary,

      error: Palette.danger,
      onError: Palette.onDark,

      // 页面底色。`Scaffold` 与 `AppBar` 的默认底都取它。
      surface: Palette.page,
      onSurface: Palette.ink,

      // Card / Dialog / NavigationBar 各读一个 container 档
      // （`card.dart` / `dialog.dart` / `navigation_bar.dart`）——
      // 三样在草图里都是「近白浮在浅蓝页面上」，所以三档同值。
      // 钉在这里是**三行覆盖三样**；写成三个组件主题要写三遍。
      surfaceContainerLow: Palette.card,
      surfaceContainer: Palette.card,
      surfaceContainerHigh: Palette.card,
      // 设置页那两块说明底（`scheme.surfaceContainerHighest`）用浅蓝。
      surfaceContainerHighest: Palette.blueTint,

      onSurfaceVariant: Palette.muted,
      // 输入框的常态边框取 outline；Chip 的边框、Divider 取 outlineVariant。
      outline: Palette.faint,
      outlineVariant: Palette.hairline,

      // 卡片的投影色。草图上的卡片是「软投影」，不是硬边。
      shadow: Color(0x1A1E2738),
    ),

    // ── 下面这几个是**色角色盖不住**的地方，逐个点名 ──

    // NavigationBar 的**选中标签**：M3 默认给的是 `onSurface`（墨色），
    // 而草图里「选中的那一栏」是蓝的。指示器与图标色走
    // secondaryContainer / onSecondaryContainer，已经在上面钉住了。
    navigationBarTheme: NavigationBarThemeData(
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected)
              ? Palette.primary
              : Palette.muted,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
      // 抬起来会有一道横贯屏幕的投影，而这一页是平的。
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),

    // 两个筛选胶囊（来源 / 日期）。它们**一个颜色字面量都没有**，全靠主题 ——
    // 不钉这里的话 Chip 的底会落到 `canvasColor`（= 页面底色），
    // 在页面背景上等于看不见（`chip.dart` 里 `_ChipDefaultsM3` 没有底）。
    chipTheme: const ChipThemeData(
      backgroundColor: Palette.blueTint,
      // 有底就不要描边了 —— 浅蓝底 + 灰描边在草图上是两个东西叠在一起。
      side: BorderSide.none,
      labelStyle: TextStyle(color: Palette.primary),
      deleteIconColor: Palette.primary,
      iconTheme: IconThemeData(color: Palette.primary, size: 18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),

    // AppBar 的底已经是 surface（页面色）、字已经是 onSurface，只有一处要改：
    // 内容滚到它下面时它会**抬起来**加一道投影，而这一页该是平的。
    appBarTheme: const AppBarThemeData(
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),

    // 让没写颜色的图标也落在调色板上（默认是 `kDefaultIconDarkColor`，
    // 一个与配色无关的固定黑）。
    iconTheme: const IconThemeData(color: Palette.ink),

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
      home: const RecorderPage(),
    );
  }
}
