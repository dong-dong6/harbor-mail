package dev.harbor.harbor_mail;

import android.Manifest;
import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.provider.Settings;
import java.util.Map;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Local arrival reminders only. No background worker, vendor SDK or mail data. */
public final class MailNotificationBridge implements MethodChannel.MethodCallHandler {
    public static final int PERMISSION_REQUEST = 4102;
    private static final int NOTIFICATION_ID = 4101;
    private static final String CHANNEL_ID = "mail_arrivals";
    private final Activity activity;
    private final NotificationManager manager;
    private final SharedPreferences preferences;
    private final MethodChannel channel;
    private MethodChannel.Result permissionResult;

    public MailNotificationBridge(Activity activity, BinaryMessenger messenger) {
        this.activity = activity;
        manager = (NotificationManager) activity.getSystemService(Activity.NOTIFICATION_SERVICE);
        preferences = activity.getSharedPreferences("mail_notifications", Activity.MODE_PRIVATE);
        channel = new MethodChannel(messenger, "harbor/mail_notifications");
        channel.setMethodCallHandler(this);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel category = new NotificationChannel(CHANNEL_ID, "新邮件", NotificationManager.IMPORTANCE_DEFAULT);
            category.setDescription("应用同步到新邮件后的提醒，不包含邮件内容");
            category.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
            manager.createNotificationChannel(category);
        }
    }

    private boolean allowed() {
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false;
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel category = manager.getNotificationChannel(CHANNEL_ID);
            if (category == null || category.getImportance() == NotificationManager.IMPORTANCE_NONE) return false;
        }
        return true;
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
            case "status":
                result.success(Map.of("enabled", preferences.getBoolean("enabled", false), "allowed", allowed()));
                return;
            case "consumeOpen":
                Intent current = activity.getIntent();
                boolean opened = current != null && current.getBooleanExtra("harbor.notification.open", false);
                if (current != null) current.removeExtra("harbor.notification.open");
                result.success(opened);
                return;
            case "setEnabled":
                if (permissionResult != null) { result.error("BUSY", "通知权限确认尚未结束", null); return; }
                boolean enabled = Boolean.TRUE.equals(call.argument("enabled"));
                if (!enabled) {
                    preferences.edit().putBoolean("enabled", false).apply();
                    manager.cancel(NOTIFICATION_ID);
                    result.success(null);
                } else if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    permissionResult = result;
                    activity.requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, PERMISSION_REQUEST);
                } else {
                    preferences.edit().putBoolean("enabled", true).apply();
                    result.success(null);
                }
                return;
            case "show":
                Number count = call.argument("count");
                if (count != null && count.intValue() > 0 && preferences.getBoolean("enabled", false) && allowed()) {
                    Intent launch = activity.getPackageManager().getLaunchIntentForPackage(activity.getPackageName());
                    if (launch != null) {
                        // The normal app entry enforces login and the device lock.
                        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                        launch.putExtra("harbor.notification.open", true);
                        PendingIntent pending = PendingIntent.getActivity(activity, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
                        Notification.Builder builder = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(activity, CHANNEL_ID) : new Notification.Builder(activity);
                        builder.setSmallIcon(R.drawable.ic_mail_notification)
                            .setContentTitle("泊信 · 新邮件")
                            .setContentText("有新邮件，打开泊信查看")
                            .setContentIntent(pending).setAutoCancel(true)
                            .setVisibility(Notification.VISIBILITY_PRIVATE)
                            .setCategory(Notification.CATEGORY_EMAIL);
                        manager.notify(NOTIFICATION_ID, builder.build());
                    }
                }
                result.success(null);
                return;
            case "clear":
                manager.cancel(NOTIFICATION_ID);
                result.success(null);
                return;
            case "openSettings":
                Intent settings = new Intent(Build.VERSION.SDK_INT >= 26 ? Settings.ACTION_APP_NOTIFICATION_SETTINGS : Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                if (Build.VERSION.SDK_INT >= 26) settings.putExtra(Settings.EXTRA_APP_PACKAGE, activity.getPackageName());
                else settings.setData(android.net.Uri.parse("package:" + activity.getPackageName()));
                activity.startActivity(settings);
                result.success(null);
                return;
            default: result.notImplemented();
        }
    }

    public void onPermissionResult(int requestCode, int[] grants) {
        if (requestCode != PERMISSION_REQUEST || permissionResult == null) return;
        boolean granted = grants.length > 0 && grants[0] == PackageManager.PERMISSION_GRANTED;
        preferences.edit().putBoolean("enabled", granted).apply();
        MethodChannel.Result pending = permissionResult;
        permissionResult = null;
        pending.success(null);
    }

    public void detach() {
        channel.setMethodCallHandler(null);
        if (permissionResult != null) {
            permissionResult.error("CLOSED", "通知权限确认已中断", null);
            permissionResult = null;
        }
    }
}
