import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/device_pairing_api.dart';
import 'package:harbor_mail/main.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('pairing transfers only the fresh server session into mailbox',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = MailApi(
        base: 'https://old.example/api/v1',
        client:
            MockClient((_) async => throw StateError('Old server contacted')))
      ..token = 'synthetic-old-token';
    final requests = <http.Request>[];
    final paired = MailApi(
        base: 'https://new.example/api/v1',
        client: MockClient((req) async {
          requests.add(req);
          final data = req.url.path.endsWith('/settings/capabilities')
              ? {'demoMode': true, 'features': <String, dynamic>{}}
              : {'items': [], 'hasMore': false, 'coverage': 'DEMO'};
          return http.Response(jsonEncode(data), 200,
              headers: {'content-type': 'application/json'});
        }))
      ..token = 'synthetic-new-token';
    await tester.pumpWidget(MailApp(api: original));
    final state = tester.state<MailboxState>(find.byType(Mailbox));
    state.pairingOpen = true;
    final connected = state.acceptPairedDevice(
      ServerProfile.parse('https://new.example/api/v1'),
      DevicePairingResult(
        api: paired,
        profile: ServerProfile.parse('https://new.example/api/v1'),
        expiresAt: DateTime.now().add(const Duration(hours: 8)),
        deviceId: 'synthetic-device',
        accountName: 'owner',
        permission: 'OWNER_FULL_ACCESS',
      ),
    );
    await tester.pumpAndSettle();
    await connected;
    expect(state.logged, isTrue);
    expect(state.api, same(paired));
    expect(state.serverAddress.text, 'https://new.example/api/v1');
    expect(state.username.text, 'owner');
    expect(original.token, isNull);
    expect(requests, isNotEmpty);
    expect(requests.every((r) => r.url.host == 'new.example'), isTrue);
    expect(
        requests.every(
            (r) => r.headers['Authorization'] == 'Bearer synthetic-new-token'),
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelled onboarding cannot accept a late authenticated result',
      (tester) async {
    final original = MailApi(
        base: 'https://old.example/api/v1',
        client: MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(MailApp(api: original));
    final state = tester.state<MailboxState>(find.byType(Mailbox));
    final paired = MailApi(base: 'https://new.example/api/v1')
      ..token = 'synthetic-discarded-token';
    await state.acceptPairedDevice(
      ServerProfile.parse('https://new.example/api/v1'),
      DevicePairingResult(
        api: paired,
        profile: ServerProfile.parse('https://new.example/api/v1'),
        expiresAt: DateTime.now().add(const Duration(hours: 8)),
        deviceId: 'synthetic-device',
        accountName: 'owner',
        permission: 'OWNER_FULL_ACCESS',
      ),
    );
    expect(state.logged, isFalse);
    expect(state.api, same(original));
    expect(paired.token, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
