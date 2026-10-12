import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_profile.dart';

/// Narrow injectable store: no API accepts passwords, tokens or pairing data.
abstract interface class ProfilePreferences {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class SharedProfilePreferences implements ProfilePreferences {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) {
      throw StateError('Could not save server profile');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (!await (await SharedPreferences.getInstance()).remove(key)) {
      throw StateError('Could not clear server profile');
    }
  }
}

class SavedServerProfile {
  const SavedServerProfile({required this.profile, required this.accountLabel});
  final ServerProfile profile;
  final String accountLabel;
}

/// Optional native-only convenience. Browser API selection remains same-origin.
/// Only canonical HTTPS server URL and account label are saved; every launch
/// still needs password, passkey, or explicitly approved device pairing.
class ServerProfileStore {
  ServerProfileStore({ProfilePreferences? preferences, bool? isWeb})
    : _preferences = preferences ?? SharedProfilePreferences(),
      _isWeb = isWeb ?? kIsWeb;
  final ProfilePreferences _preferences;
  final bool _isWeb;
  static const preferenceKey = 'harbor_mail.server_profile.v1';

  Future<SavedServerProfile?> load() async {
    if (_isWeb) return null;
    try {
      final raw = await _preferences.read(preferenceKey);
      if (raw == null || raw.length > 4096) return null;
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic> ||
          data.length != 3 ||
          data['version'] != 1 ||
          data['apiBase'] is! String ||
          !_validLabel(data['accountLabel'])) {
        return null;
      }
      return SavedServerProfile(
        profile: ServerProfile.parse(data['apiBase']),
        accountLabel: data['accountLabel'],
      );
    } catch (_) {
      // Corrupt/unavailable preferences never prevent password login.
      return null;
    }
  }

  Future<void> save(
    ServerProfile profile, {
    required String accountLabel,
  }) async {
    if (_isWeb) return;
    if (!_validLabel(accountLabel)) {
      throw const FormatException('Invalid account label');
    }
    // Re-parse without development HTTP opt-in before persisting.
    final canonical = ServerProfile.parse(profile.apiBase);
    await _preferences.write(
      preferenceKey,
      jsonEncode({
        'version': 1,
        'apiBase': canonical.apiBase,
        'accountLabel': accountLabel,
      }),
    );
  }

  Future<void> clear() async {
    if (!_isWeb) await _preferences.remove(preferenceKey);
  }

  static bool _validLabel(dynamic value) =>
      value is String &&
      value.length <= 320 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
}
