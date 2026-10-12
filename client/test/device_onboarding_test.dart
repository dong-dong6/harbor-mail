import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/device_onboarding.dart';
import 'package:harbor_mail/device_pairing_api.dart';
import 'package:harbor_mail/server_profile.dart';
import 'package:http/testing.dart';

const id = 'synthetic-pairing-0001';
String qr({String server = 'https://mail.invalid/api/v1'}) => jsonEncode({
      'type': 'harbor-mail-device-pairing',
      'version': 1,
      'serverUrl': server,
      'pairingId': id,
      'secret': 'synthetic-secret-never-display-000000000000000',
    });

PairingSnapshot snapshot(PairingState state) => PairingSnapshot(
      pairingId: id,
      state: state,
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      accountName: 'synthetic-owner',
      permission: 'OWNER_FULL_ACCESS',
      confirmationCode: '123456',
    );

class FakePairingApi extends DevicePairingApi {
  FakePairingApi(ServerProfile profile)
      : super(
            profile: profile,
            client: MockClient((_) => throw StateError('Unexpected network')));
  int claims = 0, polls = 0, redemptions = 0, cancellations = 0;
  Future<PairingSnapshot> Function()? onClaim;
  Future<PairingSnapshot> Function()? onPoll;
  Future<DevicePairingResult> Function()? onRedeem;
  String? claimedName;

  @override
  Future<PairingSnapshot> claim(PairingQr qr,
      {required String deviceName}) async {
    claims++;
    claimedName = deviceName;
    return onClaim?.call() ?? snapshot(PairingState.claimed);
  }

  @override
  Future<PairingSnapshot> poll() async {
    polls++;
    return onPoll?.call() ?? snapshot(PairingState.claimed);
  }

  @override
  Future<DevicePairingResult> redeem() async {
    redemptions++;
    if (onRedeem != null) return onRedeem!();
    return result();
  }

  DevicePairingResult result() => DevicePairingResult(
        api: MailApi(base: profile.apiBase)..token = 'synthetic-device-token',
        profile: profile,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        deviceId: 'synthetic-device-1',
        accountName: 'synthetic-owner',
        permission: 'OWNER_FULL_ACCESS',
      );

  @override
  void cancel() {
    cancellations++;
    super.cancel();
  }
}

Future<void> showOnboarding(WidgetTester tester,
    {PairingApiFactory? factory,
    ScanPairingCode? scan,
    void Function(ServerProfile, DevicePairingResult)? onConnected,
    VoidCallback? onClose,
    bool allowLoopbackHttp = false,
    Size size = const Size(1000, 1200)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      home: DeviceOnboardingPage(
    apiFactory: factory,
    scanPairingCode: scan,
    allowLoopbackHttp: allowLoopbackHttp,
    onConnected: onConnected ?? (_, result) => result.api.dispose(),
    onClose: onClose ?? () {},
  )));
  await tester.pump();
}

Future<void> tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
}

Future<void> review(WidgetTester tester, [String? value]) async {
  await tester.enterText(find.byKey(const Key('pairing-paste')), value ?? qr());
  await tap(tester, 'pairing-review-paste');
}

Future<void> claim(WidgetTester tester) async {
  await review(tester);
  await tap(tester, 'pairing-confirm-destination');
}

