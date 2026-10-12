import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/passkey_login.dart';
import 'package:harbor_mail/passkey_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'passkey_test_fixtures.dart';

void main() {
  MailApi settingsApi(List<http.Request> requests) => MailApi(
    base: 'https://mail.example.test/api/v1',
    client: MockClient((r) async {
      requests.add(r);
      if (r.url.path.endsWith('/capabilities')) {
        return passkeyJson({'available': true, 'rpId': 'mail.example.test'});
      }
      if (r.url.path.endsWith('/registration/options')) {
        return passkeyJson(passkeyOptions(registration: true));
      }
      if (r.url.path.endsWith('/registration/verify')) {
        return passkeyJson(passkeyEntry());
      }
      if (r.url.path.endsWith('/delete')) return http.Response('', 204);
      return passkeyJson({
        'items': [passkeyEntry()],
      });
    }),
  )..token = 'owner-token';

  testWidgets(
    'settings does not open OS prompt until explicit password-confirmed click',
    (tester) async {
      final requests = <http.Request>[];
      final auth = SyntheticPasskeyAuthenticator();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PasskeySettingsPanel(
              api: settingsApi(requests),
              authenticator: auth,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.registerCalls, 0);
      await tester.tap(find.text('验证密码并添加通行密钥'));
      await tester.pumpAndSettle();
      expect(auth.registerCalls, 0);
      expect(find.text('请输入通行密钥名称和当前账户密码。'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '当前账户密码（仅用于本次确认）'),
        'synthetic-password',
      );
      await tester.ensureVisible(find.text('验证密码并添加通行密钥'));
      await tester.tap(find.text('验证密码并添加通行密钥'));
      await tester.pumpAndSettle();
      expect(auth.registerCalls, 1);
      expect(find.text('synthetic-password'), findsNothing);
      expect(
        requests
            .where((r) => r.url.path.endsWith('/registration/verify'))
            .length,
        1,
      );
      expect(find.textContaining('通行密钥已添加'), findsOneWidget);
    },
  );

  testWidgets('registration stop discards late OS result without verify', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final auth = SyntheticPasskeyAuthenticator()..pending = Completer();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasskeySettingsPanel(
            api: settingsApi(requests),
            authenticator: auth,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '当前账户密码（仅用于本次确认）'),
      'synthetic-password',
    );
    await tester.tap(find.text('验证密码并添加通行密钥'));
    await tester.pumpAndSettle();
    expect(auth.registerCalls, 1);
    await tester.tap(find.text('停止等待'));
    await tester.pumpAndSettle();
    auth.pending!.complete(syntheticCredential(registration: true));
    await tester.pumpAndSettle();
    expect(
      requests.where((r) => r.url.path.endsWith('/registration/verify')),
      isEmpty,
    );
  });

  testWidgets(
    'deletion names key, requires password, cancellation is read-only',
    (tester) async {
      final requests = <http.Request>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PasskeySettingsPanel(
              api: settingsApi(requests),
              authenticator: SyntheticPasskeyAuthenticator(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('移除 我的通行密钥'));
      await tester.tap(find.byTooltip('移除 我的通行密钥'));
      await tester.pumpAndSettle();
      expect(find.textContaining('“我的通行密钥”将无法再登录'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认移除'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.url.path.endsWith('/delete')), isEmpty);
      await tester.tap(find.byTooltip('移除 我的通行密钥'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '输入当前账户密码以确认移除'),
        'synthetic-password',
      );
      await tester.pump();
      await tester.tap(find.text('确认移除'));
      await tester.pumpAndSettle();
      final sent = requests.where((r) => r.url.path.endsWith('/delete')).single;
      expect(jsonDecode(sent.body), {'password': 'synthetic-password'});
      expect(find.textContaining('服务器已移除此通行密钥'), findsOneWidget);
    },
  );

  testWidgets(
    'login resolves edited server only at click and returns memory session',
    (tester) async {
      var acquired = 0, logged = 0;
      final requests = <http.Request>[];
      final api = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          requests.add(r);
          return passkeyJson(
            r.url.path.endsWith('/options')
                ? passkeyOptions()
                : passkeySession(),
          );
        }),
      );
      final auth = SyntheticPasskeyAuthenticator();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PasskeyLoginButton(
              acquireApi: () async {
                acquired++;
                return api;
              },
              authenticator: auth,
              onAuthenticated: (received, session) {
                expect(received, same(api));
                logged++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(acquired, 0);
      expect(auth.authenticateCalls, 0);
      await tester.tap(find.text('使用通行密钥登录'));
      await tester.pumpAndSettle();
      expect(acquired, 1);
      expect(logged, 1);
      expect(api.token, isNull);
      expect(requests.every((r) => r.url.host == 'mail.example.test'), isTrue);
    },
  );

  testWidgets(
    'changing server context or unmount discards pending login success',
    (tester) async {
      for (final unmount in [false, true]) {
        var logged = 0, verifyCalls = 0;
        final pending = Completer<Map<String, dynamic>>();
        final auth = SyntheticPasskeyAuthenticator()..pending = pending;
        final api = MailApi(
          base: 'https://mail.example.test/api/v1',
          client: MockClient((r) async {
            if (r.url.path.endsWith('/verify')) verifyCalls++;
            return passkeyJson(passkeyOptions());
          }),
        );
        Widget app(String context) => MaterialApp(
          home: Scaffold(
            body: PasskeyLoginButton(
              api: api,
              contextKey: context,
              authenticator: auth,
              onAuthenticated: (_, _) {
                logged++;
              },
            ),
          ),
        );
        await tester.pumpWidget(app('first-server'));
        await tester.tap(find.text('使用通行密钥登录'));
        await tester.pumpAndSettle();
        expect(auth.authenticateCalls, 1);
        await tester.pumpWidget(unmount ? const SizedBox() : app('new-server'));
        pending.complete(syntheticCredential());
        await tester.pumpAndSettle();
        expect(logged, 0);
        expect(verifyCalls, 0);
      }
    },
  );

  testWidgets('cancel login then late verification never hands over session', (
    tester,
  ) async {
    final verify = Completer<http.Response>();
    var logged = 0;
    final api = MailApi(
      base: 'https://mail.example.test/api/v1',
      client: MockClient(
        (r) async => r.url.path.endsWith('/options')
            ? passkeyJson(passkeyOptions())
            : verify.future,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasskeyLoginButton(
            api: api,
            authenticator: SyntheticPasskeyAuthenticator(),
            onAuthenticated: (_, _) {
              logged++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('使用通行密钥登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消通行密钥登录'));
    verify.complete(passkeyJson(passkeySession()));
    await tester.pumpAndSettle();
    expect(logged, 0);
  });

  testWidgets('settings remains usable at narrow 360px width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasskeySettingsPanel(
            api: settingsApi([]),
            authenticator: SyntheticPasskeyAuthenticator(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('通行密钥'), findsOneWidget);
  });
}
