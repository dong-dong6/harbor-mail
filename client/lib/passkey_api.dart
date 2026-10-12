import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';

/// Application metadata only; credential IDs and public keys remain server-side.
class PasskeyEntry {
  const PasskeyEntry({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastUsedAt,
  });
  final String id, name;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  factory PasskeyEntry.fromJson(dynamic value) {
    final map = _object(value);
    return PasskeyEntry(
      id: _string(map, 'id', 128),
      name: _string(map, 'name', 80),
      createdAt: _date(map, 'createdAt'),
      lastUsedAt: map['lastUsedAt'] == null ? null : _date(map, 'lastUsedAt'),
    );
  }
}

class PasskeyCapabilities {
  const PasskeyCapabilities({required this.available, this.rpId});
  final bool available;
  final String? rpId;
}

/// Memory-only login result. The caller applies the token after its own current
/// server/navigation check. Neither the API nor the flow signs in implicitly.
class PasskeySession {
  const PasskeySession({
    required this.accessToken,
    required this.expiresAt,
    required this.accountName,
  });
  final String accessToken, accountName;
  final DateTime expiresAt;
  String get permission => 'OWNER_FULL_ACCESS';

  factory PasskeySession.fromJson(dynamic value) {
    final map = _object(value);
    final token = _string(map, 'accessToken', 4096);
    final expires = _date(map, 'expiresAt');
    final now = DateTime.now().toUtc();
    if (RegExp(r'\s').hasMatch(token) ||
        map['permission'] != 'OWNER_FULL_ACCESS' ||
        !expires.isAfter(now) ||
        expires.isAfter(now.add(const Duration(hours: 8, seconds: 15)))) {
      throw _invalid();
    }
    final maximum = now.add(const Duration(hours: 8));
    return PasskeySession(
      accessToken: token,
      expiresAt: expires.isAfter(maximum) ? maximum : expires,
      accountName: _string(map, 'accountName', 320),
    );
  }
}

class PasskeyOptions {
  const PasskeyOptions(this.requestId, this.publicKey);
  final String requestId;
  final Map<String, dynamic> publicKey;

  factory PasskeyOptions.fromJson(dynamic value, {required bool registration}) {
    final map = _object(value);
    final key = _object(map['publicKey']);
    _string(key, 'challenge', 1024);
    if (registration) {
      final selection = _object(key['authenticatorSelection']);
      if (selection['userVerification'] != 'required' ||
          selection['residentKey'] != 'required' ||
          key['attestation'] != 'none') {
        throw _invalid();
      }
      _string(_object(key['rp']), 'id', 253);
      _string(_object(key['user']), 'id', 1024);
      if (key['pubKeyCredParams'] is! List ||
          (key['pubKeyCredParams'] as List).isEmpty) {
        throw _invalid();
      }
    } else {
      _string(key, 'rpId', 253);
      if (key['userVerification'] != 'required') throw _invalid();
    }
    // We do not request PRF, restore keys, or any other credential extensions.
    final safeKey = Map<String, dynamic>.from(key)..remove('extensions');
    return PasskeyOptions(_string(map, 'requestId', 128), safeKey);
  }
}

/// Bounded same-server transport. Public endpoints never inherit the bearer;
/// registration/deletion bind to the exact owner session which initiated them.
class PasskeyApi {
  PasskeyApi(this.mailApi);
  final MailApi mailApi;

  Future<PasskeyCapabilities> capabilities() async {
    final map = _object(await _request('GET', '/capabilities'));
    if (map['available'] is! bool) throw _invalid();
    return PasskeyCapabilities(
      available: map['available'] as bool,
      rpId: map['available'] == true ? _string(map, 'rpId', 253) : null,
    );
  }

