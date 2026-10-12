import 'dart:async';

import 'package:flutter/material.dart';

import 'local_unlock_authenticator.dart';
export 'local_unlock_authenticator.dart';

/// An opt-in, memory-only display/input lock for an already authenticated
/// session. This is not server authentication or encrypted token storage.
class LocalUnlockController extends ChangeNotifier {
  LocalUnlockController({LocalUnlockAuthenticator? authenticator})
    : _authenticator = authenticator ?? PlatformLocalUnlockAuthenticator();

  final LocalUnlockAuthenticator _authenticator;
  Object? _session;
  bool _enabled = false;
  bool _locked = false;
  bool _busy = false;
  bool _canceling = false;
  bool _disposed = false;
  bool _foreground = true;
  AppLifecycleState? _lifecycle;
  int _generation = 0;
  int? _verifiedOnResume;
  String? _message;

  /// Platform support, before probing OS enrollment/availability.
  bool get supported => _authenticator.supported;
  bool get hasSession => _session != null;
  bool get enabled => _enabled;
  bool get locked => _locked;
  bool get busy => _busy || _canceling;
  String? get message => _message;

  /// Use a fresh opaque Object after each server login/pairing and null on
  /// logout/expiry. Never use this to create or restore a server session.
  void attachSession(Object? sessionIdentity) {
    if (_disposed || identical(_session, sessionIdentity)) return;
    _invalidateVerification();
    _session = sessionIdentity;
    _enabled = false;
    _locked = false;
    _message = null;
    _notify();
  }

