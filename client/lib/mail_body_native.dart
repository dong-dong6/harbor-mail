import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'mail_html_sanitizer.dart';

/// Native mail is a sanitized Flutter widget tree, never a WebView. No scripts,
/// navigation, forms, cookies or resource requests can run as a side effect of
/// displaying the body. Images only arrive through MailApi's explicit proxy flow.
class MailBody extends StatefulWidget {
  final String html, text;
  final MailApi? api;
  final String? messageId, accountId;
  final bool inputEnabled;

  const MailBody({
    super.key,
    required this.html,
    required this.text,
    this.api,
    this.messageId,
    this.accountId,
    this.inputEnabled = true,
  });

  @override
  State<MailBody> createState() => _MailBodyState();
}

class _MailBodyState extends State<MailBody> {
  bool _images = false, _plain = false, _loading = false, _linkPending = false;
  int _generation = 0;
  String? _imageError;
  bool Function()? _sessionCurrent;
  late SanitizedMailHtml _body;

  @override
  void initState() {
    super.initState();
    _sessionCurrent = widget.api?.captureSessionGuard();
    _body = sanitizeMailHtml(widget.html);
  }

  @override
  void didUpdateWidget(covariant MailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.text != widget.text ||
        oldWidget.messageId != widget.messageId ||
        oldWidget.accountId != widget.accountId ||
        oldWidget.api != widget.api ||
        !(_sessionCurrent?.call() ?? true)) {
      _sessionCurrent = widget.api?.captureSessionGuard();
      _plain = false;
      _blockImages();
    } else if (oldWidget.inputEnabled && !widget.inputEnabled) {
      // A covered/retired reader cannot finish an old image batch or launch a
      // previously confirmed link after the user has moved somewhere else.
      _blockImages();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  bool get _interactive =>
      mounted &&
      widget.inputEnabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _blockImages() {
    _generation++;
    _images = false;
    _loading = false;
    _imageError = null;
    _body = sanitizeMailHtml(widget.html);
  }

  Future<void> _toggleImages() async {
    if (!_interactive) return;
    if (_images || _loading) {
      setState(_blockImages);
      return;
    }
    final api = widget.api;
    final messageId = widget.messageId, accountId = widget.accountId;
    if (api == null || messageId == null || accountId == null) return;
    final ticket = ++_generation;
    final sessionCurrent = api.captureSessionGuard();
    bool current() =>
        mounted && ticket == _generation && sessionCurrent() && _interactive;
    setState(() {
      _loading = true;
      _imageError = null;
    });
    try {
      final verified = await api.remoteImages(
        messageId,
        accountId,
        isCurrent: current,
      );
      if (!current()) return;
      final body = sanitizeMailHtml(
        widget.html,
        allowImages: true,
        verifiedImages: verified,
      );
      setState(() {
        _body = body;
        _images = true;
        if (body.images.isEmpty) _imageError = '没有可安全显示的远程图片。';
      });
    } on ApiException catch (e) {
      if (!mounted || ticket != _generation) return;
      setState(() {
        _imageError = e.code == 'UNAUTHORIZED'
            ? '登录已过期，请重新登录后查看图片。'
            : '图片暂时无法载入，已保持阻止。';
      });
    } catch (_) {
      if (!mounted || ticket != _generation) return;
      setState(() => _imageError = '图片暂时无法载入，已保持阻止。');
    } finally {
      if (mounted && ticket == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<bool> _openLink(String value) async {
    // Always report handled, including rejected links. Do not allow any
    // package fallback to navigate or start another kind of application.
    final uri = safeMailLink(value);
    if (uri == null || !_interactive || _linkPending) return true;
    final ticket = _generation;
    final sessionCurrent = widget.api?.captureSessionGuard();
    _linkPending = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('打开邮件中的链接？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('将离开邮件阅读器。请核对完整网址；打开后对方可能获知访问。'),
                const SizedBox(height: 12),
                SelectableText(uri.toString()),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('在浏览器中打开'),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          ticket != _generation ||
          !(sessionCurrent?.call() ?? true) ||
          !_interactive ||
          safeMailLink(value) == null) {
        return true;
      }
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted && ticket == _generation) _linkFailed();
    } catch (_) {
      if (mounted && ticket == _generation) _linkFailed();
    } finally {
      _linkPending = false;
    }
    return true;
  }

  void _linkFailed() => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(const SnackBar(content: Text('无法打开链接。可复制网址后自行查看。')));

  @override
  Widget build(BuildContext context) {
    final hasHtml = widget.html.trim().isNotEmpty;
    // Raw HTML may consist entirely of scripts/forms or empty containers. Do
    // not let the presence of a MIME HTML part hide a usable text alternative.
    // Blocked-image placeholders are text, so legitimate image-only mail still
    // retains its explicit proxy opt-in controls.
    final hasReadableHtml =
        _body.text.trim().isNotEmpty || _body.images.isNotEmpty;
    final interactive =
        widget.inputEnabled && (ModalRoute.isCurrentOf(context) ?? true);
    final plainText = widget.text.trim().isNotEmpty ? widget.text : _body.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasHtml && hasReadableHtml)
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                icon: Icon(_plain ? Icons.article_outlined : Icons.code),
                label: Text(_plain ? '显示邮件排版' : '查看纯文本'),
                onPressed: interactive
                    ? () => setState(() {
                        _plain = !_plain;
                        _blockImages();
                      })
                    : null,
              ),
              if (!_plain)
                TextButton.icon(
                  icon: Icon(
                    _images || _loading
                        ? Icons.hide_image_outlined
                        : Icons.image_outlined,
                  ),
                  label: Text(
                    _loading
                        ? '正在安全载入（点此取消）'
                        : _images
                        ? '阻止远程图片'
                        : '显示本封邮件的远程图片',
                  ),
                  onPressed:
                      interactive &&
                          widget.api != null &&
                          widget.messageId != null &&
                          widget.accountId != null
                      ? _toggleImages
                      : null,
                ),
            ],
          ),
        if (_imageError != null && !_plain)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_imageError!, style: const TextStyle(fontSize: 12)),
          ),
        if (hasHtml && !hasReadableHtml)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '邮件排版不含可安全显示的内容，已显示纯文本。',
              style: TextStyle(fontSize: 11, color: Color(0xff687080)),
            ),
          ),
        if (hasHtml && hasReadableHtml && !_plain) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '邮件脚本已禁用。远程图片默认阻止，开启后由服务器安全代理载入；发件人仍可能获知图片被请求。内嵌附件图片暂显示占位。',
              style: TextStyle(fontSize: 11, color: Color(0xff687080)),
            ),
          ),
          if (_body.truncated)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('邮件排版内容过大，已限制显示。可切换纯文本查看。'),
            ),
          // Native hit-testing obeys dialogs, drawers and routes. Explicitly
          // suppress it too when the mailbox marks this reader as covered.
          IgnorePointer(
            ignoring: !interactive,
            child: ClipRect(
              child: SelectionArea(
                child: HtmlWidget(
                  _body.html,
                  key: ValueKey('native-mail-html-$_generation'),
                  buildAsync: false,
                  factoryBuilder: OfflineMailWidgetFactory.new,
                  textStyle: const TextStyle(fontSize: 14, height: 1.6),
                  onTapUrl: _openLink,
                  customWidgetBuilder: (element) {
                    if (element.localName != 'img') return null;
                    final bytes =
                        _body.images[element.attributes['data-harbor-image']];
                    final alt = element.attributes['alt'] ?? '邮件图片';
                    if (bytes == null) return Text('[$alt]');
                    final header = ByteData.sublistView(bytes);
                    final width = header.getUint32(16),
                        height = header.getUint32(20);
                    final scale = math.min(1.0, 1024 / math.max(width, height));
                    return Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      semanticLabel: alt,
                      cacheWidth: math.max(1, (width * scale).ceil()),
                      cacheHeight: math.max(1, (height * scale).ceil()),
                      errorBuilder: (_, _, _) => Text('[$alt：无法显示]'),
                    );
                  },
                ),
              ),
            ),
          ),
        ] else
          SelectableText(
            plainText.isEmpty ? '此邮件没有可显示的正文。' : plainText,
            style: const TextStyle(fontSize: 14, height: 1.9),
          ),
      ],
    );
  }
}

/// Defense in depth: even accidentally unsanitized image/background attributes
/// cannot load a file, asset, arbitrary data URI or network resource. Verified
/// proxy bytes are inserted separately by the host's custom widget builder.
class OfflineMailWidgetFactory extends WidgetFactory {
  @override
  ImageProvider? imageProviderFromNetwork(String url) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;

  @override
  ImageProvider? imageProviderFromAsset(String url) => null;

  @override
  ImageProvider? imageProviderFromDataUri(String dataUri) => null;
}
