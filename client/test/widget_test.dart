import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';

MailApi fake({bool noAccounts = false, int messageCount = 1}) => MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((req) async {
        final p = req.url.path;
        dynamic value;
        if (p.endsWith('/auth/login')) {
          value = {'accessToken': 'fake-session', 'demoMode': true};
        } else if (p.endsWith('/accounts')) {
          value = {
            'items': noAccounts
                ? []
                : [
                    {
                      'id': 'demo',
                      'email': 'demo@example.invalid',
                      'displayName': '演示邮箱',
                      'status': 'DEMO',
                      'unreadCount': 1,
                    },
                  ],
          };
        } else if (p.endsWith('/settings/capabilities')) {
          value = {
            'demoMode': true,
            'providers': [],
            'limits': {'maxAttachmentBytes': 10485760},
            'features': {'html': false, 'offlineCache': false},
          };
        } else if (p.endsWith('/messages/m1')) {
          value = {
            'id': 'm1',
            'accountId': 'demo',
            'fromName': '设计团队',
            'fromAddress': 'design@example.invalid',
            'subject': '欢迎来到泊信',
            'bodyText': '安全的纯文本内容',
            'bodyHtml': '<script>alert(1)</script>',
            'to': [],
            'attachments': [],
            'isRead': false,
            'isStarred': false,
            'revision': 1,
          };
        } else if (p.endsWith('/messages')) {
          value = {
            'items': noAccounts
                ? []
                : List.generate(
                    messageCount,
                    (index) => {
                      'id': 'm${index + 1}',
                      'accountId': 'demo',
                      'fromName': index == 0 ? '设计团队' : '合成发件人 ${index + 1}',
                      'fromAddress': 'design@example.invalid',
                      'subject': index == 0 ? '欢迎来到泊信' : '合成测试邮件 ${index + 1}',
                      'snippet': '一个安静的邮件空间',
                      'receivedAt': '2026-09-30T05:00:00Z',
                      'isRead': index.isOdd,
                      'isStarred': index % 3 == 1,
                      'revision': 1,
                    },
                  ),
            'hasMore': false,
            'coverage': 'DEMO',
          };
        } else {
          value = {'items': []};
        }
        return http.Response(
          jsonEncode(value),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
Future<void> signIn(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).at(0), 'owner');
  await tester.enterText(find.byType(TextField).at(1), 'test-only');
  await tester.ensureVisible(find.text('登录'));
  await tester.pumpAndSettle();
  expect(find.text('登录').hitTestable(), findsOneWidget);
  await tester.tap(find.text('登录'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('login, desktop inbox, safe detail and compose', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MailApp(api: fake()));
    expect(find.text('泊信'), findsOneWidget);
    await signIn(tester);
    expect(find.textContaining('演示环境'), findsOneWidget);
    expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('message-m1')));
    await tester.pumpAndSettle();
    expect(find.text('安全的纯文本内容'), findsOneWidget);
    expect(find.text('<script>alert(1)</script>'), findsNothing);
    await tester.tap(find.text('写邮件'));
    await tester.pumpAndSettle();
    expect(find.text('写一封邮件'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭写信窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账户与设置'));
    await tester.pumpAndSettle();
    expect(find.text('已连接邮箱'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byTooltip('返回邮箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发件状态'));
    await tester.pumpAndSettle();
    expect(find.text('暂无发送记录'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('草稿箱'));
    await tester.pumpAndSettle();
    expect(find.text('暂时没有草稿'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(find.text('登录你的私人邮件服务器'), findsOneWidget);
    expect(find.textContaining('欢迎来到泊信'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('mobile opens detail without overflow and returns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MailApp(api: fake()));
    await signIn(tester);
    await tester.tap(find.byKey(const ValueKey('message-m1')));
    await tester.pumpAndSettle();
    expect(find.text('安全的纯文本内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
