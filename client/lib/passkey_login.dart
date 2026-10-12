import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'passkey_api.dart';
import 'passkey_platform.dart';

/// Call [acquireApi] only on the explicit button press so native server edits
/// are validated by the parent. A successful result never installs its token.
class PasskeyLoginButton extends StatefulWidget {
  const PasskeyLoginButton({
    super.key,
    this.api,
    this.acquireApi,
    required this.onAuthenticated,
    this.authenticator,
    this.isCurrent,
    this.enabled = true,
    this.contextKey,
    this.onBusyChanged,
    this.rememberDevice = false,
    this.deviceName,
    this.onCancelled,
  }) : assert(api != null || acquireApi != null);
  final MailApi? api;
  final Future<MailApi> Function()? acquireApi;
  final FutureOr<void> Function(MailApi api, PasskeySession session)
  onAuthenticated;
  final PasskeyAuthenticator? authenticator;
  final bool Function()? isCurrent;
  final bool enabled, rememberDevice;
  final String? deviceName;
  final VoidCallback? onCancelled;

  /// Change when server text, account, or navigation changes.
  final Object? contextKey;
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<PasskeyLoginButton> createState() => _PasskeyLoginButtonState();
}

class _PasskeyLoginButtonState extends State<PasskeyLoginButton> {
  PasskeyFlow? _flow;
  bool _busy = false;
  int _generation = 0;
  String _error = '';

  @override
  void didUpdateWidget(covariant PasskeyLoginButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.contextKey != widget.contextKey ||
        oldWidget.authenticator != widget.authenticator ||
        oldWidget.rememberDevice != widget.rememberDevice ||
        oldWidget.deviceName != widget.deviceName) {
      final wasBusy = _busy;
      if (wasBusy) widget.onCancelled?.call();
      _invalidate();
      _error = '';
      if (wasBusy) {
        final generation = _generation;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation && !_busy) {
            widget.onBusyChanged?.call(false);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _flow?.dispose();
    super.dispose();
  }

  void _invalidate() {
    _generation++;
    _flow?.dispose();
    _flow = null;
    _busy = false;
  }

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      (widget.isCurrent?.call() ?? true);

  Future<void> _login() async {
    if (_busy || !widget.enabled) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = '';
    });
    widget.onBusyChanged?.call(true);
    try {
      final api = widget.acquireApi == null
          ? widget.api!
          : await widget.acquireApi!();
      if (!_current(generation)) return;
      final flow = PasskeyFlow(
        PasskeyApi(api),
        authenticator: widget.authenticator,
      );
      _flow = flow;
      final result = await flow.authenticate(
        isCurrent: () => _current(generation),
        rememberDevice: widget.rememberDevice,
        deviceName: widget.deviceName,
      );
      if (!_current(generation)) {
        if (result.refreshToken != null) {
          unawaited(
            api
                .revokeDeviceSession(result.refreshToken!)
                .catchError((Object _) {}),
          );
        }
        return;
      }
      await widget.onAuthenticated(api, result);
    } catch (error) {
      if (_current(generation)) {
        setState(() => _error = passkeyErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        _flow?.dispose();
        _flow = null;
        setState(() => _busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  void _cancel() {
    widget.onCancelled?.call();
    _invalidate();
    setState(() => _error = '已取消通行密钥登录。');
    widget.onBusyChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton.icon(
        key: const ValueKey('passkey-login'),
        onPressed: widget.enabled && !_busy ? _login : null,
        icon: const Icon(Icons.key_outlined),
        label: Text(_busy ? '正在等待系统验证…' : '使用通行密钥登录'),
      ),
      if (_busy) TextButton(onPressed: _cancel, child: const Text('取消通行密钥登录')),
      if (_error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}
