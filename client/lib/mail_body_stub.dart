import 'package:flutter/material.dart';
import 'api.dart';

class MailBody extends StatelessWidget {
  final String html, text;
  final MailApi? api;
  final String? messageId, accountId;
  final bool inputEnabled;
  const MailBody(
      {super.key,
      required this.html,
      required this.text,
      this.api,
      this.messageId,
      this.accountId,
      this.inputEnabled = true});
  @override
  Widget build(BuildContext context) => SelectableText(
        text.isEmpty ? '此邮件没有可显示的纯文本正文。请在 Web 版查看排版。' : text,
        style: const TextStyle(fontSize: 14, height: 1.9),
      );
}
