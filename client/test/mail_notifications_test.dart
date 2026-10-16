import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/mail_notifications.dart';

Map<String, dynamic> mail(String id, int minute, {bool read = false}) => {
  'id': id,
  'receivedAt': '2026-10-16T08:${minute.toString().padLeft(2, '0')}:00Z',
  'isRead': read,
};

void main() {
  test('initial history is silent, only newer unread arrivals notify once', () {
    final tracker = MailArrivalTracker();
    expect(tracker.observe('', [mail('old', 10)]), 0);
    expect(tracker.observe('', [mail('new', 11), mail('old', 10)]), 1);
    expect(tracker.observe('', [mail('new', 11)]), 0);
    expect(tracker.observe('', [mail('older-history', 2)]), 0);
    expect(tracker.observe('', [mail('already-read', 12, read: true)]), 0);
    tracker.clear();
    expect(tracker.observe('', [mail('new', 11)]), 0);
  });

  test(
    'empty inbox establishes a baseline and scopes do not replay arrivals',
    () {
      final tracker = MailArrivalTracker();
      expect(tracker.observe('', []), 0);
      expect(tracker.observe('', [mail('first', 10)]), 1);
      expect(tracker.observe('account-a', [mail('first', 10)]), 0);
      expect(tracker.observe('account-a', [mail('second', 11)]), 1);
      expect(tracker.observe('', [mail('second', 11)]), 0);
    },
  );

  testWidgets(
    'permission is requested only by explicit switch and denial stays off',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MailNotifications.channel,
        (call) async {
          calls.add(call.method);
          if (call.method == 'status') {
            return {'enabled': false, 'allowed': false};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MailNotifications.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MailNotificationSettings())),
      );
      await tester.pumpAndSettle();
      expect(calls, ['status']);
      await tester.tap(find.byKey(const Key('mail-notifications-switch')));
      await tester.pumpAndSettle();
      expect(calls, ['status', 'setEnabled', 'status']);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'native payload contains only count and missing/denied native hosts do not fail sync',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MailNotifications.channel, (
        call,
      ) async {
        if (call.method == 'show') {
          expect(call.arguments, {'count': 2});
          throw PlatformException(code: 'DENIED');
        }
        if (call.method == 'consumeOpen') return true;
        return null;
      });
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(MailNotifications.channel, null),
      );
      await MailNotifications.show(2);
      expect(await MailNotifications.takeOpen(), isTrue);
      await MailNotifications.clear();
    },
  );
}
