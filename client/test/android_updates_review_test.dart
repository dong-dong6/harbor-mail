import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/android_downloads.dart';
import 'package:harbor_mail/android_updates.dart';
import 'package:http/http.dart' as http;

import 'android_updates_test.dart' as fixtures;

class PendingClient extends http.BaseClient {
  final response = Completer<http.StreamedResponse>();
  http.BaseRequest? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    this.request = request;
    return response.future;
  }
}

class DelayedCancelService extends fixtures.FakeService {
  final cancellation = Completer<void>();

  @override
  Future<void> cancel() {
    cancels++;
    return cancellation.future;
  }
}

class DelayedInstallService extends fixtures.FakeService {
  Completer<String?>? installation;
  bool failInstall = false;

  @override
  Future<String?> install(String token) async {
    installs++;
    if (failInstall) throw PlatformException(code: 'installerUnavailable');
    return installation == null ? installResult : installation!.future;
  }
}

class SlowCleanupService extends fixtures.FakeService {
  final cleanup = Completer<void>();
  late final controller = StreamController<dynamic>(
    onCancel: () => cleanup.future,
  );

  @override
  Stream<dynamic> get progress => controller.stream;
}

class PendingCheckService extends fixtures.FakeService {
  final result = Completer<AndroidDownloadManifest>();
  final origins = <String>[];

  @override
  Future<AndroidDownloadManifest> check(String base) {
    checks++;
    origins.add(base);
    return result.future;
  }
}

class PendingInfoService extends fixtures.FakeService {
  final info = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> installedInfo() => info.future;
}

class PendingSettingsService extends fixtures.FakeService {
  final settingsResult = Completer<void>();

  @override
  Future<void> openSettings() {
    settings++;
    return settingsResult.future;
  }
}

Future<void> showOrigin(
  WidgetTester tester,
  fixtures.FakeService service,
  String origin,
) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: AndroidUpdateCard(apiBase: '$origin/api/v1', service: service),
      ),
    ),
  ),
);

