import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/local_unlock.dart';
import 'package:harbor_mail/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _SyntheticUnlock implements LocalUnlockAuthenticator {
  @override
  bool get supported => true;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<LocalUnlockResult> authenticate() async => LocalUnlockResult.verified;
  @override
  Future<void> cancel() async {}
}

Future<({LocalUnlockController unlock, MailboxState mailbox})> _mount(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = MailApi(
    base: 'https://mail.invalid/api/v1',
    client: MockClient(
      (request) async => http.Response(
        jsonEncode(
          request.url.path.endsWith('/settings/capabilities')
              ? {'demoMode': true, 'features': <String, dynamic>{}}
              : {'items': [], 'hasMore': false},
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ),
  )..token = 'synthetic-session';
  final unlock = LocalUnlockController(authenticator: _SyntheticUnlock());
  addTearDown(unlock.dispose);
  await tester.pumpWidget(MailApp(api: api, unlockController: unlock));
  final mailbox = tester.state<MailboxState>(find.byType(Mailbox));
  final resumed = mailbox.resumeAuthenticatedSession();
  await tester.pumpAndSettle();
  await resumed;
  return (unlock: unlock, mailbox: mailbox);
}

void main() {
  testWidgets('local-lock disable control requires explicit confirmation', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    expect(find.byKey(const Key('disable-local-session-lock')), findsNothing);
    await tester.tap(find.byKey(const Key('local-session-lock')));
    await tester.pumpAndSettle();
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
