package dev.harbor.harbor_mail;

import android.os.Build;

import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Public hardware model labels only. No identifiers, permissions or stored data. */
public final class DeviceInfoBridge implements MethodChannel.MethodCallHandler {
    private final MethodChannel channel;

    public DeviceInfoBridge(BinaryMessenger messenger) {
        channel = new MethodChannel(messenger, "dev.harbor.mail/device_info");
        channel.setMethodCallHandler(this);
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!"modelInfo".equals(call.method)) {
            result.notImplemented();
            return;
        }
        Map<String, String> info = new HashMap<>();
        info.put("manufacturer", Build.MANUFACTURER);
        info.put("model", Build.MODEL);
        result.success(info);
    }

    public void detach() {
        channel.setMethodCallHandler(null);
    }
}
