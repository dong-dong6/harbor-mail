import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/device_session.dart';
import 'package:harbor_mail/device_session_vault.dart';
import 'package:harbor_mail/passkey_api.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String secret(int byte) =>
    base64Url.encode(List<int>.filled(32, byte)).replaceAll('=', '');
Matcher failure(String code) =>
    throwsA(isA<ApiException>().having((e) => e.code, 'code', code));

class FakeVault implements DeviceSessionVault {
  DeviceSession? stored;
  bool failBegin = false,
      failCommit = false,
      failClear = false,
      failSave = false;
  bool biometric = false;
  int begins = 0, commits = 0, clears = 0, locks = 0, saves = 0;
  Completer<void>? saveGate, clearGate;
  @override
  bool get supported => true;
  DeviceSessionMetadata? get metadata {
    final s = stored;
    return s == null
        ? null
        : DeviceSessionMetadata(
            profile: s.profile,
            accountId: s.accountId,
            familyId: s.familyId,
            idleExpiresAt: s.idleExpiresAt,
            absoluteExpiresAt: s.absoluteExpiresAt,
            biometricEnabled: biometric,
          );
  }

  DeviceVaultResult result(DeviceVaultState state) =>
      DeviceVaultResult(state, metadata: metadata, session: stored);
  @override
  Future<DeviceVaultResult> status() async =>
      result(stored == null ? DeviceVaultState.empty : DeviceVaultState.saved);
  @override
  Future<DeviceVaultResult> save(
    DeviceSession session, {
    required bool explicitOptIn,
  }) async {
    saves++;
    if (saveGate != null) await saveGate!.future;
    if (!explicitOptIn) return result(DeviceVaultState.canceled);
    stored = session;
    return result(failSave ? DeviceVaultState.failed : DeviceVaultState.saved);
  }

  @override
  Future<DeviceVaultResult> unlock({
    required ServerProfile profile,
    required String accountId,
  }) async {
    if (stored?.profile != profile || stored?.accountId != accountId) {
      return result(DeviceVaultState.mismatch);
    }
    return result(DeviceVaultState.unlocked);
  }

  @override
  Future<DeviceVaultResult> beginRotation({
    required ServerProfile profile,
    required String accountId,
    required String familyId,
  }) async {
    begins++;
    if (failBegin) return result(DeviceVaultState.failed);
    final s = stored!;
    stored = DeviceSession(
      profile: s.profile,
      accountId: s.accountId,
      familyId: s.familyId,
      refreshToken: s.refreshToken,
      idleExpiresAt: s.idleExpiresAt,
      absoluteExpiresAt: s.absoluteExpiresAt,
      pending:
          s.pending ??
          DeviceRotation(
            oldRefresh: s.refreshToken,
            nextRefresh: secret(begins + 20),
            requestId:
                '00000000-0000-4000-8000-${begins.toString().padLeft(12, '0')}',
          ),
    );
    return result(DeviceVaultState.saved);
  }

  @override
  Future<DeviceVaultResult> commitRotation({
    required ServerProfile profile,
    required String accountId,
    required String familyId,
    required String requestId,
    required String nextRefresh,
    required DateTime idleExpiresAt,
    required DateTime absoluteExpiresAt,
  }) async {
    commits++;
    if (failCommit) return result(DeviceVaultState.failed);
    final s = stored!;
    expect(s.pending?.requestId, requestId);
    expect(s.pending?.nextRefresh, nextRefresh);
    stored = DeviceSession(
      profile: profile,
      accountId: accountId,
      familyId: familyId,
      refreshToken: nextRefresh,
      idleExpiresAt: idleExpiresAt,
      absoluteExpiresAt: absoluteExpiresAt,
    );
    return result(DeviceVaultState.saved);
  }

  @override
  Future<DeviceVaultResult> setBiometricEnabled(
    bool enabled, {
    required bool explicitOptIn,
  }) async {
    if (!explicitOptIn) return result(DeviceVaultState.canceled);
    biometric = enabled;
    return result(DeviceVaultState.saved);
  }

  @override
  Future<DeviceVaultResult> clear() async {
    clears++;
    if (clearGate != null) await clearGate!.future;
    if (failClear) return result(DeviceVaultState.failed);
    stored = null;
    return result(DeviceVaultState.empty);
  }

  @override
  Future<void> lock() async {
    locks++;
  }

  @override
  Future<void> cancel() async {}
}

