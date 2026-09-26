import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/app/recorder_page.dart';
import 'package:vidlog_mobile/diagnostics/app_log.dart';
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

  /// 「事件 ▸」抽屉现在**跟着日志走**（2026-09-26）。
  ///
  /// 以前它是页面自己一个 `List<String>` + 每次 `_log` 就 `setState` 整页；
  /// 现在数据源是 `AppLog.tail`（`ValueNotifier`），只有抽屉那两个控件订阅。
  ///
  /// ⚠️ 这里能这么测，是因为 `AppLog` **没 init 也能记**（缓冲模式）——
  /// widget 测试里没有平台通道，`_bootstrap` 走不到 init 那一步。
  testWidgets('★ 事件抽屉跟着日志走，不再重建整页', (WidgetTester tester) async {
    await AppLog.instance.resetForTesting();

    await tester.pumpWidget(const VidLogApp());

    // 抽屉入口在**采集页**上（备份页没有），先切过去。
    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();

    // ⚠️ 不写死 0：widget 测试里没有平台通道，`_bootstrap` 会失败并**记一条**——
    // 那一格恰恰证明「没 init 也照记」（缓冲模式）是通的。
    // 所以断言的是「这一条之后**多了一格**」。
    final before = AppLog.instance.tail.value.length;
    expect(find.text('事件 $before ▸'), findsOneWidget);

    AppLog.instance.info('界面', '一条测试事件');
    await tester.pump();

    // 入口上的条数跟着变 —— 用户靠它知道「刚刚有事情发生」。
    expect(find.text('事件 ${before + 1} ▸'), findsOneWidget);

    await tester.tap(find.byKey(const Key('work-sheet-events')));
    await tester.pumpAndSettle();

    expect(find.textContaining('一条测试事件'), findsOneWidget);

    await AppLog.instance.resetForTesting();
  });

  /// 本机名的输入框守门人（需求方 2026-09-23：上限 12 格，汉字算 2 格）。
  ///
  /// ⚠️ 这组**不起界面**，直接调那个格式化器。原因是那个弹窗要先加载
  /// `device.json`，而 widget 测试里没有平台通道 —— 框根本打不开
  /// （页面自己会降级成错误状态，`_identity` 是 null，`_editDeviceName` 直接返回）。
  /// 格式化器提成顶层就是为了这个：几何级地便宜，且测的是**同一段代码**。
  group('★ 本机名输入框：超 12 格就退回', () {
    TextEditingValue typed(String text) => TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );

    test('12 个字母打得进去，第 13 个进不来', () {
      expect(
        deviceNameInputFormatter
            .formatEditUpdate(TextEditingValue.empty, typed('abcdefghijkl'))
            .text,
        'abcdefghijkl',
      );

      expect(
        deviceNameInputFormatter
            .formatEditUpdate(typed('abcdefghijkl'), typed('abcdefghijklm'))
            .text,
        'abcdefghijkl',
        reason: '超了就整个退回上一次的值',
      );
    });

    // ⚠️ 这条正是「为什么不能用 `maxLength`」：`maxLength: 12` 数的是字符数，
    // 7 个汉字在它眼里只有 7，**会被放行**。它红了就说明上限换回了字符数。
    test('★ 第 7 个汉字进不来 —— 换成 maxLength 这条就会红', () {
      expect(
        deviceNameInputFormatter
            .formatEditUpdate(TextEditingValue.empty, typed('三号仓打包台'))
            .text,
        '三号仓打包台',
      );

      expect(
        deviceNameInputFormatter
            .formatEditUpdate(typed('三号仓打包台'), typed('三号仓打包台东'))
            .text,
        '三号仓打包台',
      );
    });

    test('在中间插字一样受管（不是只看末尾那几个）', () {
      // 12 个字母已经满了，光标挪到最前面再插一个 —— 也得退回来。
      final full = typed('abcdefghijkl');
      final inserted = TextEditingValue(
        text: 'Xabcdefghijkl',
        selection: const TextSelection.collapsed(offset: 1),
      );

      expect(
        deviceNameInputFormatter.formatEditUpdate(full, inserted).text,
        'abcdefghijkl',
      );
    });
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

    // ② 三个统计。数字本身才是这一块的实质内容。
    //
    // 标字是需求方 2026-09-23 照界面草图定的：本机 / 本机全部 / 总占用。
    // 第一块底下那句「今日录的」**是这里自己加的**（草图只有「本机」两个字）——
    // 光写「本机」会被读成「本机上全部」，和旁边那块撞车。理由写在 `_totalsCard`。
    //
    // ⚠️ 下面那张卡的筛选器上还有一个「全部」，容易和这里的「本机全部」
    // 看串。`ListView` 懒构建，此刻它还没被 build，所以这几条只可能命中的是
    // 统计那一块。**筛选器上那对字在下面单独验。**
    expect(find.text('本机'), findsOneWidget);
    expect(find.text('本机全部'), findsOneWidget);
    expect(find.text('总占用'), findsOneWidget);
    expect(find.text('0 条'), findsNWidgets(2), reason: '空机上本机和本机全部都是 0 条');
    expect(find.text('0 B'), findsOneWidget, reason: '空机上总占用是 0 B');

    // ③ 电脑备份。没配对就必须**明说传不上去**，而不是显示一个看起来正常的
    // 「主机已连接 / 0 条待上传」。
    expect(find.text('电脑备份'), findsOneWidget);
    expect(find.text('配对电脑'), findsOneWidget);
    expect(find.textContaining('录像传不上去'), findsOneWidget);

    // 没配对就不该有任何连通状态 —— 显示「离线」会让人以为「配过对、只是没连上」。
    //
    // ⚠️ 但**要显示「未连接」**：这是需求方 2026-09-23 照草图定的，
    // 而且它说的正是实话（没配过对），不会和「离线」混淆。
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('离线'), findsNothing);
    expect(find.text('连接'), findsNothing);
    expect(find.text('探测中…'), findsNothing);

    // 没配对就点不动【立即备份】。⚠️ 一个按得下去却什么都不发生的按钮，
    // 比一个禁用按钮糟得多（踩坑 #13）—— 而**为什么点不动**就写在它下面那行。
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '立即备份'))
          .onPressed,
      isNull,
    );

    // 【扫码连接】接上了（2026-09-26）。原来这里钉的是「**禁用且不会自己好**」
    // ——那时电脑端只解码、不出码，按钮是写死 `onPressed: null` 的。
    //
    // ⚠️ 顺着那条注释改的，不是删掉图个绿：现在它与**旁边那几个按钮同一条判据**
    // （设备信息读出来才可点）。所以这里断言的是「两者一致」，而不是
    // 「它是禁用的」—— 后者在这台测试机上会碰巧成立（启动还没走完），
    // 于是断言绿在一个巧合上。
    final scanButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '扫码连接'));
    final rescanButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '重新搜索'));

    expect(
      scanButton.onPressed == null,
      rescanButton.onPressed == null,
      reason: '【扫码连接】与相邻按钮同一条判据：设备信息读出来才可点',
    );

    // ⚠️ 这一页在真机上比一屏长，而 `ListView` 是**懒构建**的：下面那张卡
    // 不滚下去压根不会被 build，`find.text` 找不到它 —— 不是它不在，
    // 是它还没建。真机上这块本来也要滑，所以这里滚一下才是如实的。
    await tester.scrollUntilVisible(
      find.text('视频记录（共 0 条）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('视频记录（共 0 条）'), findsOneWidget); // ④ 视频记录

    // ⑤ 搜索框（需求方 2026-09-23 照草图加）。空的搜索框显示的是 hint。
    expect(find.text('搜索单号或日期'), findsOneWidget);

    // 真正的回归守卫是这条：以后谁往这一页塞一个假装连上了的状态，这里会红。
    // 假数字在真机上会被当成真的 —— 这个项目已经吃过一次亏。
    expect(find.textContaining('已连接'), findsNothing);
  });

  testWidgets('★ 什么都没备份的时候，整页一个「已备份」都不许出现',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    await tester.scrollUntilVisible(
      find.text('视频记录（共 0 条）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // ⚠️ **这一条比它看起来弱，先读清楚它到底锁住了什么。**
    //
    // 空机、没配对，一条录像都没有 ⇒ **一个小标都不会被画出来**，
    // 所以下面那四条 `findsNothing` 对「小标」而言是**平凡成立**的。
    // 它真正挡住的是**别的地方**（电脑备份那张卡、以后新加的卡片、
    // 页面顶上）出现一句「已备份」—— 那是这个项目唯一不能出的假话
    // （不变量 I3，§3.4.3 ★ 来自一次真实故障）。
    // 与上面 `expect(find.textContaining('已连接'), findsNothing)` 同一个路子。
    //
    // **不要**把这条读成「六段传到五段会说备份失败」验过了 —— 没有。
    for (final word in ['已备份', '备份中…', '待重试', '备份失败']) {
      expect(find.text(word), findsNothing, reason: '还没备份任何东西，却出现了「$word」');
    }

    // ⚠️ **小标本身在这里够不着**：它是 `_uploadChip(session)` 画的，
    // 而 `session` 要 `_bootstrap` 先读出 `index.jsonl` —— 那要走
    // `path_provider` 平台通道，widget 测试里没有实现（见本文件开头那条）。
    // 所以那条规矩钉在它**下游**两个可测的地方：
    // `archive_summary_test.dart`（归并规则，含 ★ 那条）
    // 和 `recording_totals_test.dart`（evidenceIds 从哪来）。
    // 剩下没测的是**接线**（`_archiveRecords` 有没有赋值、小标读的是不是这个字段）——
    // 两行赋值，且坏掉的后果**偏保守**（一律显示「未备份」，不会说「已备份」）。
    // 真机上按 `真机验收清单.md` §1.17 核，那一条才是真正的验收。
  });

  testWidgets('★ 视频记录的分页控件在这儿，档位是需求方定的 5/10/15', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 与上一条同一个理由：这一页比一屏长，不滚下去这张卡不会被 build。
    await tester.scrollUntilVisible(
      find.text('1/1'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // 默认筛「全部」（需求方 2026-09-22）。
    final segmented = tester.widget<SegmentedButton<bool>>(
      find.byType(SegmentedButton<bool>),
    );
    expect(segmented.selected, {false}, reason: '默认应该是「全部」');
    expect(segmented.segments.map((s) => (s.label as Text).data), ['全部', '今日']);

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

  testWidgets('★ 备份页在窄屏上不溢出（两个胶囊 + 五个按钮）', (WidgetTester tester) async {
    // 默认测试画布是 800×600（横着的），比任何手机都宽 ——
    // 而**布局溢出只在窄屏上才出得来**，宽画布上它永远是绿的。
    // 390 逻辑像素 ≈ 常见手机的宽度。
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const VidLogApp());
    await tester.pump();

    // 这一页比一屏长：不滚到底，下面那两张卡不会被 build，
    // 也就等于没验（`ListView` 懒构建）。
    await tester.scrollUntilVisible(
      find.text('1/1'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // `RenderFlex` 溢出在测试里是一条**真错误**（黄黑条那个东西），
    // 会被记下来交给 `takeException`。宽画布上它永远绿，所以这条必须窄着跑。
    expect(
      tester.takeException(),
      isNull,
      reason: '窄屏上溢出了 —— 多半是新加的胶囊或按钮那两处 Wrap 没兜住',
    );
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

    // 图标是齿轮（`Icons.settings_outlined`）不是滑杆 —— 2026-09-23
    // 照需求方的界面草图换掉了，`Icons.tune_outlined` 在这儿找不到才会红。
    await tester.tap(find.byIcon(Icons.settings_outlined));
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
