// Synthetic-data-only renders used for desktop/mobile visual QA.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/oauth_settings.dart';
import 'package:http/testing.dart';
import 'oauth_test_fixtures.dart';

void main() {
  testWidgets('render OAuth settings desktop mobile and demo previews', (tester) async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.otf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final entry in {
      'desktop': const Size(1100, 1200),
      'mobile': const Size(390, 844),
      'demo': const Size(1100, 1200),
    }.entries) {
      final demo = entry.key == 'demo';
      final api = MailApi(base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async => jsonResponse(snapshot(demo: demo))))
        ..token = 'synthetic-session';
      tester.view.physicalSize = entry.value;
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, fontFamily: 'NotoSansSC',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff3378ed))),
        home: OAuthSettingsPage(api: api, demoMode: demo),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final part in ['top', 'bottom']) {
        if (part == 'bottom') {
          await tester.ensureVisible(find.byKey(const Key('oauth-save')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/previews/oauth-${entry.key}-$part.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      api.dispose();
    }
  });
}
