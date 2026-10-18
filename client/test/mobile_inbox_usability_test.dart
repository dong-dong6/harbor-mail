import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/main.dart';

import 'widget_test.dart' show fake, signIn;

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('compact inbox and direct compose at $width px', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MailApp(api: fake(messageCount: 12)));
      await signIn(tester);

      final compose = find.byKey(const Key('mobile-compose'));
      expect(compose.hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('message-m1'))).dy,
        lessThan(330),
      );
      expect(find.byTooltip('同步邮件').hitTestable(), findsOneWidget);
      await tester.tap(compose);
      await tester.pumpAndSettle();
      expect(find.byType(ComposeDialog), findsOneWidget);
      await tester.tap(find.byTooltip('关闭写信窗口'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      expect(compose, findsNothing);
      expect(find.text('回复').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('mobile primary action connects an empty mailbox', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MailApp(api: fake(noAccounts: true)));
    await signIn(tester);
    await tester.tap(find.byKey(const Key('mobile-compose')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountSettingsPage), findsOneWidget);
    expect(find.byKey(const Key('mobile-compose')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
