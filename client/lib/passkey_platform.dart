import 'dart:async';

import 'package:flutter/services.dart';
import 'package:passkeys/authenticator.dart' as plugin;
import 'package:passkeys/exceptions.dart' as plugin_errors;
import 'package:passkeys/types.dart';

import 'api.dart';
import 'passkey_api.dart';

/// Inject a synthetic implementation in tests. Never emulate authenticator
/// cryptography in application code; the OS/browser owns the private keys.
abstract interface class PasskeyAuthenticator {
  Future<Map<String, dynamic>> register(Map<String, dynamic> publicKey);
  Future<Map<String, dynamic>> authenticate(Map<String, dynamic> publicKey);
  Future<void> cancel();
}

class PluginPasskeyAuthenticator implements PasskeyAuthenticator {
  // Lazy construction lets unsupported targets display the fallback UI safely.
  plugin.PasskeyAuthenticator? _plugin;
  plugin.PasskeyAuthenticator get _authenticator =>
      _plugin ??= plugin.PasskeyAuthenticator(debugMode: false);

  @override
  Future<Map<String, dynamic>> register(Map<String, dynamic> publicKey) => _run(
    () async => (await _authenticator.register(
      RegisterRequestType.fromJson(publicKey),
    )).toJson(),
  );

  @override
  Future<Map<String, dynamic>> authenticate(Map<String, dynamic> publicKey) =>
      _run(
        () async => (await _authenticator.authenticate(
          AuthenticateRequestType.fromJson(
            publicKey,
            mediation: MediationType.Required,
            preferImmediatelyAvailableCredentials: false,
          ),
        )).toJson(),
      );

  Future<Map<String, dynamic>> _run(
    Future<Map<String, dynamic>> Function() operation,
  ) async {
    try {
      return await operation();
    } on plugin_errors.PasskeyAuthCancelledException {
      throw ApiException('PASSKEY_CANCELLED', '已取消通行密钥操作');
    } on plugin_errors.NoCredentialsAvailableException {
      throw ApiException('PASSKEY_NOT_FOUND', '没有可用的通行密钥，请使用密码登录');
    } on plugin_errors.ExcludeCredentialsCanNotBeRegisteredException {
      throw ApiException('PASSKEY_EXISTS', '此通行密钥已经添加');
    } on plugin_errors.DomainNotAssociatedException {
      throw ApiException('PASSKEY_UNAVAILABLE', '此设备尚未与服务器建立可信关联');
    } on plugin_errors.DeviceNotSupportedException {
      throw ApiException('PASSKEY_UNAVAILABLE', '此系统不支持通行密钥');
    } on plugin_errors.PasskeyUnsupportedException {
      throw ApiException('PASSKEY_UNAVAILABLE', '此系统不支持通行密钥');
    } on MissingPluginException {
      throw ApiException('PASSKEY_UNAVAILABLE', '此平台暂不支持通行密钥');
    } catch (_) {
      // Plugin/DOM exceptions may include credential data. Never log or display.
      throw ApiException('PASSKEY_FAILED', '通行密钥操作未完成或已取消');
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _plugin?.cancelCurrentAuthenticatorOperation();
    } catch (_) {
      // Some platforms cannot dismiss an OS sheet. Flow guards discard results.
    }
  }
}

/// Explicit user-gesture flow. No background authentication, retries, restore
/// credentials, saved assertions, or mutation of MailApi.token.
class PasskeyFlow {
  PasskeyFlow(this.api, {PasskeyAuthenticator? authenticator})
    : authenticator = authenticator ?? PluginPasskeyAuthenticator();
  final PasskeyApi api;
  final PasskeyAuthenticator authenticator;
  int _generation = 0;
  bool _busy = false, _disposed = false;
  bool get busy => _busy;

