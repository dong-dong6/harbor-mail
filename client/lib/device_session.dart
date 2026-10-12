import 'dart:async';

import 'api.dart';
import 'device_session_vault.dart';
import 'server_profile.dart';

/// One foreground, unlocked device family. There is no refresh timer: a family
/// advances only on actual API demand or an explicit foreground restoration.
/// Access credentials never enter the vault, which owns the atomic journal.
class DeviceSessionCoordinator implements ApiSessionCoordinator {
  DeviceSessionCoordinator({
    required this.api,
    required this.vault,
    required this.profile,
    DateTime Function()? now,
    this.onChanged,
  }) : _now = now ?? DateTime.now {
    if (api.base != profile.apiBase) {
      throw ArgumentError('Device session requires its exact canonical server');
    }
  }

  final MailApi api;
  final DeviceSessionVault vault;
  final ServerProfile profile;
  final DateTime Function() _now;
  final void Function()? onChanged;
  DeviceSession? _session;
  DeviceSessionMetadata? _metadata;
  String? _accessToken;
  DateTime? _accessExpiresAt;
  String? lastError;
  DateTime? retryAfter;
  int _epoch = 0;
  bool _foreground = true;
  bool _active = false;
  bool _retired = false;
  Future<void>? _refresh;
  static final Expando<Future<void>> _vaultQueues = Expando<Future<void>>();
  String? _pendingLoginFamily;
  Future<void>? _retirementLock;

  @override
  bool get durable => _active;
  @override
  bool get canUseAccess =>
      _active &&
      !_retired &&
      _foreground &&
      _session != null &&
      _hasAccess &&
      api.token == _accessToken;
  @override
  int get epoch => _epoch;
  bool get foreground => _foreground;
  bool get locked => _session == null;
  bool get busy => _refresh != null;
  DeviceSessionMetadata? get metadata => _metadata;

