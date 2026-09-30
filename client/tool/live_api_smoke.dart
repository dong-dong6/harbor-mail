// Real Dart HTTP-client contract check. Strictly local, synthetic DEMO only.
// Run: dart run tool/live_api_smoke.dart http://127.0.0.1:8080/api/v1
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:harbor_mail/api.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  final base = args.isEmpty
      ? Platform.environment['MAIL_API_BASE'] ?? 'http://127.0.0.1:8080/api/v1'
      : args.single;
  final uri = Uri.parse(base);
  check(['localhost', '127.0.0.1', '::1'].contains(uri.host),
      'Refusing non-loopback API host');
  check(
      ['http', 'https'].contains(uri.scheme) &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment,
      'Invalid API base');
  final api = MailApi(base: base.replaceFirst(RegExp(r'/$'), ''));
  final checks = <String>[];
  try {
    final health = await api.request('GET', '/health');
    check(health['demoMode'] == true,
        'Refusing non-demo server: demoMode must be true');
    checks.add('public health explicitly DEMO');
    await api.login(Platform.environment['MAIL_DEMO_USER'] ?? 'demo',
        Platform.environment['MAIL_DEMO_PASSWORD'] ?? 'demo-local-only');
    final caps = await api.request('GET', '/settings/capabilities');
    check(caps['demoMode'] == true,
        'Authenticated capabilities must also be DEMO');
    checks.add('in-memory bearer login');
    final accounts = (await api.request('GET', '/accounts'))['items'] as List;
    check(accounts.isNotEmpty, 'Demo account list is empty');
    final accountId = accounts.first['id'];
    final list = await api
        .request('GET', '/messages', query: {'folder': 'INBOX', 'limit': '5'});
    check(list['coverage'] == 'DEMO',
        'Refusing message coverage other than DEMO');
    final messages = list['items'] as List;
    check(messages.isNotEmpty, 'Demo inbox is empty');
    final detail =
        await api.request('GET', '/messages/${messages.first['id']}');
    check(detail['id'] == messages.first['id'] && detail['bodyText'] is String,
        'Message detail contract mismatch');
    checks.add('accounts/list/plain-text detail');
    final subject =
        'Synthetic Dart HTTP smoke ${DateTime.now().microsecondsSinceEpoch}';
    final draft = await api.request('POST', '/drafts', body: {
      'accountId': accountId,
      'to': [
        {'address': 'dart-smoke@example.invalid'}
      ],
      'subject': subject,
      'bodyText':
          'Synthetic integration test only. Never delivered to a real provider.',
    });
    check(draft['id'] != null && draft['revision'] is num,
        'Draft contract mismatch');
    final bytes = Uint8List.fromList(
        utf8.encode('Synthetic attachment, no private data.'));
    final attachment =
        await api.upload(draft['id'], 'synthetic-dart-smoke.txt', bytes);
    final downloaded = await api.download(attachment['id']);
    check(base64Encode(downloaded) == base64Encode(bytes),
        'Authenticated attachment bytes mismatch');
    final drafts = (await api.request('GET', '/drafts'))['items'] as List;
    final saved = drafts.singleWhere((d) => d['id'] == draft['id']);
    check(saved['revision'] > draft['revision'],
        'Attachment must increment revision');
    check(
        (saved['attachments'] as List).any((a) => a['id'] == attachment['id']),
        'Saved draft omits attachment metadata');
    checks.add('draft/upload/download/revision');
    final key = 'dart-smoke-${draft['id']}';
    final first = await api.request('POST', '/drafts/${draft['id']}/send',
        key: key, body: {'revision': saved['revision']});
    final repeated = await api.request('POST', '/drafts/${draft['id']}/send',
        key: key, body: {'revision': saved['revision']});
    check(first['id'] == repeated['id'],
        'Idempotent send generated a second intent');
    var terminal = '';
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      terminal =
          (await api.request('GET', '/send-intents/${first['id']}'))['status'];
      if (['ACCEPTED', 'SENT_COPY_CONFIRMED', 'FAILED', 'UNKNOWN']
          .contains(terminal)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    check(terminal == 'SENT_COPY_CONFIRMED',
        'Synthetic send did not reach confirmed local copy: $terminal');
    final intents =
        (await api.request('GET', '/send-intents'))['items'] as List;
    check(intents.where((e) => e['subject'] == subject).length == 1,
        'Expected exactly one send intent');
    checks.add('send idempotency and confirmed LOCAL synthetic copy');
    await api.request('POST', '/auth/logout');
    try {
      await api.request('GET', '/accounts');
      throw StateError('Revoked bearer token was accepted');
    } on ApiException catch (error) {
      check(api.token == null, '401 must clear in-memory token');
      check(error.code.isNotEmpty, 'Missing API error code');
    }
    checks.add('logout/revocation/token clear');
    stdout.writeln(jsonEncode(
        {'status': 'PASS', 'checks': checks, 'realProviderCalls': false}));
  } catch (error) {
    stderr.writeln('Dart live API smoke FAILED: $error');
    exitCode = 1;
  } finally {
    if (api.token != null) {
      try {
        await api.request('POST', '/auth/logout');
      } catch (_) {}
    }
    api.dispose();
  }
}
