import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/local_unlock.dart';
import 'package:local_auth/local_auth.dart';

class FakeUnlockAuthenticator implements LocalUnlockAuthenticator {
  @override
  bool supported = true;
  bool available = true;
  int checks = 0;
  int prompts = 0;
  int cancellations = 0;
  Completer<bool>? capability;
  Completer<void>? cancellation;
  Completer<LocalUnlockResult>? pending;
  LocalUnlockResult result = LocalUnlockResult.verified;
  Object? failure;

  @override
  Future<bool> isAvailable() async {
    checks++;
    return capability?.future ?? available;
  }

  @override
  Future<LocalUnlockResult> authenticate() async {
    prompts++;
    if (failure != null) throw failure!;
    return pending?.future ?? result;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    await cancellation?.future;
  }
}

class FakeLocalAuthentication extends LocalAuthentication {
  bool available = true;
  bool result = true;
  Object? failure;
  int checks = 0;
  int prompts = 0;
  int cancellations = 0;
  bool? biometricOnlyUsed;
  bool? persistUsed;
  bool? sensitiveUsed;
  String? reason;

  @override
  Future<bool> isDeviceSupported() async {
    checks++;
    if (failure != null) throw failure!;
    return available;
  }

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    prompts++;
    biometricOnlyUsed = biometricOnly;
    sensitiveUsed = sensitiveTransaction;
    persistUsed = persistAcrossBackgrounding;
    reason = localizedReason;
    if (failure != null) throw failure!;
    return result;
  }

  @override
  Future<bool> stopAuthentication() async {
    cancellations++;
    if (failure != null) throw failure!;
    return true;
  }
}

