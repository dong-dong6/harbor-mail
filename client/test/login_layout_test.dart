import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/android_downloads.dart';
import 'package:harbor_mail/login_layout.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object> _syntheticDownload() => {
  'schemaVersion': 1,
  'available': true,
  'downloadPath': '/downloads/android/app.apk',
  'fileName': 'harbor-mail-dev.apk',
  'packageName': 'dev.harbor.harbor_mail.dev',
  'versionName': '0.3.0',
  'versionCode': 6,
  'sizeBytes': 12345678,
  'sha256': 'a' * 64,
  'signing': {
    'classification': 'development-debug',
    'certificateSha256': 'b' * 64,
  },
};

Widget _loginForm() => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    const Icon(Icons.mark_email_unread_rounded, size: 44),
    const SizedBox(height: 24),
    const Text('泊信', style: TextStyle(fontSize: 36)),
    const SizedBox(height: 8),
    const Text('你的邮箱，一个安静的地方。'),
    const SizedBox(height: 36),
    const Text('登录你的私人邮件服务器'),
    const SizedBox(height: 16),
    const TextField(
      key: Key('synthetic-username'),
      decoration: InputDecoration(labelText: '用户名'),
    ),
    const SizedBox(height: 12),
    const TextField(
      obscureText: true,
      decoration: InputDecoration(labelText: '密码'),
    ),
    const SizedBox(height: 20),
    SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(onPressed: () {}, child: const Text('登录')),
    ),
    const SizedBox(height: 12),
    SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () {},
        icon: const Icon(Icons.key),
        label: const Text('使用通行密钥登录'),
      ),
    ),
    const SizedBox(height: 24),
    const Text(
      '连接由你掌控的服务器。登录凭证仅保存在本次会话内；刷新或关闭后需重新登录。',
      style: TextStyle(fontSize: 12, height: 1.6),
    ),
  ],
);

Future<void> _showLogin(
  WidgetTester tester,
  Size size, {
  Map<String, Object>? metadata,
  bool includeDownload = true,
  double textScale = 1,
  GlobalKey? captureKey,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final client = MockClient((request) async {
    expect(request.url.host, 'fixture.invalid');
    expect(request.url.path, '/downloads/android/manifest.json');
    return http.Response(jsonEncode(metadata ?? _syntheticDownload()), 200);
  });
  addTearDown(client.close);
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily: 'NotoSansSC',
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff0b57d0),
            surface: Colors.white,
          ),
          scaffoldBackgroundColor: const Color(0xfff5f7fb),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: ResponsiveLoginLayout(
            login: _loginForm(),
            download: includeDownload
                ? AndroidDownloadCard(
                    origin: Uri.parse('https://fixture.invalid'),
                    client: client,
                    openDownload: (_) async => true,
                  )
                : null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('1440x900 separates login and APK into bounded wide panes', (
    tester,
  ) async {
    await _showLogin(tester, const Size(1440, 900));

    final login = tester.getRect(find.byKey(const Key('login-form-pane')));
    final download = tester.getRect(
      find.byKey(const Key('login-download-pane')),
    );
    final layout = tester.getRect(find.byKey(const Key('login-wide-layout')));
    expect(login.width, 410);
    expect(download.width, 410);
    expect(layout.width, 980);
    expect(layout.center.dx, 720);
    expect(login.top, download.top);
    expect(login.right, lessThan(download.left));
    expect(find.byKey(const Key('login-pane-divider')), findsOneWidget);
    expect(
      find.byKey(const Key('android-installation-expander')),
      findsNothing,
    );
    expect(find.byKey(const Key('android-installation-steps')), findsOneWidget);
    expect(
      find.byKey(const Key('android-development-warning')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // Long SHA-256 values must not widen the card or either form input.
    await tester.tap(find.text('校验文件与签名'));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件 SHA-256'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('synthetic-username'))).width,
      410,
    );
    expect(
      tester.getSize(find.byKey(const Key('login-download-pane'))).width,
      410,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '390x844 stacks panes and folds instructions but never warnings',
    (tester) async {
      await _showLogin(tester, const Size(390, 844));

      final login = tester.getRect(find.byKey(const Key('login-form-pane')));
      final download = tester.getRect(
        find.byKey(const Key('login-download-pane')),
      );
      expect(login.width, 342);
      expect(download.width, 342);
      expect(login.left, download.left);
      expect(download.top, greaterThan(login.bottom));
      expect(find.byKey(const Key('login-pane-divider')), findsNothing);
      expect(find.byKey(const Key('android-installation-steps')), findsNothing);
      expect(
        find.byKey(const Key('android-development-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('保留现有 App 和本地数据'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final warning = find.byKey(const Key('android-development-warning'));
      await tester.ensureVisible(warning);
      expect(warning.hitTestable(), findsOneWidget);
      final instructions = find.byKey(
        const Key('android-installation-expander'),
      );
      await tester.ensureVisible(instructions);
      await tester.tap(find.text('安装与连接说明'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('android-installation-steps')),
        findsOneWidget,
      );
      expect(find.textContaining('安装后关闭该权限'), findsOneWidget);
      expect(find.textContaining('核对设备与验证码并批准'), findsOneWidget);
      expect(warning, findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('校验文件与签名'));
      await tester.tap(find.text('校验文件与签名'));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件 SHA-256'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('synthetic-username'))).width,
        342,
      );
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(instructions);
      await tester.tap(find.text('安装与连接说明'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('android-installation-steps')), findsNothing);
      expect(warning, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a desktop without download keeps a centered 410px login form', (
    tester,
  ) async {
    await _showLogin(tester, const Size(1440, 900), includeDownload: false);
    final login = tester.getRect(find.byKey(const Key('login-form-pane')));
    expect(login.width, 410);
    expect(login.center.dx, 720);
    expect(find.byKey(const Key('login-download-pane')), findsNothing);
    expect(find.byKey(const Key('login-pane-divider')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short wide viewport scrolls without stretching login controls', (
    tester,
  ) async {
    await _showLogin(tester, const Size(960, 400));
    expect(find.byKey(const Key('login-wide-layout')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('synthetic-username'))).width,
      410,
    );
    await tester.ensureVisible(find.text('校验文件与签名'));
    expect(find.text('校验文件与签名').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small mobile and enlarged text can reach download safely', (
    tester,
  ) async {
    await _showLogin(tester, const Size(320, 720), textScale: 1.5);
    await tester.ensureVisible(
      find.byKey(const Key('android-download-button')),
    );
    expect(
      find.byKey(const Key('android-download-button')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('android-development-warning')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable APK state cannot change desktop login width', (
    tester,
  ) async {
    await _showLogin(
      tester,
      const Size(1440, 900),
      metadata: {'schemaVersion': 1, 'available': false},
    );
    expect(find.textContaining('尚未包含已验证'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('synthetic-username'))).width,
      410,
    );
    expect(find.byKey(const Key('android-download-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders deterministic synthetic login layout previews', (
    tester,
  ) async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.otf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final size in [const Size(1440, 900), const Size(390, 844)]) {
      final key = GlobalKey();
      await _showLogin(tester, size, captureKey: key);
      expect(tester.takeException(), isNull);
      // These are synthetic widget renders, not a real browser/session capture.
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'build/previews/login-layout-${size.width.toInt()}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
