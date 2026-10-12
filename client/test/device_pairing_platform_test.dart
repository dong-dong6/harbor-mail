import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/device_pairing_api.dart';
import 'package:harbor_mail/device_scanner.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const pairingId = '00000000-0000-4000-8000-000000000123';
const secret = 'synthetic_claim_secret_012345678901234567890123';
const server = 'https://mail.example.test/api/v1';
final pairingExpiry = DateTime.now().toUtc().add(const Duration(minutes: 2));

Map<String, dynamic> qrMap() => {
      'type': 'harbor-mail-device-pairing',
      'version': 1,
      'serverUrl': server,
      'pairingId': pairingId,
      'secret': secret,
    };

PairingQr qr() => PairingQr.parse(jsonEncode(qrMap()));

Map<String, dynamic> snapshot([String state = 'CLAIMED']) => {
      'pairingId': pairingId,
      'state': state,
      'confirmationCode': '042719',
      'expiresAt': pairingExpiry.toIso8601String(),
      'accountName': 'synthetic-owner',
      'permission': 'OWNER_FULL_ACCESS',
    };

Map<String, dynamic> redeemed() => {
      'accessToken': 'synthetic-device-token',
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 7))
          .toIso8601String(),
      'deviceId': 'synthetic-device',
      'accountName': 'synthetic-owner',
      'permission': 'OWNER_FULL_ACCESS',
    };

http.Response jsonResponse(Object object, [int status = 200]) =>
    http.Response(jsonEncode(object), status,
        headers: {'content-type': 'application/json'});

Matcher errorCode(String code) =>
    isA<ApiException>().having((e) => e.code, 'code', code);

