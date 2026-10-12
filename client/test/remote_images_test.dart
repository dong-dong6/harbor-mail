import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final id = 'a' * 64;
  final id2 = 'b' * 64;
  const source = 'https://tracker.invalid/private';
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z/D/PwAG/gL+DHWJ3gAAAABJRU5ErkJggg==');
  http.Response manifest([bool two = false]) => http.Response(
      jsonEncode({
        'items': [
          {'id': id, 'source': source},
          if (two) {'id': id2, 'source': 'https://tracker.invalid/second'},
        ]
      }),
      200);

  test('manifest and raster bytes use bearer-authenticated own API only',
      () async {
    final calls = <http.Request>[];
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((request) async {
          calls.add(request);
          expect(request.headers['Authorization'], 'Bearer synthetic');
          expect(request.url.host, 'mail.invalid');
          expect(request.url.queryParameters['accountId'], 'account-1');
          if (calls.length == 1) return manifest();
          expect(request.followRedirects, isFalse);
          return http.Response.bytes(png, 200,
              headers: {'content-type': 'image/png'});
        }))
      ..token = 'synthetic';
    final images = await api.remoteImages('message-1', 'account-1');
    expect(calls.length, 2);
    expect(images[source], 'data:image/png;base64,${base64Encode(png)}');
    api.dispose();
  });
  test('missing authentication never makes a request', () async {
    var calls = 0;
    final api = MailApi(client: MockClient((_) async {
      calls++;
      return manifest();
    }));
    await expectLater(api.remoteImages('m', 'a'), throwsA(isA<ApiException>()));
    expect(calls, 0);
    api.dispose();
  });
  test('image401 clears session and stops batch without anonymous retries',
      () async {
    var calls = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? manifest(true)
              : http.Response('not even JSON', 401);
        }))
      ..token = 'synthetic';
    await expectLater(
        api.remoteImages('m', 'a'),
        throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHORIZED')));
    expect(api.token, isNull);
    expect(calls, 2);
    api.dispose();
  });
  test('failure redirect SVG and non-PNG bytes never fall back to origin',
      () async {
    for (final response in [
      http.Response('', 302, headers: {'location': source}),
      http.Response('<svg/>', 200, headers: {'content-type': 'image/svg+xml'}),
      http.Response('<html/>', 200, headers: {'content-type': 'image/png'}),
      http.Response('', 502)
    ]) {
      var calls = 0;
      final api = MailApi(
          base: 'https://mail.invalid/api/v1',
          client: MockClient((request) async {
            calls++;
            expect(request.url.host, 'mail.invalid');
            return calls == 1 ? manifest() : response;
          }))
        ..token = 'synthetic';
      expect(await api.remoteImages('m', 'a'), isEmpty);
      expect(calls, 2);
      api.dispose();
    }
  });
  test('body navigation cancellation stops remaining image requests', () async {
    var current = true, calls = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async {
          calls++;
          if (calls == 1) return manifest(true);
          current = false;
          return http.Response.bytes(png, 200,
              headers: {'content-type': 'image/png'});
        }))
      ..token = 'synthetic';
    expect(await api.remoteImages('m', 'a', isCurrent: () => current), isEmpty);
    expect(calls, 2);
    api.dispose();
  });
  test('oversized bytes and malformed manifest are rejected', () async {
    var calls = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async {
          calls++;
          if (calls == 1) return manifest();
          return http.Response.bytes(Uint8List(4194305), 200,
              headers: {'content-type': 'image/png'});
        }))
      ..token = 'synthetic';
    expect(await api.remoteImages('m', 'a'), isEmpty);
    api.dispose();
    final malformed = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'items': [
                {'id': '../../secret', 'source': source}
              ]
            }),
            200)))
      ..token = 'synthetic';
    await expectLater(
        malformed.remoteImages('m', 'a'), throwsA(isA<ApiException>()));
    malformed.dispose();
  });
  test('manifest401 stops before any image request', () async {
    var calls = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async {
          calls++;
          return http.Response(
              jsonEncode({
                'error': {'code': 'UNAUTHORIZED'}
              }),
              401);
        }))
      ..token = 'synthetic';
    await expectLater(api.remoteImages('m', 'a'), throwsA(isA<ApiException>()));
    expect(calls, 1);
    expect(api.token, isNull);
    api.dispose();
  });
  test('aggregate raster bytes stop at16MiB before more admissions', () async {
    final large = Uint8List(4 * 1024 * 1024)..setRange(0, 8, png);
    var calls = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response(
                jsonEncode({
                  'items': List.generate(
                      8,
                      (i) => {
                            'id': i.toRadixString(16).padLeft(64, '0'),
                            'source': 'https://tracker.invalid/$i',
                          })
                }),
                200);
          }
          return http.Response.bytes(large, 200,
              headers: {'content-type': 'image/png'});
        }))
      ..token = 'synthetic';
    final images = await api.remoteImages('m', 'a');
    expect(images.length, 4);
    expect(calls, 5);
    api.dispose();
  });
}
