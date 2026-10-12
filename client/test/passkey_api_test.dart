import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/passkey_api.dart';
import 'package:harbor_mail/passkey_platform.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'passkey_test_fixtures.dart';

Matcher code(String value) =>
    isA<ApiException>().having((e) => e.code, 'code', value);
void main() {
  test(
    'canceled durable verification revokes returned orphan family before handover',
    () async {
      final verify = Completer<http.Response>();
      final started = Completer<void>();
      var revoked = 0;
      final now = DateTime.now().toUtc();
      final refresh = base64Url
          .encode(List<int>.filled(32, 9))
          .replaceAll('=', '');
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/device-session/logout')) {
            revoked++;
            expect(jsonDecode(r.body), {'refreshToken': refresh});
            return http.Response('', 204);
          }
          if (r.url.path.endsWith('/options')) {
            return passkeyJson(passkeyOptions());
          }
          started.complete();
          return verify.future;
        }),
      );
      final flow = PasskeyFlow(
        PasskeyApi(mail),
        authenticator: SyntheticPasskeyAuthenticator(),
      );
      final result = expectLater(
        flow.authenticate(rememberDevice: true),
        throwsA(code('PASSKEY_CANCELLED')),
      );
      await started.future;
      flow.cancel();
      verify.complete(
        passkeyJson({
          ...passkeySession(),
          'expiresAt': now.add(const Duration(minutes: 15)).toIso8601String(),
          'refreshToken': refresh,
          'deviceId': 'orphan-synthetic-family',
          'refreshExpiresAt': now
              .add(const Duration(days: 30))
              .toIso8601String(),
          'sessionExpiresAt': now
              .add(const Duration(days: 365))
              .toIso8601String(),
        }),
      );
      await result;
      expect(revoked, 1);
      expect(mail.token, isNull);
    },
  );

  test(
    'remembered passkey choice binds at options, verification cannot upgrade it',
    () async {
      final requests = <http.Request>[];
      final now = DateTime.now().toUtc();
      final durable = <String, dynamic>{
        ...passkeySession(),
        'expiresAt': now.add(const Duration(minutes: 15)).toIso8601String(),
        'refreshToken': base64Url
            .encode(List<int>.filled(32, 7))
            .replaceAll('=', ''),
        'refreshExpiresAt': now.add(const Duration(days: 30)).toIso8601String(),
        'sessionExpiresAt': now
            .add(const Duration(days: 365))
            .toIso8601String(),
        'deviceId': 'synthetic-family',
      };
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          requests.add(r);
          expect(r.headers['Authorization'], isNull);
          return passkeyJson(
            r.url.path.endsWith('/options') ? passkeyOptions() : durable,
          );
        }),
      );
      final session = await PasskeyFlow(
        PasskeyApi(mail),
        authenticator: SyntheticPasskeyAuthenticator(),
      ).authenticate(rememberDevice: true, deviceName: 'My Android');
      expect(jsonDecode(requests.first.body), {
        'rememberDevice': true,
        'deviceName': 'My Android',
      });
      expect((jsonDecode(requests.last.body) as Map).keys.toSet(), {
        'requestId',
        'credential',
      });
      expect(session.durable, isTrue);
      expect(session.deviceId, 'synthetic-family');
      expect(session.sessionResponse['refreshToken'], durable['refreshToken']);
      expect(mail.token, isNull);
      expect(
        () => PasskeySession.fromJson({...durable, 'refreshToken': 'bad'}),
        throwsA(code('INVALID_RESPONSE')),
      );
    },
  );

  test(
    'registration forwards standard options/credential to own server once',
    () async {
      final requests = <http.Request>[];
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          requests.add(r);
          expect(r.headers['Authorization'], 'Bearer owner-token');
          expect(r.followRedirects, isFalse);
          return passkeyJson(
            r.url.path.endsWith('/options')
                ? passkeyOptions(registration: true)
                : passkeyEntry(),
          );
        }),
      )..token = 'owner-token';
      final auth = SyntheticPasskeyAuthenticator();
      final result = await PasskeyFlow(
        PasskeyApi(mail),
        authenticator: auth,
      ).register(password: 'synthetic-password', name: '  Laptop  ');
      expect(result.id, 'synthetic-passkey');
      expect(auth.registerCalls, 1);
      expect(
        auth.receivedOptions!['authenticatorSelection']['userVerification'],
        'required',
      );
      expect(jsonDecode(requests[0].body), {
        'password': 'synthetic-password',
        'name': 'Laptop',
      });
      expect(jsonDecode(requests[1].body), {
        'requestId': 'synthetic-request',
        'credential': syntheticCredential(registration: true),
      });
      expect(mail.token, 'owner-token');
    },
  );

  test(
    'public authentication never sends bearer or installs returned token',
    () async {
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          expect(r.headers['Authorization'], isNull);
          return passkeyJson(
            r.url.path.endsWith('/options')
                ? passkeyOptions()
                : passkeySession(),
          );
        }),
      )..token = 'unrelated-token';
      final auth = SyntheticPasskeyAuthenticator();
      final result = await PasskeyFlow(
        PasskeyApi(mail),
        authenticator: auth,
      ).authenticate();
      expect(result.accessToken, 'synthetic-passkey-token');
      expect(auth.authenticateCalls, 1);
      expect(mail.token, 'unrelated-token');
    },
  );

  test('cancelled option response never reaches authenticator', () async {
    final pending = Completer<http.Response>();
    final mail = MailApi(
      base: 'https://mail.example.test/api/v1',
      client: MockClient((r) => pending.future),
    );
    final auth = SyntheticPasskeyAuthenticator();
    final flow = PasskeyFlow(PasskeyApi(mail), authenticator: auth);
    final future = flow.authenticate();
    final assertion = expectLater(future, throwsA(code('PASSKEY_CANCELLED')));
    flow.cancel();
    pending.complete(passkeyJson(passkeyOptions()));
    await assertion;
    expect(auth.authenticateCalls, 0);
  });

  test(
    'cancel during OS prompt prevents verification and repeated click is bounded',
    () async {
      var requests = 0;
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          requests++;
          return passkeyJson(passkeyOptions());
        }),
      );
      final auth = SyntheticPasskeyAuthenticator()..pending = Completer();
      final flow = PasskeyFlow(PasskeyApi(mail), authenticator: auth);
      final future = flow.authenticate();
      final assertion = expectLater(future, throwsA(code('PASSKEY_CANCELLED')));
      await Future<void>.delayed(Duration.zero);
      await expectLater(flow.authenticate(), throwsA(code('PASSKEY_BUSY')));
      flow.cancel();
      auth.pending!.complete(syntheticCredential());
      await assertion;
      expect(requests, 1);
    },
  );

  test(
    'changed owner session discards registration before verification',
    () async {
      var requests = 0;
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          requests++;
          return passkeyJson(passkeyOptions(registration: true));
        }),
      )..token = 'owner-token';
      final auth = SyntheticPasskeyAuthenticator()..pending = Completer();
      final flow = PasskeyFlow(PasskeyApi(mail), authenticator: auth);
      final future = flow.register(
        password: 'synthetic-password',
        name: 'Laptop',
      );
      final assertion = expectLater(future, throwsA(code('PASSKEY_CANCELLED')));
      await Future<void>.delayed(Duration.zero);
      mail.token = 'replacement-session';
      auth.pending!.complete(syntheticCredential(registration: true));
      await assertion;
      expect(requests, 1);
    },
  );

  test(
    'late verification after server/navigation change is discarded',
    () async {
      final verify = Completer<http.Response>();
      var current = true;
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient(
          (r) async => r.url.path.endsWith('/options')
              ? passkeyJson(passkeyOptions())
              : verify.future,
        ),
      );
      final flow = PasskeyFlow(
        PasskeyApi(mail),
        authenticator: SyntheticPasskeyAuthenticator(),
      );
      final future = flow.authenticate(isCurrent: () => current);
      final assertion = expectLater(future, throwsA(code('PASSKEY_CANCELLED')));
      await Future<void>.delayed(Duration.zero);
      current = false;
      verify.complete(passkeyJson(passkeySession()));
      await assertion;
      expect(mail.token, isNull);
    },
  );

  test(
    'uncertain verification failure does not retry or expose server content',
    () async {
      var verifyCalls = 0;
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/options')) {
            return passkeyJson(passkeyOptions());
          }
          verifyCalls++;
          throw Exception('secret-assertion');
        }),
      );
      final flow = PasskeyFlow(
        PasskeyApi(mail),
        authenticator: SyntheticPasskeyAuthenticator(),
      );
      await expectLater(flow.authenticate(), throwsA(code('NETWORK')));
      expect(verifyCalls, 1);
      expect(
        passkeyErrorMessage(Exception('secret-assertion')),
        isNot(contains('secret-assertion')),
      );
    },
  );

  test('UV downgrade rejected before OS call; unused extensions removed', () {
    final unsafe = passkeyOptions();
    unsafe['publicKey']['userVerification'] = 'preferred';
    expect(
      () => PasskeyOptions.fromJson(unsafe, registration: false),
      throwsA(code('INVALID_RESPONSE')),
    );
    final safe = passkeyOptions();
    safe['publicKey']['extensions'] = {
      'prf': {
        'eval': {'first': 'must-not-request'},
      },
    };
    expect(
      PasskeyOptions.fromJson(safe, registration: false).publicKey,
      isNot(contains('extensions')),
    );
  });

  test(
    'native malicious server cannot relay a different relying party challenge',
    () async {
      for (final registration in [false, true]) {
        final mail = MailApi(
          base: 'https://malicious.example.test/api/v1',
          client: MockClient(
            (r) async =>
                passkeyJson(passkeyOptions(registration: registration)),
          ),
        )..token = registration ? 'owner-token' : null;
        final auth = SyntheticPasskeyAuthenticator();
        final flow = PasskeyFlow(PasskeyApi(mail), authenticator: auth);
        await expectLater(
          registration
              ? flow.register(password: 'synthetic-password', name: 'Laptop')
              : flow.authenticate(),
          throwsA(code('PASSKEY_RP_MISMATCH')),
        );
        expect(auth.registerCalls + auth.authenticateCalls, 0);
      }
    },
  );

  test('registration requires resident key and none attestation', () {
    final unsafe = passkeyOptions(registration: true);
    unsafe['publicKey']['authenticatorSelection']['residentKey'] = 'preferred';
    expect(
      () => PasskeyOptions.fromJson(unsafe, registration: true),
      throwsA(code('INVALID_RESPONSE')),
    );
  });

  test(
    'delete requires explicit password and exact captured session',
    () async {
      var calls = 0;
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) async {
          calls++;
          expect(r.url.path, '/api/v1/auth/passkeys/synthetic-passkey/delete');
          expect(jsonDecode(r.body), {'password': 'synthetic-password'});
          return http.Response('', 204);
        }),
      )..token = 'owner-token';
      final api = PasskeyApi(mail);
      await expectLater(
        api.delete('synthetic-passkey', password: '', bearer: 'owner-token'),
        throwsA(code('INVALID_REQUEST')),
      );
      await expectLater(
        api.delete('synthetic-passkey', password: 'x', bearer: 'old-token'),
        throwsA(code('UNAUTHORIZED')),
      );
      expect(calls, 0);
      await api.delete(
        'synthetic-passkey',
        password: 'synthetic-password',
        bearer: 'owner-token',
      );
      expect(calls, 1);
    },
  );

  test(
    'password403 retains current session, late401 cannot erase newer session',
    () async {
      final pending = Completer<http.Response>();
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient((r) => pending.future),
      )..token = 'first';
      final future = PasskeyApi(mail).list(bearer: 'first');
      final assertion = expectLater(future, throwsA(code('HTTP_401')));
      mail.token = 'newer';
      pending.complete(passkeyJson({}, 401));
      await assertion;
      expect(mail.token, 'newer');
      final retained = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient(
          (r) async => passkeyJson({
            'error': {
              'code': 'REAUTHENTICATION_FAILED',
              'message': 'sensitive',
            },
          }, 403),
        ),
      )..token = 'owner';
      await expectLater(
        PasskeyApi(retained).delete('id', password: 'wrong', bearer: 'owner'),
        throwsA(code('REAUTHENTICATION_FAILED')),
      );
      expect(retained.token, 'owner');
    },
  );

  test(
    'redirect rejected; expired or overlong login permission rejected',
    () async {
      final mail = MailApi(
        base: 'https://mail.example.test/api/v1',
        client: MockClient(
          (r) async => http.Response(
            '',
            302,
            headers: {'location': 'https://evil.test/'},
          ),
        ),
      );
      await expectLater(
        PasskeyApi(mail).authenticationOptions(),
        throwsA(code('API_REDIRECT')),
      );
      final data = passkeySession()..['expiresAt'] = '2000-01-01T00:00:00Z';
      expect(
        () => PasskeySession.fromJson(data),
        throwsA(code('INVALID_RESPONSE')),
      );
      expect(
        () =>
            PasskeySession.fromJson(passkeySession()..['permission'] = 'OTHER'),
        throwsA(code('INVALID_RESPONSE')),
      );
    },
  );
}
