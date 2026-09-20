import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/main.dart';

void main() {
  testWidgets('外壳能启动', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    // 采集页的标题。**不去断言数据目录初始化完成** ——
    // 那要走平台通道，widget 测试里没有实现；页面自己会把它降级成一条错误状态。
    expect(find.text('VidLog · 采集'), findsOneWidget);
  });
}
