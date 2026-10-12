import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'server_profile.dart';

enum PairingState { created, claimed, approved, redeemed, rejected, expired }

class PairingSnapshot {
  const PairingSnapshot({
    required this.pairingId,
    required this.state,
    required this.expiresAt,
    required this.accountName,
    required this.permission,
    this.confirmationCode,
  });

  final String pairingId;
  final PairingState state;
  final DateTime expiresAt;
  final String accountName;
  final String permission;
  final String? confirmationCode;

  bool get isTerminal => const {
        PairingState.redeemed,
        PairingState.rejected,
        PairingState.expired,
      }.contains(state);

  factory PairingSnapshot.fromJson(dynamic data) {
    final map = _object(data);
    final rawState = _string(map, 'state', max: 16);
    final state = PairingState.values.where(
      (value) => value.name.toUpperCase() == rawState,
    );
    if (state.length != 1) throw _invalidResponse();
    final code = map['confirmationCode'];
    if (code != null &&
        (code is! String || !RegExp(r'^[0-9]{6}$').hasMatch(code))) {
      throw _invalidResponse();
    }
    if ({PairingState.claimed, PairingState.approved}.contains(state.single) &&
        code == null) {
      throw _invalidResponse();
    }
    return PairingSnapshot(
      pairingId: _string(map, 'pairingId', max: 128),
      state: state.single,
      expiresAt: _date(map),
      accountName: _string(map, 'accountName', max: 320),
      permission: _permission(map),
      confirmationCode: code as String?,
    );
  }
}

/// The owner of a successful result owns [api] and must dispose it on logout.
/// Access is memory-only: no token is saved by this object or pairing transport.
class DevicePairingResult {
  const DevicePairingResult({
    required this.api,
    required this.profile,
    required this.expiresAt,
    required this.deviceId,
    required this.accountName,
    required this.permission,
  });

  final MailApi api;
  final ServerProfile profile;
  final DateTime expiresAt;
  final String deviceId;
  final String accountName;
  final String permission;
  String get accessToken => api.token ?? '';
}

typedef PairingSession = DevicePairingResult;

/// A single-use, anonymous pairing transport with proof kept only in memory.
/// Never accepts or inherits an existing MailApi, cookie jar, or bearer token.
class DevicePairingApi {
  DevicePairingApi({required this.profile, http.Client? client})
      : _client = client ?? http.Client();

  final ServerProfile profile;
  final http.Client _client;
  String? _verifier;
  String? _pairingId;
  PairingSnapshot? _snapshot;
  bool _closed = false;
  bool _claimStarted = false;
  bool _redeemStarted = false;
  bool _busy = false;
  int _generation = 0;
  final Stopwatch _pollClock = Stopwatch();
  final Stopwatch _attemptClock = Stopwatch();

  Future<PairingSnapshot> claim(PairingQr qr,
      {required String deviceName}) async {
    _checkActive();
    if (_claimStarted || qr.profile != profile) {
      throw ApiException('INVALID_PAIRING', '请重新扫描配对二维码');
    }
    final name = deviceName.trim();
    if (name.isEmpty ||
        name.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw ApiException('INVALID_REQUEST', '请输入 1 至 80 个字符的设备名称');
    }
    _claimStarted = true;
    _attemptClock.start();
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final verifier = base64Url.encode(bytes).replaceAll('=', '');
    _verifier = verifier;
    _pairingId = qr.pairingId;
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final epoch = _generation;
    try {
      final data = await _request('/auth/device-pairings/claim', {
        'pairingId': qr.pairingId,
        'secret': qr.secret,
        'deviceName': name,
        'codeChallenge': challenge,
      });
      _checkActive(epoch);
      final snapshot = PairingSnapshot.fromJson(data);
      if (snapshot.pairingId != qr.pairingId ||
          snapshot.state != PairingState.claimed ||
          !snapshot.expiresAt.isAfter(DateTime.now()) ||
          snapshot.expiresAt
              .isAfter(DateTime.now().add(const Duration(seconds: 135)))) {
        throw _invalidResponse();
      }
      _snapshot = snapshot;
      return snapshot;
    } catch (_) {
      cancel();
      rethrow;
    }
  }

  Future<PairingSnapshot> poll() async {
    _checkProof();
    if (_busy ||
        (_pollClock.isRunning && _pollClock.elapsedMilliseconds < 2000)) {
      throw ApiException('POLL_TOO_FAST', '请稍候再查询配对状态');
    }
    if (_snapshot!.isTerminal || _redeemStarted) {
      throw ApiException('PAIRING_FINISHED', '本次配对已结束');
    }
    _busy = true;
    _pollClock
      ..reset()
      ..start();
    final epoch = _generation;
    try {
      final data = await _request('/auth/device-pairings/poll', _proof());
      _checkActive(epoch);
      final snapshot = PairingSnapshot.fromJson(data);
      if (snapshot.pairingId != _pairingId ||
          snapshot.state == PairingState.created ||
          (_snapshot!.state == PairingState.approved &&
              snapshot.state == PairingState.claimed) ||
          (snapshot.confirmationCode != null &&
              snapshot.confirmationCode != _snapshot!.confirmationCode) ||
          snapshot.accountName != _snapshot!.accountName ||
          snapshot.expiresAt != _snapshot!.expiresAt) {
        throw _invalidResponse();
      }
      _snapshot = snapshot;
      if (snapshot.isTerminal) _verifier = null;
      return snapshot;
    } finally {
      _busy = false;
    }
  }

