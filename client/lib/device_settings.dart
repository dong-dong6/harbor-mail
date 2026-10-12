import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'android_downloads.dart';

/// The authenticated owner approves each new device explicitly. Pairing secrets
/// are deliberately kept out of URLs, text selection, clipboard and persistence.
class DeviceSettingsPage extends StatefulWidget {
  final MailApi api;
  final VoidCallback onClose;

  const DeviceSettingsPage({
    super.key,
    required this.api,
    required this.onClose,
  });

  @override
  DeviceSettingsPageState createState() => DeviceSettingsPageState();
}

class DeviceSettingsPageState extends State<DeviceSettingsPage> {
  final _password = TextEditingController();
  Timer? _pollTimer;
  String? _sessionToken;
  int _generation = 0, _listGeneration = 0;
  int? _pollRequestGeneration;
  bool _closed = false, _creating = false, _busy = false;
  bool _loading = true, _confirming = false, _matched = false;
  bool _approvalUncertain = false, _statusFailed = false;
  String _error = '', _notice = '', _listError = '';
  String? _qrPayload;
  _OwnerPairing? _pairing;
  List<_DeviceEntry> _devices = [];
  final _rejectionSent = <String>{};

  bool get _active => _pairing?.isPending == true;
  bool get protectsDocumentExit => _active || _creating || _busy;
  bool get _hasSession =>
      !_closed && _sessionToken != null && widget.api.token == _sessionToken;

  @override
  void initState() {
    super.initState();
    _sessionToken = widget.api.token;
    _password.addListener(_changed);
    _loadDevices();
  }

