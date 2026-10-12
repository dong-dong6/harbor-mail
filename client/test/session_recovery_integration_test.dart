import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:harbor_mail/session_vault.dart';
import 'package:harbor_mail/passkey_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeVault implements SessionVault {
  FakeVault(this.saved);
  SavedSession? saved;
  VaultState restoreState = VaultState.restored;
  Completer<VaultResult>? pending;
  int clears = 0, saves = 0, restores = 0;
  VaultState clearState = VaultState.empty;
  Completer<VaultResult>? pendingClear;
  bool? explicit;
  @override
  bool get supported => true;
  @override
  Future<VaultStatus> status() async => saved == null
      ? const VaultResult(VaultState.empty)
      : VaultResult(VaultState.saved, metadata: saved!.metadata);
  @override
  Future<VaultResult> clear() async {
    clears++;
    if (pendingClear != null) return pendingClear!.future;
    if (clearState == VaultState.empty) saved = null;
    return VaultResult(clearState);
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<VaultResult> save(
    SavedSession session, {
    required bool explicitOptIn,
  }) async {
    saves++;
    explicit = explicitOptIn;
    saved = session;
    return VaultResult(VaultState.saved, metadata: session.metadata);
  }

  @override
  Future<VaultResult> restore({
    required ServerProfile profile,
    required String accountId,
  }) async {
    restores++;
    return pending?.future ??
        VaultResult(
          restoreState,
          session: restoreState == VaultState.restored ? saved : null,
          metadata: saved?.metadata,
        );
  }
}

