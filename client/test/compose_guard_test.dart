import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/main.dart';

Future<void> openComposer(WidgetTester tester, MailApi api,
    {VoidCallback? onStatus}) async {
  tester.view.physicalSize = const Size(1000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => ComposeDialog(
                          api: api,
                          accounts: const [
                            {'id': 'demo', 'email': 'demo@example.invalid'}
                          ],
                          maxBytes: 10485760,
                          onSaved: (_) {},
                          onViewStatus: onStatus)),
                  child: const Text('Open'))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'dirty draft close, Escape and back confirm; cancel preserves text without saving',
      (tester) async {
    var requests = 0;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }));
    await openComposer(tester, api);
    await tester.enterText(
        find.byType(TextField).last, 'Unsaved synthetic draft');
    await tester.tap(find.byTooltip('关闭写信窗口'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved synthetic draft'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved synthetic draft'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭写信窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(find.text('写一封邮件'), findsNothing);
    expect(requests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'save pending disables all implicit dismissal; successful save clears dirty flag',
      (tester) async {
    final pending = Completer<http.Response>();
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((_) => pending.future));
    await openComposer(tester, api);
    await tester.enterText(
        find.byType(TextField).last, 'Persisted synthetic draft');
    await tester.tap(find.text('保存草稿'));
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '关闭写信窗口'))
            .onPressed,
        isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('放弃未保存的更改？'), findsNothing);
    expect(find.text('写一封邮件'), findsOneWidget);
    pending.complete(http.Response('{"id":"d1","revision":1}', 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭写信窗口'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsNothing);
    expect(find.text('写一封邮件'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'uncertain send blocks close, Escape, back and resend; explicit status exit remains available',
      (tester) async {
    var sends = 0;
    var viewedStatus = false;
    final api = MailApi(
        base: 'https://mail.invalid/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/send')) {
            sends++;
            throw http.ClientException('Synthetic transport interruption');
          }
          return http.Response(jsonEncode({'id': 'd1', 'revision': 1}), 200);
        }));
    await openComposer(tester, api, onStatus: () => viewedStatus = true);
    await tester.enterText(
        find.byType(TextField).first, 'recipient@example.invalid');
    await tester.enterText(
        find.byType(TextField).last, 'Synthetic unknown result');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('提交结果暂不确定'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '关闭写信窗口'))
            .onPressed,
        isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('写一封邮件'), findsOneWidget);
    expect(find.text('放弃未保存的更改？'), findsNothing);
    expect(sends, 1);
    await tester.tap(find.text('关闭并查看发件状态'));
    await tester.pumpAndSettle();
    expect(find.text('写一封邮件'), findsNothing);
    expect(viewedStatus, isTrue);
    expect(sends, 1);
    expect(tester.takeException(), isNull);
  });
}
