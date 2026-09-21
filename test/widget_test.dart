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
