import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/mail_body.dart';

void main() {
  testWidgets('non-web reader retains selectable plaintext fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MailBody(html: '<h1>HTML</h1>', text: 'Plain alternative'),
        ),
      ),
    );
    expect(find.text('Plain alternative'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('<h1>HTML</h1>'), findsNothing);
  });
  testWidgets('missing plaintext has explicit fallback explanation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MailBody(html: '<p>HTML only</p>', text: ''),
        ),
      ),
    );
    expect(find.textContaining('Web 版'), findsOneWidget);
  });
}
