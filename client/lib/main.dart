import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_saver/file_saver.dart';

import 'api.dart';
import 'mail_route.dart';
import 'mail_navigation.dart';
import 'compose_editor.dart';
export 'compose_editor.dart'
    show ComposeDialog, ComposeEditor, ComposeEditorState;
import 'account_settings.dart';
export 'account_settings.dart'
    show
        SettingsDialog,
        AccountSettingsPage,
        AccountSettingsPageState,
        AddAccountPage,
        AddAccountPageState;
import 'mail_header.dart';
import 'mail_body.dart';
import 'oauth_browser.dart';

void main() {
  configureBrowserNavigation();
  runApp(const MailApp());
}

const ink = Color(0xff24344c),
    blue = Color(0xff0b57d0),
    muted = Color(0xff7c899c),
    canvas = Color(0xfff5f7fb);
typedef Json = Map<String, dynamic>;

class MailApp extends StatelessWidget {
  final MailApi? api;
  final MailNavigation? navigation;
  const MailApp({super.key, this.api, this.navigation});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '泊信 · Harbor Mail',
        initialRoute: '/',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme:
              ColorScheme.fromSeed(seedColor: blue, surface: Colors.white)
                  .copyWith(
            primary: blue,
            primaryContainer: const Color(0xffc2e7ff),
            surfaceTint: Colors.transparent,
          ),
          dialogTheme: const DialogThemeData(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
          ),
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
        home: Mailbox(api: api ?? MailApi(), navigation: navigation),
      );
}

class Mailbox extends StatefulWidget {
  final MailApi api;
  final MailNavigation? navigation;
  const Mailbox({super.key, required this.api, this.navigation});
  @override
  MailboxState createState() => MailboxState();
}

