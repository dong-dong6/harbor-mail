package dev.harbor.harbor_mail

import android.content.Intent

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private var sessionVault: SessionVaultBridge? = null
    private var deviceSessionVault: DeviceSessionVaultBridge? = null
    private var deviceInfo: DeviceInfoBridge? = null
    private var updates: AndroidUpdateBridge? = null
    private var notifications: MailNotificationBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updates = AndroidUpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        sessionVault = SessionVaultBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        deviceSessionVault = DeviceSessionVaultBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        deviceInfo = DeviceInfoBridge(flutterEngine.dartExecutor.binaryMessenger)
        notifications = MailNotificationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        notifications?.onPermissionResult(requestCode, grantResults)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        notifications?.detach()
        notifications = null
        deviceSessionVault?.detach()
        deviceSessionVault = null
        sessionVault?.detach()
        sessionVault = null
        deviceInfo?.detach()
        deviceInfo = null
        updates?.detach()
        updates = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
