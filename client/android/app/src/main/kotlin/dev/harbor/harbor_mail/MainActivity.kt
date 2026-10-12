package dev.harbor.harbor_mail

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private var sessionVault: SessionVaultBridge? = null
    private var deviceInfo: DeviceInfoBridge? = null
    private var updates: AndroidUpdateBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updates = AndroidUpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        sessionVault = SessionVaultBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        deviceInfo = DeviceInfoBridge(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        sessionVault?.detach()
        sessionVault = null
        deviceInfo?.detach()
        deviceInfo = null
        updates?.detach()
        updates = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
