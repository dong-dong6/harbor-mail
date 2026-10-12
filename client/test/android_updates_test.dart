import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/android_downloads.dart';
import 'package:harbor_mail/android_updates.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> metadata({int code = 7, String cert = 'b'}) => {
  'schemaVersion': 1,
  'available': true,
  'downloadPath': '/downloads/android/app.apk',
  'fileName': 'harbor-mail-dev.apk',
  'packageName': 'dev.harbor.harbor_mail.dev',
  'versionName': '0.3.1',
  'versionCode': code,
  'sizeBytes': 12345,
  'sha256': 'a' * 64,
  'signing': {
    'classification': 'development-debug',
    'certificateSha256': cert * 64,
  },
};
Map<String, dynamic> installed() => {
  'packageName': 'dev.harbor.harbor_mail.dev',
  'versionCode': 6,
  'versionName': '0.3.0',
  'certificateSha256': 'b' * 64,
};

class FakeService extends AndroidUpdateService {
  Map<String, Object?> manifest = metadata();
  int checks = 0, downloads = 0, installs = 0, settings = 0, cancels = 0;
  String installResult = 'opened';
  final events = StreamController<dynamic>.broadcast();
  Completer<String>? downloadCompleter;
  bool failCheck = false;
  @override
  Future<Map<String, dynamic>> installedInfo() async => installed();
  @override
  Future<AndroidDownloadManifest> check(String base) async {
    checks++;
    if (failCheck) throw StateError('offline');
    return AndroidDownloadManifest.parse(manifest);
  }

  @override
  Stream<dynamic> get progress => events.stream;
  @override
  Future<String> download(String base, AndroidDownloadManifest manifest) {
    downloads++;
    return downloadCompleter?.future ?? Future.value('verified-token');
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (downloadCompleter?.isCompleted == false) {
      downloadCompleter!.completeError(PlatformException(code: 'cancelled'));
    }
  }

  @override
  Future<String?> install(String token) async {
    installs++;
    return installResult;
  }

  @override
  Future<void> openSettings() async {
    settings++;
  }
}

Future<void> showCard(WidgetTester tester, FakeService service) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AndroidUpdateCard(
            apiBase: 'https://mail.invalid/api/v1',
            service: service,
          ),
        ),
      ),
    ),
  );
}

