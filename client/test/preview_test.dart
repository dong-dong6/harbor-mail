// Deterministic, synthetic-data UI renders; no live provider calls.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/main.dart';
import 'widget_test.dart' show fake, signIn;

void main() {
  testWidgets('render synthetic desktop and mobile UI previews',
      (tester) async {
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
      'mobile': const Size(390, 844)
    }.entries) {
      tester.view.physicalSize = entry.value;
      await tester
          .pumpWidget(RepaintBoundary(key: key, child: MailApp(api: fake())));
      await signIn(tester);
      await tester.tap(find.text('欢迎来到泊信'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/previews/${entry.key}-synthetic.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}
