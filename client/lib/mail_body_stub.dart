import 'package:flutter/material.dart';

class MailBody extends StatelessWidget {
  final String html, text;
  const MailBody({super.key, required this.html, required this.text});
  @override
  Widget build(BuildContext context) => SelectableText(
    text.isEmpty ? '此邮件没有可显示的纯文本正文。请在 Web 版查看排版。' : text,
    style: const TextStyle(fontSize: 14, height: 1.9),
  );
}
