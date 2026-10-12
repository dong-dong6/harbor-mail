import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/local_unlock.dart';
import 'package:harbor_mail/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _SyntheticUnlock implements LocalUnlockAuthenticator {
  int prompts = 0;
  LocalUnlockResult result = LocalUnlockResult.verified;
  Completer<LocalUnlockResult>? pending;
  @override
  bool get supported => true;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<LocalUnlockResult> authenticate() async {
    prompts++;
    return pending?.future ?? result;
  }

  @override
  Future<void> cancel() async {}
}

Future<
  ({LocalUnlockController unlock, MailboxState mailbox, Future<void> resumed})
>
_mount(
  WidgetTester tester, {
  bool waitForResume = true,
  _SyntheticUnlock? authenticator,
  Future<http.Response>? Function(http.Request)? intercept,
}) async {
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = MailApi(
    base: 'https://mail.invalid/api/v1',
    client: MockClient((request) async {
      final intercepted = intercept?.call(request);
      if (intercepted != null) return intercepted;
      return http.Response(
        jsonEncode(
          request.url.path.endsWith('/settings/capabilities')
              ? {'demoMode': true, 'features': <String, dynamic>{}}
              : {'items': [], 'hasMore': false},
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  )..token = 'synthetic-session';
  final unlock = LocalUnlockController(
    authenticator: authenticator ?? _SyntheticUnlock(),
  );
  addTearDown(unlock.dispose);
  await tester.pumpWidget(MailApp(api: api, unlockController: unlock));
  final mailbox = tester.state<MailboxState>(find.byType(Mailbox));
  final resumed = mailbox.resumeAuthenticatedSession();
  if (waitForResume) {
    await tester.pumpAndSettle();
    await resumed;
  } else {
    await tester.pump();
  }
  return (unlock: unlock, mailbox: mailbox, resumed: resumed);
}

Future<void> _openDeviceSecurity(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('local-session-lock')));
  await tester.pumpAndSettle();
  expect(find.text('设备安全与登录'), findsOneWidget);
  final toggle = find.byKey(const Key('device-lock-switch'));
  await tester.ensureVisible(toggle);
  expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
}

Future<void> _enableThroughSettings(WidgetTester tester) async {
  await _openDeviceSecurity(tester);
  await tester.tap(find.byKey(const Key('device-lock-switch')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first local-lock enable waits for login bootstrap and polling', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var held = false;
    final fixture = await _mount(
      tester,
      waitForResume: false,
      intercept: (request) {
        if (!held && request.url.path.endsWith('/accounts')) {
          held = true;
          return pending.future;
        }
        return null;
      },
    );
    expect(fixture.mailbox.loading, isTrue);
    expect(fixture.mailbox.applyingRoute, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('local-session-lock')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('local-session-lock')));
    await tester.pump();
    expect(fixture.unlock.enabled, isFalse);

    pending.complete(http.Response('{"items":[]}', 200));
    await tester.pumpAndSettle();
    await fixture.resumed;
    expect(fixture.mailbox.loading, isFalse);
    expect(fixture.mailbox.applyingRoute, isFalse);
    expect(fixture.mailbox.poll?.isActive, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('local-session-lock')))
          .onPressed,
      isNotNull,
    );
    await _openDeviceSecurity(tester);
    expect(fixture.unlock.enabled, isFalse);
    await tester.tap(find.byKey(const Key('device-lock-switch')));
    await tester.pumpAndSettle();
    expect(fixture.unlock.enabled, isTrue);
    expect(fixture.mailbox.poll?.isActive, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('settings defaults off and commits on only after OS success', (
    tester,
  ) async {
    final auth = _SyntheticUnlock()..pending = Completer<LocalUnlockResult>();
    final fixture = await _mount(tester, authenticator: auth);
    expect(fixture.unlock.enabled, isFalse);
    expect(auth.prompts, 0);
    await _openDeviceSecurity(tester);
    expect(auth.prompts, 0);
    expect(find.textContaining('默认关闭。手动开启'), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-lock-switch')));
    await tester.pump();
    expect(auth.prompts, 1);
    expect(fixture.unlock.enabled, isFalse);
    expect(fixture.unlock.busy, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('device-lock-switch'), skipOffstage: false),
          )
          .value,
      isFalse,
    );
    auth.pending!.complete(LocalUnlockResult.verified);
    await tester.pumpAndSettle();
    expect(fixture.unlock.enabled, isTrue);
    expect(fixture.unlock.locked, isFalse);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('device-lock-switch')))
          .value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'canceling first settings toggle leaves switch off and session usable',
    (tester) async {
      final auth = _SyntheticUnlock()..result = LocalUnlockResult.canceled;
      final fixture = await _mount(tester, authenticator: auth);
      await _enableThroughSettings(tester);
      expect(auth.prompts, 1);
      expect(fixture.unlock.enabled, isFalse);
      expect(fixture.unlock.locked, isFalse);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('device-lock-switch')))
            .value,
        isFalse,
      );
      expect(find.textContaining('已取消验证，本地锁定未开启'), findsOneWidget);
      expect(fixture.mailbox.logged, isTrue);
      expect(fixture.mailbox.api.token, 'synthetic-session');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('enabled local lock remains manually usable during refresh IO', (
    tester,
  ) async {
    Completer<http.Response>? pending;
    final fixture = await _mount(
      tester,
      intercept: (request) =>
          request.url.path.endsWith('/accounts') ? pending?.future : null,
    );
    await fixture.unlock.enable();
    await tester.pumpAndSettle();
    pending = Completer<http.Response>();
    final refresh = fixture.mailbox.refresh();
    await tester.pump();
    expect(fixture.mailbox.loading, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('local-session-lock')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('local-session-lock')));
    await tester.pumpAndSettle();
    expect(fixture.unlock.locked, isTrue);
    expect(find.text('泊信已锁定'), findsOneWidget);
    pending.complete(http.Response('{"items":[]}', 200));
    await tester.pump();
    await refresh;
    expect(fixture.unlock.locked, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local-lock disable control requires explicit confirmation', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    expect(find.byKey(const Key('disable-local-session-lock')), findsNothing);
    await _enableThroughSettings(tester);
    expect(fixture.unlock.enabled, isTrue);
    expect(fixture.unlock.locked, isFalse);
    expect(find.byTooltip('关闭本次会话的本机锁'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('disable-local-session-lock')));
    await tester.pumpAndSettle();
    expect(fixture.unlock.enabled, isTrue);
    expect(find.textContaining('返回应用无需再次进行系统验证'), findsOneWidget);
    await tester.tap(find.text('继续保护'));
    await tester.pumpAndSettle();
    expect(fixture.unlock.enabled, isTrue);

    await tester.tap(find.byKey(const Key('disable-local-session-lock')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认关闭本机锁'));
    await tester.pumpAndSettle();
    expect(fixture.unlock.enabled, isFalse);
    expect(fixture.mailbox.logged, isTrue);
    expect(fixture.mailbox.api.token, 'synthetic-session');
    expect(find.byKey(const Key('disable-local-session-lock')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('confirmation opened before lock cannot disable after unlock', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await fixture.unlock.enable();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('disable-local-session-lock')));
    await tester.pumpAndSettle();

    fixture.unlock.lock();
    await tester.pumpAndSettle();
    expect(find.text('确认关闭本机锁'), findsNothing);
    expect(find.byKey(const Key('disable-local-session-lock')), findsNothing);
    await fixture.unlock.unlock();
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认关闭本机锁'));
    await tester.pumpAndSettle();
    expect(fixture.unlock.enabled, isTrue);
    expect(fixture.mailbox.api.token, 'synthetic-session');

    // The user may explicitly start and confirm a new operation after unlock.
    await tester.tap(find.byKey(const Key('disable-local-session-lock')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认关闭本机锁'));
    await tester.pumpAndSettle();
    expect(fixture.unlock.enabled, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
