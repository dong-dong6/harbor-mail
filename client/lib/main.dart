import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'oauth_settings.dart';

void main() => runApp(MailApp());
const ink = Color(0xff24344c),
    blue = Color(0xff3363cd),
    muted = Color(0xff7c899c),
    canvas = Color(0xfff5f7fb);
typedef Json = Map<String, dynamic>;

class MailApp extends StatelessWidget {
  final MailApi? api;
  const MailApp({super.key, this.api});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '泊信 · Harbor Mail',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme:
              ColorScheme.fromSeed(seedColor: blue, surface: Colors.white),
          scaffoldBackgroundColor: canvas,
          fontFamily: 'NotoSansSC',
          textTheme: const TextTheme(bodyMedium: TextStyle(color: ink)),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: canvas,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
          cardTheme: const CardThemeData(elevation: 0),
        ),
        home: Mailbox(api: api ?? MailApi()),
      );
}

class Mailbox extends StatefulWidget {
  final MailApi api;
  const Mailbox({super.key, required this.api});
  @override
  State<Mailbox> createState() => _MailboxState();
}

class _MailboxState extends State<Mailbox> {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final username = TextEditingController(),
      password = TextEditingController(),
      search = TextEditingController();
  List<Json> accounts = [], messages = [], folders = [];
  Json? selected, caps;
  String folder = 'INBOX', account = '', coverage = '', error = '';
  bool logged = false,
      busy = false,
      loading = false,
      unread = false,
      actionBusy = false,
      more = false;
  String? cursor;
  int generation = 0, detailGeneration = 0;
  Timer? poll, debounce;
  MailApi get api => widget.api;
  List<Json> rows(dynamic value) =>
      (value as List? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
  @override
  void dispose() {
    poll?.cancel();
    debounce?.cancel();
    username.dispose();
    password.dispose();
    search.dispose();
    api.dispose();
    super.dispose();
  }

  void notify(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void fail(Object e) {
    if (!mounted) return;
    setState(() => error = e.toString());
    if (api.token == null && logged) {
      endSession(message: e.toString());
    }
  }

  Future<void> login() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await api.login(username.text.trim(), password.text);
      password.clear();
      setState(() => logged = true);
      await refresh();
      poll = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!loading && !actionBusy) refresh(silent: true);
      });
    } catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh({bool silent = false, bool append = false}) async {
    if (!logged || !mounted) return;
    final gen = ++generation;
    var nextAccounts = accounts;
    var nextCaps = caps;
    if (!silent) setState(() => loading = true);
    try {
      if (!append) {
        nextAccounts = rows((await api.request('GET', '/accounts'))['items']);
        nextCaps = Map<String, dynamic>.from(
          await api.request('GET', '/settings/capabilities'),
        );
      }
      final data = await api.request(
        'GET',
        '/messages',
        query: {
          'folder': folder,
          'limit': '40',
          'unreadOnly': '$unread',
          if (account.isNotEmpty) 'accountId': account,
          if (search.text.trim().isNotEmpty) 'query': search.text.trim(),
          if (append && cursor != null) 'cursor': cursor!,
        },
      );
      if (!mounted || gen != generation) return;
      setState(() {
        accounts = nextAccounts;
        caps = nextCaps;
        messages = append
            ? [...messages, ...rows(data['items'])]
            : rows(data['items']);
        coverage = data['coverage'] ?? '';
        more = data['hasMore'] == true;
        cursor = data['nextCursor'];
        error = '';
      });
    } catch (e) {
      if (gen == generation) fail(e);
    } finally {
      if (mounted && gen == generation) setState(() => loading = false);
    }
  }

  Future<void> chooseAccount(String id) async {
    scaffoldKey.currentState?.closeDrawer();
    setState(() {
      account = id;
      selected = null;
      folders = [];
    });
    refresh();
    if (id.isNotEmpty) {
      try {
        final data = await api.request('GET', '/accounts/$id/folders');
        if (mounted && account == id) {
          setState(() => folders = rows(data['items']));
        }
      } catch (e) {
        fail(e);
      }
    }
  }

  Future<void> open(Json mail) async {
    final gen = ++detailGeneration;
    setState(() => selected = {...mail, '_loading': true});
    try {
      final data = await api.request('GET', '/messages/${mail['id']}');
      if (mounted && gen == detailGeneration) {
        setState(() => selected = Map<String, dynamic>.from(data));
      }
    } catch (e) {
      fail(e);
      if (mounted && gen == detailGeneration) {
        setState(() => selected = {...mail, '_error': true});
      }
    }
  }

  Future<void> command(String type, {bool? value}) async {
    if (selected == null || actionBusy) return;
    setState(() => actionBusy = true);
    final item = selected!;
    try {
      final result = await api.request(
        'POST',
        '/commands',
        key: '${DateTime.now().microsecondsSinceEpoch}-$type',
        body: {
          'type': type,
          'messageId': item['id'],
          'baseRevision': item['revision'],
          if (value != null) 'value': value,
        },
      );
      var state = result['status'];
      for (var n = 0;
          n < 20 &&
              ![
                'SUCCEEDED',
                'COMPLETED',
                'APPLIED',
                'FAILED',
                'UNKNOWN',
              ].contains(state);
          n++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        state = (await api.request(
          'GET',
          '/commands/${result['id']}',
        ))['status'];
      }
      notify(
        state == 'FAILED'
            ? '操作失败，请刷新后重试'
            : state == 'UNKNOWN'
                ? '结果待核实，请勿重复提交'
                : '操作状态：$state',
      );
      await refresh(silent: true);
      if (['TRASH', 'ARCHIVE', 'RESTORE'].contains(type)) {
        if (mounted) setState(() => selected = null);
      } else {
        await open(item);
      }
    } catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> sync() async {
    if (actionBusy) return;
    setState(() => actionBusy = true);
    try {
      for (final a in accounts.where(
        (a) => account.isEmpty || a['id'] == account,
      )) {
        await api.request('POST', '/accounts/${a['id']}/sync');
      }
      notify('同步任务已提交，列表会定期刷新');
      await refresh();
    } catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> compose({Json? reply, Json? draft, bool forward = false}) async {
    if (accounts.isEmpty) {
      notify('请先在设置中添加邮箱');
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ComposeDialog(
        api: api,
        accounts: accounts,
        reply: reply,
        draft: draft,
        forward: forward,
        maxBytes: caps?['limits']?['maxAttachmentBytes'] ?? 10485760,
        onSaved: notify,
        onViewStatus: outbox,
      ),
    );
    refresh(silent: true);
  }

  Future<void> showDrafts() async {
    try {
      final drafts = rows((await api.request('GET', '/drafts'))['items']);
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('草稿箱'),
          content: SizedBox(
            width: 500,
            child: drafts.isEmpty
                ? const Text('暂时没有草稿')
                : ListView(
                    shrinkWrap: true,
                    children: drafts
                        .map(
                          (d) => ListTile(
                            title: Text(
                              d['subject']?.toString().isNotEmpty == true
                                  ? d['subject']
                                  : '（无主题）',
                            ),
                            subtitle: Text(d['updatedAt'] ?? ''),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              Navigator.pop(ctx);
                              compose(draft: d);
                            },
                          ),
                        )
                        .toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      fail(e);
    }
  }

  Future<void> outbox() async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => OutboxDialog(api: api),
    );
  }

  Future<void> settings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(api: api, caps: caps ?? {}),
    );
    refresh(silent: true);
  }

  Future<void> signout() async {
    try {
      await api.request('POST', '/auth/logout');
    } catch (e) {
      notify('服务器登出未确认；本机登录信息已清除');
    }
    endSession();
  }

  void endSession({String message = ''}) {
    api.token = null;
    poll?.cancel();
    debounce?.cancel();
    generation++;
    detailGeneration++;
    search.clear();
    if (!mounted) return;
    setState(() {
      logged = false;
      loading = false;
      accounts = [];
      messages = [];
      folders = [];
      caps = null;
      selected = null;
      account = '';
      folder = 'INBOX';
      cursor = null;
      more = false;
      unread = false;
      error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!logged) return loginView();
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            const _ComposeIntent(),
      },
      child: Actions(
        actions: {
          _ComposeIntent: CallbackAction<_ComposeIntent>(
            onInvoke: (_) {
              compose();
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, c) {
            final desktop = c.maxWidth >= 1050;
            final wide = c.maxWidth >= 720;
            return Scaffold(
              key: scaffoldKey,
              drawer: wide ? null : Drawer(child: sidebar()),
              body: SafeArea(
                child: Column(
                  children: [
                    if (caps?['demoMode'] == true)
                      Container(
                        width: double.infinity,
                        color: const Color(0xfffff3d9),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 8,
                        ),
                        child: const Text(
                          '演示环境 · 所有邮件均为合成数据，发送仅保存在本地，不会投递到真实邮箱',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xff806029),
                          ),
                        ),
                      ),
                    Expanded(
                      child: Row(
                        children: [
                          if (wide) SizedBox(width: 224, child: sidebar()),
                          if (wide)
                            const VerticalDivider(
                              width: 1,
                              color: Color(0xffe6ebf2),
                            ),
                          Expanded(
                            child: Column(
                              children: [
                                topbar(!wide),
                                if (error.isNotEmpty)
                                  MaterialBanner(
                                    content: Text(error),
                                    actions: [
                                      TextButton(
                                        onPressed: refresh,
                                        child: const Text('重试'),
                                      ),
                                    ],
                                  ),
                                Expanded(
                                  child: Row(
                                    children: [
                                      if (desktop || selected == null)
                                        SizedBox(
                                          width: desktop ? 355 : null,
                                          child: desktop ? messageList() : null,
                                        ),
                                      if (!desktop && selected == null)
                                        Expanded(child: messageList()),
                                      if (desktop)
                                        const VerticalDivider(
                                          width: 1,
                                          color: Color(0xffe6ebf2),
                                        ),
                                      if (desktop || selected != null)
                                        Expanded(child: detail(!desktop)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget loginView() => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 410),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.mark_email_unread_rounded,
                    size: 44,
                    color: blue,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '泊信',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '你的邮箱，一个安静的地方。',
                    style: TextStyle(fontSize: 17, color: muted),
                  ),
                  const SizedBox(height: 36),
                  const Text(
                    '登录你的私人邮件服务器',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: username,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: '用户名'),
                    onSubmitted: (_) => login(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: '密码'),
                    onSubmitted: (_) => login(),
                  ),
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: busy ? null : login,
                      child: Text(busy ? '正在连接…' : '登录'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '连接由你掌控的服务器。登录凭证仅保存在本次会话内；刷新或关闭后需重新登录。',
                    style: TextStyle(fontSize: 12, color: muted, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
  Widget sidebar() => Material(
      color: const Color(0xfff8faff),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.mark_email_unread_rounded, color: blue, size: 27),
                  SizedBox(width: 10),
                  Text(
                    '泊信',
                    style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(width: 7),
                  Text(
                    'MAIL',
                    style:
                        TextStyle(fontSize: 10, letterSpacing: 2, color: muted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton.icon(
                onPressed: () => compose(),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('写邮件'),
              ),
            ),
            const SizedBox(height: 26),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  nav('收件箱', Icons.inbox_outlined, 'INBOX'),
                  nav('星标邮件', Icons.star_border_rounded, 'STARRED'),
                  nav('已发送', Icons.send_outlined, 'SENT'),
                  nav('归档', Icons.archive_outlined, 'ARCHIVE'),
                  nav('废纸篓', Icons.delete_outline, 'TRASH'),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.drafts_outlined, size: 19),
                    title: const Text('草稿箱'),
                    onTap: showDrafts,
                  ),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.outbox_outlined, size: 19),
                    title: const Text('发件状态'),
                    onTap: outbox,
                  ),
                  const SizedBox(height: 25),
                  const Padding(
                    padding: EdgeInsets.only(left: 12, bottom: 10),
                    child: Text(
                      '邮箱账户',
                      style: TextStyle(
                        fontSize: 11,
                        color: muted,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  accountTile(null),
                  ...accounts.map(accountTile),
                  if (folders.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text(
                      '账户文件夹',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                    ...folders.map(
                      (f) => ListTile(
                        dense: true,
                        title: Text(
                          f['name'] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          '${f['unreadCount'] ?? 0}',
                          style: const TextStyle(color: muted),
                        ),
                        onTap: () {
                          setState(() {
                            folder = f['role'] ?? f['id'];
                            selected = null;
                          });
                          refresh();
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(),
            ListTile(
              dense: true,
              leading: const Icon(Icons.settings_outlined, size: 20),
              title: const Text('账户与设置'),
              onTap: settings,
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.logout, size: 20),
              title: const Text('退出登录'),
              onTap: signout,
            ),
            const Padding(
              padding: EdgeInsets.only(left: 12, top: 8),
              child: Text(
                'HARBOR MAIL  /  v0.1',
                style: TextStyle(fontSize: 9, color: muted, letterSpacing: 1.3),
              ),
            ),
          ],
        ),
      ));
  Widget nav(String label, IconData icon, String id) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          selected: folder == id,
          selectedTileColor: const Color(0xffe9effd),
          selectedColor: blue,
          leading: Icon(icon, size: 20),
          title: Text(
            label,
            style: TextStyle(
              fontWeight: folder == id ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          onTap: () {
            setState(() {
              folder = id;
              selected = null;
            });
            refresh();
            scaffoldKey.currentState?.closeDrawer();
          },
        ),
      );
  Widget accountTile(Json? a) {
    final id = a?['id'] ?? '';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(
        a == null ? Icons.all_inbox_outlined : Icons.circle,
        size: a == null ? 18 : 8,
        color: account == id ? blue : muted,
      ),
      title: Text(
        a?['displayName'] ?? '全部账户',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: account == id ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: a == null
          ? null
          : Text(
              '${a['email']} · ${a['status']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10),
            ),
      onTap: () => chooseAccount(id),
    );
  }

  Widget topbar(bool menu) => Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        color: Colors.white,
        child: Row(
          children: [
            if (menu)
              Builder(
                builder: (ctx) => IconButton(
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                  icon: const Icon(Icons.menu),
                ),
              ),
            Expanded(
              child: TextField(
                controller: search,
                onChanged: (_) {
                  debounce?.cancel();
                  debounce = Timer(const Duration(milliseconds: 400), () {
                    setState(() => selected = null);
                    refresh();
                  });
                },
                decoration: const InputDecoration(
                  hintText: '搜索已同步的邮件',
                  hintStyle: TextStyle(fontSize: 13, color: muted),
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 14),
            IconButton(
              tooltip: '同步邮箱',
              onPressed: actionBusy ? null : sync,
              icon: const Icon(Icons.sync, size: 21),
            ),
            const SizedBox(width: 8),
            const CircleAvatar(
              radius: 17,
              backgroundColor: Color(0xffe8edfa),
              child: Icon(Icons.person_outline, size: 19, color: blue),
            ),
          ],
        ),
      );
  Widget messageList() => Container(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 18, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          {
                                'INBOX': '收件箱',
                                'STARRED': '星标邮件',
                                'SENT': '已发送',
                                'ARCHIVE': '归档',
                                'TRASH': '废纸篓',
                              }[folder] ??
                              '邮件',
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${messages.length} 封已加载 · ${coverage == 'DEMO' ? '演示数据' : coverage == 'FULL' ? '完整索引' : '近期同步范围'}',
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ],
                    ),
                  ),
                  FilterChip(
                    label: const Text('未读', style: TextStyle(fontSize: 11)),
                    selected: unread,
                    onSelected: (v) {
                      setState(() => unread = v);
                      refresh();
                    },
                  ),
                ],
              ),
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: messages.isEmpty && !loading
                  ? empty('这里很安静', '没有符合条件的邮件', Icons.inbox_outlined)
                  : ListView.separated(
                      itemCount: messages.length + (more ? 1 : 0),
                      separatorBuilder: (_, index) => const Divider(
                        height: 1,
                        indent: 22,
                        endIndent: 22,
                        color: Color(0xffedf0f5),
                      ),
                      itemBuilder: (ctx, i) {
                        if (i == messages.length) {
                          return TextButton(
                            onPressed:
                                loading ? null : () => refresh(append: true),
                            child: const Text('加载更多'),
                          );
                        }
                        final m = messages[i],
                            chosen = selected?['id'] == m['id'],
                            read = m['isRead'] == true;
                        return InkWell(
                          onTap: () => open(m),
                          child: Container(
                            decoration: BoxDecoration(
                              color: chosen ? const Color(0xffeef3ff) : null,
                              border: Border(
                                left: BorderSide(
                                  color: chosen ? blue : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            padding: const EdgeInsets.fromLTRB(19, 20, 18, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (!read) ...[
                                      const Icon(
                                        Icons.circle,
                                        size: 6,
                                        color: blue,
                                      ),
                                      const SizedBox(width: 7),
                                    ],
                                    Expanded(
                                      child: Text(
                                        m['fromName']?.toString().isNotEmpty ==
                                                true
                                            ? m['fromName']
                                            : m['fromAddress'] ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: read
                                              ? FontWeight.w400
                                              : FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      date(m['receivedAt']),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: muted,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  m['subject'] ?? '（无主题）',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: read
                                        ? FontWeight.w400
                                        : FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  m['snippet'] ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                    height: 1.6,
                                  ),
                                ),
                                if (m['isStarred'] == true ||
                                    m['hasAttachments'] == true)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Row(
                                      children: [
                                        if (m['isStarred'] == true)
                                          const Icon(
                                            Icons.star_rounded,
                                            size: 14,
                                            color: Color(0xffd7a746),
                                          ),
                                        if (m['hasAttachments'] == true)
                                          const Icon(
                                            Icons.attach_file,
                                            size: 14,
                                            color: muted,
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(15),
              child: const Row(
                children: [
                  Icon(Icons.cloud_outlined, size: 13, color: muted),
                  SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '每 30 秒刷新 · 未启用离线操作',
                      style: TextStyle(fontSize: 10, color: muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
  String date(dynamic value) {
    final dt = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    return dt == null ? '' : '${dt.month}/${dt.day}';
  }

  Widget empty(String title, String subtitle, IconData icon) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 55, color: const Color(0xffc7d2e7)),
              const SizedBox(height: 20),
              Text(
                title,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 9),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: muted, height: 1.6),
              ),
            ],
          ),
        ),
      );
  Widget detail(bool back) {
    final m = selected;
    if (m == null) {
      return empty(
        '为重要的消息留一点空间',
        '选择一封邮件，开始阅读\n你的多个邮箱，在这里井然有序',
        Icons.mark_email_read_outlined,
      );
    }
    return Container(
      color: canvas,
      child: Column(
        children: [
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (back)
                  IconButton(
                    tooltip: '返回列表',
                    onPressed: () => setState(() => selected = null),
                    icon: const Icon(Icons.arrow_back),
                  ),
                IconButton(
                  tooltip: m['isRead'] == true ? '标为未读' : '标为已读',
                  onPressed: actionBusy || m['_loading'] == true
                      ? null
                      : () => command('SET_READ', value: m['isRead'] != true),
                  icon: Icon(
                    m['isRead'] == true
                        ? Icons.mark_email_unread_outlined
                        : Icons.mark_email_read_outlined,
                  ),
                ),
                IconButton(
                  tooltip: '星标',
                  onPressed: actionBusy || m['_loading'] == true
                      ? null
                      : () =>
                          command('SET_STAR', value: m['isStarred'] != true),
                  icon: Icon(
                    m['isStarred'] == true ? Icons.star : Icons.star_border,
                    color: m['isStarred'] == true ? Colors.amber : ink,
                  ),
                ),
                IconButton(
                  tooltip: '归档',
                  onPressed: actionBusy || m['_loading'] == true
                      ? null
                      : () => command('ARCHIVE'),
                  icon: const Icon(Icons.archive_outlined),
                ),
                IconButton(
                  tooltip: folder == 'TRASH' ? '恢复到收件箱' : '移至废纸篓',
                  onPressed: actionBusy || m['_loading'] == true
                      ? null
                      : () => command(folder == 'TRASH' ? 'RESTORE' : 'TRASH'),
                  icon: Icon(
                    folder == 'TRASH'
                        ? Icons.restore_from_trash_outlined
                        : Icons.delete_outline,
                  ),
                ),
                const Spacer(),
                const Text(
                  '安全纯文本',
                  style: TextStyle(fontSize: 10, color: muted),
                ),
              ],
            ),
          ),
          if (actionBusy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: m['_loading'] == true
                ? const Center(child: CircularProgressIndicator())
                : m['_error'] == true
                    ? Center(
                        child: TextButton(
                          onPressed: () => open(m),
                          child: const Text('加载失败，重试'),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(30, 10, 30, 32),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(30),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xffe9edf4)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m['subject'] ?? '（无主题）',
                                style: const TextStyle(
                                  fontSize: 25,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 28),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xffe9eefb),
                                    child: Text(
                                      (m['fromName']?.toString().isNotEmpty ==
                                                  true
                                              ? m['fromName']
                                              : m['fromAddress'] ?? '?')
                                          .toString()
                                          .substring(0, 1),
                                      style: const TextStyle(color: blue),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          m['fromName'] ??
                                              m['fromAddress'] ??
                                              '',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        SelectableText(
                                          m['fromAddress'] ?? '',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: muted,
                                          ),
                                        ),
                                        const SizedBox(height: 7),
                                        Text(
                                          '收件人：${(m['to'] as List? ?? []).map((e) => e['address']).join(', ')}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: muted,
                                          ),
                                        ),
                                        Text(
                                          m['receivedAt'] ?? '',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 26),
                              const Divider(color: Color(0xffedf0f5)),
                              const SizedBox(height: 24),
                              SelectableText(
                                m['bodyText']?.toString().isNotEmpty == true
                                    ? m['bodyText']
                                    : '此邮件没有纯文本正文。v0.1 不执行 HTML 内容或加载远程图片。',
                                style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.9,
                                  color: ink,
                                ),
                              ),
                              const SizedBox(height: 30),
                              ...rows(m['attachments']).map(
                                (a) => Card(
                                  color: canvas,
                                  child: ListTile(
                                    leading: const Icon(
                                      Icons.attach_file,
                                      color: blue,
                                    ),
                                    title: Text(
                                      a['fileName'] ?? '附件',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    subtitle: Text('${a['size'] ?? 0} bytes'),
                                    trailing: IconButton(
                                      tooltip: '下载附件',
                                      icon: const Icon(Icons.download_outlined),
                                      onPressed: () async {
                                        try {
                                          final bytes =
                                              await api.download(a['id']);
                                          await FileSaver.instance.saveFile(
                                            name: (a['fileName'] ??
                                                    'attachment')
                                                .toString()
                                                .replaceAll(
                                                    RegExp(r'[\\/\x00-\x1F]'),
                                                    '_'),
                                            bytes: bytes,
                                          );
                                        } catch (e) {
                                          notify(e.toString());
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () => compose(reply: m),
                                    icon: const Icon(Icons.reply, size: 17),
                                    label: const Text('回复'),
                                  ),
                                  TextButton.icon(
                                    onPressed: () =>
                                        compose(reply: m, forward: true),
                                    icon: const Icon(Icons.forward, size: 17),
                                    label: const Text('转发'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                '纯文本阅读 · 不加载追踪像素与外部图片',
                                style: TextStyle(fontSize: 10, color: muted),
                              ),
                            ],
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _ComposeIntent extends Intent {
  const _ComposeIntent();
}

class ComposeDialog extends StatefulWidget {
  final MailApi api;
  final List<Json> accounts;
  final Json? reply, draft;
  final bool forward;
  final int maxBytes;
  final void Function(String) onSaved;
  final VoidCallback? onViewStatus;
  const ComposeDialog({
    super.key,
    required this.api,
    required this.accounts,
    this.reply,
    this.draft,
    this.forward = false,
    required this.maxBytes,
    required this.onSaved,
    this.onViewStatus,
  });
  @override
  State<ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<ComposeDialog> {
  final to = TextEditingController(),
      cc = TextEditingController(),
      subject = TextEditingController(),
      body = TextEditingController();
  late String account;
  String? id;
  int? revision;
  bool busy = false;
  String error = '';
  final List<String> attachments = [];
  String? sendKey;
  bool sendUncertain = false;
  bool confirmingClose = false;
  late String savedSnapshot;
  String get snapshot =>
      jsonEncode([account, to.text, cc.text, subject.text, body.text]);
  @override
  void initState() {
    super.initState();
    final d = widget.draft, r = widget.reply;
    account = d?['accountId'] ?? r?['accountId'] ?? widget.accounts.first['id'];
    id = d?['id'];
    revision = d?['revision'];
    if (d != null) {
      to.text = (d['to'] as List? ?? []).map((e) => e['address']).join(', ');
      cc.text = (d['cc'] as List? ?? []).map((e) => e['address']).join(', ');
      subject.text = d['subject'] ?? '';
      body.text = d['bodyText'] ?? '';
      attachments.addAll((d['attachments'] as List? ?? [])
          .map((a) => a['fileName'].toString()));
    } else if (r != null) {
      to.text = widget.forward ? '' : r['fromAddress'] ?? '';
      subject.text = '${widget.forward ? 'Fwd' : 'Re'}: ${r['subject'] ?? ''}';
      body.text =
          '\n\n──────── 原邮件 ────────\n发件人：${r['fromAddress']}\n主题：${r['subject']}\n\n${r['bodyText'] ?? ''}';
    }
    savedSnapshot =
        d == null ? jsonEncode([account, '', '', '', '']) : snapshot;
  }

  @override
  void dispose() {
    to.dispose();
    cc.dispose();
    subject.dispose();
    body.dispose();
    super.dispose();
  }

  List<Json> recipients(String text) => text
      .split(RegExp(r'[,;，；\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((s) => <String, dynamic>{'address': s})
      .toList();
  Future<void> persist() async {
    final payload = {
      'accountId': account,
      'to': recipients(to.text),
      'cc': recipients(cc.text),
      'subject': subject.text,
      'bodyText': body.text,
      if (widget.reply != null && !widget.forward)
        'replyToMessageId': widget.reply!['id'],
      if (revision != null) 'revision': revision,
    };
    final data = await widget.api.request(
      id == null ? 'POST' : 'PATCH',
      id == null ? '/drafts' : '/drafts/$id',
      body: payload,
    );
    id = data['id'];
    revision = data['revision'];
    savedSnapshot = snapshot;
  }

  Future<void> act(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() => act(() async {
        await persist();
        widget.onSaved('草稿已保存');
      });
  Future<void> upload() => act(() async {
        final picked = await FilePicker.platform
            .pickFiles(withData: false, withReadStream: true);
        if (picked == null) return;
        final file = picked.files.single;
        if (file.size > widget.maxBytes) {
          throw ApiException(
            'FILE_TOO_LARGE',
            '附件超过 ${widget.maxBytes ~/ 1048576} MiB 上限',
          );
        }
        var bytes = file.bytes;
        if (bytes == null) {
          final stream = file.readStream;
          if (stream == null) {
            throw ApiException('FILE_UNAVAILABLE', '无法读取文件');
          }
          final buffer = BytesBuilder(copy: false);
          await for (final chunk in stream) {
            if (buffer.length + chunk.length > widget.maxBytes) {
              throw ApiException('FILE_TOO_LARGE', '附件超过上传上限');
            }
            buffer.add(chunk);
          }
          bytes = buffer.takeBytes();
        }
        await persist();
        await widget.api.upload(id!, file.name, bytes);
        final data = await widget.api.request('GET', '/drafts');
        final updated =
            (data['items'] as List).where((d) => d['id'] == id).firstOrNull;
        if (updated != null) revision = updated['revision'];
        if (mounted) setState(() => attachments.add(file.name));
      });
  Future<void> requestClose() async {
    if (busy || sendUncertain || confirmingClose) return;
    if (snapshot != savedSnapshot) {
      confirmingClose = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('放弃未保存的更改？'),
          content: const Text('这些更改尚未保存。放弃后无法恢复；已保存的草稿会保留。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('继续编辑')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('放弃更改')),
          ],
        ),
      );
      confirmingClose = false;
      if (discard != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  void viewUncertainStatus() {
    if (busy || !sendUncertain) return;
    Navigator.pop(context);
    widget.onViewStatus?.call();
  }

  Future<void> send() async {
    if (busy || sendUncertain) return;
    final addresses = recipients(to.text);
    if (addresses.isEmpty ||
        [...addresses, ...recipients(cc.text)].any(
          (a) => !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(a['address']),
        )) {
      setState(() => error = '请输入有效收件人地址，多个地址用逗号分隔');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认发送'),
        content: Text(
          '将从 ${widget.accounts.firstWhere((a) => a['id'] == account)['email']} 发送至 ${to.text}${cc.text.isEmpty ? '' : '，抄送 ${cc.text}'}。\n\n主题：${subject.text.isEmpty ? '（无主题）' : subject.text}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await act(() async {
      await persist();
      sendKey ??= 'send-${DateTime.now().microsecondsSinceEpoch}';
      try {
        final result = await widget.api.request(
          'POST',
          '/drafts/$id/send',
          key: sendKey,
          body: {'revision': revision},
        );
        widget.onSaved('邮件已进入发件队列（${result['status']}），请在「发件状态」查看结果');
        if (mounted) Navigator.pop(context);
      } catch (e) {
        if (e is ApiException && e.code == 'NETWORK') {
          sendUncertain = true;
          throw ApiException(
              'SEND_UNCERTAIN', '提交结果暂不确定。请通过下方按钮查看发件状态，不要重复发送。');
        }
        rethrow;
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) requestClose();
      },
      child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): requestClose
          },
          child: Dialog(
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780, maxHeight: 760),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '写一封邮件',
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭写信窗口',
                          onPressed:
                              busy || sendUncertain ? null : requestClose,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: account,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: '发件邮箱'),
                              items: widget.accounts
                                  .map(
                                    (a) => DropdownMenuItem<String>(
                                      value: a['id'],
                                      child: Text(
                                        a['email'] ?? '',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: busy || id != null
                                  ? null
                                  : (v) => setState(() => account = v!),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: to,
                              enabled: !busy && !sendUncertain,
                              decoration: const InputDecoration(
                                labelText: '收件人',
                                hintText: 'name@example.com',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: cc,
                              enabled: !busy && !sendUncertain,
                              decoration:
                                  const InputDecoration(labelText: '抄送（可选）'),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: subject,
                              enabled: !busy && !sendUncertain,
                              decoration:
                                  const InputDecoration(labelText: '主题'),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: body,
                              enabled: !busy && !sendUncertain,
                              minLines: 9,
                              maxLines: 14,
                              decoration: const InputDecoration(
                                hintText: '从这里开始…',
                                alignLabelWithHint: true,
                              ),
                            ),
                            if (attachments.isNotEmpty)
                              Wrap(
                                spacing: 8,
                                children: attachments
                                    .map(
                                      (name) => Chip(
                                        avatar: const Icon(Icons.attach_file,
                                            size: 16),
                                        label: Text(name),
                                      ),
                                    )
                                    .toList(),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          error,
                          style:
                              const TextStyle(color: Colors.red, fontSize: 12),
                        ),
                      ),
                    if (sendUncertain)
                      TextButton.icon(
                          onPressed: busy ? null : viewUncertainStatus,
                          icon: const Icon(Icons.outbox_outlined),
                          label: const Text('关闭并查看发件状态')),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: busy || sendUncertain ? null : send,
                          icon: const Icon(Icons.send_outlined, size: 17),
                          label: Text(busy ? '处理中…' : '发送'),
                        ),
                        TextButton.icon(
                          onPressed: busy || sendUncertain ? null : save,
                          icon: const Icon(Icons.save_outlined, size: 17),
                          label: const Text('保存草稿'),
                        ),
                        TextButton.icon(
                          onPressed: busy || sendUncertain ? null : upload,
                          icon: const Icon(Icons.attach_file, size: 17),
                          label: Text('附件 ≤ ${widget.maxBytes ~/ 1048576} MiB'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '草稿需手动保存 · v0.1 仅支持纯文本正文',
                      style: TextStyle(fontSize: 10, color: muted),
                    ),
                  ],
                ),
              ),
            ),
          )));
}

class SettingsDialog extends StatefulWidget {
  final MailApi api;
  final Json caps;
  const SettingsDialog({super.key, required this.api, required this.caps});
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final email = TextEditingController(),
      name = TextEditingController(),
      code = TextEditingController();
  String provider = 'QQ', error = '';
  bool busy = false;
  late Json capabilities = widget.caps;
  @override
  void dispose() {
    email.dispose();
    name.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> add() async {
    if (busy) return;
    if (email.text.trim().isEmpty || code.text.isEmpty) {
      setState(() => error = '请输入邮箱地址和授权码');
      return;
    }
    setState(() => busy = true);
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
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> systemOAuthSettings() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => OAuthSettingsPage(
          api: widget.api,
          demoMode: capabilities['demoMode'] == true,
        ),
      ));
      if (!mounted) return;
      final next = await widget.api.request('GET', '/settings/capabilities');
      if (mounted) {
        setState(() => capabilities = Map<String, dynamic>.from(next));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> oauth(Json p) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final data = await widget.api.request(
        'POST',
        '/oauth/${p['provider']}/start',
        body: {},
      );
      final uri = Uri.parse(data['authorizationUrl']);
      if (uri.scheme != 'https') {
        throw ApiException('UNSAFE_URL', '授权地址必须使用 HTTPS');
      }
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw ApiException('OPEN_FAILED', '无法打开授权页');
      }
      if (mounted) setState(() => error = '请在浏览器完成授权，然后关闭设置并刷新账户列表');
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('账户与设置'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
                      onPressed: busy ? null : systemOAuthSettings,
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
                          onPressed: busy || p['configured'] != true
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
                  onChanged: busy ? null : (v) => setState(() => provider = v!),
                  decoration: const InputDecoration(labelText: '服务商'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: email,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '邮箱地址'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: name,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '显示名称（可选）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: code,
                  enabled: !busy,
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
                FilledButton(
                  onPressed: busy ? null : add,
                  child: Text(busy ? '连接中…' : '添加邮箱'),
                ),
                const Divider(height: 30),
                const Text('本版边界',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                  '• 纯文本阅读与撰写，不执行邮件 HTML\n• 不提供离线缓存或离线变更重放\n• 列表每 30 秒刷新，支持手动同步\n• 仅显示服务器已同步范围内的搜索结果\n• 登录凭证仅存内存，关闭会话即清除',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.9),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
}

class OutboxDialog extends StatefulWidget {
  final MailApi api;
  const OutboxDialog({super.key, required this.api});
  @override
  State<OutboxDialog> createState() => _OutboxDialogState();
}

class _OutboxDialogState extends State<OutboxDialog> {
  List<Json> items = [];
  String error = '';
  bool loading = true;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final data = await widget.api.request('GET', '/send-intents');
      if (mounted) {
        setState(() {
          items = (data['items'] as List)
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          error = '';
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('发件状态'),
        content: SizedBox(
          width: 540,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '“已被服务商接受”不保证收件人已收到。结果待核实时，请勿盲目重发。',
                style: TextStyle(fontSize: 12, color: muted, height: 1.6),
              ),
              const SizedBox(height: 18),
              if (loading) const LinearProgressIndicator(),
              if (error.isNotEmpty) Text(error),
              if (items.isEmpty && !loading)
                const Padding(
                    padding: EdgeInsets.all(24), child: Text('暂无发送记录')),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: items
                      .map(
                        (m) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            m['status'] == 'FAILED'
                                ? Icons.error_outline
                                : m['status'] == 'UNKNOWN'
                                    ? Icons.help_outline
                                    : Icons.outbox_outlined,
                            color: blue,
                          ),
                          title: Text(m['subject'] ?? '（无主题）'),
                          subtitle: Text(
                            '${{
                                  'QUEUED': '排队中',
                                  'PREPARING': '准备发送',
                                  'SUBMITTING': '提交中',
                                  'ACCEPTED': '已被服务商接受',
                                  'SENT_COPY_CONFIRMED': '已确认已发送副本',
                                  'FAILED': '发送失败',
                                  'UNKNOWN': '结果待核实'
                                }[m['status']] ?? m['status']}${m['errorCode'] == null ? '' : ' · ${m['errorCode']}'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: load, child: const Text('刷新')),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
}
