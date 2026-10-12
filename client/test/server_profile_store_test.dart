import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:harbor_mail/server_profile_store.dart';

class MemoryPreferences implements ProfilePreferences {
  final data = <String, String>{};
  int reads = 0, writes = 0, removals = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    removals++;
    data.remove(key);
  }
}

void main() {
  test(
    'native profile persists only canonical URL and account label',
    () async {
      final backend = MemoryPreferences();
      final store = ServerProfileStore(preferences: backend, isWeb: false);
      await store.save(
        ServerProfile.parse('https://MAIL.example.test:443/api/v1'),
        accountLabel: 'Owner',
      );
      expect(jsonDecode(backend.data.values.single), {
        'version': 1,
        'apiBase': 'https://mail.example.test/api/v1',
        'accountLabel': 'Owner',
      });
      final saved = await store.load();
      expect(saved!.accountLabel, 'Owner');
      expect(saved.profile.apiBase, 'https://mail.example.test/api/v1');
      await store.clear();
      expect(await store.load(), isNull);
    },
  );

  test(
    'web never reads writes or deletes preferences and stays same-origin',
    () async {
      final backend = MemoryPreferences();
      final store = ServerProfileStore(preferences: backend, isWeb: true);
      await store.save(
        ServerProfile.parse('https://mail.example.test/api/v1'),
        accountLabel: 'Owner',
      );
      expect(await store.load(), isNull);
      await store.clear();
      expect([backend.reads, backend.writes, backend.removals], [0, 0, 0]);
    },
  );

  test(
    'rejects invalid stored profile and secret-bearing extra fields',
    () async {
      final backend = MemoryPreferences();
      final store = ServerProfileStore(preferences: backend, isWeb: false);
      for (final value in [
        '{broken',
        jsonEncode({
          'version': 1,
          'apiBase': 'http://localhost/api/v1',
          'accountLabel': 'Owner',
        }),
        jsonEncode({
          'version': 1,
          'apiBase': 'https://mail.test/api/v1',
          'accountLabel': 'Owner',
          'token': 'secret',
        }),
        jsonEncode({
          'version': 1,
          'apiBase': 'https://mail.test/api/v1',
          'accountLabel': 'Owner\nadmin',
        }),
      ]) {
        backend.data[ServerProfileStore.preferenceKey] = value;
        expect(await store.load(), isNull);
      }
    },
  );

  test('loopback development profile is never persisted', () async {
    final backend = MemoryPreferences();
    final store = ServerProfileStore(preferences: backend, isWeb: false);
    await expectLater(
      store.save(
        ServerProfile.parse('http://localhost/api/v1', allowLoopbackHttp: true),
        accountLabel: 'Owner',
      ),
      throwsFormatException,
    );
    expect(backend.writes, 0);
  });
}
