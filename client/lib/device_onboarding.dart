import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'device_pairing_api.dart';
import 'server_profile.dart';

typedef ScanPairingCode = Future<String?> Function();
typedef PairingApiFactory = DevicePairingApi Function(ServerProfile profile);

/// Anonymous new-device onboarding. Merely scanning a QR never contacts its
/// destination. The user must inspect the normalized server and explicitly claim.
class DeviceOnboardingPage extends StatefulWidget {
  final void Function(ServerProfile, DevicePairingResult) onConnected;
  final VoidCallback onClose;
  final ScanPairingCode? scanPairingCode;
  final PairingApiFactory? apiFactory;
  final bool allowLoopbackHttp;

  const DeviceOnboardingPage({
    super.key,
    required this.onConnected,
    required this.onClose,
    this.scanPairingCode,
    this.apiFactory,
    this.allowLoopbackHttp = false,
  });

  @override
  State<DeviceOnboardingPage> createState() => _DeviceOnboardingPageState();
}

enum _Step { input, destination, claiming, waiting, approved, redeeming, ended }

class _DeviceOnboardingPageState extends State<DeviceOnboardingPage> {
  final _raw = TextEditingController();
  final _name = TextEditingController(text: '我的设备');
  _Step _step = _Step.input;
  int _generation = 0;
  bool _closed = false, _scanning = false, _pollingFailed = false;
  bool _redeemUncertain = false;
  String _error = '';
  PairingQr? _qr;
  ServerProfile? _profile;
  PairingSnapshot? _snapshot;
  DevicePairingApi? _api;
  Timer? _pollTimer;

