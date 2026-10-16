import 'package:flutter/material.dart';

/// Displays only message metadata returned by the server; no inferred auth badge.
class MailHeader extends StatelessWidget {
  final Map<String, dynamic> message;
  const MailHeader({super.key, required this.message});
  String addresses(dynamic values) => (values as List? ?? [])
      .map((value) {
        final address = value['address']?.toString() ?? '';
        final name = value['name']?.toString().trim() ?? '';
        return name.isEmpty ? address : '$name <$address>';
      })
      .join(', ');
  String get received {
    final raw = message['receivedAt']?.toString() ?? '';
    final date = DateTime.tryParse(raw)?.toLocal();
    if (date == null) return raw.isEmpty ? '未提供' : raw;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)} ${date.timeZoneName}';
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final fromName = message['fromName']?.toString().trim() ?? '';
    final fromAddress = message['fromAddress']?.toString() ?? '';
    final cc = addresses(message['cc']);
    final subject = message['subject']?.toString().isNotEmpty == true
        ? message['subject'].toString()
        : '（无主题）';
    return Column(
      key: const Key('mail-header'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(
          subject,
          // Expose readonly selectable content as a label rather than an empty
          // web text-input node; visual selection/copy behavior is unchanged.
          semanticsLabel: subject,
          style: TextStyle(
            fontSize: compact ? 21 : 24,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
        ),
        SizedBox(height: compact ? 12 : 20),
        field(
          '发件人',
          fromName.isEmpty ? fromAddress : '$fromName <$fromAddress>',
        ),
        if (compact)
          Material(
            color: Colors.transparent,
            child: ExpansionTile(
              key: ValueKey('recipient-details-${message['id']}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('收件详情', style: TextStyle(fontSize: 12)),
              subtitle: Text(received, style: const TextStyle(fontSize: 11)),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field('收件人', addresses(message['to'])),
                if (cc.isNotEmpty) field('抄送', cc),
                field('接收时间', received),
              ],
            ),
          )
        else ...[
          field('收件人', addresses(message['to'])),
          if (cc.isNotEmpty) field('抄送', cc),
          field('接收时间', received),
        ],
      ],
    );
  }

  Widget field(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: SelectableText(
      '$label：${value.isEmpty ? '未提供' : value}',
      semanticsLabel: '$label：${value.isEmpty ? '未提供' : value}',
      style: const TextStyle(
        fontSize: 12,
        color: Color(0xff596a81),
        height: 1.6,
      ),
    ),
  );
}
