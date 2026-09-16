import 'package:flutter_test/flutter_test.dart';

import 'package:vidlog_mobile/main.dart';

void main() {
  testWidgets('外壳能启动', (WidgetTester tester) async {
    await tester.pumpWidget(const VidLogApp());

    expect(find.text('VidLog'), findsOneWidget);
  });
}