  @override
  void dispose() {
    _closed = true;
    _invalidate();
    _raw.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DeviceOnboardingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.allowLoopbackHttp != widget.allowLoopbackHttp ||
        oldWidget.apiFactory != widget.apiFactory) {
      _reset();
    }
  }

  bool _current(int generation) =>
      mounted && !_closed && generation == _generation;

  void _invalidate() {
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _api?.cancel();
    _api?.dispose();
    _api = null;
    _qr = null;
    _snapshot = null;
    _profile = null;
  }

  void _reset() {
    _invalidate();
    _raw.clear();
    if (mounted && !_closed) {
      setState(() {
        _step = _Step.input;
        _scanning = false;
        _error = '';
        _pollingFailed = false;
        _redeemUncertain = false;
      });
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _invalidate();
    _raw.clear();
    widget.onClose();
  }

  void _parse(String value) {
    if (_closed) return;
    _invalidate();
    _raw.clear();
    try {
      final qr =
          PairingQr.parse(value, allowLoopbackHttp: widget.allowLoopbackHttp);
      setState(() {
        _qr = qr;
        _profile = qr.profile;
        _step = _Step.destination;
        _scanning = false;
        _error = '';
        _redeemUncertain = false;
      });
    } catch (_) {
      setState(() {
        _step = _Step.input;
        _scanning = false;
        _error = '二维码无效或服务器地址不安全。请从已登录的泊信网页重新生成二维码。';
      });
    }
  }

  Future<void> _scan() async {
    if (_scanning || widget.scanPairingCode == null || _closed) return;
    _reset();
    final generation = _generation;
    setState(() => _scanning = true);
    try {
      final value = await widget.scanPairingCode!();
      if (!_current(generation)) return;
      if (value == null) {
        setState(() => _scanning = false);
      } else {
        _parse(value);
      }
    } catch (_) {
      if (_current(generation)) {
        setState(() {
          _scanning = false;
          _error = '未能扫描二维码。你可以允许相机权限后重试，或粘贴二维码内容。';
        });
      }
    }
  }

  String _safeError(Object failure) {
    final code = failure is ApiException ? failure.code : '';
    return switch (code) {
      'PAIRING_EXPIRED' || 'EXPIRED' => '二维码已过期，请在网页生成新的二维码。',
      'PAIRING_CLAIMED' ||
      'PAIRING_ALREADY_CLAIMED' ||
      'PAIRING_CONFLICT' =>
        '二维码已经被使用，请在网页取消此请求并生成新的二维码。',
      'PAIRING_REJECTED' => '网页已取消此连接请求。',
      'RATE_LIMITED' || 'TOO_MANY_REQUESTS' || 'HTTP_429' => '请求过于频繁，请稍后重新连接。',
      'PAIRING_REDIRECT' => '服务器尝试跳转到其他地址，已停止连接。请核对服务器配置。',
      'NETWORK' => '未能收到服务器的有效响应，请检查网络。',
      _ => '连接未完成，请在网页检查请求状态后重新生成二维码。',
    };
  }

  Future<void> _claim() async {
    final qr = _qr;
    if (_step != _Step.destination || qr == null || _closed) return;
    final name = _name.text.trim();
    if (name.isEmpty ||
        name.length > 80 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      setState(() => _error = '请输入 1 至 80 个字符的单行设备名称。');
      return;
    }
    final generation = _generation;
    setState(() {
      _step = _Step.claiming;
      _error = '';
      _qr = null;
    });
    try {
      final api = widget.apiFactory?.call(qr.profile) ??
          DevicePairingApi(profile: qr.profile);
      _api = api;
      final snapshot = await api.claim(qr, deviceName: name);
      if (!_current(generation)) return;
      setState(() {
        _snapshot = snapshot;
        _step = _Step.waiting;
      });
      _schedulePoll(generation);
    } catch (failure) {
      if (_current(generation)) {
        _api?.dispose();
        _api = null;
        setState(() {
          _step = _Step.ended;
          _error = '${_safeError(failure)} 本次扫码不会自动重试。';
        });
      }
    }
  }

  void _schedulePoll(int generation) {
    _pollTimer?.cancel();
    if (_step == _Step.waiting && _current(generation)) {
      _pollTimer = Timer(const Duration(seconds: 2), () => _poll(generation));
    }
  }

  Future<void> _poll(int generation) async {
    final api = _api;
    if (!_current(generation) || _step != _Step.waiting || api == null) return;
    if (!_snapshot!.expiresAt.isAfter(DateTime.now())) {
      _finish('连接请求已过期，请在网页生成新的二维码。');
      return;
    }
    try {
      final snapshot = await api.poll();
      if (!_current(generation)) return;
      setState(() {
        _snapshot = snapshot;
        _pollingFailed = false;
        _error = '';
      });
      switch (snapshot.state) {
        case PairingState.approved:
          setState(() => _step = _Step.approved);
          await _redeem();
        case PairingState.rejected:
          _finish('网页已取消此连接请求。');
        case PairingState.expired:
          _finish('连接请求已过期，请在网页生成新的二维码。');
        case PairingState.redeemed:
          _finish('此请求已经完成兑换。若没有成功登录，请先在网页设备列表核对并撤销旧设备，再重新连接。');
        case PairingState.claimed:
          _schedulePoll(generation);
        case PairingState.created:
          _finish('服务器返回了异常的连接状态，请重新生成二维码。');
      }
    } catch (failure) {
      if (_current(generation)) {
        setState(() {
          _pollingFailed = true;
          _error = '${_safeError(failure)} 正在等待下一次状态查询…';
        });
        _schedulePoll(generation);
      }
    }
  }

  void _finish(String message) {
    _pollTimer?.cancel();
    _api?.cancel();
    _api?.dispose();
    _api = null;
    setState(() {
      _step = _Step.ended;
      _error = message;
    });
  }

  Future<void> _redeem() async {
    final api = _api;
    final profile = _profile;
    if (_step != _Step.approved || api == null || profile == null || _closed) {
      return;
    }
    final generation = _generation;
    _pollTimer?.cancel();
    setState(() {
      _step = _Step.redeeming;
      _error = '';
    });
    try {
      final result = await api.redeem();
      if (!_current(generation)) {
        // A transport/mock may still produce a result after local cancellation.
        // Never retain or hand over its credential to the application.
        result.api.token = null;
        result.api.dispose();
        return;
      }
      _closed = true;
      _invalidate();
      _raw.clear();
      widget.onConnected(profile, result);
    } catch (_) {
      if (_current(generation)) {
        _api?.dispose();
        _api = null;
        setState(() {
          _redeemUncertain = true;
          _step = _Step.ended;
          _error = '无法确认登录兑换是否完成，本次请求不会重试。请到网页的设备列表核对并撤销可能已创建的设备，再生成新二维码。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('扫码连接泊信'),
                leading: IconButton(
                  tooltip: '取消设备连接',
                  onPressed: _close,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        const Text('在已登录的网页打开「设备与登录」，生成一次性连接二维码。'),
                        const SizedBox(height: 12),
                        _message('连接后，此设备将获得该账户的全部邮箱和设置访问权限。仅连接你信任的服务器。',
                            color: Colors.amber, key: 'pairing-owner-warning'),
                        const Text('登录只保存在内存中，最长 8 小时。关闭或重启应用后需要重新连接。'),
                        const SizedBox(height: 20),
                        if (_error.isNotEmpty)
                          _message(_error,
                              color: _pollingFailed ? Colors.amber : Colors.red,
                              key: _redeemUncertain
                                  ? 'pairing-uncertain'
                                  : null),
                        if (_step == _Step.input) _input(),
                        if (_profile != null) _destination(),
                        if (_step == _Step.destination) ...[
                          const SizedBox(height: 16),
                          TextField(
                            key: const Key('pairing-device-name'),
                            controller: _name,
                            maxLength: 80,
                            decoration: const InputDecoration(
                                labelText: '此设备名称',
                                border: OutlineInputBorder()),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            key: const Key('pairing-confirm-destination'),
                            onPressed: _claim,
                            child: const Text('确认服务器并请求连接'),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                              '点击后才会向此服务器发送一次性连接请求和设备名称。账户身份将在服务器响应后显示。'),
                        ],
                        if (_step == _Step.claiming ||
                            _step == _Step.redeeming) ...[
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(),
                          const SizedBox(height: 12),
                          Text(_step == _Step.claiming
                              ? '正在请求连接…'
                              : '正在完成一次性登录…'),
                        ],
                        if (_snapshot != null &&
                            (_step == _Step.waiting || _step == _Step.approved))
                          _confirmation(),
                        if (_step != _Step.input) ...[
                          const SizedBox(height: 20),
                          OutlinedButton.icon(
                            key: const Key('pairing-start-over'),
                            onPressed: _reset,
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('重新扫码或粘贴'),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                              '取消或重新扫码会停止此设备登录。网页中已经完成的设备授权需要在设备列表中另行撤销。'),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _input() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.scanPairingCode != null) ...[
            FilledButton.icon(
              key: const Key('pairing-scan'),
              onPressed: _scanning ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(_scanning ? '等待扫码…' : '扫描网页二维码'),
            ),
            const SizedBox(height: 20),
          ],
          TextField(
            key: const Key('pairing-paste'),
            controller: _raw,
            enabled: !_scanning,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            enableIMEPersonalizedLearning: false,
            maxLength: PairingQr.maxPayloadBytes,
            decoration: const InputDecoration(
              labelText: '粘贴二维码内容',
              helperText: '内容只用于本次连接，不会保存',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('pairing-review-paste'),
            onPressed: _scanning ? null : () => _parse(_raw.text),
            child: const Text('核对服务器地址'),
          ),
        ],
      );

  Widget _destination() => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('连接目标服务器'),
              const SizedBox(height: 8),
              Text(_profile!.origin,
                  key: const Key('pairing-server-origin'),
                  textDirection: TextDirection.ltr,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(_profile!.apiBase, textDirection: TextDirection.ltr),
              if (_profile!.apiBase.startsWith('http://'))
                const Text('仅限明确启用的本机 HTTP 演示，请勿用于真实账户。'),
            ],
          ),
        ),
      );

  Widget _confirmation() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          Text('账户：${_snapshot!.accountName}'),
          const SizedBox(height: 12),
          const Text('在网页核对相同的 6 位确认码，再输入网页账户密码批准连接。'),
          const SizedBox(height: 12),
          Semantics(
            label: '确认码 ${_snapshot!.confirmationCode!.split('').join(' ')}',
            child: ExcludeSemantics(
              child: Text(_snapshot!.confirmationCode!,
                  key: const Key('pairing-confirmation-code'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      letterSpacing: 8, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),
          Text(
              '有效至 ${_snapshot!.expiresAt.toLocal().toString().split('.').first}'),
          const SizedBox(height: 16),
          if (_step == _Step.waiting)
            const Text('等待网页批准，约每 2 秒更新一次状态…')
          else ...[
            _message('网页已批准此设备的完整访问权限。'),
            FilledButton(
              key: const Key('pairing-redeem'),
              onPressed: _redeem,
              child: const Text('完成连接'),
            ),
          ],
        ],
      );

  Widget _message(String text, {Color color = Colors.blue, String? key}) =>
      Container(
        key: key == null ? null : Key(key),
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: const TextStyle(height: 1.5)),
      );
}
