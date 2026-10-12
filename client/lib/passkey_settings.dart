import 'package:flutter/material.dart';

import 'api.dart';
import 'passkey_api.dart';
import 'passkey_platform.dart';

class PasskeySettingsPanel extends StatefulWidget {
  const PasskeySettingsPanel({
    super.key,
    required this.api,
    this.authenticator,
    this.onClose,
  });
  final MailApi api;
  final PasskeyAuthenticator? authenticator;
  final VoidCallback? onClose;

  @override
  PasskeySettingsPanelState createState() => PasskeySettingsPanelState();
}

class PasskeySettingsPanelState extends State<PasskeySettingsPanel> {
  final _name = TextEditingController(text: '我的通行密钥');
  final _password = TextEditingController();
  late PasskeyApi _api;
  PasskeyFlow? _flow;
  String? _token;
  ApiSessionCoordinator? _sessionCoordinator;
  int? _sessionEpoch;
  List<PasskeyEntry> _items = [];
  bool _loading = true, _busy = false, _available = false, _closed = false;
  bool _confirming = false;
  int _generation = 0, _listGeneration = 0;
  String _error = '', _notice = '';
  bool get protectsDocumentExit => _busy;
  bool get _hasSession =>
      !_closed &&
      (_sessionCoordinator == null
          ? _token != null && widget.api.token == _token
          : identical(widget.api.deviceSession, _sessionCoordinator) &&
                _sessionCoordinator!.durable &&
                _sessionCoordinator!.epoch == _sessionEpoch);

  @override
  void initState() {
    super.initState();
    _api = PasskeyApi(widget.api);
    _token = widget.api.token;
    _sessionCoordinator = widget.api.deviceSession;
    _sessionEpoch = _sessionCoordinator?.epoch;
    _load();
  }

