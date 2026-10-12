import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/device_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.harbor.mail/device_info');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  Object? response;
  Object? failure;

  setUp(() {
    calls = [];
    response = {'manufacturer': 'Google', 'model': 'Pixel 9 Pro'};
    failure = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (failure != null) throw failure!;
      return response;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  PlatformDeviceInfo android() => PlatformDeviceInfo(
    channel: channel,
    platform: TargetPlatform.android,
    isWeb: false,
  );

  test(
    'Android uses only the manufacturer/model method without arguments',
    () async {
      expect(await android().suggestedName(), 'Google Pixel 9 Pro');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'modelInfo');
      expect(calls.single.arguments, isNull);
    },
  );

  test('model already containing manufacturer is not duplicated', () async {
    response = {'manufacturer': 'samsung', 'model': 'Samsung Galaxy S25'};
    expect(await android().suggestedName(), 'Samsung Galaxy S25');
  });

  test('missing manufacturer preserves a real model', () async {
    response = {'manufacturer': null, 'model': 'SM-S931B'};
    expect(await android().suggestedName(), 'SM-S931B');
  });

  for (final value in [
    null,
    {'manufacturer': 'Acme'},
    {'manufacturer': 'Acme', 'model': 'unknown'},
    {'manufacturer': 'Acme', 'model': '\u0000\n\u202e'},
    {'manufacturer': 'Acme', 'model': 123},
    ['invalid'],
  ]) {
    test('missing or malformed model uses a generic name: $value', () async {
      response = value;
      expect(await android().suggestedName(), fallbackDeviceName);
    });
  }

  for (final error in [
    MissingPluginException(),
    PlatformException(code: 'unavailable'),
  ]) {
    test('native failure returns generic fallback: $error', () async {
      failure = error;
      expect(await android().suggestedName(), fallbackDeviceName);
    });
  }

  test('Web and unsupported platforms never call native metadata', () async {
    for (final platform in TargetPlatform.values) {
      expect(
        await PlatformDeviceInfo(
          channel: channel,
          platform: platform,
          isWeb: true,
        ).suggestedName(),
        fallbackDeviceName,
      );
      if (platform != TargetPlatform.android) {
        expect(
          await PlatformDeviceInfo(
            channel: channel,
            platform: platform,
            isWeb: false,
          ).suggestedName(),
          fallbackDeviceName,
        );
      }
    }
    expect(calls, isEmpty);
  });

  test('metadata is sanitized and limited to 80 UTF-16 code units', () async {
    response = {
      'manufacturer': ' Google\n',
      'model': '\u202ePixel\u200b \t9 ${'X' * 100}',
    };
    final name = await android().suggestedName();
    expect(name, startsWith('Google Pixel 9 '));
    expect(name.length, 80);
    expect(name.contains(RegExp(r'[\x00-\x1f\x7f-\x9f\u202e\u200b]')), isFalse);
    expect(sanitizeDeviceName('😀' * 41), '😀' * 40);
    expect(sanitizeDeviceName('${'x' * 79}😀'), 'x' * 79);
    expect(sanitizeDeviceName('  \n\u202e '), fallbackDeviceName);
  });
}
