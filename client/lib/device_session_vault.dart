import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'server_profile.dart';

/// Durable device credentials. Access tokens and passwords never belong here.
class DeviceSession {
  const DeviceSession({
    required this.profile,
    required this.accountId,
    required this.familyId,
    required this.refreshToken,
    required this.idleExpiresAt,
    required this.absoluteExpiresAt,
    this.pending,
  });
  final ServerProfile profile;
  final String accountId;
  final String familyId;
  final String refreshToken;
  final DateTime idleExpiresAt;
  final DateTime absoluteExpiresAt;
  final DeviceRotation? pending;
  @override
  String toString() => 'DeviceSession([redacted])';
}

/// Persisted before sending a refresh. An ambiguous response MUST reuse this
/// exact tuple, even after process death. Never generate a successor in Dart.
class DeviceRotation {
  const DeviceRotation({
    required this.oldRefresh,
    required this.nextRefresh,
    required this.requestId,
  });
  final String oldRefresh;
  final String nextRefresh;
  final String requestId;
  @override
  String toString() => 'DeviceRotation([redacted])';
}

/// Discovery information is unauthenticated until unlock succeeds. It must not
/// select the destination for an authenticated request without user selection.
class DeviceSessionMetadata {
  const DeviceSessionMetadata({
    required this.profile,
    required this.accountId,
    required this.familyId,
    required this.idleExpiresAt,
    required this.absoluteExpiresAt,
    required this.biometricEnabled,
  });
  final ServerProfile profile;
  final String accountId;
  final String familyId;
  final DateTime idleExpiresAt;
  final DateTime absoluteExpiresAt;
  final bool biometricEnabled;
}

enum DeviceVaultState {
  saved,
  unlocked,
  empty,
  canceled,
  unavailable,
  locked,
  lockedOut,
  expired,
  invalidated,
  corrupt,
  mismatch,
  busy,
  failed,
}

class DeviceVaultResult {
  const DeviceVaultResult(this.state, {this.metadata, this.session});
  final DeviceVaultState state;
  final DeviceSessionMetadata? metadata;
  final DeviceSession? session;
  bool get isSuccess =>
      state == DeviceVaultState.saved || state == DeviceVaultState.unlocked;
  @override
  String toString() => 'DeviceVaultResult(${state.name})';
}

abstract interface class DeviceSessionVault {
  bool get supported;
  Future<DeviceVaultResult> status();
  Future<DeviceVaultResult> save(
    DeviceSession session, {
    required bool explicitOptIn,
  });
  Future<DeviceVaultResult> unlock({
    required ServerProfile profile,
    required String accountId,
  });
  Future<DeviceVaultResult> beginRotation({
    required ServerProfile profile,
    required String accountId,
    required String familyId,
  });
  Future<DeviceVaultResult> commitRotation({
    required ServerProfile profile,
    required String accountId,
    required String familyId,
    required String requestId,
    required String nextRefresh,
    required DateTime idleExpiresAt,
    required DateTime absoluteExpiresAt,
  });
  Future<DeviceVaultResult> setBiometricEnabled(
    bool enabled, {
    required bool explicitOptIn,
  });
  Future<DeviceVaultResult> clear();
  Future<void> lock();
  Future<void> cancel();
}

/// Android Keystore envelope encryption + AtomicFile in noBackupFilesDir.
/// Remember-device and OS authentication are separate explicit opt-ins. Default
/// storage is Keystore encrypted; it does NOT claim biometric protection.
class PlatformDeviceSessionVault implements DeviceSessionVault {
  PlatformDeviceSessionVault({
    MethodChannel? channel,
    bool? supported,
    DateTime Function()? now,
  }) : _channel =
           channel ??
           const MethodChannel('dev.harbor.mail/device_session_vault'),
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _now = now ?? DateTime.now;
  final MethodChannel _channel;
  final bool _supported;
  final DateTime Function() _now;
  @override
  bool get supported => _supported;

  @override
  Future<DeviceVaultResult> status() => _call('status');

  @override
  Future<DeviceVaultResult> save(
    DeviceSession session, {
    required bool explicitOptIn,
  }) async {
    if (!explicitOptIn) {
      return const DeviceVaultResult(DeviceVaultState.canceled);
    }
    if (!_validSession(session) || session.pending != null) {
      return const DeviceVaultResult(DeviceVaultState.corrupt);
    }
    return _call('save', {
      ..._binding(session.profile, session.accountId, session.familyId),
      'refreshToken': session.refreshToken,
      'idleExpiresAt': session.idleExpiresAt.toUtc().millisecondsSinceEpoch,
      'absoluteExpiresAt': session.absoluteExpiresAt
          .toUtc()
          .millisecondsSinceEpoch,
      'explicitOptIn': true,
    });
  }

