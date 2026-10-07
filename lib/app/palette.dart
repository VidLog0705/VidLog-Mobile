import 'package:flutter/material.dart';

import '../recording/business_type.dart';

/// 备份页那套配色。**色相逐格取自需求方那张草图 PNG**（2026-09-28 采样）。
///
/// 为什么要有这个文件：改版前全应用只有 `ColorScheme.fromSeed` 一处定义，
/// 而 M3 的色调算法会把种子色**降饱和**再摊到几十个角色上 ——
/// 草图上那支蓝，生成出来是另一支蓝。页面「看着是这个色、
/// 又不是这个色」的根子在这里，不在某个控件上（`实现决策.md` §47）。
///
/// ⚠️ 这里**只有颜色**。本文件**不做**设计令牌。
///
/// 2026-10-07（改造清单 P1）改掉了这句话的后半段。原话是「不做设计令牌
/// （间距 / 圆角 / 字阶各一层）—— 现在错的只有颜色，把错的修掉就是全部」，
/// 那句当时成立；**圆角后来补了一层**，就写在隔壁 [Corners]（`corners.dart`）。
/// 现在这句如实说的是：**颜色只在本文件，圆角只在 [Corners]**，两不相混。
///
/// 字阶**不在任何一层** —— 它归 M3 的 `textTheme`（`main.dart`，T7 清的零）。
/// 间距**有意不做**，理由见 [Corners] 的说明。
///
/// ---
///
/// **2026-10-04：整体压暗过一次（改造清单 T2）。** 采样值只保住了色相，
/// 明度全部下调到「在任何一块浅底上都够看」的程度 —— 草图上的绿与橙
/// 对浅底只有 1.7~2.4:1，远低于 WCAG AA 正文要求的 4.5:1。
/// 需求方当日裁定：**放弃「照草图原值」，改为深色化到达标**。
///
/// 两档门槛，别混：
/// - **画字**的颜色 ≥ **4.5:1**（正文 AA）。
/// - **画线 / 画图标**的颜色 ≥ **3:1**（非文字 AA，1.4.11）。只有 [faint] 是这一档。
///
/// `test/palette_test.dart` 里有一条绊线逐个色、逐个底地量，改值前先看它。
///
/// ---
///
/// **2026-10-07（改造清单「暗色」）：本类不再是一组常量，而是一整套跟主题走的颜色**
/// （`ThemeExtension`）—— 亮色是 [Palette.light]，暗色是 [Palette.dark]，
/// 由 `main.dart` 按系统偏好挑一套（`themeMode: ThemeMode.system`）。
///
/// ⚠️ **界面里取色写 `context.palette.x`**（见文件末尾的 `PaletteOf`），
/// **不要**写 `Palette.light.x`：那等于把亮色钉死在那个控件上，系统切到暗色时
/// 它不动，而且没有任何东西会喊（电脑端 `FindResource` 那个坑的同款）。
/// 本文件之外也**不许**写 `Color(0x…)` —— `wiring_test.dart` 钉着这条。
///
/// 字段分三类，别混：
/// - **跟主题走的** = 本类的**实例字段**（`page` / `ink` / `primary`…）。
/// - **不跟主题走的** = `static const`（`onDark` / `backdrop` / `mediaWarn`…）——
///   它们的底是**取景画面**，不是纸张，亮暗两套下都是同一张画面。
/// - **实心块** = `primarySolid` / `greenSolid` / `dangerSolid`：压在它们上面的字
///   是白的（[onDark]），所以**它们自己必须够深**；但仍然各写一份，
///   因为它们是「跟主题走」那一类。
///   ⚠️ 这三支**不是同一种底**：`greenSolid` / `dangerSolid` 的底是**取景画面**，
///   两套同值；`primarySolid` 的底是**纸面**（设置页表头 / 卡片），
///   所以它还得跟纸面分得开 —— 两套不同值。见字段说明。
///
/// ⚠️ **下面每支字段的说明里，「2026-10-04（T2）：A → B」这种改动史记的都是
/// 亮色那一支的** —— 下面那些值就是 [Palette.light] 里的那些。
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.brightness,
    required this.primary,
    required this.blueTint,
    required this.selectedTint,
    required this.green,
    required this.greenTint,
    required this.amber,
    required this.amberTint,
    required this.violet,
    required this.violetTint,
    required this.page,
    required this.card,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.hairline,
    required this.danger,
    required this.primarySolid,
    required this.greenSolid,
    required this.dangerSolid,
    required this.onAccent,
  });

  /// 亮色那一套。
  ///
  /// ⚠️ **值就是 2026-10-07 之前全应用在用的那些，一个都没动。**
  /// （这一次把常量搬成实例字段是**纯搬家**，`flutter test` 的条数与
  /// `palette_test` 那条全组合绊线的结论都和搬之前一样。）
  static const light = Palette(
    brightness: Brightness.light,
    primary: Color(0xFF1160E6),
    blueTint: Color(0xFFE7F1FD),
    // ⚠️ 与 `blueTint` **同值**，而且是有意的 —— 亮色这一半因此一个像素都没动
    // （暗色下这两支走不同的值，那才是这一支存在的理由）。见字段说明。
    selectedTint: Color(0xFFE7F1FD),
    green: Color(0xFF117946),
    greenTint: Color(0xFFE7F8F3),
    amber: Color(0xFF965C03),
    amberTint: Color(0xFFFCE8C8),
    violet: Color(0xFF4D4FFC),
    violetTint: Color(0xFFE8E8FE),
    page: Color(0xFFEEF5FD),
    card: Color(0xFFFBFDFF),
    ink: Color(0xFF1E2738),
    muted: Color(0xFF616A79),
    faint: Color(0xFF78869C),
    hairline: Color(0xFFE4EBF5),
    danger: Color(0xFFC92A2A),
    // 亮色下这三支与上面那三支**同值** —— 这不是重复定义：上面那三支在暗色下
    // 要变浅（当字用），这三支**永远得够深**（因为压在它们上面的是白字）。
    // 一笔合成的画法叫「一支色兼两种角色」，正是电脑端这次拆掉的那个缺陷。
    primarySolid: Color(0xFF1160E6),
    greenSolid: Color(0xFF117946),
    dangerSolid: Color(0xFFC92A2A),
    onAccent: Color(0xFFFFFFFF),
  );

  /// 暗色那一套（2026-10-07）。
  ///
  /// **来源：电脑端那份暗色表**（`VidLog.Desktop.Core/Theme/ThemePalette.cs`
  /// 的 `Dark` 字典，Tailwind slate 系）。理由是需求方认下的那句话：
  /// **同一个产品的两端，暗色不该是两个暗。**
  ///
  /// ⚠️ **对齐的规则是「能对齐就对齐，对不齐的把数写在这儿」** —— 不是照抄。
  /// 对不齐的只有五支，全都卡在**同一块底**上：本仓的绊线
  /// （`test/palette_test.dart`）量的是**全组合**（7 支字 × 7 块底），
  /// 而电脑端那张表是**逐对**量的、并且没有 `hairline`（slate-700 `#334155`）
  /// 这么一块「既是指示器底、又是分隔线底」的档。把电脑端那五支原样搬过来，
  /// 这条绊线会红十条（实测）：
  ///
  /// | 本仓这一支 | 电脑端那一支 | 压 `hairline` | 改成 | 压 `hairline` |
  /// |---|---|---|---|---|
  /// | `primary` | `Accent` `#60A5FA`（blue-400） | 4.07 | blue-300 `#93C5FD` | 5.74 |
  /// | `green` | `Success` `#10B981`（emerald-500） | 4.08 | emerald-400 `#34D399` | 5.39 |
  /// | `muted` | `TextSecondary` `#94A3B8` | 4.04 | slate-300 `#CBD5E1` | 6.97 |
  /// | `danger` | `Danger` `#EF4444`（red-500） | **2.75** | red-300 `#FCA5A5` | 5.46 |
  /// | `faint` | `TextDisabled` `#64748B` | **2.18**（门槛 3:1） | slate-400 `#94A3B8` | 4.04 |
  ///
  /// 其余**逐字对齐**：`page` / `card` / `hairline` / `blueTint` / `amberTint` /
  /// `ink` 与电脑端那六个键同值。
  /// `amber` 本来也差一档（amber-400 `#FBBF24`），但 amber-500 `#F59E0B`
  /// **实测过得去**（最差 `hairline` 4.82）⇒ 按规则回到电脑端那一支。
  ///
  /// ⚠️ **`primarySolid` 是后来（2026-10-07 当天）才从「逐字对齐」那张名单里出来的**：
  /// 电脑端的 `AccentSolid` `#2563EB` 压 `Surface` 只有 **2.83:1** ——
  /// 而本仓这一个实心块是压在**纸面**上的（`lib/` 里三处：设置页表头那块蓝底、
  /// 设置页卡片上那个齿轮方块、备份页那颗圆），2.83 连图形要的 3:1 都不到。
  /// 暗色那一支按窗往上挪到 `#2768F6`：压 `card` **3.06**、压 `blueTint` **3.08**、
  /// 白字 **4.78**（这一支原来 5.17）。
  ///
  /// ⚠️ **那个窗很窄，别再随手往上提**：白字要 ≥4.5 就要求填色亮度 ≤0.1833，
  /// 而压 `card` 要 ≥3.0 又要求 ≥0.1653 —— 只有这一小段可选（现在取 0.170）。
  /// ⚠️ 电脑端那一支**不能顺手跟着改**：它那张表把「`AccentSolid` 压 `Surface`
  /// < 3.0」当成「必须把它和 `Accent` 拆成两支」的**论据**钉在
  /// `ThemePaletteTests.Accent那两支必须分开…` 里，改值先得改那条论据。
  ///
  /// ⚠️ 暗色下**字色压底色那张全组合表里最紧的一对是 `violet` 压 `hairline`
  /// 5.19:1**。再往下调任何一支之前先跑那条绊线。
  ///
  /// ⚠️ `greenSolid` / `dangerSolid` **与亮色同值**，是有意的：压在它们上面的是
  /// 白字，白压这两个绿/红本来就是 5.46:1 —— 提亮只会两头都变差
  /// （电脑端 `Success` / `Danger` 两套同值，同一条理由，`ThemePalette.cs` 里写着）。
  /// 它们**不在上面那个「纸面分得开」的要求里**：这两支的底是**取景画面**
  /// （【开始】/【结束】那颗按钮压在预览上），走媒体层那套规矩，不是纸面。
  ///
  /// ⚠️ 暗色独有的一个**看得见**的后果（量出来的，不是猜的）：
  /// `blueTint` `#172554` 与 `card` `#1E293B` **只差 1.00:1**（亮色是 1.12:1）
  /// ⇒ 设置页那两块说明底在暗色下**不再读得出是一块块**。
  /// 电脑端那张表里 `AccentWeak` / `Surface` 也是这两个色、也差 1.00:1
  /// （本仓 `blueTint` 那两个值就是从那儿来的）—— 所以这是「跟着电脑端走」的结果，
  /// 不是本仓走偏。真机上觉得糊再说。
  ///
  /// ⚠️ **唯一被单独拎出来救的一处是「选中」那一类**（[selectedTint]，
  /// 2026-10-07 需求方在「动 / 不动」之间选的 C）：那里零对比度等于
  /// 「看不出选的是哪一栏」，是**功能**没了，不是好不好看的问题。
  static const dark = Palette(
    brightness: Brightness.dark,

    // ── 与电脑端那张表逐字同值的 ──
    page: Color(0xFF0F172A), // slate-900（= PageBackground）
    card: Color(0xFF1E293B), // slate-800（= Surface）
    hairline: Color(0xFF334155), // slate-700（= CardBorder）
    blueTint: Color(0xFF172554), // blue-950（= AccentWeak）
    amberTint: Color(0xFF422006), // amber-950（= WarningSurface）
    ink: Color(0xFFF1F5F9), // slate-100（= TextPrimary）
    amber: Color(0xFFF59E0B), // amber-500（= Warning）

    // ── 按上表「对不齐」那一栏改过的 ──
    primary: Color(0xFF93C5FD), // blue-300（电脑端 blue-400 压 hairline 只有 4.07）
    green: Color(0xFF34D399), // emerald-400（10B981 只有 4.08）
    muted: Color(0xFFCBD5E1), // slate-300（94A3B8 只有 4.04）
    danger: Color(0xFFFCA5A5), // red-300（EF4444 压 hairline 2.75、压 card 3.89）
    faint: Color(0xFF94A3B8), // slate-400（64748B 只有 2.18，连 3:1 都不到）
    // ⚠️ 这一支是**实心块**不是字色，跟着这一组放是因为同一类原因：电脑端那个值
    // （`AccentSolid` blue-600）压纸面只有 2.83。它**不是 Tailwind 档位**，
    // 是解出来的（窗很窄，别随手改）—— 怎么解的、为什么不能动电脑端那一支，
    // 见字段说明。
    primarySolid: Color(0xFF2768F6),

    // ── 电脑端没有对应角色的 ──
    // 底栏 / 分段选择器**选中态**的底。电脑端没有一个键对应这个角色 ——
    // 它的「选中」是一行列表项，底读 `AccentWeak`（= 本仓 `blueTint`），
    // 底下的容器是 `SurfaceAlt`（1.42:1）而不是 `Surface`。本仓这两处没有
    // 「列表行」那个结构，只能单开一支。值、以及它只载哪几支前景，见字段说明。
    selectedTint: Color(0xFF1E3A8A), // blue-900
    // `violet` 只当图标（见亮色那支的说明），电脑端没有紫那一档；按另外三支
    // 同样的步进定 indigo-300，压 hairline 5.19 —— 全组合里最紧的一对。
    violet: Color(0xFFA5B4FC),
    // 暗底的浅底取的是 Tailwind 的「xx-950」那一族（亮色取的是 xx-50/100），
    // 与另外三支同一个做法。`greenTint` 电脑端没有（那张表里没有绿色面）。
    greenTint: Color(0xFF022C22), // emerald-950
    violetTint: Color(0xFF1E1B4B), // indigo-950
    // 与亮色同值，见类注释。
    greenSolid: Color(0xFF117946),
    dangerSolid: Color(0xFFC92A2A),
    // 暗色下 `primary` / `danger` 是**浅**的，压在上面的字得是**深**的 ——
    // 取的就是暗色的页面底（电脑端没有这个角色：它的强调色底永远够深、字永远白）。
    onAccent: Color(0xFF0F172A),
  );

  /// 这一套是亮还是暗。
  ///
  /// ⚠️ 它不是「顺手多存一个字段」：`ColorScheme.brightness` 决定 M3 那一大堆
  /// **自己决定怎么画**的控件（滚动条、输入框光标、`Switch` 的轨道、日期选择器…）
  /// 走哪一套默认。这里漏填的话，暗色主题会配着一个 `Brightness.light` 跑 ——
  /// 界面大部分是对的，坏的那几处全在 M3 内部，查起来毫无头绪。
  final Brightness brightness;

  /// 主蓝：主按钮、选中的那一栏、行上那道竖条、链接、发货。
  ///
  /// 草图上是 `#246EF0 → #1564E8` 的竖向渐变、纯色块是 `#1C69F8`。
  /// 取**一个实色**：渐变要多一层 widget，而这一版只修颜色（§47）。
  ///
  /// 2026-10-04（T2）：`#1D6AEE → #1160E6`，对 `blueTint` 由 4.23 提到 4.79。
  /// 只动了明度，色相与饱和度没碰，肉眼几乎看不出。
  ///
  /// ⚠️ **实心蓝块不许读它。** 它同时是 `ColorScheme.primary`，而 M3 的暗色主题里
  /// `primary` 本身是一支**浅色**（暗底上要用它写字）—— 拿它当底、上面压白字，
  /// 暗色下就白压白。实心块读 [primarySolid]。
  final Color primary;

  /// 主蓝的浅底：胶囊 / 小标 / 图标底 / 说明底。
  ///
  /// ⚠️ **「选中」那一类的底不读它**（底栏选中的那一栏、分段选择器选中的那一段），
  /// 读 [selectedTint] —— 理由在那边。
  final Color blueTint;

  /// **选中态**的底：底栏（`NavigationBar`）选中那一栏的胶囊、
  /// 分段选择器（`SegmentedButton`）选中的那一段。
  ///
  /// ⚠️ 这两处**都只载一支前景**：`onSecondaryContainer` = [primary]。
  /// - 底栏：那颗选中图标（`navigation_bar.dart:1456`）。选中那栏的**字**在
  ///   **底栏底**上、不在胶囊上（M3 的指示器只包住图标，`buildLabel` 是另一棵）。
  /// - 分段选择器：那一段的字与勾（M3 默认 `onSecondaryContainer`）。
  ///
  /// **为什么单开一支**（2026-10-07，需求方在那道「动 / 不动」选择题里选了 C）：
  /// 不写这一支的话这两处的底都落到 `ColorScheme.secondaryContainer`
  /// （= [blueTint]，`navigation_bar.dart:1463`）—— 而 [blueTint] 与 [card] 在
  /// 暗色下**只差 1.00:1**，选中的那一个**看不出来**（亮色是 1.12:1，也弱，但没到零）。
  ///
  /// ⚠️ **没有改成去动 [blueTint]**（那是另一条路）：[blueTint] 同时是 Chip 的底、
  /// 设置页那两块说明底、`surfaceContainerHighest`、`primaryContainer`，改一处
  /// 会连带一圈；而且它这一支是照着电脑端那张表逐字对齐来的（`AccentWeak`）。
  /// 所以这里**只**给「选中」一支新色，代价是「底栏胶囊 / 分段选择器与 Chip
  /// 不再是同一个蓝」。
  ///
  /// - 亮色 `#E7F1FD`：**与 [blueTint] 同值** ⇒ 亮色这一半一个像素都没动
  ///   （这两处亮色下读的本来就是 [blueTint]）。
  /// - 暗色 `#1E3A8A`（blue-900）：压底栏底 / 卡片（`surfaceContainer` = [card]）
  ///   **1.41:1**；压在那支选中前景（[primary] blue-300）上 **5.74:1**。
  ///
  /// ⚠️ 与电脑端的关系（2026-10-07 实测，收掉先前一句错的）：电脑端「选中的那一行」
  /// （`SettingsWindow` 的 `DiskTable`）用的也是 `AccentWeak`，但它压在
  /// **`SurfaceAlt` #334155** 上 —— 那一对是 **1.42:1**（亮色 1.11:1），
  /// 与本仓这一支的 1.41 **同一个量级** ⇒ 这一处**不是**「两端分道」。
  /// （先前记的「那边 1.00:1」是拿 `AccentWeak` 比 `Surface` 量出来的，
  /// 而那张表底下不是 `Surface` —— 量错了底。别再把那一句抄回来。）
  ///
  /// ⚠️ 换值前先看 `palette_test.dart` 里「压选中胶囊」那一对（它量着 5.74 那个数）。
  final Color selectedTint;

  /// 已备份 / 在线 / 已配对。
  ///
  /// ⚠️ 它当**文字**用（胶囊里的字、`N 个都已经备份`那句），所以走 4.5:1 那档。
  /// 2026-10-04（T2）：`#1BBE6E → #117946`，对 `greenTint` 由 2.21 提到 4.97。
  ///
  /// **它现在是深墨绿，不是草图上的鲜绿。** 鲜绿对任何浅底都只有 2.2:1 ——
  /// 要让绿字达标，明度就得压到这个位置，没有第三条路（改胶囊的底也一样：
  /// 底要更浅、字要更深，字这头终归躲不掉）。这是需求方 2026-10-04 拍板接受的
  /// 代价，别再「顺手调回草图那个绿」。
  ///
  /// ⚠️ 同上：**【开始】那个绿实心按钮不读它**，读 [greenSolid]。
  final Color green;

  final Color greenTint;

  /// 退货，以及「待重试」这类要提醒但不致命的状态。
  ///
  /// 2026-10-04（T2）：`#FBA012 → #965C03`，对 `amberTint` 由 1.73 提到 4.57。
  ///
  /// ⚠️ **视觉变化最大的一支**：鲜橙压到 4.5:1 会变成**深棕**（不是暗橙 ——
  /// 橙色在低明度上就是棕）。草图上的琥珀色块观感会明显变沉。
  /// 若真机上觉得不能接受，唯一的出路是**改胶囊的底**（把 `amberTint` 再调浅，
  /// 或用深底 + 反白字），而不是把 [amber] 调回去 —— 调回去就等于这条绊线
  /// 永远红着，等于没有绊线。
  final Color amber;

  final Color amberTint;

  /// 总占用那一格的图标色。
  ///
  /// ⚠️ **它只当图标用，从没当过文字**（`_statCard` 里只染那颗 19px 的图标，
  /// 数值是墨色、单位是 [muted]）。所以它其实只需要 3:1；
  /// 这里仍按 4.5:1 收，是为了让绊线保持「所有前景色一个门槛」这条简单规则。
  /// 2026-10-04（T2）：`#5A5CFC → #4D4FFC`，差值肉眼不可见。
  final Color violet;

  /// ⚠️ **推导值，不是采样值** —— 草图上那一格只有图标是紫的，没有紫的浅底。
  /// 按另外三档同样的深浅比例推出来；真机上觉得不对再调（§47）。
  final Color violetTint;

  /// 页面底色。
  final Color page;

  /// 卡片底色。比页面白，卡片才浮得起来。
  final Color card;

  /// 正文墨色。
  final Color ink;

  /// 次要文字。改版前散在文件里的是 `Colors.black54`。
  ///
  /// 2026-10-04（T2）：`#8B94A2 → #616A79`，对 `card` 由 3.00 提到 5.36。
  /// 它是 `ColorScheme.onSurfaceVariant`，M3 里那些「说明性小字」全读它。
  final Color muted;

  /// **描边 / 装饰色，不是文字色。** 改版前散着 `black45` / `black38` / `black26` 三种。
  ///
  /// ⚠️ **别拿它写字。** 2026-10-04（T2）查过：它原先被 5 处当小字用
  /// （10~12px 的说明句），那 5 处已经改成 [muted]。原因不是它不够深 ——
  /// 是**它深不了**：它同时是 `ColorScheme.outline`，也就是**全应用输入框的常态边框**，
  /// 压到 4.5:1 会让每一道边框都变成深灰线，而且和 [muted] 撞成同一个色
  /// （两者都要对最亮的底达标 ⇒ 明度被钉在同一处，色相再分也分不出层次）。
  /// 所以它守的是**非文字**那档 3:1（1.4.11：图形与控件边界），这也正是边框该守的。
  ///
  /// 现状用途（全是描边/图标）：`outline` 输入框边框、行上「判不出来」那道 3px 竖条、
  /// 状态圆点、`edit` / `delete` / `chevron` / 缩略图占位四个图标。
  /// 2026-10-04（T2）：`#A9B2C0 → #78869C`，最差底（`violetTint`）由 1.78 提到 3.06。
  final Color faint;

  /// 分隔线、浅灰底、缩略图占位。改版前是 `Colors.black12` 那种透明黑。
  ///
  /// 用**实色**：透明黑压在不同的底上会是不同的灰，而草图里这几块是同一个浅灰蓝。
  ///
  /// ⚠️ **它自己不算「底」也不算「字」**：绊线把它列在**底**那一侧（它有 11 处
  /// 被当底用：`_hostPill` / `_pairedPill` / 清理流水那个小标……），
  /// 但它不进**前景**名单 —— 真要求它 4.5:1，每一道分隔线都会变成深灰粗线，
  /// 那不是无障碍，那是把界面拆了。
  final Color hairline;

  /// 语义红：删除 / 备份失败。
  ///
  /// ⚠️ **草图里没有红这一档**（图上画的是「一切正常」的样子）。
  /// 失效与删除是规格 §3.4.3 ★ / §3.5.6 要求必须看得见的，所以照 Material
  /// 的语义红定一个，全应用**只此一处** —— 改版前是 `Colors.red` 与
  /// `Colors.red.shade700` 两个值散在三处。
  ///
  /// 2026-10-04（T2）：`#D32F2F → #C92A2A`，对 `card` 由 4.88 提到 5.35。
  ///
  /// ⚠️ 同上：**【结束】那个红实心按钮不读它**，读 [dangerSolid]。
  final Color danger;

  /// 压**实心主色块**的底色（设置页那两个齿轮方块、备份页「电脑备份」那颗圆）。
  ///
  /// ⚠️ 与 [primary] **分开的理由**：上面那支的两半身 —— 它既是「暗底上的蓝字」，
  /// 又是「蓝底上的白字」。暗色下这两个角色要的值**一个往浅走、一个不能动**，
  /// 合在一支里就是电脑端这次拆掉的那个缺陷（`PrimaryDisabledInk` 那批）。
  ///
  /// ⚠️ **它是三支实心块里唯一压在纸面上的那支**（[greenSolid] / [dangerSolid]
  /// 压在取景画面上）。所以它多一条别人没有的要求：**它得跟纸面分得开** ——
  /// 那些方块读起来是「一块蓝底 + 一个白齿轮」，底和纸面撞色就只剩个齿轮浮着。
  ///
  /// 2026-10-07（T1 尾巴）：暗色这一支原来是电脑端的 `AccentSolid` `#2563EB`，
  /// 压在 `card` 上只有 **2.83**、压 `blueTint` 2.84、压 `amberTint` 2.82 ——
  /// 连图形要的 3:1 都不到（亮色那一支 `#1160E6` 压 `card` 是 5.36，一直是够的，
  /// 所以这是暗色独有的）。暗色改成 `#2768F6`：压 `card` **3.06**、
  /// 压 `blueTint` **3.08**、压 `amberTint` **3.05**；
  /// 白字由 5.17 落到 **4.78**（仍 ≥4.5）。
  ///
  /// ⚠️ **那个可选窗很窄，加宽它的两条边都不是这里能动的**：白字要 ≥4.5 就要求
  /// 填色的相对亮度 ≤ **0.1833**，压 `card` 要 ≥3.0 又要求 ≥ **0.1653** ——
  /// `#2768F6` 取的是 0.170。想再往上提就得先动 `card` 或者改白字。
  /// ⚠️ **电脑端那一支不能顺手跟着改**：那张表把「`AccentSolid` 压 `Surface`
  /// < 3.0」当成「必须把它和 `Accent` 拆成两支」的**论据**钉在
  /// `ThemePaletteTests.Accent那两支必须分开…` 里，改值先得改那条论据。
  final Color primarySolid;

  /// 【开始工作】那个绿按钮的底。**字是白的**，所以它永远得够深。
  final Color greenSolid;

  /// 【结束】那个红按钮的底、删除类按钮的底。同上，永远够深。
  final Color dangerSolid;

  /// 压在**跟主题走的实心块**上的墨色（`ColorScheme.onPrimary` /
  /// `onSecondary` / `onError`）。
  ///
  /// ⚠️ 亮色是白、暗色是**页面底色**。因为 M3 的暗色主题里 `primary` 自己就是
  /// 一支浅蓝（要在暗底上当字用），白字压上去等于看不见。
  ///
  /// ⚠️ **它只管 `ColorScheme` 那三个角色。** 本仓自己画的实心块
  /// （[primarySolid] / [greenSolid] / [dangerSolid]）在两套主题下都够深，
  /// 压在它们上面的一律是 [onDark]（白），不走这里。
  final Color onAccent;

  /// ⚠️ **没有任何东西调它**（`grep -rn '\.copyWith()'` 在整个 flutter SDK 的
  /// `src/` 下一处都没有），它在这儿只是因为 `ThemeExtension` 要求实现。
  /// 要加字段就照这个模式补可选参数 —— 在那之前，写
  /// `palette.copyWith(...)` 会**编译不过**，这是故意的：宁可编译报错，
  /// 也不要一个悄悄把新字段吞掉的 `copyWith`。
  @override
  Palette copyWith() => this;

  /// ⚠️ **硬切，不是渐变。**
  ///
  /// 框架只在主题**过渡动画**里调它（`ThemeData.lerp` → `AnimatedTheme`），
  /// 而 `main.dart` 把 `themeAnimationDuration` 设成了 `Duration.zero`
  /// ⇒ 实际上一次都调不到。真调到了也照切不误（`t` 过半就换成新的那套）：
  /// 逐个 `Color.lerp` 要写 20 行，换来的是 200ms 里界面在两种配色之间飘 ——
  /// 那既不是亮色也不是暗色，中途的状态没有任何人验过。**亮暗之间没有中间态。**
  ///
  /// ⚠️ 想改成交叉淡出的话，改这里的同时**必须**把 `themeAnimationDuration`
  /// 加回去，否则那 20 行永远不会被执行。
  @override
  Palette lerp(covariant Palette? other, double t) =>
      other == null || t < 0.5 ? this : other;

  // ─────────────────────────────────────────────
  // 媒体层：压在**画面**上、而不是压在纸张上的那一套（改造清单 T3）
  // ─────────────────────────────────────────────
  //
  // ⚠️ **这一族守不住 4.5:1，而且这不是疏忽。** 上面那些色的底是
  // [page] / [card] 这类**我们定的**浅底，量得出比值；媒体层的底是
  // **实时取景画面 / 播放中的视频 / 一张缩略图** —— 仓库顶灯、白墙、白面单，
  // 整片白的时候纯白字就是看不见。这不能靠调颜色解决，靠的是
  // **遮罩（[veil]、渐变 scrim）与描边**（`_strokedText` 那两层字）。
  //
  // 所以这一族只守一个**下限**：对**纯黑**够看。真机上遇到白底画面看不清，
  // 出路是加厚遮罩，不是把这几个色调深 —— 调深了在黑画面上反而是自杀。
  //
  // 改版前这一族散着 `Colors.white` / `white70` / `white60` / `white54` /
  // `black` / `black87` / `black.withValues(...)` 七种写法，同一个角色
  // （「压在画面上的次要字」）在不同文件里是不同的白。
  //
  // ⚠️ **这一族是 `static const`，因为它不跟主题走**（2026-10-07 拆亮暗时定的）：
  // 它的底是画面，而画面在亮色和暗色下是**同一张画面**。把它挪进实例字段
  // 只会凭空多出 8 个「暗色下该调成什么样」的问题，而答案全是「不调」。

  /// 压在**实心深底**上的白：取景画面上的字与图标、播放器黑底、缩略图上的播放键，
  /// 以及本仓自己画的实心色块里的字形（[primarySolid] / [greenSolid] / [dangerSolid]）。
  ///
  /// ⚠️ **它不管 `ColorScheme` 那三个实心角色**（`onPrimary` / `onSecondary` /
  /// `onError`）—— 那三个的底跟主题走，读的是实例字段 [onAccent]。
  ///
  /// ⚠️ 白字在**这三支里最紧**的那一对：亮色是 [dangerSolid]（**5.46:1**）、
  /// 暗色是 [primarySolid]（**4.78:1**）—— 两套下都离 4.5 还有余量，
  /// 所以「白字处处安全」这句话成立；但**别再说「最浅的永远是 primarySolid」**，
  /// 亮色下这三支本来就在 5.46–5.47 之间差得看不见（2026-10-07 量的，
  /// 这一句原先写的是手算的 `5.48` 和「primarySolid 永远最浅」，两条都不准）。
  /// 暗色那支由 5.17 落到 4.78 是拿「跟纸面分得开」换的，见 [primarySolid]。
  static const onDark = Color(0xFFFFFFFF);

  /// 压在深底上的**次要**字与图标（改版前是 `Colors.white70`）。
  static const onDarkSoft = Color(0xB3FFFFFF);

  /// 压在深底上的**最次要**字（改版前 `Colors.white54` 与 `Colors.white60` 两种写法学名）。
  ///
  /// ⚠️ 这两个值（54% / 60%）合并成了一个：差值肉眼不可见，
  /// 而留着两种写法就会有人继续挑一个随手用。
  static const onDarkFaint = Color(0x8AFFFFFF);

  /// **深底本身**：取景页铺满整页的那层、播放器的背景与信箱边。
  ///
  /// 半透明的黑（`black.withValues(alpha: 0.45)` 之类）也从它派生 ——
  /// 那些 alpha 是**状态**（按下去 / 摊开 / 渐变端点），不是调色板的色阶。
  static const backdrop = Color(0xFF000000);

  /// 盖在画面上的一层**深色面板**（改版前是 `Colors.black87`）：
  /// 扫码页底部那条提示、相机起不来时的整块底。
  ///
  /// 比 [backdrop] 浅一档是**故意的**：它下面还有画面在动，
  /// 全黑会让「相机其实开着」这件事看不出来。
  static const veil = Color(0xDD000000);

  // ── 媒体层里**带色相**的三支 ──
  //
  // 它们压在黑底上，所以照上述只守「对纯黑够看」这一条。**别换成上面那些
  // 为浅底压暗过的色** —— [amber]（深棕）压黑底只有 2.9:1，[danger] 也只有 3.3:1。

  /// 取景浮层上的警示（改版前散着 `Colors.orangeAccent` 与 `Colors.orange`）。
  static const mediaWarn = Color(0xFFFFAB40);

  /// 录制中的红：那颗圆点，以及画面正中那个**不许截断**的单号。
  static const mediaRecord = Color(0xFFFF5252);

  /// 播放器里选中的那一档（改版前是 `Colors.lightBlueAccent`）。
  static const mediaPick = Color(0xFF40C4FF);
}

