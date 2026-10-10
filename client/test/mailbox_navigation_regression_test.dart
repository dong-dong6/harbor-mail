import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Every request in this suite is synthetic and stays inside MockClient.
const _accounts = <Map<String, dynamic>>[
  {
    'id': 'alpha',
    'email': 'alpha@example.invalid',
    'displayName': 'Alpha 测试邮箱',
    'status': 'DEMO',
    'unreadCount': 1,
  },
  {
    'id': 'beta',
    'email': 'beta@example.invalid',
    'displayName': 'Beta 测试邮箱',
    'status': 'DEMO',
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
}) =>
    _json({
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
  late final MailApi api;

  _Fixture({this.accounts = _accounts}) {
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
          final filtered = request.url.queryParameters['folder'] == 'STARRED' ||
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MailApp(api: fixture.api));
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

Finder get _messageList => find.byKey(const ValueKey('message-list'));
Finder _row(int index) => find.byKey(ValueKey('message-m$index'));
Finder get _listScrollable =>
    find.descendant(of: _messageList, matching: find.byType(Scrollable)).first;
Finder get _search => find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '搜索已同步的邮件',
    );

Future<void> _chooseBeta(WidgetTester tester) async {
  await tester.tap(find.byTooltip('切换邮箱账户'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Beta 测试邮箱').last);
  await tester.pumpAndSettle();
}

Future<void> _reachLoadMore(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('加载更多'),
    500,
    scrollable: _listScrollable,
    maxScrolls: 60,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop list and reader each use the available mailbox width', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _signIn(tester, fixture);
    expect(tester.getSize(_messageList).width, greaterThan(1000));
    expect(find.text('为重要的消息留一点空间'), findsNothing);
    await tester.tap(_row(0));
    await tester.pumpAndSettle();
    expect(_messageList, findsNothing);
    expect(find.text('Synthetic body 0'), findsOneWidget);
    expect(find.byTooltip('返回列表'), findsOneWidget);
    final reader = find.ancestor(
      of: find.text('Synthetic body 0'),
      matching: find.byType(SingleChildScrollView),
    );
    expect(tester.getSize(reader).width, greaterThan(1000));
    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    expect(_messageList, findsOneWidget);
    expect(_row(0), findsOneWidget);
    await _disposeMailbox(tester);
  });

  testWidgets('folder navigation invalidates a slow detail response', (
    tester,
  ) async {
    final fixture = _Fixture();
    final detail = fixture.delayDetail('m0');
    await _signIn(tester, fixture);
    await tester.tap(_row(0));
    await tester.pump();
    await tester.tap(find.text('星标邮件'));
    await tester.pumpAndSettle();
    expect(_row(1), findsOneWidget);
    detail.complete(_json(_message(0)));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic body 0'), findsNothing);
    expect(find.byTooltip('返回列表'), findsNothing);
    expect(_row(1), findsOneWidget);
    expect(fixture.listRequests.last.queryParameters['folder'], 'STARRED');
    await _disposeMailbox(tester);
  });

  testWidgets('account navigation invalidates a slow detail response', (
    tester,
  ) async {
    final fixture = _Fixture();
    final detail = fixture.delayDetail('m0');
    await _signIn(tester, fixture);
    await tester.tap(_row(0));
    await tester.pump();
    // A pending detail has an indeterminate progress indicator. Pump bounded
    // animation frames rather than waiting for it to settle before navigation.
    await tester.tap(find.byTooltip('切换邮箱账户'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.tap(find.text('Beta 测试邮箱').last);
    await tester.pumpAndSettle();
    expect(_row(2), findsOneWidget);
    detail.complete(_json(_message(0)));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic body 0'), findsNothing);
    expect(_row(2), findsOneWidget);
    expect(fixture.listRequests.last.queryParameters['accountId'], 'beta');
    await _disposeMailbox(tester);
  });

  testWidgets('search invalidates detail before its debounce completes', (
    tester,
  ) async {
    final fixture = _Fixture();
    final detail = fixture.delayDetail('m0');
    await _signIn(tester, fixture);
    await tester.tap(_row(0));
    await tester.pump();
    await tester.enterText(_search, 'fresh query');
    detail.complete(_json(_message(0)));
    await tester.pump();
    expect(
      find.text('Synthetic body 0'),
      findsNothing,
      reason: 'A superseded detail must not reopen during search debounce.',
    );
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(_row(1), findsOneWidget);
    expect(find.byTooltip('返回列表'), findsNothing);
    expect(fixture.listRequests.last.queryParameters['query'], 'fresh query');
    await _disposeMailbox(tester);
  });

  testWidgets('back invalidates a slow detail response on desktop and mobile', (
    tester,
  ) async {
    for (final size in [
      const Size(1440, 1000),
      const Size(390, 844),
      const Size(320, 720),
    ]) {
      final fixture = _Fixture();
      final detail = fixture.delayDetail('m0');
      await _signIn(tester, fixture, size: size);
      await tester.tap(_row(0));
      await tester.pump();
      await tester.tap(find.byTooltip('返回列表'));
      await tester.pumpAndSettle();
      detail.complete(_json(_message(0)));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic body 0'), findsNothing);
      expect(find.byTooltip('返回列表'), findsNothing);
      expect(_row(0), findsOneWidget);
      await _disposeMailbox(tester);
    }
  });

  testWidgets(
    'a superseded detail failure does not pollute the current folder',
    (tester) async {
      final fixture = _Fixture();
      final detail = fixture.delayDetail('m0');
      await _signIn(tester, fixture);
      await tester.tap(_row(0));
      await tester.pump();
      await tester.tap(find.text('星标邮件'));
      await tester.pumpAndSettle();
      detail.complete(
        _json({
          'error': {
            'code': 'SYNTHETIC_ERROR',
            'message': 'Obsolete detail failure',
          },
        }, status: 500),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Obsolete detail failure'), findsNothing);
      expect(find.text('加载失败，重试'), findsNothing);
      expect(_row(1), findsOneWidget);
      await _disposeMailbox(tester);
    },
  );

  testWidgets('a stale detail cannot replace a newer selected message', (
    tester,
  ) async {
    final fixture = _Fixture()
      ..listResponse = (_) => _page([_message(0), _message(1)]);
    final detail = fixture.delayDetail('m0');
    await _signIn(tester, fixture);
    await tester.tap(_row(0));
    await tester.pump();
    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    await tester.tap(_row(1));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic body 1'), findsOneWidget);
    detail.complete(_json(_message(0)));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic body 1'), findsOneWidget);
    expect(find.text('Synthetic body 0'), findsNothing);
    await _disposeMailbox(tester);
  });

  testWidgets('silent 30 second refresh preserves loaded pages and scroll', (
    tester,
  ) async {
    final fixture = _Fixture();
    fixture.listResponse = (uri) {
      if (uri.queryParameters['cursor'] == 'page-2') {
        return _page(List.generate(40, (index) => _message(index + 40)));
      }
      return _page(List.generate(40, _message), cursor: 'page-2');
    };
    await _signIn(tester, fixture);
    await _reachLoadMore(tester);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.textContaining('80 封已加载'), findsOneWidget);
    final scroll = tester.state<ScrollableState>(_listScrollable).position;
    scroll.jumpTo(scroll.maxScrollExtent - 100);
    await tester.pumpAndSettle();
    final before = scroll.pixels;
    final requestCount = fixture.listRequests.length;
    expect(before, greaterThan(500));

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(fixture.listRequests.length, greaterThan(requestCount));
    expect(
      find.textContaining('80 封已加载'),
      findsOneWidget,
      reason: 'A quiet first-page refresh must retain later loaded pages.',
    );
    expect(
      tester.state<ScrollableState>(_listScrollable).position.pixels,
      closeTo(before, 1),
    );
    await tester.scrollUntilVisible(_row(79), 500, scrollable: _listScrollable);
    await tester.pumpAndSettle();
    expect(_row(79), findsOneWidget);
    await _disposeMailbox(tester);
  });

  testWidgets(
    'repeated load-more taps and overlapping pages do not duplicate',
    (tester) async {
      final fixture = _Fixture();
      final secondPage = Completer<http.Response>();
      var secondPageRequests = 0;
      fixture.listResponse = (uri) {
        if (uri.queryParameters['cursor'] == 'page-2') {
          secondPageRequests++;
          return secondPage.future;
        }
        if (uri.queryParameters['cursor'] == 'page-3') {
          return _page([_message(79), _message(80)]);
        }
        return _page(List.generate(40, _message), cursor: 'page-2');
      };
      await _signIn(tester, fixture);
      await _reachLoadMore(tester);
      // Intentionally avoid a pump between taps, exercising the callback before
      // the button gets rebuilt into its disabled state.
      await tester.tap(find.text('加载更多'));
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      expect(secondPageRequests, 1);
      secondPage.complete(
        _page(
          List.generate(41, (index) => _message(index + 39)),
          cursor: 'page-3',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('80 封已加载'), findsOneWidget);
      await _reachLoadMore(tester);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.textContaining('81 封已加载'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      expect(secondPageRequests, 1);
      await _disposeMailbox(tester);
    },
  );

  testWidgets('compose defaults to the currently selected mailbox', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _signIn(tester, fixture);
    await _chooseBeta(tester);
    await tester.tap(find.text('写邮件'));
    await tester.pumpAndSettle();
    final accountField = find.descendant(
      of: find.byType(ComposeDialog),
      matching: find.byType(DropdownButtonFormField<String>),
    );
    expect(
      tester.widget<DropdownButtonFormField<String>>(accountField).initialValue,
      'beta',
    );
    await tester.tap(find.byTooltip('关闭写信窗口'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsNothing);
    expect(
      fixture.requests.where((r) => r.url.path.endsWith('/send')),
      isEmpty,
    );
    await _disposeMailbox(tester);
  });

  testWidgets('320px reader and compose remain usable without overflow', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _signIn(tester, fixture, size: const Size(320, 720));
    await tester.tap(_row(0));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic body 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('打开导航'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写邮件'));
    await tester.pumpAndSettle();
    expect(find.byType(ComposeDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭写信窗口'));
    await tester.pumpAndSettle();
    expect(find.byType(ComposeDialog), findsNothing);
    await _disposeMailbox(tester);
  });

  testWidgets('no-account connect CTA and compose both open account settings', (
    tester,
  ) async {
    final fixture = _Fixture(accounts: []);
    await _signIn(tester, fixture);
    expect(find.text('连接邮箱'), findsWidgets);
    await tester.tap(find.text('连接邮箱').first);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(find.byType(ComposeDialog), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写邮件'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);
    expect(find.byType(ComposeDialog), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(
      fixture.requests.where((r) => r.url.path.endsWith('/send')),
      isEmpty,
    );
    await _disposeMailbox(tester);
  });
}
