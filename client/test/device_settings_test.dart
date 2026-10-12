import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/device_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const pairingId = 'synthetic-pairing-0001';
const secret = 'synthetic-secret-never-display-000000000000000';

http.Response jsonResponse(Object data, [int status = 200]) => http.Response(
      jsonEncode(data),
      status,
      headers: {'content-type': 'application/json'},
    );

Map<String, Object> ownerStatus(String state) => {
      'pairingId': pairingId,
      'state': state,
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 2))
          .toUtc()
          .toIso8601String(),
      'accountName': 'synthetic-owner',
      'permission': 'OWNER_FULL_ACCESS',
      if (state == 'CLAIMED' || state == 'APPROVED') ...{
        'confirmationCode': '123456',
        'deviceName': '合成测试手机',
      },
    };

Map<String, Object> createResponse() => {
      'pairingId': pairingId,
      'state': 'CREATED',
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 2))
          .toUtc()
          .toIso8601String(),
      'qrPayload': jsonEncode({
        'type': 'harbor-mail-device-pairing',
        'version': 1,
        'serverUrl': 'https://mail.invalid/api/v1',
        'pairingId': pairingId,
        'secret': secret,
      }),
    };

Map<String, Object> device({bool revoked = false}) => {
      'id': 'synthetic-device-1',
      'name': '合成测试手机',
      'createdAt': DateTime.now()
          .subtract(const Duration(minutes: 1))
          .toUtc()
          .toIso8601String(),
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
      'revoked': revoked,
      'permission': 'OWNER_FULL_ACCESS',
    };

Future<void> showSettings(WidgetTester tester, MailApi api,
    {VoidCallback? onClose, Size size = const Size(1100, 1200)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      home: DeviceSettingsPage(
    api: api,
    onClose: onClose ?? () {},
  )));
  await tester.pump();
}

MailApi mockApi(Future<http.Response> Function(http.Request) handler) =>
    MailApi(base: 'https://mail.invalid/api/v1', client: MockClient(handler))
      ..token = 'synthetic-owner-token';

Future<void> tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
}

Future<void> claim(WidgetTester tester) async {
  await tap(tester, 'device-create-pairing');
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
}

Future<void> approve(WidgetTester tester) async {
  await tap(tester, 'device-code-matched');
  await tester.enterText(
      find.byKey(const Key('device-owner-password')), 'synthetic-password');
  await tester.pump();
  await tap(tester, 'device-approve');
}