class MailboxState extends State<Mailbox> {
  late final navigation = widget.navigation ?? MailNavigation();
  late MailRoute pendingRoute;
  bool applyingRoute = false;
  String settingsSection = 'accounts';
  MailRoute get currentRoute => MailRoute(
        messageId: selected?['id']?.toString(),
        account: account,
        folder: folder,
        filter: filter,
        settings: settingsOpen ? settingsSection : '',
      );
  void publishRoute() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && logged && !applyingRoute) {
        navigation.write(currentRoute.location);
        pendingRoute = currentRoute;
      }
    });
  }

  Future<bool> applyBrowserRoute(
    String location, {
    bool restoringLogin = false,
  }) async {
    final target = MailRoute.parse(location);
    if (!logged) {
      pendingRoute = target;
      return true;
    }
    if (applyingRoute || actionBusy || composeOpen) return false;
    applyingRoute = true;
    try {
      if (!restoringLogin && !await canLeave()) return false;
      if (!mounted || !logged) return false;
      debounce?.cancel();
      generation++;
      detailGeneration++;
      final accountExists = target.account.isEmpty ||
          accounts.any((a) => a['id'] == target.account);
      setState(() {
        account = accountExists ? target.account : '';
        folder = target.folder;
        filter = target.filter;
        unread = filter == 'unread';
        folders = [];
        search.clear();
        acceptedSearch = '';
        closeMessage();
        loading = false;
        refreshing = false;
        settingsOpen = target.settings.isNotEmpty;
        settingsSection =
            target.settings.isEmpty ? 'accounts' : target.settings;
        if (settingsSection == 'oauth' &&
            caps?['features']?['oauthSettings'] != true) {
          settingsSection = 'accounts';
        }
      });
      if (!accountExists) notify('链接中的邮箱账户不可用，请选择当前账户');
      if (settingsOpen) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !logged || !settingsOpen) return false;
        await settingsKey.currentState?.showSection(
          settingsSection,
          guarded: false,
        );
      } else {
        final routeGeneration = generation + 1;
        await refresh();
        if (!mounted || !logged || generation != routeGeneration) return false;
        if (target.messageId != null) {
          unawaited(open({'id': target.messageId}, guarded: false));
        }
      }
      pendingRoute = currentRoute;
      return true;
    } finally {
      applyingRoute = false;
      if (mounted && logged) {
        navigation.write(currentRoute.location, replace: restoringLogin);
      }
    }
  }

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
  final listScroll = ScrollController();
  bool refreshing = false, composeOpen = false, settingsOpen = false;
  String filter = 'all';
  final settingsKey = GlobalKey<AccountSettingsPageState>();
  final inlineComposeKey = GlobalKey<ComposeEditorState>();
  final inlineAnchorKey = GlobalKey();
  final detailScroll = ScrollController();
  Json? inlineReply;
  bool inlineForward = false, drawerOpen = false, guardingNavigation = false;
  String acceptedSearch = '';

  Future<bool> canLeave() async {
    if (guardingNavigation || composeOpen) return false;
    guardingNavigation = true;
    try {
      if (inlineReply != null &&
          !(await inlineComposeKey.currentState?.canLeave() ?? true)) {
        return false;
      }
      if (settingsOpen &&
          !(await settingsKey.currentState?.canLeave() ?? true)) {
        return false;
      }
      return mounted;
    } finally {
      guardingNavigation = false;
    }
  }

  Future<void> backToList() async {
    if (!await canLeave() || !mounted) return;
    setState(() {
      closeMessage();
      settingsOpen = false;
    });
  }

  Future<void> chooseFolder(String id) async {
    if (!await canLeave() || !mounted) return;
    setState(() {
      folder = id;
      filter = 'all';
      unread = false;
      settingsOpen = false;
      closeMessage();
    });
    scaffoldKey.currentState?.closeDrawer();
    refresh();
  }

  void accountsChanged(List<Json> next) {
    if (!mounted) return;
    generation++;
    setState(() {
      accounts = next;
      loading = false;
      refreshing = false;
      if (account.isNotEmpty && !next.any((a) => a['id'] == account)) {
        account = '';
        folder = 'INBOX';
        folders = [];
        filter = 'all';
        unread = false;
        messages = [];
        cursor = null;
        more = false;
        closeMessage();
      } else if (selected != null &&
          !next.any((a) => a['id'] == selected!['accountId'])) {
        closeMessage();
      }
    });
    refresh(silent: true);
  }

  Future<void> searchChanged(String next) async {
    debounce?.cancel();
    if (!await canLeave() || !mounted) {
      search.value = TextEditingValue(
        text: acceptedSearch,
        selection: TextSelection.collapsed(offset: acceptedSearch.length),
      );
      return;
    }
    acceptedSearch = next;
    generation++;
    refreshing = false;
    setState(() {
      closeMessage();
      settingsOpen = false;
      loading = false;
    });
    debounce = Timer(const Duration(milliseconds: 400), () => refresh());
  }

  Future<void> inlineCompose(Json mail, {bool forward = false}) async {
    if (inlineReply != null &&
        !(await inlineComposeKey.currentState?.canLeave() ?? true)) {
      return;
    }
    if (!mounted) return;
    // Dispose an old editor before reusing its key so reply/forward fields reset.
    setState(() => inlineReply = null);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || selected?['id'] != mail['id']) return;
    setState(() {
      inlineReply = mail;
      inlineForward = forward;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = inlineAnchorKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: 0,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final oauthReturned = consumeOAuthReturn();
    pendingRoute = MailRoute.parse(navigation.location);
    navigation.listen(applyBrowserRoute);
    navigation.protectDocument(() {
      if (!mounted) return false;
      final editor = inlineComposeKey.currentState;
      return composeOpen ||
          (inlineReply != null &&
              (editor == null || editor.dirty || editor.locked)) ||
          (settingsOpen &&
              (settingsKey.currentState?.protectsDocumentExit ?? true));
    });
    if (oauthReturned) {
      error = '邮箱已连接。原登录窗口不可用，请重新登录查看账户。';
    }
  }

  MailApi get api => widget.api;
  List<Json> rows(dynamic value) =>
      (value as List? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
  @override
  void dispose() {
    navigation.dispose();
    poll?.cancel();
    debounce?.cancel();
    listScroll.dispose();
    detailScroll.dispose();
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
      final resume = pendingRoute;
      applyingRoute = true;
      setState(() => logged = true);
      await refresh();
      applyingRoute = false;
      await applyBrowserRoute(resume.location, restoringLogin: true);
      poll = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!loading && !actionBusy && !applyingRoute && !settingsOpen) {
          refresh(silent: true);
        }
      });
    } catch (e) {
      fail(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void closeMessage() {
    detailGeneration++;
    selected = null;
    inlineReply = null;
  }

  Future<void> refresh({bool silent = false, bool append = false}) async {
    if (!logged || !mounted || (append && loading) || (silent && refreshing)) {
      return;
    }
    final gen = ++generation;
    var requestFolder = filter == 'starred' ? 'STARRED' : folder;
    var requestAccount = account;
    final requestSearch = search.text.trim();
    final requestUnread = unread;
    final target = silent ? messages.length : 40;
    var nextAccounts = accounts;
    var nextCaps = caps;
    refreshing = true;
    if (!silent) setState(() => loading = true);
    try {
      if (!append) {
        nextAccounts = rows((await api.request('GET', '/accounts'))['items']);
        nextCaps = Map<String, dynamic>.from(
          await api.request('GET', '/settings/capabilities'),
        );
      }
      if (!mounted || gen != generation) return;
      if (requestAccount.isNotEmpty &&
          !nextAccounts.any((a) => a['id'] == requestAccount)) {
        requestAccount = '';
        requestFolder = 'INBOX';
        setState(() {
          account = '';
          folder = 'INBOX';
          folders = [];
          filter = 'all';
          unread = false;
          closeMessage();
        });
      }
      final fetched = <Json>[];
      String? nextCursor = append ? cursor : null;
      var hasMore = false;
      var nextCoverage = coverage;
      do {
        final previousCursor = nextCursor;
        final data = await api.request(
          'GET',
          '/messages',
          query: {
            'folder': requestFolder,
            'limit': '40',
            'unreadOnly': '$requestUnread',
            if (requestAccount.isNotEmpty) 'accountId': requestAccount,
            if (requestSearch.isNotEmpty) 'query': requestSearch,
            if (nextCursor != null) 'cursor': nextCursor,
          },
        );
        if (!mounted || gen != generation) return;
        fetched.addAll(rows(data['items']));
        nextCoverage = data['coverage'] ?? '';
        hasMore = data['hasMore'] == true;
        nextCursor = data['nextCursor'];
        if (!silent ||
            !hasMore ||
            nextCursor == null ||
            nextCursor == previousCursor) {
          break;
        }
      } while (fetched.length < target);
      setState(() {
        accounts = nextAccounts;
        caps = nextCaps;
        final unique = <String, Json>{};
        for (final m in [...(append ? messages : <Json>[]), ...fetched]) {
          unique[m['id'].toString()] = m;
        }
        messages = unique.values.toList();
        coverage = nextCoverage;
        more = hasMore;
        cursor = nextCursor;
        error = '';
      });
    } catch (e) {
      if (gen == generation) fail(e);
    } finally {
      if (mounted && gen == generation) {
        setState(() {
          loading = false;
          refreshing = false;
        });
      }
    }
  }

  Future<void> chooseAccount(String id) async {
    if (!await canLeave() || !mounted) return;
    scaffoldKey.currentState?.closeDrawer();
    setState(() {
      account = id;
      settingsOpen = false;
      closeMessage();
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
        if (mounted && account == id) fail(e);
      }
    }
  }

  Future<void> open(Json mail, {bool guarded = true}) async {
    if (guarded && (!await canLeave() || !mounted)) return;
    inlineReply = null;
    if (detailScroll.hasClients) detailScroll.jumpTo(0);
    final gen = ++detailGeneration;
    setState(() => selected = {...mail, '_loading': true});
    try {
      final data = await api.request('GET', '/messages/${mail['id']}');
      if (mounted && gen == detailGeneration) {
        setState(() => selected = Map<String, dynamic>.from(data));
      }
    } catch (e) {
      if (mounted && gen == detailGeneration) {
        fail(e);
        setState(() => selected = {...mail, '_error': true});
      }
    }
  }

  Future<void> command(String type, {bool? value}) async {
    if (selected == null ||
        selected?['_error'] == true ||
        actionBusy ||
        !await canLeave() ||
        !mounted) {
      return;
    }
    setState(() => actionBusy = true);
    final item = selected!;
    final detailGen = detailGeneration;
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
      if (detailGen != detailGeneration) return;
      if (['TRASH', 'ARCHIVE', 'RESTORE'].contains(type)) {
        if (mounted) setState(closeMessage);
      } else {
        await open(item, guarded: false);
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
    if (composeOpen || !await canLeave() || !mounted) return;
    if (accounts.isEmpty) {
      await settings();
      return;
    }
    setState(() => inlineReply = null);
    composeOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ComposeDialog(
          api: api,
          accounts: accounts,
          initialAccountId: account,
          reply: reply,
          draft: draft,
          forward: forward,
          maxBytes: caps?['limits']?['maxAttachmentBytes'] ?? 10485760,
          onSaved: notify,
          onViewStatus: outbox,
        ),
      );
    } finally {
      composeOpen = false;
    }
    refresh(silent: true);
  }

  Future<void> showDrafts() async {
    if (!await canLeave() || !mounted) return;
    setState(() => inlineReply = null);
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

  Future<void> settings({String section = 'accounts'}) async {
    if (settingsOpen) {
      if (settingsKey.currentState?.section != section) {
        await settingsKey.currentState?.showSection(section);
      }
      return;
    }
    if (!await canLeave() || !mounted) return;
    scaffoldKey.currentState?.closeDrawer();
    setState(() {
      closeMessage();
      settingsSection = section;
      settingsOpen = true;
    });
    if (section != 'accounts') {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => settingsKey.currentState?.showSection(section),
      );
    }
  }

  Future<void> signout() async {
    if (!await canLeave() || !mounted) return;
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
      settingsOpen = false;
      acceptedSearch = '';
      loading = false;
      accounts = [];
      messages = [];
      folders = [];
      caps = null;
      closeMessage();
      account = '';
      folder = 'INBOX';
      cursor = null;
      more = false;
      unread = false;
      filter = 'all';
      refreshing = false;
      error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!logged) return loginView();
    publishRoute();
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
            final wide = c.maxWidth >= 720;
            return Scaffold(
              key: scaffoldKey,
              onDrawerChanged: (open) => setState(() => drawerOpen = open),
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
                          if (wide) SizedBox(width: 242, child: sidebar()),
                          Expanded(
                            child: Column(
                              children: [
                                topbar(!wide),
                                if (!wide) mobileAccounts(),
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
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      wide ? 6 : 8,
                                      0,
                                      wide ? 20 : 8,
                                      wide ? 20 : 8,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(14),
                                      child: Material(
                                        color: Colors.white,
                                        child: settingsOpen
                                            ? AccountSettingsPage(
                                                key: settingsKey,
                                                initialSection: settingsSection,
                                                onSectionChanged: (next) {
                                                  settingsSection = next;
                                                  publishRoute();
                                                },
                                                api: api,
                                                caps: caps ?? {},
                                                initialAccounts: accounts,
                                                onAccountsChanged:
                                                    accountsChanged,
                                                onClose: () {
                                                  setState(
                                                    () => settingsOpen = false,
                                                  );
                                                  refresh(silent: true);
                                                },
                                              )
                                            : accounts.isEmpty && !loading
                                                ? onboarding()
                                                : selected == null
                                                    ? messageList()
                                                    : detail(true),
                                      ),
                                    ),
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
  String accountLabel(Json a) {
    final name = a['displayName']?.toString().trim() ?? '';
    return name.isEmpty ? a['email']?.toString() ?? '邮箱' : name;
  }

  String providerLabel(Json a) =>
      {
        'GOOGLE': 'Gmail',
        'GMAIL': 'Gmail',
        'MICROSOFT': 'Outlook',
        'OUTLOOK': 'Outlook',
        'MICROSOFT_365': 'Microsoft 365',
        'M365': 'Microsoft 365',
        'M365_E3': 'Microsoft 365',
        'QQ': 'QQ',
        'NETEASE': '163',
      }[a['provider']] ??
      (a['provider']?.toString().trim().isNotEmpty == true
          ? a['provider'].toString()
          : '邮箱');

  Widget accountTile(Json? a) {
    final id = a?['id']?.toString() ?? '';
    final label = a == null ? '全部账户' : accountLabel(a);
    final email = a?['email']?.toString() ?? '';
    // Do not repeat the same address when it is also the display name.
    final subtitle = a == null
        ? null
        : label.toLowerCase() == email.toLowerCase()
            ? providerLabel(a)
            : email;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: ListTile(
        key: ValueKey('account-$id'),
        dense: true,
        minTileHeight: a == null ? 40 : 54,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        horizontalTitleGap: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        selected: account == id,
        selectedTileColor: const Color(0xffdce7fa),
        selectedColor: const Color(0xff244f99),
        leading: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: const Color(0xffe6eefe),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: a == null
              ? const Icon(Icons.all_inbox_outlined, size: 18, color: blue)
              : Text(
                  providerLabel(a).substring(0, 1),
                  style: const TextStyle(
                    fontSize: 12,
                    color: blue,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: muted),
              ),
        trailing: a == null
            ? Text(
                '${accounts.length}',
                style: const TextStyle(fontSize: 11, color: muted),
              )
            : null,
        onTap: () => chooseAccount(id),
      ),
    );
  }

  Widget sidebar() => Material(
        color: canvas,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 0, 15),
                child: Row(
                  children: [
                    Icon(Icons.mark_email_unread_outlined,
                        color: blue, size: 30),
                    SizedBox(width: 11),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '泊信',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          'HARBOR MAIL',
                          style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 2,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffcee4fb),
                    foregroundColor: ink,
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  onPressed: () => compose(),
                  icon: const Icon(Icons.edit_outlined, size: 21),
                  label: const Text('写邮件'),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    Row(
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(left: 12),
                          child: Text(
                            '邮箱',
                            style: TextStyle(fontSize: 11, color: muted),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '连接邮箱',
                          onPressed: () => settings(section: 'add'),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add, size: 18),
                        ),
                      ],
                    ),
                    accountTile(null),
                    ...accounts.map(accountTile),
                    if (accounts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: TextButton(
                          onPressed: settings,
                          child: const Text('连接邮箱'),
                        ),
                      ),
                    const Divider(
                      height: 24,
                      indent: 12,
                      endIndent: 12,
                      color: Color(0xffe3e9f1),
                    ),
                    nav('收件箱', Icons.inbox_outlined, 'INBOX'),
                    nav('星标邮件', Icons.star_border_rounded, 'STARRED'),
                    nav('已发送', Icons.send_outlined, 'SENT'),
                    sidebarAction('草稿箱', Icons.drafts_outlined, showDrafts),
                    nav('归档', Icons.archive_outlined, 'ARCHIVE'),
                    nav('废纸篓', Icons.delete_outline, 'TRASH'),
                    sidebarAction('发件状态', Icons.outbox_outlined, outbox),
                    if (folders.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 16, 0, 6),
                        child: Text(
                          '账户文件夹',
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                      ...folders.map(
                        (f) => ListTile(
                          dense: true,
                          minTileHeight: 36,
                          leading: const Icon(Icons.folder_outlined, size: 18),
                          title: Text(
                            f['name'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(
                            '${f['unreadCount'] ?? 0}',
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                          onTap: () => chooseFolder(f['role'] ?? f['id']),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 12, color: Color(0xffe3e9f1)),
              sidebarAction('账户与设置', Icons.settings_outlined, settings),
              sidebarAction('退出登录', Icons.logout, signout),
            ],
          ),
        ),
      );

  Widget sidebarAction(String label, IconData icon, VoidCallback action) =>
      ListTile(
        dense: true,
        minTileHeight: 36,
        horizontalTitleGap: 12,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Icon(icon, size: 18, color: muted),
        title: Text(label, style: const TextStyle(fontSize: 12)),
        onTap: action,
      );

  Widget mobileAccounts() => SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          children: [
            for (final a in <Json?>[null, ...accounts])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('mobile-account-${a?['id'] ?? ''}'),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      a == null ? '全部账户' : accountLabel(a),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  selected: account == (a?['id'] ?? ''),
                  onSelected: (_) => chooseAccount(a?['id'] ?? ''),
                ),
              ),
            ActionChip(
              label: const Text('连接邮箱'),
              onPressed: () => settings(section: 'add'),
              avatar: const Icon(Icons.add, size: 16),
            ),
          ],
        ),
      );

  Widget nav(String label, IconData icon, String id) => Padding(
        padding: const EdgeInsets.only(bottom: 1),
        child: ListTile(
          dense: true,
          minTileHeight: 36,
          horizontalTitleGap: 12,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          selected: folder == id,
          selectedTileColor: const Color(0xffd3e3fd),
          selectedColor: ink,
          leading: Icon(icon, size: 18),
          title: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: folder == id ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          onTap: () => chooseFolder(id),
        ),
      );

  Widget topbar(bool menu) => Container(
        height: 72,
        padding: EdgeInsets.symmetric(horizontal: menu ? 8 : 18),
        color: canvas,
        child: Row(
          children: [
            if (menu)
              IconButton(
                tooltip: '打开导航',
                onPressed: () => scaffoldKey.currentState?.openDrawer(),
                icon: const Icon(Icons.menu),
              ),
            Expanded(
              child: TextField(
                controller: search,
                onChanged: searchChanged,
                decoration: InputDecoration(
                  hintText: '搜索已同步的邮件',
                  hintStyle: const TextStyle(fontSize: 14, color: muted),
                  prefixIcon: const Icon(Icons.search),
                  fillColor: const Color(0xffe9f0fc),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(32),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 20,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '账户与设置',
              onPressed: settings,
              icon: const Icon(Icons.settings_outlined, size: 22),
            ),
          ],
        ),
      );

  Future<void> setFilter(String next) async {
    if (!await canLeave() || !mounted) return;
    setState(() {
      filter = next;
      if (next == 'starred') {
        folder = 'STARRED';
      } else if (folder == 'STARRED') {
        folder = 'INBOX';
      }
      unread = next == 'unread';
      closeMessage();
    });
    refresh();
  }

  String get mailboxTitle {
    final label = {
          'INBOX': '收件箱',
          'STARRED': '星标邮件',
          'SENT': '已发送',
          'ARCHIVE': '归档',
          'TRASH': '废纸篓',
        }[folder] ??
        '邮件';
    final chosen = accounts.where((a) => a['id'] == account);
    return chosen.isEmpty
        ? '全部账户 · $label'
        : '${accountLabel(chosen.first)} · $label';
  }

  Widget messageList() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              mailboxTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
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
                  style: const TextStyle(fontSize: 13, color: muted),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '刷新邮件',
                  onPressed: loading ? null : () => refresh(silent: true),
                  icon: const Icon(Icons.refresh, size: 21),
                ),
                IconButton(
                  tooltip: '同步邮箱',
                  onPressed: actionBusy ? null : sync,
                  icon: const Icon(Icons.sync, size: 21),
                ),
                const Spacer(),
                Text(
                  '${messages.length} 封已加载',
                  style: const TextStyle(fontSize: 11, color: muted),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xffe8edf4)),
          SizedBox(
            height: 46,
            child: Row(
              children: [
                for (final entry in [
                  ('all', '全部邮件', Icons.inbox_outlined),
                  ('unread', '未读', Icons.mark_email_unread_outlined),
                  ('starred', '已加星标', Icons.star_border),
                ])
                  Expanded(
                    child: InkWell(
                      onTap: () => setFilter(entry.$1),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              width: 3,
                              color: filter == entry.$1
                                  ? blue
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              entry.$3,
                              size: 18,
                              color: filter == entry.$1 ? blue : muted,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              entry.$2,
                              style: TextStyle(
                                fontSize: 12,
                                color: filter == entry.$1 ? blue : muted,
                                fontWeight: filter == entry.$1
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: messages.isEmpty && !loading
                ? empty('这里很安静', '没有符合条件的邮件', Icons.inbox_outlined)
                : ListView.builder(
                    key: const ValueKey('message-list'),
                    controller: listScroll,
                    itemCount: messages.length + (more ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i == messages.length) {
                        return TextButton(
                          onPressed:
                              loading ? null : () => refresh(append: true),
                          child: const Text('加载更多'),
                        );
                      }
                      return messageRow(messages[i]);
                    },
                  ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Text(
              '每 30 秒刷新 · 仅搜索已同步邮件',
              style: TextStyle(fontSize: 10, color: muted),
            ),
          ),
        ],
      );

  Widget messageRow(Json m) {
    final read = m['isRead'] == true;
    final matching = accounts.where((a) => a['id'] == m['accountId']);
    final badge = matching.isEmpty
        ? ''
        : matching.first['displayName'] ?? matching.first['email'] ?? '';
    final recipients = (m['to'] as List? ?? [])
        .map(
          (r) => r['name']?.toString().isNotEmpty == true
              ? r['name']
              : r['address'],
        )
        .join(', ');
    final sender = folder == 'SENT'
        ? '收件人：${recipients.isEmpty ? '未提供' : recipients}'
        : m['fromName']?.toString().isNotEmpty == true
            ? m['fromName']
            : m['fromAddress'] ?? '';
    final style = TextStyle(
      fontSize: 13,
      fontWeight: read ? FontWeight.w400 : FontWeight.w600,
      color: ink,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        return InkWell(
          key: ValueKey('message-${m['id']}'),
          onTap: loading ? null : () => open(m),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : 20,
              vertical: compact ? 11 : 13,
            ),
            decoration: BoxDecoration(
              color: read ? const Color(0xfff8fafd) : Colors.white,
              border: const Border(
                bottom: BorderSide(color: Color(0xffe8edf4)),
              ),
            ),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              sender,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            date(m['receivedAt']),
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        m['subject'] ?? '（无主题）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        m['snippet'] ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                      if (badge.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            badge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                        ),
                    ],
                  )
                : Row(
                    children: [
                      Icon(
                        m['isStarred'] == true ? Icons.star : Icons.star_border,
                        size: 18,
                        color: m['isStarred'] == true
                            ? const Color(0xffbf8700)
                            : muted,
                      ),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 150,
                        child: Text(
                          sender,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: m['subject'] ?? '（无主题）',
                                style: style,
                              ),
                              TextSpan(
                                text: '  —  ${m['snippet'] ?? ''}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (m['hasAttachments'] == true)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.attach_file,
                            size: 16,
                            color: muted,
                          ),
                        ),
                      if (badge.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(left: 12),
                          constraints: const BoxConstraints(maxWidth: 100),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xffe3ebf8),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                        ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 60,
                        child: Text(
                          date(m['receivedAt']),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 10, color: muted),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  String date(dynamic value) {
    final dt = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (dt == null) return '';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return dt.year == now.year
        ? '${dt.month}月${dt.day}日'
        : '${dt.year}/${dt.month}/${dt.day}';
  }

  Widget onboarding() => Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(22),
            child: Row(
              children: [
                Text('收件箱', style: TextStyle(color: muted, fontSize: 13)),
                Spacer(),
                Text('尚未连接邮箱', style: TextStyle(color: muted, fontSize: 11)),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xffe8edf4)),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: const Color(0xffe6efff),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(Icons.inbox_outlined,
                          size: 40, color: ink),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      '让邮件，在这里靠岸。',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 28, fontWeight: FontWeight.w400),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '先连接你的第一个邮箱。\n收件、写信、整理，都可以在泊信完成。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted, fontSize: 14, height: 2),
                    ),
                    const SizedBox(height: 36),
                    FilledButton.icon(
                      onPressed: settings,
                      icon: const Icon(Icons.add),
                      label: const Text('连接邮箱'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 20,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '支持的邮箱可使用 OAuth 授权，也可手动配置连接',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      '选择邮箱服务商  ·  完成授权  ·  开始同步',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: settings,
                      child: const Text(
                        'QQ / 163 邮箱：使用 IMAP / SMTP 连接',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );

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
    final compact = MediaQuery.sizeOf(context).width < 600;
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
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 16),
            child: Row(
              children: [
                if (back)
                  IconButton(
                    tooltip: '返回列表',
                    onPressed: backToList,
                    icon: const Icon(Icons.arrow_back),
                  ),
                IconButton(
                  tooltip: m['isRead'] == true ? '标为未读' : '标为已读',
                  onPressed: actionBusy ||
                          m['_loading'] == true ||
                          m['_error'] == true
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
                  onPressed: actionBusy ||
                          m['_loading'] == true ||
                          m['_error'] == true
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
                  onPressed:
                      actionBusy || m['_loading'] == true || m['_error'] == true
                          ? null
                          : () => command('ARCHIVE'),
                  icon: const Icon(Icons.archive_outlined),
                ),
                IconButton(
                  tooltip: folder == 'TRASH' ? '恢复到收件箱' : '移至废纸篓',
                  onPressed: actionBusy ||
                          m['_loading'] == true ||
                          m['_error'] == true
                      ? null
                      : () => command(folder == 'TRASH' ? 'RESTORE' : 'TRASH'),
                  icon: Icon(
                    folder == 'TRASH'
                        ? Icons.restore_from_trash_outlined
                        : Icons.delete_outline,
                  ),
                ),
                const Spacer(),
                if (!compact)
                  const Text(
                    '安全邮件阅读',
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
                        key: ValueKey('reader-${m['id']}-$detailGeneration'),
                        controller: detailScroll,
                        padding: EdgeInsets.fromLTRB(
                          compact ? 8 : 30,
                          10,
                          compact ? 8 : 30,
                          24,
                        ),
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(compact ? 16 : 30),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xffe9edf4)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              MailHeader(message: m),
                              const SizedBox(height: 26),
                              const Divider(color: Color(0xffedf0f5)),
                              const SizedBox(height: 24),
                              MailBody(
                                key: ValueKey(m['id']),
                                api: api,
                                messageId: m['id']?.toString(),
                                accountId: m['accountId']?.toString(),
                                inputEnabled: !drawerOpen,
                                html: m['bodyHtml']?.toString() ?? '',
                                text: m['bodyText']?.toString() ?? '',
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
                                            name:
                                                (a['fileName'] ?? 'attachment')
                                                    .toString()
                                                    .replaceAll(
                                                      RegExp(r'[\\/\x00-\x1F]'),
                                                      '_',
                                                    ),
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
                              if (inlineReply == null)
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () => inlineCompose(m),
                                      icon: const Icon(Icons.reply, size: 17),
                                      label: const Text('回复'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          inlineCompose(m, forward: true),
                                      icon: const Icon(Icons.forward, size: 17),
                                      label: const Text('转发'),
                                    ),
                                  ],
                                ),
                              if (inlineReply != null)
                                Container(
                                  key: inlineAnchorKey,
                                  child: ComposeEditor(
                                    key: inlineComposeKey,
                                    api: api,
                                    accounts: accounts,
                                    initialAccountId: m['accountId'] ?? account,
                                    reply: inlineReply,
                                    forward: inlineForward,
                                    inline: true,
                                    maxBytes: caps?['limits']
                                            ?['maxAttachmentBytes'] ??
                                        10485760,
                                    onSaved: notify,
                                    onViewStatus: outbox,
                                    onClose: () {
                                      if (mounted) {
                                        setState(() => inlineReply = null);
                                        refresh(silent: true);
                                      }
                                    },
                                  ),
                                ),
                              const SizedBox(height: 20),
                              const Text(
                                '隔离邮件阅读 · 远程图片默认阻止',
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
