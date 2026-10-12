import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'login_layout.dart';

const _manifestPath = '/downloads/android/manifest.json';
const _apkPath = '/downloads/android/app.apk';
const _maxManifestBytes = 64 * 1024;

/// Public build information contains no session, pairing secret, or local path.
class AndroidDownloadManifest {
  final bool available;
  final String versionName, sha256, certificateSha256, releaseNotes;
  final int versionCode, sizeBytes;

  const AndroidDownloadManifest._({
    required this.available,
    this.versionName = '',
    this.versionCode = 0,
    this.sizeBytes = 0,
    this.sha256 = '',
    this.certificateSha256 = '',
    this.releaseNotes = '',
  });

  factory AndroidDownloadManifest.parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] is! int ||
        value['schemaVersion'] != 1 ||
        value['available'] is! bool) {
      throw const FormatException('Invalid download metadata');
    }
    if (value['available'] == false) {
      return const AndroidDownloadManifest._(available: false);
    }
    final version = value['versionName'];
    final code = value['versionCode'];
    final size = value['sizeBytes'];
    final hash = value['sha256'];
    final signing = value['signing'];
    final notes = value.containsKey('releaseNotes')
        ? value['releaseNotes']
        : '';
    if (notes is! String || notes.runes.length > 4000) {
      throw const FormatException('Invalid release notes');
    }
    final certificate = signing is Map ? signing['certificateSha256'] : null;
    if (value['downloadPath'] != _apkPath ||
        value['fileName'] != 'harbor-mail-dev.apk' ||
        value['packageName'] != 'dev.harbor.harbor_mail.dev' ||
        version is! String ||
        version.length > 64 ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        code is! int ||
        code < 1 ||
        code > 2100000000 ||
        size is! int ||
        size < 1 ||
        size > 256 * 1024 * 1024 ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        signing is! Map ||
        signing['classification'] != 'development-debug' ||
        certificate is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(certificate)) {
      throw const FormatException('Unverified download metadata');
    }
    return AndroidDownloadManifest._(
      available: true,
      versionName: version,
      versionCode: code,
      sizeBytes: size,
      sha256: hash,
      certificateSha256: certificate,
      releaseNotes: notes,
    );
  }
}

/// All requests and download links stay on the Web page's own origin.
/// [origin], [client] and [openDownload] are injectable for isolated UI tests.
class AndroidDownloadCard extends StatefulWidget {
  final Uri? origin;
  final http.Client? client;
  final Future<bool> Function(Uri)? openDownload;
  final bool? compactInstructions;

  const AndroidDownloadCard({
    super.key,
    this.origin,
    this.client,
    this.openDownload,
    this.compactInstructions,
  });

  @override
  State<AndroidDownloadCard> createState() => _AndroidDownloadCardState();
}

class _AndroidDownloadCardState extends State<AndroidDownloadCard> {
  late http.Client _client;
  late bool _ownsClient;
  AndroidDownloadManifest? _manifest;
  String? _error;
  bool _loading = true, _opening = false;
  int _generation = 0;
  Completer<void>? _abort;
  Timer? _deadline;

  Uri get _origin {
    final value = widget.origin ?? Uri.base;
    if (!['http', 'https'].contains(value.scheme) ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty) {
      throw const FormatException('A Web origin is required');
    }
    return value.replace(path: '/', query: null, fragment: null);
  }

  @override
  void initState() {
    super.initState();
    _setClient();
    _load();
  }

  void _setClient() {
    _ownsClient = widget.client == null;
    _client = widget.client ?? http.Client();
  }

  @override
  void didUpdateWidget(covariant AndroidDownloadCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.origin != widget.origin ||
        oldWidget.client != widget.client) {
      _generation++;
      if (_ownsClient) _client.close();
      _setClient();
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    _cancelRequest();
    if (_ownsClient) _client.close();
    super.dispose();
  }

  void _cancelRequest() {
    _deadline?.cancel();
    _deadline = null;
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _abort = null;
  }

