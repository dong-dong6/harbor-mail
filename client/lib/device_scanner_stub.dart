import 'package:flutter/material.dart';

bool get supportsDeviceScanner => false;

Future<String?> scanPairingCode(BuildContext context) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DeviceScannerPage()),
    );

class DeviceScannerPage extends StatelessWidget {
  const DeviceScannerPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('扫描配对二维码')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('此平台暂不支持相机扫描。请返回并粘贴配对内容，或使用 Android App 扫码。'),
          ),
        ),
      );
}
