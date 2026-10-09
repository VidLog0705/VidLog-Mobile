import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/text_scale.dart';
import 'package:vidlog_mobile/main.dart';

/// 字号阶梯（需求 ①「手机端小字太多」，2026-10-09）。
///
/// ## 为什么要有这一条
///
/// 这一刀**只改了三个数字**，而全仓**没有一条既有的断言读字号**
/// （`palette_test` 管色、`wiring_test` 只管「有没有人在页面里散着写
/// `fontSize:`」）。所以下面这四件事**一件都不会有人喊**：
///
/// 1. 有人把值改回去（12 / 11 / 继承 14）；
/// 2. 有人顺手多改一档（把 `bodyMedium` 也抬了 —— 那会连带改掉全仓每一句
///    裸 `Text()`，量级完全不同）；
/// 3. `ThemeData` 的行为被误判 —— 它必须是**按字段合并**；要是哪天变成
///    整张覆盖，没列出来的档会是 null（不像今天这样落回默认值），
///    界面会大面积掉字号而**不报错**；
/// 4. 亮色那份改了、暗色那份没跟着（两份主题走同一个 `_buildTheme`，
///    这条把「不许拆成两份」也钉住）。
///
/// ## ⚠️ 一个能让你量错数的坑（2026-10-09 亲自踩过）
///
/// **`ThemeData.textTheme` 里没有字号**，它是**配色表**：`ThemeData` 只把
/// `Typography.black/white`（`blackMountainView` 那一份 —— 只有
/// `color`/`fontFamily`，`fontSize` 全 null）并进去，字号那半（geometry）
/// 要等 `Theme.of(context)` 那一刻才按**当前 locale 的 `ScriptCategory`**
/// 合并（`material/theme.dart:139` 那句 `ThemeData.localize`）。
///
/// 所以**读 `VidLogApp.theme.textTheme.bodySmall.fontSize` 永远是 null** ——
/// 那不是「框架没给字号」，是「问错了对象」。屏幕上真正的字号要按
/// `Theme.of` 那种算法拿，下面的 `seenByUser()` 就是那个算法。
///
/// M3 给的几何（`typography.dart` 里 `_M3Typography.englishLike` / `dense` /
/// `tall` 三份，**字号三份完全一样**，只差 `textBaseline`）：
/// `bodySmall 12`、`labelSmall 11`、`titleMedium 16`、`bodyMedium 14`、
/// `bodyLarge 16`、`titleLarge 22`、`headlineSmall 24`、`labelLarge 14`。
///
/// 顺带一条：裸 `Text(...)` 不吃 `textTheme` 的哪一档，它继承
/// `Material` 给的 `DefaultTextStyle`（= `bodyMedium`，**14**）。
/// 改前那 9 处裸 `TextStyle(fontWeight: bold)` 卡片标题因此是 **14**，
/// 不是 `titleMedium` 的 16。
///
/// ## 它**证不到**的东西（别把它当成「验过了」）
///
/// 字变大之后**布局会不会挤**。本地只能证「档位没跑偏」，
/// 真机逐屏看才算完 —— 见 `lib/app/text_scale.dart` 里那段 ⚠️。
///
/// 采集页那层冻住的 `Theme` 有没有接上，由 `wiring_test.dart` 里那条
/// 按源码读的绊线管（`textTheme: TextScale.theme` 那一行），
/// 因为 `_cameraOverlayTheme` 是私有的，从这里够不到。
void main() {
  /// 屏幕上真正生效的那张 `textTheme` —— 照 `Theme.of(context)` 的算法
  /// （`theme.dart:139`）：把 M3 的 locale 几何并到配色表上。
  ///
  /// 应用是中文 ⇒ 真实设备走 `ScriptCategory.dense`；三份几何字号一样，
  /// 这里取 `dense` 只为贴近真机。
  TextTheme seenByUser(ThemeData theme) =>
      ThemeData.localize(theme, theme.typography.geometryThemeFor(ScriptCategory.dense)).textTheme;

  double? sizeOf(TextTheme t, String role) => switch (role) {
    'bodySmall' => t.bodySmall?.fontSize,
    'labelSmall' => t.labelSmall?.fontSize,
    'titleMedium' => t.titleMedium?.fontSize,
    'bodyMedium' => t.bodyMedium?.fontSize,
    'bodyLarge' => t.bodyLarge?.fontSize,
    'titleLarge' => t.titleLarge?.fontSize,
    'headlineSmall' => t.headlineSmall?.fontSize,
    'labelLarge' => t.labelLarge?.fontSize,
    _ => throw ArgumentError('没定义这个档：$role'),
  };

  test('★ 改的那三档：说明句 13、小标 12、卡片标题 17', () {
    expect(sizeOf(TextScale.theme, 'bodySmall'), 13);
    expect(sizeOf(TextScale.theme, 'labelSmall'), 12);
    expect(sizeOf(TextScale.theme, 'titleMedium'), 17);
  });

  test('★ 屏幕上真的生效（不是只写在这份常量里）', () {
    // 光 断言 `TextScale.theme` 自己不算数 —— 它得**真的赢过** M3 几何
    // （改前 12 / 11 / 16）。上面那句「按字段合并」在这里被正面量到。
    final t = seenByUser(VidLogApp.theme);
    expect(sizeOf(t, 'bodySmall'), 13);
    expect(sizeOf(t, 'labelSmall'), 12);
    expect(sizeOf(t, 'titleMedium'), 17);
    // 卡片标题那 9 处**改前是裸 `Text(bold)` ⇒ 继承 `bodyMedium` = 14**。
    // 钉住「改前 14」这个起点，好让「改完是几」有得比。
    expect(sizeOf(t, 'bodyMedium'), 14, reason: '卡片标题的改前起点');
  });

  test('★ 卡片标题那支必须带 bold', () {
    // 改前是各调用点自己写裸 `TextStyle(fontWeight: FontWeight.bold)`；
    // 现在只在这一处定义。**漏掉 `bold` 不会报错**，只会让全仓标题一起瘦下来
    // —— 而那是「字变大」这一刀里最容易被当成「也没差多少」的一处。
    expect(TextScale.theme.titleMedium?.fontWeight, FontWeight.bold);
  });

  test('★ 没列的档一个都没动 —— 照 M3 默认（0 处「顺手也改了」）', () {
    // 这一条同时是「`ThemeData` 是按字段合并」的证据：
    // 它要是整张覆盖，下面这些要么是 null、要么落不到 M3 的值。
    // ⚠️ 必须走 `seenByUser()` —— 直接读 `VidLogApp.theme.textTheme`
    // 会拿到**没有字号的配色表**，这里会全 null（见文件头那个坑）。
    final t = seenByUser(VidLogApp.theme);
    expect(sizeOf(t, 'bodyMedium'), 14);
    expect(sizeOf(t, 'bodyLarge'), 16);
    expect(sizeOf(t, 'titleLarge'), 22);
    expect(sizeOf(t, 'headlineSmall'), 24);
    expect(sizeOf(t, 'labelLarge'), 14);
  });

  test('★ 亮、暗两份主题给的是同一套字号（字号不随配色变）', () {
    final light = seenByUser(VidLogApp.theme);
    final dark = seenByUser(VidLogApp.darkTheme);
    for (final role in [
      'bodySmall',
      'labelSmall',
      'titleMedium',
      'bodyMedium',
      'bodyLarge',
      'titleLarge',
    ]) {
      expect(sizeOf(dark, role), sizeOf(light, role), reason: role);
    }
  });

  test('★ 采集页那层冻住的 Theme 那种建法，也吃得到这一套', () {
    // 采集页的 `_cameraOverlayTheme` 是**自己新建**的一份 `ThemeData`
    // （不是从 `VidLogApp.theme` 派生的 —— 它要冻住 `#1565C0` 那份历史配色），
    // 所以它必须**显式**带上 `textTheme: TextScale.theme`。
    // 下面按它那种建法复现一遍：证「带上就吃得到」这个机制成立。
    final overlayLike = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
      textTheme: TextScale.theme,
    );
    expect(sizeOf(seenByUser(overlayLike), 'bodySmall'), 13);
    expect(sizeOf(seenByUser(overlayLike), 'labelSmall'), 12);
    expect(sizeOf(seenByUser(overlayLike), 'titleMedium'), 17);
    // ⚠️ 它**不该**把字色一起带过去：这一份只定义字号与字重，
    // 颜色仍由那一层自己的亮色默认给（否则暗色下采集页会白字压白底）。
    expect(TextScale.theme.bodySmall?.color, isNull);
    expect(overlayLike.textTheme.bodySmall?.color, isNotNull);
  });
}
