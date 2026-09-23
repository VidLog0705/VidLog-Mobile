import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/recorder_page.dart';
import 'package:vidlog_mobile/main.dart';
import 'package:vidlog_mobile/recording/recorder_config.dart';
import 'package:vidlog_mobile/recording/recorder_events.dart';
import 'package:vidlog_mobile/recording/retention_setting.dart';
import 'package:vidlog_mobile/recording/work_mode.dart';

void main() {
  testWidgets('外壳能启动', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 默认落在**备份**栏。**不去断言数据目录初始化完成** ——
    // 那要走平台通道，widget 测试里没有实现；页面自己会把它降级成一条错误状态。
    expect(find.text('备份'), findsWidgets);
  });

  testWidgets('底部是需求方定的四栏', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 四栏是需求方 2026-09-21 直接定的，不是从规格书推的 ——
    // 这里锁的是那个决定，别被后来人「顺手优化」掉。
    for (final label in ['备份', '发货', '退货', '设置']) {
      expect(find.text(label), findsWidgets, reason: '缺了「$label」这一栏');
    }
  });

  testWidgets('★ 备份页只显示盘上真有的东西，不编数字', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 默认就落在备份栏。四个模块都得在（需求方 2026-09-22 定的布局）。
    expect(find.text('未命名机位'), findsOneWidget); // ① 本机身份
    expect(find.text('电脑备份'), findsOneWidget); // ③ 电脑备份
    expect(find.text('录像记录（共 0 条）'), findsOneWidget); // ④ 录像记录

    // ② 三个统计。「今日」「全部」同时也是筛选项上的字，所以各出现两次；
    // 数字本身才是这一块的实质内容。
    expect(find.text('今日'), findsNWidgets(2));
    expect(find.text('全部'), findsNWidgets(2));
    expect(find.text('总占用'), findsOneWidget);
    expect(find.text('0 条'), findsNWidgets(2), reason: '空机上今日和全部都是 0 条');
    expect(find.text('0 B'), findsOneWidget, reason: '空机上总占用是 0 B');

    // 上传功能还不存在，这一页必须**明说**，而不是显示一个看起来正常的
    // 「主机已连接 / 0 条待上传」。
    expect(find.textContaining('手机端还没有上传功能'), findsOneWidget);

    // 没配对就不该有任何连通状态 —— 显示「离线」会让人以为「配过对、只是没连上」。
    expect(find.text('配对电脑'), findsOneWidget);
    expect(find.text('离线'), findsNothing);
    expect(find.text('连接'), findsNothing);
    expect(find.text('探测中…'), findsNothing);

    // 真正的回归守卫是这条：以后谁往这一页塞一个假装连上了的状态，这里会红。
    // 假数字在真机上会被当成真的 —— 这个项目已经吃过一次亏。
    expect(find.textContaining('已连接'), findsNothing);
  });

  testWidgets('★ 录像记录的分页控件在这儿，档位是需求方定的 5/10/15', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 默认筛「全部」（需求方 2026-09-22）。
    final segmented = tester.widget<SegmentedButton<bool>>(
      find.byType(SegmentedButton<bool>),
    );
    expect(segmented.selected, {false}, reason: '默认应该是「全部」');

    // 每页 5/10/15 是需求方指定的三档，别被后来人改成别的数。
    final dropdown = tester.widget<DropdownButton<int>>(
      find.byType(DropdownButton<int>),
    );
    expect(dropdown.items!.map((i) => i.value), [5, 10, 15]);
    expect(dropdown.value, 5, reason: '默认每页 5 条');

    // 空列表也要显示页码，**不能是 0/0**：分母是 0 会让人以为列表坏了。
    expect(find.text('1/1'), findsOneWidget);

    // ⚠️ 「换了筛选/每页条数要把页码打回第一页」这条在 widget 测试里验不了 ——
    // 没有真文件就造不出多条会话，页码永远是 1/1。真机上补：
    // `docs/真机验收清单.md` §1.12。
  });

  // ─────────────────────────────────────────────
  // 进栏播报（需求方 2026-09-22）
  // ─────────────────────────────────────────────

  group('modeAnnouncementFor', () {
    test('进发货 / 退货各播各的', () {
      expect(modeAnnouncementFor(1, 0), VoicePrompt.shippingModeOn);
      expect(modeAnnouncementFor(2, 1), VoicePrompt.returnModeOn,
          reason: '发货↔退货互切要重播 —— 靠它确认这一件是发还是退');
      expect(modeAnnouncementFor(2, 0), VoicePrompt.returnModeOn);
    });

    test('★ 重复点当前那一栏不重播', () {
      // ⚠️ `onDestinationSelected` 点了当前那一栏**也会回调**：
      // 没有这道闸，手抖连点两下发货就连播两遍。
      // 变红配方：去掉 `if (tab == previousTab) return null;`。
      expect(modeAnnouncementFor(1, 1), isNull);
      expect(modeAnnouncementFor(2, 2), isNull);
    });

    test('备份 / 设置两栏不播报', () {
      expect(modeAnnouncementFor(0, 1), isNull);
      expect(modeAnnouncementFor(3, 1), isNull);
      expect(modeAnnouncementFor(0, 0), isNull);
    });
  });

  testWidgets('★ 发货与退货共用同一个录制页（不是两份）', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 【开始】只该有一个。做成两份页面的话，两栏各一个 ——
    // 而背后是**两个 `UiKitView`、两次开相机**，真机上相机同时只开得了一个。
    // 这条锁的就是「栈里只有三个孩子」那个决定。
    Finder workButton() => find.text('开始');

    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();
    expect(workButton(), findsOneWidget);

    await tester.tap(find.byIcon(Icons.assignment_return_outlined));
    await tester.pumpAndSettle();
    expect(workButton(), findsOneWidget, reason: '退货这一栏不该再开一个录制页');
  });

  testWidgets('★ 采集页底部只有一个操作按钮，且没有「停止当前录制」',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();

    // 需求方 2026-09-22 裁决 #6：**只留开始/结束一个**。
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('结束'), findsNothing, reason: '没在工作时不该同时出现【结束】');
    expect(find.text('结束工作'), findsNothing);

    // ⚠️ 这条锁的是一个**规格禁令**，不只是个 UI 偏好：
    // 规格 §3.3.2:183 明文禁止为「同码停 / 扫码静止停录」提供
    // 「手动结束当前单」按钮 —— 而它一直挂在页面上，直到 2026-09-22 才删掉。
    // 后来人「顺手加回一个方便按钮」的话，这里会红。
    expect(find.text('停止当前录制（相机继续开着）'), findsNothing,
        reason: '规格 §3.3.2:183 禁止这个按钮');
  });

  testWidgets('★ 采集页画面正上方有实时时间，且带描边（规格 §3.2.6）',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();

    final clock = find.byKey(const Key('recorder-clock'));
    expect(clock, findsOneWidget);

    // ① 格式必须是「年/月/日/时/分/秒」六段全带。
    // 需求方原话：「按年/月/日/时/分/秒显示」。少一段（比如省掉年）
    // 就得靠猜是今年还是去年，而这个钟是为「事后对着录像核时间」用的。
    final texts = tester
        .widgetList<Text>(find.descendant(of: clock, matching: find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .toList();

    expect(texts, isNotEmpty);
    for (final text in texts) {
      expect(
        text,
        matches(RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$')),
        reason: '钟的格式不对：$text',
      );
    }

    // ② 两层都画：底下那层只描边、上面那层只填充。
    // **白字压实景**是这个需求唯一的技术理由（取景框底色不可控，
    // 整片白的时候纯白字看不见）。只画一层的话这里会红。
    expect(texts, hasLength(2), reason: '白字要画两层（描边层 + 填充层）');

    // ③ 显示的是**当下**，不是一个画死的字符串。
    // 少了这条，一个把 '2026/01/01 00:00:00' 写死的钟也能过上面两条 ——
    // 而那种钟在真机上看起来完全正常，只有核时间的时候才发现是错的。
    final match = RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})$')
        .firstMatch(texts.first)!;
    final shown = DateTime(
      int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!),
      int.parse(match[4]!), int.parse(match[5]!), int.parse(match[6]!),
    );
    expect(shown.difference(DateTime.now()).inSeconds.abs(),
        lessThanOrEqualTo(2),
        reason: '钟显示的不是「现在」：$shown');

    // ⚠️ **「一秒一秒在走」这一条测不了**，只能真机验。
    // widget 测试里 `Timer` 走的是假时钟，而 `DateTime.now()` **不是** ——
    // `tester.pump(Duration(seconds: 2))` 会让计时器空转两秒而墙钟纹丝不动，
    // 于是断言「秒数变了」必然假红（不是代码坏了，是测不了）。
    // 所以这一条记在 `真机验收清单.md` 里，不在这里假装验过。
  });

  testWidgets('★ 采集页全屏：没有 AppBar，抽屉默认收着', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();

    // 需求方 2026-09-22：**页面全屏显示手机摄像头画面**。
    // 有 AppBar 就铺不满 —— 这条锁的是「发货/退货 不给 AppBar」那个决定，
    // 后来人顺手加回去一个标题栏，这里会红。
    expect(find.byType(AppBar), findsNothing, reason: '采集页不能有 AppBar，画面要铺到状态栏底下');

    // 三个抽屉入口常驻可见：兜底手段必须**一眼看得到**，不能藏在别处。
    final manualTab = find.byKey(const Key('work-sheet-manual'));
    expect(manualTab, findsOneWidget);
    expect(find.byKey(const Key('work-sheet-events')), findsOneWidget);
    expect(find.byKey(const Key('work-sheet-diagnostics')), findsOneWidget);

    // 但面板本身默认**收着** —— 取景画面是这一页的全部意义，
    // 没点开的东西不该占着它。单号输入框是「手动输入」面板独有的。
    expect(find.byType(TextField), findsNothing, reason: '抽屉默认收着，不该有输入框占着画面');

    // 点开「手动输入」→ 输入框出来（规格 §3.2.2 的兜底不能丢）。
    await tester.tap(manualTab);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('手动输入 ▾'), findsOneWidget, reason: '展开的那一块要显示 ▾');

    // 再点一次 → 收回去。抽屉是**开关**，不是一次性展开。
    await tester.tap(manualTab);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    // ⚠️ 会溢出的**不是小屏，是键盘**。
    //
    // 360×640 是台正常手机，抽屉全开也就 ~374px，塞得下 560px 的页面。
    // 但手输面板里有个 `TextField`，一点它键盘就弹起来 —— `Scaffold`
    // 默认贴着键盘缩，可用高度当场少掉三百多。**这才是真机上的事。**
    //
    // 溢出时**被顶出屏幕的是面板顶部**，不是底部 ——
    // 底部浮层是 `Positioned(bottom: 0)` 钉住的，列比可用高度高时
    // 多出来的那截从**上面**冒出去（实测手输面板标题在 y = -38）。
    // 标题和兜底说明当场看不见，而它们正是这个面板存在的理由。
    //
    // ⚠️ 所以这里**只能断言矩形**：溢出的子树照样在 widget 树里、照样画出来
    // （只是被 `Stack` 默认的 `Clip.hardEdge` 裁掉），`find.*` 一律找得到，
    // `takeException()` 也是 null —— 溢出是 `paint` 阶段报的。
    // 前一版这两条都写上了，实测在 200×300 和 360×640 两种尺寸下**都不会红**，
    // 是个永远绿的摆设。矩形断言才真的会红。
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    await tester.tap(manualTab);
    await tester.pumpAndSettle();

    // 这一页没有 AppBar，所以正文从 y = 0 开始，屏幕顶就是正文顶。
    final mustBeOnScreen = <String, Finder>{
      '抽屉面板': find.byType(SingleChildScrollView),
      '开始': find.text('开始'),
      '抽屉入口': find.byKey(const Key('work-sheet-events')),
    };
    for (final entry in mustBeOnScreen.entries) {
      expect(
        tester.getRect(entry.value).top,
        greaterThanOrEqualTo(0.0),
        reason: '键盘弹起时「${entry.key}」被顶出了屏幕顶，用户够不着',
      );
    }
  });

  testWidgets('★ 设置页：盘上的设置没读出来之前，档位控件必须是禁用的',
      (WidgetTester tester) async {
    // ⚠️ 先把视口拉高。设置页是 `ListView`，**屏幕外的卡片根本没建** ——
    // 默认的 800×600 下第三、四块不在树里，`find` 会找不到它们。
    // 2400 是 2026-09-23 加上「归档后的本地保留期」那块之后的高度 ——
    // 再加卡片就要跟着往上调，否则红的是 `find` 而不是真正想验的那条守卫。
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const VidLogApp());

    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();

    // 五块都在。验收工具那块缺了 M4 的「时长兜底」验收没法跑；
    // 生效时机那块缺了，用户改完没反应只会以为开关坏了。
    // 语音播报是需求方 2026-09-22 点名要的。
    expect(find.text('工作模式'), findsOneWidget);
    expect(find.text('防忘停录'), findsOneWidget);
    expect(find.text('语音播报'), findsOneWidget);
    expect(find.textContaining('时长兜底加速'), findsOneWidget);
    expect(find.textContaining('不用退出去重进'), findsOneWidget);

    // ⚠️ 这条是实质的。`_settings` 是 `_bootstrap` 里异步读出来的，
    // 读出来之前改设置会被随后读到盘上值直接覆盖 —— 用户看到的是
    // 「开关点了没反应」，而且下一次打开发现改的没了。
    // 所以控件在这段时间里必须是禁用的（`onSelectionChanged: null`）。
    //
    // widget 测试里没有平台通道，`_bootstrap` 必然失败 → `_settings` 恒为 null，
    // 正好就是这个状态。把 `_settingsReady` 那道守卫去掉，这条会红。
    expect(
      tester
          .widget<SegmentedButton<WorkMode>>(find.byType(SegmentedButton<WorkMode>))
          .onSelectionChanged,
      isNull,
      reason: '设置还没读出来就允许改 → 改完被盘上值覆盖，用户以为开关坏了',
    );
    expect(
      tester
          .widget<SegmentedButton<StaticStopSetting>>(
              find.byType(SegmentedButton<StaticStopSetting>))
          .onSelectionChanged,
      isNull,
    );
    expect(
      tester
          .widget<SegmentedButton<DurationFallbackSetting>>(
              find.byType(SegmentedButton<DurationFallbackSetting>))
          .onSelectionChanged,
      isNull,
    );

    // 归档后的本地保留期那两块下拉同理（规格 §3.5.2.1）。
    // 它们**两份各自一个**，所以两条都验 —— 只验一条的话，
    // 另一条漏掉守卫（`onChanged: (v) => ...` 而没套 `_settingsReady`）
    // 在真机上就是「退货那一份改了没反应」。
    for (final key in const [
      'settings-retention-outbound',
      'settings-retention-return',
    ]) {
      expect(
        tester
            .widget<DropdownButton<RetentionSetting>>(find.byKey(Key(key)))
            .onChanged,
        isNull,
        reason: '「$key」在设置读出来之前必须禁用',
      );
    }

    // 页上有两个开关，靠 key 取 —— 这也顺带把「哪个开关是哪个」钉住了。
    SwitchListTile switchAt(String key) =>
        tester.widget<SwitchListTile>(find.byKey(Key(key)));

    // 验收开关**不落盘**，所以它不依赖盘上的设置读没读出来 —— 一直是可用的。
    expect(switchAt('settings-accelerated-switch').onChanged, isNotNull);

    // ⚠️ 播报开关是**落盘**的，所以它跟着一起禁用。
    // 它同时是唯一「立刻生效」的一项设置：关它的人是因为现在就吵，
    // 让他「先结束工作再开始」是不合理的（`实现决策.md` §17.3）。
    expect(switchAt('settings-voice-switch').onChanged, isNull);
    expect(switchAt('settings-voice-switch').value, isTrue,
        reason: '设置没读出来时按开算 —— 不该静默把提示功能关掉');

    // 最小的真机宽度下，五档的静止档位选择器不能横着溢出。
    // 溢出的子树照样在 widget 树里、`find` 找得到、`takeException` 也是 null
    // （溢出是 paint 阶段报的）—— 所以这里只认矩形。
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    final staticStop = find.byType(SegmentedButton<StaticStopSetting>);
    expect(
      tester.getRect(staticStop).right,
      lessThanOrEqualTo(360.0),
      reason: '360dp 的屏上静止档位选择器超出了右边缘，最后两档点不到',
    );
  });
}
