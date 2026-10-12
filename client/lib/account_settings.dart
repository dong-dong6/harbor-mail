import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'oauth_settings.dart';
import 'oauth_browser.dart';

typedef Json = Map<String, dynamic>;
const muted = Color(0xff7c899c), blue = Color(0xff0b57d0);

/// Full content-area account management. Credentials are intentionally absent.
class AccountSettingsPage extends StatefulWidget {
  final MailApi api;
  final Json caps;
  final List<Json> initialAccounts;
  final ValueChanged<List<Json>>? onAccountsChanged;
  final VoidCallback? onClose;
  final String initialSection;
  final ValueChanged<String>? onSectionChanged;
  const AccountSettingsPage({
    super.key,
    required this.api,
    required this.caps,
    this.initialAccounts = const [],
    this.onAccountsChanged,
    this.onClose,
    this.initialSection = 'accounts',
    this.onSectionChanged,
  });
  @override
  AccountSettingsPageState createState() => AccountSettingsPageState();
}

class AccountSettingsPageState extends State<AccountSettingsPage> {
  late List<Json> accounts = widget.initialAccounts;
  late Json caps = widget.caps;
  late String section = widget.initialSection;
  final name = TextEditingController();
  final addKey = GlobalKey<AddAccountPageState>();
  final oauthKey = GlobalKey<OAuthSettingsPageState>();
  String? editingId;
  String originalName = '', error = '', notice = '';
  bool loading = false, busy = false, confirming = false;
  int generation = 0;
  bool get protectsDocumentExit =>
      locked ||
      dirty ||
      (section == 'add' &&
          (addKey.currentState?.protectsDocumentExit ?? false)) ||
      (section == 'oauth' &&
          (oauthKey.currentState?.protectsDocumentExit ?? false));
  bool get dirty => editingId != null && name.text.trim() != originalName;
  bool get locked => busy || confirming;
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    generation++;
    name.dispose();
    super.dispose();
  }

  Future<bool> canLeave() async {
    if (locked) return false;
    if (section == 'add') return await addKey.currentState?.canLeave() ?? true;
    if (section == 'oauth') {
      return await oauthKey.currentState?.canLeave() ?? true;
    }
    if (!dirty) return true;
    return confirm('放弃未保存的名称？', '显示名称的更改尚未保存。', '放弃更改');
  }

  Future<bool> confirm(String title, String message, String action) async {
    if (locked) return false;
    setState(() => confirming = true);
    try {
      return await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(action),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  Future<void> showSection(String next, {bool guarded = true}) async {
    if ((guarded && !await canLeave()) || !mounted) return;
    setState(() {
      section = next;
      editingId = null;
      error = '';
      notice = '';
    });
    widget.onSectionChanged?.call(next);
    if (next == 'accounts') reload();
  }

  Future<void> requestClose() async {
    if (section != 'accounts') {
      await showSection('accounts');
      return;
    }
    if (await canLeave() && mounted) widget.onClose?.call();
  }

  Future<void> reload() async {
    if (locked) return;
    final request = ++generation;
    setState(() => loading = true);
    try {
      final data = await widget.api.request('GET', '/accounts');
      if (!mounted || request != generation) return;
      final next = (data['items'] as List? ?? [])
          .map((a) => Map<String, dynamic>.from(a))
          .toList();
      setState(() {
        accounts = next;
        error = '';
      });
      widget.onAccountsChanged?.call(next);
    } catch (e) {
      if (mounted && request == generation) {
        setState(() => error = '无法载入邮箱，请重试。');
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  Future<void> edit(Json account) async {
    if (!await canLeave() || !mounted) return;
    setState(() {
      editingId = account['id'];
      originalName = account['displayName']?.toString() ?? '';
      name.text = originalName;
      error = '';
      notice = '';
    });
  }

  Future<void> saveName() async {
    if (locked || editingId == null) return;
    final value = name.text.trim();
    if (value.isEmpty ||
        value.length > 100 ||
        value.contains(RegExp(r'[\r\n\x00-\x1f]'))) {
      setState(() => error = '显示名称不能为空，须为单行且不超过 100 个字符。');
      return;
    }
    final id = editingId!;
    generation++; // Any older GET must never overwrite the mutation response.
    setState(() {
      busy = true;
      loading = false;
      error = '';
    });
    try {
      final saved = Map<String, dynamic>.from(
        await widget.api.request(
          'PATCH',
          '/accounts/$id',
          body: {'displayName': value},
        ),
      );
      if (!mounted) return;
      setState(() {
        accounts =
            accounts.map((a) => a['id'] == id ? {...a, ...saved} : a).toList();
        editingId = null;
        notice = '显示名称已更新';
      });
      widget.onAccountsChanged?.call(accounts);
    } catch (e) {
      if (mounted) setState(() => error = '名称未确认保存，请重新载入后核对。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> disconnect(Json account) async {
    if (!await canLeave() || !mounted) return;
    if (account['canDisconnect'] == false) {
      setState(() => error = '有待处理或结果未确认的发送／同步操作，请先核对发件状态。');
      return;
    }
    final approved = await confirm(
      '断开 ${account['email']}？',
      '将删除此应用保存的授权凭据、该邮箱的本地缓存邮件、附件、草稿和操作记录。此操作无法撤销。\n\n服务商邮箱及其中的邮件不会被删除，其他已连接邮箱不受影响。有待处理或结果未知的发送时无法断开。',
      '断开邮箱',
    );
    if (!approved || !mounted) return;
    generation++;
    setState(() {
      busy = true;
      loading = false;
      error = '';
    });
    try {
      await widget.api.request('DELETE', '/accounts/${account['id']}');
      if (!mounted) return;
      setState(() {
        accounts = accounts.where((a) => a['id'] != account['id']).toList();
        editingId = null;
        notice = '邮箱已断开，服务商邮箱未改动';
      });
      widget.onAccountsChanged?.call(accounts);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiException && e.code == 'ACCOUNT_BUSY'
              ? '有待处理或结果未确认的操作，未断开邮箱。请先核对发件状态。'
              : '断开结果未确认，请重新载入账户列表后核对。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> connected() async {
    await showSection('accounts', guarded: false);
  }

  Future<void> oauthClosed() async {
    await showSection('accounts', guarded: false);
    try {
      final next = await widget.api.request('GET', '/settings/capabilities');
      if (mounted) setState(() => caps = Map<String, dynamic>.from(next));
    } catch (_) {
      /* The existing capability snapshot remains conservative. */
    }
  }

  String status(Json a) => switch (a['status']) {
        'CONNECTED' || 'ACTIVE' => '已连接',
        'DEMO' => '演示账户',
        'AUTH_REQUIRED' || 'NEEDS_REAUTH' || 'REAUTH_REQUIRED' => '需要重新授权',
        'ERROR' => '连接异常',
        'SYNCING' => '正在同步',
        _ => a['status']?.toString() ?? '状态未提供',
      };
  @override
  Widget build(BuildContext context) {
    if (section == 'add') {
      return AddAccountPage(
        key: addKey,
        api: widget.api,
        caps: caps,
        onClose: () => showSection('accounts', guarded: false),
        onConnected: connected,
        onOAuthSettings: () => showSection('oauth', guarded: false),
      );
    }
    if (section == 'oauth') {
      return OAuthSettingsPage(
        key: oauthKey,
        api: widget.api,
        demoMode: caps['demoMode'] == true,
        onClose: oauthClosed,
      );
    }
    return Column(
      key: const Key('account-settings-page'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回邮箱',
                onPressed: locked ? null : requestClose,
                icon: const Icon(Icons.arrow_back),
              ),
              const Expanded(
                child: Text(
                  '账户与设置',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '刷新账户',
                onPressed: locked || loading ? null : reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (loading || busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              const Text(
                '已连接邮箱',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '在这里管理显示名称和连接状态。服务商凭据不会回传或显示。',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(error, style: const TextStyle(color: Colors.red)),
                ),
              if (notice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(notice),
                ),
              if (accounts.isEmpty && !loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('尚未连接邮箱'),
                ),
              for (final a in accounts) accountCard(a),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    key: const Key('add-account'),
                    onPressed: locked ? null : () => showSection('add'),
                    icon: const Icon(Icons.add),
                    label: const Text('添加邮箱'),
                  ),
                  if (caps['features']?['oauthSettings'] == true)
                    OutlinedButton.icon(
                      onPressed: locked ? null : () => showSection('oauth'),
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                      label: const Text('系统 OAuth 设置'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget accountCard(Json a) => Card(
        margin: const EdgeInsets.only(top: 14),
        color: const Color(0xfff5f7fb),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                a['displayName']?.toString().isNotEmpty == true
                    ? a['displayName']
                    : a['email'] ?? '邮箱',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              SelectableText(a['email'] ?? ''),
              const SizedBox(height: 6),
              Text(
                '${a['provider'] ?? '邮箱'} · ${status(a)}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              if (a['lastSyncAt'] != null)
                Text(
                  '最近同步：${a['lastSyncAt']}',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              if (a['canDisconnect'] == false)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '存在待处理或结果未确认的操作，暂不可断开',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: 10),
              if (editingId == a['id']) ...[
                TextField(
                  key: ValueKey('account-name-${a['id']}'),
                  controller: name,
                  enabled: !locked,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: '显示名称'),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: locked ? null : saveName,
                      child: const Text('保存名称'),
                    ),
                    TextButton(
                      onPressed: locked
                          ? null
                          : () async {
                              if (await canLeave() && mounted) {
                                setState(() => editingId = null);
                              }
                            },
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ] else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      key: ValueKey('edit-account-${a['id']}'),
                      onPressed: locked ? null : () => edit(a),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('编辑名称'),
                    ),
                    TextButton.icon(
                      key: ValueKey('disconnect-account-${a['id']}'),
                      onPressed: locked || a['canDisconnect'] == false
                          ? null
                          : () => disconnect(a),
                      icon: const Icon(Icons.link_off, size: 18),
                      label: const Text('断开连接'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      );
}

/// Kept for callers that embed the old entry point; the content itself is a page.
class SettingsDialog extends AccountSettingsPage {
  const SettingsDialog({super.key, required super.api, required super.caps});
}

class AddAccountPage extends StatefulWidget {
  final MailApi api;
  final Json caps;
  final VoidCallback? onClose, onConnected, onOAuthSettings;
  const AddAccountPage({
    super.key,
    required this.api,
    required this.caps,
    this.onClose,
    this.onConnected,
    this.onOAuthSettings,
  });
  @override
  AddAccountPageState createState() => AddAccountPageState();
}

class AddAccountPageState extends State<AddAccountPage> {
  final email = TextEditingController(),
      name = TextEditingController(),
      code = TextEditingController();
  String provider = 'QQ', error = '', notice = '';
  bool busy = false, confirming = false;
  bool get protectsDocumentExit =>
      busy || confirming || oauthFlow != null || dirty;
  bool get dirty =>
      email.text.isNotEmpty || name.text.isNotEmpty || code.text.isNotEmpty;
  Future<bool> canLeave() async {
    if (busy || confirming || oauthFlow != null) return false;
    if (!dirty) return true;
    setState(() => confirming = true);
    try {
      return await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('放弃未保存的连接信息？'),
              content: const Text('邮箱地址、显示名称和授权码输入将被清除，不会连接邮箱。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('继续编辑'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('放弃更改'),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  Future<void> requestClose() async {
    if (await canLeave() && mounted) {
      if (widget.onClose != null) {
        widget.onClose!();
      } else {
        Navigator.pop(context);
      }
    }
  }

  void connected() {
    email.clear();
    name.clear();
    code.clear();
    if (widget.onConnected != null) {
      widget.onConnected!();
    } else {
      Navigator.pop(context);
    }
  }

  String safeError(Object e) => e is ApiException && e.code == 'UNAUTHORIZED'
      ? '会话已过期，请重新登录'
      : '连接未完成，请检查配置后重试。授权码不会显示在错误信息中。';
  OAuthBrowserFlow? oauthFlow;
  late Json capabilities = widget.caps;
  @override
  void dispose() {
    oauthFlow?.cancel();
    email.dispose();
    name.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> add() async {
    if (busy || oauthFlow != null) return;
    if (email.text.trim().isEmpty || code.text.isEmpty) {
      setState(() => error = '请输入邮箱地址和授权码');
      return;
    }
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      await widget.api.request(
        'POST',
        '/accounts/imap',
        body: {
          'provider': provider,
          'email': email.text.trim(),
          'displayName':
              name.text.trim().isEmpty ? email.text.trim() : name.text.trim(),
          'authorizationCode': code.text,
        },
      );
      code.clear();
      if (mounted) connected();
    } catch (e) {
      if (mounted) {
        setState(() {
          code.clear();
          error = safeError(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> systemOAuthSettings() async {
    if (await canLeave() && mounted) widget.onOAuthSettings?.call();
  }

  Future<void> oauth(Json p) async {
    if (busy || oauthFlow != null) return;
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      oauthFlow = prepareOAuthBrowser((success) {
        if (!mounted) return;
        oauthFlow = null;
        if (success) {
          connected();
        } else {
          setState(() => notice = '等待授权已超时。可重新连接；若已完成授权，请关闭设置查看账户。');
        }
      });
      final data = await widget.api.request(
        'POST',
        '/oauth/${p['provider']}/start',
        body: {if (oauthFlow != null) 'completionId': oauthFlow!.id},
      );
      if (!mounted) return;
      final uri = Uri.parse(data['authorizationUrl']);
      if (uri.scheme != 'https') {
        throw ApiException('UNSAFE_URL', '授权地址必须使用 HTTPS');
      }
      final opened = oauthFlow != null
          ? oauthFlow!.open(uri.toString())
          : await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw ApiException('OPEN_FAILED', '无法打开授权页');
      }
      if (mounted) {
        setState(() {
          error = '';
          notice = oauthFlow != null
              ? '请在新窗口完成授权，成功后将自动返回并刷新账户。若已关闭授权窗口，可取消等待后重试。'
              : '请在浏览器完成授权，再返回此应用并关闭设置以刷新账户。';
        });
      }
    } catch (e) {
      oauthFlow?.cancel();
      oauthFlow = null;
      if (mounted) {
        setState(() {
          code.clear();
          error = safeError(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回账户设置',
                  onPressed: busy || oauthFlow != null ? null : requestClose,
                  icon: const Icon(Icons.arrow_back),
                ),
                const Expanded(
                  child: Text(
                    '添加邮箱',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: [
                const Text('授权连接',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text(
                  '真实账户需先配置 OAuth 应用。保存配置不等于邮箱已连接，授权在服务商页面完成。',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.6),
                ),
                if (capabilities['features']?['oauthSettings'] == true)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: OutlinedButton.icon(
                      onPressed: busy || oauthFlow != null
                          ? null
                          : systemOAuthSettings,
                      icon: const Icon(Icons.admin_panel_settings_outlined),
                      label: const Text('系统 OAuth 设置'),
                    ),
                  ),
                ...((capabilities['providers'] as List?) ?? [])
                    .where((p) => p['supportsOAuth'] == true)
                    .map(
                      (p) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.link, color: blue),
                        title: Text(
                          oauthProviderNames[p['provider']] ?? p['provider'],
                        ),
                        subtitle: Text(
                          p['configured'] == true
                              ? '本地配置完整 · 仍需服务商授权'
                              : '服务器尚未配置 OAuth',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: OutlinedButton(
                          onPressed: busy ||
                                  oauthFlow != null ||
                                  p['configured'] != true
                              ? null
                              : () => oauth(Map<String, dynamic>.from(p)),
                          child: const Text('连接'),
                        ),
                      ),
                    ),
                const Divider(height: 30),
                const Text(
                  'QQ / 163 邮箱',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: provider,
                  items: const [
                    DropdownMenuItem(value: 'QQ', child: Text('QQ 邮箱')),
                    DropdownMenuItem(value: 'NETEASE', child: Text('163 邮箱')),
                  ],
                  onChanged: busy || oauthFlow != null
                      ? null
                      : (v) => setState(() => provider = v!),
                  decoration: const InputDecoration(labelText: '服务商'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: email,
                  enabled: !busy && oauthFlow == null,
                  decoration: const InputDecoration(labelText: '邮箱地址'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: name,
                  enabled: !busy && oauthFlow == null,
                  decoration: const InputDecoration(labelText: '显示名称（可选）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: code,
                  enabled: !busy && oauthFlow == null,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration:
                      const InputDecoration(labelText: 'IMAP / SMTP 授权码'),
                ),
                const SizedBox(height: 10),
                const Text(
                  '授权码将发送至你的服务器并加密保存。需在邮箱设置中先开启 IMAP / SMTP；请勿填写网页登录密码。',
                  style: TextStyle(fontSize: 11, color: muted, height: 1.6),
                ),
                const SizedBox(height: 12),
                const Divider(height: 30),
                const Text('本版边界',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                  '• Web 版支持隔离 HTML 阅读，远程图片默认阻止\n• 纯文本撰写；原生端使用纯文本阅读\n• 不提供离线缓存或离线变更重放\n• 列表每 30 秒刷新，支持手动同步\n• 仅显示服务器已同步范围内的搜索结果\n• 登录凭证仅存内存，关闭会话即清除',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.9),
                ),
                if (oauthFlow != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            oauthFlow?.cancel();
                            setState(() {
                              oauthFlow = null;
                              notice = '已停止等待。若授权仍在进行，请关闭授权窗口后再重试。';
                            });
                          },
                    child: const Text('取消等待'),
                  ),
                if (notice.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      notice,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: busy || oauthFlow != null ? null : add,
                    child: Text(busy ? '连接中…' : '添加邮箱'),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}
