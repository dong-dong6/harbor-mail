import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/compose_editor.dart';
import 'package:harbor_mail/mail_header.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const accounts = <Map<String, dynamic>>[
  {'id': 'a', 'email': 'me@example.invalid'},
];
const mail = <String, dynamic>{
  'id': 'm',
  'accountId': 'a',
  'fromAddress': 'sender@example.invalid',
  'to': [
    {'address': 'me@example.invalid'},
  ],
  'cc': [
    {'name': 'Other', 'address': 'other@example.invalid'},
  ],
  'subject': 'Synthetic subject',
  'bodyText': 'Original synthetic quote',
  'receivedAt': '2026-10-01T08:00:00Z',
};
Future<void> mount(
  WidgetTester tester,
  MailApi api, {
  GlobalKey<ComposeEditorState>? key,
  Map<String, dynamic> message = mail,
  bool forward = false,
  double width = 1000,
  VoidCallback? close,
  VoidCallback? status,
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ComposeEditor(
            key: key,
            api: api,
            accounts: accounts,
            reply: message,
            forward: forward,
            inline: true,
            maxBytes: 10485760,
            onSaved: (_) {},
            onClose: close,
            onViewStatus: status,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'reply is inline, fields editable, quote collapsed, own-sent targets original To',
    (tester) async {
      final api = MailApi(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await mount(
        tester,
        api,
        message: {
          ...mail,
          'fromAddress': 'me@example.invalid',
          'to': [
            {'address': 'original-recipient@example.invalid'},
          ],
        },
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const Key('inline-compose')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '收件人'))
            .controller!
            .text,
        'original-recipient@example.invalid',
      );
      expect(find.textContaining('Original synthetic quote'), findsNothing);
      await tester.tap(find.byKey(const Key('toggle-quoted-message')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Original synthetic quote'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '主题'),
        'Edited subject',
      );
      expect(find.text('Edited subject'), findsOneWidget);
    },
  );
  testWidgets(
    'inline unsaved, busy and uncertain states all block implicit navigation',
    (tester) async {
      final key = GlobalKey<ComposeEditorState>();
      final save = Completer<http.Response>();
      var saveCount = 0, sends = 0, closed = false, viewed = false;
      final api = MailApi(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/send')) {
            sends++;
            throw http.ClientException('synthetic interruption');
          }
          if (++saveCount == 1) return save.future;
          return http.Response('{"id":"d","revision":2}', 200);
        }),
      );
      await mount(
        tester,
        api,
        key: key,
        close: () => closed = true,
        status: () => viewed = true,
      );
      await tester.enterText(
        find.byType(TextField).last,
        'Unsaved synthetic body',
      );
      final leaving = key.currentState!.canLeave();
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(await leaving, isFalse);
      await tester.tap(find.text('保存草稿'));
      await tester.pump();
      expect(await key.currentState!.canLeave(), isFalse);
      save.complete(http.Response('{"id":"d","revision":1}', 200));
      await tester.pumpAndSettle();
      expect(await key.currentState!.canLeave(), isTrue);
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(await key.currentState!.canLeave(), isFalse);
      await tester.tap(find.text('发送').last);
      await tester.pumpAndSettle();
      expect(await key.currentState!.canLeave(), isFalse);
      expect(sends, 1);
      expect(closed, isFalse);
      await tester.tap(find.text('关闭并查看发件状态'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(viewed, isTrue);
      expect(sends, 1);
    },
  );
  testWidgets(
    'forward keeps recipient empty and stores quoted body with edited content',
    (tester) async {
      Map<String, dynamic>? payload;
      final api = MailApi(
        client: MockClient((r) async {
          payload = jsonDecode(r.body);
          return http.Response('{"id":"d","revision":1}', 200);
        }),
      );
      await mount(tester, api, forward: true);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '收件人'))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(find.byType(TextField).last, 'New intro');
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(payload!['bodyText'], contains('New intro'));
      expect(payload!['bodyText'], contains('Original synthetic quote'));
      expect(payload!.containsKey('replyToMessageId'), isFalse);
    },
  );
  for (final width in [320.0, 390.0]) {
    testWidgets('inline editor and complete header fit ${width.toInt()}px', (
      tester,
    ) async {
      final api = MailApi(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await mount(tester, api, width: width);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: MailHeader(message: mail),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('发件人：sender@example.invalid'), findsOneWidget);
      expect(find.textContaining('收件人：me@example.invalid'), findsNothing);
      await tester.tap(find.text('收件详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('收件人：me@example.invalid'), findsOneWidget);
      expect(
        find.textContaining('抄送：Other <other@example.invalid>'),
        findsOneWidget,
      );
      expect(find.textContaining('接收时间：2026-10-01'), findsOneWidget);
    });
  }
}
