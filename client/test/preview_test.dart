// Deterministic, synthetic-data UI renders; no live provider calls.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/main.dart';

import 'widget_test.dart' show fake, signIn;

Future<void> _savePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/previews/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('render synthetic desktop and mobile UI previews', (
    tester,
  ) async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.otf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final key = GlobalKey();
    for (final entry in {
      'desktop': const Size(1440, 960),
      'mobile': const Size(390, 844),
      'compact': const Size(320, 720),
    }.entries) {
      tester.view.physicalSize = entry.value;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MailApp(api: fake(noAccounts: true)),
        ),
      );
      await signIn(tester);
      expect(tester.takeException(), isNull);
      await _savePreview(tester, key, '${entry.key}-onboarding');
      await tester.tap(find.text('连接邮箱').first);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _savePreview(tester, key, '${entry.key}-account-settings');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MailApp(api: fake(messageCount: 12)),
        ),
      );
      await signIn(tester);
      expect(tester.takeException(), isNull);
      await _savePreview(tester, key, '${entry.key}-mailbox-list');
      await tester.tap(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _savePreview(tester, key, '${entry.key}-synthetic');
      await tester.tap(find.byTooltip('返回列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField).first);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(ComposeDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _savePreview(tester, key, '${entry.key}-compose');
      await tester.tap(find.byTooltip('关闭写信窗口'));
      await tester.pumpAndSettle();
      expect(find.byType(ComposeDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}
