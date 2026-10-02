import 'dart:convert';
import 'package:harbor_mail/api.dart';
import 'package:http/http.dart' as http;

Map<String, dynamic> metadata(
  String provider, {
  String source = 'ENVIRONMENT',
  int revision = 0,
  bool hasSecret = true,
}) =>
    {
      'provider': provider,
      'source': source,
      'revision': revision,
      'clientId': '$provider-id',
      'redirectUri': 'https://mail.example.com/api/v1/oauth/$provider/callback',
      'tenant': provider == 'OUTLOOK'
          ? 'consumers'
          : provider == 'EXCHANGE'
              ? 'organizations'
              : '',
      'hasClientSecret': hasSecret,
      'configured': hasSecret,
      'validationErrors': <String>[],
    };

Map<String, dynamic> snapshot({bool demo = false, bool readOnly = false}) => {
      'demoMode': demo,
      'readOnly': readOnly,
      'items': oauthProviderNames.keys.map(metadata).toList(),
    };

http.Response jsonResponse(Object value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