  /// On supported, configured devices, enabling immediately shields the
  /// session and verifies the user. A canceled/failed attempt remains locked;
  /// retry or sign out instead of exposing the session without verification.
  Future<bool> enable() async {
    if (_disposed || !hasSession || busy || _enabled) return false;
    if (!supported) {
      _message = '此平台暂不支持本地解锁，请使用正常登录。';
      _notify();
      return false;
    }
    if (!_foreground) return false;
    final generation = _generation;
    _busy = true;
    _message = null;
    _notify();
    try {
      final available = await _authenticator.isAvailable();
      if (!_isCurrent(generation)) return false;
      if (!available) {
        _message = '系统验证不可用，请先在系统设置中配置指纹、设备密码或 Windows Hello。';
        return false;
      }
      if (!_foreground) {
        _message = '请返回应用后再启用本地锁定。';
        return false;
      }
      _enabled = true;
      _locked = true;
      _notify();
      return await _verify(generation);
    } catch (_) {
      if (_isCurrent(generation)) _message = _failureMessage;
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// May only be disabled from a verified, foreground session.
  bool disable() {
    if (_disposed || _locked || busy || !_foreground) return false;
    _invalidateVerification();
    _enabled = false;
    _message = null;
    _notify();
    return true;
  }

  void lock() {
    if (_disposed || !_enabled || !hasSession) return;
    _invalidateVerification();
    _locked = true;
    _message = null;
    _notify();
  }

  Future<bool> unlock() async {
    if (_disposed ||
        !_enabled ||
        !_locked ||
        !hasSession ||
        busy ||
        !_foreground) {
      return false;
    }
    final generation = _generation;
    _busy = true;
    _message = null;
    _notify();
    try {
      return await _verify(generation);
    } catch (_) {
      if (_isCurrent(generation)) _message = _failureMessage;
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  static const _failureMessage = '系统验证未完成。请重试，或退出后重新登录服务器。';

  Future<bool> _verify(int generation) async {
    final result = await _authenticator.authenticate();
    if (!_isCurrent(generation)) return false;
    switch (result) {
      case LocalUnlockResult.verified:
        if (_foreground) {
          _locked = false;
          _message = null;
        } else {
          // The OS dialog can temporarily remove input focus. Wait until the
          // app is resumed before showing content. A real background event,
          // explicit lock, logout, or a session change invalidates this grant.
          _verifiedOnResume = generation;
          _message = '验证已完成，返回应用后解锁。';
        }
        return true;
      case LocalUnlockResult.canceled:
        _message = '已取消验证，当前会话仍已锁定。可重试或退出后重新登录。';
      case LocalUnlockResult.lockedOut:
        _message = '系统验证暂时锁定。请稍后重试，或退出后重新登录服务器。';
      case LocalUnlockResult.unavailable:
        _message = '系统验证不可用。请检查系统设置，或退出后重新登录服务器。';
      case LocalUnlockResult.failed:
        _message = _failureMessage;
    }
    return false;
  }

  /// Called by LocalUnlockGate; public for deterministic lifecycle tests.
  void handleLifecycleState(AppLifecycleState state) {
    if (_disposed || _lifecycle == state) return;
    _lifecycle = state;
    _foreground = state == AppLifecycleState.resumed;
    switch (state) {
      case AppLifecycleState.resumed:
        if (_verifiedOnResume == _generation && _enabled && hasSession) {
          _locked = false;
          _verifiedOnResume = null;
          _message = null;
        }
      case AppLifecycleState.inactive:
        // Native verification dialogs also cause inactive. Do not cancel
        // those just for losing focus, but never reveal content meanwhile.
        if (_enabled && hasSession) _locked = true;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _invalidateVerification();
        if (_enabled && hasSession) {
          _locked = true;
          _message = '当前会话已锁定，请重新验证。';
        }
    }
    _notify();
  }

  bool _isCurrent(int generation) =>
      !_disposed && hasSession && generation == _generation;

  void _invalidateVerification() {
    _generation++;
    _verifiedOnResume = null;
    if (_busy && !_canceling) {
      _canceling = true;
      unawaited(_cancelSafely());
    }
  }

  Future<void> _cancelSafely() async {
    try {
      await _authenticator.cancel();
    } catch (_) {
      // Injected adapters may throw too. Generation checks remain decisive.
    } finally {
      // A slow native stop must not race with and cancel a newer prompt.
      _canceling = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidateVerification();
    super.dispose();
  }
}

/// Keep this above every protected route/overlay. Descendants stay mounted
/// while locked, preserving unsaved editors but removing rendering, semantics,
/// focus, keyboard input, pointer input, and tickers. Existing routes outside
/// this subtree are the integrating application's responsibility.
class LocalUnlockGate extends StatefulWidget {
  const LocalUnlockGate({
    super.key,
    required this.controller,
    required this.onSignOut,
    required this.child,
  });

  final LocalUnlockController controller;
  final VoidCallback onSignOut;
  final Widget child;

  @override
  State<LocalUnlockGate> createState() => _LocalUnlockGateState();
}

class _LocalUnlockGateState extends State<LocalUnlockGate>
    with WidgetsBindingObserver {
  final _protectedFocus = FocusScopeNode(debugLabel: 'LocalUnlockProtected');
  bool _confirmSignOut = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(LocalUnlockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  void _changed() {
    if (widget.controller.locked) _protectedFocus.unfocus();
    if (!widget.controller.locked) _confirmSignOut = false;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.handleLifecycleState(state);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    _protectedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final locked = controller.locked;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: locked,
          child: ExcludeSemantics(
            excluding: locked,
            child: ExcludeFocus(
              excluding: locked,
              child: IgnorePointer(
                ignoring: locked,
                child: TickerMode(
                  enabled: !locked,
                  child: FocusScope(node: _protectedFocus, child: widget.child),
                ),
              ),
            ),
          ),
        ),
        if (locked)
          PopScope(
            canPop: false,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline, size: 44),
                          const SizedBox(height: 16),
                          Text(
                            '泊信已锁定',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '使用系统指纹、设备密码或 Windows Hello 解锁当前会话。'
                            '这是本地锁定，不会延长服务器会话；完全关闭应用后仍需重新登录。',
                            textAlign: TextAlign.center,
                          ),
                          if (controller.message != null) ...[
                            const SizedBox(height: 12),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                controller.message!,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            key: const ValueKey('local-unlock-retry'),
                            onPressed: controller.busy
                                ? null
                                : () => unawaited(controller.unlock()),
                            icon: controller.busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.fingerprint),
                            label: Text(controller.busy ? '正在验证…' : '验证并解锁'),
                          ),
                          const SizedBox(height: 8),
                          if (_confirmSignOut) ...[
                            const Text(
                              '退出会丢弃尚未保存的编辑，并清除本次登录。确认退出？',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 12,
                              children: [
                                TextButton(
                                  key: const ValueKey('local-unlock-stay'),
                                  onPressed: () =>
                                      setState(() => _confirmSignOut = false),
                                  child: const Text('继续锁定'),
                                ),
                                FilledButton(
                                  key: const ValueKey(
                                    'local-unlock-confirm-signout',
                                  ),
                                  onPressed: () {
                                    setState(() => _confirmSignOut = false);
                                    widget.onSignOut();
                                  },
                                  child: const Text('确认退出'),
                                ),
                              ],
                            ),
                          ] else
                            TextButton(
                              key: const ValueKey('local-unlock-signout'),
                              onPressed: () =>
                                  setState(() => _confirmSignOut = true),
                              child: const Text('退出并重新登录'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