  Future<AndroidDownloadManifest> _fetch(Uri url, Future<void> abort) async {
    // Do not use MailApi.request: this public request must never carry a bearer token.
    final request = http.AbortableRequest('GET', url, abortTrigger: abort)
      ..followRedirects = false;
    final response = await _client.send(request);
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > _maxManifestBytes) {
      // Cancel the rejected response without waiting for a remote stream's close
      // acknowledgement before updating the UI. The request aborts in finally.
      unawaited(
        response.stream.listen((_) {}).cancel().catchError((Object _) {}),
      );
      throw const FormatException('Download metadata unavailable');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > _maxManifestBytes) {
        throw const FormatException('Download metadata too large');
      }
      bytes.addAll(chunk);
    }
    return AndroidDownloadManifest.parse(jsonDecode(utf8.decode(bytes)));
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _cancelRequest();
    final abort = Completer<void>();
    _abort = abort;
    final deadline = Timer(const Duration(seconds: 12), () {
      if (!abort.isCompleted) abort.complete();
      if (mounted && generation == _generation) {
        _generation++;
        setState(() {
          _loading = false;
          _error = '暂时无法检查 APK，请稍后重试。';
        });
      }
    });
    _deadline = deadline;
    setState(() {
      _loading = true;
      _opening = false;
      _error = null;
      _manifest = null;
    });
    try {
      final manifest = await _fetch(
        _origin.resolve(_manifestPath),
        abort.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _manifest = manifest;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '暂时无法检查 APK，请稍后重试。';
      });
    } finally {
      deadline.cancel();
      if (identical(_deadline, deadline)) _deadline = null;
      if (!abort.isCompleted) abort.complete();
      if (identical(_abort, abort)) _abort = null;
    }
  }

  Future<void> _download() async {
    if (_opening || _manifest?.available != true) return;
    final generation = _generation;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final url = _origin.resolve(_apkPath);
      final opened =
          await (widget.openDownload?.call(url) ??
              launchUrl(
                url,
                mode: LaunchMode.externalApplication,
                webOnlyWindowName: '_blank',
              ));
      if (!opened) throw StateError('Download not opened');
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '浏览器未能打开下载，请允许此次下载后重试。');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final compactInstructions =
        widget.compactInstructions ??
        MediaQuery.sizeOf(context).width < ResponsiveLoginLayout.wideBreakpoint;
    const installationSteps = Column(
      key: Key('android-installation-steps'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('安装：下载后打开 APK，仅为此次使用的浏览器或文件管理器允许安装来源，安装后关闭该权限。'),
        SizedBox(height: 8),
        Text('安装并打开 App 后，扫描网页“连接设备”二维码，再在网页核对设备与验证码并批准。'),
      ],
    );
    return Card(
      key: const Key('android-download-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '下载 Android APK',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Text('正在检查此服务器提供的 Android 构建…')
            else if (manifest?.available != true && _error == null)
              const Text('此服务器尚未包含已验证的 APK。构建完成并更新服务后即可下载。'),
            if (manifest?.available == true) ...[
              Text(
                '版本 ${manifest!.versionName} (${manifest.versionCode}) · '
                '${(manifest.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
              ),
              const SizedBox(height: 8),
              const Text(
                '开发测试版 · Android 调试签名。请使用测试账号；不要用于正式邮件。',
                key: Key('android-development-warning'),
              ),
              const Text(
                '仅适用于 Android。不同 CI 构建的签名可能变化，导致无法覆盖更新。请保留现有 App 和本地数据，联系管理员确认兼容版本。',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('android-download-button'),
                onPressed: _opening ? null : _download,
                icon: const Icon(Icons.download),
                label: Text(_opening ? '正在打开…' : '下载测试 APK'),
              ),
              const SizedBox(height: 8),
              if (compactInstructions)
                const ExpansionTile(
                  key: Key('android-installation-expander'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.only(bottom: 12),
                  title: Text('安装与连接说明'),
                  children: [installationSteps],
                )
              else
                installationSteps,
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('校验文件与签名'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      '文件 SHA-256\n${manifest.sha256}\n\n签名证书 SHA-256\n${manifest.certificateSha256}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              Text(_error!, key: const Key('android-download-error')),
              TextButton(
                onPressed: _loading ? null : _load,
                child: const Text('重新检查 APK'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
