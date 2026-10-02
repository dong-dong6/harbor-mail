import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'oauth_test_fixtures.dart';

void main() {
  test('admin read uses bearer and parses metadata without keeping secrets',
      () async {
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/settings/oauth');
        expect(request.headers['Authorization'], 'Bearer admin');
        final response = snapshot();
        (response['items'] as List).first['clientSecret'] = 'must-not-retain';
        return jsonResponse(response);
      }),
    )..token = 'admin';
    final result = await api.oauthSettings();
    expect(result.items.length, 3);
    expect(result.items.first.hasClientSecret, isTrue);
    expect(result.items.first.clientId, 'GMAIL-id');
    expect(result.toString(), isNot(contains('must-not-retain')));
    expect(() => result.items.clear(), throwsUnsupportedError);
    api.dispose();
  });

  test(
      'blank secret omitted, nonblank replaced verbatim, clear explicit and revision sent',
      () async {
    final requests = <http.Request>[];
    final api = MailApi(
      base: 'https://mail.invalid/api/v1',
      client: MockClient((request) async {
        requests.add(request);
        return jsonResponse(metadata('GMAIL', source: 'DATABASE', revision: 5));
      }),
    );
    for (final value in ['', '   ', ' synthetic-secret ']) {
      await api.saveOAuthSettings(
          provider: 'GMAIL',
          revision: 4,
          clientId: ' app ',
          redirectUri: ' https://mail.example.com/api/v1/oauth/GMAIL/callback ',
          tenant: ' ',
          clientSecret: value);
    }
    await api.saveOAuthSettings(
        provider: 'GMAIL',
        revision: 4,
        clientId: 'app',
        redirectUri: '',
        tenant: '',
        clearClientSecret: true);
    expect(
        requests.every((r) =>
            r.method == 'PUT' && r.url.path == '/api/v1/settings/oauth/GMAIL'),
        isTrue);
    final bodies = requests.map((r) => jsonDecode(r.body) as Map).toList();
    expect(bodies[0], {
      'revision': 4,
      'clientId': 'app',
      'redirectUri': 'https://mail.example.com/api/v1/oauth/GMAIL/callback',
      'tenant': ''
    });
    expect(bodies[1].containsKey('clientSecret'), isFalse);
    expect(bodies[2]['clientSecret'], ' synthetic-secret ');
    expect(bodies[3]['clearClientSecret'], isTrue);
    expect(bodies[3].containsKey('clientSecret'), isFalse);
    api.dispose();
  });

  test('reset is POST with optimistic revision and no credential payload',
      () async {
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/settings/oauth/EXCHANGE/reset');
          expect(jsonDecode(request.body), {'revision': 12});
          return jsonResponse(metadata('EXCHANGE', revision: 13));
        }));
    final result =
        await api.resetOAuthSettings(provider: 'EXCHANGE', revision: 12);
    expect(result.source, 'ENVIRONMENT');
    expect(result.revision, 13);
    api.dispose();
  });

  test('unknown provider and contradictory secret actions never send requests',
      () async {
    var requests = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async {
          requests++;
          return jsonResponse({});
        }));
    await expectLater(api.resetOAuthSettings(provider: '../auth', revision: 0),
        throwsA(isA<ApiException>()));
    await expectLater(
        api.saveOAuthSettings(
            provider: 'GMAIL',
            revision: 0,
            clientId: '',
            redirectUri: '',
            tenant: '',
            clientSecret: 'synthetic',
            clearClientSecret: true),
        throwsA(isA<ApiException>()));
    expect(requests, 0);
    api.dispose();
  });

  test(
      'malformed metadata, absent readonly and duplicate providers fail closed',
      () {
    for (final data in [
      {},
      {...snapshot()}..remove('readOnly'),
      {
        ...snapshot(),
        'items': [metadata('GMAIL'), metadata('GMAIL'), metadata('EXCHANGE')]
      },
      {
        ...snapshot(),
        'items': [metadata('GMAIL')]
      },
      {
        ...snapshot(),
        'items': [
          metadata('GMAIL'),
          metadata('OUTLOOK'),
          {...metadata('EXCHANGE'), 'hasClientSecret': 'yes'}
        ]
      },
    ]) {
      expect(() => OAuthSettingsSnapshot.fromJson(data),
          throwsA(isA<ApiException>()));
    }
  });

  test('revision conflicts remain actionable and do not silently retry',
      () async {
    var requests = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async {
          requests++;
          return jsonResponse({
            'error': {'code': 'CONFIG_REVISION_CONFLICT', 'message': 'Reload'}
          }, 409);
        }));
    await expectLater(
        api.resetOAuthSettings(provider: 'GMAIL', revision: 0),
        throwsA(isA<ApiException>().having(
            (error) => error.code, 'code', 'CONFIG_REVISION_CONFLICT')));
    expect(requests, 1);
    api.dispose();
  });
}