void main() {
  late FakeVault vault;
  late SavedSession original;
  late MailboxState state;
  late List<http.Request> requests;
  late MailApi initial;
  Future<void> setup(
    WidgetTester t, {
    Future<http.Response> Function(http.Request)? intercept,
  }) async {
    t.view.physicalSize = const Size(1440, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    original = SavedSession(
      token: 'synthetic-opaque-bearer-only',
      profile: ServerProfile.parse('https://mail.example/api/v1'),
      accountId: 'owner',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
    );
    vault = FakeVault(original);
    requests = [];
    http.Client client() => MockClient((r) async {
      requests.add(r);
      if (intercept != null) return intercept(r);
      return http.Response(
        jsonEncode(
          r.url.path.endsWith('/settings/capabilities')
              ? {'features': {}}
              : {'items': [], 'hasMore': false},
        ),
        200,
      );
    });
    initial = MailApi(base: original.profile.apiBase, client: client());
    await t.pumpWidget(
      MailApp(
        api: initial,
        sessionVault: vault,
        recoveryApiFactory: (base) => MailApi(base: base, client: client()),
      ),
    );
    await t.pumpAndSettle();
    state = t.state<MailboxState>(find.byType(Mailbox));
  }

  testWidgets(
    'cold start exposes no mailbox requests; OS cancel stays signed out',
    (t) async {
      await setup(t);
      expect(requests, isEmpty);
      expect(state.logged, isFalse);
      expect(vault.saves, 0);
      vault.restoreState = VaultState.canceled;
      await state.restoreSavedSession();
      await t.pumpAndSettle();
      expect(requests, isEmpty);
      expect(state.logged, isFalse);
      expect(vault.saved, isNotNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'restoration validates bound server before mailbox and preserves original expiry',
    (t) async {
      final validation = Completer<http.Response>();
      var calls = 0;
      await setup(
        t,
        intercept: (r) async {
          if (++calls == 1) return validation.future;
          return http.Response(
            jsonEncode(
              r.url.path.endsWith('/settings/capabilities')
                  ? {'features': {}}
                  : {'items': [], 'hasMore': false},
            ),
            200,
          );
        },
      );
      final restore = state.restoreSavedSession();
      await t.pump();
      expect(requests.length, 1);
      expect(state.logged, isFalse);
      expect(
        requests.single.url.toString(),
        'https://mail.example/api/v1/accounts',
      );
      expect(
        requests.single.headers['Authorization'],
        'Bearer ${original.token}',
      );
      validation.complete(http.Response('{"items":[]}', 200));
      await t.pumpAndSettle();
      await restore;
      expect(state.logged, isTrue);
      expect(state.api.sessionExpiresAt, original.expiresAt);
      expect(vault.saves, 0);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'revoked session clears encrypted record and never opens mailbox',
    (t) async {
      await setup(
        t,
        intercept: (_) async => http.Response(
          '{"error":{"code":"UNAUTHORIZED","message":"revoked"}}',
          401,
        ),
      );
      await state.restoreSavedSession();
      await t.pumpAndSettle();
      expect(state.logged, isFalse);
      expect(vault.saved, isNull);
      expect(requests.length, 1);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'network failure does not pretend authentication or delete retryable encrypted record',
    (t) async {
      await setup(
        t,
        intercept: (_) async => throw http.ClientException('offline'),
      );
      await state.restoreSavedSession();
      await t.pumpAndSettle();
      expect(state.logged, isFalse);
      expect(vault.saved, isNotNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('late OS restoration cannot revive discarded login', (t) async {
    await setup(t);
    vault.pending = Completer<VaultResult>();
    final restore = state.restoreSavedSession();
    await t.pump();
    await state.discardSavedSession();
    vault.pending!.complete(
      VaultResult(
        VaultState.restored,
        session: original,
        metadata: original.metadata,
      ),
    );
    await restore;
    await t.pumpAndSettle();
    expect(state.logged, isFalse);
    expect(requests, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'explicit save keeps exact original expiry; logout clears saved record',
    (t) async {
      await setup(t);
      await state.discardSavedSession();
      initial.token = original.token;
      initial.sessionExpiresAt = original.expiresAt;
      initial.sessionAccount = 'owner';
      final login = state.resumeAuthenticatedSession();
      await t.pumpAndSettle();
      await login;
      expect(vault.saves, 0);
      await state.setSavedSession(true);
      await t.pumpAndSettle();
      expect(vault.explicit, isTrue);
      expect(vault.saved!.expiresAt, original.expiresAt);
      state.endSession();
      await t.pumpAndSettle();
      expect(vault.saved, isNull);
      expect(state.logged, isFalse);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'failed clear remains visible and never claims saved record was deleted',
    (t) async {
      await setup(t);
      vault.clearState = VaultState.failed;
      expect(await state.discardSavedSession(), isFalse);
      await t.pumpAndSettle();
      expect(vault.saved, isNotNull);
      expect(state.vaultClearFailed, isTrue);
      expect(state.savedSessionMetadata, isNotNull);
      expect(state.error, contains('未能删除'));
      await state.restoreSavedSession();
      expect(vault.restores, 0);
      expect(requests, isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'server edit while passkey accept awaits clearing discards old result',
    (t) async {
      await setup(t);
      vault.pendingClear = Completer<VaultResult>();
      final pending = state.acceptPasskeySession(
        initial,
        PasskeySession(
          accessToken: original.token,
          expiresAt: original.expiresAt,
          accountName: 'owner',
        ),
      );
      await t.pump();
      state.serverAddress.text = 'https://other.example/api/v1';
      vault.pendingClear!.complete(const VaultResult(VaultState.empty));
      await pending;
      await t.pumpAndSettle();
      expect(state.logged, isFalse);
      expect(initial.token, isNull);
      expect(requests, isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('background during server validation never opens mailbox', (
    t,
  ) async {
    final response = Completer<http.Response>();
    await setup(t, intercept: (_) => response.future);
    final pending = state.restoreSavedSession();
    await t.pump();
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    response.complete(http.Response('{"items":[]}', 200));
    await pending;
    await t.pumpAndSettle();
    expect(state.logged, isFalse);
    expect(vault.saved, isNotNull);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await t.pump();
    expect(state.logged, isFalse);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
