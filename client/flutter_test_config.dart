import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests have no Android engine. Default vault fixture is empty and
/// cannot authenticate/save anything; vault-specific tests replace this handler.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('dev.harbor.mail/session_vault'),
    (call) async => <String, Object>{
      'status': switch (call.method) {
        'status' || 'clear' => 'empty',
        'cancel' => 'canceled',
        _ => 'unavailable',
      },
    },
  );
  await testMain();
}
