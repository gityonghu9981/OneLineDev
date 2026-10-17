import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:localai_app/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('APP 启动：底部导航「聊天」「设置」存在', (tester) async {
    await tester.pumpWidget(const LocalAiApp());
    expect(find.text('聊天'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('聊天页 UI：输入框/发送/输入切换/语音开关/清空齐备', (tester) async {
    await tester.pumpWidget(const LocalAiApp());
    // 空状态提示
    expect(find.textContaining('在下方输入消息'), findsOneWidget);
    // 输入框（hint = 输入消息...）
    expect(
        find.byWidgetPredicate((w) =>
            w is TextField && (w.decoration?.hintText ?? '') == '输入消息...'),
        findsOneWidget);
    // 输入切换按钮（默认键盘模式显示 keyboard 图标）
    expect(find.byIcon(Icons.keyboard), findsOneWidget);
    // 发送按钮
    expect(find.byIcon(Icons.send), findsOneWidget);
    // 清空对话按钮
    expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);
    // 语音开关
    expect(find.text('语音'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);

    // 切换到语音模式（微信式输入隔离）：显示「按住 说话」，输入框隐藏
    await tester.tap(find.byIcon(Icons.keyboard));
    await tester.pump();
    expect(find.text('按住 说话'), findsOneWidget);
    expect(
        find.byWidgetPredicate((w) =>
            w is TextField && (w.decoration?.hintText ?? '') == '输入消息...'),
        findsNothing);
  });

  testWidgets('导航切换到设置页：主题/连接管理/后端选择/当前后端/声线/保存齐备',
      (tester) async {
    await tester.pumpWidget(const LocalAiApp());
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    // 外观主题（明暗两套）
    expect(find.text('外观主题'), findsOneWidget);
    expect(find.text('白底黑字'), findsOneWidget);
    expect(find.text('黑底白字'), findsOneWidget);

    // 连接管理
    expect(find.text('连接管理'), findsOneWidget);
    expect(find.text('电脑局域网 IP'), findsOneWidget);
    expect(find.text('端口'), findsOneWidget);
    expect(find.text('连接'), findsWidgets);
    expect(find.text('断开'), findsOneWidget);

    // 多后端（v1.2.0）
    expect(find.text('后端选择'), findsOneWidget);

    // 当前后端设置（在 ListView 中，滚动到可见）
    await tester.scrollUntilVisible(find.textContaining('当前后端'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('当前后端'), findsWidgets);

    // 声线 + 保存（滚动到可见）
    await tester.scrollUntilVisible(find.text('声线选择'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('声线选择'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('保存设置'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('保存设置'), findsOneWidget);
  });

  testWidgets('未连接时发送消息提示「未连接」', (tester) async {
    await tester.pumpWidget(const LocalAiApp());
    // 输入文字并点发送（此时 bridge.connected=false，应提示未连接）
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField && (w.decoration?.hintText ?? '') == '输入消息...'),
        '你好');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    // 未连接时应在消息列表出现系统提示
    expect(find.text('⚠ 未连接，请先在「设置」连接电脑'), findsOneWidget);
  });
}