class Fixture {
  Fixture() {
    api = MailApi(
      base: profile.apiBase,
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshes++;
          expect(request.headers['Authorization'], isNull);
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          // Proves write-before-send, including a pending tuple after restart.
          expect(body['refreshToken'], vault.stored?.pending?.oldRefresh);
          expect(body['nextRefreshToken'], vault.stored?.pending?.nextRefresh);
          expect(body['requestId'], vault.stored?.pending?.requestId);
          if (refreshHandler != null) return refreshHandler!(request);
          return success(request);
        }
        if (request.url.path.endsWith('/auth/device-session/logout')) {
          revocations++;
          return http.Response('', 204);
        }
        resources++;
        if (resourceHandler != null) return resourceHandler!(request);
        return http.Response('{"items":[]}', 200);
      }),
    );
    coordinator = makeCoordinator();
  }
  final profile = ServerProfile.parse('https://mail.invalid/api/v1');
  DateTime now = DateTime.utc(2030, 1, 1);
  final DateTime absolute = DateTime.utc(2031, 1, 1);
  final vault = FakeVault();
  late MailApi api;
  late DeviceSessionCoordinator coordinator;
  int refreshes = 0, resources = 0, revocations = 0;
  List<http.Request> requests = [];
  Future<http.Response> Function(http.Request)? refreshHandler, resourceHandler;
  DeviceSessionCoordinator makeCoordinator() => DeviceSessionCoordinator(
    api: api,
    vault: vault,
    profile: profile,
    now: () => now,
  );
  Map<String, dynamic> login({String? token, DateTime? idle}) => {
    'accessToken': 'access-initial-memory-only',
    'expiresAt': now.add(const Duration(minutes: 15)).toIso8601String(),
    'refreshToken': token ?? secret(1),
    'refreshExpiresAt': (idle ?? now.add(const Duration(days: 30)))
        .toIso8601String(),
    'sessionExpiresAt': absolute.toIso8601String(),
    'deviceId': 'family-one',
    'accountName': 'owner',
    'permission': 'OWNER_FULL_ACCESS',
  };
  Future<void> start({DateTime? idle}) =>
      coordinator.acceptLogin(login(idle: idle), explicitOptIn: true);
  http.Response success(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        ...login(token: body['nextRefreshToken']),
        'accessToken': 'fresh-access-$refreshes',
      }),
      200,
    );
  }

  http.Response rejected(String code, {int status = 401}) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': 'Synthetic rejection'},
    }),
    status,
  );
  void expireAccess() {
    now = now.add(const Duration(minutes: 16));
  }
}