  @override
  Future<DeviceVaultResult> unlock({
    required ServerProfile profile,
    required String accountId,
  }) => _boundCall('unlock', profile, accountId);
  @override
  Future<DeviceVaultResult> beginRotation({
    required ServerProfile profile,
    required String accountId,
    required String familyId,
  }) => _boundCall('beginRotation', profile, accountId, familyId: familyId);
  @override
  Future<DeviceVaultResult> commitRotation({
    required ServerProfile profile,
    required String accountId,
    required String familyId,
    required String requestId,
    required String nextRefresh,
    required DateTime idleExpiresAt,
    required DateTime absoluteExpiresAt,
  }) async {
    if (!_validRefresh(nextRefresh) ||
        !_validRequestId(requestId) ||
        !_validDates(idleExpiresAt, absoluteExpiresAt)) {
      return const DeviceVaultResult(DeviceVaultState.corrupt);
    }
    return _boundCall(
      'commitRotation',
      profile,
      accountId,
      familyId: familyId,
      extra: {
        'requestId': requestId,
        'nextRefresh': nextRefresh,
        'idleExpiresAt': idleExpiresAt.toUtc().millisecondsSinceEpoch,
        'absoluteExpiresAt': absoluteExpiresAt.toUtc().millisecondsSinceEpoch,
      },
    );
  }

  @override
  Future<DeviceVaultResult> setBiometricEnabled(
    bool enabled, {
    required bool explicitOptIn,
  }) async {
    if (!explicitOptIn) {
      return const DeviceVaultResult(DeviceVaultState.canceled);
    }
    return _call('setBiometricEnabled', {
      'enabled': enabled,
      'explicitOptIn': true,
    });
  }

  @override
  Future<DeviceVaultResult> clear() => _call('clear');
  @override
  Future<void> lock() async {
    await _call('lock');
  }

  @override
  Future<void> cancel() async {
    await _call('cancel');
  }

  Future<DeviceVaultResult> _boundCall(
    String method,
    ServerProfile profile,
    String accountId, {
    String? familyId,
    Map<String, Object>? extra,
  }) async {
    if (!_validBinding(profile, accountId, familyId)) {
      return const DeviceVaultResult(DeviceVaultState.mismatch);
    }
    final result = await _call(method, {
      ..._binding(profile, accountId, familyId),
      ...?extra,
    });
    final metadata = result.metadata;
    if (metadata != null &&
        (metadata.profile != profile ||
            metadata.accountId != accountId ||
            (familyId != null && metadata.familyId != familyId))) {
      await lock();
      return const DeviceVaultResult(DeviceVaultState.mismatch);
    }
    return result;
  }

