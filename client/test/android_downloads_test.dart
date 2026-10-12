import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/android_downloads.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object> metadata() => {
  'schemaVersion': 1,
  'available': true,
  'downloadPath': '/downloads/android/app.apk',
  'fileName': 'harbor-mail-dev.apk',
  'packageName': 'dev.harbor.harbor_mail.dev',
  'versionName': '0.2.3',
  'versionCode': 5,
  'sizeBytes': 12345678,
  'sha256': 'a' * 64,
  'signing': {
    'classification': 'development-debug',
    'certificateSha256': 'b' * 64,
  },
};

Future<void> showCard(
  WidgetTester tester,
  http.Client client, {
  Future<bool> Function(Uri)? open,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AndroidDownloadCard(
            origin: Uri.parse(
              'https://mail.invalid/settings?private=ignored#part',
            ),
            client: client,
            openDownload: open,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'manifest rejects arbitrary URLs, packages, size, digests and release claims',
    () {
      final mutations = <String, Object>{
        'downloadPath': 'https://attacker.invalid/app.apk',
        'packageName': 'dev.harbor.harbor_mail',
        'sizeBytes': 1 << 30,
        'sha256': 'fake',
        'versionCode': 1.5,
        'signing': {
          'classification': 'production',
          'certificateSha256': 'b' * 64,
        },
      };
      for (final change in mutations.entries) {
        expect(
          () => AndroidDownloadManifest.parse({
            ...metadata(),
            change.key: change.value,
          }),
          throwsFormatException,
        );
      }
      expect(
        AndroidDownloadManifest.parse({
          'schemaVersion': 1,
          'available': false,
        }).available,
        isFalse,
      );
    },
  );

  testWidgets('verified download is same-origin and clearly debug signed', (
    tester,
  ) async {
    Uri? opened;
    final client = MockClient((request) async {
      expect(
        request.url,
        Uri.parse('https://mail.invalid/downloads/android/manifest.json'),
      );
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.followRedirects, isFalse);
      return http.Response(jsonEncode(metadata()), 200);
    });
    await showCard(
      tester,
      client,
      open: (uri) async {
        opened = uri;
        return true;
      },
    );
    expect(find.textContaining('Android 调试签名'), findsOneWidget);
    expect(find.textContaining('0.2.3 (5)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-download-button')));
    await tester.pumpAndSettle();
    expect(opened, Uri.parse('https://mail.invalid/downloads/android/app.apk'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('no artifact has no active or placeholder download', (
    tester,
  ) async {
    final client = MockClient(
      (_) async => http.Response('{"schemaVersion":1,"available":false}', 200),
    );
    await showCard(tester, client);
    expect(find.textContaining('尚未包含已验证'), findsOneWidget);
    expect(find.byKey(const Key('android-download-button')), findsNothing);
  });

  testWidgets('redirect and oversized manifests fail closed with retry', (
    tester,
  ) async {
    for (final response in [
      http.Response('', 302),
      http.Response('x' * 17000, 200),
    ]) {
      await showCard(tester, MockClient((_) async => response));
      expect(
        find.byKey(const Key('android-download-error')),
        findsOneWidget,
        reason:
            'status=${response.statusCode}; texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
      );
      expect(find.byKey(const Key('android-download-button')), findsNothing);
    }
  });

  testWidgets('late response after disposal cannot reopen UI', (tester) async {
    final late = Completer<http.Response>();
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidDownloadCard(
          origin: Uri.parse('https://mail.invalid'),
          client: MockClient((_) => late.future),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    late.complete(http.Response(jsonEncode(metadata()), 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('android-download-button')), findsNothing);
  });

  testWidgets('timeout removes loading and never enables a stale download', (
    tester,
  ) async {
    final late = Completer<http.Response>();
    await tester.pumpWidget(
      MaterialApp(
        home: AndroidDownloadCard(
          origin: Uri.parse('https://mail.invalid'),
          client: MockClient((_) => late.future),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 13));
    expect(find.byKey(const Key('android-download-error')), findsOneWidget);
    late.complete(http.Response(jsonEncode(metadata()), 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-download-button')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow screen keeps warnings and download visible without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showCard(
        tester,
        MockClient((_) async => http.Response(jsonEncode(metadata()), 200)),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('校验文件与签名'));
      await tester.tap(find.text('校验文件与签名'));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件 SHA-256'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