Future<void> tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  test('old metadata works; notes are plain bounded Unicode text', () {
    expect(AndroidDownloadManifest.parse(metadata()).releaseNotes, '');
    expect(
      AndroidDownloadManifest.parse({
        ...metadata(),
        'releaseNotes': '😀' * 4000,
      }).releaseNotes.runes.length,
      4000,
    );
    for (final invalid in [
      null,
      42,
      ['notes'],
      '😀' * 4001,
    ]) {
      expect(
        () => AndroidDownloadManifest.parse({
          ...metadata(),
          'releaseNotes': invalid,
        }),
        throwsFormatException,
      );
    }
  });
  test(
    'only increasing versionCode and same installed signature may update',
    () {
      expect(
        androidUpdateBlocker(
          AndroidDownloadManifest.parse(metadata()),
          installed(),
        ),
        isNull,
      );
      expect(
        androidUpdateBlocker(
          AndroidDownloadManifest.parse(metadata(code: 5)),
          installed(),
        ),
        contains('阻止降级'),
      );
      expect(
        androidUpdateBlocker(
          AndroidDownloadManifest.parse(metadata(code: 6)),
          installed(),
        ),
        contains('版本码相同'),
      );
      expect(
        androidUpdateBlocker(
          AndroidDownloadManifest.parse({
            ...metadata(code: 6),
            'versionName': '0.3.0',
          }),
          installed(),
        ),
        contains('最新版本'),
      );
      expect(
        androidUpdateBlocker(
          AndroidDownloadManifest.parse(metadata(cert: 'c')),
          installed(),
        ),
        contains('不要卸载'),
      );
      expect(
        androidUpdateBlocker(AndroidDownloadManifest.parse(metadata()), {
          ...installed(),
          'packageName': 'other',
        }),
        isNotNull,
      );
    },
  );
  test('public request has no authentication and rejects redirects', () async {
    final service = AndroidUpdateService(
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://mail.invalid/downloads/android/manifest.json',
        );
        expect(request.headers.containsKey('authorization'), false);
        expect(request.followRedirects, false);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://other.invalid/app.apk'},
        );
      }),
    );
    await expectLater(
      service.check('https://mail.invalid/api/v1'),
      throwsFormatException,
    );
    service.dispose();
  });
  test('rejects HTTP origin, oversized metadata and invalid JSON', () async {
    int requests = 0;
    final service = AndroidUpdateService(
      client: MockClient((_) async {
        requests++;
        return http.Response('x' * 65537, 200);
      }),
    );
    await expectLater(
      service.check('http://mail.invalid/api/v1'),
      throwsFormatException,
    );
    expect(requests, 0);
    await expectLater(
      service.check('https://mail.invalid/api/v1'),
      throwsFormatException,
    );
    service.dispose();
    final bad = AndroidUpdateService(
      client: MockClient((_) async => http.Response('bad-json', 200)),
    );
    await expectLater(
      bad.check('https://mail.invalid/api/v1'),
      throwsFormatException,
    );
    bad.dispose();
  });
  test('old server manifest remains available', () async {
    final service = AndroidUpdateService(
      client: MockClient(
        (_) async => http.Response(jsonEncode(metadata()), 200),
      ),
    );
    expect((await service.check('https://mail.invalid/api/v1')).versionCode, 7);
    service.dispose();
  });
  testWidgets('check download install are separate explicit actions', (
    tester,
  ) async {
    final service = FakeService();
    await showCard(tester, service);
    expect(service.checks, 0);
    await tap(tester, '检查更新');
    expect(service.downloads, 0);
    await tap(tester, '下载更新');
    expect(service.downloads, 1);
    expect(service.installs, 0);
    await tap(tester, '安装更新');
    expect(service.installs, 1);
    expect(find.textContaining('已打开系统安装器'), findsOneWidget);
  });
  testWidgets('signature mismatch stops download and protects configuration', (
    tester,
  ) async {
    final service = FakeService()..manifest = metadata(cert: 'c');
    await showCard(tester, service);
    await tap(tester, '检查更新');
    expect(find.text('下载更新'), findsNothing);
    expect(find.textContaining('不要卸载'), findsOneWidget);
    expect(service.downloads, 0);
  });
  testWidgets(
    'settings only opens explicitly and returning does not auto install',
    (tester) async {
      final service = FakeService()..installResult = 'permissionRequired';
      await showCard(tester, service);
      await tap(tester, '检查更新');
      await tap(tester, '下载更新');
      await tap(tester, '安装更新');
      expect(service.settings, 0);
      await tap(tester, '前往系统设置');
      expect(service.settings, 1);
      expect(service.installs, 1);
      service.installResult = 'opened';
      await tap(tester, '安装更新');
      expect(service.installs, 2);
    },
  );
  testWidgets('progress, repeated taps, cancel and retry', (tester) async {
    final service = FakeService()..downloadCompleter = Completer<String>();
    await showCard(tester, service);
    await tap(tester, '检查更新');
    await tester.tap(find.text('下载更新'));
    await tester.pump();
    await tester.tap(find.text('下载更新'));
    expect(service.downloads, 1);
    service.events.add({'received': 50, 'total': 100});
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
    await tap(tester, '取消下载');
    expect(service.cancels, 1);
    expect(find.text('安装更新'), findsNothing);
    service.downloadCompleter = null;
    await tap(tester, '下载更新');
    expect(service.downloads, 2);
    expect(find.text('安装更新'), findsOneWidget);
  });
  testWidgets('network failure is retryable', (tester) async {
    final service = FakeService()..failCheck = true;
    await showCard(tester, service);
    await tap(tester, '检查更新');
    expect(find.textContaining('检查更新失败'), findsOneWidget);
    service.failCheck = false;
    await tap(tester, '检查更新');
    expect(find.text('下载更新'), findsOneWidget);
  });
  testWidgets('closing while downloading cancels safely', (tester) async {
    final service = FakeService()..downloadCompleter = Completer<String>();
    await showCard(tester, service);
    await tap(tester, '检查更新');
    await tester.tap(find.text('下载更新'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(service.cancels, 1);
    expect(tester.takeException(), isNull);
  });
}
