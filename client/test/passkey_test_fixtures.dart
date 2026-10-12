import 'dart:async';
import 'dart:convert';

import 'package:harbor_mail/passkey_platform.dart';
import 'package:http/http.dart' as http;

Map<String, dynamic> passkeyOptions({bool registration = false}) => {
  'requestId': 'synthetic-request',
  'publicKey': {
    'challenge': 'c3ludGhldGljLWNoYWxsZW5nZQ',
    'timeout': 120000,
    if (registration) ...{
      'rp': {'id': 'mail.example.test', 'name': 'Synthetic Mail'},
      'user': {
        'id': 'c3ludGhldGljLXVzZXI',
        'name': 'owner',
        'displayName': 'Owner',
      },
      'authenticatorSelection': {
        'userVerification': 'required',
        'residentKey': 'required',
      },
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
      ],
      'attestation': 'none',
      'excludeCredentials': <dynamic>[],
    } else ...{
      'rpId': 'mail.example.test',
      'userVerification': 'required',
    },
  },
};
Map<String, dynamic> syntheticCredential({bool registration = false}) => {
  'type': 'public-key',
  'id': 'c3ludGhldGljLWlk',
  'rawId': 'c3ludGhldGljLWlk',
  'response': {
    'clientDataJSON': 'c3ludGhldGljLWNsaWVudA',
    if (registration)
      'attestationObject': 'c3ludGhldGljLWF0dGVzdGF0aW9u'
    else ...{
      'authenticatorData': 'c3ludGhldGljLWRhdGE',
      'signature': 'c3ludGhldGljLXNpZ25hdHVyZQ',
      'userHandle': 'c3ludGhldGljLXVzZXI',
    },
  },
  'clientExtensionResults': <String, dynamic>{},
};
Map<String, dynamic> passkeyEntry() => {
  'id': 'synthetic-passkey',
  'name': '我的通行密钥',
  'createdAt': '2026-10-01T12:00:00Z',
  'lastUsedAt': null,
};
Map<String, dynamic> passkeySession() => {
  'accessToken': 'synthetic-passkey-token',
  'accountName': 'synthetic-owner',
  'expiresAt': DateTime.now()
      .toUtc()
      .add(const Duration(hours: 7))
      .toIso8601String(),
  'permission': 'OWNER_FULL_ACCESS',
};
http.Response passkeyJson(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

/// Test-only synthetic outputs. Never touches an OS authenticator or key store.
class SyntheticPasskeyAuthenticator implements PasskeyAuthenticator {
  int registerCalls = 0, authenticateCalls = 0, cancelCalls = 0;
  Map<String, dynamic>? receivedOptions;
  Completer<Map<String, dynamic>>? pending;
  Object? failure;
  @override
  Future<Map<String, dynamic>> register(Map<String, dynamic> publicKey) async {
    registerCalls++;
    receivedOptions = publicKey;
    if (failure != null) throw failure!;
    return pending?.future ?? syntheticCredential(registration: true);
  }

  @override
  Future<Map<String, dynamic>> authenticate(
    Map<String, dynamic> publicKey,
  ) async {
    authenticateCalls++;
    receivedOptions = publicKey;
    if (failure != null) throw failure!;
    return pending?.future ?? syntheticCredential();
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}
