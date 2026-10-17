import 'package:flutter_test/flutter_test.dart';

import 'package:localai_app/main.dart';

void main() {
  testWidgets('APP 启动冒烟测试', (WidgetTester tester) async {
    // 构建 APP 并触发一帧
    await tester.pumpWidget(const LocalAiApp());

    // 验证底部导航存在
    expect(find.text('聊天'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
