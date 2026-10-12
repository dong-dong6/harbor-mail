import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:harbor_mail/session_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.harbor.mail/session_vault');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime.utc(2026, 10, 12, 10);
  final profile = ServerProfile.parse('https://mail.example/api/v1');
  final expiry = now.add(const Duration(hours: 2));
  SavedSession session({
    DateTime? expiresAt,
    ServerProfile? server,
    String? owner,
    String? token,
  }) => SavedSession(
    token: token ?? 'synthetic-session-not-a-real-token',
    profile: server ?? profile,
    accountId: owner ?? 'owner',
    expiresAt: expiresAt ?? expiry,
  );
  Map<String, Object> metadata({
    String? base,
    String? owner,
    DateTime? expiresAt,
  }) => {
    'apiBase': base ?? profile.apiBase,
    'accountId': owner ?? 'owner',
    'expiresAt': (expiresAt ?? expiry).millisecondsSinceEpoch,
  };
  final calls = <MethodCall>[];
  dynamic response;
  late PlatformSessionVault vault;

  setUp(() {
    calls.clear();
    response = {'status': 'empty'};
    vault = PlatformSessionVault(
      channel: channel,
      supported: true,
      now: () => now,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'no explicit opt-in never invokes native storage or OS enrollment',
    () async {
      expect(
        (await vault.save(session(), explicitOptIn: false)).state,
        VaultState.canceled,
      );
      expect(calls, isEmpty);
    },
  );

  test('unsupported platforms never touch native persistence', () async {
    final other = PlatformSessionVault(supported: false, now: () => now);
    expect((await other.status()).state, VaultState.unavailable);
    expect(
      (await other.save(session(), explicitOptIn: true)).state,
      VaultState.unavailable,
    );
    expect(
      (await other.restore(profile: profile, accountId: 'owner')).state,
      VaultState.unavailable,
    );
    await other.clear();
    await other.cancel();
    expect(calls, isEmpty);
  });

  test(
    'save waits for native OS-bound operation and preserves original expiry',
    () async {
      final authenticated = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return authenticated.future;
      });
      var completed = false;
      final pending = vault.save(session(), explicitOptIn: true).then((result) {
        completed = true;
        return result;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(calls.single.method, 'save');
      expect(calls.single.arguments, {
        ...metadata(),
        'token': 'synthetic-session-not-a-real-token',
        'explicitOptIn': true,
      });
      authenticated.complete({'status': 'saved', 'metadata': metadata()});
      final result = await pending;
      expect(result.state, VaultState.saved);
      expect(result.metadata!.expiresAt, expiry);
      expect(result.session, isNull);
    },
  );

  test(
    'expired, over-eight-hour, malformed and HTTP sessions cannot be saved',
    () async {
      for (final invalid in [
        session(expiresAt: now),
        session(expiresAt: now.subtract(const Duration(seconds: 1))),
        session(expiresAt: now.add(const Duration(hours: 8, milliseconds: 1))),
      ]) {
        expect(
          (await vault.save(invalid, explicitOptIn: true)).state,
          VaultState.expired,
        );
      }
      for (final invalid in [
        session(owner: ''),
        session(owner: 'owner\nother'),
        session(token: 'x'),
        session(token: 'synthetic token with spaces'),
        session(
          server: ServerProfile.parse(
            'http://localhost/api/v1',
            allowLoopbackHttp: true,
          ),
        ),
      ]) {
        expect(
          (await vault.save(invalid, explicitOptIn: true)).state,
          VaultState.corrupt,
        );
      }
      expect(calls, isEmpty);
    },
  );

  test('status exposes discovery metadata without exposing bearer', () async {
    response = {
      'status': 'saved',
      'metadata': metadata(),
      'token': 'synthetic-session-not-a-real-token',
    };
    final result = await vault.status();
    expect(result.state, VaultState.saved);
    expect(result.metadata!.accountId, 'owner');
    expect(result.session, isNull);
  });

  test('only an authenticated restore response may return a token', () async {
    response = {
      'status': 'restored',
      'metadata': metadata(),
      'token': 'synthetic-session-not-a-real-token',
    };
    expect((await vault.status()).state, VaultState.corrupt);
    final result = await vault.restore(profile: profile, accountId: 'owner');
    expect(result.state, VaultState.restored);
    expect(result.session!.token, 'synthetic-session-not-a-real-token');
    expect(result.session!.expiresAt, expiry);
    expect(result.session.toString(), isNot(contains('synthetic')));
  });

  test(
    'restore rejects returned origin or owner mismatch and clears vault',
    () async {
      for (final wrong in [
        metadata(base: 'https://other.example/api/v1'),
        metadata(owner: 'other'),
      ]) {
        calls.clear();
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'clear'
              ? {'status': 'empty'}
              : {
                  'status': 'restored',
                  'metadata': wrong,
                  'token': 'synthetic-session-not-a-real-token',
                };
        });
        final result = await vault.restore(
          profile: profile,
          accountId: 'owner',
        );
        expect(result.state, VaultState.mismatch);
        expect(result.session, isNull);
        expect(calls.map((call) => call.method), ['restore', 'clear']);
      }
    },
  );

  test('every native failure status fails closed without a token', () async {
    for (final state in [
      VaultState.canceled,
      VaultState.unavailable,
      VaultState.lockedOut,
      VaultState.expired,
      VaultState.invalidated,
      VaultState.corrupt,
      VaultState.mismatch,
      VaultState.busy,
      VaultState.failed,
    ]) {
      response = {
        'status': state.name,
        'token': 'synthetic-session-not-a-real-token',
      };
      final result = await vault.restore(profile: profile, accountId: 'owner');
      expect(result.state, state);
      expect(result.session, isNull);
    }
  });

  test(
    'malformed metadata and overlong lifetime never yield a token',
    () async {
      for (final bad in [
        {...metadata(), 'expiresAt': expiry.toIso8601String()},
        {...metadata(), 'accountId': ''},
        {...metadata(), 'apiBase': 'http://mail.example/api/v1'},
      ]) {
        response = {
          'status': 'restored',
          'metadata': bad,
          'token': 'synthetic-session-not-a-real-token',
        };
        expect(
          (await vault.restore(profile: profile, accountId: 'owner')).state,
          VaultState.corrupt,
        );
      }
      response = {
        'status': 'restored',
        'metadata': metadata(expiresAt: now.add(const Duration(hours: 9))),
        'token': 'synthetic-session-not-a-real-token',
      };
      expect(
        (await vault.restore(profile: profile, accountId: 'owner')).state,
        VaultState.expired,
      );
    },
  );

  test(
    'clear failure is surfaced and cancel has no plaintext arguments',
    () async {
      response = {'status': 'failed'};
      expect((await vault.clear()).state, VaultState.failed);
      await vault.cancel();
      expect(calls.map((call) => call.method), ['clear', 'cancel']);
      expect(calls.every((call) => call.arguments == null), isTrue);
    },
  );

  test('missing plugin and platform errors fail safely', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException(),
    );
    expect((await vault.status()).state, VaultState.unavailable);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'synthetic-error'),
    );
    expect((await vault.status()).state, VaultState.failed);
  });
}
