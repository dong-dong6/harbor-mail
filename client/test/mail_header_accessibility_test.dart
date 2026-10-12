import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/mail_header.dart';

void main() {
  testWidgets('selectable header exposes complete accessible labels',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: MailHeader(message: {
      'subject': 'Accessible subject',
      'fromName': 'Sender',
      'fromAddress': 'sender@example.invalid',
      'to': [
        {'name': 'Recipient', 'address': 'recipient@example.invalid'}
      ],
      'cc': [
        {'name': 'Copy', 'address': 'copy@example.invalid'}
      ],
      'receivedAt': '2026-10-11T10:42:00Z',
    }))));
    expect(find.bySemanticsLabel('Accessible subject'), findsOneWidget);
    expect(find.bySemanticsLabel('发件人：Sender <sender@example.invalid>'),
        findsOneWidget);
    expect(find.bySemanticsLabel('收件人：Recipient <recipient@example.invalid>'),
        findsOneWidget);
    expect(find.bySemanticsLabel('抄送：Copy <copy@example.invalid>'),
        findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^接收时间：2026-10-11 ')), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(5));
    semantics.dispose();
  });
}
