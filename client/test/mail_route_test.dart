import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/mail_route.dart';

void main() {
  test('mail URLs roundtrip navigation context', () {
    const route = MailRoute(
      messageId: 'm_123-a',
      account: 'account-1',
      folder: 'Projects/中文',
      filter: 'unread',
    );
    final parsed = MailRoute.parse(route.location);
    expect(parsed.messageId, 'm_123-a');
    expect(parsed.account, 'account-1');
    expect(parsed.folder, 'Projects/中文');
    expect(parsed.filter, 'unread');
    expect(parsed.location, route.location);
  });
  test('settings have independent URLs', () {
    for (final leaf in ['accounts', 'add', 'oauth', 'devices', 'passkeys']) {
      expect(MailRoute.parse('/settings/$leaf').settings, leaf);
    }
  });
  test('old starred filter URLs become the single starred folder view', () {
    final route = MailRoute.parse('/mail?folder=SENT&filter=starred');
    expect(route.folder, 'STARRED');
    expect(route.filter, 'all');
    expect(route.location, '/mail?folder=STARRED');
  });
  test('draft and outbox URLs preserve the mailbox scope', () {
    for (final folder in ['DRAFTS', 'OUTBOX']) {
      final route = MailRoute.parse('/mail?account=a&folder=$folder');
      expect(route.folder, folder);
      expect(route.account, 'a');
    }
  });
  test('external and malformed paths cannot redirect or become API paths', () {
    for (final location in [
      'https://evil.invalid',
      '//evil.invalid',
      '/mail/../auth',
      '/mail/%2fadmin',
      '/mail/%00',
      '/mail/%',
      '/settings/unknown',
      '/mail/a?account=../admin',
      '/mail/a#fragment',
    ]) {
      expect(MailRoute.parse(location).location, '/mail', reason: location);
    }
  });
  test('only navigation allowlist survives serialization', () {
    expect(
      MailRoute.parse(
        '/mail/m1?token=secret&query=private&body=private',
      ).location,
      '/mail/m1',
    );
    expect(MailRoute.parse('/mail?filter=invalid').location, '/mail');
  });
}