  @override
  void didUpdateWidget(covariant PasskeySettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.authenticator != widget.authenticator ||
        !_hasSession) {
      _invalidate();
      _token = widget.api.token;
      _sessionCoordinator = widget.api.deviceSession;
      _sessionEpoch = _sessionCoordinator?.epoch;
      _api = PasskeyApi(widget.api);
      _items = [];
      _load();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _invalidate();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  void _invalidate() {
    _generation++;
    _listGeneration++;
    _flow?.dispose();
    _flow = null;
    _password.clear();
    _busy = false;
  }

  bool _current(int generation) =>
      mounted && !_closed && generation == _generation && _hasSession;

  Future<void> _load() async {
    final generation = ++_listGeneration;
    if (!_hasSession) {
      setState(() {
        _loading = false;
        _error = '会话已失效，请重新登录。';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final capability = await _api.capabilities();
      if (!mounted ||
          _closed ||
          generation != _listGeneration ||
          !_hasSession) {
        return;
      }
      final items = await _api.list(bearer: _token!);
      if (!mounted ||
          _closed ||
          generation != _listGeneration ||
          !_hasSession) {
        return;
      }
      setState(() {
        _available = capability.available;
        _items = items;
      });
    } catch (error) {
      if (mounted && !_closed && generation == _listGeneration) {
        setState(() => _error = passkeyErrorMessage(error));
      }
    } finally {
      if (mounted && !_closed && generation == _listGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _register() async {
    if (_busy || _loading || !_available || !_hasSession) return;
    if (_password.text.isEmpty || _name.text.trim().isEmpty) {
      setState(() => _error = '请输入通行密钥名称和当前账户密码。');
      return;
    }
    final password = _password.text;
    _password.clear();
    final generation = ++_generation;
    final flow = PasskeyFlow(_api, authenticator: widget.authenticator);
    _flow = flow;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    try {
      await flow.register(
        password: password,
        name: _name.text.trim(),
        isCurrent: () => _current(generation),
      );
      if (!_current(generation)) return;
      setState(() => _notice = '通行密钥已添加。以后可通过系统验证登录，密码登录仍可使用。');
      await _load();
    } catch (error) {
      if (mounted && !_closed && generation == _generation) {
        setState(
          () => _error = '${passkeyErrorMessage(error)} 如系统已保存密钥，请刷新列表确认。',
        );
      }
    } finally {
      flow.dispose();
      if (mounted && !_closed && generation == _generation) {
        _flow = null;
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete(PasskeyEntry entry) async {
    if (_busy || _confirming || !_hasSession) return;
    final generation = _generation;
    _confirming = true;
    final password = await showDialog<String>(
      context: context,
      builder: (context) => _DeletePasskeyDialog(name: entry.name),
    );
    _confirming = false;
    if (password == null || !_current(generation)) return;
    final action = ++_generation;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
    });
    try {
      await _api.delete(entry.id, password: password, bearer: _token!);
      if (!_current(action)) return;
      setState(
        () => _notice =
            '服务器已移除此通行密钥的登录权限。已登录的会话不会因此退出，最长可继续使用 8 小时。系统密码管理器中的副本可由你手动删除。',
      );
      await _load();
    } catch (error) {
      if (mounted && !_closed && action == _generation) {
        setState(() => _error = passkeyErrorMessage(error));
      }
    } finally {
      if (mounted && !_closed && action == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  void _cancel() {
    _invalidate();
    setState(() => _notice = '已停止等待。已经提交的操作可能已完成，请刷新列表确认。');
  }

  Future<bool> canLeave() async {
    if (_confirming) return false;
    if (!_busy) return true;
    _confirming = true;
    final leave =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('离开通行密钥设置？'),
            content: const Text('将停止等待系统验证。已提交到服务器的操作可能已经完成，下次进入时请刷新列表确认。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续等待'),
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
    if (!mounted || _closed) return false;
    if (leave) _cancel();
    return leave;
  }

  Future<void> _close() async {
    if (await canLeave() && mounted && !_closed) {
      _closed = true;
      _invalidate();
      widget.onClose?.call();
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              '通行密钥',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ),
          if (widget.onClose != null)
            IconButton(
              onPressed: _close,
              tooltip: '关闭通行密钥设置',
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        '通过 Android 指纹、Windows Hello 或系统提供的屏幕锁与安全密钥完成验证。具体方式由系统决定；私钥由系统保管，服务器只保存公钥。',
      ),
      const SizedBox(height: 8),
      const Text('只在你信任的设备上添加。同步的通行密钥可能在同一密码管理器的其他设备上使用。密码登录始终保留。'),
      if (widget.api.deviceSession?.durable == true) ...[
        const SizedBox(height: 8),
        const Text('添加或删除通行密钥请在网页临时登录后操作；当前设备可正常使用已注册通行密钥登录。'),
      ],
      const SizedBox(height: 20),
      if (_loading) const LinearProgressIndicator(),
      if (!_loading && !_available) const Text('服务器尚未启用通行密钥，或可信域名关联尚未配置。'),
      if (_error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (_notice.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_notice),
        ),
      TextField(
        controller: _name,
        enabled: !_busy,
        maxLength: 80,
        decoration: const InputDecoration(labelText: '通行密钥名称'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        enabled: !_busy,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: const InputDecoration(labelText: '当前账户密码（仅用于本次确认）'),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: !_loading && !_busy && _available && _hasSession
                ? _register
                : null,
            icon: const Icon(Icons.add),
            label: Text(_busy ? '正在等待系统或服务器…' : '验证密码并添加通行密钥'),
          ),
          if (_busy) TextButton(onPressed: _cancel, child: const Text('停止等待')),
          OutlinedButton(
            onPressed: !_busy && !_loading ? _load : null,
            child: const Text('刷新列表'),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const Text(
        '已添加的通行密钥',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
      ),
      if (!_loading && _items.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('暂无通行密钥。'),
        ),
      for (final entry in _items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.key),
          title: Text(entry.name),
          subtitle: Text(
            '添加于 ${_dateText(entry.createdAt)}${entry.lastUsedAt == null ? '' : '\n最近使用 ${_dateText(entry.lastUsedAt!)}'}',
          ),
          trailing: IconButton(
            tooltip: '移除 ${entry.name}',
            onPressed: !_busy && _hasSession ? () => _delete(entry) : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ),
    ],
  );

  String _dateText(DateTime value) =>
      value.toLocal().toString().split('.').first;
}

class _DeletePasskeyDialog extends StatefulWidget {
  const _DeletePasskeyDialog({required this.name});
  final String name;
  @override
  State<_DeletePasskeyDialog> createState() => _DeletePasskeyDialogState();
}

class _DeletePasskeyDialogState extends State<_DeletePasskeyDialog> {
  final _password = TextEditingController();
  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('移除通行密钥？'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '“${widget.name}”将无法再登录此服务器。已登录的会话不会因此退出，最长可继续使用 8 小时。移除最后一个通行密钥后仍可使用密码登录。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: '输入当前账户密码以确认移除'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _password.text.isEmpty
            ? null
            : () {
                final password = _password.text;
                _password.clear();
                Navigator.pop(context, password);
              },
        child: const Text('确认移除'),
      ),
    ],
  );
}
