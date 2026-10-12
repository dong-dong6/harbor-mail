import 'package:flutter/material.dart';

/// Explicit, separate controls for the current display lock and encrypted
/// restart recovery. Neither switch is enabled by opening this page.
class DeviceSecurityCard extends StatelessWidget {
  const DeviceSecurityCard({
    super.key,
    required this.lockSupported,
    required this.lockEnabled,
    required this.storageSupported,
    required this.storageEnabled,
    required this.busy,
    required this.onLockChanged,
    required this.onStorageChanged,
    this.expiresAt,
    this.idleExpiresAt,
    this.durable = false,
    this.message,
  });
  final bool lockSupported, lockEnabled, storageSupported, storageEnabled, busy;
  final ValueChanged<bool> onLockChanged, onStorageChanged;
  final DateTime? expiresAt, idleExpiresAt;
  final bool durable;
  final String? message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设备安全与登录', style: Theme.of(context).textTheme.titleMedium),
          if (lockSupported)
            SwitchListTile.adaptive(
              key: const Key('device-lock-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('指纹 / 系统验证锁'),
              subtitle: Text(
                durable
                    ? '默认关闭。开启并通过系统加密验证后，返回应用或重启需验证。自动续期不会每 15 分钟要求验证。'
                    : '默认关闭。手动开启并通过首次验证后，返回应用需要系统验证。使用系统已录入的指纹或设备密码。',
              ),
              value: lockEnabled,
              onChanged: busy ? null : onLockChanged,
            ),
          if (durable) ...[
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.verified_user_outlined),
              title: Text('此设备已记住登录'),
              subtitle: Text(
                '已加密保存，自动续期。默认连续 30 天未使用或满 365 天需重新登录。退出登录会删除本机凭证并请求撤销服务器访问权限。',
              ),
            ),
            if (idleExpiresAt != null)
              Text(
                '未继续使用时到期：${idleExpiresAt!.toLocal().toString().split('.').first}',
              ),
          ],
          if (storageSupported && !durable)
            SwitchListTile.adaptive(
              key: const Key('saved-session-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('安全保存本次登录'),
              subtitle: const Text(
                '默认关闭。明确开启并通过系统验证后，将现有会话加密保存在此设备；重启后可验证恢复。不保存密码，不延长服务器的 8 小时有效期。需要 Android 11 或更新版本。',
              ),
              value: storageEnabled,
              onChanged: busy ? null : onStorageChanged,
            ),
          if (storageSupported && expiresAt != null)
            Text(
              '${durable ? '最晚重新登录日期' : '本次登录到期'}：${expiresAt!.toLocal().toString().split('.').first}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (message?.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message!),
            ),
        ],
      ),
    ),
  );
}
