import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/main.dart';

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

  testWidgets('★ 发货与退货共用同一个录制页（不是两份）', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 「开始工作」只该有一个。做成两份页面的话，两栏各一个 ——
    // 而背后是**两个 `UiKitView`、两次开相机**，真机上相机同时只开得了一个。
    // 这条锁的就是「栈里只有三个孩子」那个决定。
    Finder workButton() => find.text('开始工作');

    await tester.tap(find.byIcon(Icons.local_shipping_outlined));
    await tester.pumpAndSettle();
    expect(workButton(), findsOneWidget);

    await tester.tap(find.byIcon(Icons.assignment_return_outlined));
    await tester.pumpAndSettle();
    expect(workButton(), findsOneWidget, reason: '退货这一栏不该再开一个录制页');
  });
}
