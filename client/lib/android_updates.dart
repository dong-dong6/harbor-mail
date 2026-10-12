import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'android_downloads.dart';
import 'server_profile.dart';

/// Separate public transport: no MailApi, session token, or account mutation.
class AndroidUpdateService {
  AndroidUpdateService({http.Client? client, MethodChannel? channel})
    : _client = client ?? http.Client(),
      _channel = channel ?? const MethodChannel('dev.harbor.mail/updates');
  final http.Client _client;
  final MethodChannel _channel;
  Completer<void>? _abort;
  bool _disposed = false;

  Stream<dynamic> get progress => const EventChannel(
    'dev.harbor.mail/updates/progress',
  ).receiveBroadcastStream();

  Future<Map<String, dynamic>> installedInfo() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMethod<Map>('installedInfo') ?? {},
      );

  Future<AndroidDownloadManifest> check(String apiBase) async {
    if (_disposed) throw StateError('Update service is closed');
    final origin = ServerProfile.parse(apiBase).origin;
    final abort = Completer<void>();
    if (_abort?.isCompleted == false) _abort!.complete();
    _abort = abort;
    Future<AndroidDownloadManifest> fetch() async {
      final response = await _client.send(
        http.AbortableRequest(
          'GET',
          Uri.parse('$origin/downloads/android/manifest.json'),
          abortTrigger: abort.future,
        )..followRedirects = false,
      );
      if (response.statusCode != 200 || (response.contentLength ?? 0) > 65536) {
        unawaited(
          response.stream.listen((_) {}).cancel().catchError((Object _) {}),
        );
        throw const FormatException('Update metadata unavailable');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 65536) {
          throw const FormatException('Update metadata exceeds limit');
        }
        bytes.addAll(chunk);
      }
      return AndroidDownloadManifest.parse(jsonDecode(utf8.decode(bytes)));
    }

    try {
      // Bound DNS/connect, headers and body, even before IOClient attaches abort.
      return await fetch().timeout(const Duration(seconds: 12));
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (identical(_abort, abort)) _abort = null;
    }
  }

  Future<String> download(
    String apiBase,
    AndroidDownloadManifest manifest,
  ) async {
    final token = await _channel.invokeMethod<String>('download', {
      'origin': ServerProfile.parse(apiBase).origin,
      'versionName': manifest.versionName,
      'versionCode': manifest.versionCode,
      'sizeBytes': manifest.sizeBytes,
      'sha256': manifest.sha256,
      'certificateSha256': manifest.certificateSha256,
    });
    if (token == null || token.isEmpty) throw StateError('No verified package');
    return token;
  }

  Future<void> cancel() async => _channel.invokeMethod<void>('cancel');
  Future<String?> install(String token) =>
      _channel.invokeMethod<String>('install', {'token': token});
  Future<void> openSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_abort?.isCompleted == false) _abort!.complete();
    _abort = null;
    _client.close();
  }
}

/// Only an increasing Android versionCode is an update. Semantic names are display-only.
String? androidUpdateBlocker(
  AndroidDownloadManifest manifest,
  Map<String, dynamic> installed,
) {
  if (!manifest.available) return '此服务器暂未提供 Android 更新。';
  if (installed['packageName'] != 'dev.harbor.harbor_mail.dev' ||
      installed['versionCode'] is! int ||
      installed['certificateSha256'] is! String) {
    return '当前安装包不属于此更新通道，无法安全更新。';
  }
  if (manifest.certificateSha256 != installed['certificateSha256']) {
    return '新版本签名与本机不一致，无法保留配置覆盖更新。当前测试包使用临时 CI 签名，请联系管理员处理签名连续性；不要卸载现有 App。';
  }
  final code = installed['versionCode'] as int;
  if (manifest.versionCode < code) {
    return '服务器提供的版本比本机更旧，已阻止降级。请联系服务器管理员发布正确版本。';
  }
  if (manifest.versionCode == code) {
    if (manifest.versionName != installed['versionName']) {
      return '服务器版本名称与本机不同，但版本码相同，无法更新。请管理员修正发布版本码。';
    }
    return '当前已是此服务器提供的最新版本。';
  }
  return null;
}

class AndroidUpdateCard extends StatefulWidget {
  const AndroidUpdateCard({super.key, required this.apiBase, this.service});
  final String apiBase;
  final AndroidUpdateService? service;
  @override
  State<AndroidUpdateCard> createState() => _AndroidUpdateCardState();
}

