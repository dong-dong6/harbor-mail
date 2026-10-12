import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'server_profile.dart';

/// No passwords, refresh credentials, biometrics, or renewed expiry belong here.
/// This value must come from an existing successful server authentication.
class SavedSession {
  const SavedSession({
    required this.token,
    required this.profile,
    required this.accountId,
    required this.expiresAt,
  });

  final String token;
  final ServerProfile profile;

  /// Authenticated owner username/accountName, not a mailbox account ID.
  final String accountId;

  /// The original server-issued expiration. Never replace with now + duration.
  final DateTime expiresAt;

  VaultMetadata get metadata => VaultMetadata(
    profile: profile,
    accountId: accountId,
    expiresAt: expiresAt,
  );

  @override
  String toString() => 'SavedSession([redacted])';
}

/// Discovery metadata is untrusted until native AEAD authentication succeeds.
/// It may label a restore card; never use it to make authenticated requests.
class VaultMetadata {
  const VaultMetadata({
    required this.profile,
    required this.accountId,
    required this.expiresAt,
  });

  final ServerProfile profile;
  final String accountId;
  final DateTime expiresAt;

  bool matches(ServerProfile expectedProfile, String expectedAccountId) =>
      profile == expectedProfile && accountId == expectedAccountId;

  Map<String, Object> toMap() => {
    'apiBase': profile.apiBase,
    'accountId': accountId,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
  };
}

enum VaultState {
  ready,
  saved,
  restored,
  empty,
  canceled,
  unavailable,
  lockedOut,
  expired,
  invalidated,
  corrupt,
  mismatch,
  busy,
  failed,
}

class VaultResult {
  const VaultResult(this.state, {this.metadata, this.session});
  final VaultState state;
  final VaultMetadata? metadata;

  /// Only restore can return a token, and only after native OS authentication.
  /// A restored token still requires server validation before displaying mail.
  final SavedSession? session;
}

typedef VaultStatus = VaultResult;

abstract interface class SessionVault {
  bool get supported;
  Future<VaultStatus> status();
  Future<VaultResult> save(SavedSession session, {required bool explicitOptIn});
  Future<VaultResult> restore({
    required ServerProfile profile,
    required String accountId,
  });
  Future<VaultResult> clear();
  Future<void> cancel();
}

/// Android 11+ uses a native AndroidKeyStore auth-per-use AES-GCM operation.
/// This does not wrap a software key in a separate local_auth boolean check.
class PlatformSessionVault implements SessionVault {
  PlatformSessionVault({
    MethodChannel? channel,
    bool? supported,
    DateTime Function()? now,
  }) : _channel =
           channel ?? const MethodChannel('dev.harbor.mail/session_vault'),
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _now = now ?? DateTime.now;

  final MethodChannel _channel;
  final bool _supported;
  final DateTime Function() _now;
  static const maxLifetime = Duration(hours: 8);

  @override
  bool get supported => _supported;

  @override
  Future<VaultStatus> status() => _call('status');

  @override
  Future<VaultResult> save(
    SavedSession session, {
    required bool explicitOptIn,
  }) async {
    if (!explicitOptIn) return const VaultResult(VaultState.canceled);
    if (!_validMetadata(session.metadata) || !_validToken(session.token)) {
      return const VaultResult(VaultState.corrupt);
    }
    if (!_withinLifetime(session.expiresAt)) {
      return const VaultResult(VaultState.expired);
    }
    return _call('save', {
      ...session.metadata.toMap(),
      'token': session.token,
      'explicitOptIn': true,
    });
  }

  @override
  Future<VaultResult> restore({
    required ServerProfile profile,
    required String accountId,
  }) async {
    try {
      if (ServerProfile.parse(profile.apiBase) != profile ||
          !_validAccount(accountId)) {
        return const VaultResult(VaultState.mismatch);
      }
    } catch (_) {
      return const VaultResult(VaultState.mismatch);
    }
    final result = await _call('restore', {
      'apiBase': profile.apiBase,
      'accountId': accountId,
    });
    if (result.state == VaultState.restored &&
        !(result.session?.metadata.matches(profile, accountId) ?? false)) {
      await clear();
      return const VaultResult(VaultState.mismatch);
    }
    return result;
  }

  @override
  Future<VaultResult> clear() => _call('clear');

  @override
  Future<void> cancel() async {
    await _call('cancel');
  }

  Future<VaultResult> _call(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    if (!supported) return const VaultResult(VaultState.unavailable);
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        method,
        arguments,
      );
      if (data == null || data['status'] is! String) {
        return const VaultResult(VaultState.failed);
      }
      final state = VaultState.values
          .where((value) => value.name == data['status'])
          .firstOrNull;
      if (state == null) return const VaultResult(VaultState.failed);
      VaultMetadata? metadata;
      if (data['metadata'] != null) {
        final raw = data['metadata'];
        if (raw is! Map ||
            raw['apiBase'] is! String ||
            raw['accountId'] is! String ||
            raw['expiresAt'] is! int) {
          return const VaultResult(VaultState.corrupt);
        }
        metadata = VaultMetadata(
          profile: ServerProfile.parse(raw['apiBase']),
          accountId: raw['accountId'],
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
            raw['expiresAt'],
            isUtc: true,
          ),
        );
        if (!_validMetadata(metadata)) {
          return const VaultResult(VaultState.corrupt);
        }
        if (!_withinLifetime(metadata.expiresAt)) {
          return const VaultResult(VaultState.expired);
        }
      }
      // Only this method/status pair may surface a bearer to the application.
      if (state == VaultState.restored) {
        if (method != 'restore' ||
            metadata == null ||
            !_validToken(data['token'])) {
          return const VaultResult(VaultState.corrupt);
        }
        return VaultResult(
          state,
          metadata: metadata,
          session: SavedSession(
            token: data['token'],
            profile: metadata.profile,
            accountId: metadata.accountId,
            expiresAt: metadata.expiresAt,
          ),
        );
      }
      if (state == VaultState.saved && metadata == null) {
        return const VaultResult(VaultState.corrupt);
      }
      return VaultResult(state, metadata: metadata);
    } on MissingPluginException {
      return const VaultResult(VaultState.unavailable);
    } on PlatformException {
      return const VaultResult(VaultState.failed);
    } catch (_) {
      // Neither platform errors nor debug descriptions include token material.
      return const VaultResult(VaultState.corrupt);
    }
  }

  bool _withinLifetime(DateTime expiry) {
    final remaining = expiry.difference(_now().toUtc());
    return remaining > Duration.zero && remaining <= maxLifetime;
  }

  static bool _validMetadata(VaultMetadata metadata) {
    try {
      return _validAccount(metadata.accountId) &&
          ServerProfile.parse(metadata.profile.apiBase) == metadata.profile;
    } catch (_) {
      return false;
    }
  }

  static bool _validAccount(dynamic value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 320 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
  static bool _validToken(dynamic value) =>
      value is String &&
      value.length >= 16 &&
      value.length <= 8192 &&
      !RegExp(r'[^\x21-\x7e]').hasMatch(value);
}