void main() {
  testWidgets(
      'QR stays visual-only; approval requires matching code and password',
      (tester) async {
    var approvals = 0;
    Map<String, dynamic>? approvalBody;
    final api = mockApi((request) async {
      if (request.url.path.endsWith('/auth/devices')) {
        return jsonResponse({'items': []});
      }
      if (request.url.path.endsWith('/approve')) {
        approvals++;
        approvalBody = jsonDecode(request.body);
        return jsonResponse({'state': 'APPROVED'});
      }
      if (request.url.path.endsWith('/reject')) {
        return jsonResponse({'state': 'REJECTED'});
      }
      if (request.method == 'POST') return jsonResponse(createResponse());
      return jsonResponse(ownerStatus('CLAIMED'));
    });
    await showSettings(tester, api);
    await tap(tester, 'device-create-pairing');
    expect(find.byKey(const Key('device-pairing-qr')), findsOneWidget);
    expect(find.textContaining(secret), findsNothing);
    expect(find.textContaining('全部邮箱和设置'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.byKey(const Key('device-pairing-qr')), findsNothing);
    expect(find.text('123456'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('device-approve')))
            .onPressed,
        isNull);
    await tester.enterText(
        find.byKey(const Key('device-owner-password')), 'synthetic-password');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('device-approve')))
            .onPressed,
        isNull);
    expect(approvals, 0);
    await tap(tester, 'device-code-matched');
    await tap(tester, 'device-approve');
    expect(approvals, 1);
    expect(approvalBody,
        {'password': 'synthetic-password', 'confirmationCode': '123456'});
    expect(find.text('已批准，等待新设备完成连接'), findsOneWidget);
    expect(find.byKey(const Key('device-owner-password')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets('late claimed poll cannot undo owner approval', (tester) async {
    final stalePoll = Completer<http.Response>();
    var polls = 0;
    final api = mockApi((request) async {
      if (request.url.path.endsWith('/auth/devices')) {
        return jsonResponse({'items': []});
      }
      if (request.url.path.endsWith('/approve')) {
        return jsonResponse({'state': 'APPROVED'});
      }
      if (request.url.path.endsWith('/reject')) {
        return jsonResponse({'state': 'REJECTED'});
      }
      if (request.method == 'POST') return jsonResponse(createResponse());
      if (++polls == 2) return stalePoll.future;
      return jsonResponse(ownerStatus('CLAIMED'));
    });
    await showSettings(tester, api);
    await claim(tester);
    await tester.pump(const Duration(seconds: 2));
    await approve(tester);
    stalePoll.complete(jsonResponse(ownerStatus('CLAIMED')));
    await tester.pump();
    expect(find.text('已批准，等待新设备完成连接'), findsOneWidget);
    expect(find.byKey(const Key('device-approve')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets('late poll cannot resurrect a cancelled pairing', (tester) async {
    final stalePoll = Completer<http.Response>();
    var polls = 0;
    final api = mockApi((request) async {
      if (request.url.path.endsWith('/auth/devices')) {
        return jsonResponse({'items': []});
      }
      if (request.url.path.endsWith('/reject')) {
        return jsonResponse({'state': 'REJECTED'});
      }
      if (request.method == 'POST') return jsonResponse(createResponse());
      if (++polls == 2) return stalePoll.future;
      return jsonResponse(ownerStatus('CLAIMED'));
    });
    await showSettings(tester, api);
    await claim(tester);
    await tester.pump(const Duration(seconds: 2));
    await tap(tester, 'device-reject-pairing');
    stalePoll.complete(jsonResponse(ownerStatus('CLAIMED')));
    await tester.pump();
    expect(find.text('连接请求已取消'), findsOneWidget);
    expect(find.byKey(const Key('device-confirmation-code')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets('logout while waiting discards QR and stale server status',
      (tester) async {
    final delayed = Completer<http.Response>();
    final api = mockApi((request) async {
      if (request.url.path.endsWith('/auth/devices')) {
        return jsonResponse({'items': []});
      }
      if (request.method == 'POST') return jsonResponse(createResponse());
      return delayed.future;
    });
    await showSettings(tester, api);
    await tap(tester, 'device-create-pairing');
    await tester.pump(const Duration(seconds: 2));
    api.token = null;
    delayed.complete(jsonResponse(ownerStatus('CLAIMED')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('device-pairing-qr')), findsNothing);
    expect(find.text('123456'), findsNothing);
    expect(find.text('会话已失效，请返回登录后重试。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets(
      'close prompts and best-effort rejects; late creation never reopens',
      (tester) async {
    final created = Completer<http.Response>();
    var closed = 0;
    final api = mockApi((request) async {
      if (request.url.path.endsWith('/auth/devices')) {
        return jsonResponse({'items': []});
      }
      return created.future;
    });
    await showSettings(tester, api, onClose: () => closed++);
    await tap(tester, 'device-create-pairing');
    await tester.tap(find.byTooltip('返回账户设置'));
    await tester.pumpAndSettle();
    expect(find.text('离开设备连接？'), findsOneWidget);
    await tester.tap(find.text('离开'));
    await tester.pumpAndSettle();
    expect(closed, 1);
    created.complete(jsonResponse(createResponse()));
    await tester.pump();
    expect(find.byKey(const Key('device-pairing-qr')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets(
      'unavailable or forbidden creation leaves device management usable',
      (tester) async {
    final api = mockApi((request) async {
      if (request.url.path.endsWith('/auth/devices')) {
        return jsonResponse({
          'items': [device()]
        });
      }
      return jsonResponse({
        'error': {'code': 'PAIRING_UNAVAILABLE', 'message': secret}
      }, 409);
    });
    await showSettings(tester, api);
    await tap(tester, 'device-create-pairing');
    expect(find.textContaining('可信的 HTTPS'), findsOneWidget);
    expect(find.text('合成测试手机'), findsOneWidget);
    expect(find.byKey(const Key('device-revoke-synthetic-device-1')),
        findsOneWidget);
    expect(find.textContaining(secret), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets('device revocation requires explicit dialog and refreshes result',
      (tester) async {
    var revoked = false;
    final api = mockApi((request) async {
      if (request.method == 'DELETE') {
        revoked = true;
        return http.Response('', 204);
      }
      return jsonResponse({
        'items': [device(revoked: revoked)]
      });
    });
    await showSettings(tester, api);
    await tap(tester, 'device-revoke-synthetic-device-1');
    expect(revoked, isFalse);
    await tester.pumpAndSettle();
    await tap(tester, 'device-confirm-revoke');
    await tester.pumpAndSettle();
    expect(revoked, isTrue);
    expect(find.text('已撤销'), findsOneWidget);
    expect(find.byKey(const Key('device-revoke-synthetic-device-1')),
        findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets('owner pairing fits a narrow viewport without overflow',
      (tester) async {
    final api = mockApi((request) async {
      if (request.url.path.endsWith('/auth/devices')) {
        return jsonResponse({'items': []});
      }
      if (request.url.path.endsWith('/reject')) {
        return jsonResponse({'state': 'REJECTED'});
      }
      if (request.method == 'POST') return jsonResponse(createResponse());
      return jsonResponse(ownerStatus('CLAIMED'));
    });
    await showSettings(tester, api, size: const Size(360, 780));
    await claim(tester);
    await tester.ensureVisible(find.byKey(const Key('device-owner-password')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });
}
