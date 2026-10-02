import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';
import 'package:harbor_mail/oauth_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'oauth_test_fixtures.dart';

Future<void> openSettings(
  WidgetTester tester,
  MailApi api, {
  bool demo = false,
  bool settle = true,
  Size size = const Size(1000, 1100),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(api.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                          builder: (_) =>
                              OAuthSettingsPage(api: api, demoMode: demo))),
                  child: const Text('Open'),
                ))),
  ));
  await tester.tap(find.text('Open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> edit(WidgetTester tester, String key, String value) async {
  final field = find.byKey(Key(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> chooseProvider(WidgetTester tester, String provider) async {
  await tapVisible(tester, find.byKey(const Key('oauth-provider')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(oauthProviderNames[provider]!).last);
  await tester.pumpAndSettle();
}

MailApi apiWith(Future<http.Response> Function(http.Request) handler) =>
    MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient(handler),
    )..token = 'synthetic-admin-session';

void main() {
  testWidgets('loading has no editors; late completion after disposal is safe',
      (tester) async {
    final pending = Completer<http.Response>();
    await openSettings(tester, apiWith((_) => pending.future), settle: false);
    expect(find.text('正在载入配置…'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.byTooltip('返回账户设置'));
    await tester.pumpAndSettle();
    pending.complete(jsonResponse(snapshot()));
    await tester.pumpAndSettle();
    expect(find.text('系统 OAuth 设置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('load errors are sanitized and retry restores controls',
      (tester) async {
    var loads = 0;
    await openSettings(tester, apiWith((_) async {
      if (loads++ == 0) {
        return jsonResponse({
          'error': {'code': 'HTTP_500', 'message': 'sensitive-echo'}
        }, 500);
      }
      return jsonResponse(snapshot());
    }));
    expect(find.textContaining('操作未完成'), findsOneWidget);
    expect(find.textContaining('sensitive-echo'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text('重新载入配置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('oauth-client-id')), findsOneWidget);
    expect(loads, 2);
  });

  testWidgets('blank preserves secret and save remains explicitly unverified',
      (tester) async {
    Map<String, dynamic>? sent;
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      sent = jsonDecode(request.body);
      return jsonResponse({
        ...metadata('GMAIL', source: 'DATABASE', revision: 1),
        'clientId': 'new-app'
      });
    }));
    expect(find.textContaining('不可读取'), findsOneWidget);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('oauth-client-secret')))
            .controller!
            .text,
        isEmpty);
    await edit(tester, 'oauth-client-id', 'new-app');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(sent!['revision'], 0);
    expect(sent!.containsKey('clientSecret'), isFalse);
    expect(sent!.containsKey('clearClientSecret'), isFalse);
    expect(find.textContaining('配置已保存，尚未经过服务商授权验证'), findsOneWidget);
    expect(find.textContaining('数据库（已保存）'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('oauth-save')))
            .onPressed,
        isNull);
  });

  testWidgets('new secret is obscured, transmitted once and cleared after save',
      (tester) async {
    final writes = <Map<String, dynamic>>[];
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') {
        final data = snapshot();
        (data['items'] as List).first['clientSecret'] =
            'server-secret-must-be-ignored';
        return jsonResponse(data);
      }
      writes.add(jsonDecode(request.body));
      return jsonResponse(metadata('GMAIL', source: 'DATABASE', revision: 1));
    }));
    final input = find.byKey(const Key('oauth-client-secret'));
    expect(tester.widget<TextFormField>(input).controller!.text, isEmpty);
    await edit(tester, 'oauth-client-secret', 'synthetic-new-secret');
    final editable = tester.widget<EditableText>(
        find.descendant(of: input, matching: find.byType(EditableText)));
    expect(editable.obscureText, isTrue);
    expect(editable.autocorrect, isFalse);
    expect(editable.enableSuggestions, isFalse);
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(writes.single['clientSecret'], 'synthetic-new-secret');
    expect(tester.widget<TextFormField>(input).controller!.text, isEmpty);
    expect(find.textContaining('server-secret-must-be-ignored'), findsNothing);
  });

  testWidgets('clear requires confirmation and save; cancel makes no request',
      (tester) async {
    final writes = <Map<String, dynamic>>[];
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      writes.add(jsonDecode(request.body));
      return jsonResponse(
          metadata('GMAIL', source: 'DATABASE', revision: 1, hasSecret: false));
    }));
    await tapVisible(tester, find.byKey(const Key('oauth-clear-secret')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.textContaining('已标记清除'), findsNothing);
    await tapVisible(tester, find.byKey(const Key('oauth-clear-secret')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记清除'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.textContaining('已标记清除'), findsOneWidget);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('oauth-client-secret')))
            .enabled,
        isFalse);
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(writes.single['clearClientSecret'], isTrue);
    expect(writes.single.containsKey('clientSecret'), isFalse);
    expect(find.text('密钥状态：尚未配置'), findsOneWidget);
  });

  testWidgets('reset confirms destructive override removal and sends revision',
      (tester) async {
    final writes = <http.Request>[];
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') {
        final data = snapshot();
        (data['items'] as List)[0] =
            metadata('GMAIL', source: 'DATABASE', revision: 7);
        return jsonResponse(data);
      }
      writes.add(request);
      return jsonResponse(metadata('GMAIL', revision: 8));
    }));
    await tapVisible(tester, find.byKey(const Key('oauth-reset')));
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除此服务商的数据库覆盖配置'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tapVisible(tester, find.byKey(const Key('oauth-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复环境配置').last);
    await tester.pumpAndSettle();
    expect(writes.single.method, 'POST');
    expect(writes.single.url.path, '/api/v1/settings/oauth/GMAIL/reset');
    expect(jsonDecode(writes.single.body), {'revision': 7});
    expect(find.textContaining('已恢复环境配置'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('oauth-reset')))
            .onPressed,
        isNull);
  });

  for (final mode in ['capabilities-demo', 'server-demo', 'readonly']) {
    testWidgets('$mode prevents editing secrets or any mutation',
        (tester) async {
      var requests = 0;
      await openSettings(tester, apiWith((_) async {
        requests++;
        return jsonResponse(snapshot(
            demo: mode == 'server-demo', readOnly: mode == 'readonly'));
      }), demo: mode == 'capabilities-demo');
      for (final field
          in tester.widgetList<TextFormField>(find.byType(TextFormField))) {
        expect(field.enabled, isFalse);
      }
      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('oauth-save')))
              .onPressed,
          isNull);
      expect(
          tester
              .widget<TextButton>(find.byKey(const Key('oauth-clear-secret')))
              .onPressed,
          isNull);
      await chooseProvider(tester, 'OUTLOOK');
      expect(
          tester
              .widget<TextFormField>(
                  find.byKey(const Key('oauth-client-secret')))
              .enabled,
          isFalse);
      expect(requests, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('invalid redirect schemes paths and URL components block writes',
      (tester) async {
    var writes = 0;
    await openSettings(tester, apiWith((request) async {
      if (request.method != 'GET') writes++;
      return jsonResponse(snapshot());
    }));
    for (final url in [
      'http://mail.example.com/api/v1/oauth/GMAIL/callback',
      'https://mail.example.com:70000/api/v1/oauth/GMAIL/callback',
      'https://mail.example.com:0/api/v1/oauth/GMAIL/callback',
      'https://mail.example.com/wrong',
      'https://mail.example.com/api/v1/oauth/OUTLOOK/callback',
      'https://user:password@mail.example.com/api/v1/oauth/GMAIL/callback',
      'https://mail.example.com/api/v1/oauth/GMAIL/callback?x=1',
      'https://mail.example.com/api/v1/oauth/GMAIL/callback#fragment',
    ]) {
      await edit(tester, 'oauth-redirect-uri', url);
      await tapVisible(tester, find.byKey(const Key('oauth-save')));
      expect(find.textContaining('需使用 HTTPS，且路径为'), findsOneWidget);
    }
    expect(writes, 0);
  });

  testWidgets('Microsoft account types have separate tenant validation',
      (tester) async {
    final writes = <http.Request>[];
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      writes.add(request);
      return jsonResponse({
        ...metadata('EXCHANGE', source: 'DATABASE', revision: 1),
        'tenant': '12345678-1234-1234-1234-123456789abc'
      });
    }));
    await chooseProvider(tester, 'OUTLOOK');
    await edit(tester, 'oauth-tenant', 'organizations');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    expect(find.text('个人 Outlook 的租户必须为 consumers'), findsOneWidget);
    await chooseProvider(tester, 'EXCHANGE');
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    await edit(tester, 'oauth-tenant', 'consumers');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    expect(find.textContaining('不支持 common / consumers'), findsOneWidget);
    expect(writes, isEmpty);
    await edit(tester, 'oauth-tenant', '12345678-1234-1234-1234-123456789abc');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(writes.single.url.path, '/api/v1/settings/oauth/EXCHANGE');
  });

  testWidgets('pending save prevents duplicate writes, edits, back and Escape',
      (tester) async {
    final pending = Completer<http.Response>();
    var writes = 0;
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      writes++;
      return pending.future;
    }));
    await edit(tester, 'oauth-client-id', 'changed');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.tap(find.byKey(const Key('oauth-save')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(writes, 1);
    expect(find.text('系统 OAuth 设置'), findsOneWidget);
    expect(find.text('放弃未保存的配置？'), findsNothing);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('oauth-client-id')))
            .enabled,
        isFalse);
    pending.complete(jsonResponse({
      ...metadata('GMAIL', source: 'DATABASE', revision: 1),
      'clientId': 'changed'
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('配置已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'save disposal and failure do not leak secret or use disposed controllers',
      (tester) async {
    final pending = Completer<http.Response>();
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      return pending.future;
    }));
    await edit(tester, 'oauth-client-secret', 'synthetic-private');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpWidget(const SizedBox());
    pending.complete(jsonResponse({
      'error': {'code': 'INVALID_REQUEST', 'message': 'synthetic-private'}
    }, 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'revision conflict clears new secret and requires explicit reload',
      (tester) async {
    var loads = 0, writes = 0;
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') {
        loads++;
        return jsonResponse(snapshot());
      }
      writes++;
      return jsonResponse({
        'error': {
          'code': 'CONFIG_REVISION_CONFLICT',
          'message': 'synthetic-private'
        }
      }, 409);
    }));
    await edit(tester, 'oauth-client-id', 'changed');
    await edit(tester, 'oauth-client-secret', 'synthetic-private');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('配置已被其他会话修改'), findsOneWidget);
    expect(find.textContaining('synthetic-private'), findsNothing);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('oauth-client-secret')))
            .controller!
            .text,
        isEmpty);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('oauth-save')))
            .onPressed,
        isNull);
    expect(writes, 1);
    await tester.tap(find.byTooltip('重新载入配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('oauth-client-id')))
            .enabled,
        isTrue);
  });

  testWidgets(
      'dirty provider switch, back and Escape confirm without losing edits on cancel',
      (tester) async {
    await openSettings(tester, apiWith((_) async => jsonResponse(snapshot())));
    await edit(tester, 'oauth-client-secret', 'synthetic-unsaved');
    await chooseProvider(tester, 'OUTLOOK');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<DropdownButton<String>>(
                find.byKey(const Key('oauth-provider')))
            .value,
        'GMAIL');
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('oauth-client-secret')))
            .controller!
            .text,
        'synthetic-unsaved');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的配置？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的配置？'), findsOneWidget);
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(find.text('系统 OAuth 设置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save validation failure is safe and can retry with a new secret',
      (tester) async {
    var writes = 0;
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      if (writes++ == 0) {
        return jsonResponse({
          'error': {'code': 'INVALID_REQUEST', 'message': 'synthetic-private'}
        }, 400);
      }
      return jsonResponse(metadata('GMAIL', source: 'DATABASE', revision: 1));
    }));
    await edit(tester, 'oauth-client-secret', 'synthetic-private');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('配置未通过服务器校验'), findsOneWidget);
    expect(find.textContaining('synthetic-private'), findsNothing);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('oauth-client-secret')))
            .controller!
            .text,
        isEmpty);
    await edit(tester, 'oauth-client-secret', 'synthetic-retry');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(writes, 2);
    expect(find.textContaining('配置已保存'), findsOneWidget);
  });

  testWidgets('incomplete configuration can save but never appears connected',
      (tester) async {
    Map<String, dynamic>? sent;
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      sent = jsonDecode(request.body);
      return jsonResponse({
        ...metadata('GMAIL', source: 'DATABASE', revision: 1),
        'clientId': '',
        'redirectUri': '',
        'configured': false
      });
    }));
    await edit(tester, 'oauth-client-id', '');
    await edit(tester, 'oauth-redirect-uri', '');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(sent!['clientId'], isEmpty);
    expect(sent!['redirectUri'], isEmpty);
    expect(find.textContaining('本地校验：配置未完整或无效'), findsOneWidget);
    expect(find.textContaining('服务商验证：未验证'), findsOneWidget);
  });

  testWidgets(
      'network-uncertain save clears the editor and blocks automatic retry',
      (tester) async {
    var writes = 0;
    await openSettings(tester, apiWith((request) async {
      if (request.method == 'GET') return jsonResponse(snapshot());
      writes++;
      throw http.ClientException('synthetic-secret-do-not-render');
    }));
    await edit(tester, 'oauth-client-secret', 'synthetic-private');
    await tapVisible(tester, find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法确认服务器响应'), findsOneWidget);
    expect(find.textContaining('synthetic-secret-do-not-render'), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('oauth-save')))
            .onPressed,
        isNull);
    expect(writes, 1);
  });

  testWidgets(
      'mobile form has no overflow and account settings entry refreshes capabilities',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var capsReloaded = 0;
    final api = apiWith((request) async {
      if (request.url.path.endsWith('/capabilities')) {
        capsReloaded++;
        return jsonResponse({
          'features': {'oauthSettings': true},
          'providers': []
        });
      }
      return jsonResponse(snapshot(demo: true));
    });
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => SettingsDialog(api: api, caps: const {
                                'demoMode': true,
                                'features': {'oauthSettings': true},
                                'providers': []
                              })),
                      child: const Text('Open'),
                    )))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统 OAuth 设置'));
    await tester.pumpAndSettle();
    await chooseProvider(tester, 'EXCHANGE');
    await tester.ensureVisible(find.byKey(const Key('oauth-save')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('返回账户设置'));
    await tester.pumpAndSettle();
    expect(capsReloaded, 1);
    expect(find.text('账户与设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