/// 界面里取色的**唯一入口**：`context.palette.ink`。
///
/// ⚠️ 走 `Theme.of(context)` 而不是直接读 `Palette.light`，因为前者**跟着主题走**：
/// 系统切到暗色时 `Theme.of` 拿到的是另一棵主题，这里的 `palette` 自动变成
/// 暗色那一套。写死 `Palette.light.x` 的话，那个控件两套主题下是同一个色。
///
/// ⚠️ 末尾这个 `!` 是**故意**的：拿不到就是说这个 widget 被挂在一棵**没有挂
/// `extensions: [Palette.…]`** 的主题下面（`main.dart` 是唯一该挂的地方）。
/// 那是一个接线错误，早崩早发现 —— 返回亮色兜底会让它在真机上静默地一直是亮色。
extension PaletteOf on BuildContext {
  /// 当前主题那一套颜色。
  Palette get palette => Theme.of(this).extension<Palette>()!;
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
///
/// ⚠️ **色盘要传进来**（`businessTypeLook(context.palette, type)`）而不是在这里读
/// 全局：这个函数是纯的，没有 `BuildContext`；而且亮暗两套都得能调它
/// —— 钉死 `Palette.light` 的那一版在暗色下会给出一套亮色。
({Color color, Color tint}) businessTypeLook(Palette palette, BusinessType? type) =>
    switch (type) {
      BusinessType.outbound => (color: palette.primary, tint: palette.blueTint),
      BusinessType.returning => (color: palette.amber, tint: palette.amberTint),
      // 判不出来：灰。**不是第三种业务类型**，是「不知道」。
      //
      // ⚠️ 这里给的是 [Palette.faint] 那一档 —— 一支**描边色**（3:1 那档）。今天安全，
      // 因为这一支只被列表上那道 3px 竖条读走；`record_detail_page` 那颗胶囊
      // 外面套着 `if (type != null)`，判不出来时根本不画。
      // **要是哪天要在「判不出来」时也画胶囊，得先把这里换成 [Palette.muted] 那一档**，
      // 否则就是拿 3:1 的色去写字。
      null => (color: palette.faint, tint: palette.hairline),
    };

/// 清理流水上那个动作小标 → **一支色 + 它的浅底**（T24）。
///
/// ⚠️ 与 [businessTypeLook] 同一个位置、同一个理由：颜色散在页面里就会
/// 「同一件事两个色」，而这一支还多一层 —— 动作码是**从盘上读回来的**
/// （`cleanup-audit.jsonl` 两端共用），用户认不出 `deleted` 是什么意思，
/// 全靠这个色和旁边那个词。判错了不会有任何测试喊。
///
/// ⚠️ **每一对、在两套主题下的对比度都是量出来的**（WCAG，压在**它自己那个底**上）：
/// - 亮色：`deleted` 绿 4.97:1、`refused` 蓝 4.79:1、`deleting` 琥珀 4.57:1、
///   `failed` 红 4.55:1、认不出的灰 4.55:1 —— 五对都过了 4.5:1。
/// - 暗色（2026-10-07 补量）：绿 7.88、蓝 8.15、琥珀 6.79、红 5.46、灰 6.97。
///
/// 改这儿任何一支色**要重新量**，别照着别的屏抄一个值。
///
/// ⚠️ 暗色那几个数**也**被 `palette_test.dart` 那条全组合绊线盖着
/// （它把 7 支字逐个压到这 5 块底上），所以下面这几对不会单独漂。
///
/// ⚠️ `failed` 与认不出的那两对走的是 [Palette.hairline] 那个**灰底**
/// （调色板里没有红的浅底，也不值得为这一个地方新开一支）——
/// 「红字压灰底」读起来仍是「出事了」，不影响判读。
/// ⚠️ 认不出的那支用的是 [Palette.muted] 那一档而**不是** [Palette.faint]：
/// 后者是**描边色**（3.08:1），拿它写字就掉到 4.5:1 以下了
/// （同一条规矩见 [businessTypeLook] 里那段）。
({Color color, Color tint}) cleanupActionLook(Palette palette, String action) =>
    switch (action) {
      'deleted' => (color: palette.green, tint: palette.greenTint),
      'refused' => (color: palette.primary, tint: palette.blueTint),
      'deleting' => (color: palette.amber, tint: palette.amberTint),
      'failed' => (color: palette.danger, tint: palette.hairline),
      // 认不出来的动作码：灰，**不是第六种结局**，是「不知道」。
      // （词那边照旧原样印出来，见 `CleanupLogView.describeAction`。）
      _ => (color: palette.muted, tint: palette.hairline),
    };
