import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';
import 'package:harbor_mail/local_unlock.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class VerifiedAuthenticator implements LocalUnlockAuthenticator {
  @override
  bool get supported => true;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<LocalUnlockResult> authenticate() async => LocalUnlockResult.verified;
  @override
  Future<void> cancel() async {}
}

void main() {
  late LocalUnlockController unlock;
  late MailApi api;
  late MailboxState state;
  Future<void> setup(
    WidgetTester tester, {
    Future<http.Response> Function(http.Request)? intercept,
  }) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    unlock = LocalUnlockController(authenticator: VerifiedAuthenticator());
    api = MailApi(
      base: 'https://mail.example/api/v1',
      client: MockClient((r) async {
        if (intercept != null &&
            (r.url.path.contains('/drafts') ||
                r.url.path.contains('/attachments') ||
                r.url.path.endsWith('/logout'))) {
          return intercept(r);
        }
        final Object data = r.url.path.endsWith('/settings/capabilities')
            ? {'demoMode': true, 'features': <String, dynamic>{}}
            : {'items': [], 'hasMore': false, 'coverage': 'DEMO'};
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(MailApp(api: api, unlockController: unlock));
    state = tester.state<MailboxState>(find.byType(Mailbox));
    api.token = 'synthetic-session';
    final login = state.resumeAuthenticatedSession();
    await tester.pumpAndSettle();
    await login;
    addTearDown(unlock.dispose);
  }

  testWidgets(
    'child clearing current bearer immediately ends mailbox session',
    (tester) async {
      await setup(tester);
      expect(state.logged, isTrue);
      api.token = null;
      await tester.pumpAndSettle();
      expect(state.logged, isFalse);
      expect(unlock.hasSession, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final boundary in ['lock', 'logout']) {
    testWidgets('late attachment bytes cannot save after $boundary', (
      tester,
    ) async {
      final response = Completer<http.Response>();
      await setup(tester, intercept: (_) => response.future);
      if (boundary == 'lock') await unlock.enable();
      var saved = false;
      final pending = state.downloadAttachment(
        {'id': 'synthetic-id', 'fileName': 'private.txt'},
        save: (_, __) async {
          saved = true;
        },
      );
      await tester.pump();
      if (boundary == 'lock') {
        unlock.lock();
      } else {
        state.endSession();
      }
      response.complete(http.Response.bytes([1, 2, 3], 200));
      await pending;
      await tester.pumpAndSettle();
      expect(saved, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('late draft list never opens after session ends', (tester) async {
    final response = Completer<http.Response>();
    await setup(tester, intercept: (_) => response.future);
    final pending = state.showDrafts();
    await tester.pump();
    state.endSession();
    response.complete(
      http.Response(
        jsonEncode({
          'items': [
            {'id': 'private-draft', 'subject': 'PRIVATE DELAYED DRAFT'},
          ],
        }),
        200,
      ),
    );
    await pending;
    await tester.pumpAndSettle();
    expect(
      find.text('PRIVATE DELAYED DRAFT', skipOffstage: false),
      findsNothing,
    );
    expect(state.logged, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'logout removes an already mounted private modal before next session',
    (tester) async {
      await setup(tester);
      unawaited(
        showDialog<void>(
          context: state.context,
          builder: (_) => const AlertDialog(content: Text('PRIVATE OLD MODAL')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE OLD MODAL'), findsOneWidget);
      await unlock.enable();
      unlock.lock();
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE OLD MODAL'), findsNothing);
      state.endSession();
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE OLD MODAL', skipOffstage: false), findsNothing);
      api.token = 'synthetic-next-session';
      final login = state.resumeAuthenticatedSession();
      await tester.pumpAndSettle();
      await login;
      expect(find.text('PRIVATE OLD MODAL', skipOffstage: false), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