  Future<DevicePairingResult> redeem() async {
    _checkProof();
    if (_busy || _redeemStarted || _snapshot!.state != PairingState.approved) {
      throw ApiException('PAIRING_NOT_APPROVED', '请先在网页确认并批准配对');
    }
    // Set before I/O. A timeout may still have consumed the one-time grant:
    // never retry redemption automatically or manually on this attempt.
    _redeemStarted = true;
    final epoch = _generation;
    final proof = _proof();
    try {
      final map =
          _object(await _request('/auth/device-pairings/redeem', proof));
      _checkActive(epoch);
      final token = _string(map, 'accessToken', max: 4096);
      if (RegExp(r'\s').hasMatch(token)) throw _invalidResponse();
      final serverExpiresAt = _date(map);
      final localDeadline = DateTime.now().add(const Duration(hours: 8));
      final expiresAt = serverExpiresAt.isAfter(localDeadline)
          ? localDeadline
          : serverExpiresAt;
      final deviceId = _string(map, 'deviceId', max: 128);
      final accountName = _string(map, 'accountName', max: 320);
      final permission = _permission(map);
      if (accountName != _snapshot!.accountName ||
          !serverExpiresAt.isAfter(DateTime.now()) ||
          serverExpiresAt
              .isAfter(localDeadline.add(const Duration(seconds: 15)))) {
        throw _invalidResponse();
      }
      // Separate transport and token scope. Disposing this pairing transport
      // after handover will never close the caller's authenticated mail API.
      final api = MailApi(base: profile.apiBase)..token = token;
      return DevicePairingResult(
        api: api,
        profile: profile,
        expiresAt: expiresAt,
        deviceId: deviceId,
        accountName: accountName,
        permission: permission,
      );
    } finally {
      _verifier = null;
      _pairingId = null;
    }
  }

  Map<String, String> _proof() => {
        'pairingId': _pairingId!,
        'codeVerifier': _verifier!,
      };

  void _checkProof() {
    _checkActive();
    if (_verifier == null || _pairingId == null || _snapshot == null) {
      throw ApiException('INVALID_PAIRING', '请重新扫描配对二维码');
    }
    if (!_snapshot!.expiresAt.isAfter(DateTime.now()) ||
        _attemptClock.elapsed >= const Duration(seconds: 120)) {
      cancel();
      throw ApiException('PAIRING_EXPIRED', '配对二维码已过期，请重新生成');
    }
  }

  void _checkActive([int? generation]) {
    if (_closed || (generation != null && generation != _generation)) {
      throw ApiException('PAIRING_CANCELLED', '本次配对已取消');
    }
  }

  Future<dynamic> _request(String path, Map<String, String> body) async {
    final clock = Stopwatch()..start();
    const timeout = Duration(seconds: 20);
    final request = http.Request('POST', Uri.parse('${profile.apiBase}$path'))
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/json'
      ..body = jsonEncode(body);
    try {
      final streamed = await _client.send(request).timeout(timeout);
      if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
        await streamed.stream.listen((_) {}).cancel();
        throw ApiException('PAIRING_REDIRECT', '配对服务器返回了重定向，已停止连接');
      }
      if ((streamed.contentLength ?? 0) > 16384) {
        await streamed.stream.listen((_) {}).cancel();
        throw _invalidResponse();
      }
      final iterator = StreamIterator<List<int>>(streamed.stream);
      final bytes = <int>[];
      Future<void> collect() async {
        while (await iterator.moveNext()) {
          final chunk = iterator.current;
          if (bytes.length + chunk.length > 16384) throw _invalidResponse();
          bytes.addAll(chunk);
        }
      }

      try {
        // A whole-request deadline, not an inactivity timeout: a server cannot
        // keep a claim alive indefinitely by slowly trickling response bytes.
        final remaining = timeout - clock.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Pairing timeout');
        }
        await collect().timeout(remaining);
      } finally {
        await iterator.cancel();
      }
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        throw _invalidResponse();
      }
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final error = data is Map ? data['error'] : null;
        final code = error is Map &&
                error['code'] is String &&
                RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(error['code'])
            ? error['code'] as String
            : 'HTTP_${streamed.statusCode}';
        // Do not reflect arbitrary server text (which may contain the secret).
        throw ApiException(
            code,
            streamed.statusCode == 429
                ? '配对请求过于频繁，请稍后再试'
                : '配对未完成，请返回网页检查状态或重新生成二维码');
      }
      return data;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      cancel();
      _client.close();
      throw ApiException('NETWORK', '连接超时，请重新配对');
    } catch (_) {
      throw ApiException('NETWORK', '连接未完成，请检查网络；若正在登录，请重新配对');
    }
  }

  /// Invalidates any in-flight result and drops the in-memory proof.
  void cancel() {
    _generation++;
    _closed = true;
    _verifier = null;
    _pairingId = null;
    _snapshot = null;
    _pollClock.stop();
    _attemptClock.stop();
  }

  void dispose() {
    cancel();
    _client.close();
  }
}

ApiException _invalidResponse() =>
    ApiException('INVALID_RESPONSE', '服务器返回了无效的配对响应');

Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>) throw _invalidResponse();
  return value;
}

String _string(Map<String, dynamic> map, String key, {required int max}) {
  final value = map[key];
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw _invalidResponse();
  }
  return value;
}

DateTime _date(Map<String, dynamic> map) {
  final raw = _string(map, 'expiresAt', max: 40);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !parsed.isUtc) throw _invalidResponse();
  return parsed;
}

String _permission(Map<String, dynamic> map) {
  if (map['permission'] != 'OWNER_FULL_ACCESS') throw _invalidResponse();
  return 'OWNER_FULL_ACCESS';
}