  @override
  void didUpdateWidget(covariant DeviceSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _discardPairing();
      _listGeneration++;
      _sessionToken = widget.api.token;
      _devices = [];
      _loadDevices();
    }
  }

  @override
  void dispose() {
    _rejectOnExit();
    _closed = true;
    _generation++;
    _listGeneration++;
    _pollTimer?.cancel();
    _qrPayload = null;
    _pairing = null;
    _password.removeListener(_changed);
    _password.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted && !_closed) setState(() {});
  }

  bool _current(int generation) {
    if (!mounted || _closed || generation != _generation) return false;
    if (!_hasSession) {
      _discardPairing();
      setState(() {
        _devices = [];
        _error = '会话已失效，请返回登录后重试。';
        _busy = false;
        _creating = false;
      });
      return false;
    }
    return true;
  }

  void _discardPairing() {
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;
    _qrPayload = null;
    _pairing = null;
    _matched = false;
    _approvalUncertain = false;
    _statusFailed = false;
    _password.clear();
  }

  void _rejectOnExit() {
    final pending = _pairing;
    if (!_hasSession || pending == null || !pending.isPending) return;
    if (!_rejectionSent.add(pending.id)) return;
    // A completed authorization is never described as revoked by this cleanup.
    unawaited(
      widget.api
          .request(
            'POST',
            '/auth/device-pairings/${pending.id}/reject',
            body: <String, dynamic>{},
            followRedirects: false,
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  Future<bool> canLeave() async {
    if (_confirming) return false;
    if (!protectsDocumentExit) return true;
    _confirming = true;
    final generation = _generation;
    final leave =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('离开设备连接？'),
            content: const Text(
              '将尝试取消待完成的连接。已经连接的设备不会因离开此页而被撤销；请在设备列表中撤销其访问权限。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续连接'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('离开'),
              ),
            ],
          ),
        ) ==
        true;
    _confirming = false;
    if (!mounted || _closed || generation != _generation) return false;
    if (leave) {
      _rejectOnExit();
      _discardPairing();
      setState(() {
        _creating = false;
        _busy = false;
      });
    }
    return leave;
  }

  Future<void> _close() async {
    if (await canLeave() && mounted && !_closed) {
      _closed = true;
      _generation++;
      _listGeneration++;
      _pollTimer?.cancel();
      _password.clear();
      widget.onClose();
    }
  }

  String _safeError(Object error) {
    final code = error is ApiException ? error.code : '';
    return switch (code) {
      'UNAUTHORIZED' || 'HTTP_401' => '会话已失效，请返回登录后重试。',
      'FORBIDDEN' ||
      'HTTP_403' ||
      'OWNER_SESSION_REQUIRED' ||
      'BROWSER_SESSION_REQUIRED' => '请使用密码登录的网页会话添加新设备。通过扫码连接的设备不能批准其他设备。',
      'PAIRING_UNAVAILABLE' => '服务器尚未配置可信的 HTTPS 地址，暂时不能生成连接二维码。',
      'INVALID_PASSWORD' ||
      'BAD_CREDENTIALS' ||
      'INVALID_CREDENTIALS' ||
      'REAUTHENTICATION_FAILED' => '密码验证失败，请核对当前账户密码。',
      'RATE_LIMITED' ||
      'TOO_MANY_REQUESTS' ||
      'HTTP_429' ||
      'PAIRING_LIMIT' => '请求过于频繁，请稍后再试。',
      'PAIRING_EXPIRED' || 'EXPIRED' => '连接请求已过期，请生成新的二维码。',
      'NETWORK' => '无法确认服务器响应，请检查网络并刷新状态。',
      _ => '操作未完成，请刷新状态后重试。',
    };
  }

  Future<void> _loadDevices() async {
    if (!_hasSession) {
      setState(() {
        _loading = false;
        _listError = '会话已失效，请返回登录后重试。';
      });
      return;
    }
    final generation = ++_listGeneration;
    setState(() {
      _loading = true;
      _listError = '';
    });
    try {
      final result = await widget.api.request(
        'GET',
        '/auth/devices',
        followRedirects: false,
      );
      if (!mounted || _closed || generation != _listGeneration) return;
      if (!_hasSession) {
        _current(_generation);
        return;
      }
      if (result is! Map || result['items'] is! List) {
        throw const FormatException('Invalid device list');
      }
      final entries = (result['items'] as List)
          .map((item) => _DeviceEntry.parse(item))
          .toList();
      setState(() => _devices = entries);
    } catch (error) {
      if (mounted && !_closed && generation == _listGeneration) {
        setState(() => _listError = _safeError(error));
      }
    } finally {
      if (mounted && !_closed && generation == _listGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _create() async {
    if (_creating || _busy || _active || !_hasSession) return;
    _discardPairing();
    final generation = _generation;
    setState(() {
      _creating = true;
      _error = '';
      _notice = '';
    });
    try {
      final result = await widget.api.request(
        'POST',
        '/auth/device-pairings',
        body: <String, dynamic>{},
        followRedirects: false,
      );
      if (!_current(generation)) return;
      final pairing = _OwnerPairing.created(result);
      final qr = result['qrPayload'];
      if (qr is! String || qr.isEmpty || qr.length > 4096) {
        throw const FormatException('Invalid QR');
      }
      setState(() {
        _pairing = pairing;
        _qrPayload = qr;
      });
      _schedulePoll(generation);
    } catch (error) {
      if (_current(generation)) {
        setState(() => _error = _safeError(error));
      }
    } finally {
      if (_current(generation)) setState(() => _creating = false);
    }
  }

  void _schedulePoll(int generation) {
    _pollTimer?.cancel();
    if (_active && _hasSession) {
      _pollTimer = Timer(const Duration(seconds: 2), () => _poll(generation));
    }
  }

  Future<void> _poll(int generation) async {
    if (!_current(generation) ||
        !_active ||
        _busy ||
        _pollRequestGeneration == generation) {
      return;
    }
    final pairing = _pairing!;
    if (!pairing.expiresAt.isAfter(DateTime.now())) {
      _acceptPairing(pairing.withState('EXPIRED'));
      return;
    }
    _pollRequestGeneration = generation;
    try {
      final result = await widget.api.request(
        'GET',
        '/auth/device-pairings/${pairing.id}',
        followRedirects: false,
      );
      if (!_current(generation) || _pairing?.id != pairing.id) return;
      final updated = _OwnerPairing.parse(result);
      if (updated.id != pairing.id) {
        throw const FormatException('Pairing mismatch');
      }
      _acceptPairing(updated);
      _schedulePoll(generation);
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _error = _safeError(error);
          _statusFailed = true;
        });
      }
    } finally {
      if (_pollRequestGeneration == generation) _pollRequestGeneration = null;
    }
  }

  void _acceptPairing(_OwnerPairing updated) {
    setState(() {
      _pairing = updated;
      _error = '';
      _statusFailed = false;
      _approvalUncertain = false;
      if (updated.state != 'CREATED') _qrPayload = null;
      if (updated.state != 'CLAIMED') {
        _password.clear();
        _matched = false;
      }
      if (!updated.isPending) _pollTimer?.cancel();
      if (updated.state == 'REDEEMED') _notice = '设备已连接，可在下方随时撤销访问权限。';
    });
    if (updated.state == 'REDEEMED') _loadDevices();
  }

  Future<void> _approve() async {
    final pairing = _pairing;
    if (_busy ||
        !_matched ||
        _approvalUncertain ||
        _statusFailed ||
        pairing?.state != 'CLAIMED' ||
        _password.text.isEmpty ||
        !_hasSession) {
      return;
    }
    if (!pairing!.expiresAt.isAfter(DateTime.now())) {
      _acceptPairing(pairing.withState('EXPIRED'));
      return;
    }
    final generation = ++_generation; // Fence any older in-flight status read.
    final password = _password.text;
    _password.clear();
    _pollTimer?.cancel();
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final result = await widget.api.request(
        'POST',
        '/auth/device-pairings/${pairing.id}/approve',
        body: {'password': password, 'confirmationCode': pairing.code},
        followRedirects: false,
      );
      if (!_current(generation)) return;
      if (result is! Map || result['state'] != 'APPROVED') {
        throw const FormatException('Invalid approval');
      }
      _acceptPairing(pairing.withState('APPROVED'));
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _approvalUncertain = true;
          _error = '${_safeError(error)} 批准结果需先刷新确认。';
        });
      }
    } finally {
      if (_current(generation)) {
        setState(() => _busy = false);
        _schedulePoll(generation);
      }
    }
  }

  Future<void> _reject() async {
    final pairing = _pairing;
    if (_busy || pairing == null || !pairing.isPending || !_hasSession) return;
    final generation = ++_generation; // A late poll cannot undo cancellation.
    _pollTimer?.cancel();
    _qrPayload = null;
    _password.clear();
    setState(() {
      _busy = true;
      _matched = false;
      _error = '';
    });
    try {
      final result = await widget.api.request(
        'POST',
        '/auth/device-pairings/${pairing.id}/reject',
        body: <String, dynamic>{},
        followRedirects: false,
      );
      if (!_current(generation)) return;
      if (result is! Map || result['state'] != 'REJECTED') {
        throw const FormatException('Invalid rejection');
      }
      _rejectionSent.add(pairing.id);
      _acceptPairing(pairing.withState('REJECTED'));
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _statusFailed = true;
          _approvalUncertain = true;
          _error = '尚未确认取消。${_safeError(error)} 已连接的设备需在列表中撤销。';
        });
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(_DeviceEntry device) async {
    if (_busy || _confirming || !_hasSession) return;
    _confirming = true;
    final generation = _generation;
    final approved =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('撤销「${device.name}」的访问权限？'),
            content: const Text('该设备的邮箱和设置访问权限将立即失效。再次使用需要重新连接。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保留设备'),
              ),
              FilledButton(
                key: const Key('device-confirm-revoke'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('撤销访问权限'),
              ),
            ],
          ),
        ) ==
        true;
    _confirming = false;
    if (!approved || !_current(generation)) return;
    setState(() => _busy = true);
    try {
      await widget.api.request(
        'DELETE',
        '/auth/devices/${device.id}',
        followRedirects: false,
      );
      if (!_current(generation)) return;
      setState(() => _notice = '已撤销「${device.name}」的访问权限。');
      await _loadDevices();
    } catch (error) {
      if (_current(generation)) {
        setState(() => _error = '撤销结果尚未确认。${_safeError(error)}');
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
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
            title: const Text('已连接设备'),
            leading: IconButton(
              tooltip: '返回账户设置',
              onPressed: _close,
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _message(
                      '新设备将获得当前账户的全部邮箱和设置访问权限。仅连接你信任的设备。',
                      color: Colors.amber,
                      key: 'device-owner-warning',
                    ),
                    const Text('本阶段登录只保存在内存中，最长 8 小时。关闭或重启应用后需要重新连接。'),
                    const SizedBox(height: 20),
                    if (_error.isNotEmpty) _message(_error, color: Colors.red),
                    if (_notice.isNotEmpty) _message(_notice),
                    if (kIsWeb) AndroidDownloadCard(client: widget.api.client),
                    _pairingCard(),
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '设备访问权限',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新设备列表',
                          onPressed: _loading || _busy ? null : _loadDevices,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    if (_loading) const LinearProgressIndicator(),
                    if (_listError.isNotEmpty)
                      _message(_listError, color: Colors.red),
                    if (!_loading && _devices.isEmpty && _listError.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('尚无已连接的设备。'),
                      ),
                    for (final device in _devices) _deviceTile(device),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _pairingCard() {
    final pairing = _pairing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('连接新设备', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (pairing == null || !pairing.isPending) ...[
              if (pairing != null) Text(_stateLabel(pairing.state)),
              const Text('在新设备打开泊信，选择扫码连接。二维码有效期为 2 分钟，请勿分享或截图发送给他人。'),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('device-create-pairing'),
                onPressed: _creating || _busy || !_hasSession ? null : _create,
                icon: const Icon(Icons.qr_code),
                label: Text(_creating ? '正在生成…' : '生成连接二维码'),
              ),
            ] else ...[
              Text(_stateLabel(pairing.state)),
              const SizedBox(height: 8),
              Text('有效至 ${_time(pairing.expiresAt)}'),
              if (_qrPayload != null)
                Center(
                  child: Semantics(
                    label: '一次性设备连接二维码，请使用新设备扫描',
                    child: ExcludeSemantics(
                      child: QrImageView(
                        key: const Key('device-pairing-qr'),
                        data: _qrPayload!,
                        size: 236,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              if (pairing.state == 'CLAIMED') ...[
                const SizedBox(height: 12),
                Text('账户：${pairing.accountName}'),
                Text('请求设备：${pairing.deviceName}'),
                const SizedBox(height: 12),
                const Text('请与新设备屏幕上的 6 位确认码逐位核对：'),
                Semantics(
                  label: '确认码 ${pairing.code!.split('').join(' ')}',
                  child: ExcludeSemantics(
                    child: Text(
                      pairing.code!,
                      key: const Key('device-confirmation-code'),
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            letterSpacing: 8,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
                CheckboxListTile(
                  key: const Key('device-code-matched'),
                  contentPadding: EdgeInsets.zero,
                  value: _matched,
                  onChanged: _busy || _approvalUncertain || _statusFailed
                      ? null
                      : (value) => setState(() => _matched = value == true),
                  title: const Text('我已在新设备核对确认码，且两边完全一致'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                TextField(
                  key: const Key('device-owner-password'),
                  controller: _password,
                  enabled: !_busy && !_approvalUncertain && !_statusFailed,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(
                    labelText: '当前账户密码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('device-approve'),
                  onPressed:
                      _busy ||
                          !_matched ||
                          _password.text.isEmpty ||
                          _approvalUncertain ||
                          _statusFailed
                      ? null
                      : _approve,
                  child: const Text('批准此设备的完整访问权限'),
                ),
              ],
              if (_busy) const LinearProgressIndicator(),
              if (_statusFailed || _approvalUncertain)
                TextButton.icon(
                  key: const Key('device-refresh-status'),
                  onPressed: _busy ? null : () => _schedulePoll(_generation),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新连接状态'),
                ),
              const SizedBox(height: 8),
              TextButton(
                key: const Key('device-reject-pairing'),
                onPressed: _busy ? null : _reject,
                child: const Text('取消连接请求'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _deviceTile(_DeviceEntry device) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(device.name, style: Theme.of(context).textTheme.titleMedium),
          const Text('全部邮箱和设置访问权限'),
          Text('连接时间：${_time(device.createdAt)}'),
          Text('到期时间：${_time(device.expiresAt)}'),
          if (device.lastSeenAt != null)
            Text('最近使用：${_time(device.lastSeenAt!)}'),
          if (device.revoked)
            const Text('已撤销')
          else if (!device.expiresAt.isAfter(DateTime.now()))
            const Text('已到期')
          else
            TextButton.icon(
              key: Key('device-revoke-${device.id}'),
              onPressed: _busy ? null : () => _revoke(device),
              icon: const Icon(Icons.link_off),
              label: const Text('撤销访问权限'),
            ),
        ],
      ),
    ),
  );

  Widget _message(String text, {Color color = Colors.blue, String? key}) =>
      Container(
        key: key == null ? null : Key(key),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: const TextStyle(height: 1.5)),
      );
}

String _time(DateTime value) => value.toLocal().toString().split('.').first;
String _stateLabel(String state) => switch (state) {
  'CREATED' => '等待新设备扫码',
  'CLAIMED' => '新设备请求连接，请核对确认码',
  'APPROVED' => '已批准，等待新设备完成连接',
  'REDEEMED' => '设备已连接',
  'REJECTED' => '连接请求已取消',
  'EXPIRED' => '二维码已过期，请重新生成',
  _ => '无法识别连接状态',
};

String _requiredString(Map value, String key, {int maxLength = 254}) {
  final text = value[key];
  if (text is! String ||
      text.isEmpty ||
      text.length > maxLength ||
      text.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const FormatException('Invalid field');
  }
  return text;
}

String _id(Map value, String key) {
  final id = _requiredString(value, key, maxLength: 128);
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
    throw const FormatException('Invalid identifier');
  }
  return id;
}

DateTime _date(Map value, String key) =>
    DateTime.parse(_requiredString(value, key, maxLength: 40));

class _OwnerPairing {
  final String id, state;
  final DateTime expiresAt;
  final String? code, accountName, deviceName;
  const _OwnerPairing(
    this.id,
    this.state,
    this.expiresAt, {
    this.code,
    this.accountName,
    this.deviceName,
  });

  bool get isPending =>
      const ['CREATED', 'CLAIMED', 'APPROVED'].contains(state);

  factory _OwnerPairing.created(dynamic value) {
    if (value is! Map || value['state'] != 'CREATED') {
      throw const FormatException('Invalid pairing');
    }
    return _OwnerPairing(
      _id(value, 'pairingId'),
      'CREATED',
      _date(value, 'expiresAt'),
    );
  }

  factory _OwnerPairing.parse(dynamic value) {
    if (value is! Map || value['permission'] != 'OWNER_FULL_ACCESS') {
      throw const FormatException('Invalid owner permission');
    }
    final state = _requiredString(value, 'state', maxLength: 20);
    if (!const [
      'CREATED',
      'CLAIMED',
      'APPROVED',
      'REDEEMED',
      'REJECTED',
      'EXPIRED',
    ].contains(state)) {
      throw const FormatException('Invalid state');
    }
    String? code, deviceName;
    if (state == 'CLAIMED') {
      code = _requiredString(value, 'confirmationCode', maxLength: 6);
      if (!RegExp(r'^\d{6}$').hasMatch(code)) {
        throw const FormatException('Invalid code');
      }
      deviceName = _requiredString(value, 'deviceName', maxLength: 100);
    }
    return _OwnerPairing(
      _id(value, 'pairingId'),
      state,
      _date(value, 'expiresAt'),
      code: code,
      accountName: _requiredString(value, 'accountName'),
      deviceName: deviceName,
    );
  }

  _OwnerPairing withState(String next) => _OwnerPairing(
    id,
    next,
    expiresAt,
    code: code,
    accountName: accountName,
    deviceName: deviceName,
  );
}

class _DeviceEntry {
  final String id, name;
  final DateTime createdAt, expiresAt;
  final DateTime? lastSeenAt;
  final bool revoked;
  const _DeviceEntry(
    this.id,
    this.name,
    this.createdAt,
    this.expiresAt,
    this.lastSeenAt,
    this.revoked,
  );

  factory _DeviceEntry.parse(dynamic value) {
    if (value is! Map ||
        value['permission'] != 'OWNER_FULL_ACCESS' ||
        value['revoked'] is! bool) {
      throw const FormatException('Invalid device');
    }
    return _DeviceEntry(
      _id(value, 'id'),
      _requiredString(value, 'name', maxLength: 100),
      _date(value, 'createdAt'),
      _date(value, 'expiresAt'),
      value['lastSeenAt'] == null ? null : _date(value, 'lastSeenAt'),
      value['revoked'] as bool,
    );
  }
}
