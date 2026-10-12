import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:harbor_mail/api.dart';

void main() {
  test('authenticated API does not follow redirects to another destination',
      () async {
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response('{}', 307,
            headers: {'location': 'https://other.invalid/api/v1/accounts'});
      }),
    )..token = 'synthetic-session';
    await expectLater(
        api.request('GET', '/accounts'),
        throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'API_REDIRECT')));
    expect(api.token, 'synthetic-session');
    api.dispose();
  });
  test(
    'login retains only session bearer and applies it to requests',
    () async {
      final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) {
            expect(jsonDecode(request.body), {
              'username': 'owner',
              'password': 'test-only',
            });
            return http.Response('{"accessToken":"session-only"}', 200);
          }
          expect(request.headers['Authorization'], 'Bearer session-only');
          expect(request.url.queryParameters['query'], '中文 & subject');
          return http.Response('{"items":[]}', 200);
        }),
      );
      await api.login('owner', 'test-only');
      await api.request('GET', '/messages', query: {'query': '中文 & subject'});
      api.dispose();
      expect(api.token, isNull);
    },
  );
  test('401 clears memory token and exposes sanitized server error', () async {
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient(
        (_) async => http.Response(
          '{"error":{"code":"UNAUTHORIZED","message":"Session expired"}}',
          401,
        ),
      ),
    )..token = 'expired';
    await expectLater(
      api.request('GET', '/messages'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHORIZED'),
      ),
    );
    expect(api.token, isNull);
  });
  test('command preserves idempotency key and revision', () async {
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((req) async {
        expect(req.headers['Idempotency-Key'], 'key-1');
        expect(jsonDecode(req.body)['baseRevision'], 3);
        return http.Response('{"id":"c1","status":"QUEUED"}', 202);
      }),
    );
    final result = await api.request(
      'POST',
      '/commands',
      key: 'key-1',
      body: {
        'type': 'SET_STAR',
        'messageId': 'm1',
        'baseRevision': 3,
        'value': true,
      },
    );
    expect(result['status'], 'QUEUED');
  });
  test('malformed payload is explicit error', () async {
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient(
        (_) async => http.Response('<html>not api</html>', 200),
      ),
    );
    await expectLater(
      api.request('GET', '/messages'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'INVALID_RESPONSE'),
      ),
    );
  });
}