void main() {
  test(
    'resume continuation cannot refresh a replacement same-account family',
    () async {
      final f = Fixture();
      await f.start();
      await f.coordinator.suspend();
      final old = f.vault.stored!;
      f.vault.stored = DeviceSession(
        profile: old.profile,
        accountId: old.accountId,
        familyId: 'replacement-family',
        refreshToken: secret(99),
        idleExpiresAt: old.idleExpiresAt,
        absoluteExpiresAt: old.absoluteExpiresAt,
      );
      await expectLater(
        f.coordinator.resume(expectedFamilyId: 'family-one'),
        failure('STALE_SESSION'),
      );
      expect(f.refreshes, 0);
      expect(f.vault.stored!.familyId, 'replacement-family');
      expect(f.api.token, isNull);
      expect(f.vault.clears, 0);
    },
  );

  test(
    'owned continuation resumes only the same family and dies after logout',
    () async {
      final f = Fixture();
      await f.start();
      final oldGuard = f.api.captureSessionGuard();
      await f.coordinator.suspend();
      await expectLater(
        f.api.request('GET', '/messages'),
        failure('APP_BACKGROUND'),
      );
      expect(f.refreshes, 0);
      expect(oldGuard(), isFalse);
      await f.coordinator.resume(expectedFamilyId: 'family-one');
      expect(f.refreshes, 1);
      expect(oldGuard(), isFalse);
      expect(f.api.captureSessionGuard()(), isTrue);
      await f.coordinator.logout();
      await expectLater(
        f.coordinator.resume(expectedFamilyId: 'family-one'),
        failure('STALE_SESSION'),
      );
    },
  );

  test(
    'passive polling never sends while locked or background and refuses redirects',
    () async {
      final f = Fixture();
      await f.start();
      f.resourceHandler = (_) async => http.Response(
        '',
        307,
        headers: {'location': 'https://other.invalid'},
      );
      await expectLater(
        f.api.requestPassive('/messages'),
        failure('API_REDIRECT'),
      );
      expect(f.requests.single.followRedirects, isFalse);
      await f.coordinator.suspend();
      await expectLater(
        f.api.requestPassive('/messages'),
        failure('PASSIVE_ACCESS_EXPIRED'),
      );
      expect(f.requests.length, 1);
      expect(f.refreshes, 0);
    },
  );

  test(
    'passive current revoked401 clears local grant without any refresh',
    () async {
      final f = Fixture();
      await f.start();
      f.resourceHandler = (_) async => f.rejected('UNAUTHORIZED');
      await expectLater(
        f.api.requestPassive('/messages'),
        failure('UNAUTHORIZED'),
      );
      expect(f.refreshes, 0);
      expect(f.vault.stored, isNull);
      expect(f.api.token, isNull);
    },
  );

  test(
    'old locked coordinator logout cannot revoke replacement same-account family',
    () async {
      final f = Fixture();
      await f.start();
      final old = f.coordinator;
      await old.suspend();
      f.coordinator = f.makeCoordinator();
      final replacement = f.login(token: secret(99))
        ..['deviceId'] = 'replacement-family';
      await f.coordinator.acceptLogin(replacement, explicitOptIn: true);
      await expectLater(old.logout(), failure('REMOTE_REVOKE_REQUIRED'));
      expect(f.revocations, 0);
      expect(f.vault.stored!.familyId, 'replacement-family');
      expect(f.api.token, 'access-initial-memory-only');
      expect(f.coordinator.durable, isTrue);
    },
  );

  test('passive polling never renews locally expired access', () async {
    final f = Fixture();
    await f.start();
    f.expireAccess();
    await expectLater(
      f.api.requestPassive('/messages'),
      failure('PASSIVE_ACCESS_EXPIRED'),
    );
    expect(f.requests, isEmpty);
    expect(f.vault.clears, 0);
    await f.api.request('GET', '/messages');
    expect(f.refreshes, 1);
    expect(f.resources, 1);
  });

  test(
    'passive typed401 preserves grant and forces refresh only on next explicit demand',
    () async {
      final f = Fixture();
      await f.start();
      f.resourceHandler = (_) async => f.rejected('ACCESS_EXPIRED');
      await expectLater(
        f.api.requestPassive('/messages'),
        failure('PASSIVE_ACCESS_EXPIRED'),
      );
      await expectLater(
        f.api.requestPassive('/messages'),
        failure('PASSIVE_ACCESS_EXPIRED'),
      );
      expect(f.refreshes, 0);
      expect(f.resources, 1);
      expect(f.vault.clears, 0);
      expect(f.api.token, 'access-initial-memory-only');
      f.resourceHandler = null;
      await f.api.request('GET', '/messages');
      expect(f.refreshes, 1);
      expect(f.resources, 2);
    },
  );

  test('logout revokes server family even when local deletion fails', () async {
    final f = Fixture();
    await f.start();
    f.vault.failClear = true;
    await expectLater(f.coordinator.logout(), failure('VAULT_CLEAR_FAILED'));
    expect(f.revocations, 1);
    expect(f.api.token, isNull);
    expect(f.vault.stored, isNotNull);
  });

  test(
    'failed initial save clears uncertain local record and revokes only new family',
    () async {
      final f = Fixture();
      f.vault.failSave = true;
      f.api.token = 'access-initial-memory-only';
      await expectLater(f.start(), failure('VAULT_SAVE_FAILED'));
      expect(f.api.token, isNull);
      expect(f.vault.stored, isNull);
      expect(f.revocations, 1);
    },
  );

  test('owner account names may contain ordinary internal spaces', () async {
    final f = Fixture();
    final login = f.login()..['accountName'] = 'Alice Bob';
    await f.coordinator.acceptLogin(login, explicitOptIn: true);
    expect(f.coordinator.metadata!.accountId, 'Alice Bob');
  });

  test(
    'passkey management instance survives same-family bearer rotation',
    () async {
      final f = Fixture();
      await f.start();
      final passkeys = PasskeyApi(f.api);
      final originalBearer = f.api.token!;
      f.expireAccess();
      await f.coordinator.ensureAccess();
      expect(await passkeys.list(bearer: originalBearer), isEmpty);
      expect(f.requests.last.headers['Authorization'], 'Bearer fresh-access-1');
      await f.coordinator.suspend();
      await expectLater(
        passkeys.list(bearer: originalBearer),
        failure('UNAUTHORIZED'),
      );
    },
  );

  test(
    '20 simultaneous expired-access demands share one journaled rotation',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      await Future.wait(
        List.generate(20, (_) => f.api.request('GET', '/messages')),
      );
      expect(f.refreshes, 1);
      expect(f.vault.begins, 1);
      expect(f.vault.commits, 1);
      expect(f.resources, 20);
      expect(f.api.token, 'fresh-access-1');
      expect(f.vault.stored!.pending, isNull);
      expect(f.vault.stored!.toString(), isNot(contains('access')));
    },
  );

  test(
    '20 concurrent typed pre-handler401s rotate once and each retry once',
    () async {
      final f = Fixture();
      await f.start();
      f.resourceHandler = (r) async =>
          r.headers['Authorization']!.contains('initial')
          ? f.rejected('ACCESS_EXPIRED')
          : http.Response('{}', 200);
      await Future.wait(
        List.generate(
          20,
          (_) => f.api.request(
            'POST',
            '/drafts/d/send',
            body: {'revision': 1},
            key: 'same-safe-key',
          ),
        ),
      );
      expect(f.refreshes, 1);
      expect(f.resources, 40);
      for (final r in f.requests.where((r) => r.url.path.endsWith('/send'))) {
        expect(r.headers['Idempotency-Key'], 'same-safe-key');
        expect(jsonDecode(r.body), {'revision': 1});
      }
    },
  );

  test('a second typed401 never creates a third request or rotation', () async {
    final f = Fixture();
    await f.start();
    f.resourceHandler = (_) async => f.rejected('ACCESS_EXPIRED');
    await expectLater(
      f.api.request('POST', '/drafts/d/send'),
      failure('ACCESS_EXPIRED'),
    );
    expect(f.resources, 2);
    expect(f.refreshes, 1);
    expect(f.vault.clears, 0);
    expect(f.api.token, isNull);
  });

  test(
    'post-handler untyped401 fails closed and never replays mutation',
    () async {
      final f = Fixture();
      await f.start();
      f.resourceHandler = (_) async => f.rejected('UNAUTHORIZED');
      await expectLater(
        f.api.request('POST', '/drafts/d/send'),
        failure('UNAUTHORIZED'),
      );
      expect(f.resources, 1);
      expect(f.refreshes, 0);
      expect(f.vault.stored, isNull);
      expect(f.api.token, isNull);
    },
  );

  test(
    'uncertain send network outcome never refreshes or resends mutation',
    () async {
      final f = Fixture();
      await f.start();
      f.resourceHandler = (_) async =>
          throw http.ClientException('lost response');
      await expectLater(
        f.api.request('POST', '/drafts/d/send'),
        failure('NETWORK'),
      );
      expect(f.resources, 1);
      expect(f.refreshes, 0);
      expect(f.vault.stored, isNotNull);
    },
  );

  test(
    'lost refresh response retains pending and retry reuses exact tuple',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      f.refreshHandler = (_) async =>
          throw http.ClientException('response lost');
      await expectLater(
        f.coordinator.ensureAccess(),
        failure('RECONNECT_REQUIRED'),
      );
      final first = f.requests.single.body;
      final pending = f.vault.stored!.pending;
      expect(pending, isNotNull);
      expect(f.vault.clears, 0);
      f.refreshHandler = null;
      await f.coordinator.ensureAccess();
      expect(f.requests.last.body, first);
      expect(f.vault.stored!.refreshToken, pending!.nextRefresh);
      expect(f.refreshes, 2);
    },
  );

  test(
    'process restart recovers same tuple even beyond cached old idle expiry',
    () async {
      final f = Fixture();
      await f.start(idle: f.now.add(const Duration(minutes: 20)));
      f.expireAccess();
      f.refreshHandler = (_) async =>
          throw http.ClientException('response lost');
      await expectLater(
        f.coordinator.ensureAccess(),
        failure('RECONNECT_REQUIRED'),
      );
      final first = f.requests.single.body;
      await f.coordinator.retire();
      f.now = f.now.add(const Duration(minutes: 10));
      f.coordinator = f.makeCoordinator();
      f.refreshHandler = null;
      await f.coordinator.restore(accountId: 'owner');
      expect(f.requests.last.body, first);
      expect(f.api.token, 'fresh-access-2');
      expect(f.vault.clears, 0);
    },
  );

  test('journal persistence failure blocks network refresh', () async {
    final f = Fixture();
    await f.start();
    f.expireAccess();
    f.vault.failBegin = true;
    await expectLater(
      f.coordinator.ensureAccess(),
      failure('VAULT_SAVE_FAILED'),
    );
    expect(f.refreshes, 0);
    expect(f.vault.stored, isNotNull);
  });

  test(
    'commit failure never installs access; next demand retries same journal',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      f.vault.failCommit = true;
      await expectLater(
        f.coordinator.ensureAccess(),
        failure('VAULT_SAVE_FAILED'),
      );
      expect(f.api.token, 'access-initial-memory-only');
      final first = f.requests.single.body;
      f.vault.failCommit = false;
      await f.coordinator.ensureAccess();
      expect(f.requests.last.body, first);
      expect(f.api.token, 'fresh-access-2');
    },
  );

  for (final code in [
    'INVALID_REFRESH',
    'INVALID_GRANT',
    'SESSION_REVOKED',
    'SESSION_EXPIRED',
    'REFRESH_REUSED',
  ]) {
    test('$code removes both persisted and memory credentials', () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      f.refreshHandler = (_) async => f.rejected(code);
      await expectLater(f.coordinator.ensureAccess(), failure(code));
      expect(f.api.token, isNull);
      expect(f.vault.stored, isNull);
      expect(f.coordinator.durable, isFalse);
    });
  }

  for (final code in ['STALE_ROTATION', 'INVALID_ROTATION']) {
    test(
      '$code retires only unrecoverable local journal without revoking family',
      () async {
        final f = Fixture();
        await f.start();
        f.expireAccess();
        f.refreshHandler = (_) async => f.rejected(code, status: 409);
        await expectLater(f.coordinator.ensureAccess(), failure(code));
        expect(f.refreshes, 1);
        expect(f.revocations, 0);
        expect(f.vault.stored, isNull);
        expect(f.api.token, isNull);
      },
    );
  }

  test(
    '429 honors server retry deadline and keeps same pending tuple',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      f.refreshHandler = (_) async => http.Response(
        jsonEncode({
          'error': {
            'code': 'RATE_LIMITED',
            'retryAfterSeconds': 120,
            'message': 'Wait',
          },
        }),
        429,
      );
      await expectLater(f.coordinator.ensureAccess(), failure('RATE_LIMITED'));
      final first = f.requests.single.body;
      await expectLater(f.coordinator.ensureAccess(), failure('RATE_LIMITED'));
      expect(f.refreshes, 1);
      expect(f.vault.stored!.pending, isNotNull);
      f.now = f.now.add(const Duration(seconds: 120));
      f.refreshHandler = null;
      await f.coordinator.ensureAccess();
      expect(f.refreshes, 2);
      expect(f.requests.last.body, first);
    },
  );

  test(
    'stable session guard survives rotation and fails after suspension',
    () async {
      final f = Fixture();
      await f.start();
      final current = f.api.captureSessionGuard();
      f.expireAccess();
      await f.coordinator.ensureAccess();
      expect(current(), isTrue);
      await f.coordinator.suspend();
      expect(current(), isFalse);
    },
  );

  test(
    'owned OS prompt background drops secrets and gates all network until resume',
    () async {
      final f = Fixture();
      await f.start();
      final epoch = f.coordinator.epoch;
      f.coordinator.pauseForAuthentication();
      expect(f.coordinator.epoch, epoch);
      expect(f.coordinator.locked, isTrue);
      expect(f.api.token, isNull);
      await expectLater(
        f.api.request('GET', '/messages'),
        failure('APP_BACKGROUND'),
      );
      f.coordinator.authenticationForeground();
      await expectLater(
        f.api.request('GET', '/messages'),
        failure('DEVICE_LOCKED'),
      );
      expect(f.requests, isEmpty);
      await f.coordinator.resume();
      expect(f.api.token, isNotNull);
    },
  );

  test(
    'ordinary idle and absolute expiry clear locally without renewal',
    () async {
      for (final absolute in [false, true]) {
        final f = Fixture();
        await f.start();
        f.now = absolute ? f.absolute : f.now.add(const Duration(days: 31));
        await expectLater(
          f.coordinator.ensureAccess(),
          failure('SESSION_EXPIRED'),
        );
        expect(f.refreshes, 0);
        expect(f.vault.stored, isNull);
      }
    },
  );

  test(
    'failed credential deletion is surfaced rather than claimed successful',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      f.vault.failClear = true;
      f.refreshHandler = (_) async => f.rejected('SESSION_REVOKED');
      await expectLater(
        f.coordinator.ensureAccess(),
        failure('VAULT_CLEAR_FAILED'),
      );
      expect(f.api.token, isNull);
      expect(f.vault.stored, isNotNull);
    },
  );

  test(
    'background demand is blocked and late refresh cannot repopulate secrets',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      final reply = Completer<http.Response>();
      final started = Completer<void>();
      f.refreshHandler = (_) {
        started.complete();
        return reply.future;
      };
      final work = f.coordinator.ensureAccess();
      final checked = expectLater(work, failure('STALE_SESSION'));
      await started.future;
      await f.coordinator.suspend();
      await expectLater(
        f.api.request('GET', '/messages'),
        failure('APP_BACKGROUND'),
      );
      reply.complete(f.success(f.requests.single));
      await checked;
      expect(f.api.token, isNull);
      expect(f.coordinator.locked, isTrue);
      expect(f.vault.stored!.pending, isNotNull);
      expect(f.resources, 0);
      f.refreshHandler = null;
      await f.coordinator.resume();
      expect(f.api.token, 'fresh-access-2');
    },
  );

  test(
    'delayed refresh after logout never resurrects deleted credentials',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      final reply = Completer<http.Response>();
      final started = Completer<void>();
      f.refreshHandler = (_) {
        started.complete();
        return reply.future;
      };
      final checked = expectLater(
        f.coordinator.ensureAccess(),
        failure('STALE_SESSION'),
      );
      await started.future;
      final response = f.success(f.requests.single);
      await f.coordinator.logout();
      reply.complete(response);
      await checked;
      expect(f.api.token, isNull);
      expect(f.vault.stored, isNull);
      expect(f.revocations, 1);
      expect(f.vault.commits, 0);
    },
  );

  test(
    'retiring for server/account switch rejects late refresh and preserves vault',
    () async {
      final f = Fixture();
      await f.start();
      f.expireAccess();
      final reply = Completer<http.Response>();
      final started = Completer<void>();
      f.refreshHandler = (_) {
        started.complete();
        return reply.future;
      };
      final checked = expectLater(
        f.coordinator.ensureAccess(),
        failure('STALE_SESSION'),
      );
      await started.future;
      final response = f.success(f.requests.single);
      await f.coordinator.retire();
      f.api.token = 'different-account-access';
      reply.complete(response);
      await checked;
      expect(f.api.token, 'different-account-access');
      expect(f.vault.commits, 0);
      expect(f.vault.stored!.pending, isNotNull);
    },
  );

  test('logout serializes deletion after a delayed initial save', () async {
    final f = Fixture();
    f.vault.saveGate = Completer<void>();
    final saving = expectLater(f.start(), failure('STALE_SESSION'));
    await Future<void>.delayed(Duration.zero);
    final logout = f.coordinator.logout(revokeRemote: false);
    f.vault.saveGate!.complete();
    await saving;
    await logout;
    expect(f.vault.stored, isNull);
    expect(f.api.token, isNull);
  });

  test(
    'delayed old clear callback cannot retire a newly accepted login',
    () async {
      final f = Fixture();
      await f.start();
      var callbacks = 0;
      f.api.onSessionCleared = () => callbacks++;
      f.vault.clearGate = Completer<void>();
      final rejection = f.coordinator.rejectAccess(
        requestBearer: f.api.token,
        code: 'UNAUTHORIZED',
      );
      await Future<void>.delayed(Duration.zero);
      final login = f.start();
      f.vault.clearGate!.complete();
      await rejection;
      await login;
      expect(callbacks, 0);
      expect(f.api.token, 'access-initial-memory-only');
      expect(f.vault.stored, isNotNull);
    },
  );

  test('mere clock movement causes no background keepalive traffic', () async {
    final f = Fixture();
    await f.start();
    f.expireAccess();
    await Future<void>.delayed(Duration.zero);
    expect(f.refreshes, 0);
    await f.coordinator.suspend();
    expect(f.refreshes, 0);
  });

  test('remember-device opt-out never writes durable credentials', () async {
    final f = Fixture();
    await expectLater(
      f.coordinator.acceptLogin(f.login(), explicitOptIn: false),
      failure('REMEMBER_DEVICE_REQUIRED'),
    );
    expect(f.vault.saves, 0);
    expect(f.refreshes, 0);
  });
}
