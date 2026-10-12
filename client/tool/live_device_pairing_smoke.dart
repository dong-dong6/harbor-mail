// Explicitly synthetic loopback-only contract smoke. Never use real credentials.
import 'dart:convert';
import 'dart:io';

import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/device_pairing_api.dart';
import 'package:harbor_mail/server_profile.dart';

Future<void> main(List<String> args) async {
  final profile = ServerProfile.parse(
    args.single,
    allowLoopbackHttp: true,
  );
  final uri = Uri.parse(profile.apiBase);
  if (!{'127.0.0.1', 'localhost', '::1'}.contains(uri.host)) {
    throw StateError('Synthetic smoke only permits an explicit loopback host');
  }
  final owner = MailApi(base: profile.apiBase);
  final app = DevicePairingApi(profile: profile);
  DevicePairingResult? device;
  try {
    final health = await owner.request('GET', '/health');
    if (health is! Map || health['demoMode'] != true) {
      throw StateError('Refusing non-demo server before login or mutation');
    }
    await owner.login('demo', 'demo-local-only');
    final created =
        await owner.request('POST', '/auth/device-pairings', body: {});
    final qr = PairingQr.parse(created['qrPayload'], allowLoopbackHttp: true);
    if (qr.profile != profile) {
      throw StateError('Demo QR unexpectedly selected a different server');
    }
    final claimed =
        await app.claim(qr, deviceName: 'Synthetic contract device');
    if (claimed.permission != 'OWNER_FULL_ACCESS') {
      throw StateError('Scope mismatch');
    }
    final observed =
        await owner.request('GET', '/auth/device-pairings/${qr.pairingId}');
    if (observed['confirmationCode'] != claimed.confirmationCode) {
      throw StateError('Web/app confirmation code mismatch');
    }
    await owner.request('POST', '/auth/device-pairings/${qr.pairingId}/approve',
        body: {
          'password': 'demo-local-only',
          'confirmationCode': claimed.confirmationCode
        });
    final approved = await app.poll();
    if (approved.state != PairingState.approved) {
      throw StateError('Approval missing');
    }
    device = await app.redeem();
    if (device.accessToken == owner.token) {
      throw StateError('Browser token was copied');
    }
    final accounts = await device.api.request('GET', '/accounts');
    if (accounts is! Map || accounts['items'] is! List) {
      throw StateError('Paired device cannot read synthetic accounts');
    }
    final devices = await owner.request('GET', '/auth/devices');
    if (!(devices['items'] as List).any((d) => d['id'] == device!.deviceId)) {
      throw StateError('Device is not listed');
    }
    await owner.request('DELETE', '/auth/devices/${device.deviceId}');
    var revoked = false;
    try {
      await device.api.request('GET', '/accounts');
    } on ApiException catch (e) {
      revoked = e.code == 'UNAUTHORIZED';
    }
    if (!revoked) throw StateError('Revoked device still has access');
    stdout.writeln(jsonEncode({
      'result': 'passed',
      'checks': [
        'qr_profile',
        'S256_claim',
        'matching_codes',
        'owner_password_approval',
        'independent_session',
        'account_access',
        'device_listing',
        'immediate_revocation'
      ],
      'syntheticOnly': true,
    }));
  } finally {
    device?.api.dispose();
    app.dispose();
    if (owner.token != null) {
      try {
        await owner.request('POST', '/auth/logout');
      } catch (_) {}
    }
    owner.dispose();
  }
}
