import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
import 'device_settings.dart';
import 'device_onboarding.dart';
import 'device_pairing_api.dart';
import 'server_profile.dart';
import 'device_scanner.dart';
import 'local_unlock.dart';
import 'android_downloads.dart';
import 'login_layout.dart';
import 'session_vault.dart';
import 'device_session.dart';
import 'device_session_vault.dart';
import 'device_info.dart';
import 'device_security_card.dart';
import 'device_privacy_gate.dart';
import 'passkey_api.dart';
import 'passkey_login.dart';
import 'passkey_settings.dart';
import 'server_profile_store.dart';

void main() {
  configureBrowserNavigation();
  runApp(const MailApp());
}

const ink = Color(0xff24344c),
    blue = Color(0xff0b57d0),
    muted = Color(0xff7c899c),
    canvas = Color(0xfff5f7fb);
typedef Json = Map<String, dynamic>;

class MailApp extends StatefulWidget {
  final MailApi? api;
  final MailNavigation? navigation;
  final LocalUnlockController? unlockController;
  final SessionVault? sessionVault;
  final DeviceSessionVault? deviceSessionVault;
  final MailApi Function(String)? recoveryApiFactory;
  const MailApp({
    super.key,
    this.api,
    this.navigation,
    this.unlockController,
    this.sessionVault,
    this.deviceSessionVault,
    this.recoveryApiFactory,
  });
  @override
  State<MailApp> createState() => _MailAppState();
}

/// Retire protected transient routes synchronously when a server session ends.
/// Waiting for pop animations could reveal an old dialog after the lock lifts.
class _SessionRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> routes = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        routes.removeAt(index);
      } else {
        routes[index] = newRoute;
      }
    }
  }

  void clearTransientRoutes() {
    for (final route in routes.skip(1).toList().reversed) {
      navigator?.removeRoute(route);
    }
  }
}

class _MailAppState extends State<MailApp> {
  final mailboxKey = GlobalKey<MailboxState>();
  final sessionRoutes = _SessionRouteObserver();
  final durablePrivacy = ValueNotifier<int>(0);
  late final initialApi = widget.api ?? MailApi();
  late final unlock =
      widget.unlockController ??
      LocalUnlockController(authenticator: PlatformLocalUnlockAuthenticator());
  @override
  void dispose() {
    if (widget.unlockController == null) unlock.dispose();
    durablePrivacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '泊信 · Harbor Mail',
    initialRoute: '/',
    navigatorObservers: [sessionRoutes],
    builder: (context, child) => LocalUnlockGate(
      controller: unlock,
      onSignOut: () => mailboxKey.currentState?.signoutFromLock(),
      child: ValueListenableBuilder<int>(
        valueListenable: durablePrivacy,
        child: child ?? const SizedBox.shrink(),
        builder: (context, _, navigator) {
          final mailbox = mailboxKey.currentState;
          return DevicePrivacyGate(
            locked: mailbox?.durableLocked ?? false,
            shield: mailbox?.durableLockView() ?? const SizedBox.shrink(),
            child: navigator!,
          );
        },
      ),
    ),
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: blue, surface: Colors.white)
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
    home: Mailbox(
      key: mailboxKey,
      api: initialApi,
      navigation: widget.navigation,
      localUnlock: unlock,
      sessionVault: widget.sessionVault,
      deviceSessionVault: widget.deviceSessionVault,
      recoveryApiFactory: widget.recoveryApiFactory,
      clearTransientRoutes: sessionRoutes.clearTransientRoutes,
      onDevicePrivacyChanged: () => durablePrivacy.value++,
    ),
  );
}

class Mailbox extends StatefulWidget {
  final MailApi api;
  final MailNavigation? navigation;
  final LocalUnlockController? localUnlock;
  final SessionVault? sessionVault;
  final DeviceSessionVault? deviceSessionVault;
  final MailApi Function(String)? recoveryApiFactory;
  final VoidCallback? clearTransientRoutes;
  final VoidCallback? onDevicePrivacyChanged;
  const Mailbox({
    super.key,
    required this.api,
    this.navigation,
    this.localUnlock,
    this.sessionVault,
    this.deviceSessionVault,
    this.recoveryApiFactory,
    this.clearTransientRoutes,
    this.onDevicePrivacyChanged,
  });
  @override
  MailboxState createState() => MailboxState();
}

