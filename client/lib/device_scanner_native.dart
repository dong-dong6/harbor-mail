import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

// Phase A only ships the Android camera integration. Do not request iOS/macOS
// camera access before those targets have their own native QA and entitlements.
bool get supportsDeviceScanner =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<String?> scanPairingCode(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DeviceScannerPage()),
    );

class DeviceScannerPage extends StatefulWidget {
  const DeviceScannerPage({super.key});

  @override
  State<DeviceScannerPage> createState() => _DeviceScannerPageState();
}

class _DeviceScannerPageState extends State<DeviceScannerPage>
    with WidgetsBindingObserver {
  MobileScannerController? _controller;
  bool _returned = false;
  bool _scanFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (supportsDeviceScanner) {
      _controller = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
        returnImage: false,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed && !_returned && !_scanFailed) {
      unawaited(controller.start().catchError((Object _) {
        if (mounted) setState(() => _scanFailed = true);
      }));
    } else if (state != AppLifecycleState.resumed) {
      unawaited(controller.stop().catchError((Object _) {}));
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_returned || !mounted) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _returned = true;
        // Only return the raw content. The onboarding screen validates it and
        // asks the user to confirm the destination before making any request.
        unawaited(_controller?.stop());
        Navigator.of(context).pop(value);
        break;
      }
    }
  }

  @override
  void dispose() {
    _returned = true;
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  Widget _fallback(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回并粘贴配对内容'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('扫描配对二维码')),
      body: controller == null
          ? _fallback('此平台暂不支持相机扫描。请使用 Android App，或粘贴配对内容。')
          : _scanFailed
              ? _fallback('无法读取相机画面。请检查相机权限，或粘贴配对内容。')
              : Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('将网页“设备登录”中的二维码放入画面。扫描后会先显示服务器地址，确认后才连接。'),
                    ),
                    Expanded(
                      child: MobileScanner(
                        controller: controller,
                        // This route owns lifecycle for its external controller.
                        useAppLifecycleState: false,
                        onDetect: _onDetect,
                        onDetectError: (_, __) {
                          if (mounted && !_returned) {
                            setState(() => _scanFailed = true);
                            unawaited(controller.stop());
                          }
                        },
                        errorBuilder: (_, error) => _fallback(
                          error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied
                              ? '未获得相机权限。可在系统设置中允许相机，或返回粘贴配对内容。'
                              : '相机暂不可用。请返回并粘贴配对内容。',
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