void main() {
  group('platform verification adapter, all native calls mocked', () {
    for (final platform in TargetPlatform.values) {
      test(
        '$platform support is explicitly limited to Android and Windows',
        () async {
          final plugin = FakeLocalAuthentication();
          final adapter = PlatformLocalUnlockAuthenticator(
            localAuthentication: plugin,
            platform: platform,
            isWeb: false,
          );
          final expected =
              platform == TargetPlatform.android ||
              platform == TargetPlatform.windows;
          expect(adapter.supported, expected);
          expect(await adapter.isAvailable(), expected);
          expect(
            await adapter.authenticate(),
            expected
                ? LocalUnlockResult.verified
                : LocalUnlockResult.unavailable,
          );
          expect(plugin.prompts, expected ? 1 : 0);
        },
      );
    }

    test(
      'Web cannot call native verification even with Android platform hint',
      () async {
        final plugin = FakeLocalAuthentication();
        final adapter = PlatformLocalUnlockAuthenticator(
          localAuthentication: plugin,
          platform: TargetPlatform.android,
          isWeb: true,
        );
        expect(adapter.supported, isFalse);
        expect(await adapter.isAvailable(), isFalse);
        expect(await adapter.authenticate(), LocalUnlockResult.unavailable);
        await adapter.cancel();
        expect(plugin.checks + plugin.prompts + plugin.cancellations, 0);
      },
    );

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      test(
        '$platform permits device credentials and disables background retry',
        () async {
          final plugin = FakeLocalAuthentication();
          final adapter = PlatformLocalUnlockAuthenticator(
            localAuthentication: plugin,
            platform: platform,
            isWeb: false,
          );
          expect(await adapter.authenticate(), LocalUnlockResult.verified);
          expect(plugin.biometricOnlyUsed, isFalse);
          expect(plugin.persistUsed, isFalse);
          expect(plugin.sensitiveUsed, isTrue);
          expect(plugin.reason, isNotEmpty);
        },
      );
    }

    final cases = {
      LocalAuthExceptionCode.userCanceled: LocalUnlockResult.canceled,
      LocalAuthExceptionCode.systemCanceled: LocalUnlockResult.canceled,
      LocalAuthExceptionCode.userRequestedFallback: LocalUnlockResult.canceled,
      LocalAuthExceptionCode.timeout: LocalUnlockResult.canceled,
      LocalAuthExceptionCode.temporaryLockout: LocalUnlockResult.lockedOut,
      LocalAuthExceptionCode.biometricLockout: LocalUnlockResult.lockedOut,
      LocalAuthExceptionCode.noCredentialsSet: LocalUnlockResult.unavailable,
      LocalAuthExceptionCode.noBiometricsEnrolled:
          LocalUnlockResult.unavailable,
      LocalAuthExceptionCode.noBiometricHardware: LocalUnlockResult.unavailable,
      LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable:
          LocalUnlockResult.unavailable,
      LocalAuthExceptionCode.uiUnavailable: LocalUnlockResult.unavailable,
      LocalAuthExceptionCode.authInProgress: LocalUnlockResult.failed,
      LocalAuthExceptionCode.deviceError: LocalUnlockResult.failed,
      LocalAuthExceptionCode.unknownError: LocalUnlockResult.failed,
    };
    for (final entry in cases.entries) {
      test('maps ${entry.key} without exposing OS error details', () async {
        final plugin = FakeLocalAuthentication()
          ..failure = LocalAuthException(code: entry.key);
        final adapter = PlatformLocalUnlockAuthenticator(
          localAuthentication: plugin,
          platform: TargetPlatform.windows,
          isWeb: false,
        );
        expect(await adapter.authenticate(), entry.value);
        expect(await adapter.isAvailable(), isFalse);
        await adapter.cancel();
      });
    }

    test(
      'unknown errors and false verification never become success',
      () async {
        final plugin = FakeLocalAuthentication()..result = false;
        final adapter = PlatformLocalUnlockAuthenticator(
          localAuthentication: plugin,
          platform: TargetPlatform.android,
          isWeb: false,
        );
        expect(await adapter.authenticate(), LocalUnlockResult.canceled);
        plugin.failure = StateError('synthetic failure');
        expect(await adapter.authenticate(), LocalUnlockResult.failed);
      },
    );
  });

  group('memory-only session controller', () {
    late FakeUnlockAuthenticator auth;
    late LocalUnlockController controller;
    setUp(() {
      auth = FakeUnlockAuthenticator();
      controller = LocalUnlockController(authenticator: auth);
    });
    tearDown(() => controller.dispose());

    test('cannot enable or unlock without authenticated session', () async {
      expect(controller.enabled, isFalse);
      expect(await controller.enable(), isFalse);
      expect(await controller.unlock(), isFalse);
      expect(auth.checks + auth.prompts, 0);
    });

    test(
      'unsupported or unconfigured device keeps explicit login available',
      () async {
        controller.attachSession(Object());
        auth.supported = false;
        expect(await controller.enable(), isFalse);
        expect(controller.enabled, isFalse);
        expect(controller.message, contains('暂不支持'));
        auth.supported = true;
        auth.available = false;
        expect(await controller.enable(), isFalse);
        expect(controller.enabled, isFalse);
        expect(controller.locked, isFalse);
        expect(controller.message, contains('系统验证不可用'));
        expect(auth.prompts, 0);
      },
    );

    test('opt-in, manual lock, verification and explicit disable', () async {
      controller.attachSession(Object());
      expect(await controller.enable(), isTrue);
      expect(controller.enabled, isTrue);
      expect(controller.locked, isFalse);
      controller.lock();
      expect(controller.locked, isTrue);
      expect(controller.disable(), isFalse);
      expect(await controller.unlock(), isTrue);
      expect(controller.locked, isFalse);
      expect(controller.disable(), isTrue);
      controller.lock();
      expect(controller.locked, isFalse);
    });

    for (final result in LocalUnlockResult.values.where(
      (result) => result != LocalUnlockResult.verified,
    )) {
      test('failed opt-in ($result) keeps current session shielded', () async {
        controller.attachSession(Object());
        auth.result = result;
        expect(await controller.enable(), isFalse);
        expect(controller.enabled, isTrue);
        expect(controller.locked, isTrue);
        expect(controller.message, isNotEmpty);
        expect(controller.disable(), isFalse);
        auth.result = LocalUnlockResult.verified;
        expect(await controller.unlock(), isTrue);
      });
    }

    test('duplicate attempts cannot open duplicate native prompts', () async {
      controller.attachSession(Object());
      auth.pending = Completer<LocalUnlockResult>();
      final enable = controller.enable();
      await Future<void>.delayed(Duration.zero);
      expect(controller.locked, isTrue);
      expect(controller.busy, isTrue);
      expect(await controller.enable(), isFalse);
      expect(await controller.unlock(), isFalse);
      expect(auth.prompts, 1);
      auth.pending!.complete(LocalUnlockResult.verified);
      expect(await enable, isTrue);
      expect(controller.busy, isFalse);
    });

    test('inactive dialog then resumed before success unlocks once', () async {
      controller.attachSession(Object());
      auth.pending = Completer<LocalUnlockResult>();
      final attempt = controller.enable();
      await Future<void>.delayed(Duration.zero);
      controller.handleLifecycleState(AppLifecycleState.inactive);
      expect(controller.locked, isTrue);
      expect(auth.cancellations, 0);
      controller.handleLifecycleState(AppLifecycleState.resumed);
      expect(controller.locked, isTrue);
      auth.pending!.complete(LocalUnlockResult.verified);
      expect(await attempt, isTrue);
      expect(controller.locked, isFalse);
      expect(auth.prompts, 1);
    });

    test('success while native dialog inactive waits for resume', () async {
      controller.attachSession(Object());
      auth.pending = Completer<LocalUnlockResult>();
      final attempt = controller.enable();
      await Future<void>.delayed(Duration.zero);
      controller.handleLifecycleState(AppLifecycleState.inactive);
      auth.pending!.complete(LocalUnlockResult.verified);
      expect(await attempt, isTrue);
      expect(controller.locked, isTrue);
      controller.handleLifecycleState(AppLifecycleState.resumed);
      expect(controller.locked, isFalse);
      expect(auth.prompts, 1);
    });

    for (final background in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      test(
        '$background invalidates late native success and does not auto-retry',
        () async {
          controller.attachSession(Object());
          await controller.enable();
          controller.lock();
          auth.pending = Completer<LocalUnlockResult>();
          final attempt = controller.unlock();
          controller.handleLifecycleState(background);
          controller.handleLifecycleState(AppLifecycleState.resumed);
          auth.pending!.complete(LocalUnlockResult.verified);
          expect(await attempt, isFalse);
          expect(controller.locked, isTrue);
          expect(auth.cancellations, greaterThan(0));
          expect(auth.prompts, 2);
        },
      );
    }

    test('real background discards verified-but-not-resumed grant', () async {
      controller.attachSession(Object());
      auth.pending = Completer<LocalUnlockResult>();
      final attempt = controller.enable();
      await Future<void>.delayed(Duration.zero);
      controller.handleLifecycleState(AppLifecycleState.inactive);
      auth.pending!.complete(LocalUnlockResult.verified);
      await attempt;
      controller.handleLifecycleState(AppLifecycleState.hidden);
      controller.handleLifecycleState(AppLifecycleState.resumed);
      expect(controller.locked, isTrue);
    });

    test('normal loss of focus locks without prompting on reopen', () async {
      controller.attachSession(Object());
      await controller.enable();
      controller.handleLifecycleState(AppLifecycleState.inactive);
      expect(controller.locked, isTrue);
      controller.handleLifecycleState(AppLifecycleState.resumed);
      expect(controller.locked, isTrue);
      expect(auth.prompts, 1);
    });

    for (final change in ['logout', 'new session', 'manual lock', 'dispose']) {
      test('$change invalidates pending native result', () async {
        controller.attachSession(Object());
        await controller.enable();
        controller.lock();
        auth.pending = Completer<LocalUnlockResult>();
        final attempt = controller.unlock();
        switch (change) {
          case 'logout':
            controller.attachSession(null);
          case 'new session':
            controller.attachSession(Object());
          case 'manual lock':
            controller.lock();
          case 'dispose':
            controller.dispose();
        }
        auth.pending!.complete(LocalUnlockResult.verified);
        expect(await attempt, isFalse);
        expect(auth.cancellations, greaterThan(0));
        if (change == 'manual lock') expect(controller.locked, isTrue);
        if (change == 'logout' || change == 'new session') {
          expect(controller.enabled, isFalse);
          expect(controller.locked, isFalse);
        }
      });
    }

    test(
      'session replacement during capability probe cannot lock new session',
      () async {
        controller.attachSession(Object());
        auth.capability = Completer<bool>();
        final attempt = controller.enable();
        controller.attachSession(Object());
        auth.capability!.complete(true);
        expect(await attempt, isFalse);
        expect(controller.enabled, isFalse);
        expect(auth.prompts, 0);
      },
    );

    test(
      'slow platform cancellation cannot race with a newer prompt',
      () async {
        controller.attachSession(Object());
        await controller.enable();
        controller.lock();
        auth.pending = Completer<LocalUnlockResult>();
        auth.cancellation = Completer<void>();
        final attempt = controller.unlock();
        controller.lock();
        auth.pending!.complete(LocalUnlockResult.verified);
        expect(await attempt, isFalse);
        expect(controller.busy, isTrue);
        expect(await controller.unlock(), isFalse);
        expect(auth.prompts, 2);
        auth.cancellation!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(controller.busy, isFalse);
        auth.pending = null;
        expect(await controller.unlock(), isTrue);
        expect(auth.prompts, 3);
      },
    );

    test('unexpected injected error fails closed', () async {
      controller.attachSession(Object());
      auth.failure = StateError('synthetic error');
      expect(await controller.enable(), isFalse);
      expect(controller.locked, isTrue);
      expect(controller.busy, isFalse);
      expect(controller.message, contains('系统验证未完成'));
    });

    test(
      'same session attachment preserves lock and opt-in; logout clears both',
      () async {
        final session = Object();
        controller.attachSession(session);
        await controller.enable();
        controller.lock();
        controller.attachSession(session);
        expect(controller.locked, isTrue);
        controller.attachSession(null);
        expect(controller.hasSession, isFalse);
        expect(controller.enabled, isFalse);
        expect(controller.locked, isFalse);
      },
    );
  });

  testWidgets(
    'gate preserves editor but excludes rendering, input and semantics',
    (tester) async {
      final auth = FakeUnlockAuthenticator();
      final controller = LocalUnlockController(authenticator: auth)
        ..attachSession(Object());
      final editor = TextEditingController();
      final focus = FocusNode();
      var shortcuts = 0;
      final semantics = tester.ensureSemantics();
      addTearDown(controller.dispose);
      addTearDown(editor.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, navigator) => LocalUnlockGate(
            controller: controller,
            onSignOut: () {},
            child: navigator!,
          ),
          home: Scaffold(
            body: CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.keyN,
                  control: true,
                ): () =>
                    shortcuts++,
              },
              child: TextField(
                controller: editor,
                focusNode: focus,
                decoration: const InputDecoration(labelText: 'Private draft'),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Unsaved synthetic text');
      await controller.enable();
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      final originalState = tester.state(find.byType(EditableText));
      controller.lock();
      await tester.pumpAndSettle();
      expect(find.text('泊信已锁定'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.bySemanticsLabel('Private draft'), findsNothing);
      expect(focus.hasFocus, isFalse);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(shortcuts, 0);
      expect(editor.text, 'Unsaved synthetic text');
      await tester.tap(find.byKey(const ValueKey('local-unlock-retry')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.state(find.byType(EditableText)), same(originalState));
      expect(editor.text, 'Unsaved synthetic text');
      semantics.dispose();
    },
  );

  testWidgets('gate outside Navigator hides existing modal and preserves it', (
    tester,
  ) async {
    final controller = LocalUnlockController(
      authenticator: FakeUnlockAuthenticator(),
    )..attachSession(Object());
    addTearDown(controller.dispose);
    var privateActions = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, navigator) => LocalUnlockGate(
          controller: controller,
          onSignOut: () {},
          child: navigator!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Private mail content'),
                    actions: [
                      TextButton(
                        onPressed: () => privateActions++,
                        child: const Text('Private action'),
                      ),
                    ],
                  ),
                ),
                child: const Text('Open private dialog'),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open private dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Private mail content'), findsOneWidget);
    await controller.enable();
    controller.lock();
    await tester.pumpAndSettle();
    expect(find.text('Private mail content'), findsNothing);
    expect(find.text('Private action').hitTestable(), findsNothing);
    expect(privateActions, 0);
    await tester.tap(find.byKey(const ValueKey('local-unlock-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Private mail content'), findsOneWidget);
  });

  testWidgets(
    'sign out uses explicit inline discard confirmation outside gate',
    (tester) async {
      final controller = LocalUnlockController(
        authenticator: FakeUnlockAuthenticator(),
      )..attachSession(Object());
      addTearDown(controller.dispose);
      var signOuts = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, navigator) => LocalUnlockGate(
            controller: controller,
            onSignOut: () => signOuts++,
            child: navigator!,
          ),
          home: const Scaffold(body: Text('Private editor')),
        ),
      );
      await controller.enable();
      controller.lock();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-unlock-signout')));
      await tester.pumpAndSettle();
      expect(signOuts, 0);
      expect(find.textContaining('退出会丢弃尚未保存的编辑'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-unlock-stay')));
      await tester.pumpAndSettle();
      expect(controller.locked, isTrue);
      expect(signOuts, 0);
      await tester.tap(find.byKey(const ValueKey('local-unlock-signout')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local-unlock-confirm-signout')),
      );
      await tester.pumpAndSettle();
      expect(signOuts, 1);
    },
  );

  testWidgets('lifecycle locks gate and canceled retry remains retryable', (
    tester,
  ) async {
    final auth = FakeUnlockAuthenticator();
    final controller = LocalUnlockController(authenticator: auth)
      ..attachSession(Object());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, navigator) => LocalUnlockGate(
          controller: controller,
          onSignOut: () {},
          child: navigator!,
        ),
        home: const Scaffold(body: Text('Private editor')),
      ),
    );
    await controller.enable();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(controller.locked, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    auth.result = LocalUnlockResult.canceled;
    await tester.tap(find.byKey(const ValueKey('local-unlock-retry')));
    await tester.pumpAndSettle();
    expect(controller.locked, isTrue);
    expect(find.textContaining('已取消验证'), findsOneWidget);
    expect(auth.prompts, 2);
    auth.result = LocalUnlockResult.verified;
    await tester.tap(find.byKey(const ValueKey('local-unlock-retry')));
    await tester.pumpAndSettle();
    expect(controller.locked, isFalse);
    expect(find.text('Private editor'), findsOneWidget);
  });
}
