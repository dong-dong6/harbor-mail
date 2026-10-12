import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';

/// System-wide provider application settings, separate from mailbox consent.
class OAuthSettingsPage extends StatefulWidget {
  final MailApi api;
  final bool demoMode;
  final VoidCallback? onClose;
  const OAuthSettingsPage({
    super.key,
    required this.api,
    this.demoMode = false,
    this.onClose,
  });

  @override
  OAuthSettingsPageState createState() => OAuthSettingsPageState();
}

class OAuthSettingsPageState extends State<OAuthSettingsPage> {
  var formKey = GlobalKey<FormState>();
  final clientId = TextEditingController();
  final redirectUri = TextEditingController();
  final tenant = TextEditingController();
  final secret = TextEditingController();
  final pageFocus = FocusNode();
  OAuthSettingsSnapshot? snapshot;
  String provider = 'GMAIL', error = '', notice = '';
  bool loading = true, busy = false, confirming = false;
  bool clearSecret = false, needsReload = false, populating = false;

  OAuthProviderSettings? get current {
    final items = snapshot?.items;
    if (items == null) return null;
    return items.firstWhere((item) => item.provider == provider);
  }

  bool get readOnly =>
      widget.demoMode ||
      snapshot == null ||
      snapshot!.demoMode ||
      snapshot!.readOnly;
  bool get locked => loading || busy || confirming;
  bool get editable => !locked && !readOnly && !needsReload;
  bool get dirty {
    final saved = current;
    return saved != null &&
        (clientId.text.trim() != saved.clientId ||
            redirectUri.text.trim() != saved.redirectUri ||
            tenant.text.trim() != saved.tenant ||
            secret.text.isNotEmpty ||
            clearSecret);
  }

  @override
  void initState() {
    super.initState();
    for (final controller in [clientId, redirectUri, tenant, secret]) {
      controller.addListener(changed);
    }
    load();
  }

  @override
  void dispose() {
    // Secrets live only in the masked editor for this route's lifetime.
    for (final controller in [clientId, redirectUri, tenant, secret]) {
      controller.removeListener(changed);
      controller.dispose();
    }
    pageFocus.dispose();
    super.dispose();
  }

  void changed() {
    if (mounted && !populating) setState(() {});
  }

  void populate(OAuthProviderSettings saved) {
    populating = true;
    clientId.text = saved.clientId;
    redirectUri.text = saved.redirectUri;
    tenant.text = saved.tenant;
    secret.clear();
    clearSecret = false;
    populating = false;
    formKey = GlobalKey<FormState>();
  }

  String safeError(Object failure) {
    // Never render raw upstream errors or an echoed credential in this form.
    final code = failure is ApiException ? failure.code : '';
    return switch (code) {
      'UNAUTHORIZED' || 'HTTP_401' => '会话已过期，请关闭设置后重新登录',
      'FORBIDDEN' || 'HTTP_403' => '仅服务器管理员可以管理 OAuth 配置',
      'CONFIG_REVISION_CONFLICT' => '配置已被其他会话修改。请重新载入后核对，再保存',
      'DEMO_MODE' => '演示环境为只读，禁止保存真实 OAuth 凭据',
      'NETWORK' => '无法确认服务器响应，请重新载入配置后核对',
      'INVALID_REQUEST' => '配置未通过服务器校验，请检查应用 ID、回调地址和租户',
      'INVALID_RESPONSE' => '服务器配置响应不完整，请重新载入',
      _ => '操作未完成，请稍后重新载入；不要在错误报告中附上密钥',
    };
  }

