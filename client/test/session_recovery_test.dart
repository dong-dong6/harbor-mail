import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:harbor_mail/session_recovery.dart';
import 'package:harbor_mail/session_vault.dart';

class SyntheticVault implements SessionVault {
  late VaultResult result;
  int restores = 0, clears = 0, cancels = 0;
  bool clearFails = false;
  Completer<VaultResult>? pending;
  @override
  bool get supported => true;
  @override
  Future<VaultResult> status() async => result;
  @override
  Future<VaultResult> save(
    SavedSession session, {
    required bool explicitOptIn,
  }) async => const VaultResult(VaultState.failed);
  @override
  Future<VaultResult> restore({
    required ServerProfile profile,
    required String accountId,
  }) async {
    restores++;
    return pending == null ? result : pending!.future;
  }

  @override
  Future<VaultResult> clear() async {
    clears++;
    return VaultResult(clearFails ? VaultState.failed : VaultState.empty);
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }
}

void main() {
  var now = DateTime.utc(2026, 10, 12, 10);
  final profile = ServerProfile.parse('https://mail.example/api/v1');
  late SyntheticVault vault;
  late SessionRecovery recovery;
  late SavedSession session;
  setUp(() {
    now = DateTime.utc(2026, 10, 12, 10);
    session = SavedSession(
      token: 'synthetic-session-not-a-real-token',
      profile: profile,
      accountId: 'owner',
      expiresAt: now.add(const Duration(hours: 2)),
    );
    vault = SyntheticVault()
      ..result = VaultResult(VaultState.restored, session: session);
    recovery = SessionRecovery(vault, now: () => now);
  });

  test('restore exposes nothing until server validation succeeds', () async {
    final validation = Completer<SessionValidation>();
    var done = false;
    final future = recovery
        .restoreAndValidate(
          profile: profile,
          accountId: 'owner',
          validate: (candidate) {
            expect(candidate.expiresAt, session.expiresAt);
            return validation.future;
          },
        )
        .then((result) {
          done = true;
          return result;
        });
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    expect(recovery.busy, isTrue);
    validation.complete(SessionValidation.accepted);
    final result = await future;
    expect(result.session, same(session));
    expect(result.state, VaultState.restored);
    expect(vault.clears, 0);
  });

  test('rejected/revoked server session clears encrypted record', () async {
    final result = await recovery.restoreAndValidate(
      profile: profile,
      accountId: 'owner',
      validate: (_) async => SessionValidation.rejected,
    );
    expect(result.session, isNull);
    expect(result.state, VaultState.invalidated);
    expect(vault.clears, 1);
  });

  test(
    'failed removal is reported without exposing a rejected session',
    () async {
      vault.clearFails = true;
      final result = await recovery.restoreAndValidate(
        profile: profile,
        accountId: 'owner',
        validate: (_) async => SessionValidation.rejected,
      );
      expect(result.session, isNull);
      expect(result.state, VaultState.failed);
      expect(vault.clears, 1);
    },
  );

  test(
    'offline/timeout never exposes mail and permits later OS-authenticated retry',
    () async {
      final result = await recovery.restoreAndValidate(
        profile: profile,
        accountId: 'owner',
        validate: (_) async => throw TimeoutException('synthetic offline'),
      );
      expect(result.session, isNull);
      expect(result.validation, SessionValidation.retryable);
      expect(vault.clears, 0);
      expect(recovery.busy, isFalse);
      expect(
        (await recovery.restoreAndValidate(
          profile: profile,
          accountId: 'owner',
          validate: (_) async => SessionValidation.accepted,
        )).session,
        same(session),
      );
      expect(vault.restores, 2);
    },
  );

  test(
    'cancel during decryption rejects late token without server request',
    () async {
      vault.pending = Completer<VaultResult>();
      var validated = false;
      final future = recovery.restoreAndValidate(
        profile: profile,
        accountId: 'owner',
        validate: (_) async {
          validated = true;
          return SessionValidation.accepted;
        },
      );
      await recovery.cancel();
      vault.pending!.complete(vault.result);
      final result = await future;
      expect(result.state, VaultState.canceled);
      expect(result.session, isNull);
      expect(validated, isFalse);
      expect(vault.cancels, 1);
    },
  );

  test('cancel during server validation rejects late acceptance', () async {
    final validation = Completer<SessionValidation>();
    final future = recovery.restoreAndValidate(
      profile: profile,
      accountId: 'owner',
      validate: (_) => validation.future,
    );
    await Future<void>.delayed(Duration.zero);
    await recovery.cancel();
    validation.complete(SessionValidation.accepted);
    final result = await future;
    expect(result.state, VaultState.canceled);
    expect(result.session, isNull);
  });

  test('duplicate restore requests cannot cause parallel prompts', () async {
    vault.pending = Completer<VaultResult>();
    final first = recovery.restoreAndValidate(
      profile: profile,
      accountId: 'owner',
      validate: (_) async => SessionValidation.accepted,
    );
    final duplicate = await recovery.restoreAndValidate(
      profile: profile,
      accountId: 'owner',
      validate: (_) async => SessionValidation.accepted,
    );
    expect(duplicate.state, VaultState.busy);
    expect(vault.restores, 1);
    vault.pending!.complete(vault.result);
    await first;
  });

  test(
    'expiry while validating clears without renewing original timestamp',
    () async {
      final result = await recovery.restoreAndValidate(
        profile: profile,
        accountId: 'owner',
        validate: (_) async {
          now = session.expiresAt;
          return SessionValidation.accepted;
        },
      );
      expect(result.state, VaultState.expired);
      expect(result.session, isNull);
      expect(vault.clears, 1);
    },
  );

  test('wrong origin/owner stops before server request', () async {
    var validated = false;
    final result = await recovery.restoreAndValidate(
      profile: profile,
      accountId: 'other',
      validate: (_) async {
        validated = true;
        return SessionValidation.accepted;
      },
    );
    expect(result.state, VaultState.mismatch);
    expect(validated, isFalse);
    expect(vault.clears, 1);
  });

  test(
    'canceled native prompt leaves encrypted session and never validates',
    () async {
      vault.result = const VaultResult(VaultState.canceled);
      var validated = false;
      final result = await recovery.restoreAndValidate(
        profile: profile,
        accountId: 'owner',
        validate: (_) async {
          validated = true;
          return SessionValidation.accepted;
        },
      );
      expect(result.state, VaultState.canceled);
      expect(validated, isFalse);
      expect(vault.clears, 0);
    },
  );
}