void main() {
  group('strict runtime server profile', () {
    test('supports normalized TLS host, private deployments and explicit ports',
        () {
      expect(
          ServerProfile.parse('https://MAIL.example.test:443/api/v1').apiBase,
          server);
      expect(ServerProfile.parse('https://192.168.1.42:8443/api/v1').origin,
          'https://192.168.1.42:8443');
      expect(ServerProfile.parse('https://mail.internal/api/v1').apiBase,
          'https://mail.internal/api/v1');
      expect(ServerProfile.parse('https://[::1]:8443/api/v1').origin,
          'https://[::1]:8443');
    });

    test('HTTP loopback requires explicit opt-in', () {
      for (final host in ['localhost', '127.0.0.1', '[::1]']) {
        final address = 'http://$host:8080/api/v1';
        expect(() => ServerProfile.parse(address), throwsFormatException);
        expect(ServerProfile.parse(address, allowLoopbackHttp: true).apiBase,
            address);
      }
      expect(
          () => ServerProfile.parse('http://192.168.1.42/api/v1',
              allowLoopbackHttp: true),
          throwsFormatException);
    });

    for (final value in [
      '/api/v1',
      'https://mail.example.test',
      'https://mail.example.test/api/v1/',
      'https://mail.example.test/x/../api/v1',
      'https://mail.example.test/%61pi/v1',
      'https://user:pass@mail.example.test/api/v1',
      'https://@mail.example.test/api/v1',
      'https://mail.example.test/api/v1?token=secret',
      'https://mail.example.test/api/v1?',
      'https://mail.example.test/api/v1#fragment',
      'https://mail.example.test/api/v1#',
      'https://mail.example.test:0/api/v1',
      'https://mail.example.test:65536/api/v1',
      'https://mail.example.test:0443/api/v1',
      'https://mail.example.test:/api/v1',
      'https://mail.example.test\\@evil.test/api/v1',
      'https://mail.example.test./api/v1',
      'https://127.1/api/v1',
      'https://0177.0.0.1/api/v1',
      'https://0x7f000001/api/v1',
      'https://2130706433/api/v1',
      'https://999.0.0.1/api/v1',
      ' https://mail.example.test/api/v1',
      'https://mail.example.test/api/v1\n',
      'https://máil.example.test/api/v1',
    ]) {
      test('rejects ambiguous destination $value', () {
        expect(() => ServerProfile.parse(value), throwsFormatException);
      });
    }
  });

  group('strict QR schema', () {
    test('parses typed payload without exposing secret in debug output', () {
      final parsed = qr();
      expect(parsed.profile.apiBase, server);
      expect(parsed.pairingId, pairingId);
      expect(parsed.secret, secret);
      expect(parsed.toString(), isNot(contains(secret)));
    });
    for (final replacement in [
      {'version': '1'},
      {'version': 1.0},
      {'version': 2},
      {'type': 'other'},
      {'serverUrl': null},
      {'pairingId': 'a'},
      {'secret': 'short'},
      {'secret': '$secret='},
      {'accountName': 'untrusted'},
    ]) {
      test('rejects malformed schema $replacement', () {
        expect(() => PairingQr.parse(jsonEncode({...qrMap(), ...replacement})),
            throwsFormatException);
      });
    }
    test('rejects missing, duplicate, nested and oversized payloads', () {
      expect(() => PairingQr.parse(jsonEncode(qrMap()..remove('secret'))),
          throwsFormatException);
      final raw = jsonEncode(qrMap());
      expect(
          () => PairingQr.parse(
              '${raw.substring(0, raw.length - 1)},"version":1}'),
          throwsFormatException);
      expect(
          () => PairingQr.parse(jsonEncode([qrMap()])), throwsFormatException);
      expect(() => PairingQr.parse(' ' * 4097), throwsFormatException);
    });
  });

  group('anonymous proof-bound transport', () {
    test(
        'generates S256 proof, passes no bearer or URL secret, hands off independent API',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return jsonResponse(request.url.path.endsWith('/claim')
            ? snapshot()
            : request.url.path.endsWith('/poll')
                ? snapshot('APPROVED')
                : redeemed());
      });
      final api = DevicePairingApi(profile: qr().profile, client: client);
      final claimed = await api.claim(qr(), deviceName: 'Synthetic phone');
      expect(claimed.confirmationCode, '042719');
      await api.poll();
      final result = await api.redeem();
      final claimBody = jsonDecode(requests[0].body) as Map;
      final pollBody = jsonDecode(requests[1].body) as Map;
      final redeemBody = jsonDecode(requests[2].body) as Map;
      final verifier = pollBody['codeVerifier'] as String;
      expect(verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(
          claimBody['codeChallenge'],
          base64Url
              .encode(sha256.convert(ascii.encode(verifier)).bytes)
              .replaceAll('=', ''));
      expect(claimBody.containsKey('codeVerifier'), false);
      expect(redeemBody, pollBody);
      for (final request in requests) {
        expect(request.method, 'POST');
        expect(request.url.origin, 'https://mail.example.test');
        expect(request.url.query, isEmpty);
        expect(request.url.fragment, isEmpty);
        expect(request.headers.containsKey('authorization'), false);
        expect(request.followRedirects, false);
        expect(request.maxRedirects, 0);
      }
      expect(result.api.base, server);
      expect(result.accessToken, 'synthetic-device-token');
      api.dispose();
      expect(result.api.token, 'synthetic-device-token');
      result.api.dispose();
      expect(result.api.token, isNull);
    });

    test('fresh attempts produce distinct verifiers', () async {
      final challenges = <String>{};
      for (var i = 0; i < 4; i++) {
        final api = DevicePairingApi(
            profile: qr().profile,
            client: MockClient((r) async {
              challenges.add(jsonDecode(r.body)['codeChallenge']);
              return jsonResponse(snapshot());
            }));
        await api.claim(qr(), deviceName: 'Synthetic');
        api.dispose();
      }
      expect(challenges.length, 4);
    });

    test('rejects cross-profile claim before I/O', () async {
      var called = false;
      final api = DevicePairingApi(
          profile: ServerProfile.parse('https://other.test/api/v1'),
          client: MockClient((_) async {
            called = true;
            return jsonResponse(snapshot());
          }));
      await expectLater(api.claim(qr(), deviceName: 'Synthetic'),
          throwsA(errorCode('INVALID_PAIRING')));
      expect(called, false);
      api.dispose();
    });

    for (final status in [301, 302, 303, 307, 308]) {
      test('rejects HTTP $status redirects before decoding', () async {
        final api = DevicePairingApi(
            profile: qr().profile,
            client: MockClient((r) async {
              expect(r.followRedirects, false);
              return http.Response('', status,
                  headers: {'location': 'https://other.test/collect'});
            }));
        await expectLater(api.claim(qr(), deviceName: 'Synthetic'),
            throwsA(errorCode('PAIRING_REDIRECT')));
        api.dispose();
      });
    }

    test('cancelling an in-flight claim discards its result', () async {
      final response = Completer<http.Response>();
      final api = DevicePairingApi(
          profile: qr().profile, client: MockClient((_) => response.future));
      final claim = api.claim(qr(), deviceName: 'Synthetic');
      final check = expectLater(claim, throwsA(errorCode('PAIRING_CANCELLED')));
      api.cancel();
      response.complete(jsonResponse(snapshot()));
      await check;
      await expectLater(api.poll(), throwsA(errorCode('PAIRING_CANCELLED')));
      api.dispose();
    });

    test(
        'cancelling in-flight redemption never produces an authenticated result',
        () async {
      final response = Completer<http.Response>();
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((r) async {
            if (r.url.path.endsWith('/redeem')) return response.future;
            return jsonResponse(snapshot(
                r.url.path.endsWith('/poll') ? 'APPROVED' : 'CLAIMED'));
          }));
      await api.claim(qr(), deviceName: 'Synthetic');
      await api.poll();
      final redeem = api.redeem();
      final check =
          expectLater(redeem, throwsA(errorCode('PAIRING_CANCELLED')));
      api.cancel();
      response.complete(jsonResponse(redeemed()));
      await check;
      api.dispose();
    });

    test('never retries uncertain redemption', () async {
      var redeemCount = 0;
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((r) async {
            if (r.url.path.endsWith('/redeem')) {
              redeemCount++;
              throw http.ClientException('synthetic connection loss');
            }
            return jsonResponse(snapshot(
                r.url.path.endsWith('/poll') ? 'APPROVED' : 'CLAIMED'));
          }));
      await api.claim(qr(), deviceName: 'Synthetic');
      await api.poll();
      await expectLater(api.redeem(), throwsA(errorCode('NETWORK')));
      await expectLater(api.redeem(), throwsA(errorCode('INVALID_PAIRING')));
      expect(redeemCount, 1);
      api.dispose();
    });

    test(
        'polls are throttled at two seconds and approval is required for redeem',
        () async {
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((r) async => jsonResponse(snapshot())));
      await api.claim(qr(), deviceName: 'Synthetic');
      await expectLater(
          api.redeem(), throwsA(errorCode('PAIRING_NOT_APPROVED')));
      await api.poll();
      await expectLater(api.poll(), throwsA(errorCode('POLL_TOO_FAST')));
      api.dispose();
    });

    test('terminal rejection drops proof and cannot redeem', () async {
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((r) async => jsonResponse(
              r.url.path.endsWith('/claim')
                  ? snapshot()
                  : (snapshot('REJECTED')..remove('confirmationCode')))));
      await api.claim(qr(), deviceName: 'Synthetic');
      expect((await api.poll()).isTerminal, true);
      await expectLater(api.redeem(), throwsA(errorCode('INVALID_PAIRING')));
      api.dispose();
    });

    test('rejects wrong permission and mismatched confirmation code', () async {
      final invalid = snapshot('APPROVED')..['confirmationCode'] = '999999';
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((r) async => jsonResponse(
              r.url.path.endsWith('/claim') ? snapshot() : invalid)));
      await api.claim(qr(), deviceName: 'Synthetic');
      await expectLater(api.poll(), throwsA(errorCode('INVALID_RESPONSE')));
      expect(
          () => PairingSnapshot.fromJson(snapshot()..['permission'] = 'OTHER'),
          throwsA(errorCode('INVALID_RESPONSE')));
      api.dispose();
    });

    test('bounded response and arbitrary server errors do not echo secrets',
        () async {
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((r) async => http.Response('x' * 16385, 200)));
      await expectLater(api.claim(qr(), deviceName: 'Synthetic'),
          throwsA(errorCode('INVALID_RESPONSE')));
      api.dispose();
      final errorApi = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((r) async => jsonResponse({
                'error': {'code': secret, 'message': secret}
              }, 400)));
      await expectLater(
          errorApi.claim(qr(), deviceName: 'Synthetic'),
          throwsA(isA<ApiException>().having(
              (e) => e.toString(), 'safe message', isNot(contains(secret)))));
      errorApi.dispose();
    });
  });

  test('continuous trickle is cancelled at whole-response deadline', () async {
    var cancelled = false;
    final controller = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final client = _StreamingClient(controller.stream);
    final api = DevicePairingApi(profile: qr().profile, client: client);
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!controller.isClosed) controller.add([32]);
    });
    final check = expectLater(api.claim(qr(), deviceName: 'Synthetic'),
        throwsA(errorCode('NETWORK')));
    await check;
    expect(cancelled, true);
    expect(client.closed, true);
    timer.cancel();
    await controller.close();
    api.dispose();
  });

  test(
      'server clock skew is tolerated and local access is capped at eight hours',
      () async {
    for (final skew in [const Duration(seconds: 5), const Duration(hours: 1)]) {
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/redeem')) {
              return jsonResponse(redeemed()
                ..['expiresAt'] = DateTime.now()
                    .toUtc()
                    .add(const Duration(hours: 8))
                    .add(skew)
                    .toIso8601String());
            }
            return jsonResponse(snapshot(
                request.url.path.endsWith('/poll') ? 'APPROVED' : 'CLAIMED'));
          }));
      await api.claim(qr(), deviceName: 'Synthetic');
      await api.poll();
      if (skew.inSeconds == 5) {
        final result = await api.redeem();
        expect(
            result.expiresAt
                .isAfter(DateTime.now().add(const Duration(hours: 8))),
            false);
        result.api.dispose();
      } else {
        await expectLater(api.redeem(), throwsA(errorCode('INVALID_RESPONSE')));
      }
      api.dispose();
    }
  });

  test('rejects expired or far-future claim lifetimes', () async {
    for (final expiry in [
      DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      DateTime.now().toUtc().add(const Duration(hours: 1)),
    ]) {
      final api = DevicePairingApi(
          profile: qr().profile,
          client: MockClient((_) async => jsonResponse(
              snapshot()..['expiresAt'] = expiry.toIso8601String())));
      await expectLater(api.claim(qr(), deviceName: 'Synthetic'),
          throwsA(errorCode('INVALID_RESPONSE')));
      api.dispose();
    }
  });

  testWidgets('unsupported scanner gracefully falls back without camera access',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    expect(supportsDeviceScanner, false);
    await tester.pumpWidget(const MaterialApp(home: DeviceScannerPage()));
    expect(find.textContaining('此平台暂不支持相机扫描'), findsOneWidget);
    expect(find.text('返回并粘贴配对内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.stream);
  final Stream<List<int>> stream;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200);
  @override
  void close() {
    closed = true;
  }
}
