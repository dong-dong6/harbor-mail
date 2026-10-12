import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';
import 'package:harbor_mail/mail_navigation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Every request in this suite is synthetic and stays inside MockClient.
const _accounts = <Map<String, dynamic>>[
  {
    'id': 'alpha',
    'email': 'alpha@example.invalid',
    'displayName': 'Alpha 测试邮箱',
    'status': 'DEMO',
    'provider': 'GMAIL',
    'unreadCount': 1,
  },
  {
    'id': 'beta',
    'email': 'beta@example.invalid',
    'displayName': 'Beta 测试邮箱',
    'status': 'DEMO',
    'provider': 'GMAIL',
    'unreadCount': 0,
  },
];

Map<String, dynamic> _message(int index, {String account = 'alpha'}) => {
  'id': 'm$index',
  'accountId': account,
  'fromName': 'Synthetic sender $index',
  'fromAddress': 'sender$index@example.invalid',
  'subject': 'Synthetic subject $index',
  'snippet': 'Synthetic preview $index',
  'bodyText': 'Synthetic body $index',
  'receivedAt': '2026-10-01T08:00:00Z',
  'isRead': false,
  'isStarred': false,
  'revision': 1,
  'to': <Object>[],
  'attachments': <Object>[],
};

http.Response _json(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _page(
  Iterable<Map<String, dynamic>> messages, {
  String? cursor,
}) => _json({
  'items': messages.toList(),
  'coverage': 'DEMO',
  'hasMore': cursor != null,
  if (cursor != null) 'nextCursor': cursor,
});

class _Fixture {
  final List<Map<String, dynamic>> accounts;
  final List<Uri> listRequests = [];
  final List<http.Request> requests = [];
  final Map<String, Completer<http.Response>> delayedDetails = {};
  FutureOr<http.Response> Function(Uri uri)? listResponse;
  bool missingDetails = false;
  late final MailApi api;

  _Fixture() : accounts = _accounts {
    api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path.endsWith('/auth/login')) {
          return _json({'accessToken': 'synthetic-session'});
        }
        if (path.endsWith('/auth/logout')) return _json({});
        if (path.endsWith('/accounts')) return _json({'items': accounts});
        if (path.endsWith('/settings/capabilities')) {
          return _json({
            'demoMode': true,
            'providers': <Object>[],
            'limits': {'maxAttachmentBytes': 10485760},
            'features': {'html': false, 'offlineCache': false},
          });
        }
        if (path.endsWith('/folders')) {
          return _json({'items': <Object>[]});
        }
        if (path.endsWith('/messages')) {
          listRequests.add(request.url);
          if (listResponse != null) return await listResponse!(request.url);
          if (accounts.isEmpty) return _page([]);
          final isBeta = request.url.queryParameters['accountId'] == 'beta';
          final filtered =
              request.url.queryParameters['folder'] == 'STARRED' ||
              request.url.queryParameters.containsKey('query');
          return _page([
            _message(
              isBeta
                  ? 2
                  : filtered
                  ? 1
                  : 0,
              account: isBeta ? 'beta' : 'alpha',
            ),
          ]);
        }
        if (path.contains('/messages/')) {
          if (missingDetails) {
            return _json({
              'code': 'NOT_FOUND',
              'message': '邮件不存在或没有访问权限',
            }, status: 404);
          }
          final id = request.url.pathSegments.last;
          final pending = delayedDetails[id];
          if (pending != null) return pending.future;
          return _json(_message(int.parse(id.substring(1))));
        }
        throw StateError(
          'Unexpected synthetic request: ${request.method} $path',
        );
      }),
    );
  }

  Completer<http.Response> delayDetail(String id) =>
      delayedDetails[id] = Completer<http.Response>();
}

Future<void> _signIn(
  WidgetTester tester,
  _Fixture fixture, {
  Size size = const Size(1440, 1000),
  MailNavigation? navigation,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MailApp(api: fixture.api, navigation: navigation));
  await tester.enterText(find.byType(TextField).at(0), 'synthetic-owner');
  await tester.enterText(find.byType(TextField).at(1), 'synthetic-password');
  await tester.tap(find.text('登录'));
  await tester.pumpAndSettle();
}

