import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class Fixture {
  final accounts = <Map<String, dynamic>>[
    {
      'id': 'a',
      'email': 'a@example.invalid',
      'displayName': 'Account A',
      'status': 'CONNECTED',
      'canDisconnect': true,
    },
    {
      'id': 'b',
      'email': 'b@example.invalid',
      'displayName': 'Account B',
      'status': 'CONNECTED',
      'canDisconnect': true,
    },
  ];
  final lists = <Uri>[];
  late final MailApi api = MailApi(
    base: 'https://mail.invalid/api/v1',
    client: MockClient((r) async {
      final path = r.url.path;
      if (path.endsWith('/auth/login'))
        return json({'accessToken': 'synthetic'});
      if (r.method == 'DELETE') {
        accounts.removeWhere((a) => path.endsWith('/${a['id']}'));
        return http.Response('', 204);
      }
      if (path.endsWith('/accounts')) return json({'items': accounts});
      if (path.endsWith('/settings/capabilities'))
        return json({
          'providers': [],
          'limits': {'maxAttachmentBytes': 10485760},
        });
      if (path.endsWith('/folders')) return json({'items': []});
      if (path.endsWith('/messages')) {
        lists.add(r.url);
        return json({
          'items': [message('m1'), message('m2')],
          'hasMore': false,
        });
      }
      if (path.contains('/messages/'))
        return json(message(path.split('/').last));
      throw StateError('Unexpected synthetic request ${r.method} $path');
    }),
  );
  Map<String, dynamic> message(String id) => {
    'id': id,
    'accountId': accounts.first['id'],
    'subject': 'Subject $id',
    'fromAddress': 'sender@example.invalid',
    'to': [
      {'address': 'a@example.invalid'},
    ],
    'cc': [
      {'address': 'cc@example.invalid'},
    ],
    'receivedAt': '2026-10-01T08:00:00Z',
    'bodyText': List.filled(90, 'Synthetic long content').join('\n'),
    'attachments': [],
    'revision': 1,
  };
}

Future<void> login(WidgetTester tester, Fixture f) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MailApp(api: f.api));
  await tester.enterText(find.widgetWithText(TextField, '用户名'), 'synthetic');
  await tester.enterText(find.widgetWithText(TextField, '密码'), 'synthetic');
  await tester.tap(find.text('登录'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'disconnect selected account returns to unified inbox and keeps remaining mailbox',
    (tester) async {
      final f = Fixture();
      await login(tester, f);
      await tester.tap(find.byKey(const ValueKey('account-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('账户与设置'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const ValueKey('disconnect-account-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('断开邮箱'));
      await tester.pumpAndSettle();
      final state = tester.state<MailboxState>(find.byType(Mailbox));
      expect(state.account, '');
      expect(state.accounts.single['id'], 'b');
      expect(f.lists.last.queryParameters['accountId'], isNull);
      await tester.tap(find.byTooltip('返回邮箱'));
      await tester.pumpAndSettle();
      expect(find.text('全部账户 · 收件箱'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'every open resets reader scroll and inline draft guards account navigation',
    (tester) async {
      final f = Fixture();
      await login(tester, f);
      await tester.tap(find.byKey(const ValueKey('message-m1')));
      await tester.pumpAndSettle();
      final state = tester.state<MailboxState>(find.byType(Mailbox));
      state.detailScroll.jumpTo(1200);
      await tester.pump();
      expect(state.detailScroll.offset, greaterThan(0));
      await tester.tap(find.byTooltip('返回列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-m2')));
      await tester.pumpAndSettle();
      expect(state.detailScroll.offset, 0);
      expect(find.text('Subject m2'), findsOneWidget);
      await tester.ensureVisible(find.text('回复'));
      await tester.tap(find.text('回复'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('inline-compose')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('inline-body')),
        'Do not discard',
      );
      await tester.tap(find.byKey(const ValueKey('account-b')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的更改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(state.account, '');
      expect(find.text('Do not discard'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      expect(state.account, 'b');
      expect(find.byKey(const Key('inline-compose')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
