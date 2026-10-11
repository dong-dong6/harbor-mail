// Synthetic account data only. PNGs are Flutter widget renders, not browser QA.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'widget_test.dart' show signIn;

void main() {
  testWidgets(
      'visible account navigation, duplicate labels, responsive renders',
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
    final requestedAccounts = <String?>[];
    for (final size in [
      const Size(1440, 960),
      const Size(390, 844),
      const Size(320, 720),
      const Size(800, 600)
    ]) {
      tester.view.physicalSize = size;
      final api = MailApi(
          base: 'https://fixture.invalid/api/v1',
          client: MockClient((req) async {
            dynamic body = {'items': []};
            if (req.url.path.endsWith('/auth/login')) {
              body = {'accessToken': 'synthetic'};
            }
            if (req.url.path.endsWith('/accounts')) {
              body = {
                'items': [
                  {
                    'id': 'personal',
                    'displayName': '个人邮箱',
                    'email': 'personal@example.invalid',
                    'provider': 'GOOGLE'
                  },
                  {
                    'id': 'work',
                    'displayName': '工作邮箱',
                    'email': 'work@example.invalid',
                    'provider': 'OUTLOOK'
                  },
                  {
                    'id': 'letters',
                    'displayName': 'letters@example.invalid',
                    'email': 'letters@example.invalid',
                    'provider': 'GOOGLE'
                  },
                ]
              };
            }
            if (req.url.path.endsWith('/settings/capabilities')) {
              body = {'demoMode': true, 'providers': []};
            }
            if (req.url.path.endsWith('/messages')) {
              requestedAccounts.add(req.url.queryParameters['accountId']);
              body = {
                'items': List.generate(
                    12,
                    (i) => {
                          'id': 'fixture-$i',
                          'accountId': i.isEven ? 'personal' : 'work',
                          'fromName': '合成发件人 ${i + 1}',
                          'subject': '测试邮件 · 界面与布局检查 ${i + 1}',
                          'snippet': '仅供自动化测试的合成内容，不是真实邮件。',
                          'isRead': i > 3,
                          'isStarred': i == 2,
                          'receivedAt': '2026-10-11T10:42:00Z',
                        }),
                'hasMore': false
              };
            }
            return http.Response(jsonEncode(body), 200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }));
      final key = GlobalKey();
      await tester
          .pumpWidget(RepaintBoundary(key: key, child: MailApp(api: api)));
      await signIn(tester);
      final desktop = size.width >= 720;
      final work = find
          .byKey(ValueKey(desktop ? 'account-work' : 'mobile-account-work'));
      expect(work, findsOneWidget);
      if (desktop) {
        expect(find.byKey(const ValueKey('account-personal')), findsOneWidget);
        final duplicate = find.descendant(
            of: find.byKey(const ValueKey('account-letters')),
            matching: find.text('letters@example.invalid'));
        expect(duplicate, findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file =
            File('build/previews/multi-account-${size.width.toInt()}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.ensureVisible(work);
      await tester.tap(work);
      await tester.pumpAndSettle();
      expect(requestedAccounts.last, 'work');
      expect(find.text('工作邮箱 · 收件箱'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}
