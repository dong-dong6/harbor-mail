import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef LoadDeviceName = Future<String> Function();

const fallbackDeviceName = '我的设备';

/// A display label only, never a stable identifier or proof of device identity.
/// Limits UTF-16 length to match the API without splitting surrogate pairs.
String sanitizeDeviceName(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ')
      .replaceAll(
        RegExp(r'[\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]'),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return fallbackDeviceName;
  final result = StringBuffer();
  var length = 0;
  for (final rune in cleaned.runes) {
    final width = rune > 0xffff ? 2 : 1;
    if (length + width > 80) break;
    result.writeCharCode(rune);
    length += width;
  }
  return result.toString().trimRight();
}

/// Android exposes just Build.MANUFACTURER and Build.MODEL. This requires no
/// permission and never reads a serial, Android ID, account or advertising ID.
/// Unsupported platforms and unavailable metadata keep a generic editable name.
class PlatformDeviceInfo {
  PlatformDeviceInfo({
    MethodChannel? channel,
    TargetPlatform? platform,
    bool? isWeb,
  }) : _channel = channel ?? const MethodChannel('dev.harbor.mail/device_info'),
       _platform = platform ?? defaultTargetPlatform,
       _isWeb = isWeb ?? kIsWeb;

  final MethodChannel _channel;
  final TargetPlatform _platform;
  final bool _isWeb;

  Future<String> suggestedName() async {
    if (_isWeb || _platform != TargetPlatform.android) {
      return fallbackDeviceName;
    }
    try {
      final info = await _channel.invokeMapMethod<Object?, Object?>(
        'modelInfo',
      );
      final model = _component(info?['model']);
      final manufacturer = _component(info?['manufacturer']);
      if (model.isEmpty) return fallbackDeviceName;
      final label =
          manufacturer.isEmpty ||
              model.toLowerCase().startsWith(manufacturer.toLowerCase())
          ? model
          : '$manufacturer $model';
      return sanitizeDeviceName(label);
    } catch (_) {
      return fallbackDeviceName;
    }
  }

  String _component(Object? value) {
    if (value is! String || value.trim().isEmpty) return '';
    final label = sanitizeDeviceName(value);
    if (label == fallbackDeviceName ||
        const ['unknown', 'null', 'n/a'].contains(label.toLowerCase())) {
      return '';
    }
    return label;
  }
}