void main() {
  test('actual byte cap rejects otherwise valid chunked metadata', () async {
    final client = PendingClient();
    final service = AndroidUpdateService(client: client);
    addTearDown(service.dispose);
    final bytes = utf8.encode(
      jsonEncode({...fixtures.metadata(), 'ignoredExtraField': 'x' * 65537}),
    );
    client.response.complete(
      http.StreamedResponse(
        Stream.fromIterable([bytes.sublist(0, 32768), bytes.sublist(32768)]),
        200,
      ),
    );
    await expectLater(
      service.check('https://mail.invalid/api/v1'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('exceeds limit'),
        ),
      ),
    );
  });

  testWidgets('metadata deadline bounds a transport that ignores abort', (
    tester,
  ) async {
    final client = PendingClient();
    final service = AndroidUpdateService(client: client);
    addTearDown(service.dispose);
    Object? failure;
    AndroidDownloadManifest? result;
    unawaited(
      service
          .check('https://mail.invalid/api/v1')
          .then(
            (value) => result = value,
            onError: (Object error) => failure = error,
          ),
    );
    await tester.pump();
    bool aborted = false;
    final request = client.request as http.AbortableRequest;
    unawaited(request.abortTrigger!.then((_) => aborted = true));
    await tester.pump(const Duration(seconds: 13));
    expect(failure, isA<TimeoutException>());
    expect(aborted, isTrue);
    expect(result, isNull);
    client.response.complete(
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(fixtures.metadata()))),
        200,
      ),
    );
    await tester.pump();
    expect(result, isNull, reason: 'A response after the deadline is stale.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('metadata deadline also bounds a stalled response body', (
    tester,
  ) async {
    final client = PendingClient();
    final service = AndroidUpdateService(client: client);
    final body = StreamController<List<int>>();
    addTearDown(service.dispose);
    Object? failure;
    unawaited(
      service
          .check('https://mail.invalid/api/v1')
          .then((_) {}, onError: (Object error) => failure = error),
    );
    client.response.complete(http.StreamedResponse(body.stream, 200));
    await tester.pump();
    body.add(utf8.encode('{'));
    await tester.pump(const Duration(seconds: 13));
    expect(failure, isA<TimeoutException>());
    await body.close();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('equal version does not hide an incompatible signing certificate', () {
    final manifest = AndroidDownloadManifest.parse({
      ...fixtures.metadata(code: 6, cert: 'c'),
      'versionName': '0.3.0',
    });
    final blocker = androidUpdateBlocker(manifest, fixtures.installed());
    expect(blocker, contains('签名'));
    expect(blocker, isNot(contains('最新版本')));
  });

  testWidgets(
    'long Unicode notes fit a narrow screen and actions stay usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = fixtures.FakeService()
        ..manifest = {...fixtures.metadata(), 'releaseNotes': '更新说明😀 ' * 500};
      await fixtures.showCard(tester, service);
      await fixtures.tap(tester, '检查更新');
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('下载更新'));
      await fixtures.tap(tester, '下载更新');
      expect(find.text('安装更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('installer failure recovers through recheck and redownload', (
    tester,
  ) async {
    final service = DelayedInstallService()..failInstall = true;
    await fixtures.showCard(tester, service);
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    await fixtures.tap(tester, '安装更新');
    expect(find.textContaining('无法打开安装器'), findsOneWidget);
    service.failInstall = false;
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    await fixtures.tap(tester, '安装更新');
    expect(service.installs, 2);
    expect(service.downloads, 2);
    expect(find.textContaining('已打开系统安装器'), findsOneWidget);
  });

  testWidgets('repeated install taps do not open concurrent installers', (
    tester,
  ) async {
    final service = DelayedInstallService()
      ..installation = Completer<String?>();
    await fixtures.showCard(tester, service);
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    expect(service.installs, 1);
    service.installation!.complete('opened');
    await tester.pumpAndSettle();
    expect(find.textContaining('已打开系统安装器'), findsOneWidget);
  });

  testWidgets('cancel acknowledgement gates retry and rejects a late token', (
    tester,
  ) async {
    final service = DelayedCancelService()
      ..downloadCompleter = Completer<String>();
    await fixtures.showCard(tester, service);
    await fixtures.tap(tester, '检查更新');
    await tester.tap(find.text('下载更新'));
    await tester.pump();
    await tester.tap(find.text('取消下载'));
    await tester.pump();
    await tester.tap(find.text('取消下载'));
    await tester.tap(find.text('下载更新'));
    await tester.pump();
    expect(service.cancels, 1);
    expect(service.downloads, 1);
    service.downloadCompleter!.complete('stale-token');
    await tester.pump();
    expect(find.text('安装更新'), findsNothing);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '下载更新'),
    );
    expect(button.onPressed, isNull);
    service.cancellation.complete();
    await tester.pumpAndSettle();
    service.downloadCompleter = null;
    await fixtures.tap(tester, '下载更新');
    expect(service.downloads, 2);
    expect(find.text('安装更新'), findsOneWidget);
  });

  testWidgets('slow event-stream cleanup cannot block verified install UI', (
    tester,
  ) async {
    final service = SlowCleanupService();
    await fixtures.showCard(tester, service);
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    expect(service.cleanup.isCompleted, isFalse);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '安装更新'),
    );
    expect(button.onPressed, isNotNull);
    service.cleanup.complete();
    await tester.pump();
  });

  testWidgets('server change clears an already verified install token', (
    tester,
  ) async {
    final service = fixtures.FakeService();
    await showOrigin(tester, service, 'https://first.invalid');
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    expect(find.text('安装更新'), findsOneWidget);
    await showOrigin(tester, service, 'https://second.invalid');
    await tester.pump();
    expect(find.text('安装更新'), findsNothing);
    expect(find.text('下载更新'), findsNothing);
    expect(service.installs, 0);
  });

  testWidgets('server change discards a late check from the old server', (
    tester,
  ) async {
    final service = PendingCheckService();
    await showOrigin(tester, service, 'https://first.invalid');
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await showOrigin(tester, service, 'https://second.invalid');
    service.result.complete(AndroidDownloadManifest.parse(fixtures.metadata()));
    await tester.pumpAndSettle();
    expect(find.text('下载更新'), findsNothing);
    expect(service.origins, ['https://first.invalid/api/v1']);
    final check = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '检查更新'),
    );
    expect(check.onPressed, isNotNull);
  });

  testWidgets('late installed-info cannot start a check for another server', (
    tester,
  ) async {
    final service = PendingInfoService();
    await showOrigin(tester, service, 'https://first.invalid');
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await showOrigin(tester, service, 'https://second.invalid');
    service.info.complete(fixtures.installed());
    await tester.pumpAndSettle();
    expect(service.checks, 0);
    expect(find.text('下载更新'), findsNothing);
  });

  testWidgets('late install permission result cannot restore old-server UI', (
    tester,
  ) async {
    final service = DelayedInstallService()
      ..installation = Completer<String?>();
    await showOrigin(tester, service, 'https://first.invalid');
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await showOrigin(tester, service, 'https://second.invalid');
    await tester.pump();
    expect(service.cancels, 1);
    service.installation!.complete('permissionRequired');
    await tester.pumpAndSettle();
    expect(find.text('前往系统设置'), findsNothing);
    expect(find.text('安装更新'), findsNothing);
    expect(find.textContaining('服务器已变更'), findsOneWidget);
  });

  testWidgets('closing during install verification cancels the native action', (
    tester,
  ) async {
    final service = DelayedInstallService()
      ..installation = Completer<String?>();
    await fixtures.showCard(tester, service);
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    await tester.tap(find.text('安装更新'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(service.cancels, 1);
    service.installation!.complete('permissionRequired');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('old settings return cannot unlock a new-server check', (
    tester,
  ) async {
    final oldService = PendingSettingsService()
      ..installResult = 'permissionRequired';
    await showOrigin(tester, oldService, 'https://first.invalid');
    await fixtures.tap(tester, '检查更新');
    await fixtures.tap(tester, '下载更新');
    await fixtures.tap(tester, '安装更新');
    await tester.tap(find.text('前往系统设置'));
    await tester.pump();
    final newService = PendingCheckService();
    await showOrigin(tester, newService, 'https://second.invalid');
    await tester.pump();
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    oldService.settingsResult.complete();
    await tester.pump();
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '检查更新'),
    );
    expect(button.onPressed, isNull);
    newService.result.complete(
      AndroidDownloadManifest.parse(fixtures.metadata()),
    );
    await tester.pumpAndSettle();
    expect(find.text('下载更新'), findsOneWidget);
  });
}
