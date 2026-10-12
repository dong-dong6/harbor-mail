import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('session-clear callback fires once on authenticated-to-null only', () {
    var cleared = 0;
    final api = MailApi();
    api.onSessionCleared = () {
      cleared++;
      expect(api.token, isNull);
      // Reentrant cleanup cannot notify a second time.
      api.token = null;
    };
    api.token = null;
    api.token = 'first';
    api.token = 'replacement';
    expect(cleared, 0);
    api.token = null;
    api.token = null;
    expect(cleared, 1);
    api.token = 'new-login';
    expect(cleared, 1);
    api.token = null;
    expect(cleared, 2);
    api.dispose();
    expect(cleared, 2);
  });

  test('current401 notifies the owner after clearing memory token', () async {
    var cleared = 0;
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((_) async => http.Response('{}', 401)),
      onSessionCleared: () => cleared++,
    )..token = 'expired';
    await expectLater(
      api.request('GET', '/accounts'),
      throwsA(isA<ApiException>()),
    );
    expect(api.token, isNull);
    expect(cleared, 1);
    api.dispose();
    expect(cleared, 1);
  });

  test('stale401 never notifies the new session owner', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    var cleared = 0;
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((_) {
        started.complete();
        return response.future;
      }),
      onSessionCleared: () => cleared++,
    )..token = 'old';
    final future = api.request('GET', '/accounts');
    final rejected = expectLater(future, throwsA(isA<ApiException>()));
    await started.future;
    api.token = 'new';
    response.complete(http.Response('{}', 401));
    await rejected;
    expect(api.token, 'new');
    expect(cleared, 0);
    api.onSessionCleared = null;
    api.dispose();
    expect(cleared, 0);
  });

  final operations = <String, Future<Object?> Function(MailApi)>{
    'ordinary request': (api) => api.request('GET', '/accounts'),
    'logout': (api) => api.request('POST', '/auth/logout'),
    'attachment upload': (api) =>
        api.upload('synthetic-draft', 'test.txt', Uint8List.fromList([1])),
    'attachment download': (api) => api.download('synthetic-attachment'),
  };

  for (final operation in operations.entries) {
    for (final malformed in [false, true]) {
      test('${operation.key}: late ${malformed ? 'malformed ' : ''}401 '
          'cannot clear a replacement session', () async {
        final response = Completer<http.Response>();
        final started = Completer<void>();
        final api = MailApi(
          base: 'https://mail.invalid/api/v1',
          client: MockClient((request) {
            expect(request.headers['Authorization'], 'Bearer old-session');
            expect(request.followRedirects, isFalse);
            started.complete();
            return response.future;
          }),
        )..token = 'old-session';
        final future = operation.value(api);
        final rejected = expectLater(future, throwsA(isA<ApiException>()));
        await started.future;
        api.token = null;
        api.token = 'replacement-session';
        response.complete(
          http.Response(
            malformed
                ? '<html>expired session</html>'
                : '{"error":{"code":"UNAUTHORIZED","message":"Expired"}}',
            401,
          ),
        );
        await rejected;
        expect(api.token, 'replacement-session');
        api.dispose();
      });
    }

    test(
      '${operation.key}: current-session 401 still clears the token',
      () async {
        final api = MailApi(
          base: 'https://mail.invalid/api/v1',
          client: MockClient((_) async => http.Response('{}', 401)),
        )..token = 'expired-session';
        await expectLater(operation.value(api), throwsA(isA<ApiException>()));
        expect(api.token, isNull);
        api.dispose();
      },
    );
  }

  test(
    'anonymous request 401 cannot clear a login established afterward',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((request) {
          expect(request.headers['Authorization'], isNull);
          started.complete();
          return response.future;
        }),
      );
      final future = api.request('GET', '/accounts');
      final rejected = expectLater(future, throwsA(isA<ApiException>()));
      await started.future;
      api.token = 'new-session';
      response.complete(http.Response('{}', 401));
      await rejected;
      expect(api.token, 'new-session');
      api.dispose();
    },
  );

  for (final responseStage in ['manifest', 'image']) {
    test(
      'late remote-image $responseStage 401 preserves replacement session',
      () async {
        final response = Completer<http.Response>();
        final started = Completer<void>();
        final imageId = 'a' * 64;
        var calls = 0;
        final api = MailApi(
          base: 'https://mail.invalid/api/v1',
          client: MockClient((request) {
            calls++;
            expect(request.headers['Authorization'], 'Bearer old-session');
            if (responseStage == 'image' && calls == 1) {
              return Future.value(
                http.Response(
                  jsonEncode({
                    'items': [
                      {
                        'id': imageId,
                        'source': 'https://tracker.invalid/image',
                      },
                    ],
                  }),
                  200,
                ),
              );
            }
            started.complete();
            return response.future;
          }),
        )..token = 'old-session';
        final future = api.remoteImages(
          'synthetic-message',
          'synthetic-account',
        );
        final rejected = expectLater(future, throwsA(isA<ApiException>()));
        await started.future;
        api.token = 'replacement-session';
        response.complete(http.Response('{}', 401));
        await rejected;
        expect(api.token, 'replacement-session');
        expect(calls, responseStage == 'manifest' ? 1 : 2);
        api.dispose();
      },
    );
  }

  for (final operation in ['attachment upload', 'attachment download']) {
    test(
      '$operation refuses redirects instead of forwarding authenticated data',
      () async {
        final api = MailApi(
          base: 'https://mail.invalid/api/v1',
          client: MockClient((request) async {
            expect(request.followRedirects, isFalse);
            return http.Response(
              '',
              307,
              headers: {'location': 'https://other.invalid/private'},
            );
          }),
        )..token = 'session';
        await expectLater(
          operations[operation]!(api),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'API_REDIRECT',
            ),
          ),
        );
        expect(api.token, 'session');
        api.dispose();
      },
    );
  }
}