  Future<DeviceVaultResult> _call(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    if (!supported) {
      return const DeviceVaultResult(DeviceVaultState.unavailable);
    }
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        method,
        arguments,
      );
      if (data == null || data['status'] is! String) {
        return const DeviceVaultResult(DeviceVaultState.failed);
      }
      final state = DeviceVaultState.values
          .where((v) => v.name == data['status'])
          .firstOrNull;
      if (state == null) {
        return const DeviceVaultResult(DeviceVaultState.failed);
      }
      DeviceSessionMetadata? metadata;
      if (data['metadata'] != null) {
        final raw = data['metadata'];
        if (raw is! Map ||
            raw['apiBase'] is! String ||
            raw['accountId'] is! String ||
            raw['familyId'] is! String ||
            raw['idleExpiresAt'] is! int ||
            raw['absoluteExpiresAt'] is! int ||
            raw['biometricEnabled'] is! bool) {
          return const DeviceVaultResult(DeviceVaultState.corrupt);
        }
        metadata = DeviceSessionMetadata(
          profile: ServerProfile.parse(raw['apiBase']),
          accountId: raw['accountId'],
          familyId: raw['familyId'],
          idleExpiresAt: DateTime.fromMillisecondsSinceEpoch(
            raw['idleExpiresAt'],
            isUtc: true,
          ),
          absoluteExpiresAt: DateTime.fromMillisecondsSinceEpoch(
            raw['absoluteExpiresAt'],
            isUtc: true,
          ),
          biometricEnabled: raw['biometricEnabled'],
        );
        if (!_validBinding(
              metadata.profile,
              metadata.accountId,
              metadata.familyId,
            ) ||
            !_validDates(metadata.idleExpiresAt, metadata.absoluteExpiresAt)) {
          return const DeviceVaultResult(DeviceVaultState.corrupt);
        }
        if (!metadata.absoluteExpiresAt.isAfter(_now().toUtc())) {
          return const DeviceVaultResult(DeviceVaultState.expired);
        }
      }
      DeviceSession? session;
      if (data['refreshToken'] != null || data['pending'] != null) {
        if (!{
              'unlock',
              'beginRotation',
              'commitRotation',
              'save',
            }.contains(method) ||
            !(state == DeviceVaultState.unlocked ||
                state == DeviceVaultState.saved) ||
            metadata == null ||
            !_validRefresh(data['refreshToken'])) {
          return const DeviceVaultResult(DeviceVaultState.corrupt);
        }
        DeviceRotation? pending;
        if (data['pending'] != null) {
          final raw = data['pending'];
          if (raw is! Map ||
              !_validRefresh(raw['oldRefresh']) ||
              !_validRefresh(raw['nextRefresh']) ||
              !_validRequestId(raw['requestId']) ||
              raw['oldRefresh'] != data['refreshToken'] ||
              raw['oldRefresh'] == raw['nextRefresh']) {
            return const DeviceVaultResult(DeviceVaultState.corrupt);
          }
          pending = DeviceRotation(
            oldRefresh: raw['oldRefresh'],
            nextRefresh: raw['nextRefresh'],
            requestId: raw['requestId'],
          );
        }
        session = DeviceSession(
          profile: metadata.profile,
          accountId: metadata.accountId,
          familyId: metadata.familyId,
          refreshToken: data['refreshToken'],
          idleExpiresAt: metadata.idleExpiresAt,
          absoluteExpiresAt: metadata.absoluteExpiresAt,
          pending: pending,
        );
      }
      if ((state == DeviceVaultState.saved ||
                  state == DeviceVaultState.unlocked) &&
              metadata == null ||
          state == DeviceVaultState.unlocked && session == null ||
          method == 'beginRotation' &&
              state == DeviceVaultState.unlocked &&
              session?.pending == null) {
        return const DeviceVaultResult(DeviceVaultState.corrupt);
      }
      if ((state == DeviceVaultState.unlocked &&
              !{'unlock', 'beginRotation'}.contains(method)) ||
          (state == DeviceVaultState.saved &&
              {'unlock', 'beginRotation'}.contains(method)) ||
          (state == DeviceVaultState.saved &&
              method == 'commitRotation' &&
              session == null)) {
        return const DeviceVaultResult(DeviceVaultState.corrupt);
      }
      return DeviceVaultResult(state, metadata: metadata, session: session);
    } on MissingPluginException {
      return const DeviceVaultResult(DeviceVaultState.unavailable);
    } on PlatformException {
      return const DeviceVaultResult(DeviceVaultState.failed);
    } catch (_) {
      return const DeviceVaultResult(DeviceVaultState.corrupt);
    }
  }

  static Map<String, Object> _binding(ServerProfile p, String a, [String? f]) =>
      {'apiBase': p.apiBase, 'accountId': a, if (f != null) 'familyId': f};
  static bool _validBinding(ServerProfile p, String a, String? f) {
    try {
      return ServerProfile.parse(p.apiBase) == p &&
          a.isNotEmpty &&
          a.length <= 320 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(a) &&
          (f == null || RegExp(r'^[a-zA-Z0-9_-]{16,128}$').hasMatch(f));
    } catch (_) {
      return false;
    }
  }

  static bool _validDates(DateTime idle, DateTime absolute) =>
      idle.millisecondsSinceEpoch > 0 && !idle.isAfter(absolute);
  static bool _validRefresh(dynamic v) =>
      v is String &&
      RegExp(r'^[a-zA-Z0-9_-]{43}$').hasMatch(v) &&
      'AEIMQUYcgkosw048'.contains(v[v.length - 1]);
  static bool _validRequestId(dynamic v) =>
      v is String &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(v);
  static bool _validSession(DeviceSession s) =>
      _validBinding(s.profile, s.accountId, s.familyId) &&
      _validRefresh(s.refreshToken) &&
      _validDates(s.idleExpiresAt, s.absoluteExpiresAt);
}
