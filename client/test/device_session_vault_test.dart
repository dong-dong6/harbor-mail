import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/device_session_vault.dart';
import 'package:harbor_mail/server_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.harbor.mail/device_session_vault');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final profile = ServerProfile.parse('https://mail.example/api/v1');
  final now = DateTime.utc(2026, 10, 12, 12);
  final idle = now.add(const Duration(days: 1));
  final absolute = now.add(const Duration(days: 90));
  const family = '00000000-0000-4000-8000-000000000001';
  const request = '00000000-0000-4000-8000-000000000002';
  final old = base64Url.encode(List.filled(32, 0)).replaceAll('=', '');
  final next = base64Url.encode(List.filled(32, 1)).replaceAll('=', '');
  final calls = <MethodCall>[];
  late PlatformDeviceSessionVault vault;
  dynamic response;
  Map<String, Object> metadata({
    String? accountId,
    String? familyId,
    String? apiBase,
    bool biometric = false,
    DateTime? idleAt,
    DateTime? absoluteAt,
  }) => {
    'apiBase': apiBase ?? profile.apiBase,
    'accountId': accountId ?? 'owner',
    'familyId': familyId ?? family,
    'idleExpiresAt': (idleAt ?? idle).millisecondsSinceEpoch,
    'absoluteExpiresAt': (absoluteAt ?? absolute).millisecondsSinceEpoch,
    'biometricEnabled': biometric,
  };
  Map<String, Object> unlocked({
    bool pending = false,
    Map<String, Object>? meta,
  }) => {
    'status': 'unlocked',
    'metadata': meta ?? metadata(),
    'refreshToken': old,
    if (pending)
      'pending': {'oldRefresh': old, 'nextRefresh': next, 'requestId': request},
  };
  DeviceSession session({String? refresh, DeviceRotation? pending}) =>
      DeviceSession(
        profile: profile,
        accountId: 'owner',
        familyId: family,
        refreshToken: refresh ?? old,
        idleExpiresAt: idle,
        absoluteExpiresAt: absolute,
        pending: pending,
      );
  setUp(() {
    calls.clear();
    response = {'status': 'empty'};
    vault = PlatformDeviceSessionVault(
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
    'remember device requires explicit opt in independently of biometric mode',
    () async {
      expect(
        (await vault.save(session(), explicitOptIn: false)).state,
        DeviceVaultState.canceled,
      );
      expect(
        (await vault.setBiometricEnabled(true, explicitOptIn: false)).state,
        DeviceVaultState.canceled,
      );
      expect(calls, isEmpty);
    },
  );
  test('unsupported platform never falls back to plaintext', () async {
    final other = PlatformDeviceSessionVault(supported: false);
    expect(
      (await other.save(session(), explicitOptIn: true)).state,
      DeviceVaultState.unavailable,
    );
    expect((await other.status()).state, DeviceVaultState.unavailable);
    await other.lock();
    await other.cancel();
    await other.clear();
    expect(calls, isEmpty);
  });
  test(
    'save passes only bound refresh and original expiry, no access credential',
    () async {
      response = {'status': 'saved', 'metadata': metadata()};
      expect(
        (await vault.save(session(), explicitOptIn: true)).isSuccess,
        isTrue,
      );
      final args = calls.single.arguments as Map;
      expect(args.keys.toSet(), {
        'apiBase',
        'accountId',
        'familyId',
        'refreshToken',
        'idleExpiresAt',
        'absoluteExpiresAt',
        'explicitOptIn',
      });
      expect(args['refreshToken'], old);
      expect(args['absoluteExpiresAt'], absolute.millisecondsSinceEpoch);
      expect(args.containsKey('biometricEnabled'), isFalse);
    },
  );
  test('no caller provided pending journal may be saved', () async {
    final pending = DeviceRotation(
      oldRefresh: old,
      nextRefresh: next,
      requestId: request,
    );
    expect(
      (await vault.save(session(pending: pending), explicitOptIn: true)).state,
      DeviceVaultState.corrupt,
    );
    expect(calls, isEmpty);
  });
  test(
    'native fresh successor creation must complete before begin returns',
    () async {
      final durable = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return durable.future;
      });
      var done = false;
      final pending = vault
          .beginRotation(profile: profile, accountId: 'owner', familyId: family)
          .then((v) {
            done = true;
            return v;
          });
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      durable.complete(unlocked(pending: true));
      final result = await pending;
      expect(result.session!.pending!.requestId, request);
      expect((calls.single.arguments as Map).keys.toSet(), {
        'apiBase',
        'accountId',
        'familyId',
      });
    },
  );
  test('repeated begin exposes same persisted tuple', () async {
    response = unlocked(pending: true);
    final a = await vault.beginRotation(
      profile: profile,
      accountId: 'owner',
      familyId: family,
    );
    final b = await vault.beginRotation(
      profile: profile,
      accountId: 'owner',
      familyId: family,
    );
    expect(a.session!.pending!.nextRefresh, b.session!.pending!.nextRefresh);
    expect(a.session!.pending!.requestId, b.session!.pending!.requestId);
  });
  test('commit passes exact confirmed tuple and expiries', () async {
    response = {
      'status': 'saved',
      'metadata': metadata(),
      'refreshToken': next,
    };
    final result = await vault.commitRotation(
      profile: profile,
      accountId: 'owner',
      familyId: family,
      requestId: request,
      nextRefresh: next,
      idleExpiresAt: idle,
      absoluteExpiresAt: absolute,
    );
    expect(result.session!.refreshToken, next);
    expect(calls.single.method, 'commitRotation');
    final args = calls.single.arguments as Map;
    expect(args['requestId'], request);
    expect(args['nextRefresh'], next);
    expect(args.containsKey('accessToken'), isFalse);
  });
  test(
    'expired old idle can recover lost response pending until fixed absolute expiry',
    () async {
      response = unlocked(
        pending: true,
        meta: metadata(idleAt: now.subtract(const Duration(seconds: 1))),
      );
      expect(
        (await vault.unlock(profile: profile, accountId: 'owner')).state,
        DeviceVaultState.unlocked,
      );
    },
  );
  test('absolute expiry boundary blocks disclosure', () async {
    response = unlocked(
      pending: true,
      meta: metadata(idleAt: now, absoluteAt: now),
    );
    final result = await vault.unlock(profile: profile, accountId: 'owner');
    expect(result.state, DeviceVaultState.expired);
    expect(result.session, isNull);
  });
  test('status returns metadata but never refresh secrets', () async {
    response = {'status': 'saved', 'metadata': metadata(biometric: true)};
    final result = await vault.status();
    expect(result.metadata!.biometricEnabled, isTrue);
    expect(result.session, isNull);
    response = {'status': 'saved', 'metadata': metadata(), 'refreshToken': old};
    expect((await vault.status()).state, DeviceVaultState.corrupt);
  });
  test(
    'cross account result locks native cache and never exposes session',
    () async {
      response = unlocked(meta: metadata(accountId: 'other'));
      final result = await vault.unlock(profile: profile, accountId: 'owner');
      expect(result.state, DeviceVaultState.mismatch);
      expect(result.session, isNull);
      expect(calls.map((c) => c.method), ['unlock', 'lock']);
    },
  );
  test('cross family begin result is refused', () async {
    response = unlocked(pending: true, meta: metadata(familyId: request));
    expect(
      (await vault.beginRotation(
        profile: profile,
        accountId: 'owner',
        familyId: family,
      )).state,
      DeviceVaultState.mismatch,
    );
  });
  test('cross origin unlock result is refused', () async {
    response = unlocked(
      meta: metadata(apiBase: 'https://other.example/api/v1'),
    );
    expect(
      (await vault.unlock(profile: profile, accountId: 'owner')).state,
      DeviceVaultState.mismatch,
    );
  });
  test('malformed or self-referential pending is refused', () async {
    for (final bad in [
      {'oldRefresh': next, 'nextRefresh': old, 'requestId': request},
      {'oldRefresh': old, 'nextRefresh': old, 'requestId': request},
      {'oldRefresh': old, 'nextRefresh': next, 'requestId': 'not-uuid'},
    ]) {
      response = {...unlocked(), 'pending': bad};
      expect(
        (await vault.beginRotation(
          profile: profile,
          accountId: 'owner',
          familyId: family,
        )).state,
        DeviceVaultState.corrupt,
      );
    }
  });
  test('successful begin must include pending', () async {
    response = unlocked();
    expect(
      (await vault.beginRotation(
        profile: profile,
        accountId: 'owner',
        familyId: family,
      )).state,
      DeviceVaultState.corrupt,
    );
  });
  test('invalid tokens and request ids never invoke native mutators', () async {
    for (final token in ['abc', '$old=', '${old.substring(0, 42)}B']) {
      expect(
        (await vault.save(session(refresh: token), explicitOptIn: true)).state,
        DeviceVaultState.corrupt,
      );
    }
    expect(
      (await vault.commitRotation(
        profile: profile,
        accountId: 'owner',
        familyId: family,
        requestId: 'bad',
        nextRefresh: next,
        idleExpiresAt: idle,
        absoluteExpiresAt: absolute,
      )).state,
      DeviceVaultState.corrupt,
    );
    expect(calls, isEmpty);
  });
  test('OS cancellation cannot be mistaken for enabling protection', () async {
    response = {'status': 'canceled'};
    final result = await vault.setBiometricEnabled(true, explicitOptIn: true);
    expect(result.isSuccess, isFalse);
    expect(result.metadata, isNull);
    expect(calls.single.arguments, {'enabled': true, 'explicitOptIn': true});
  });
  test(
    'clear reports storage failure without pretending logged-out deletion worked',
    () async {
      response = {'status': 'failed'};
      expect((await vault.clear()).state, DeviceVaultState.failed);
    },
  );
  test('lock and cancel invoke native cache purge boundaries', () async {
    response = {'status': 'locked'};
    await vault.lock();
    await vault.cancel();
    expect(calls.map((c) => c.method), ['lock', 'cancel']);
  });
  test(
    'successful result is restricted to the expected method and payload',
    () async {
      response = {'status': 'saved', 'metadata': metadata()};
      expect(
        (await vault.unlock(profile: profile, accountId: 'owner')).state,
        DeviceVaultState.corrupt,
      );
      expect(
        (await vault.commitRotation(
          profile: profile,
          accountId: 'owner',
          familyId: family,
          requestId: request,
          nextRefresh: next,
          idleExpiresAt: idle,
          absoluteExpiresAt: absolute,
        )).state,
        DeviceVaultState.corrupt,
      );
      response = unlocked();
      expect(
        (await vault.save(session(), explicitOptIn: true)).state,
        DeviceVaultState.corrupt,
      );
    },
  );
  test('platform errors redact credentials', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'broken', message: old);
    });
    final result = await vault.status();
    expect(result.state, DeviceVaultState.failed);
    expect(result.toString(), isNot(contains(old)));
    expect(session().toString(), isNot(contains(old)));
    expect(
      DeviceRotation(
        oldRefresh: old,
        nextRefresh: next,
        requestId: request,
      ).toString(),
      isNot(contains(next)),
    );
  });
}
