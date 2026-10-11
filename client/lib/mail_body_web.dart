// The web reader deliberately uses an opaque sandbox, never application DOM HTML.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_interop';

import 'package:flutter/material.dart';

@JS('harborRenderMail')
external JSString _renderMail(JSString raw, JSBoolean images);

@JS('harborRenderMail')
external JSFunction? get _renderer;

class MailBody extends StatefulWidget {
  final String html, text;
  const MailBody({super.key, required this.html, required this.text});
  @override
  State<MailBody> createState() => _MailBodyState();
}

class _MailBodyState extends State<MailBody> {
  bool images = false, plain = false;
  html.IFrameElement? frame;

  @override
  void didUpdateWidget(covariant MailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      images = false;
      plain = false;
      updateFrame();
    }
  }

  void updateFrame() {
    if (frame == null) return;
    frame!.srcdoc = _renderMail(widget.html.toJS, images.toJS).toDart;
  }

  @override
  Widget build(BuildContext context) {
    final hasHtml = widget.html.trim().isNotEmpty;
    // Fail closed if the bundled renderer could not load.
    final ready = _renderer != null;
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
                  icon: Icon(
                    images ? Icons.hide_image_outlined : Icons.image_outlined,
                  ),
                  label: Text(images ? '阻止远程图片' : '显示本封邮件的远程图片'),
                  onPressed: () => setState(() {
                    images = !images;
                    updateFrame();
                  }),
                ),
            ],
          ),
        if (hasHtml && ready && !plain) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '邮件脚本已禁用。显示远程图片可能让发件人获知你已阅读；内嵌附件图片暂显示占位。',
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
                    'sandbox',
                    'allow-popups allow-popups-to-escape-sandbox',
                  )
                  ..setAttribute('referrerpolicy', 'no-referrer')
                  ..setAttribute('title', '邮件正文')
                  ..style.width = '100%'
                  ..style.height = '100%'
                  ..style.border = '0';
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