class MailboxState extends State<Mailbox> with WidgetsBindingObserver {
  bool _appForeground = true;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    final coordinator = deviceSession;
    if (state == AppLifecycleState.resumed) {
      for (final waiter in _foregroundWaiters.toList()) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _foregroundWaiters.clear();
    }
    if (coordinator == null) return;
    if (state == AppLifecycleState.resumed) {
      if (_deviceAuthenticationOwned) {
        coordinator.authenticationForeground();
        if (mounted) setState(() {});
      } else if (coordinator.metadata?.biometricEnabled != true &&
          _ownedPicker == null) {
        unawaited(resumeDeviceSession());
      } else if (mounted) {
        setState(() {});
      }
    } else if (state == AppLifecycleState.detached ||
        !(_deviceAuthenticationOwned &&
            (_biometricConfiguration || coordinator.locked))) {
      // An owned CryptoObject prompt may pause/stop for device PIN entry.
      // Native code retains only ciphertext and cannot release the DEK until
      // RESUMED with an unlocked keyguard. Never exempt a refresh/network wait.
      sessionGeneration++;
      generation++;
      detailGeneration++;
      unawaited(coordinator.suspend());
      if (mounted) setState(() {});
    } else {
      coordinator.pauseForAuthentication();
      sessionGeneration++;
      generation++;
      detailGeneration++;
      if (mounted) setState(() {});
    }
    updateDevicePrivacy();
  }

  late final navigation = widget.navigation ?? MailNavigation();
  late MailRoute pendingRoute;
  bool applyingRoute = false;
  String settingsSection = 'accounts';
  final deviceSettingsKey = GlobalKey<DeviceSettingsPageState>();
  final passkeySettingsKey = GlobalKey<PasskeySettingsPanelState>();
  final profileStore = ServerProfileStore();
  late final SessionVault sessionVault =
      widget.sessionVault ?? PlatformSessionVault();
  late final DeviceSessionVault deviceSessionVault =
      widget.deviceSessionVault ?? PlatformDeviceSessionVault();
  DeviceSessionCoordinator? deviceSession;
  DeviceSessionMetadata? rememberedMetadata;
  bool rememberDevice = true;
  bool _loggingOut = false, _deviceClearFailed = false;
  bool _acceptingPasskey = false;
  Object? _ownedPicker;
  final _foregroundWaiters = <Completer<void>>{};

  void updateDevicePrivacy() {
    if (mounted) widget.onDevicePrivacyChanged?.call();
  }

  void cancelPickerContinuation() {
    _ownedPicker = null;
    for (final waiter in _foregroundWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _foregroundWaiters.clear();
  }

  Future<ExternalPickerResult<T>> runExternalPicker<T>(
    Future<T> Function() pick,
  ) async {
    final coordinator = deviceSession;
    final metadata = coordinator?.metadata;
    if (coordinator == null ||
        metadata == null ||
        metadata.biometricEnabled ||
        !logged ||
        durableLocked ||
        (widget.localUnlock?.enabled ?? false)) {
      return ExternalPickerResult(await pick());
    }
    if (_ownedPicker != null) throw ApiException('PICKER_BUSY', '请先完成当前文件选择');
    final identity = Object();
    final source = api;
    final login = loginGeneration;
    final owner = metadata.accountId;
    final family = metadata.familyId;
    final profile = metadata.profile;
    _ownedPicker = identity;
    bool current() =>
        mounted &&
        logged &&
        login == loginGeneration &&
        identical(_ownedPicker, identity) &&
        identical(api, source) &&
        identical(deviceSession, coordinator) &&
        coordinator.durable &&
        coordinator.profile == profile &&
        coordinator.metadata?.accountId == owner &&
        coordinator.metadata?.familyId == family &&
        coordinator.metadata?.biometricEnabled == false &&
        !(widget.localUnlock?.enabled ?? false) &&
        !_loggingOut;
    try {
      final value = await pick();
      if (!current()) throw ApiException('STALE_SESSION', '登录已更改，请重新选择附件');
      while (!_appForeground) {
        final resumed = Completer<void>();
        _foregroundWaiters.add(resumed);
        await resumed.future;
        if (!current()) throw ApiException('STALE_SESSION', '登录已更改，请重新选择附件');
      }
      if (coordinator.locked || !coordinator.foreground) {
        await coordinator.resume(expectedFamilyId: family);
      }
      if (!current() || !_appForeground || durableLocked) {
        throw ApiException('STALE_SESSION', '请返回应用后重新选择附件');
      }
      updateDevicePrivacy();
      return ExternalPickerResult(value, reauthorize: true);
    } finally {
      if (identical(_ownedPicker, identity)) {
        final stillCurrent = current();
        _ownedPicker = null;
        if (stillCurrent && _appForeground && coordinator.locked) {
          unawaited(resumeDeviceSession());
        }
      }
      updateDevicePrivacy();
    }
  }

  bool _deviceAuthenticationOwned = false, _biometricConfiguration = false;
  bool get hasDurableSession => deviceSession?.durable ?? false;
  bool get durableLocked =>
      hasDurableSession &&
      (deviceSession!.locked ||
          !deviceSession!.foreground ||
          !_appForeground ||
          (_deviceAuthenticationOwned && vaultBusy));
  VaultMetadata? savedSessionMetadata;
  bool savedCurrentSession = false, vaultBusy = false;
  String vaultMessage = '';
  int vaultGeneration = 0, vaultOperation = 0;
  int vaultAuthenticationsInFlight = 0;
  bool vaultClearFailed = false;
  Timer? sessionExpiryTimer;
  MailApi? _configuredApi;
  bool pairingOpen = false;
  int sessionGeneration = 0, loginGeneration = 0;
  Object? _composeDialogIdentity;
  bool _wasLocked = false;
  final serverAddress = TextEditingController();
  final rememberedDeviceName = TextEditingController(text: fallbackDeviceName);
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
    if (widget.localUnlock?.locked ?? false) return false;
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
      final accountExists =
          target.account.isEmpty ||
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
        settingsSection = target.settings.isEmpty
            ? 'accounts'
            : target.settings;
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
    final session = sessionGeneration;
    if (logged && api.token == null && !hasDurableSession) {
      endSession(message: '登录已失效，请重新登录');
      return false;
    }
    if (!isCurrentSession(session)) return false;
    if (guardingNavigation || composeOpen) return false;
    guardingNavigation = true;
    try {
      if (inlineReply != null &&
          !(await inlineComposeKey.currentState?.canLeave() ?? true)) {
        return false;
      }
      if (settingsOpen &&
          settingsSection == 'devices' &&
          !(await deviceSettingsKey.currentState?.canLeave() ?? true)) {
        return false;
      }
      if (settingsOpen &&
          settingsSection == 'passkeys' &&
          !(await passkeySettingsKey.currentState?.canLeave() ?? true)) {
        return false;
      }
      if (settingsOpen &&
          !{'devices', 'passkeys'}.contains(settingsSection) &&
          !(await settingsKey.currentState?.canLeave() ?? true)) {
        return false;
      }
      return isCurrentSession(session);
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
    final session = sessionGeneration;
    if (!isCurrentSession(session)) return;
    if (inlineReply != null &&
        !(await inlineComposeKey.currentState?.canLeave() ?? true)) {
      return;
    }
    if (!mounted) return;
    // Dispose an old editor before reusing its key so reply/forward fields reset.
    setState(() => inlineReply = null);
    await WidgetsBinding.instance.endOfFrame;
    if (!isCurrentSession(session) || selected?['id'] != mail['id']) return;
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
    WidgetsBinding.instance.addObserver(this);
    widget.localUnlock?.addListener(unlockChanged);
    bindApiSession(widget.api);
    serverAddress.text = widget.api.base.startsWith('https://')
        ? widget.api.base
        : '';
    if (!kIsWeb) {
      unawaited(restoreServerProfile().then((_) => discoverRememberedDevice()));
      unawaited(discoverSavedSession());
      final beforeName = rememberedDeviceName.text;
      unawaited(
        PlatformDeviceInfo().suggestedName().then((name) {
          if (mounted && !busy && rememberedDeviceName.text == beforeName) {
            setState(() => rememberedDeviceName.text = name);
          }
        }),
      );
    }
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
              (settingsSection == 'devices'
                  ? deviceSettingsKey.currentState?.protectsDocumentExit ?? true
                  : settingsSection == 'passkeys'
                  ? passkeySettingsKey.currentState?.protectsDocumentExit ??
                        true
                  : settingsKey.currentState?.protectsDocumentExit ?? true));
    });
    if (oauthReturned) {
      error = '邮箱已连接。原登录窗口不可用，请重新登录查看账户。';
    }
  }

  bool isSameSession(int epoch) =>
      mounted && logged && epoch == sessionGeneration;

  bool isCurrentSession(int epoch) =>
      mounted &&
      logged &&
      (api.token != null || hasDurableSession) &&
      epoch == sessionGeneration &&
      !(widget.localUnlock?.locked ?? false) &&
      !durableLocked;

  bool Function() captureSessionGuard() {
    final epoch = sessionGeneration;
    return () => isCurrentSession(epoch);
  }

  void unlockChanged() {
    final locked = widget.localUnlock?.locked ?? false;
    if (locked && !_wasLocked) {
      sessionGeneration++;
      generation++;
      detailGeneration++;
      loading = false;
      refreshing = false;
      actionBusy = false;
    }
    _wasLocked = locked;
    if (!locked && logged && api.token == null && !hasDurableSession) {
      endSession(message: '登录已失效，请重新登录');
      return;
    }
    if (mounted) setState(() {});
  }

  void bindApiSession(MailApi source) {
    source.onSessionCleared = () {
      if (mounted &&
          logged &&
          identical(source, api) &&
          !_loggingOut &&
          !hasDurableSession) {
        endSession(message: '登录已失效，请重新登录');
      }
    };
  }

  MailApi get api => _configuredApi ?? widget.api;
  List<Json> rows(dynamic value) =>
      (value as List? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cancelPickerContinuation();
    vaultGeneration++;
    sessionExpiryTimer?.cancel();
    unawaited(sessionVault.cancel());
    final retiring = deviceSession;
    deviceSession = null;
    unawaited(retiring?.retire() ?? deviceSessionVault.lock());
    widget.localUnlock?.removeListener(unlockChanged);
    navigation.dispose();
    poll?.cancel();
    debounce?.cancel();
    listScroll.dispose();
    detailScroll.dispose();
    serverAddress.dispose();
    rememberedDeviceName.dispose();
    username.dispose();
    password.dispose();
    search.dispose();
    api.onSessionCleared = null;
    widget.api.onSessionCleared = null;
    api.dispose();
    if (_configuredApi != null) widget.api.dispose();
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
    if (api.token == null && logged && !hasDurableSession && !_loggingOut) {
      endSession(message: e.toString());
    }
  }

  DeviceSessionCoordinator createDeviceSession(
    MailApi source,
    ServerProfile profile,
  ) {
    late DeviceSessionCoordinator coordinator;
    coordinator = DeviceSessionCoordinator(
      api: source,
      vault: deviceSessionVault,
      profile: profile,
      onChanged: () {
        if (!mounted || !identical(deviceSession, coordinator)) return;
        setState(() {
          rememberedMetadata = coordinator.metadata ?? rememberedMetadata;
        });
        updateDevicePrivacy();
      },
    );
    return coordinator;
  }

  Future<void> discoverRememberedDevice() async {
    if (!deviceSessionVault.supported) return;
    final operation = vaultOperation;
    final result = await deviceSessionVault.status();
    if (!mounted ||
        operation != vaultOperation ||
        logged ||
        busy ||
        pairingOpen) {
      return;
    }
    final metadata = result.metadata;
    if (metadata == null) {
      if ({
        DeviceVaultState.expired,
        DeviceVaultState.invalidated,
        DeviceVaultState.corrupt,
        DeviceVaultState.mismatch,
      }.contains(result.state)) {
        setState(() => error = '此设备保存的登录已到期或不可用，请重新登录。');
      }
      return;
    }
    setState(() => rememberedMetadata = metadata);
    // Discovery cannot redirect authenticated traffic. Only auto-restore the
    // selected HTTPS origin/account; native unlock authenticates that binding.
    if (!metadata.biometricEnabled &&
        serverAddress.text == metadata.profile.apiBase &&
        username.text == metadata.accountId) {
      await restoreRememberedDevice();
    }
  }

  Future<void> restoreRememberedDevice() async {
    final metadata = rememberedMetadata;
    if (metadata == null ||
        _loggingOut ||
        busy ||
        vaultBusy ||
        logged ||
        pairingOpen ||
        !_appForeground) {
      return;
    }
    if (widget.localUnlock?.busy ?? false) return;
    final operation = ++vaultOperation;
    _deviceAuthenticationOwned = metadata.biometricEnabled;
    widget.localUnlock?.setExternalAuthenticationBusy(true);
    setState(() {
      busy = true;
      vaultBusy = true;
      error = '';
    });
    final candidate =
        widget.recoveryApiFactory?.call(metadata.profile.apiBase) ??
        MailApi(base: metadata.profile.apiBase);
    final coordinator = createDeviceSession(candidate, metadata.profile);
    final previous = deviceSession;
    deviceSession = coordinator;
    await previous?.retire();
    try {
      await coordinator.restore(accountId: metadata.accountId);
      if (!mounted ||
          operation != vaultOperation ||
          pairingOpen ||
          !_appForeground ||
          !identical(deviceSession, coordinator)) {
        return;
      }
      _configuredApi?.dispose();
      widget.api.token = null;
      _configuredApi = candidate;
      bindApiSession(candidate);
      serverAddress.text = metadata.profile.apiBase;
      username.text = metadata.accountId;
      password.clear();
      await resumeAuthenticatedSession();
    } catch (e) {
      if (mounted && operation == vaultOperation) {
        setState(() => error = e.toString());
      }
    } finally {
      _deviceAuthenticationOwned = false;
      widget.localUnlock?.setExternalAuthenticationBusy(false);
      if (!identical(api, candidate)) {
        await coordinator.retire();
        candidate.dispose();
        if (identical(deviceSession, coordinator)) deviceSession = null;
      }
      if (mounted && operation == vaultOperation) {
        setState(() {
          busy = false;
          vaultBusy = false;
        });
      }
    }
  }

  Future<void> resumeDeviceSession() async {
    final coordinator = deviceSession;
    if (coordinator == null ||
        vaultBusy ||
        _loggingOut ||
        (widget.localUnlock?.busy ?? false)) {
      return;
    }
    final operation = vaultOperation;
    _deviceAuthenticationOwned = coordinator.metadata?.biometricEnabled == true;
    widget.localUnlock?.setExternalAuthenticationBusy(true);
    setState(() => vaultBusy = true);
    updateDevicePrivacy();
    try {
      await coordinator.resume();
      if (!mounted ||
          operation != vaultOperation ||
          !identical(deviceSession, coordinator)) {
        return;
      }
      _deviceAuthenticationOwned = false;
      setState(() => error = '');
      if (logged && !durableLocked) await refresh(silent: true);
    } catch (e) {
      if (mounted && operation == vaultOperation) {
        setState(() => error = e.toString());
      }
    } finally {
      _deviceAuthenticationOwned = false;
      _biometricConfiguration = false;
      widget.localUnlock?.setExternalAuthenticationBusy(false);
      if (mounted && operation == vaultOperation) {
        setState(() => vaultBusy = false);
        updateDevicePrivacy();
      }
    }
  }

  Future<void> setDeviceBiometric(bool enabled) async {
    final coordinator = deviceSession;
    if (coordinator == null || !logged || vaultBusy || !_appForeground) return;
    if (widget.localUnlock?.busy ?? false) return;
    final operation = vaultOperation;
    _deviceAuthenticationOwned = true;
    _biometricConfiguration = true;
    widget.localUnlock?.setExternalAuthenticationBusy(true);
    setState(() {
      vaultBusy = true;
      vaultMessage = '';
    });
    updateDevicePrivacy();
    try {
      await coordinator.setBiometricEnabled(enabled, explicitOptIn: true);
      if (mounted &&
          _appForeground &&
          operation == vaultOperation &&
          identical(deviceSession, coordinator) &&
          coordinator.locked) {
        await coordinator.resume();
      }
      if (mounted &&
          operation == vaultOperation &&
          identical(deviceSession, coordinator)) {
        setState(
          () => vaultMessage = coordinator.metadata?.biometricEnabled == true
              ? '指纹 / 系统验证已开启，返回应用或重启后需验证。自动续期不会反复弹出验证。'
              : '指纹 / 系统验证已关闭；此设备仍会加密保存登录并自动续期。',
        );
      }
    } catch (e) {
      // A canceled PIN setup keeps the previous encryption mode. If lifecycle
      // pausing erased plaintext, restore the still-unprotected mode silently.
      if (mounted &&
          _appForeground &&
          operation == vaultOperation &&
          identical(deviceSession, coordinator) &&
          coordinator.locked &&
          coordinator.metadata?.biometricEnabled != true) {
        try {
          await coordinator.resume();
        } catch (_) {}
      }
      if (mounted && operation == vaultOperation) {
        setState(() => vaultMessage = e.toString());
      }
    } finally {
      _deviceAuthenticationOwned = false;
      _biometricConfiguration = false;
      widget.localUnlock?.setExternalAuthenticationBusy(false);
      if (mounted && operation == vaultOperation) {
        setState(() => vaultBusy = false);
        updateDevicePrivacy();
      }
    }
  }

  Widget rememberedDeviceCard() {
    final metadata = rememberedMetadata!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('此设备已记住登录'),
            Text('${metadata.accountId} · ${metadata.profile.origin}'),
            FilledButton.icon(
              key: const Key('restore-remembered-device'),
              onPressed: busy ? null : restoreRememberedDevice,
              icon: Icon(
                metadata.biometricEnabled ? Icons.fingerprint : Icons.login,
              ),
              label: Text(metadata.biometricEnabled ? '系统验证后继续' : '继续登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget durableLockView() => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: 16),
              const Text('此设备的登录已锁定'),
              if (error.isNotEmpty) Text(error),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('unlock-remembered-device'),
                onPressed: vaultBusy || !_appForeground
                    ? null
                    : resumeDeviceSession,
                icon: const Icon(Icons.fingerprint),
                label: Text(vaultBusy ? '正在恢复…' : '解锁并继续'),
              ),
              TextButton(
                onPressed: vaultBusy ? null : signoutFromLock,
                child: const Text('退出登录'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> discoverSavedSession() async {
    if (!sessionVault.supported) return;
    final epoch = vaultGeneration;
    final result = await sessionVault.status();
    if (!mounted || epoch != vaultGeneration || logged || busy || pairingOpen) {
      return;
    }
    setState(
      () => savedSessionMetadata = result.state == VaultState.saved
          ? result.metadata
          : null,
    );
    if ({
      VaultState.expired,
      VaultState.corrupt,
      VaultState.invalidated,
    }.contains(result.state)) {
      await discardSavedSession();
    }
  }

  Future<bool> discardSavedSession() async {
    final hadVaultState =
        savedSessionMetadata != null ||
        savedCurrentSession ||
        vaultAuthenticationsInFlight != 0 ||
        vaultBusy ||
        vaultClearFailed;
    final epoch = ++vaultGeneration;
    final result = sessionVault.supported
        ? await sessionVault.clear()
        : const VaultResult(VaultState.empty);
    if (!mounted || epoch != vaultGeneration) return false;
    // A platform without a vault plugin may still use memory-only login.
    // Never treat unavailable as deletion if any saved/pending record is known.
    final cleared =
        result.state == VaultState.empty ||
        (result.state == VaultState.unavailable &&
            !hadVaultState &&
            savedSessionMetadata == null &&
            !savedCurrentSession &&
            vaultAuthenticationsInFlight == 0 &&
            !vaultBusy &&
            !vaultClearFailed);
    setState(() {
      vaultClearFailed = !cleared;
      if (cleared) {
        savedSessionMetadata = null;
        savedCurrentSession = false;
      } else {
        vaultMessage = '未能删除设备保存的登录，请重试。不要将此设备交给他人；也可在网页撤销该设备会话。';
        error = vaultMessage;
      }
    });
    return cleared;
  }

  String vaultStatusMessage(VaultState state) => switch (state) {
    VaultState.saved => '本次登录已加密保存。重启后需系统验证，原到期时间不变。',
    VaultState.canceled => '已取消系统验证，设置未开启。',
    VaultState.unavailable => '安全恢复需要 Android 11 或更新版本及可用的系统锁屏验证。',
    VaultState.lockedOut => '系统验证暂时锁定，请稍后再试。',
    VaultState.expired => '原登录已到期，请重新登录。',
    VaultState.invalidated => '设备安全密钥已失效，请重新登录并手动开启安全保存。',
    VaultState.corrupt || VaultState.mismatch => '保存的登录不可用，已停止恢复。请重新登录。',
    _ => '操作未完成，请重试。',
  };

  Future<void> setSavedSession(bool enabled) async {
    if (!_appForeground ||
        vaultBusy ||
        (widget.localUnlock?.busy ?? false) ||
        !logged ||
        api.token == null) {
      return;
    }
    final operation = ++vaultOperation;
    if (!enabled) {
      setState(() => vaultBusy = true);
      final cleared = await discardSavedSession();
      if (mounted && operation == vaultOperation) {
        setState(() {
          vaultBusy = false;
          if (cleared) vaultMessage = '已删除此设备保存的登录。当前内存会话仍有效。';
        });
      }
      return;
    }
    final token = api.token!;
    final expiry = api.sessionExpiresAt;
    final owner = api.sessionAccount;
    if (expiry == null ||
        owner == null ||
        !expiry.isAfter(DateTime.now().toUtc())) {
      setState(() => vaultMessage = '当前会话缺少有效的原到期信息，请重新登录后开启。');
      return;
    }
    final epoch = ++vaultGeneration;
    final source = api;
    vaultAuthenticationsInFlight++;
    widget.localUnlock?.setExternalAuthenticationBusy(true);
    setState(() {
      vaultBusy = true;
      vaultMessage = '';
    });
    try {
      final result = await sessionVault.save(
        SavedSession(
          token: token,
          profile: ServerProfile.parse(source.base),
          accountId: owner,
          expiresAt: expiry,
        ),
        explicitOptIn: true,
      );
      if (!mounted ||
          epoch != vaultGeneration ||
          !logged ||
          !identical(api, source) ||
          api.token != token) {
        return;
      }
      setState(() {
        savedCurrentSession = result.state == VaultState.saved;
        savedSessionMetadata = savedCurrentSession ? result.metadata : null;
        vaultMessage = vaultStatusMessage(result.state);
      });
    } catch (_) {
      if (mounted && epoch == vaultGeneration) {
        setState(() => vaultMessage = '安全保存未完成，请重试。');
      }
    } finally {
      vaultAuthenticationsInFlight--;
      widget.localUnlock?.setExternalAuthenticationBusy(false);
      if (mounted && operation == vaultOperation) {
        setState(() => vaultBusy = false);
      }
    }
  }

  Future<void> restoreSavedSession() async {
    final metadata = savedSessionMetadata;
    if (metadata == null ||
        busy ||
        vaultBusy ||
        vaultClearFailed ||
        logged ||
        pairingOpen ||
        (widget.localUnlock?.busy ?? false)) {
      return;
    }
    final operation = ++vaultOperation;
    final epoch = ++vaultGeneration;
    vaultAuthenticationsInFlight++;
    widget.localUnlock?.setExternalAuthenticationBusy(true);
    setState(() {
      busy = true;
      vaultBusy = true;
      error = '';
    });
    MailApi? candidate;
    try {
      final result = await sessionVault.restore(
        profile: metadata.profile,
        accountId: metadata.accountId,
      );
      if (!mounted || epoch != vaultGeneration || logged || pairingOpen) return;
      final session = result.session;
      if (result.state != VaultState.restored || session == null) {
        if ({
          VaultState.expired,
          VaultState.corrupt,
          VaultState.invalidated,
          VaultState.mismatch,
        }.contains(result.state)) {
          await discardSavedSession();
        }
        if (mounted && !vaultClearFailed) {
          setState(() => error = vaultStatusMessage(result.state));
        }
        return;
      }
      candidate =
          widget.recoveryApiFactory?.call(session.profile.apiBase) ??
          MailApi(base: session.profile.apiBase);
      candidate.token = session.token;
      candidate.sessionExpiresAt = session.expiresAt;
      candidate.sessionAccount = session.accountId;
      // Validate with the bound origin BEFORE exposing any authenticated UI.
      await candidate.request('GET', '/accounts');
      if (!mounted || epoch != vaultGeneration || logged || pairingOpen) return;
      if (!_appForeground) {
        setState(() => error = '请返回应用后重新验证恢复登录。');
        return;
      }
      if (!session.expiresAt.isAfter(DateTime.now().toUtc())) {
        await discardSavedSession();
        if (mounted && !vaultClearFailed) {
          setState(() => error = '原登录已到期，请重新登录。');
        }
        return;
      }
      _configuredApi?.dispose();
      widget.api.token = null;
      _configuredApi = candidate;
      bindApiSession(candidate);
      candidate = null;
      serverAddress.text = session.profile.apiBase;
      username.text = session.accountId;
      password.clear();
      savedCurrentSession = true;
      await resumeAuthenticatedSession();
    } on ApiException catch (e) {
      if (!mounted || epoch != vaultGeneration) return;
      if (candidate?.token == null || e.code == 'UNAUTHORIZED') {
        await discardSavedSession();
      }
      if (mounted && !vaultClearFailed) {
        setState(() => error = '恢复尚未完成：${e.message}');
      }
    } catch (_) {
      if (mounted && epoch == vaultGeneration) {
        setState(() => error = '安全恢复未完成，请重试或重新登录。');
      }
    } finally {
      vaultAuthenticationsInFlight--;
      widget.localUnlock?.setExternalAuthenticationBusy(false);
      candidate?.dispose();
      if (mounted && operation == vaultOperation) {
        setState(() {
          busy = false;
          vaultBusy = false;
        });
      }
    }
  }

  Widget savedSessionCard() {
    final metadata = savedSessionMetadata!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('恢复已安全保存的登录'),
            Text('${metadata.accountId} · ${metadata.profile.origin}'),
            Text(
              '原到期时间：${metadata.expiresAt.toLocal().toString().split('.').first}',
            ),
            FilledButton.icon(
              key: const Key('restore-saved-session'),
              onPressed: busy || vaultClearFailed ? null : restoreSavedSession,
              icon: const Icon(Icons.fingerprint),
              label: const Text('系统验证后恢复'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await discardSavedSession();
                      if (mounted) setState(() {});
                    },
              child: const Text('删除保存的登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget? deviceSecuritySettings() {
    final controller = widget.localUnlock;
    if (hasDurableSession) {
      return DeviceSecurityCard(
        lockSupported: true,
        lockEnabled: deviceSession!.metadata?.biometricEnabled ?? false,
        storageSupported: true,
        storageEnabled: true,
        durable: true,
        idleExpiresAt: deviceSession!.metadata?.idleExpiresAt,
        expiresAt: deviceSession!.metadata?.absoluteExpiresAt,
        busy: vaultBusy || loading || applyingRoute,
        message: vaultMessage,
        onLockChanged: (value) => unawaited(setDeviceBiometric(value)),
        onStorageChanged: (_) {},
      );
    }
    if (!(controller?.supported ?? false) && !sessionVault.supported) {
      return null;
    }
    return DeviceSecurityCard(
      lockSupported: controller?.supported ?? false,
      lockEnabled: controller?.enabled ?? false,
      storageSupported: sessionVault.supported,
      storageEnabled: savedCurrentSession,
      busy:
          vaultBusy || (controller?.busy ?? false) || loading || applyingRoute,
      expiresAt: api.sessionExpiresAt,
      message: vaultMessage,
      onStorageChanged: (value) => unawaited(setSavedSession(value)),
      onLockChanged: (value) async {
        if (controller == null || vaultBusy || controller.busy || !logged) {
          return;
        }
        if (value) {
          await controller.enable();
        } else {
          controller.disable();
        }
        if (mounted) {
          setState(
            () => vaultMessage =
                controller.message ??
                (controller.enabled ? '本机会话锁已开启。' : '本机会话锁已关闭。'),
          );
        }
      },
    );
  }

  Future<void> restoreServerProfile() async {
    final before = serverAddress.text;
    try {
      final saved = await profileStore.load();
      if (!mounted ||
          busy ||
          logged ||
          pairingOpen ||
          saved == null ||
          serverAddress.text != before ||
          username.text.isNotEmpty) {
        return;
      }
      setState(() {
        serverAddress.text = saved.profile.apiBase;
        username.text = saved.accountLabel;
      });
    } catch (_) {
      // Connection hints are optional; platform storage failure never signs in.
    }
  }

  Future<MailApi> prepareLoginApi() async {
    if (!kIsWeb && serverAddress.text.trim().isNotEmpty) {
      final profile = ServerProfile.parse(serverAddress.text.trim());
      if (api.base != profile.apiBase) {
        final previous = deviceSession;
        deviceSession = null;
        await previous?.retire();
        _configuredApi?.dispose();
        widget.api.token = null;
        _configuredApi = MailApi(base: profile.apiBase);
        bindApiSession(_configuredApi!);
      }
    }
    return api;
  }

  Future<void> rememberServerProfile() async {
    if (kIsWeb) return;
    try {
      await profileStore.save(
        ServerProfile.parse(api.base),
        accountLabel: username.text.trim(),
      );
    } catch (_) {
      // No token is stored. Failure only removes next-launch convenience.
    }
  }

  void cancelPasskeyAcceptance() {
    if (!_acceptingPasskey) return;
    _acceptingPasskey = false;
    vaultOperation++;
    final retiring = deviceSession;
    deviceSession = null;
    if (retiring != null) unawaited(retiring.retire());
  }

  Future<void> acceptPasskeySession(
    MailApi candidate,
    PasskeySession session,
  ) async {
    void discardGrant() {
      if (session.refreshToken != null) {
        unawaited(
          candidate
              .revokeDeviceSession(session.refreshToken!)
              .catchError((Object _) {}),
        );
      }
    }

    if (!mounted ||
        logged ||
        pairingOpen ||
        _loggingOut ||
        !identical(api, candidate)) {
      discardGrant();
      return;
    }
    final operation = ++vaultOperation;
    final serverIntent = serverAddress.text;
    bool current() =>
        mounted &&
        operation == vaultOperation &&
        serverAddress.text == serverIntent &&
        !logged &&
        !pairingOpen &&
        !_loggingOut &&
        identical(api, candidate);
    _acceptingPasskey = true;
    try {
      if (!await discardSavedSession() || !current()) {
        discardGrant();
        return;
      }
      final previous = deviceSession;
      deviceSession = null;
      await previous?.retire();
      if (deviceSessionVault.supported) {
        final result = await deviceSessionVault.clear();
        if (result.state != DeviceVaultState.empty) {
          discardGrant();
          throw ApiException('VAULT_CLEAR_FAILED', '未能删除原设备登录，请重试。');
        }
      }
      if (!current()) {
        discardGrant();
        return;
      }
      rememberedMetadata = null;
      candidate.token = session.accessToken;
      candidate.sessionExpiresAt = session.expiresAt;
      candidate.sessionAccount = session.accountName;
      if (session.durable) {
        if (!deviceSessionVault.supported || !rememberDevice) {
          discardGrant();
          candidate.clearAccess(notify: false);
          throw ApiException('REMEMBER_DEVICE_REQUIRED', '请确认是否记住此设备后重新登录。');
        }
        final coordinator = createDeviceSession(
          candidate,
          ServerProfile.parse(candidate.base),
        );
        deviceSession = coordinator;
        await coordinator.acceptLogin(
          session.sessionResponse,
          explicitOptIn: true,
        );
        if (!current() || !identical(deviceSession, coordinator)) {
          await coordinator.logout();
          return;
        }
      }
      username.text = session.accountName;
      password.clear();
      if (!_appForeground) {
        await deviceSession?.suspend();
        if (!hasDurableSession) candidate.clearAccess(notify: false);
        return;
      }
      // Persistence has completed before authenticated UI is exposed. Mailbox
      // loading may continue asynchronously, preserving the existing UI flow.
      unawaited(resumeAuthenticatedSession().catchError(fail));
    } finally {
      if (operation == vaultOperation) _acceptingPasskey = false;
    }
  }

  Future<void> login() async {
    if (busy || _loggingOut || (widget.localUnlock?.busy ?? false)) return;
    final operation = ++vaultOperation;
    final accountIntent = username.text.trim();
    final serverIntent = serverAddress.text;
    final remember = deviceSessionVault.supported && rememberDevice;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (!await discardSavedSession()) return;
      await prepareLoginApi();
      final source = api;
      final previous = deviceSession;
      deviceSession = null;
      await previous?.retire();
      if (deviceSessionVault.supported) {
        final cleared = await deviceSessionVault.clear();
        if (cleared.state != DeviceVaultState.empty) {
          throw ApiException('VAULT_CLEAR_FAILED', '未能删除原设备登录，请重试后再登录。');
        }
        rememberedMetadata = null;
        _deviceClearFailed = false;
      }
      final profile = remember ? ServerProfile.parse(source.base) : null;
      final response = await source.login(
        accountIntent,
        password.text,
        rememberDevice: remember,
        deviceName: remember
            ? sanitizeDeviceName(rememberedDeviceName.text)
            : null,
      );
      if (!mounted ||
          operation != vaultOperation ||
          !identical(api, source) ||
          serverAddress.text != serverIntent ||
          username.text.trim() != accountIntent ||
          pairingOpen) {
        if (response['refreshToken'] is String) {
          unawaited(
            source
                .revokeDeviceSession(response['refreshToken'] as String)
                .catchError((Object _) {}),
          );
        }
        if (source.token == response['accessToken']) {
          source.clearAccess(notify: false);
        }
        return;
      }
      if (remember && response['refreshToken'] != null) {
        final coordinator = createDeviceSession(source, profile!);
        deviceSession = coordinator;
        await coordinator.acceptLogin(response, explicitOptIn: true);
        if (!mounted ||
            operation != vaultOperation ||
            !identical(deviceSession, coordinator)) {
          return;
        }
      }
      password.clear();
      if (!_appForeground) {
        await deviceSession?.suspend();
        if (!hasDurableSession) source.clearAccess(notify: false);
        return;
      }
      await resumeAuthenticatedSession();
      if (remember && response['refreshToken'] == null && mounted && logged) {
        setState(() => error = '此服务器尚未提供长期登录，本次登录仍按原有效期到期，未记住此设备。');
      }
    } catch (e) {
      if (mounted && operation == vaultOperation) fail(e);
    } finally {
      if (mounted && operation == vaultOperation) setState(() => busy = false);
    }
  }

  Future<void> resumeAuthenticatedSession() async {
    if (!mounted || api.token == null) return;
    final session = ++sessionGeneration;
    sessionExpiryTimer?.cancel();
    final expiry = api.sessionExpiresAt;
    if (expiry != null && !hasDurableSession) {
      final remaining = expiry.difference(DateTime.now().toUtc());
      if (remaining <= Duration.zero) {
        endSession(message: '本次登录已到期，请重新登录');
        return;
      }
      sessionExpiryTimer = Timer(remaining, () {
        if (mounted && logged) endSession(message: '本次登录已到期，请重新登录');
      });
    }
    loginGeneration++;
    unawaited(rememberServerProfile());
    widget.localUnlock?.attachSession(Object());
    final resume = pendingRoute;
    applyingRoute = true;
    setState(() => logged = true);
    try {
      await refresh();
    } finally {
      applyingRoute = false;
    }
    if (!isCurrentSession(session)) return;
    await applyBrowserRoute(resume.location, restoringLogin: true);
    poll?.cancel();
    poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_appForeground &&
          !durableLocked &&
          !loading &&
          !actionBusy &&
          !applyingRoute &&
          !settingsOpen &&
          !(widget.localUnlock?.locked ?? false)) {
        refresh(silent: true, passive: true);
      }
    });
  }

  void discardPairedResult(DevicePairingResult result) {
    if (result.refreshToken != null) {
      unawaited(
        result.api
            .revokeDeviceSession(result.refreshToken!)
            .then<void>((_) {}, onError: (Object _) {})
            .whenComplete(result.api.dispose),
      );
    } else {
      result.api.dispose();
    }
  }

  Future<void> acceptPairedDevice(
    ServerProfile profile,
    DevicePairingResult result,
  ) async {
    if (!mounted || !pairingOpen || logged || _loggingOut) {
      discardPairedResult(result);
      return;
    }
    final operation = ++vaultOperation;
    final cleared = await discardSavedSession();
    if (!cleared ||
        !mounted ||
        operation != vaultOperation ||
        !pairingOpen ||
        logged) {
      discardPairedResult(result);
      return;
    }
    final previous = deviceSession;
    deviceSession = null;
    await previous?.retire();
    if (!mounted || operation != vaultOperation || !pairingOpen || logged) {
      discardPairedResult(result);
      return;
    }
    if (deviceSessionVault.supported) {
      final removed = await deviceSessionVault.clear();
      if (!mounted || operation != vaultOperation || !pairingOpen || logged) {
        discardPairedResult(result);
        return;
      }
      if (removed.state != DeviceVaultState.empty) {
        discardPairedResult(result);
        setState(() {
          _deviceClearFailed = true;
          pairingOpen = false;
          error = '未能删除原设备登录，未保存新登录。请重试删除后重新扫码；不要将设备交给他人。';
        });
        return;
      }
      rememberedMetadata = null;
      _deviceClearFailed = false;
    }
    _configuredApi?.dispose();
    widget.api.token = null;
    _configuredApi = result.api;
    result.api.sessionExpiresAt = result.expiresAt;
    result.api.sessionAccount = result.accountName;
    result.api.sessionDeviceId = result.deviceId;
    bindApiSession(result.api);
    serverAddress.text = profile.apiBase;
    username.text = result.accountName;
    password.clear();
    setState(() {
      pairingOpen = false;
      busy = true;
      error = '';
    });
    try {
      if (result.remembered) {
        final coordinator = createDeviceSession(result.api, profile);
        deviceSession = coordinator;
        await coordinator.acceptLogin(
          result.sessionResponse,
          explicitOptIn: true,
        );
        if (!mounted ||
            operation != vaultOperation ||
            !identical(deviceSession, coordinator)) {
          return;
        }
      }
      await resumeAuthenticatedSession();
    } catch (e) {
      fail(e);
    } finally {
      if (mounted && operation == vaultOperation) setState(() => busy = false);
    }
  }

  void closeMessage() {
    detailGeneration++;
    selected = null;
    inlineReply = null;
  }

  Future<void> refresh({
    bool silent = false,
    bool append = false,
    bool passive = false,
  }) async {
    final session = sessionGeneration;
    if (!isCurrentSession(session) ||
        (append && loading) ||
        (silent && refreshing)) {
      return;
    }
    Future<dynamic> read(String path, {Map<String, String>? query}) => passive
        ? api.requestPassive(path, query: query)
        : api.request('GET', path, query: query);
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
        nextAccounts = rows((await read('/accounts'))['items']);
        if (!isCurrentSession(session) || gen != generation) return;
        nextCaps = Map<String, dynamic>.from(
          await read('/settings/capabilities'),
        );
      }
      if (!isCurrentSession(session) || gen != generation) return;
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
        final data = await read(
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
        if (!isCurrentSession(session) || gen != generation) return;
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
      if (passive && e is ApiException && e.code == 'PASSIVE_ACCESS_EXPIRED') {
        return;
      }
      if (isSameSession(session) && gen == generation) fail(e);
    } finally {
      if (isCurrentSession(session) && gen == generation) {
        setState(() {
          loading = false;
          refreshing = false;
        });
      }
    }
  }

  Future<void> chooseAccount(String id) async {
    if (!await canLeave() || !mounted) return;
    final session = sessionGeneration;
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
        if (isCurrentSession(session) && account == id) {
          setState(() => folders = rows(data['items']));
        }
      } catch (e) {
        if (isSameSession(session) && account == id) fail(e);
      }
    }
  }

  Future<void> open(Json mail, {bool guarded = true}) async {
    if (guarded && (!await canLeave() || !mounted)) return;
    final session = sessionGeneration;
    if (!isCurrentSession(session)) return;
    inlineReply = null;
    if (detailScroll.hasClients) detailScroll.jumpTo(0);
    final gen = ++detailGeneration;
    setState(() => selected = {...mail, '_loading': true});
    try {
      final data = await api.request('GET', '/messages/${mail['id']}');
      if (isCurrentSession(session) && gen == detailGeneration) {
        setState(() => selected = Map<String, dynamic>.from(data));
      }
    } catch (e) {
      if (isSameSession(session) && gen == detailGeneration) {
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
    final session = sessionGeneration;
    if (!isCurrentSession(session)) return;
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
      if (!isCurrentSession(session)) return;
      var state = result['status'];
      for (
        var n = 0;
        n < 20 &&
            ![
              'SUCCEEDED',
              'COMPLETED',
              'APPLIED',
              'FAILED',
              'UNKNOWN',
            ].contains(state);
        n++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!isCurrentSession(session)) return;
        state = (await api.request(
          'GET',
          '/commands/${result['id']}',
        ))['status'];
      }
      if (!isCurrentSession(session)) return;
      notify(
        state == 'FAILED'
            ? '操作失败，请刷新后重试'
            : state == 'UNKNOWN'
            ? '结果待核实，请勿重复提交'
            : '操作状态：$state',
      );
      await refresh(silent: true);
      if (!isCurrentSession(session) || detailGen != detailGeneration) return;
      if (['TRASH', 'ARCHIVE', 'RESTORE'].contains(type)) {
        if (mounted) setState(closeMessage);
      } else {
        await open(item, guarded: false);
      }
    } catch (e) {
      if (isSameSession(session)) fail(e);
    } finally {
      if (isCurrentSession(session)) setState(() => actionBusy = false);
    }
  }

  Future<void> sync() async {
    if (actionBusy) return;
    final session = sessionGeneration;
    if (!isCurrentSession(session)) return;
    setState(() => actionBusy = true);
    try {
      for (final a in accounts.where(
        (a) => account.isEmpty || a['id'] == account,
      )) {
        if (!isCurrentSession(session)) return;
        await api.request('POST', '/accounts/${a['id']}/sync');
      }
      if (!isCurrentSession(session)) return;
      notify('同步任务已提交，列表会定期刷新');
      await refresh();
    } catch (e) {
      if (isSameSession(session)) fail(e);
    } finally {
      if (isCurrentSession(session)) setState(() => actionBusy = false);
    }
  }

  Future<void> compose({Json? reply, Json? draft, bool forward = false}) async {
    if (composeOpen || !await canLeave() || !mounted) return;
    if (accounts.isEmpty) {
      await settings();
      return;
    }
    final session = sessionGeneration;
    if (!isCurrentSession(session)) return;
    setState(() => inlineReply = null);
    composeOpen = true;
    final dialogIdentity = Object();
    _composeDialogIdentity = dialogIdentity;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ComposeDialog(
          api: api,
          captureSessionGuard: captureSessionGuard,
          runExternalPicker: runExternalPicker,
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
      if (identical(_composeDialogIdentity, dialogIdentity)) {
        composeOpen = false;
        _composeDialogIdentity = null;
      }
    }
    if (isCurrentSession(session)) refresh(silent: true);
  }

  Future<void> showDrafts() async {
    if (!await canLeave() || !mounted) return;
    final session = sessionGeneration;
    final login = loginGeneration;
    if (!isCurrentSession(session)) return;
    setState(() => inlineReply = null);
    try {
      final drafts = rows((await api.request('GET', '/drafts'))['items']);
      if (!mounted || !isCurrentSession(session)) return;
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
                              if (!mounted ||
                                  !logged ||
                                  login != loginGeneration ||
                                  (widget.localUnlock?.locked ?? false)) {
                                return;
                              }
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
      if (isSameSession(session)) fail(e);
    }
  }

  Future<void> outbox() async {
    if (!isCurrentSession(sessionGeneration)) return;
    showDialog<void>(
      context: context,
      builder: (_) =>
          OutboxDialog(api: api, captureSessionGuard: captureSessionGuard),
    );
  }

  Future<void> settings({String section = 'accounts'}) async {
    if (settingsOpen &&
        !{'devices', 'passkeys'}.contains(settingsSection) &&
        !{'devices', 'passkeys'}.contains(section)) {
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
    if (!{'accounts', 'devices', 'passkeys'}.contains(section)) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => settingsKey.currentState?.showSection(section),
      );
    }
  }

  Future<void> signout() async {
    if (!await canLeave() || !mounted) return;
    signoutFromLock();
  }

  Future<void> downloadAttachment(
    Json attachment, {
    Future<void> Function(String, Uint8List)? save,
  }) async {
    final session = sessionGeneration;
    if (!isCurrentSession(session)) return;
    try {
      final bytes = await api.download(attachment['id'].toString());
      if (!isCurrentSession(session)) return;
      final name = (attachment['fileName'] ?? 'attachment')
          .toString()
          .replaceAll(RegExp(r'[\\/\x00-\x1F]'), '_');
      if (save != null) {
        await save(name, bytes);
      } else {
        await FileSaver.instance.saveFile(name: name, bytes: bytes);
      }
    } catch (e) {
      if (isCurrentSession(session)) notify(e.toString());
    }
  }

  void signoutFromLock() {
    if (_loggingOut) return;
    final coordinator = deviceSession;
    if (coordinator != null && coordinator.durable) {
      _loggingOut = true;
      // logout copies the refresh credential synchronously before local UI
      // retirement, so expired access never prevents family revocation.
      final request = coordinator.logout();
      deviceSession = null;
      rememberedMetadata = null;
      endSession();
      unawaited(
        request.then<void>(
          (_) {
            if (mounted) {
              setState(() => _loggingOut = false);
            } else {
              _loggingOut = false;
            }
          },
          onError: (Object e) {
            _loggingOut = false;
            _deviceClearFailed =
                e is ApiException && e.code == 'VAULT_CLEAR_FAILED';
            if (mounted) {
              setState(
                () =>
                    error = e is ApiException && e.code == 'VAULT_CLEAR_FAILED'
                    ? '未能删除此设备保存的登录，请重试；不要将设备交给他人。'
                    : '此设备已退出，但尚未确认服务器撤销。请联网后在其他已登录设备撤销此设备。',
              );
            }
          },
        ),
      );
      return;
    }
    final request = api.request('POST', '/auth/logout');
    endSession();
    unawaited(request.then<void>((_) {}, onError: (_) {}));
  }

  Future<void> retryDeviceClear() async {
    if (_loggingOut || busy) return;
    setState(() => busy = true);
    final result = await deviceSessionVault.clear();
    if (!mounted) return;
    setState(() {
      busy = false;
      _deviceClearFailed = result.state != DeviceVaultState.empty;
      error = _deviceClearFailed
          ? '仍未能删除此设备登录，请重试或在系统设置中清除应用数据。'
          : '已删除本机登录；服务器撤销仍需在其他已登录设备确认。';
    });
  }

  void endSession({String message = ''}) {
    cancelPickerContinuation();
    final retired = deviceSession;
    deviceSession = null;
    if (retired != null) {
      rememberedMetadata = null;
      unawaited(retired.retire());
    }
    vaultOperation++;
    busy = false;
    vaultBusy = false;
    sessionExpiryTimer?.cancel();
    unawaited(discardSavedSession());
    sessionGeneration++;
    loginGeneration++;
    _composeDialogIdentity = null;
    logged = false;
    widget.clearTransientRoutes?.call();
    widget.localUnlock?.attachSession(null);
    api.token = null;
    poll?.cancel();
    debounce?.cancel();
    generation++;
    detailGeneration++;
    search.clear();
    if (!mounted) return;
    setState(() {
      logged = false;
      actionBusy = false;
      composeOpen = false;
      applyingRoute = false;
      pairingOpen = false;
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
    updateDevicePrivacy();
  }

  @override
  Widget build(BuildContext context) {
    if (!logged && pairingOpen) {
      return DeviceOnboardingPage(
        onConnected: acceptPairedDevice,
        onClose: () => setState(() => pairingOpen = false),
        scanPairingCode: supportsDeviceScanner
            ? () => Navigator.of(context).push<String>(
                MaterialPageRoute(builder: (_) => const DeviceScannerPage()),
              )
            : null,
      );
    }
    if (!logged) return loginView();
    if (durableLocked && widget.onDevicePrivacyChanged == null) {
      return durableLockView();
    }
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
                                        child:
                                            settingsOpen &&
                                                settingsSection == 'passkeys'
                                            ? PasskeySettingsPanel(
                                                key: passkeySettingsKey,
                                                api: api,
                                                onClose: () => setState(
                                                  () => settingsOpen = false,
                                                ),
                                              )
                                            : settingsOpen &&
                                                  settingsSection == 'devices'
                                            ? DeviceSettingsPage(
                                                key: deviceSettingsKey,
                                                api: api,
                                                onClose: () {
                                                  setState(
                                                    () => settingsOpen = false,
                                                  );
                                                  if (api.token == null &&
                                                      !hasDurableSession) {
                                                    endSession();
                                                  }
                                                },
                                              )
                                            : settingsOpen
                                            ? AccountSettingsPage(
                                                key: settingsKey,
                                                initialSection: settingsSection,
                                                onSectionChanged: (next) {
                                                  settingsSection = next;
                                                  publishRoute();
                                                },
                                                api: api,
                                                deviceSecurity:
                                                    deviceSecuritySettings(),
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
    body: ResponsiveLoginLayout(
      download: kIsWeb ? AndroidDownloadCard(client: api.client) : null,
      login: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.mark_email_unread_rounded, size: 44, color: blue),
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
          if (rememberedMetadata != null && deviceSessionVault.supported)
            rememberedDeviceCard(),
          if (savedSessionMetadata != null && sessionVault.supported)
            savedSessionCard(),
          const Text(
            '登录你的私人邮件服务器',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: username,
            enabled: !busy && !_loggingOut,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(labelText: '用户名'),
            onSubmitted: (_) => login(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: password,
            enabled: !busy && !_loggingOut,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(labelText: '密码'),
            onSubmitted: (_) => login(),
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('server-address'),
              controller: serverAddress,
              enabled: !busy && !_loggingOut,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '服务器 URL',
                hintText: 'https://mail.example.com/api/v1',
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (deviceSessionVault.supported)
            CheckboxListTile(
              key: const Key('remember-device'),
              contentPadding: EdgeInsets.zero,
              value: rememberDevice,
              onChanged: busy
                  ? null
                  : (value) => setState(() => rememberDevice = value == true),
              title: const Text('记住此设备'),
              subtitle: const Text(
                '登录后加密保存登录并自动续期。默认连续 30 天未使用或满 365 天需重新登录，可随时退出或撤销。指纹锁默认关闭，可在设置中另行开启。',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          if (deviceSessionVault.supported && rememberDevice)
            TextField(
              key: const Key('remember-device-name'),
              controller: rememberedDeviceName,
              onChanged: (_) => setState(() {}),
              enabled: !busy && !_loggingOut,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '此设备名称',
                helperText: '用于识别和撤销此设备，可自行修改',
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error, style: const TextStyle(color: Colors.red)),
            ),
          if (_deviceClearFailed)
            TextButton(
              key: const Key('retry-device-clear'),
              onPressed: busy || _loggingOut ? null : retryDeviceClear,
              child: const Text('重试删除此设备登录'),
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: busy || _loggingOut ? null : login,
              child: Text(busy ? '正在连接…' : '登录'),
            ),
          ),
          const SizedBox(height: 12),
          PasskeyLoginButton(
            acquireApi: prepareLoginApi,
            enabled: !busy && !_loggingOut,
            contextKey: serverAddress.text,
            isCurrent: () => mounted && !logged && !pairingOpen,
            onBusyChanged: (value) {
              if (mounted) setState(() => busy = value);
            },
            onAuthenticated: acceptPasskeySession,
            rememberDevice: deviceSessionVault.supported && rememberDevice,
            deviceName: sanitizeDeviceName(rememberedDeviceName.text),
            onCancelled: cancelPasskeyAcceptance,
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('pair-device'),
                onPressed: busy || _loggingOut
                    ? null
                    : () => setState(() {
                        password.clear();
                        error = '';
                        pairingOpen = true;
                      }),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫描网页二维码，配置并登录'),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            kIsWeb
                ? '连接由你掌控的服务器。网页登录凭证仅保存在本次会话内；刷新或关闭后需重新登录。'
                : '勾选“记住此设备”后点登录，即允许在此设备保持登录。扫码登录由网页账户所有者决定是否记住；取消勾选则仅本次会话有效。',
            style: TextStyle(fontSize: 12, color: muted, height: 1.6),
          ),
        ],
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
                Icon(Icons.mark_email_unread_outlined, color: blue, size: 30),
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
          sidebarAction(
            '设备与登录',
            Icons.devices_outlined,
            () => settings(section: 'devices'),
          ),
          sidebarAction(
            '通行密钥',
            Icons.key_outlined,
            () => settings(section: 'passkeys'),
          ),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
        if (widget.localUnlock?.supported ?? false)
          IconButton(
            key: const Key('local-session-lock'),
            tooltip: widget.localUnlock!.enabled
                ? '锁定本次会话'
                : '设备安全设置（指纹 / 系统验证）',
            onPressed:
                vaultBusy ||
                    widget.localUnlock!.busy ||
                    (!widget.localUnlock!.enabled && (loading || applyingRoute))
                ? null
                : () async {
                    final controller = widget.localUnlock!;
                    if (controller.enabled) {
                      controller.lock();
                    } else {
                      await settings();
                    }
                  },
            icon: const Icon(Icons.lock_outline, size: 22),
          ),
        if ((widget.localUnlock?.enabled ?? false) &&
            !widget.localUnlock!.locked)
          IconButton(
            key: const Key('disable-local-session-lock'),
            tooltip: '关闭本次会话的本机锁',
            onPressed: vaultBusy || widget.localUnlock!.busy
                ? null
                : () async {
                    final controller = widget.localUnlock!;
                    final session = sessionGeneration;
                    if (!isCurrentSession(session)) return;
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('关闭本机会话锁？'),
                        content: const Text(
                          '关闭后，返回应用无需再次进行系统验证。'
                          '本次服务器登录仍然有效，你可以随时重新启用本机锁。'
                          '\n\n如果选择附件时本机锁中断了操作，可先关闭本机锁再选择文件。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('继续保护'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('确认关闭本机锁'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true && isCurrentSession(session)) {
                      controller.disable();
                    }
                  },
            icon: const Icon(Icons.lock_open_outlined, size: 22),
          ),
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
    final label =
        {
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
                          color: filter == entry.$1 ? blue : Colors.transparent,
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
                      onPressed: loading ? null : () => refresh(append: true),
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
                  child: const Icon(Icons.inbox_outlined, size: 40, color: ink),
                ),
                const SizedBox(height: 28),
                const Text(
                  '让邮件，在这里靠岸。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w400),
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
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
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
                  onPressed:
                      actionBusy || m['_loading'] == true || m['_error'] == true
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
                  onPressed:
                      actionBusy || m['_loading'] == true || m['_error'] == true
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
                  onPressed:
                      actionBusy || m['_loading'] == true || m['_error'] == true
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
                                  onPressed: () => downloadAttachment(a),
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
                                captureSessionGuard: captureSessionGuard,
                                runExternalPicker: runExternalPicker,
                                key: inlineComposeKey,
                                api: api,
                                accounts: accounts,
                                initialAccountId: m['accountId'] ?? account,
                                reply: inlineReply,
                                forward: inlineForward,
                                inline: true,
                                maxBytes:
                                    caps?['limits']?['maxAttachmentBytes'] ??
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
  final bool Function() Function()? captureSessionGuard;
  const OutboxDialog({super.key, required this.api, this.captureSessionGuard});
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
    timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => load(passive: true),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load({bool passive = false}) async {
    final check = widget.captureSessionGuard?.call() ?? () => true;
    final bearer = widget.api.token;
    final coordinator = widget.api.deviceSession;
    final epoch = coordinator?.epoch;
    bool current() =>
        mounted &&
        check() &&
        (coordinator == null
            ? widget.api.token == bearer
            : identical(widget.api.deviceSession, coordinator) &&
                  coordinator.durable &&
                  coordinator.epoch == epoch);
    if (!current()) return;
    try {
      final data = passive
          ? await widget.api.requestPassive('/send-intents')
          : await widget.api.request('GET', '/send-intents');
      if (current()) {
        setState(() {
          items = (data['items'] as List)
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          error = '';
          loading = false;
        });
      }
    } catch (e) {
      if (passive && e is ApiException && e.code == 'PASSIVE_ACCESS_EXPIRED') {
        return;
      }
      if (current()) {
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
            const Padding(padding: EdgeInsets.all(24), child: Text('暂无发送记录')),
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
                        '${{'QUEUED': '排队中', 'PREPARING': '准备发送', 'SUBMITTING': '提交中', 'ACCEPTED': '已被服务商接受', 'SENT_COPY_CONFIRMED': '已确认已发送副本', 'FAILED': '发送失败', 'UNKNOWN': '结果待核实'}[m['status']] ?? m['status']}${m['errorCode'] == null ? '' : ' · ${m['errorCode']}'}',
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
