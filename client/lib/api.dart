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
  String? _token;

  /// Original absolute server expiry; never renewed by local restoration.
  DateTime? sessionExpiresAt;
  String? sessionAccount;
  String? sessionDeviceId;

  /// The session owner can immediately retire protected UI after any current
  /// API path (including passkeys) clears its token. Never fires on a login or
  /// on a stale request rejection which leaves the current token untouched.
  void Function()? onSessionCleared;
  String? get token => _token;
  set token(String? value) {
    final wasAuthenticated = _token != null;
    if (value != _token) {
      sessionExpiresAt = null;
      sessionAccount = null;
      sessionDeviceId = null;
    }
    _token = value;
    if (wasAuthenticated && value == null) onSessionCleared?.call();
  }

  MailApi({http.Client? client, String? base, this.onSessionCleared})
    : client = client ?? http.Client(),
      base =
          base ??
          const String.fromEnvironment('API_BASE', defaultValue: '/api/v1');
  Uri uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$base$path').replace(queryParameters: query);
  Map<String, String> get headers => _headersFor(token);
  Map<String, String> _headersFor(String? bearer) => {
    'Content-Type': 'application/json',
    if (bearer != null) 'Authorization': 'Bearer $bearer',
  };

  /// A delayed rejection of an old request must not sign out a newer login.
  void _clearRejectedSession(String? requestBearer) {
    if (requestBearer != null && token == requestBearer) token = null;
  }

  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    String? key,
    bool followRedirects = false,
  }) async {
    final bearer = token;
    final req = http.Request(method, uri(path, query))
      ..followRedirects = followRedirects
      ..headers.addAll(_headersFor(bearer));
    if (key != null) req.headers['Idempotency-Key'] = key;
    if (body != null) req.body = jsonEncode(body);
    try {
      final response = await http.Response.fromStream(
        await client.send(req).timeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 30));
      return decode(response, requestBearer: bearer);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('NETWORK', '无法连接服务器，请检查网络后重试');
    }
  }

  dynamic decode(http.Response response, {required String? requestBearer}) {
    if (response.statusCode == 401) _clearRejectedSession(requestBearer);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw ApiException('API_REDIRECT', '服务器地址发生重定向，请核对服务器 URL');
    }
    dynamic data;
    try {
      data = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      if (response.statusCode == 401) {
        throw ApiException('UNAUTHORIZED', '请重新登录');
      }
      throw ApiException('INVALID_RESPONSE', '服务器返回了无法识别的响应');
    }
    if (response.statusCode >= 400) {
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
    sessionExpiresAt = DateTime.tryParse(
      result['expiresAt']?.toString() ?? '',
    )?.toUtc();
    sessionAccount = username;
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
    final bearer = token;
    final req = http.MultipartRequest(
      'POST',
      uri('/drafts/$draftId/attachments'),
    )..followRedirects = false;
    if (bearer != null) req.headers['Authorization'] = 'Bearer $bearer';
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    return Map<String, dynamic>.from(
      decode(
        await http.Response.fromStream(
          await client.send(req).timeout(const Duration(seconds: 60)),
        ),
        requestBearer: bearer,
      ),
    );
  }

  Future<Uint8List> download(String id) async {
    final bearer = token;
    final request = http.Request('GET', uri('/attachments/$id/content'))
      ..followRedirects = false
      ..headers.addAll(_headersFor(bearer));
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 60)),
    ).timeout(const Duration(seconds: 60));
    if (response.statusCode >= 300) {
      decode(response, requestBearer: bearer);
    }
    return response.bodyBytes;
  }

  /// Opt-in only. All network requests stay on the authenticated mail API.
  /// Raster data is handed to the opaque iframe; remote URLs are never used there.
  Future<Map<String, String>> remoteImages(
    String messageId,
    String accountId, {
    bool Function()? isCurrent,
  }) async {
    final bearer = token;
    bool current() =>
        bearer != null && token == bearer && (isCurrent?.call() ?? true);
    if (!current()) throw ApiException('UNAUTHORIZED', '请重新登录');
    final path = '/messages/${Uri.encodeComponent(messageId)}/images';
    final manifest = await request(
      'GET',
      path,
      query: {'accountId': accountId},
      followRedirects: false,
    );
    if (!current()) throw ApiException('UNAUTHORIZED', '请重新登录');
    if (manifest is! Map ||
        manifest['items'] is! List ||
        (manifest['items'] as List).length > 32) {
      throw ApiException('INVALID_RESPONSE', '无法读取图片清单');
    }
    final items = List<dynamic>.from(manifest['items']);
    for (final item in items) {
      if (item is! Map ||
          item['id'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(item['id']) ||
          item['source'] is! String ||
          (item['source'] as String).length > 4096) {
        throw ApiException('INVALID_RESPONSE', '无法读取图片清单');
      }
    }
    final result = <String, String>{};
    var totalBytes = 0;
    const maxBatchBytes = 16 * 1024 * 1024;
    // Sequential admission means a 401 stops the batch immediately: no anonymous
    // retry, no remaining request, and no automatic retry of a tracking image.
    for (final item in items) {
      if (!current() || totalBytes >= maxBatchBytes) break;
      try {
        final req =
            http.Request(
                'GET',
                uri('$path/${item['id']}', {'accountId': accountId}),
              )
              ..followRedirects = false
              ..headers['Authorization'] = 'Bearer $bearer'
              ..headers['Accept'] = 'image/png';
        final streamed = await client
            .send(req)
            .timeout(const Duration(seconds: 12));
        if (streamed.statusCode == 401) {
          _clearRejectedSession(bearer);
          await streamed.stream.listen((_) {}).cancel();
          throw ApiException('UNAUTHORIZED', '请重新登录');
        }
        if (streamed.statusCode != 200 ||
            streamed.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase() !=
                'image/png' ||
            (streamed.contentLength ?? 0) > 4194304) {
          await streamed.stream.listen((_) {}).cancel();
          continue;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in streamed.stream.timeout(
          const Duration(seconds: 12),
        )) {
          if (!current()) break;
          if (bytes.length + chunk.length > 4194304) {
            throw ApiException('IMAGE_TOO_LARGE', '图片过大');
          }
          if (totalBytes + bytes.length + chunk.length > maxBatchBytes) {
            throw ApiException('IMAGE_BATCH_TOO_LARGE', '本封邮件图片总大小已达上限');
          }
          bytes.add(chunk);
        }
        if (!current()) break;
        final png = bytes.takeBytes();
        const magic = [137, 80, 78, 71, 13, 10, 26, 10];
        if (png.length < 8 ||
            Iterable<int>.generate(8).any((i) => png[i] != magic[i])) {
          continue;
        }
        totalBytes += png.length;
        result[item['source']] = 'data:image/png;base64,${base64Encode(png)}';
      } on ApiException catch (e) {
        if (e.code == 'UNAUTHORIZED') rethrow;
        if (e.code == 'IMAGE_BATCH_TOO_LARGE') break;
        // A failed image stays blocked. Never fall back to its original URL.
      } catch (_) {
        // The rest of the message remains readable when one image fails.
      }
    }
    return result;
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
