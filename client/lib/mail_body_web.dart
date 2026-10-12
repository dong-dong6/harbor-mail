// The web reader deliberately uses an opaque sandbox, never application DOM HTML.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';

import 'package:flutter/material.dart';

import 'api.dart';

@JS('harborRenderMail')
external JSString _renderMail(
    JSString raw, JSBoolean images, JSString verified);

@JS('harborRenderMail')
external JSFunction? get _renderer;

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
  bool images = false, plain = false, loading = false;
  bool interactive = true;
  int generation = 0;
  String? imageError;
  Map<String, String> verified = {};
  html.IFrameElement? frame;

  @override
  void didUpdateWidget(covariant MailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.messageId != widget.messageId ||
        oldWidget.accountId != widget.accountId ||
        oldWidget.api != widget.api) {
      generation++;
      images = false;
      plain = false;
      loading = false;
      imageError = null;
      verified = {};
      updateFrame();
    }
  }

  @override
  void dispose() {
    generation++;
    frame?.style.pointerEvents = 'none';
    frame = null;
    super.dispose();
  }

  void updateFrame() {
    if (frame == null || _renderer == null) return;
    frame!.srcdoc =
        _renderMail(widget.html.toJS, images.toJS, jsonEncode(verified).toJS)
            .toDart;
  }

  Future<void> toggleImages() async {
    final ticket = ++generation;
    if (images || loading) {
      setState(() {
        images = false;
        loading = false;
        verified = {};
        imageError = null;
      });
      updateFrame();
      return;
    }
    final api = widget.api,
        messageId = widget.messageId,
        accountId = widget.accountId;
    if (api == null || messageId == null || accountId == null) return;
    setState(() {
      loading = true;
      imageError = null;
    });
    try {
      final data = await api.remoteImages(messageId, accountId,
          isCurrent: () => mounted && ticket == generation);
      if (!mounted || ticket != generation) return;
      setState(() {
        verified = data;
        images = true;
        loading = false;
        if (data.isEmpty) imageError = '没有可安全显示的远程图片。';
      });
      updateFrame();
    } on ApiException catch (e) {
      if (!mounted || ticket != generation) return;
      setState(() {
        loading = false;
        imageError =
            e.code == 'UNAUTHORIZED' ? '登录已过期，请重新登录后查看图片。' : '图片暂时无法载入，已保持阻止。';
      });
    } catch (_) {
      if (!mounted || ticket != generation) return;
      setState(() {
        loading = false;
        imageError = '图片暂时无法载入，已保持阻止。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasHtml = widget.html.trim().isNotEmpty;
    final ready = _renderer != null;
    // HtmlElementView is outside Flutter's hit-testing. Disable its DOM hit target
    // whenever a route/dialog or the mobile drawer covers this reader.
    interactive =
        widget.inputEnabled && (ModalRoute.isCurrentOf(context) ?? false);
    frame?.style.pointerEvents = interactive ? 'auto' : 'none';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasHtml && ready)
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                icon: Icon(plain ? Icons.article_outlined : Icons.code),
                label: Text(plain ? '显示邮件排版' : '查看纯文本'),
                onPressed: () => setState(() => plain = !plain),
              ),
              if (!plain)
                TextButton.icon(
                  icon: Icon(images || loading
                      ? Icons.hide_image_outlined
                      : Icons.image_outlined),
                  label: Text(loading
                      ? '正在安全载入（点此取消）'
                      : images
                          ? '阻止远程图片'
                          : '显示本封邮件的远程图片'),
                  onPressed: widget.api != null &&
                          widget.messageId != null &&
                          widget.accountId != null
                      ? toggleImages
                      : null,
                ),
            ],
          ),
        if (imageError != null && !plain)
          Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(imageError!, style: const TextStyle(fontSize: 12))),
        if (hasHtml && ready && !plain) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '邮件脚本已禁用。远程图片默认阻止，开启后由服务器安全代理载入；发件人仍可能获知图片被请求。内嵌附件图片暂显示占位。',
              style: TextStyle(fontSize: 11, color: Color(0xff687080)),
            ),
          ),
          SizedBox(
            height:
                MediaQuery.sizeOf(context).height.clamp(360, 900).toDouble() *
                    .75,
            child: HtmlElementView.fromTagName(
              tagName: 'iframe',
              onElementCreated: (Object element) {
                frame = element as html.IFrameElement;
                frame!
                  ..setAttribute(
                      'sandbox', 'allow-popups allow-popups-to-escape-sandbox')
                  ..setAttribute('referrerpolicy', 'no-referrer')
                  ..setAttribute('title', '邮件正文')
                  ..style.width = '100%'
                  ..style.height = '100%'
                  ..style.border = '0'
                  ..style.pointerEvents = interactive ? 'auto' : 'none';
                updateFrame();
              },
            ),
          ),
        ] else
          SelectableText(
            widget.text.isEmpty ? '此邮件没有可显示的纯文本正文。' : widget.text,
            style: const TextStyle(fontSize: 14, height: 1.9),
          ),
      ],
    );
  }
}