class _AndroidUpdateCardState extends State<AndroidUpdateCard> {
  late AndroidUpdateService _service = widget.service ?? AndroidUpdateService();
  AndroidDownloadManifest? _manifest;
  Map<String, dynamic>? _installed;
  StreamSubscription<dynamic>? _progress;
  String? _token;
  String _message = '手动检查此服务器的新版本。更新保留账户配置。';
  bool _busy = false,
      _downloading = false,
      _permissionRequired = false,
      _cancelling = false;
  double? _fraction;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant AndroidUpdateCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiBase == widget.apiBase &&
        oldWidget.service == widget.service) {
      return;
    }
    final generation = ++_generation;
    final oldService = _service;
    final cancellation = oldService.cancel().catchError((Object _) {});
    unawaited(_progress?.cancel().catchError((Object _) {}));
    _progress = null;
    if (oldWidget.service != widget.service) {
      if (oldWidget.service == null) oldService.dispose();
      _service = widget.service ?? AndroidUpdateService();
    }
    _manifest = null;
    _installed = null;
    _token = null;
    _permissionRequired = false;
    _downloading = false;
    _cancelling = false;
    _busy = true;
    _message = '服务器已变更，请重新检查更新。';
    unawaited(
      cancellation.then((_) {
        if (mounted && generation == _generation) setState(() => _busy = false);
      }),
    );
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_progress?.cancel().catchError((Object _) {}));
    // Cancels pre-handoff verification too; native code retains handed-off APKs.
    unawaited(_service.cancel().catchError((Object _) {}));
    if (widget.service == null) _service.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _manifest = null;
      _token = null;
      _permissionRequired = false;
      _message = '正在检查更新…';
    });
    try {
      final service = _service;
      final apiBase = widget.apiBase;
      final installed = await service.installedInfo();
      if (!mounted || generation != _generation) return;
      final manifest = await service.check(apiBase);
      if (!mounted || generation != _generation) return;
      setState(() {
        _installed = installed;
        _manifest = manifest;
        _message =
            androidUpdateBlocker(manifest, installed) ?? '发现新版本，可下载后确认安装。';
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _message = '检查更新失败。请检查网络、服务器 HTTPS 地址及下载服务后重试。');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final manifest = _manifest;
    if (_busy ||
        manifest == null ||
        _installed == null ||
        androidUpdateBlocker(manifest, _installed!) != null) {
      return;
    }
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _downloading = true;
      _fraction = null;
      _message = '正在下载并校验更新…';
    });
    final progress = _service.progress.listen((event) {
      if (!mounted || generation != _generation || event is! Map) return;
      final received = event['received'], total = event['total'];
      if (received is num && total is num && total > 0) {
        setState(() => _fraction = (received / total).clamp(0, 1).toDouble());
      }
    }, onError: (Object _) {});
    _progress = progress;
    try {
      final token = await _service.download(widget.apiBase, manifest);
      if (!mounted || generation != _generation) return;
      setState(() {
        _token = token;
        _message = '下载与安全校验完成。点击安装后由 Android 系统确认，账户配置会保留。';
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _message =
              error is PlatformException && error.code == 'integrityError'
              ? '安装包校验失败：文件、签名或版本与服务器声明不一致。已阻止安装，请重新检查或联系管理员。'
              : '下载未完成或安全校验失败。可重试；当前账户配置未改变。',
        );
      }
    } finally {
      // Event-channel cancellation is cleanup, not a prerequisite for UI readiness.
      unawaited(progress.cancel().catchError((Object _) {}));
      if (identical(_progress, progress)) _progress = null;
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _cancel() async {
    if (!_downloading || _cancelling) return;
    setState(() => _cancelling = true);
    final generation = ++_generation;
    // Keep controls disabled until native cancellation has acknowledged cleanup.
    try {
      await _service.cancel();
      if (mounted && generation == _generation) {
        setState(() => _message = '已取消下载，可重新下载。');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _message = '正在结束下载。请稍后重新检查更新。');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _downloading = false;
          _cancelling = false;
        });
      }
    }
  }

  Future<void> _install() async {
    if (_busy || _token == null) return;
    final generation = _generation;
    final service = _service;
    final token = _token!;
    setState(() => _busy = true);
    try {
      final result = await service.install(token);
      if (!mounted || generation != _generation) return;
      if (result != 'permissionRequired' && result != 'opened') {
        throw StateError('Unexpected installer result');
      }
      setState(() {
        _permissionRequired = result == 'permissionRequired';
        _message = _permissionRequired
            ? 'Android 尚未允许泊信安装更新。可前往系统设置自行允许，返回后再次点击安装。安装后可关闭此权限。'
            : '已打开系统安装器。请在系统页面确认；若取消，可再次点击安装。安装结果以系统提示为准。';
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _token = null;
          _permissionRequired = false;
          _message = '无法打开安装器或更新校验失效。请重新检查更新。当前配置未改变。';
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _settings() async {
    if (_busy || !_permissionRequired) return;
    final generation = _generation;
    final service = _service;
    setState(() => _busy = true);
    try {
      await service.openSettings();
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _message = '无法打开系统设置，请在 Android 的应用设置中检查“安装未知应用”权限。');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    final canDownload =
        manifest != null &&
        _installed != null &&
        androidUpdateBlocker(manifest, _installed!) == null;
    return Card(
      key: const Key('android-update-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('应用更新', style: Theme.of(context).textTheme.titleMedium),
            if (_installed != null)
              Text(
                '本机 ${_installed!['versionName']} (${_installed!['versionCode']})',
              ),
            Text(_message, key: const Key('android-update-message')),
            if (manifest?.available == true) ...[
              Text(
                '服务器版本 ${manifest!.versionName} (${manifest.versionCode}) · '
                '${(manifest.sizeBytes / 1048576).toStringAsFixed(1)} MB',
              ),
              Text(
                manifest.releaseNotes.isEmpty
                    ? '此版本未提供更新说明。'
                    : manifest.releaseNotes,
              ),
            ],
            if (_downloading) ...[
              LinearProgressIndicator(value: _fraction),
              if (_fraction != null) Text('${(_fraction! * 100).floor()}%'),
            ],
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy ? null : _check,
                  child: const Text('检查更新'),
                ),
                if (canDownload && _token == null)
                  FilledButton(
                    onPressed: _busy ? null : _download,
                    child: const Text('下载更新'),
                  ),
                if (_downloading)
                  TextButton(
                    onPressed: _cancelling ? null : _cancel,
                    child: const Text('取消下载'),
                  ),
                if (_token != null)
                  FilledButton(
                    onPressed: _busy ? null : _install,
                    child: const Text('安装更新'),
                  ),
                if (_permissionRequired)
                  TextButton(
                    onPressed: _busy ? null : _settings,
                    child: const Text('前往系统设置'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

bool get supportsAndroidUpdates =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
