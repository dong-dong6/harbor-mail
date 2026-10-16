import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/device_session_vault.dart';
import 'package:harbor_mail/device_session.dart';
import 'package:harbor_mail/device_pairing_api.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:harbor_mail/main.dart';
import 'package:harbor_mail/passkey_api.dart';
import 'package:harbor_mail/server_profile_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_session_test.dart' show FakeVault, secret;
import 'compose_session_guard_test.dart' show ControlledPicker, syntheticFile;

class UiVault extends FakeVault {
  int unlocks = 0;
  Completer<void>? biometricGate;
  bool cancelBiometric = false, rejectProtectedOverwrite = false;
  @override
  Future<DeviceVaultResult> save(
    DeviceSession session, {
    required bool explicitOptIn,
  }) async {
    if (rejectProtectedOverwrite && stored != null && biometric) {
      return result(DeviceVaultState.failed);
    }
    return super.save(session, explicitOptIn: explicitOptIn);
  }

  @override
  Future<DeviceVaultResult> clear() async {
    final cleared = await super.clear();
    if (cleared.state == DeviceVaultState.empty) biometric = false;
    return cleared;
  }

  @override
  Future<DeviceVaultResult> unlock({
    required profile,
    required String accountId,
  }) {
    unlocks++;
    return super.unlock(profile: profile, accountId: accountId);
  }

  @override
  Future<DeviceVaultResult> commitRotation({
    required profile,
    required String accountId,
    required String familyId,
    required String requestId,
    required String nextRefresh,
    required DateTime idleExpiresAt,
    required DateTime absoluteExpiresAt,
  }) async {
    commits++;
    if (stored?.pending?.requestId != requestId ||
        stored?.pending?.nextRefresh != nextRefresh) {
      return result(DeviceVaultState.mismatch);
    }
    stored = DeviceSession(
      profile: profile,
      accountId: accountId,
      familyId: familyId,
      refreshToken: nextRefresh,
      idleExpiresAt: idleExpiresAt,
      absoluteExpiresAt: absoluteExpiresAt,
    );
    return result(DeviceVaultState.saved);
  }

  @override
  Future<DeviceVaultResult> setBiometricEnabled(
    bool enabled, {
    required bool explicitOptIn,
  }) async {
    if (biometricGate != null) await biometricGate!.future;
    if (cancelBiometric) return result(DeviceVaultState.canceled);
    return super.setBiometricEnabled(enabled, explicitOptIn: explicitOptIn);
  }
}