Future<void> _disposeMailbox(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

class _Navigation extends MailNavigation {
  Future<bool> Function(String)? handler;
  _Navigation(String initial) {
    location = initial;
  }
  @override
  void listen(Future<bool> Function(String) onNavigate) {
    handler = onNavigate;
  }

  Future<bool> go(String target) async {
    final accepted = await handler!(target);
    if (accepted) location = target;
    return accepted;
  }
}

void main() {
  testWidgets('copied mail route resumes after memory-only login', (
    tester,
  ) async {
    final f = _Fixture();
    final nav = _Navigation('/mail/m1?account=alpha');
    await _signIn(tester, f, navigation: nav);
    expect(find.text('Synthetic body 1'), findsOneWidget);
    expect(nav.location, '/mail/m1?account=alpha');
    await _disposeMailbox(tester);
  });
  testWidgets('mail click and browser Back change URL and visible page', (
    tester,
  ) async {
    final f = _Fixture();
    final nav = _Navigation('/mail');
    await _signIn(tester, f, navigation: nav);
    await tester.tap(find.byKey(const ValueKey('message-m0')));
    await tester.pumpAndSettle();
    expect(nav.location, '/mail/m0');
    final back = nav.go('/mail');
    await tester.pumpAndSettle();
    expect(await back, isTrue);
    expect(find.byKey(const ValueKey('message-list')), findsOneWidget);
    await _disposeMailbox(tester);
  });
  testWidgets('dirty inline reply rejects browser Back and preserves text', (
    tester,
  ) async {
    final f = _Fixture();
    final nav = _Navigation('/mail/m0');
    await _signIn(tester, f, navigation: nav);
    await tester.tap(find.text('回复'));
    await tester.pumpAndSettle();
    final editor = tester.state<ComposeEditorState>(find.byType(ComposeEditor));
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller == editor.body,
      ),
      'keep reply',
    );
    final back = nav.go('/mail');
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(await back, isFalse);
    expect(nav.location, '/mail/m0');
    expect(find.text('keep reply'), findsOneWidget);
    await _disposeMailbox(tester);
  });
  testWidgets('uncertain-send editor blocks browser navigation', (
    tester,
  ) async {
    final f = _Fixture();
    final nav = _Navigation('/mail/m0');
    await _signIn(tester, f, navigation: nav);
    await tester.tap(find.text('回复'));
    await tester.pumpAndSettle();
    tester.state<ComposeEditorState>(find.byType(ComposeEditor)).sendUncertain =
        true;
    final back = nav.go('/mail');
    await tester.pumpAndSettle();
    expect(await back, isFalse);
    expect(nav.location, '/mail/m0');
    await _disposeMailbox(tester);
  });
  testWidgets('new browser mail target ignores old delayed detail', (
    tester,
  ) async {
    final f = _Fixture();
    final nav = _Navigation('/mail');
    await _signIn(tester, f, navigation: nav);
    final old = f.delayDetail('m0');
    await tester.tap(find.byKey(const ValueKey('message-m0')));
    await tester.pump();
    final go = nav.go('/mail/m1');
    await tester.pumpAndSettle();
    expect(await go, isTrue);
    old.complete(_json(_message(0)));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic body 1'), findsOneWidget);
    expect(find.text('Synthetic body 0'), findsNothing);
    await _disposeMailbox(tester);
  });
  testWidgets('new account selection supersedes slow browser route list', (
    tester,
  ) async {
    final f = _Fixture();
    final nav = _Navigation('/mail');
    await _signIn(tester, f, navigation: nav);
    final pending = Completer<http.Response>();
    f.listResponse = (uri) => uri.queryParameters['accountId'] == 'beta'
        ? _page([_message(2, account: 'beta')])
        : pending.future;
    final go = nav.go('/mail/m1');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('account-beta')));
    await tester.pumpAndSettle();
    pending.complete(_page([_message(0)]));
    await tester.pumpAndSettle();
    expect(await go, isFalse);
    expect(nav.location, '/mail?account=beta');
    expect(find.byKey(const ValueKey('message-m2')), findsOneWidget);
    await _disposeMailbox(tester);
  });
  testWidgets(
    'unavailable account falls back and missing mail is recoverable',
    (tester) async {
      final f = _Fixture()..missingDetails = true;
      final nav = _Navigation('/mail/m1?account=gone');
      await _signIn(tester, f, navigation: nav);
      expect(find.text('加载失败，重试'), findsOneWidget);
      expect(nav.location, '/mail/m1');
      await tester.tap(find.byTooltip('返回列表'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-list')), findsOneWidget);
      await _disposeMailbox(tester);
    },
  );
  testWidgets('copied add-account route resumes settings', (tester) async {
    final f = _Fixture();
    final nav = _Navigation('/settings/add');
    await _signIn(tester, f, navigation: nav);
    expect(find.byType(AddAccountPage), findsOneWidget);
    expect(nav.location, '/settings/add');
    final go = nav.go('/settings/accounts');
    await tester.pumpAndSettle();
    expect(await go, isTrue);
    expect(find.byType(AddAccountPage), findsNothing);
    await _disposeMailbox(tester);
  });
  testWidgets('dirty account name rejects browser Back', (tester) async {
    final f = _Fixture();
    final nav = _Navigation('/settings/accounts');
    await _signIn(tester, f, navigation: nav);
    await tester.tap(find.byKey(const ValueKey('edit-account-alpha')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('account-name-alpha')),
      'unsaved name',
    );
    final go = nav.go('/mail');
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的名称？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(await go, isFalse);
    expect(nav.location, '/settings/accounts');
    expect(find.text('unsaved name'), findsOneWidget);
    await _disposeMailbox(tester);
  });
}
