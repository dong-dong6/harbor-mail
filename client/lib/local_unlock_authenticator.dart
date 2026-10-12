import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Local user verification only. This API never accepts or creates a server
/// credential, and does not store biometric information or session tokens.
abstract interface class LocalUnlockAuthenticator {
  bool get supported;
  Future<bool> isAvailable();
  Future<LocalUnlockResult> authenticate();
  Future<void> cancel();
}

enum LocalUnlockResult { verified, canceled, unavailable, lockedOut, failed }

/// Uses the operating system's verification prompt on Android and Windows.
/// Android may use enrolled biometrics or device credentials. Windows Hello
/// chooses the verification method, including PIN; biometric-only cannot be
/// required by the Windows API. Other platforms (including Web) stay disabled.
class PlatformLocalUnlockAuthenticator implements LocalUnlockAuthenticator {
  PlatformLocalUnlockAuthenticator({
    LocalAuthentication? localAuthentication,
    TargetPlatform? platform,
    bool? isWeb,
  }) : _authentication = localAuthentication ?? LocalAuthentication(),
       _platform = platform ?? defaultTargetPlatform,
       _isWeb = isWeb ?? kIsWeb;

  final LocalAuthentication _authentication;
  final TargetPlatform _platform;
  final bool _isWeb;

  @override
  bool get supported =>
      !_isWeb &&
      (_platform == TargetPlatform.android ||
          _platform == TargetPlatform.windows);

  @override
  Future<bool> isAvailable() async {
    if (!supported) return false;
    try {
      return await _authentication.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<LocalUnlockResult> authenticate() async {
    if (!supported) return LocalUnlockResult.unavailable;
    try {
      final verified = await _authentication.authenticate(
        localizedReason: '验证身份以解锁泊信当前会话',
        biometricOnly: false,
        sensitiveTransaction: true,
        // The controller cancels real background transitions and requires a
        // fresh explicit attempt. The plugin must not silently retry later.
        persistAcrossBackgrounding: false,
      );
      return verified ? LocalUnlockResult.verified : LocalUnlockResult.canceled;
    } on LocalAuthException catch (error) {
      switch (error.code) {
        case LocalAuthExceptionCode.userCanceled:
        case LocalAuthExceptionCode.systemCanceled:
        case LocalAuthExceptionCode.userRequestedFallback:
        case LocalAuthExceptionCode.timeout:
          return LocalUnlockResult.canceled;
        case LocalAuthExceptionCode.temporaryLockout:
        case LocalAuthExceptionCode.biometricLockout:
          return LocalUnlockResult.lockedOut;
        case LocalAuthExceptionCode.noCredentialsSet:
        case LocalAuthExceptionCode.noBiometricsEnrolled:
        case LocalAuthExceptionCode.noBiometricHardware:
        case LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable:
        case LocalAuthExceptionCode.uiUnavailable:
          return LocalUnlockResult.unavailable;
        default:
          return LocalUnlockResult.failed;
      }
    } catch (_) {
      // Includes unsupported/missing plugin and future platform error codes.
      // Never turn a platform failure into an unlocked application.
      return LocalUnlockResult.failed;
    }
  }

  @override
  Future<void> cancel() async {
    if (!supported) return;
    try {
      await _authentication.stopAuthentication();
    } catch (_) {
      // Cancellation is best effort. The controller separately invalidates
      // the pending result, including on platforms unable to stop a prompt.
    }
  }
}
