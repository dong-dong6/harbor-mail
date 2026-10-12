import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/device_security_card.dart';

void main() {
  testWidgets('opening device security never enables either setting', (
    t,
  ) async {
    var lockCalls = 0, saveCalls = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DeviceSecurityCard(
              lockSupported: true,
              lockEnabled: false,
              storageSupported: true,
              storageEnabled: false,
              busy: false,
              onLockChanged: (_) => lockCalls++,
              onStorageChanged: (_) => saveCalls++,
            ),
          ),
        ),
      ),
    );
    expect(lockCalls, 0);
    expect(saveCalls, 0);
    expect(
      t
          .widget<SwitchListTile>(find.byKey(const Key('device-lock-switch')))
          .value,
      isFalse,
    );
    expect(
      t
          .widget<SwitchListTile>(find.byKey(const Key('saved-session-switch')))
          .value,
      isFalse,
    );
    await t.tap(find.byKey(const Key('device-lock-switch')));
    expect(lockCalls, 1);
    expect(saveCalls, 0);
  });
}
