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
