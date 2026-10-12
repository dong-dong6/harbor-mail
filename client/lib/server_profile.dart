import 'dart:convert';

/// Non-secret runtime connection details. Never contains login credentials.
class ServerProfile {
  const ServerProfile._(this.apiBase, this.origin);

  final String apiBase;
  final String origin;

  /// Pairing destinations must be explicit, unambiguous TLS origins.
  /// HTTP is available only to callers explicitly opting into loopback demos.
  factory ServerProfile.parse(String value, {bool allowLoopbackHttp = false}) {
    const invalid = FormatException('服务器地址必须是 HTTPS 地址并以 /api/v1 结尾');
    if (value.isEmpty ||
        value.length > 2048 ||
        RegExp(r'[^\x21-\x7e]').hasMatch(value) ||
        value.contains('\\') ||
        value.contains('%') ||
        value.contains('?') ||
        value.contains('#') ||
        value.contains('@')) {
      throw invalid;
    }
    final match = RegExp(
            r'^(https?)://(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?/api/v1$')
        .firstMatch(value);
    if (match == null) throw invalid;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) throw invalid;
    final port = match.group(3);
    if (port != null &&
        (!RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(port) ||
            int.parse(port) > 65535)) {
      throw invalid;
    }
    final host = uri.host.toLowerCase();
    if (!host.contains(':')) {
      if (host.length > 253 ||
          host.split('.').any((label) =>
              label.isEmpty ||
              label.length > 63 ||
              !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label))) {
        throw invalid;
      }
      // Numeric hosts must use four canonical decimal octets. Reject legacy
      // short, octal, integer and hexadecimal address interpretation.
      if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
        final parts = host.split('.');
        if (parts.length != 4 ||
            parts.any((part) =>
                !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part) ||
                int.parse(part) > 255)) {
          throw invalid;
        }
      } else if (RegExp(r'(^|\.)0x[0-9a-f]+($|\.)').hasMatch(host)) {
        throw invalid;
      }
    }
    final isLoopback = host == 'localhost' ||
        host == '::1' ||
        (RegExp(r'^127\.[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(host));
    if (uri.scheme != 'https' && !(allowLoopbackHttp && isLoopback)) {
      throw invalid;
    }
    return ServerProfile._('${uri.origin}/api/v1', uri.origin);
  }

  @override
  bool operator ==(Object other) =>
      other is ServerProfile && apiBase == other.apiBase;

  @override
  int get hashCode => apiBase.hashCode;

  @override
  String toString() => apiBase;
}

/// A QR contains only a short-lived claim secret, never a login credential.
class PairingQr {
  const PairingQr._(this.profile, this.pairingId, this.secret);

  final ServerProfile profile;
  final String pairingId;
  final String secret;

  static const maxPayloadBytes = 4096;

  factory PairingQr.parse(String raw, {bool allowLoopbackHttp = false}) {
    const invalid = FormatException('这不是有效的泊信设备配对二维码');
    if (raw.isEmpty ||
        raw.length > maxPayloadBytes ||
        utf8.encode(raw).length > maxPayloadBytes) {
      throw invalid;
    }
    dynamic data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      throw invalid;
    }
    const fields = {'type', 'version', 'serverUrl', 'pairingId', 'secret'};
    if (data is! Map<String, dynamic> ||
        data.length != fields.length ||
        !data.keys.toSet().containsAll(fields) ||
        data['type'] != 'harbor-mail-device-pairing' ||
        data['version'] is! int ||
        data['version'] != 1 ||
        data['serverUrl'] is! String ||
        data['pairingId'] is! String ||
        data['secret'] is! String) {
      throw invalid;
    }
    // Every field is scalar. Count JSON object keys before decoding so a
    // duplicate key cannot quietly override the destination or claim secret.
    final keyMatches = RegExp(r'"(?:[^"\\]|\\.)*"\s*:').allMatches(raw);
    if (keyMatches.length != fields.length) throw invalid;
    final id = data['pairingId'] as String;
    final secret = data['secret'] as String;
    if (!RegExp(r'^[a-zA-Z0-9_-]{16,128}$').hasMatch(id) ||
        !RegExp(r'^[a-zA-Z0-9_-]{43,128}$').hasMatch(secret)) {
      throw invalid;
    }
    return PairingQr._(
      ServerProfile.parse(data['serverUrl'],
          allowLoopbackHttp: allowLoopbackHttp),
      id,
      secret,
    );
  }

  // Deliberately do not expose the secret from toString/debug output.
  @override
  String toString() => 'PairingQr(${profile.origin})';
}