void main() {
  late UiVault vault;
  late List<http.Request> requests;
  late MailboxState state;
  late MailApi api;
  bool offline = false, populatedMailbox = false;
  final now = DateTime.now().toUtc();
  var serverNow = now;
  Map<String, dynamic> response({String? next}) => {
    'accessToken': 'synthetic-ui-access-${requests.length}',
    'expiresAt': serverNow.add(const Duration(minutes: 15)).toIso8601String(),
    'refreshToken': next ?? secret(1),
    'refreshExpiresAt': serverNow
        .add(const Duration(days: 30))
        .toIso8601String(),
    'sessionExpiresAt': now.add(const Duration(days: 365)).toIso8601String(),
    'deviceId': '00000000-0000-4000-8000-000000000001',
    'accountName': 'synthetic-owner',
    'permission': 'OWNER_FULL_ACCESS',
  };
  http.Client client() => MockClient((request) async {
    requests.add(request);
    if (offline) throw StateError('Synthetic offline');
    final path = request.url.path;
    Object data;
    if (path.endsWith('/auth/login')) {
      final body = jsonDecode(request.body) as Map;
      data = body['rememberDevice'] == true
          ? response()
          : {
              'accessToken': 'synthetic-legacy',
              'expiresAt': now.add(const Duration(hours: 8)).toIso8601String(),
            };
    } else if (path.endsWith('/auth/refresh')) {
      final body = jsonDecode(request.body) as Map;
      data = response(
        next:
            body['nextRefreshToken'] as String? ??
            body['nextRefresh'] as String?,
      );
    } else if (path.endsWith('/accounts') && populatedMailbox) {
      data = {
        'items': [
          {'id': 'mailbox', 'email': 'synthetic@example.invalid'},
        ],
      };
    } else if (path.endsWith('/drafts') && request.method == 'POST') {
      data = {'id': 'synthetic-draft', 'revision': 1};
    } else if (path.endsWith('/drafts')) {
      data = {
        'items': [
          {'id': 'synthetic-draft', 'revision': 2},
        ],
      };
    } else if (path.endsWith('/settings/capabilities')) {
      data = {'features': <String, dynamic>{}};
    } else {
      data = {'items': [], 'hasMore': false};
    }
    return http.Response(jsonEncode(data), 200);
  });
  Future<void> setup(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    offline = false;
    populatedMailbox = false;
    serverNow = now;
    vault = UiVault();
    requests = [];
    tester.view.physicalSize = const Size(1440, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    api = MailApi(base: 'https://mail.invalid/api/v1', client: client());
    await tester.pumpWidget(
      MailApp(
        api: api,
        deviceSessionVault: vault,
        recoveryApiFactory: (base) => MailApi(base: base, client: client()),
      ),
    );
    await tester.pumpAndSettle();
    state = tester.state<MailboxState>(find.byType(Mailbox));
    state.username.text = 'synthetic-owner';
    state.password.text = 'synthetic-password';
  }

  Future<void> login(WidgetTester tester) async {
    final pending = state.login();
    await tester.pumpAndSettle();
    await pending;
    expect(state.logged, isTrue);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'remember opt-in is visible, defaults on and never enables biometrics',
    (tester) async {
      await setup(tester);
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('remember-device')))
            .value,
        isTrue,
      );
      expect(vault.saves, 0);
      await login(tester);
      final body =
          jsonDecode(
                requests
                    .firstWhere((r) => r.url.path.endsWith('/auth/login'))
                    .body,
              )
              as Map;
      expect(body['rememberDevice'], isTrue);
      expect(vault.saves, 1);
      expect(vault.biometric, isFalse);
      expect(state.hasDurableSession, isTrue);
      expect(state.sessionExpiryTimer, isNull);
      await state.settings();
      await tester.pumpAndSettle();
      expect(find.text('此设备已记住登录'), findsOneWidget);
      expect(find.byKey(const Key('saved-session-switch')), findsNothing);
      await close(tester);
    },
  );

  testWidgets('unchecking remember preserves the legacy short session', (
    tester,
  ) async {
    await setup(tester);
    state.rememberDevice = false;
    await login(tester);
    expect(vault.saves, 0);
    expect(state.hasDurableSession, isFalse);
    expect(state.sessionExpiryTimer, isNotNull);
    expect(jsonDecode(requests.first.body)['rememberDevice'], isNull);
    await close(tester);
  });

  testWidgets(
    'background clears access and no-biometric resume restores without logout',
    (tester) async {
      await setup(tester);
      await login(tester);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(api.token, isNull);
      expect(state.logged, isTrue);
      expect(vault.stored, isNotNull);
      expect(find.text('此设备的登录已锁定'), findsOneWidget);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(state.api.token, isNotNull, reason: state.error);
      expect(state.logged, isTrue);
      expect(vault.unlocks, 1);
      expect(find.text('此设备的登录已锁定'), findsNothing);
      await close(tester);
    },
  );

  testWidgets(
    'owned PIN setup may pause, stays private and commits only after success',
    (tester) async {
      await setup(tester);
      await login(tester);
      vault.biometricGate = Completer<void>();
      final before = state.deviceSession!.epoch;
      final enabling = state.setDeviceBiometric(true);
      await tester.pump();
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(state.deviceSession!.epoch, before);
      expect(vault.biometric, isFalse);
      expect(api.token, isNull);
      expect(state.deviceSession!.foreground, isFalse);
      expect(find.text('此设备的登录已锁定'), findsOneWidget);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      vault.biometricGate!.complete();
      await enabling;
      await tester.pumpAndSettle();
      expect(vault.biometric, isTrue);
      final unlocksAfterSetup = vault.unlocks;
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(vault.unlocks, unlocksAfterSetup);
      expect(find.byKey(const Key('unlock-remembered-device')), findsOneWidget);
      final resumed = state.resumeDeviceSession();
      await tester.pumpAndSettle();
      await resumed;
      expect(vault.unlocks, unlocksAfterSetup + 1);
      expect(state.logged, isTrue);
      await close(tester);
    },
  );

  testWidgets(
    'offline refresh retains remembered login; offline logout warns and clears',
    (tester) async {
      await setup(tester);
      await login(tester);
      offline = true;
      try {
        await state.deviceSession!.ensureAccess(force: true);
      } on ApiException catch (_) {}
      expect(state.logged, isTrue);
      expect(vault.stored?.pending, isNotNull);
      final saved = vault.stored;
      state.signoutFromLock();
      await tester.pumpAndSettle();
      expect(state.logged, isFalse);
      expect(vault.stored, isNull);
      expect(saved, isNotNull);
      expect(state.error, contains('尚未确认服务器撤销'));
      expect(
        requests.any((r) => r.url.path.endsWith('/auth/device-session/logout')),
        isTrue,
      );
      await close(tester);
    },
  );

  testWidgets(
    'cold startup restores matching HTTPS profile without a biometric prompt',
    (tester) async {
      await setup(tester);
      await login(tester);
      final remembered = vault.stored;
      await close(tester);
      expect(remembered, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ServerProfileStore.preferenceKey), isNotNull);
      await tester.pumpWidget(
        MailApp(
          api: MailApi(base: 'https://mail.invalid/api/v1', client: client()),
          deviceSessionVault: vault,
          recoveryApiFactory: (base) => MailApi(base: base, client: client()),
        ),
      );
      await tester.pumpAndSettle();
      state = tester.state<MailboxState>(find.byType(Mailbox));
      expect(state.logged, isTrue);
      expect(vault.unlocks, 1);
      expect(vault.biometric, isFalse);
      await close(tester);
    },
  );
  testWidgets(
    'remembered passkey waits for persistence before opening mailbox',
    (tester) async {
      await setup(tester);
      vault.saveGate = Completer<void>();
      final session = PasskeySession.fromJson(response());
      final acceptance = state.acceptPasskeySession(api, session);
      await tester.pump();
      expect(state.logged, isFalse);
      expect(vault.saves, 1);
      vault.saveGate!.complete();
      await acceptance;
      await tester.pumpAndSettle();
      expect(state.logged, isTrue);
      expect(state.hasDurableSession, isTrue);
      expect(vault.biometric, isFalse);
      await close(tester);
    },
  );

  testWidgets('canceling passkey during durable save never revives login', (
    tester,
  ) async {
    await setup(tester);
    vault.saveGate = Completer<void>();
    final acceptance = state
        .acceptPasskeySession(api, PasskeySession.fromJson(response()))
        .then<void>((_) {}, onError: (Object _) {});
    await tester.pump();
    state.cancelPasskeyAcceptance();
    vault.saveGate!.complete();
    await acceptance;
    await tester.pumpAndSettle();
    expect(state.logged, isFalse);
    expect(vault.stored, isNull);
    expect(api.token, isNull);
    expect(
      requests.any((r) => r.url.path.endsWith('/auth/device-session/logout')),
      isTrue,
    );
    await close(tester);
  });

  testWidgets('Android 390 by 844 login controls stay reachable by scrolling', (
    tester,
  ) async {
    await setup(tester);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remember-device')), findsOneWidget);
    expect(find.byKey(const Key('remember-device-name')), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(FilledButton, '登录').hitTestable(),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('passkey-login')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('passkey-login')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets(
    'cancelled PIN setup restores the original unprotected remembered login',
    (tester) async {
      await setup(tester);
      await login(tester);
      vault.cancelBiometric = true;
      vault.biometricGate = Completer<void>();
      final enabling = state.setDeviceBiometric(true);
      await tester.pump();
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(api.token, isNull);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      vault.biometricGate!.complete();
      await enabling;
      await tester.pumpAndSettle();
      expect(vault.biometric, isFalse);
      expect(state.logged, isTrue);
      expect(api.token, isNotNull);
      expect(state.durableLocked, isFalse);
      await close(tester);
    },
  );

  testWidgets('new login waits until outstanding logout deletion settles', (
    tester,
  ) async {
    await setup(tester);
    await login(tester);
    vault.clearGate = Completer<void>();
    state.signoutFromLock();
    await tester.pump();
    final loginRequests = requests
        .where((r) => r.url.path.endsWith('/auth/login'))
        .length;
    await state.login();
    expect(
      requests.where((r) => r.url.path.endsWith('/auth/login')).length,
      loginRequests,
    );
    expect(state.logged, isFalse);
    vault.clearGate!.complete();
    await tester.pumpAndSettle();
    expect(vault.stored, isNull);
    await close(tester);
  });
  for (final clearFails in [false, true]) {
    testWidgets(
      'QR replacement of protected saved slot, deletion fails: $clearFails',
      (tester) async {
        await setup(tester);
        final profile = ServerProfile.parse(api.base);
        vault.stored = DeviceSession(
          profile: profile,
          accountId: 'previous-owner',
          familyId: '00000000-0000-4000-8000-000000000009',
          refreshToken: secret(9),
          idleExpiresAt: now.add(const Duration(days: 30)),
          absoluteExpiresAt: now.add(const Duration(days: 365)),
        );
        vault.biometric = true;
        vault.rejectProtectedOverwrite = true;
        vault.failClear = clearFails;
        final original = vault.stored;
        state.pairingOpen = true;
        final pairedApi = MailApi(base: api.base, client: client())
          ..token = 'synthetic-paired-access';
        final pending = state.acceptPairedDevice(
          profile,
          DevicePairingResult(
            api: pairedApi,
            profile: profile,
            expiresAt: now.add(const Duration(minutes: 15)),
            deviceId: '00000000-0000-4000-8000-000000000001',
            accountName: 'synthetic-owner',
            permission: 'OWNER_FULL_ACCESS',
            refreshToken: secret(1),
            refreshExpiresAt: now.add(const Duration(days: 30)),
            sessionExpiresAt: now.add(const Duration(days: 365)),
          ),
        );
        await tester.pumpAndSettle();
        await pending;
        if (clearFails) {
          expect(state.logged, isFalse);
          expect(vault.stored, same(original));
          expect(state.error, contains('未能删除原设备登录'));
          expect(find.byKey(const Key('retry-device-clear')), findsOneWidget);
          expect(
            requests.any(
              (r) => r.url.path.endsWith('/auth/device-session/logout'),
            ),
            isTrue,
          );
        } else {
          expect(state.logged, isTrue);
          expect(state.hasDurableSession, isTrue);
          expect(vault.stored?.accountId, 'synthetic-owner');
          expect(vault.biometric, isFalse);
        }
        await close(tester);
      },
    );
  }

  testWidgets(
    'unattended mailbox and outbox polling cannot extend device authority',
    (tester) async {
      const notificationChannel = MethodChannel('harbor/mail_notifications');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        notificationChannel,
        (call) async {
          if (call.method == 'status') {
            return {'enabled': true, 'allowed': true};
          }
          return false;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notificationChannel,
          null,
        ),
      );
      await setup(tester);
      await login(tester);
      var clock = now;
      await state.deviceSession!.retire();
      final coordinator = DeviceSessionCoordinator(
        api: api,
        vault: vault,
        profile: ServerProfile.parse(api.base),
        now: () => clock,
      );
      state.deviceSession = coordinator;
      await coordinator.acceptLogin(response(), explicitOptIn: true);
      state.outbox();
      await tester.pumpAndSettle();
      final before = requests.length;
      final clears = vault.clears;
      clock = now.add(const Duration(minutes: 16));
      serverNow = clock;
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(requests.length, before);
      expect(state.logged, isTrue);
      expect(state.error, isEmpty);
      expect(vault.stored, isNotNull);
      expect(vault.clears, clears);
      expect(vault.begins, 0);
      await tester.tap(find.widgetWithText(TextButton, '刷新状态'));
      await tester.pumpAndSettle();
      expect(vault.begins, 1);
      expect(requests.any((r) => r.url.path.endsWith('/auth/refresh')), isTrue);
      expect(state.logged, isTrue);
      await close(tester);
    },
  );
  Future<ComposeEditorState> openComposer(WidgetTester tester) async {
    populatedMailbox = true;
    state.accounts = [
      {'id': 'mailbox', 'email': 'synthetic@example.invalid'},
    ];
    unawaited(state.compose());
    await tester.pumpAndSettle();
    final editor = tester.state<ComposeEditorState>(find.byType(ComposeDialog));
    editor.to.text = 'recipient@example.invalid';
    editor.body.text = 'Private unsaved synthetic draft';
    await tester.pump();
    return editor;
  }

  testWidgets(
    'background retains modal draft behind opaque input and semantics shield',
    (tester) async {
      await setup(tester);
      await login(tester);
      final semantics = tester.ensureSemantics();
      final editor = await openComposer(tester);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(find.byType(ComposeDialog), findsNothing);
      expect(find.byType(ComposeDialog, skipOffstage: false), findsOneWidget);
      expect(
        find.byType(ComposeDialog, skipOffstage: false).hitTestable(),
        findsNothing,
      );
      expect(
        tester.semantics.simulatedAccessibilityTraversal().map(
          (n) => n.getSemanticsData().value,
        ),
        isNot(contains('Private unsaved synthetic draft')),
      );
      expect(editor.body.text, 'Private unsaved synthetic draft');
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ComposeDialog, skipOffstage: false), findsOneWidget);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(ComposeDialog), findsOneWidget);
      expect(
        tester.state<ComposeEditorState>(find.byType(ComposeDialog)),
        same(editor),
      );
      expect(editor.body.text, 'Private unsaved synthetic draft');
      semantics.dispose();
      await close(tester);
    },
  );

  testWidgets(
    'owned Android picker restores same family then uploads exactly once',
    (tester) async {
      await setup(tester);
      await login(tester);
      final picker = ControlledPicker();
      FilePicker.platform = picker;
      final editor = await openComposer(tester);
      final upload = editor.upload();
      await tester.pump();
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      final before = requests.length;
      picker.picked.complete(syntheticFile());
      await tester.pump();
      expect(requests.length, before);
      expect(api.token, isNull);
      expect(find.byType(ComposeDialog), findsNothing);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await upload;
      expect(
        requests.where((r) => r.url.path.contains('/attachments')).length,
        1,
      );
      expect(editor.attachments, ['synthetic.txt']);
      expect(editor.body.text, 'Private unsaved synthetic draft');
      expect(state.logged, isTrue);
      await close(tester);
    },
  );

  testWidgets('protected picker result remains stale after lifecycle lock', (
    tester,
  ) async {
    await setup(tester);
    await login(tester);
    await state.setDeviceBiometric(true);
    await tester.pumpAndSettle();
    final picker = ControlledPicker();
    FilePicker.platform = picker;
    final editor = await openComposer(tester);
    final upload = editor.upload();
    await tester.pump();
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    picker.picked.complete(syntheticFile());
    await tester.pump();
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await upload;
    expect(requests.where((r) => r.url.path.contains('/attachments')), isEmpty);
    expect(state.durableLocked, isTrue);
    expect(editor.body.text, 'Private unsaved synthetic draft');
    await close(tester);
  });

  testWidgets('logout while picker is pending cannot upload its late result', (
    tester,
  ) async {
    await setup(tester);
    await login(tester);
    final picker = ControlledPicker();
    FilePicker.platform = picker;
    final editor = await openComposer(tester);
    final upload = editor.upload();
    await tester.pump();
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    state.signoutFromLock();
    await tester.pumpAndSettle();
    picker.picked.complete(syntheticFile());
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await upload;
    expect(state.logged, isFalse);
    expect(requests.where((r) => r.url.path.contains('/attachments')), isEmpty);
    await close(tester);
  });
  testWidgets('ordinary background preserves an unsaved inline reply', (
    tester,
  ) async {
    await setup(tester);
    await login(tester);
    populatedMailbox = true;
    await state.refresh();
    state.selected = {
      'id': 'synthetic-mail',
      'accountId': 'mailbox',
      'subject': 'Synthetic subject',
      'fromAddress': 'sender@example.invalid',
      'to': <Object>[],
      'bodyText': 'Synthetic plain message',
      'receivedAt': now.toIso8601String(),
    };
    state.inlineReply = state.selected;
    await state.refresh();
    await tester.pumpAndSettle();
    final editor = state.inlineComposeKey.currentState!;
    editor.body.text = 'Unsaved inline synthetic reply';
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inline-compose')), findsNothing);
    expect(state.inlineComposeKey.currentState, same(editor));
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(state.inlineComposeKey.currentState, same(editor));
    expect(editor.body.text, 'Unsaved inline synthetic reply');
    await close(tester);
  });
  testWidgets(
    'picker cannot consume a replacement family found during unlock',
    (tester) async {
      await setup(tester);
      await login(tester);
      final picker = ControlledPicker();
      FilePicker.platform = picker;
      final editor = await openComposer(tester);
      final upload = editor.upload();
      await tester.pump();
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      final previous = vault.stored!;
      final replacement = DeviceSession(
        profile: previous.profile,
        accountId: previous.accountId,
        familyId: '00000000-0000-4000-8000-000000000007',
        refreshToken: secret(7),
        idleExpiresAt: previous.idleExpiresAt,
        absoluteExpiresAt: previous.absoluteExpiresAt,
      );
      vault.stored = replacement;
      final before = requests.length;
      picker.picked.complete(syntheticFile());
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await upload;
      expect(requests.length, before);
      expect(vault.stored, same(replacement));
      expect(editor.attachments, isEmpty);
      await close(tester);
    },
  );

  testWidgets(
    'changing server while picker waits cannot authorize its result',
    (tester) async {
      await setup(tester);
      await login(tester);
      final picker = ControlledPicker();
      FilePicker.platform = picker;
      final editor = await openComposer(tester);
      final upload = editor.upload();
      await tester.pump();
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      state.serverAddress.text = 'https://replacement.invalid/api/v1';
      await state.prepareLoginApi();
      final before = requests.length;
      picker.picked.complete(syntheticFile());
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await upload;
      expect(requests.length, before);
      expect(editor.attachments, isEmpty);
      await close(tester);
    },
  );
}