  // Serializing native writes also makes logout wait for earlier journal/save
  // operations before deletion. A delayed save can never resurrect local state.
  Future<T> _withVault<T>(Future<T> Function() action) {
    final result = (_vaultQueues[vault] ?? Future<void>.value()).then(
      (_) => action(),
    );
    _vaultQueues[vault] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  void _notify() => onChanged?.call();

  void _check(
    int generation, {
    bool requireUnlocked = true,
    bool requireForeground = true,
  }) {
    if (_retired ||
        generation != _epoch ||
        !identical(api.deviceSession, this)) {
      throw ApiException('STALE_SESSION', '当前会话已更改，请重新操作');
    }
    if (requireForeground && !_foreground) {
      throw ApiException('APP_BACKGROUND', '请回到应用后继续');
    }
    if (requireUnlocked && _session == null) {
      throw ApiException('DEVICE_LOCKED', '请先解锁此设备');
    }
    if (api.token != _accessToken) {
      throw ApiException('STALE_SESSION', '当前登录已更改，请重新操作');
    }
  }

  DeviceSessionMetadata _describe(DeviceSession value, {bool? biometric}) =>
      DeviceSessionMetadata(
        profile: value.profile,
        accountId: value.accountId,
        familyId: value.familyId,
        idleExpiresAt: value.idleExpiresAt,
        absoluteExpiresAt: value.absoluteExpiresAt,
        biometricEnabled: biometric ?? _metadata?.biometricEnabled ?? false,
      );

  static String _field(
    Map<String, dynamic> value,
    String key,
    int max, {
    bool allowSpaces = false,
  }) {
    final text = value[key];
    if (text is! String ||
        text.isEmpty ||
        text.length > max ||
        RegExp(
          allowSpaces ? r'[\x00-\x1f\x7f]' : r'[\x00-\x20\x7f]',
        ).hasMatch(text)) {
      throw ApiException('INVALID_RESPONSE', '无效的设备登录响应');
    }
    return text;
  }

  static DateTime _date(Map<String, dynamic> value, String key) {
    final date = DateTime.tryParse(_field(value, key, 40));
    if (date == null || !date.isUtc) {
      throw ApiException('INVALID_RESPONSE', '无效的设备登录有效期');
    }
    return date;
  }

  DeviceSession _parse(Map<String, dynamic> value) {
    final now = _now().toUtc();
    final token = _field(value, 'refreshToken', 43);
    final idle = _date(value, 'refreshExpiresAt');
    final absolute = _date(value, 'sessionExpiresAt');
    final expires = _date(value, 'expiresAt');
    if (!RegExp(r'^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$').hasMatch(token) ||
        value['permission'] != 'OWNER_FULL_ACCESS' ||
        !expires.isAfter(now) ||
        expires.isAfter(now.add(const Duration(minutes: 60, seconds: 15))) ||
        !idle.isAfter(now) ||
        !absolute.isAfter(now) ||
        idle.isAfter(absolute) ||
        idle.isAfter(now.add(const Duration(days: 90, seconds: 15))) ||
        absolute.isAfter(now.add(const Duration(days: 730, seconds: 15)))) {
      throw ApiException('INVALID_RESPONSE', '无效的设备登录有效期');
    }
    _field(value, 'accessToken', 8192);
    return DeviceSession(
      profile: profile,
      accountId: _field(value, 'accountName', 320, allowSpaces: true),
      familyId: _field(value, 'deviceId', 128),
      refreshToken: token,
      idleExpiresAt: idle,
      absoluteExpiresAt: absolute,
    );
  }

  void _installAccess(Map<String, dynamic> value) {
    _accessToken = value['accessToken'] as String;
    _accessExpiresAt = _date(value, 'expiresAt');
    api.token = _accessToken;
    api.sessionExpiresAt = _accessExpiresAt;
    api.sessionAccount = _metadata!.accountId;
    api.sessionDeviceId = _metadata!.familyId;
    lastError = null;
    retryAfter = null;
  }

  Future<void> acceptLogin(
    Map<String, dynamic> response, {
    required bool explicitOptIn,
  }) async {
    if (!explicitOptIn) {
      throw ApiException('REMEMBER_DEVICE_REQUIRED', '记住此设备需要明确同意');
    }
    if (_retired || !_foreground) {
      throw ApiException('STALE_SESSION', '本次登录已取消');
    }
    DeviceSession session;
    try {
      session = _parse(response);
    } catch (_) {
      api.clearAccess(notify: false);
      final proof = response['refreshToken'];
      if (proof is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(proof)) {
        try {
          await api.revokeDeviceSession(proof);
        } catch (_) {}
      }
      rethrow;
    }
    final generation = ++_epoch;
    api.deviceSession = this;
    _active = true;
    _accessToken = api.token;
    _pendingLoginFamily = session.familyId;
    try {
      final saved = await _withVault(
        () => vault.save(session, explicitOptIn: true),
      );
      _check(generation, requireUnlocked: false);
      if (saved.state != DeviceVaultState.saved) {
        throw ApiException('VAULT_SAVE_FAILED', '无法安全保存设备登录，请重试');
      }
      _metadata = saved.metadata ?? _describe(session);
    } catch (error) {
      final stillCurrent =
          _epoch == generation && identical(api.deviceSession, this);
      if (stillCurrent) {
        _accessToken = null;
        _accessExpiresAt = null;
        _session = null;
        _active = false;
        api.clearAccess(notify: false);
      }
      final cleared = await _clearFamily(session.familyId);
      // The captured newly issued family is the only remote authority retired.
      // A late failure must never revoke a replacement login's family.
      try {
        await api.revokeDeviceSession(session.refreshToken);
      } catch (_) {}
      if (stillCurrent && cleared.state != DeviceVaultState.empty) {
        lastError = 'VAULT_CLEAR_FAILED';
        _notify();
        throw ApiException('VAULT_CLEAR_FAILED', '无法删除未保存成功的设备凭据，请清除应用数据');
      }
      rethrow;
    } finally {
      if (_pendingLoginFamily == session.familyId) _pendingLoginFamily = null;
    }
    _session = session;
    _active = true;
    _installAccess(response);
    _notify();
  }

  Future<void> restore({
    required String accountId,
    String? expectedFamilyId,
  }) async {
    final expectedFamily = expectedFamilyId ?? _metadata?.familyId;
    if (expectedFamilyId != null &&
        _metadata != null &&
        expectedFamilyId != _metadata!.familyId) {
      throw ApiException('STALE_SESSION', '设备登录已更改，请重新操作');
    }
    if (_retired || !_foreground) {
      throw ApiException('APP_BACKGROUND', '请回到应用后解锁');
    }
    final generation = ++_epoch;
    _refresh = null;
    api.deviceSession = this;
    _active = true;
    _accessToken = null;
    _accessExpiresAt = null;
    api.clearAccess(notify: false);
    final result = await _withVault(
      () => vault.unlock(profile: profile, accountId: accountId),
    );
    _check(generation, requireUnlocked: false);
    final session = result.session;
    if (expectedFamily != null &&
        ((result.metadata != null &&
                result.metadata!.familyId != expectedFamily) ||
            (session != null && session.familyId != expectedFamily))) {
      // A picker/unlock continuation has authority only for its captured family.
      // Preserve a newer same-account encrypted grant without refreshing it.
      await vault.lock();
      _check(generation, requireUnlocked: false);
      lastError = 'STALE_SESSION';
      _notify();
      throw ApiException('STALE_SESSION', '设备登录已更改，请重新操作');
    }
    if (result.state != DeviceVaultState.unlocked || session == null) {
      if (const {
        DeviceVaultState.expired,
        DeviceVaultState.invalidated,
        DeviceVaultState.corrupt,
      }.contains(result.state)) {
        _metadata = result.metadata;
        final code = 'VAULT_${result.state.name.toUpperCase()}';
        await _invalidateGrant(code);
        throw ApiException(code, '保存的设备登录已失效，请重新登录');
      }
      lastError = result.state == DeviceVaultState.canceled
          ? 'DEVICE_LOCKED'
          : 'VAULT_${result.state.name.toUpperCase()}';
      _notify();
      throw ApiException(lastError!, '无法解锁设备登录，请重试或重新登录');
    }
    if (session.profile != profile || session.accountId != accountId) {
      await _invalidateGrant('INVALID_REFRESH');
      throw ApiException('INVALID_REFRESH', '保存的设备登录与当前服务器不匹配');
    }
    _session = session;
    _metadata = result.metadata ?? _describe(session);
    _active = true;
    await ensureAccess();
  }

  @override
  Future<void> ensureAccess({String? rejectedBearer, bool force = false}) {
    final generation = _epoch;
    try {
      _check(generation);
    } on ApiException catch (error) {
      return Future<void>.error(error);
    }
    // Another request may have already replaced the rejected bearer.
    if (rejectedBearer != null &&
        _accessToken != rejectedBearer &&
        _hasAccess) {
      return Future<void>.value();
    }
    if (!force && _hasAccess) return Future<void>.value();
    if (retryAfter != null && retryAfter!.isAfter(_now().toUtc())) {
      return Future<void>.error(
        ApiException(
          'RATE_LIMITED',
          '续期请求过于频繁，请稍后重试',
          retryAfterSeconds:
              retryAfter!.difference(_now().toUtc()).inSeconds + 1,
        ),
      );
    }
    final existing = _refresh;
    if (existing != null) return existing;
    final work = _rotate(generation);
    _refresh = work;
    // Do not use an ignored whenComplete future: failures must not become an
    // extra unhandled asynchronous error after callers handle the shared future.
    unawaited(
      work.then<void>(
        (_) {
          if (identical(_refresh, work)) _refresh = null;
          _notify();
        },
        onError: (Object _, StackTrace __) {
          if (identical(_refresh, work)) _refresh = null;
          _notify();
        },
      ),
    );
    return work;
  }

  bool get _hasAccess =>
      _accessToken != null &&
      _accessExpiresAt != null &&
      _accessExpiresAt!.isAfter(_now().toUtc());

  Future<void> _rotate(int generation) async {
    _check(generation);
    final session = _session!;
    final now = _now().toUtc();
    if (!session.absoluteExpiresAt.isAfter(now) ||
        (session.pending == null && !session.idleExpiresAt.isAfter(now))) {
      await _invalidateGrant('SESSION_EXPIRED');
      throw ApiException('SESSION_EXPIRED', '设备登录已过期，请重新登录');
    }
    try {
      final prepared = await _withVault(
        () => vault.beginRotation(
          profile: profile,
          accountId: session.accountId,
          familyId: session.familyId,
        ),
      );
      _check(generation);
      final pendingSession = prepared.session;
      final pending = pendingSession?.pending;
      if (!prepared.isSuccess ||
          pendingSession == null ||
          pending == null ||
          pendingSession.profile != profile ||
          pendingSession.accountId != session.accountId ||
          pendingSession.familyId != session.familyId ||
          pending.oldRefresh != pendingSession.refreshToken) {
        throw ApiException('VAULT_SAVE_FAILED', '无法安全保存续期请求，请重试');
      }
      _session = pendingSession;
      // beginRotation returns only AFTER durable journal write. An uncertain
      // response preserves this exact old/next/requestId tuple for the next try.
      final response = await api.refreshDeviceSession(
        refreshToken: pending.oldRefresh,
        nextRefreshToken: pending.nextRefresh,
        requestId: pending.requestId,
      );
      _check(generation);
      final next = _parse(response);
      if (next.accountId != session.accountId ||
          next.familyId != session.familyId ||
          next.refreshToken != pending.nextRefresh ||
          next.absoluteExpiresAt != session.absoluteExpiresAt) {
        throw ApiException('INVALID_RESPONSE', '设备登录响应与当前会话不匹配');
      }
      final committed = await _withVault(
        () => vault.commitRotation(
          profile: profile,
          accountId: session.accountId,
          familyId: session.familyId,
          requestId: pending.requestId,
          nextRefresh: pending.nextRefresh,
          idleExpiresAt: next.idleExpiresAt,
          absoluteExpiresAt: next.absoluteExpiresAt,
        ),
      );
      _check(generation);
      if (!committed.isSuccess) {
        throw ApiException('VAULT_SAVE_FAILED', '无法保存续期结果，请重新连接后重试');
      }
      _session = next;
      _metadata = committed.metadata ?? _describe(next);
      _installAccess(response);
      _notify();
    } on ApiException catch (error) {
      // A late response has no authority over a newer server/account/unlock.
      _check(generation);
      if (const {
        'INVALID_REFRESH',
        'INVALID_GRANT',
        'SESSION_REVOKED',
        'SESSION_EXPIRED',
        'REFRESH_REUSED',
        'STALE_ROTATION',
        'INVALID_ROTATION',
      }.contains(error.code)) {
        await _invalidateGrant(error.code);
        rethrow;
      }
      if (error.code == 'RATE_LIMITED') {
        final seconds = (error.retryAfterSeconds ?? 60).clamp(1, 3600);
        retryAfter = _now().toUtc().add(Duration(seconds: seconds));
      }
      if (error.code == 'NETWORK') {
        lastError = 'RECONNECT_REQUIRED';
        _notify();
        throw ApiException('RECONNECT_REQUIRED', '请重新连接网络后重试，设备登录仍已保留');
      }
      lastError = error.code;
      _notify();
      rethrow;
    }
  }

  @override
  Future<void> rejectAccess({
    required String? requestBearer,
    required String code,
  }) async {
    if (!_active || requestBearer == null || requestBearer != api.token) return;
    if (code == 'ACCESS_EXPIRED') {
      // A second typed rejection does not justify a third attempt or revocation.
      _accessToken = null;
      _accessExpiresAt = null;
      api.clearAccess(notify: false);
      lastError = code;
      _notify();
      return;
    }
    await _invalidateGrant(code);
  }

  Future<DeviceVaultResult> _clearFamily(
    String? familyId,
  ) => _withVault(() async {
    final current = await vault.status();
    // Another coordinator may already have saved a replacement family into
    // this single-slot vault. Never delete that newer authenticated credential.
    if (familyId != null &&
        current.metadata != null &&
        current.metadata!.familyId != familyId) {
      return const DeviceVaultResult(DeviceVaultState.empty);
    }
    return vault.clear();
  });

  Future<void> _invalidateGrant(String reason) async {
    final familyId = _metadata?.familyId ?? _session?.familyId;
    final generation = ++_epoch;
    _session = null;
    _accessToken = null;
    _accessExpiresAt = null;
    _active = false;
    _refresh = null;
    lastError = reason;
    api.clearAccess(notify: false);
    final result = await _clearFamily(familyId);
    if (_epoch != generation) return;
    _metadata = null;
    _notify();
    api.onSessionCleared?.call();
    if (result.state != DeviceVaultState.empty) {
      lastError = 'VAULT_CLEAR_FAILED';
      _notify();
      throw ApiException('VAULT_CLEAR_FAILED', '登录已停止，但无法删除本机凭据，请在系统设置中清除应用数据');
    }
  }

  Future<void> setBiometricEnabled(
    bool enabled, {
    required bool explicitOptIn,
  }) async {
    final generation = _epoch;
    _check(generation);
    final result = await _withVault(
      () => vault.setBiometricEnabled(enabled, explicitOptIn: explicitOptIn),
    );
    _check(generation, requireUnlocked: false, requireForeground: false);
    if (!result.isSuccess || result.metadata == null) {
      throw ApiException('VAULT_LOCK_FAILED', '无法更新生物识别保护，请重试');
    }
    _metadata = result.metadata;
    _notify();
  }

  Future<void> setBiometricRequired(bool enabled) =>
      setBiometricEnabled(enabled, explicitOptIn: true);

  /// An owned OS authentication sheet can background the activity. Pause Dart
  /// access without canceling that exact native prompt or authorizing network.
  void pauseForAuthentication() {
    if (_retired) return;
    _foreground = false;
    _session = null;
    _accessToken = null;
    _accessExpiresAt = null;
    api.clearAccess(notify: false);
    _notify();
  }

  /// Called only by the real resumed lifecycle event; no credentials restored.
  void authenticationForeground() {
    if (_retired) return;
    _foreground = true;
    _notify();
  }

  Future<void> suspend() async {
    if (_retired) return;
    _epoch++;
    _foreground = false;
    _session = null;
    _accessToken = null;
    _accessExpiresAt = null;
    _refresh = null;
    api.clearAccess(notify: false);
    _notify();
    await vault.lock();
  }

  Future<void> resume({String? expectedFamilyId}) async {
    if (_retired) throw ApiException('STALE_SESSION', '当前会话已结束');
    _foreground = true;
    if (_session != null) {
      if (expectedFamilyId != null && _session!.familyId != expectedFamilyId) {
        throw ApiException('STALE_SESSION', '设备登录已更改，请重新操作');
      }
      return ensureAccess();
    }
    final account = _metadata?.accountId;
    if (account == null) throw ApiException('DEVICE_LOCKED', '请重新选择设备登录');
    await restore(accountId: account, expectedFamilyId: expectedFamilyId);
  }

  @override
  void invalidate() {
    if (_retired) return;
    _epoch++;
    _retired = true;
    _active = false;
    _foreground = false;
    _session = null;
    _accessToken = null;
    _accessExpiresAt = null;
    _refresh = null;
    if (identical(api.deviceSession, this)) {
      api.deviceSession = null;
      api.clearAccess(notify: false);
      _retirementLock = vault.lock();
      unawaited(_retirementLock!.catchError((Object _) {}));
    }
    _notify();
  }

  Future<void> retire() async {
    invalidate();
    await (_retirementLock ?? vault.lock());
  }

  Future<void> logout({bool revokeRemote = true}) async {
    var proof = _session?.refreshToken;
    final account = _metadata?.accountId;
    final familyId = _metadata?.familyId ?? _pendingLoginFamily;
    invalidate();
    if (revokeRemote && proof == null && account != null) {
      final unlocked = await _withVault(
        () => vault.unlock(profile: profile, accountId: account),
      );
      final recovered = unlocked.session;
      if (unlocked.state == DeviceVaultState.unlocked &&
          recovered != null &&
          familyId != null &&
          recovered.familyId == familyId &&
          recovered.profile == profile &&
          recovered.accountId == account) {
        proof = recovered.refreshToken;
      }
    }
    final cleared = await _clearFamily(familyId);
    _metadata = null;
    ApiException? remoteError;
    if (revokeRemote) {
      if (proof == null) {
        remoteError = ApiException(
          'REMOTE_REVOKE_REQUIRED',
          '本机凭据已删除，请从另一台设备撤销此设备登录',
        );
      } else {
        try {
          await api.revokeDeviceSession(proof);
        } on ApiException catch (error) {
          if (!const {
            'INVALID_REFRESH',
            'SESSION_REVOKED',
            'SESSION_EXPIRED',
          }.contains(error.code)) {
            remoteError = error;
          }
        }
      }
    }
    // Local deletion and remote revocation are independent best-effort cleanup.
    // A disk failure must never prevent the server family from being revoked.
    if (cleared.state != DeviceVaultState.empty) {
      lastError = 'VAULT_CLEAR_FAILED';
      _notify();
      throw ApiException('VAULT_CLEAR_FAILED', '已退出，但无法删除本机凭据，请在系统设置中清除应用数据');
    }
    _notify();
    if (remoteError != null) throw remoteError;
  }
}
