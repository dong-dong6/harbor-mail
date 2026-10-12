import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/account_settings.dart';
import 'package:harbor_mail/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const account = <String, dynamic>{
  'id': 'a',
  'email': 'synthetic@example.invalid',
  'displayName': 'Synthetic account',
  'provider': 'GMAIL',
  'status': 'CONNECTED',
  'canDisconnect': true,
};
http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Future<void> mount(
  WidgetTester tester,
  MailApi api, {
  GlobalKey<AccountSettingsPageState>? key,
  ValueChanged<List<Map<String, dynamic>>>? changed,
  double width = 1000,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AccountSettingsPage(
          key: key,
          api: api,
          caps: const {},
          initialAccounts: const [account],
          onAccountsChanged: changed,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'connected accounts first; name patch contains displayName only and refresh updates parent',
    (tester) async {
      final requests = <http.Request>[];
      List<Map<String, dynamic>>? changed;
      final api = MailApi(
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'PATCH')
            return json({...account, 'displayName': 'Work mailbox'});
          return json({
            'items': [account],
          });
        }),
      );
      await mount(tester, api, changed: (next) => changed = next);
      expect(find.text('已连接邮箱'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('IMAP / SMTP 授权码'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('edit-account-a')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('account-name-a')),
        'Work mailbox',
      );
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.last.body), {'displayName': 'Work mailbox'});
      expect(changed!.single['displayName'], 'Work mailbox');
      expect(find.text('Work mailbox'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disconnect explains local removal and provider preservation then removes only target',
    (tester) async {
      var deleted = false;
      final api = MailApi(
        client: MockClient((r) async {
          if (r.method == 'DELETE') {
            deleted = true;
            return http.Response('', 204);
          }
          return json({
            'items': [
              account,
              {
                ...account,
                'id': 'b',
                'email': 'other@example.invalid',
                'displayName': 'Other',
              },
            ],
          });
        }),
      );
      await mount(tester, api);
      await tester.tap(find.byKey(const ValueKey('disconnect-account-a')));
      await tester.pumpAndSettle();
      expect(find.textContaining('本地缓存邮件、附件、草稿'), findsOneWidget);
      expect(find.textContaining('服务商邮箱及其中的邮件不会被删除'), findsOneWidget);
      expect(deleted, isFalse);
      await tester.tap(find.text('断开邮箱'));
      await tester.pumpAndSettle();
      expect(deleted, isTrue);
      expect(find.text('Synthetic account'), findsNothing);
      expect(find.text('Other'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('blocked disconnect and 409 preserve account', (tester) async {
    var deletes = 0;
    final api = MailApi(
      client: MockClient((r) async {
        if (r.method == 'DELETE') {
          deletes++;
          return json({
            'error': {'code': 'ACCOUNT_BUSY'},
          }, 409);
        }
        return json({
          'items': [
            account,
            {...account, 'id': 'blocked', 'canDisconnect': false},
          ],
        });
      }),
    );
    await mount(tester, api);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('disconnect-account-blocked')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('disconnect-account-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('断开邮箱'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
    expect(find.textContaining('未断开邮箱'), findsOneWidget);
    expect(find.byKey(const ValueKey('disconnect-account-a')), findsOneWidget);
  });

  testWidgets(
    'stale account GET cannot overwrite saved rename; pending save prevents leaving',
    (tester) async {
      final key = GlobalKey<AccountSettingsPageState>();
      final stale = Completer<http.Response>(),
          patch = Completer<http.Response>();
      var reads = 0;
      final api = MailApi(
        client: MockClient((r) async {
          if (r.method == 'PATCH') return patch.future;
          if (++reads == 2) return stale.future;
          return json({
            'items': [account],
          });
        }),
      );
      await mount(tester, api, key: key);
      unawaited(key.currentState!.reload());
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('edit-account-a')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('account-name-a')),
        'Fresh name',
      );
      await tester.tap(find.text('保存名称'));
      await tester.pump();
      expect(await key.currentState!.canLeave(), isFalse);
      patch.complete(json({...account, 'displayName': 'Fresh name'}));
      await tester.pumpAndSettle();
      stale.complete(
        json({
          'items': [account],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fresh name'), findsOneWidget);
      expect(find.text('Synthetic account'), findsNothing);
    },
  );

  testWidgets(
    'dirty names and new masked authorization-code forms protect leave',
    (tester) async {
      final key = GlobalKey<AccountSettingsPageState>();
      final api = MailApi(
        client: MockClient(
          (_) async => json({
            'items': [account],
          }),
        ),
      );
      await mount(tester, api, key: key);
      await tester.tap(find.byKey(const ValueKey('edit-account-a')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('account-name-a')),
        'Unsaved name',
      );
      final leave = key.currentState!.canLeave();
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await leave, isFalse);
      expect(find.text('Unsaved name'), findsOneWidget);
      final go = key.currentState!.showSection('add');
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      await go;
      expect(find.text('IMAP / SMTP 授权码'), findsOneWidget);
      final code = find.widgetWithText(TextField, 'IMAP / SMTP 授权码');
      expect(tester.widget<TextField>(code).obscureText, isTrue);
      await tester.enterText(code, 'synthetic-only-code');
      final leaveAdd = key.currentState!.canLeave();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的连接信息？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(await leaveAdd, isFalse);
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets('account management and add page fit ${width.toInt()}px', (
      tester,
    ) async {
      final api = MailApi(
        client: MockClient(
          (_) async => json({
            'items': [account],
          }),
        ),
      );
      final key = GlobalKey<AccountSettingsPageState>();
      await mount(tester, api, key: key, width: width);
      expect(tester.takeException(), isNull);
      await key.currentState!.showSection('add');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('添加邮箱'), findsWidgets);
    });
  }
}
