import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/mail_body.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _source = 'https://tracking.example.invalid/banner';
const _imageHtml = '<h2>HTML message</h2><img src="$_source" alt="Banner">';
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgaPj/HwAEggJ/59habAAAAABJRU5ErkJggg==',
);

http.Response _manifest() => http.Response(
  jsonEncode({
    'items': [
      {'id': 'a' * 64, 'source': _source},
      {'id': 'b' * 64, 'source': 'https://tracking.example.invalid/other'},
    ],
  }),
  200,
);

Future<void> _pump(
  WidgetTester tester, {
  String html = _imageHtml,
  String text = 'Plain alternative',
  MailApi? api,
  String messageId = 'message-1',
  String accountId = 'account-1',
  bool inputEnabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MailBody(
            html: html,
            text: text,
            api: api,
            messageId: messageId,
            accountId: accountId,
            inputEnabled: inputEnabled,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _NoNetwork extends HttpOverrides {
  int requests = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('A mail body must never start a network image request.');
  }
}

Finder get _table =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == 'HtmlTable');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native reader renders rich HTML and tables, with selectable plaintext toggle',
    (tester) async {
      await _pump(
        tester,
        html: '''
      <h1>Formatted heading</h1><p>Hello <strong>bold</strong> and <em>italic</em></p>
      <table border="1" cellpadding="6"><tr><th>Item</th><th>Total</th></tr>
      <tr><td style="background:#eef1f5;color:#123456">Widgets</td><td>42</td></tr></table>
    ''',
      );
      expect(find.byType(HtmlWidget), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(
        find.text('Formatted heading', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Widgets', findRichText: true), findsOneWidget);
      expect(_table, findsOneWidget);
      expect(find.text('Plain alternative'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('查看纯文本'));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlWidget), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('Plain alternative'), findsOneWidget);
      await tester.tap(find.text('显示邮件排版'));
      await tester.pumpAndSettle();
      expect(_table, findsOneWidget);
    },
  );

  testWidgets(
    'HTML-only malformed message stays readable and derives safe plain text',
    (tester) async {
      await _pump(
        tester,
        html:
            '<p>HTML only<strong> readable<table><tr><td>Cell<script>evil()</script>',
        text: '',
      );
      expect(
        find.textContaining('HTML only', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Cell', findRichText: true), findsOneWidget);
      expect(find.textContaining('Web 版'), findsNothing);
      await tester.tap(find.text('查看纯文本'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.textContaining('HTML only readable'), findsOneWidget);
      expect(find.textContaining('evil'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide HTML tables scroll within a narrow native reader', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      html: '''
      <h2>Order summary</h2><p>A formatted message on a small screen.</p>
      <table border="1" cellpadding="8" style="width:1200px">
        <tr><th>Product</th><th>Description</th><th>Total</th></tr>
        <tr><td>Widgets</td><td>Long description for a wide table</td><td>42</td></tr>
      </table>
    ''',
    );
    expect(_table, findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
      findsAtLeastNWidgets(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('text-only and empty messages retain safe readable fallback', (
    tester,
  ) async {
    await _pump(tester, html: '', text: 'Text only message');
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('Text only message'), findsOneWidget);
    expect(find.text('查看纯文本'), findsNothing);
    await _pump(tester, html: '', text: '');
    expect(find.text('此邮件没有可显示的正文。'), findsOneWidget);
  });

  testWidgets(
    'fully stripped HTML automatically shows its safe text alternative',
    (tester) async {
      for (final html in [
        '<script>alert(1)</script>',
        '<form action="https://tracking.invalid"><input value="secret"></form>',
        '<p> </p><div><span></span></div>',
      ]) {
        await _pump(tester, html: html, text: '安全的纯文本内容');
        expect(find.text('安全的纯文本内容'), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        expect(find.byType(HtmlWidget), findsNothing);
        expect(find.text('查看纯文本'), findsNothing);
        expect(find.text('邮件排版不含可安全显示的内容，已显示纯文本。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('image-only mail retains placeholders and image opt-in', (
    tester,
  ) async {
    await _pump(
      tester,
      html: '<img src="$_source" alt="Banner">',
      text: 'Image alternative',
    );
    expect(find.byType(HtmlWidget), findsOneWidget);
    expect(find.text('[Banner]', findRichText: true), findsOneWidget);
    expect(find.text('显示本封邮件的远程图片'), findsOneWidget);
    expect(find.text('Image alternative'), findsNothing);
  });

  testWidgets(
    'hostile HTML cannot create executable widgets or network requests',
    (tester) async {
      final original = HttpOverrides.current;
      final network = _NoNetwork();
      HttpOverrides.global = network;
      addTearDown(() => HttpOverrides.global = original);
      var apiCalls = 0;
      final api = MailApi(
        client: MockClient((_) async {
          apiCalls++;
          return _manifest();
        }),
      )..token = 'synthetic';
      addTearDown(api.dispose);
      await _pump(
        tester,
        api: api,
        html:
            '''
      <h2>Safe text</h2><script>secret-script</script>
      <iframe src="https://tracking.invalid/frame">secret-frame</iframe>
      <form action="https://tracking.invalid/form"><input value="secret">secret-form</form>
      <svg onload="evil()"><image href="https://tracking.invalid/svg"/></svg>
      <style>@import "https://tracking.invalid/style";</style>
      <div style="background-image:url(https://tracking.invalid/css)">Visible</div>
      <img src="$_source" onerror="evil()"><img src="file:///private">
      <img src="data:image/svg+xml,evil"><img src="asset:///private">
      <a href="javascript:evil()">Inert link</a>
    ''',
      );
      expect(find.text('Safe text', findRichText: true), findsOneWidget);
      expect(find.textContaining('secret', findRichText: true), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(network.requests, 0);
      expect(apiCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resource factory fails closed even if sanitizer is bypassed', (
    tester,
  ) async {
    final original = HttpOverrides.current;
    final network = _NoNetwork();
    HttpOverrides.global = network;
    addTearDown(() => HttpOverrides.global = original);
    final factory = OfflineMailWidgetFactory();
    expect(factory.imageProviderFromNetwork(_source), isNull);
    expect(factory.imageProviderFromFileUri('file:///private'), isNull);
    expect(factory.imageProviderFromAsset('asset:///private'), isNull);
    expect(
      factory.imageProviderFromDataUri('data:image/png;base64,invalid'),
      isNull,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HtmlWidget('''
      <img src="$_source"><img src="file:///private"><img src="asset:///private">
      <img src="data:image/png;base64,invalid">
      <div style="background-image:url($_source)">Background</div>
    ''', factoryBuilder: OfflineMailWidgetFactory.new),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(network.requests, 0);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'explicit opt-in uses only own authenticated proxy and blocks again',
    (tester) async {
      final calls = <http.Request>[];
      final api = MailApi(
        base: 'https://mail.example.invalid/api/v1',
        client: MockClient((request) async {
          calls.add(request);
          expect(request.url.host, 'mail.example.invalid');
          expect(request.headers['authorization'], 'Bearer synthetic');
          expect(request.followRedirects, isFalse);
          if (request.url.path.endsWith('/images')) return _manifest();
          return http.Response.bytes(
            _png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      )..token = 'synthetic';
      addTearDown(api.dispose);
      await _pump(tester, api: api);
      expect(calls, isEmpty);
      expect(find.byType(Image), findsNothing);
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '显示本封邮件的远程图片'),
      );
      await tester.runAsync(
        () => (button.onPressed! as Future<void> Function())(),
      );
      await tester.pumpAndSettle();
      expect(calls, hasLength(3));
      expect(find.byType(Image), findsOneWidget);
      final provider = tester.widget<Image>(find.byType(Image)).image;
      expect(provider, isA<ResizeImage>());
      expect((provider as ResizeImage).imageProvider, isA<MemoryImage>());
      expect(provider.width, lessThanOrEqualTo(1024));
      expect(provider.height, lessThanOrEqualTo(1024));
      await tester.tap(find.text('阻止远程图片'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('[Banner]', findRichText: true), findsOneWidget);
      expect(calls, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in [
    'cancel',
    'message',
    'account',
    'session',
    'covered',
    'plain',
    'dispose',
  ]) {
    testWidgets('stale proxy responses cannot cross $change boundary', (
      tester,
    ) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final api = MailApi(
        base: 'https://mail.example.invalid/api/v1',
        client: MockClient((request) async {
          calls++;
          return calls == 1 ? _manifest() : pending.future;
        }),
      )..token = 'synthetic';
      addTearDown(api.dispose);
      await _pump(tester, api: api);
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '显示本封邮件的远程图片'),
      );
      late Future<void> loading;
      await tester.runAsync(() async {
        loading = (button.onPressed! as Future<void> Function())();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(calls, 2);
      switch (change) {
        case 'cancel':
          await tester.tap(find.text('正在安全载入（点此取消）'));
        case 'message':
          await _pump(tester, api: api, messageId: 'message-2');
        case 'account':
          await _pump(tester, api: api, accountId: 'account-2');
        case 'session':
          api.token = 'new-synthetic-session';
          await _pump(tester, api: api);
        case 'covered':
          await _pump(tester, api: api, inputEnabled: false);
        case 'plain':
          await tester.tap(find.text('查看纯文本'));
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
      }
      await tester.runAsync(() async {
        pending.complete(
          http.Response.bytes(
            _png,
            200,
            headers: {'content-type': 'image/png'},
          ),
        );
        await loading;
      });
      await tester.pumpAndSettle();
      expect(
        calls,
        2,
        reason: 'Cancelled batch must not request its next image',
      );
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large proxy raster is decoded into a bounded proportional cache', (
    tester,
  ) async {
    final wide = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAEAAAAAABCAYAAABeIWt8AAAAKklEQVR4nO3DMQ0AAAwDoEqf81bGHkhIrlVVVVVVVVVVVVVVVVVVVVV/Dxfu4krvQoMkAAAAAElFTkSuQmCC',
    );
    final api = MailApi(
      base: 'https://mail.example.invalid/api/v1',
      client: MockClient(
        (request) async => request.url.path.endsWith('/images')
            ? _manifest()
            : http.Response.bytes(
                wide,
                200,
                headers: {'content-type': 'image/png'},
              ),
      ),
    )..token = 'synthetic';
    addTearDown(api.dispose);
    await _pump(tester, api: api);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '显示本封邮件的远程图片'),
    );
    await tester.runAsync(
      () => (button.onPressed! as Future<void> Function())(),
    );
    await tester.pumpAndSettle();
    final provider =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(provider.width, 1024);
    expect(provider.height, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('proxy failure stays blocked without direct fallback', (
    tester,
  ) async {
    var calls = 0;
    final api = MailApi(
      base: 'https://mail.example.invalid/api/v1',
      client: MockClient((request) async {
        calls++;
        expect(request.url.host, 'mail.example.invalid');
        return http.Response('', 503);
      }),
    )..token = 'synthetic';
    addTearDown(api.dispose);
    await _pump(tester, api: api);
    await tester.tap(find.text('显示本封邮件的远程图片'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(Image), findsNothing);
    expect(find.text('图片暂时无法载入，已保持阻止。'), findsOneWidget);
  });

  testWidgets(
    'links show destination, cancellation stays put, explicit approval launches externally',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _pump(
        tester,
        html: '<a href="https://example.invalid/report">Open report</a>',
      );
      expect(calls, isEmpty);
      await tester.tap(find.text('Open report', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('https://example.invalid/report'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('Open report', findRichText: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在浏览器中打开'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'launch');
      expect(calls.single.arguments['url'], 'https://example.invalid/report');
      expect(calls.single.arguments['useWebView'], isFalse);
      expect(calls.single.arguments['headers'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated link taps and late approval cannot launch a retired message',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      const html = '<a href="https://example.invalid/report">Open report</a>';
      await _pump(tester, html: html);
      final callback = tester
          .widget<HtmlWidget>(find.byType(HtmlWidget))
          .onTapUrl!;
      final first = callback('https://example.invalid/report');
      final second = callback('https://example.invalid/report');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await _pump(tester, html: html, messageId: 'message-2');
      await tester.tap(find.text('在浏览器中打开'));
      await tester.pumpAndSettle();
      await Future.wait([Future.value(first), Future.value(second)]);
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
