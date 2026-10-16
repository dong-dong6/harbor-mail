import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Only a generic arrival count crosses the platform boundary. Mail content,
/// credentials and message identifiers never enter a system notification.
class MailNotifications {
  static const channel = MethodChannel('harbor/mail_notifications');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<Map<String, dynamic>> status() async {
    if (!supported) return {};
    try {
      return Map<String, dynamic>.from(
        await channel.invokeMapMethod('status') ?? {},
      );
    } on PlatformException {
      return {};
    } on MissingPluginException {
      return {};
    }
  }

  static Future<void> show(int count) async {
    if (!supported || count == 0) return;
    try {
      await channel.invokeMethod('show', {'count': count});
    } on PlatformException {
      /* Notification denial must not fail mail sync. */
    } on MissingPluginException {
      /* Older native hosts may lack this channel. */
    }
  }

  static Future<void> clear() async {
    if (!supported) return;
    try {
      await channel.invokeMethod('clear');
    } on PlatformException {
      /* Best effort OS cleanup. */
    } on MissingPluginException {
      /* Older native host. */
    }
  }

  static Future<bool> takeOpen() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('consumeOpen') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// A new scope starts with a silent baseline. Old history and pagination cannot
/// become new arrivals; reading/star changes and repeated snapshots are silent.
class MailArrivalTracker {
  final _latest = <String, DateTime>{};
  final _seen = <String>{};
  int observe(String scope, List<Map<String, dynamic>> messages) {
    final baseline = _latest[scope];
    var latest = baseline;
    var count = 0;
    for (final m in messages) {
      final id = m['id']?.toString();
      final date = DateTime.tryParse(m['receivedAt']?.toString() ?? '');
      if (id == null || date == null) continue;
      if (baseline != null &&
          date.isAfter(baseline) &&
          !_seen.contains(id) &&
          m['isRead'] == false) {
        count++;
      }
      if (latest == null || date.isAfter(latest)) latest = date;
      _seen.add(id);
    }
    _latest[scope] =
        latest ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    // Only recent first-page identities are needed beyond the date watermarks.
    if (_seen.length > 5000) {
      _seen.removeAll(_seen.take(_seen.length - 2500).toList());
    }
    return count;
  }

  void clear() {
    _latest.clear();
    _seen.clear();
  }
}

class MailNotificationSettings extends StatefulWidget {
  const MailNotificationSettings({super.key});
  @override
  State<MailNotificationSettings> createState() =>
      _MailNotificationSettingsState();
}

class _MailNotificationSettingsState extends State<MailNotificationSettings>
    with WidgetsBindingObserver {
  Map<String, dynamic> state = {};
  bool busy = true;
  String error = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    final next = await MailNotifications.status();
    if (mounted) {
      setState(() {
        state = next;
        busy = false;
      });
    }
  }

  Future<void> toggle(bool enabled) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await MailNotifications.channel.invokeMethod('setEnabled', {
        'enabled': enabled,
      });
    } on PlatformException {
      if (mounted) setState(() => error = '通知设置未完成，请在系统设置中检查通知权限。');
    } on MissingPluginException {
      if (mounted) setState(() => error = '当前安装包尚不支持系统通知，请更新应用。');
    }
    await load();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('邮件通知', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile.adaptive(
            key: const Key('mail-notifications-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('新邮件系统提醒'),
            subtitle: const Text('应用运行并同步到新邮件时提醒。通知不显示发件人或正文。'),
            value: state['enabled'] == true,
            onChanged: busy || state.isEmpty ? null : toggle,
          ),
          if (state['enabled'] == true && state['allowed'] != true)
            const Text('系统已关闭通知权限，请在系统设置中允许泊信通知。'),
          if (error.isNotEmpty) Text(error),
          const Text(
            '后台推送尚未接入；退出应用后，不能保证即时到信提醒。',
            style: TextStyle(fontSize: 12),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    try {
                      await MailNotifications.channel.invokeMethod(
                        'openSettings',
                      );
                    } on PlatformException {
                      /* User can use Android settings manually. */
                    } on MissingPluginException {
                      /* Older native host. */
                    }
                    await load();
                  },
            child: const Text('打开系统通知设置'),
          ),
        ],
      ),
    ),
  );
}
