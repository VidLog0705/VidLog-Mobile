import 'package:flutter/material.dart';

/// 全应用的字号阶梯 —— **本仓定义字号的地方就这一处**。
///
/// ## 为什么要这一层
///
/// 改造清单 T7 把散在各页的 105 处 `fontSize:` 收进了 M3 的 `textTheme`
/// （页面只写「这是说明句」＝ `bodySmall`，不写它多大）。**收得很干净，
/// 但档位本身选小了** —— T7 只把字搬进了主题，没有人回头量过「搬进去的
/// 这几个档到底该多大」。
///
/// 2026-10-09 照 `github.com/PackingProof/PackingProof-Mobile` 对着量了一遍
/// （报告：桌面 `VidLog-界面参照PackingProof-对照报告-2026-10-09.md`），结论是
/// **同类角色本仓小一号**：
///
/// | 角色 | 本仓（改前） | 参照方 |
/// |---|---|---|
/// | 说明句 / 卡片副标 | `bodySmall` **12** —— 50 处，全仓用得最多的一档 | **13** |
/// | 胶囊 / 小注 / 时间戳 | `labelSmall` **11**（12 处） | **12** |
/// | 卡片标题 | 裸 `TextStyle(bold)` 继承 `bodyMedium` → **14** | **17** + `w800` |
///
/// ## 只改这三档 —— 别的档一个字节都没动
///
/// `TextTheme` 传进 `ThemeData` 是**按字段合并**的（Flutter 的
/// `ThemeData` 拿默认字体表 `.merge()` 传入的那份），所以没列出来的
/// `bodyMedium`(14) / `bodyLarge`(16) / `titleLarge`(22) / `headlineSmall`(24)
/// 照旧。这一点由 `test/text_scale_test.dart` 钉住：谁顺手改到别的档，它会红。
///
/// ## 两处刻意的选择
///
/// ⚠️ **卡片标题把 `bold` 一起钉在这里**，而不是让每个调用点 `copyWith` 一遍：
/// 全仓原本有 9 处标题各写一遍裸 `TextStyle(fontWeight: FontWeight.bold)`，
/// 而备份页那张卡与记录卡头早就是 `titleMedium` —— **同一个角色、两个大小**
/// （14 对 16），当年各写各的（正是 T7 要消掉的那种散）。
/// 这一支让它们一起落回同一个定义。
///
/// ⚠️ **采集页那层冻住的 `Theme`（`recorder_page.dart` 的 `_cameraOverlayTheme`）
/// 也读这一份。** 它冻的是**配色** —— `#1565C0` 那份改版前的历史值 ——
/// 不是字号；不跟着读的话，同一句说明在设置页是 13、在采集页还是 12。
/// （它读的这份**只带字号与字重**，字体颜色仍由那一层自己的亮色默认给，
/// 所以暗色下采集页的字不会变成白字压白底。）
///
/// ⚠️ **这是真行为变化**：字变大就会挤布局。本地能证的只有「测试全绿 +
/// 档位没跑偏」，**要出包真机逐屏看**才算完 —— 别把上面那条测试当成「验过了」。
abstract final class TextScale {
  /// 唯一的一份定义。
  static const TextTheme theme = TextTheme(
    /// 说明句、卡片副标（`bodySmall`）。改前 12、参照方 13。
    bodySmall: TextStyle(fontSize: 13),

    /// 胶囊、小注、时间戳、免责句（`labelSmall`）。改前 11、参照方 12。
    ///
    /// ⚠️ 它**不是**「比 `bodySmall` 再小一号」的意思 —— 改完之后两者同值（13 / 12 仍是
    /// 一小一大，但差 1）。真需要「更小」的场合先问需求方，别在这儿再加一档。
    labelSmall: TextStyle(fontSize: 12),

    /// 卡片 / 区块标题（`titleMedium`）。改前继承 14、参照方 17。
    ///
    /// `FontWeight.bold` 钉在这一支上：全仓读它的都是标题（设置页与网盘页的卡片标题、
    /// 备份页与记录卡的卡头、采集页两个面板标题）。
    titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
  );
}
