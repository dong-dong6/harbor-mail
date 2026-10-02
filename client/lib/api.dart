import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String code, message;
  ApiException(this.code, this.message);
  @override
  String toString() => '$message ($code)';
}

class MailApi {
  final http.Client client;
  final String base;
  String? token;
  MailApi({http.Client? client, String? base})
      : client = client ?? http.Client(),
        base = base ??
            const String.fromEnvironment('API_BASE', defaultValue: '/api/v1');
  Uri uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$base$path').replace(queryParameters: query);
  Map<String, String> get headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    String? key,
  }) async {
    final req = http.Request(method, uri(path, query))..headers.addAll(headers);
    if (key != null) req.headers['Idempotency-Key'] = key;
    if (body != null) req.body = jsonEncode(body);
    try {
      final response = await http.Response.fromStream(
        await client.send(req).timeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 30));
      return decode(response);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('NETWORK', '无法连接服务器，请检查网络后重试');
    }
  }

  dynamic decode(http.Response response) {
    dynamic data;
    try {
      data = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw ApiException('INVALID_RESPONSE', '服务器返回了无法识别的响应');
    }
    if (response.statusCode >= 400) {
      if (response.statusCode == 401) token = null;
      final error = data is Map ? data['error'] : null;
      throw ApiException(
        error?['code']?.toString() ?? 'HTTP_${response.statusCode}',
        error?['message']?.toString() ?? '操作未完成',
      );
    }
    return data;
  }

  Future<void> login(String username, String password) async {
    final result = await request(
      'POST',
      '/auth/login',
      body: {'username': username, 'password': password},
    );
    token = result['accessToken'];
  }

  Future<OAuthSettingsSnapshot> oauthSettings() async =>
      OAuthSettingsSnapshot.fromJson(await request('GET', '/settings/oauth'));

  Future<OAuthProviderSettings> saveOAuthSettings({
    required String provider,
    required int revision,
    required String clientId,
    required String redirectUri,
    required String tenant,
    String clientSecret = '',
    bool clearClientSecret = false,
  }) async {
    _checkOAuthProvider(provider);
    if (clearClientSecret && clientSecret.trim().isNotEmpty) {
      throw ApiException('INVALID_REQUEST', '不能同时替换和清除密钥');
    }
    return OAuthProviderSettings.fromJson(
      await request(
        'PUT',
        '/settings/oauth/$provider',
        body: {
          'revision': revision,
          'clientId': clientId.trim(),
          'redirectUri': redirectUri.trim(),
          'tenant': tenant.trim(),
          // An empty editor means preserve, never a placeholder or an empty secret.
          if (clientSecret.trim().isNotEmpty) 'clientSecret': clientSecret,
          if (clearClientSecret) 'clearClientSecret': true,
        },
      ),
    );
  }

  Future<OAuthProviderSettings> resetOAuthSettings({
    required String provider,
    required int revision,
  }) async {
    _checkOAuthProvider(provider);
    return OAuthProviderSettings.fromJson(
      await request(
        'POST',
        '/settings/oauth/$provider/reset',
        body: {'revision': revision},
      ),
    );
  }

  Future<Map<String, dynamic>> upload(
    String draftId,
    String name,
    Uint8List bytes,
  ) async {
    final req = http.MultipartRequest(
      'POST',
      uri('/drafts/$draftId/attachments'),
    );
    req.headers['Authorization'] = 'Bearer $token';
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    return Map<String, dynamic>.from(
      decode(
        await http.Response.fromStream(
          await client.send(req).timeout(const Duration(seconds: 60)),
        ),
      ),
    );
  }

  Future<Uint8List> download(String id) async {
    final response = await client
        .get(uri('/attachments/$id/content'), headers: headers)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode >= 400) decode(response);
    return response.bodyBytes;
  }

  void dispose() {
    token = null;
    client.close();
  }
}

const oauthProviderNames = <String, String>{
  'GMAIL': 'Google / Gmail',
  'OUTLOOK': '个人 Outlook',
  'EXCHANGE': 'Microsoft 365 E3（企业）',
};

void _checkOAuthProvider(String provider) {
  if (!oauthProviderNames.containsKey(provider)) {
    throw ApiException('INVALID_REQUEST', '不支持的 OAuth 服务商');
  }
}

/// Safe configuration metadata only. Secret values from responses are ignored.
class OAuthProviderSettings {
  final String provider, source, clientId, redirectUri, tenant;
  final int revision;
  final bool hasClientSecret, configured;

  const OAuthProviderSettings({
    required this.provider,
    required this.source,
    required this.revision,
    required this.clientId,
    required this.redirectUri,
    required this.tenant,
    required this.hasClientSecret,
    required this.configured,
  });

  factory OAuthProviderSettings.fromJson(dynamic value) {
    if (value is! Map ||
        !oauthProviderNames.containsKey(value['provider']) ||
        !['ENVIRONMENT', 'DATABASE'].contains(value['source']) ||
        value['revision'] is! int ||
        (value['revision'] as int) < 0 ||
        value['clientId'] is! String ||
        value['redirectUri'] is! String ||
        value['tenant'] is! String ||
        value['hasClientSecret'] is! bool ||
        value['configured'] is! bool) {
      throw ApiException('INVALID_RESPONSE', '无法读取 OAuth 配置，请重新载入');
    }
    return OAuthProviderSettings(
      provider: value['provider'],
      source: value['source'],
      revision: value['revision'],
      clientId: value['clientId'],
      redirectUri: value['redirectUri'],
      tenant: value['tenant'],
      hasClientSecret: value['hasClientSecret'],
      configured: value['configured'],
    );
  }
}

class OAuthSettingsSnapshot {
  final bool demoMode, readOnly;
  final List<OAuthProviderSettings> items;
  const OAuthSettingsSnapshot({
    required this.demoMode,
    required this.readOnly,
    required this.items,
  });

  factory OAuthSettingsSnapshot.fromJson(dynamic value) {
    if (value is! Map ||
        value['demoMode'] is! bool ||
        value['readOnly'] is! bool ||
        value['items'] is! List) {
      throw ApiException('INVALID_RESPONSE', '无法读取 OAuth 配置，请重新载入');
    }
    final items = (value['items'] as List)
        .map(OAuthProviderSettings.fromJson)
        .toList(growable: false);
    if (items.length != oauthProviderNames.length ||
        items.map((item) => item.provider).toSet().length != items.length) {
      throw ApiException('INVALID_RESPONSE', 'OAuth 服务商配置不完整，请重新载入');
    }
    return OAuthSettingsSnapshot(
      demoMode: value['demoMode'],
      readOnly: value['readOnly'],
      items: List.unmodifiable(items),
    );
  }
}