  Future<PasskeySession> authenticate({
    bool Function()? isCurrent,
    bool rememberDevice = false,
    String? deviceName,
  }) async {
    final sessionCurrent = api.mailApi.captureSessionGuard();
    return _perform((check) async {
      final options = await api.authenticationOptions(
        rememberDevice: rememberDevice,
        deviceName: deviceName,
      );
      check();
      final credential = await authenticator.authenticate(options.publicKey);
      check();
      final result = await api.verifyAuthentication(options, credential);
      try {
        check();
      } catch (_) {
        if (result.refreshToken != null) {
          try {
            await api.mailApi.revokeDeviceSession(result.refreshToken!);
          } catch (_) {}
        }
        rethrow;
      }
      return result;
    }, isCurrent: () => sessionCurrent() && (isCurrent?.call() ?? true));
  }

  Future<PasskeyEntry> register({
    required String password,
    required String name,
    bool Function()? isCurrent,
  }) async {
    final token = api.mailApi.token;
    final sessionCurrent = api.mailApi.captureSessionGuard();
    if (token == null || token.isEmpty) {
      throw ApiException('UNAUTHORIZED', '请重新登录');
    }
    return _perform((check) async {
      final options = await api.registrationOptions(
        password: password,
        name: name,
        bearer: token,
      );
      check();
      final credential = await authenticator.register(options.publicKey);
      check();
      final result = await api.verifyRegistration(
        options,
        credential,
        bearer: token,
      );
      check();
      return result;
    }, isCurrent: () => sessionCurrent() && (isCurrent?.call() ?? true));
  }

  Future<T> _perform<T>(
    Future<T> Function(void Function()) operation, {
    required bool Function() isCurrent,
  }) async {
    if (_disposed || _busy) throw ApiException('PASSKEY_BUSY', '请等待本次操作结束');
    _busy = true;
    final generation = ++_generation;
    final clock = Stopwatch()..start();
    void check() {
      if (_disposed || generation != _generation || !isCurrent()) {
        throw ApiException('PASSKEY_CANCELLED', '本次通行密钥操作已取消');
      }
      if (clock.elapsed >= const Duration(seconds: 120)) {
        throw ApiException('PASSKEY_EXPIRED', '本次通行密钥请求已过期');
      }
    }

    try {
      check();
      return await operation(check).timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          cancel();
          throw ApiException('PASSKEY_EXPIRED', '本次通行密钥请求已过期');
        },
      );
    } finally {
      _busy = false;
      clock.stop();
    }
  }

  void cancel() {
    _generation++;
    unawaited(authenticator.cancel().catchError((Object _) {}));
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}

String passkeyErrorMessage(Object error) {
  final code = error is ApiException ? error.code : '';
  return switch (code) {
    'PASSKEY_CANCELLED' => '已取消通行密钥操作。',
    'PASSKEY_EXPIRED' => '请求已过期，请重新开始。',
    'PASSKEY_NOT_FOUND' => '没有可用的通行密钥，请使用密码登录。',
    'PASSKEY_EXISTS' || 'PASSKEY_ALREADY_REGISTERED' => '此通行密钥已经添加。',
    'PASSKEY_UNAVAILABLE' => '此设备或服务器尚未配置通行密钥，请使用密码登录。',
    'UNAUTHORIZED' || 'HTTP_401' => '会话已失效，请重新登录。',
    'INVALID_PASSWORD' ||
    'BAD_CREDENTIALS' ||
    'REAUTHENTICATION_FAILED' => '密码验证失败，请核对当前账户密码。',
    'FORBIDDEN' ||
    'HTTP_403' ||
    'OWNER_SESSION_REQUIRED' ||
    'BROWSER_SESSION_REQUIRED' => '请使用密码登录的账户会话管理通行密钥。',
    'RATE_LIMITED' || 'HTTP_429' || 'TOO_MANY_REQUESTS' => '请求过于频繁，请稍后再试。',
    'NETWORK' => '无法确认服务器是否完成操作。请刷新列表或使用密码登录，本次操作不会自动重试。',
    'PASSKEY_RP_MISMATCH' => '通行密钥域名与所选服务器不一致，已停止系统验证。',
    'API_REDIRECT' => '服务器尝试重定向，已停止连接。请核对服务器地址。',
    _ => '通行密钥操作未完成或已取消。你仍可使用密码登录。',
  };
}
