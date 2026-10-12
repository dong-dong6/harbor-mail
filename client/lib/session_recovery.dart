import 'server_profile.dart';
import 'session_vault.dart';

/// Validation must use the recovered bearer on its exact canonical origin,
/// reject redirects, and return rejected for expired/revoked/401 sessions.
/// A timeout/offline server is retryable and must not reveal mailbox content.
enum SessionValidation { accepted, rejected, retryable }

typedef SessionValidator =
    Future<SessionValidation> Function(SavedSession session);

class SessionRecoveryResult {
  const SessionRecoveryResult(this.state, {this.session, this.validation});
  final VaultState state;
  final SavedSession? session;
  final SessionValidation? validation;
}

/// Optional narrow helper for integrations that don't already own generation
/// guards. It never logs in, refreshes, or exposes a token before server check.
class SessionRecovery {
  SessionRecovery(this.vault, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final SessionVault vault;
  final DateTime Function() _now;
  int _generation = 0;
  bool _busy = false;
  bool get busy => _busy;

  Future<SessionRecoveryResult> restoreAndValidate({
    required ServerProfile profile,
    required String accountId,
    required SessionValidator validate,
  }) async {
    if (_busy) return const SessionRecoveryResult(VaultState.busy);
    final generation = ++_generation;
    _busy = true;
    bool current() => generation == _generation;
    try {
      final recovered = await vault.restore(
        profile: profile,
        accountId: accountId,
      );
      if (!current()) return const SessionRecoveryResult(VaultState.canceled);
      final session = recovered.session;
      if (recovered.state != VaultState.restored || session == null) {
        return SessionRecoveryResult(recovered.state);
      }
      if (!session.metadata.matches(profile, accountId)) {
        return SessionRecoveryResult(await _clearAs(VaultState.mismatch));
      }
      if (!_validAtPresent(session)) {
        return SessionRecoveryResult(await _clearAs(VaultState.expired));
      }
      SessionValidation validation;
      try {
        validation = await validate(session);
      } catch (_) {
        validation = SessionValidation.retryable;
      }
      if (!current()) return const SessionRecoveryResult(VaultState.canceled);
      if (!_validAtPresent(session)) {
        return SessionRecoveryResult(await _clearAs(VaultState.expired));
      }
      switch (validation) {
        case SessionValidation.accepted:
          return SessionRecoveryResult(
            VaultState.restored,
            session: session,
            validation: validation,
          );
        case SessionValidation.rejected:
          return SessionRecoveryResult(
            await _clearAs(VaultState.invalidated),
            validation: validation,
          );
        case SessionValidation.retryable:
          return SessionRecoveryResult(
            VaultState.failed,
            validation: validation,
          );
      }
    } catch (_) {
      return SessionRecoveryResult(
        current() ? VaultState.failed : VaultState.canceled,
      );
    } finally {
      if (current()) _busy = false;
    }
  }

  Future<VaultState> _clearAs(VaultState reason) async {
    final result = await vault.clear();
    return result.state == VaultState.empty ? reason : VaultState.failed;
  }

  bool _validAtPresent(SavedSession session) {
    final remaining = session.expiresAt.difference(_now());
    return remaining > Duration.zero &&
        remaining <= PlatformSessionVault.maxLifetime;
  }

  /// Use on logout, switching servers/accounts, or retiring this login flow.
  /// Call clear on logout separately, because cancel intentionally preserves a
  /// saved encrypted token after a user dismisses an unlock prompt.
  Future<void> cancel() async {
    final generation = ++_generation;
    // Do not admit a newer restore until the native cancel request settles.
    _busy = true;
    try {
      await vault.cancel();
    } finally {
      if (generation == _generation) _busy = false;
    }
  }
}