  Future<PasskeyOptions> registrationOptions({
    required String password,
    required String name,
    required String bearer,
  }) async {
    _checkPassword(password);
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(trimmed)) {
      throw ApiException('INVALID_REQUEST', '请输入 1 至 80 个字符的通行密钥名称');
    }
    final options = PasskeyOptions.fromJson(
      await _request(
        'POST',
        '/registration/options',
        bearer: bearer,
        body: {'password': password, 'name': trimmed},
      ),
      registration: true,
    );
    _checkRp(options, registration: true);
    return options;
  }

  Future<PasskeyEntry> verifyRegistration(
    PasskeyOptions options,
    Map<String, dynamic> credential, {
    required String bearer,
  }) async => PasskeyEntry.fromJson(
    await _request(
      'POST',
      '/registration/verify',
      bearer: bearer,
      body: {'requestId': options.requestId, 'credential': credential},
    ),
  );

  Future<PasskeyOptions> authenticationOptions() async {
    final options = PasskeyOptions.fromJson(
      await _request(
        'POST',
        '/authentication/options',
        body: <String, dynamic>{},
      ),
      registration: false,
    );
    _checkRp(options, registration: false);
    return options;
  }

  void _checkRp(PasskeyOptions options, {required bool registration}) {
    final selected = Uri.parse(mailApi.base);
    final host = (selected.hasAuthority ? selected : Uri.base).host
        .toLowerCase();
    final rp = registration
        ? (options.publicKey['rp'] as Map)['id']
        : options.publicKey['rpId'];
    // A QR-selected malicious server must not relay another RP's challenge to
    // an app with that RP's trusted native association. No parent-domain or
    // server-provided alternate RP is accepted here.
    if (host.isEmpty || rp != host) {
      throw ApiException('PASSKEY_RP_MISMATCH', '通行密钥域名与所选服务器不一致');
    }
  }

  Future<PasskeySession> verifyAuthentication(
    PasskeyOptions options,
    Map<String, dynamic> credential,
  ) async => PasskeySession.fromJson(
    await _request(
      'POST',
      '/authentication/verify',
      body: {'requestId': options.requestId, 'credential': credential},
    ),
  );

  Future<List<PasskeyEntry>> list({required String bearer}) async {
    final map = _object(await _request('GET', '', bearer: bearer));
    if (map['items'] is! List || (map['items'] as List).length > 100) {
      throw _invalid();
    }
    return (map['items'] as List).map(PasskeyEntry.fromJson).toList();
  }

  Future<void> delete(
    String id, {
    required String password,
    required String bearer,
  }) async {
    _checkPassword(password);
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id)) {
      throw ApiException('INVALID_REQUEST', '无效的通行密钥');
    }
    await _request(
      'POST',
      '/$id/delete',
      bearer: bearer,
      body: {'password': password},
    );
  }

  Future<dynamic> _request(
    String method,
    String suffix, {
    String? bearer,
    Map<String, dynamic>? body,
  }) async {
    if (bearer != null && (bearer.isEmpty || mailApi.token != bearer)) {
      throw ApiException('UNAUTHORIZED', '请重新登录');
    }
    final request = http.Request(method, mailApi.uri('/auth/passkeys$suffix'))
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (bearer != null) 'Authorization': 'Bearer $bearer',
      });
    if (body != null) request.body = jsonEncode(body);
    try {
      return await (() async {
        final streamed = await mailApi.client.send(request);
        if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
          await streamed.stream.listen((_) {}).cancel();
          throw ApiException('API_REDIRECT', '服务器发生重定向，请核对地址');
        }
        if ((streamed.contentLength ?? 0) > 131072) {
          await streamed.stream.listen((_) {}).cancel();
          throw _invalid();
        }
        final bytes = <int>[];
        await for (final chunk in streamed.stream) {
          if (bytes.length + chunk.length > 131072) throw _invalid();
          bytes.addAll(chunk);
        }
        if (streamed.statusCode == 401 &&
            bearer != null &&
            mailApi.token == bearer) {
          mailApi.token = null;
        }
        final dynamic data = bytes.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(utf8.decode(bytes));
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          final error = data is Map ? data['error'] : null;
          final code =
              error is Map &&
                  error['code'] is String &&
                  RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(error['code'])
              ? error['code'] as String
              : 'HTTP_${streamed.statusCode}';
          throw ApiException(code, '通行密钥操作未完成');
        }
        return data;
      })().timeout(const Duration(seconds: 30));
    } on ApiException {
      rethrow;
    } on FormatException {
      throw _invalid();
    } catch (_) {
      // No retries: the server may have consumed a one-time request already.
      throw ApiException('NETWORK', '无法确认服务器响应，请检查状态后再操作');
    }
  }
}

void _checkPassword(String password) {
  if (password.isEmpty || password.length > 4096) {
    throw ApiException('INVALID_REQUEST', '请输入当前账户密码');
  }
}

ApiException _invalid() => ApiException('INVALID_RESPONSE', '无效的通行密钥响应');
Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>) throw _invalid();
  return value;
}

String _string(Map<String, dynamic> map, String key, int maximum) {
  final value = map[key];
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw _invalid();
  }
  return value;
}

DateTime _date(Map<String, dynamic> map, String key) {
  final value = DateTime.tryParse(_string(map, key, 40));
  if (value == null || !value.isUtc) throw _invalid();
  return value;
}