void main() {
  testWidgets(
      'QR parsing only shows destination and sends nothing before confirmation',
      (tester) async {
    var constructed = 0;
    late FakePairingApi api;
    await showOnboarding(tester, factory: (profile) {
      constructed++;
      return api = FakePairingApi(profile);
    });
    await review(tester);
    expect(find.text('https://mail.invalid'), findsOneWidget);
    expect(find.textContaining('全部邮箱和设置'), findsOneWidget);
    expect(find.textContaining('synthetic-owner'), findsNothing);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    expect(constructed, 0);
    await tester.enterText(
        find.byKey(const Key('pairing-device-name')), '合成测试手机');
    await tap(tester, 'pairing-confirm-destination');
    expect(api.claims, 1);
    expect(api.claimedName, '合成测试手机');
    expect(find.text('123456'), findsOneWidget);
    expect(find.text('账户：synthetic-owner'), findsOneWidget);
    expect(api.polls, 0);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(api.polls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(api.polls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'APPROVED automatically redeems once and transfers a runtime profile',
      (tester) async {
    late FakePairingApi api;
    DevicePairingResult? connected;
    ServerProfile? destination;
    await showOnboarding(tester,
        factory: (profile) => api = FakePairingApi(profile)
          ..onPoll = () async => snapshot(PairingState.approved),
        onConnected: (profile, result) {
          destination = profile;
          connected = result;
        });
    await claim(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(api.redemptions, 1);
    expect(connected?.api.token, 'synthetic-device-token');
    expect(destination?.apiBase, 'https://mail.invalid/api/v1');
    await tester.pump(const Duration(seconds: 10));
    expect(api.redemptions, 1);
    connected!.api.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'invalid and plaintext HTTP QR are rejected without contacting a server',
      (tester) async {
    var constructed = 0;
    await showOnboarding(tester, factory: (profile) {
      constructed++;
      return FakePairingApi(profile);
    });
    for (final invalid in [
      'not-json',
      qr(server: 'http://mail.invalid/api/v1'),
      qr(server: 'http://localhost/api/v1')
    ]) {
      await review(tester, invalid);
      expect(find.textContaining('二维码无效'), findsOneWidget);
      expect(
          find.byKey(const Key('pairing-confirm-destination')), findsNothing);
    }
    expect(constructed, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('loopback HTTP needs explicit demo-only option', (tester) async {
    await showOnboarding(tester, allowLoopbackHttp: true);
    await review(tester, qr(server: 'http://localhost:8080/api/v1'));
    expect(find.text('http://localhost:8080'), findsOneWidget);
    expect(find.textContaining('仅限明确启用'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scanner cancellation leaves paste fallback and no request',
      (tester) async {
    var scans = 0;
    await showOnboarding(tester, scan: () async {
      scans++;
      return null;
    });
    await tap(tester, 'pairing-scan');
    expect(scans, 1);
    expect(find.byKey(const Key('pairing-paste')), findsOneWidget);
    expect(find.byKey(const Key('pairing-server-origin')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scanner late result after close cannot open a destination',
      (tester) async {
    final scan = Completer<String?>();
    var closed = 0;
    await showOnboarding(tester,
        scan: () => scan.future, onClose: () => closed++);
    await tap(tester, 'pairing-scan');
    await tester.tap(find.byTooltip('取消设备连接'));
    await tester.pump();
    scan.complete(qr());
    await tester.pump();
    expect(closed, 1);
    expect(find.byKey(const Key('pairing-server-origin')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rescan discards pending claim and never starts old polling',
      (tester) async {
    final pending = Completer<PairingSnapshot>();
    late FakePairingApi api;
    await showOnboarding(tester,
        factory: (profile) =>
            api = FakePairingApi(profile)..onClaim = () => pending.future);
    await claim(tester);
    expect(api.claims, 1);
    await tap(tester, 'pairing-start-over');
    pending.complete(snapshot(PairingState.claimed));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(api.cancellations, greaterThan(0));
    expect(api.polls, 0);
    expect(find.text('123456'), findsNothing);
    expect(find.byKey(const Key('pairing-paste')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late approval after close never redeems or logs in',
      (tester) async {
    final pending = Completer<PairingSnapshot>();
    late FakePairingApi api;
    var connected = 0;
    await showOnboarding(tester,
        factory: (profile) =>
            api = FakePairingApi(profile)..onPoll = () => pending.future,
        onConnected: (_, result) {
          connected++;
          result.api.dispose();
        });
    await claim(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byTooltip('取消设备连接'));
    await tester.pump();
    pending.complete(snapshot(PairingState.approved));
    await tester.pump();
    expect(api.redemptions, 0);
    expect(connected, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'late redeem after rescan destroys returned token and cannot log in',
      (tester) async {
    final pending = Completer<DevicePairingResult>();
    late FakePairingApi api;
    var connected = 0;
    await showOnboarding(tester,
        factory: (profile) => api = FakePairingApi(profile)
          ..onPoll = (() async => snapshot(PairingState.approved))
          ..onRedeem = (() => pending.future),
        onConnected: (_, result) {
          connected++;
          result.api.dispose();
        });
    await claim(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(api.redemptions, 1);
    await tap(tester, 'pairing-start-over');
    final lateResult = api.result();
    pending.complete(lateResult);
    await tester.pump();
    expect(connected, 0);
    expect(lateResult.api.token, isNull);
    expect(find.byKey(const Key('pairing-paste')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'uncertain redemption is never retried and explains revocation recovery',
      (tester) async {
    late FakePairingApi api;
    await showOnboarding(tester,
        factory: (profile) => api = FakePairingApi(profile)
          ..onPoll = (() async => snapshot(PairingState.approved))
          ..onRedeem = () async =>
              throw ApiException('NETWORK', 'synthetic-secret-echo'));
    await claim(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byKey(const Key('pairing-uncertain')), findsOneWidget);
    expect(find.textContaining('撤销可能已创建的设备'), findsOneWidget);
    expect(find.textContaining('synthetic-secret-echo'), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(api.redemptions, 1);
    expect(find.byKey(const Key('pairing-redeem')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unmount while claim is pending is safe', (tester) async {
    final pending = Completer<PairingSnapshot>();
    late FakePairingApi api;
    await showOnboarding(tester,
        factory: (profile) =>
            api = FakePairingApi(profile)..onClaim = () => pending.future);
    await claim(tester);
    await tester.pumpWidget(const SizedBox());
    pending.complete(snapshot(PairingState.claimed));
    await tester.pump();
    expect(api.cancellations, greaterThan(0));
    expect(api.polls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('onboarding fits narrow viewport and long server names',
      (tester) async {
    await showOnboarding(tester, size: const Size(360, 780));
    await review(
        tester,
        qr(
            server:
                'https://mail.subdomain.synthetic-example.invalid:8443/api/v1'));
    await tester
        .ensureVisible(find.byKey(const Key('pairing-confirm-destination')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