  Future<bool> confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    if (confirming || !mounted) return false;
    setState(() => confirming = true);
    try {
      return await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: Text(title),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(action),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) {
        setState(() => confirming = false);
        pageFocus.requestFocus();
      }
    }
  }

  Future<bool> discard() async =>
      !dirty ||
      await confirm(
        title: '放弃未保存的配置？',
        message: '当前输入（包括新密钥）将被清除，不会保存到服务器。',
        action: '放弃更改',
      );

  Future<bool> canLeave() async => !busy && !confirming && await discard();
  Future<void> requestClose() async {
    if (await canLeave() && mounted) {
      if (widget.onClose != null) {
        widget.onClose!();
      } else {
        Navigator.pop(context);
      }
    }
  }

  Future<void> load({bool reload = false}) async {
    if (busy || confirming || (reload && loading)) return;
    if (reload && !await discard()) return;
    if (!mounted) return;
    setState(() {
      loading = true;
      error = '';
      notice = '';
    });
    try {
      final next = await widget.api.oauthSettings();
      if (!mounted) return;
      setState(() {
        snapshot = next;
        needsReload = false;
        populate(current!);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = safeError(e);
        needsReload = true;
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> selectProvider(String next) async {
    if (locked || next == provider || !await discard() || !mounted) return;
    setState(() {
      provider = next;
      error = '';
      notice = '';
      populate(current!);
    });
  }

  void replaceSaved(OAuthProviderSettings saved) {
    if (saved.provider != provider) {
      throw ApiException('INVALID_RESPONSE', '配置服务商不匹配');
    }
    final previous = snapshot!;
    snapshot = OAuthSettingsSnapshot(
      demoMode: previous.demoMode,
      readOnly: previous.readOnly,
      items: previous.items
          .map((item) => item.provider == provider ? saved : item)
          .toList(growable: false),
    );
    populate(saved);
  }

  Future<void> save() async {
    if (!editable || !dirty || !formKey.currentState!.validate()) return;
    final saved = current!;
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      final result = await widget.api.saveOAuthSettings(
        provider: provider,
        revision: saved.revision,
        clientId: clientId.text,
        redirectUri: redirectUri.text,
        tenant: tenant.text,
        clientSecret: secret.text,
        clearClientSecret: clearSecret,
      );
      if (!mounted) return;
      setState(() {
        replaceSaved(result);
        notice = '配置已保存，尚未经过服务商授权验证。请回到账户与设置连接邮箱。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final submittedSecret = secret.text.isNotEmpty;
        secret.clear();
        error = safeError(e);
        if (submittedSecret) error += ' 密钥输入已清空。';
        needsReload =
            e is! ApiException ||
            [
              'NETWORK',
              'CONFIG_REVISION_CONFLICT',
              'INVALID_RESPONSE',
              'DEMO_MODE',
              'UNAUTHORIZED',
              'HTTP_401',
              'FORBIDDEN',
              'HTTP_403',
            ].contains(e.code);
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> markSecretForClear() async {
    if (!editable || !current!.hasClientSecret) return;
    final approved = await confirm(
      title: '清除已保存的密钥？',
      message: '点击保存后生效。该服务商将无法发起新的授权或刷新令牌，直到重新配置。已有邮箱可能需要重新授权。',
      action: '标记清除',
    );
    if (!approved || !mounted) return;
    setState(() {
      secret.clear();
      clearSecret = true;
    });
  }

  Future<void> resetToEnvironment() async {
    if (!editable || current!.source != 'DATABASE') return;
    final approved = await confirm(
      title: '恢复环境配置？',
      message: '将删除此服务商的数据库覆盖配置（包括密钥），立即使用服务器环境配置。当前未保存的输入会被丢弃，已有邮箱可能需要重新授权。',
      action: '恢复环境配置',
    );
    if (!approved || !mounted) return;
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      final result = await widget.api.resetOAuthSettings(
        provider: provider,
        revision: current!.revision,
      );
      if (!mounted) return;
      setState(() {
        replaceSaved(result);
        notice = '已恢复环境配置，尚未经过服务商授权验证。请检查配置是否完整。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        secret.clear();
        error = safeError(e);
        needsReload = true;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String? validateRedirect(String? input) {
    final value = input?.trim() ?? '';
    if (value.isEmpty) {
      return null; // Incomplete drafts may be saved deliberately.
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !value.startsWith('https://') ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/api/v1/oauth/$provider/callback') {
      return '需使用 HTTPS，且路径为 /api/v1/oauth/$provider/callback；不可含查询参数、片段或用户名';
    }
    return null;
  }

  String? validateTenant(String? input) {
    final value = input?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return null;
    if (provider == 'OUTLOOK') {
      return value == 'consumers' ? null : '个人 Outlook 的租户必须为 consumers';
    }
    if (provider == 'EXCHANGE') {
      final guid = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      );
      final domain = RegExp(
        r'^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$',
      );
      if (value != 'organizations' &&
          !guid.hasMatch(value) &&
          !domain.hasMatch(value)) {
        return '请输入 organizations、企业租户 GUID 或已验证域名；不支持 common / consumers';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) requestClose();
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): requestClose,
      },
      child: Focus(
        focusNode: pageFocus,
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('系统 OAuth 设置'),
            leading: IconButton(
              tooltip: '返回账户设置',
              onPressed: busy || confirming ? null : requestClose,
              icon: const Icon(Icons.arrow_back),
            ),
            actions: [
              IconButton(
                tooltip: '重新载入配置',
                onPressed: locked ? null : () => load(reload: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Text('管理员配置服务商应用；每个邮箱仍需在服务商页面单独授权。'),
                    const SizedBox(height: 12),
                    if (widget.demoMode || snapshot?.demoMode == true)
                      messageBox(
                        '演示环境 · 仅可查看配置状态。所有输入和保存均已禁用，请勿输入真实密钥。',
                        color: Colors.amber,
                      )
                    else if (snapshot?.readOnly == true)
                      messageBox('当前配置为只读，不能编辑或保存。'),
                    if (loading) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      const Text('正在载入配置…'),
                    ],
                    if (error.isNotEmpty) messageBox(error, color: Colors.red),
                    if (notice.isNotEmpty)
                      messageBox(notice, color: Colors.green),
                    if (snapshot != null) ...[
                      const SizedBox(height: 8),
                      InputDecorator(
                        decoration: const InputDecoration(labelText: '邮箱服务'),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            key: const Key('oauth-provider'),
                            value: provider,
                            isExpanded: true,
                            items: oauthProviderNames.entries
                                .map(
                                  (entry) => DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(entry.value),
                                  ),
                                )
                                .toList(),
                            onChanged: locked
                                ? null
                                : (value) => selectProvider(value!),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      editor(),
                    ] else if (!loading)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                          onPressed: () => load(reload: true),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新载入配置'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget messageBox(String text, {Color color = Colors.blue}) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: const TextStyle(height: 1.6)),
  );

  Widget editor() {
    final saved = current!;
    return Form(
      key: formKey,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                oauthProviderNames[provider]!,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text('配置来源：${saved.source == 'DATABASE' ? '数据库（已保存）' : '服务器环境'}'),
              Text(
                '本地校验：${saved.configured ? '配置完整' : '配置未完整或无效'} · 服务商验证：未验证',
              ),
              const SizedBox(height: 10),
              const Text(
                '保存成功仅表示配置已存储，不代表凭据有效、权限获批或邮箱已连接。修改应用、密钥、回调或租户后，已有邮箱可能需要重新授权。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              if (provider == 'EXCHANGE') ...[
                const SizedBox(height: 8),
                const Text(
                  '企业 Microsoft 365 / E3 使用工作或学校账号，须由租户管理员允许应用权限；E3 许可证本身不等于已授权。',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
              const SizedBox(height: 20),
              TextFormField(
                key: const Key('oauth-client-id'),
                controller: clientId,
                enabled: editable,
                maxLength: 1024,
                decoration: const InputDecoration(
                  labelText: '应用 ID（Client ID）',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('oauth-redirect-uri'),
                controller: redirectUri,
                enabled: editable,
                keyboardType: TextInputType.url,
                autocorrect: false,
                maxLength: 2048,
                validator: validateRedirect,
                decoration: InputDecoration(
                  labelText: 'HTTPS 回调地址（Redirect URI）',
                  hintText:
                      'https://mail.example.com/api/v1/oauth/$provider/callback',
                  helperText: '须与服务商后台登记的完整地址一致',
                  errorMaxLines: 4,
                ),
              ),
              if (provider != 'GMAIL') ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('oauth-tenant'),
                  controller: tenant,
                  enabled: editable,
                  maxLength: 253,
                  autocorrect: false,
                  validator: validateTenant,
                  decoration: InputDecoration(
                    labelText: 'Microsoft 租户（Tenant）',
                    helperText: provider == 'OUTLOOK'
                        ? '个人账号固定使用 consumers；留空使用该值'
                        : 'organizations、企业租户 GUID 或已验证域名；留空使用 organizations',
                    helperMaxLines: 3,
                    errorMaxLines: 4,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text('密钥状态：${saved.hasClientSecret ? '已配置（不可读取）' : '尚未配置'}'),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('oauth-client-secret'),
                controller: secret,
                enabled: editable && !clearSecret,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [],
                validator: (value) =>
                    (value?.length ?? 0) > 8192 ||
                        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value ?? '')
                    ? '密钥不能超过 8192 个字符或包含控制字符'
                    : null,
                decoration: const InputDecoration(
                  labelText: '新客户端密钥（Client Secret）',
                  helperText: '留空保留已有密钥；只可写入，服务器不会返回原值',
                  helperMaxLines: 3,
                ),
              ),
              if (clearSecret) ...[
                const SizedBox(height: 8),
                const Text('已标记清除密钥，点击保存后生效'),
                TextButton(
                  onPressed: editable
                      ? () => setState(() => clearSecret = false)
                      : null,
                  child: const Text('撤销清除'),
                ),
              ] else
                TextButton.icon(
                  key: const Key('oauth-clear-secret'),
                  onPressed: editable && saved.hasClientSecret
                      ? markSecretForClear
                      : null,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('清除已保存的密钥'),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('oauth-save'),
                    onPressed: editable && dirty ? save : null,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined, size: 18),
                    label: Text(busy ? '处理中…' : '保存配置'),
                  ),
                  OutlinedButton(
                    key: const Key('oauth-reset'),
                    onPressed: editable && saved.source == 'DATABASE'
                        ? resetToEnvironment
                        : null,
                    child: const Text('恢复环境配置'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '允许保存未完整的配置，但缺少必要字段时不能连接邮箱。保存后数据库配置优先于环境变量，只有恢复环境配置才会重新使用环境值。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
