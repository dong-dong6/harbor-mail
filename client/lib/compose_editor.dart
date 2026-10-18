import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import 'api.dart';

typedef Json = Map<String, dynamic>;
const muted = Color(0xff596a81);

class ExternalPickerResult<T> {
  const ExternalPickerResult(this.value, {this.reauthorize = false});
  final T value;
  final bool reauthorize;
}

typedef RunExternalPicker =
    Future<ExternalPickerResult<T>> Function<T>(Future<T> Function() picker);

const _sendUncertainMessage = '提交结果暂不确定。请通过下方按钮查看发件状态，不要重复发送。';

// A guard belongs to one action. A lock/unlock or logout invalidates it even
// when this editor remains mounted and the bearer later appears unchanged.
class _ComposeSession {
  final MailApi api;
  bool Function() apiCurrent;
  bool Function()? current;

  _ComposeSession(this.api, this.current)
    : apiCurrent = api.captureSessionGuard();

  void adoptAuthorizedContinuation(_ComposeSession fresh) {
    if (!identical(api, fresh.api)) throw _ComposeSessionChanged();
    apiCurrent = fresh.apiCurrent;
    current = fresh.current;
  }
}

class _ComposeSessionChanged implements Exception {}

class ComposeEditor extends StatefulWidget {
  final MailApi api;
  final List<Json> accounts;
  final Json? reply, draft;
  final String initialAccountId;
  final bool forward;
  final bool inline;
  final VoidCallback? onClose;
  final int maxBytes;
  final void Function(String) onSaved;
  final VoidCallback? onViewStatus;
  final bool Function() Function()? captureSessionGuard;
  final RunExternalPicker? runExternalPicker;
  const ComposeEditor({
    super.key,
    required this.api,
    required this.accounts,
    this.initialAccountId = '',
    this.reply,
    this.draft,
    this.forward = false,
    this.inline = false,
    this.onClose,
    required this.maxBytes,
    required this.onSaved,
    this.onViewStatus,
    this.captureSessionGuard,
    this.runExternalPicker,
  });
  @override
  ComposeEditorState createState() => ComposeEditorState();
}

class ComposeEditorState extends State<ComposeEditor> {
  final to = TextEditingController(),
      cc = TextEditingController(),
      subject = TextEditingController(),
      body = TextEditingController();
  final editorFocus = FocusNode();
  late String account;
  String? id;
  int? revision;
  bool busy = false;
  String error = '';
  final List<String> attachments = [];
  String? sendKey;
  bool sendUncertain = false;
  bool confirmingClose = false, confirmingSend = false, quoteExpanded = false;
  String quotedText = '';
  bool get dirty => snapshot != savedSnapshot;
  bool get sessionAvailable =>
      mounted && (widget.captureSessionGuard?.call().call() ?? true);
  bool get locked =>
      !sessionAvailable ||
      busy ||
      sendUncertain ||
      confirmingClose ||
      confirmingSend;

  _ComposeSession _captureSession() =>
      _ComposeSession(widget.api, widget.captureSessionGuard?.call());

  bool _isCurrentSession(_ComposeSession session) =>
      mounted &&
      identical(widget.api, session.api) &&
      session.apiCurrent() &&
      (session.current?.call() ?? true);

  void _requireCurrentSession(_ComposeSession session) {
    if (!_isCurrentSession(session)) throw _ComposeSessionChanged();
  }

  late String savedSnapshot;
  String get snapshot =>
      jsonEncode([account, to.text, cc.text, subject.text, body.text]);
  @override
  void initState() {
    super.initState();
    final d = widget.draft, r = widget.reply;
    account =
        d?['accountId'] ??
        r?['accountId'] ??
        (widget.accounts.any((a) => a['id'] == widget.initialAccountId)
            ? widget.initialAccountId
            : widget.accounts.first['id']);
    id = d?['id'];
    revision = d?['revision'];
    if (d != null) {
      to.text = (d['to'] as List? ?? []).map((e) => e['address']).join(', ');
      cc.text = (d['cc'] as List? ?? []).map((e) => e['address']).join(', ');
      subject.text = d['subject'] ?? '';
      body.text = d['bodyText'] ?? '';
      attachments.addAll(
        (d['attachments'] as List? ?? []).map((a) => a['fileName'].toString()),
      );
    } else if (r != null) {
      final ownAddresses = widget.accounts
          .map((a) => a['email']?.toString().toLowerCase())
          .toSet();
      final fromOwnAccount = ownAddresses.contains(
        r['fromAddress']?.toString().toLowerCase(),
      );
      to.text = widget.forward
          ? ''
          : fromOwnAccount
          ? (r['to'] as List? ?? []).map((e) => e['address']).join(', ')
          : r['fromAddress'] ?? '';
      subject.text = '${widget.forward ? 'Fwd' : 'Re'}: ${r['subject'] ?? ''}';
      quotedText =
          '\n\n──────── 原邮件 ────────\n发件人：${r['fromAddress']}\n主题：${r['subject']}\n\n${r['bodyText'] ?? ''}';
    }
    savedSnapshot = d == null
        ? jsonEncode([account, '', '', '', ''])
        : snapshot;
  }

  @override
  void dispose() {
    editorFocus.dispose();
    to.dispose();
    cc.dispose();
    subject.dispose();
    body.dispose();
    super.dispose();
  }

  List<Json> recipients(String text) => text
      .split(RegExp(r'[,;，；\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((s) => <String, dynamic>{'address': s})
      .toList();
  Future<void> _persist(_ComposeSession session) async {
    _requireCurrentSession(session);
    final payload = {
      'accountId': account,
      'to': recipients(to.text),
      'cc': recipients(cc.text),
      'subject': subject.text,
      'bodyText': '${body.text}$quotedText',
      if (widget.reply != null && !widget.forward)
        'replyToMessageId': widget.reply!['id'],
      if (revision != null) 'revision': revision,
    };
    final data = await session.api.request(
      id == null ? 'POST' : 'PATCH',
      id == null ? '/drafts' : '/drafts/$id',
      body: payload,
    );
    _requireCurrentSession(session);
    id = data['id'];
    revision = data['revision'];
    savedSnapshot = snapshot;
  }

  Future<void> _act(
    Future<void> Function(_ComposeSession) work, {
    _ComposeSession? session,
  }) async {
    if (locked) return;
    final started = session ?? _captureSession();
    if (!_isCurrentSession(started)) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await work(started);
    } on _ComposeSessionChanged {
      // The completed step cannot authorize any work in a replacement session.
    } catch (e) {
      if (_isCurrentSession(started)) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() => _act((session) async {
    await _persist(session);
    _requireCurrentSession(session);
    widget.onSaved('草稿已保存');
  });
  Future<void> upload() => _act((session) async {
    Future<FilePickerResult?> pick() =>
        FilePicker.platform.pickFiles(withData: false, withReadStream: true);
    final runner = widget.runExternalPicker;
    final result = runner == null
        ? ExternalPickerResult(await pick())
        : await runner<FilePickerResult?>(pick);
    if (result.reauthorize) {
      // Only the owner's exact-family foreground runner can authorize this
      // selected file after an OS picker lifecycle interruption.
      session.adoptAuthorizedContinuation(_captureSession());
    }
    _requireCurrentSession(session);
    final picked = result.value;
    if (picked == null) return;
    final file = picked.files.single;
    if (file.size > widget.maxBytes) {
      throw ApiException(
        'FILE_TOO_LARGE',
        '附件超过 ${widget.maxBytes ~/ 1048576} MiB 上限',
      );
    }
    var bytes = file.bytes;
    if (bytes == null) {
      final stream = file.readStream;
      if (stream == null) {
        throw ApiException('FILE_UNAVAILABLE', '无法读取文件');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        _requireCurrentSession(session);
        if (buffer.length + chunk.length > widget.maxBytes) {
          throw ApiException('FILE_TOO_LARGE', '附件超过上传上限');
        }
        buffer.add(chunk);
      }
      _requireCurrentSession(session);
      bytes = buffer.takeBytes();
    }
    await _persist(session);
    _requireCurrentSession(session);
    await session.api.upload(id!, file.name, bytes);
    _requireCurrentSession(session);
    final data = await session.api.request('GET', '/drafts');
    _requireCurrentSession(session);
    final updated = (data['items'] as List)
        .where((d) => d['id'] == id)
        .firstOrNull;
    if (updated != null) revision = updated['revision'];
    setState(() => attachments.add(file.name));
  });
  Future<bool> canLeave() async {
    if (locked) return false;
    if (!dirty) return true;
    final session = _captureSession();
    setState(() => confirmingClose = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('放弃未保存的更改？'),
          content: const Text('这些更改尚未保存。放弃后无法恢复；已保存的草稿会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃更改'),
            ),
          ],
        ),
      );
      return _isCurrentSession(session) && confirmed == true;
    } finally {
      if (mounted) {
        setState(() => confirmingClose = false);
        if (_isCurrentSession(session)) editorFocus.requestFocus();
      }
    }
  }

  void close() {
    if (!sessionAvailable) return;
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> requestClose() async {
    if (!sessionAvailable) return;
    final session = _captureSession();
    if (await canLeave() && _isCurrentSession(session)) close();
  }

  void viewUncertainStatus() {
    if (!sessionAvailable || busy || !sendUncertain) return;
    close();
    widget.onViewStatus?.call();
  }

  Future<void> send() async {
    if (locked) return;
    final addresses = recipients(to.text);
    if (addresses.isEmpty ||
        [...addresses, ...recipients(cc.text)].any(
          (a) => !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(a['address']),
        )) {
      setState(() => error = '请输入有效收件人地址，多个地址用逗号分隔');
      return;
    }
    final session = _captureSession();
    setState(() => confirmingSend = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认发送'),
        content: Text(
          '将从 ${widget.accounts.firstWhere((a) => a['id'] == account)['email']} 发送至 ${to.text}${cc.text.isEmpty ? '' : '，抄送 ${cc.text}'}。\n\n主题：${subject.text.isEmpty ? '（无主题）' : subject.text}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => confirmingSend = false);
    if (confirmed != true || !_isCurrentSession(session)) return;
    await _act((session) async {
      await _persist(session);
      _requireCurrentSession(session);
      sendKey ??= 'send-${DateTime.now().microsecondsSinceEpoch}';
      // Once submitted, a stale completion must never make this editor resendable.
      // Only a current-session definite result may clear the uncertainty guard.
      sendUncertain = true;
      try {
        final result = await session.api.request(
          'POST',
          '/drafts/$id/send',
          key: sendKey,
          body: {'revision': revision},
        );
        _requireCurrentSession(session);
        sendUncertain = false;
        widget.onSaved('邮件已进入发件队列（${result['status']}），请在「发件状态」查看结果');
        if (_isCurrentSession(session)) close();
      } catch (e) {
        if (!_isCurrentSession(session)) rethrow;
        if (e is ApiException &&
            (e.code == 'NETWORK' ||
                e.code == 'INVALID_RESPONSE' ||
                e.code.startsWith('HTTP_5'))) {
          throw ApiException('SEND_UNCERTAIN', _sendUncertainMessage);
        }
        sendUncertain = false;
        rethrow;
      }
    }, session: session);
  }

  Widget fields() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        initialValue: account,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '发件邮箱'),
        items: widget.accounts
            .map(
              (a) => DropdownMenuItem<String>(
                value: a['id'],
                child: Text(a['email'] ?? '', overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: locked || id != null
            ? null
            : (v) => setState(() => account = v!),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: to,
        enabled: !locked,
        decoration: const InputDecoration(
          labelText: '收件人',
          hintText: 'name@example.com',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: cc,
        enabled: !locked,
        decoration: const InputDecoration(labelText: '抄送（可选）'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: subject,
        enabled: !locked,
        decoration: const InputDecoration(labelText: '主题'),
      ),
      const SizedBox(height: 12),
      TextField(
        key: widget.inline ? const Key('inline-body') : null,
        controller: body,
        enabled: !locked,
        minLines: widget.inline ? 5 : 9,
        maxLines: 14,
        decoration: InputDecoration(
          labelText: widget.inline ? '回复正文' : null,
          hintText: '从这里开始…',
          alignLabelWithHint: true,
        ),
      ),
      if (quotedText.isNotEmpty) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('toggle-quoted-message'),
            onPressed: () => setState(() => quoteExpanded = !quoteExpanded),
            icon: Icon(quoteExpanded ? Icons.expand_less : Icons.more_horiz),
            label: Text(quoteExpanded ? '收起原邮件' : '显示原邮件'),
          ),
        ),
        if (quoteExpanded)
          SelectableText(
            quotedText,
            style: const TextStyle(fontSize: 12, color: muted),
          ),
      ],
      if (attachments.isNotEmpty)
        Wrap(
          spacing: 8,
          children: attachments
              .map(
                (name) => Chip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(name),
                ),
              )
              .toList(),
        ),
    ],
  );

  Widget editor() => Padding(
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 12 : 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.inline ? (widget.forward ? '转发邮件' : '回复邮件') : '写一封邮件',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: widget.inline ? '关闭编辑' : '关闭写信窗口',
              onPressed: locked ? null : requestClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (widget.inline)
          fields()
        else
          Flexible(child: SingleChildScrollView(child: fields())),
        if (error.isNotEmpty || (sendUncertain && !busy))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              error.isNotEmpty ? error : _sendUncertainMessage,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        if (sendUncertain)
          TextButton.icon(
            onPressed: busy ? null : viewUncertainStatus,
            icon: const Icon(Icons.outbox_outlined),
            label: const Text('关闭并查看发件状态'),
          ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: locked ? null : send,
              icon: const Icon(Icons.send_outlined, size: 17),
              label: Text(busy ? '处理中…' : '发送'),
            ),
            TextButton.icon(
              onPressed: locked ? null : save,
              icon: const Icon(Icons.save_outlined, size: 17),
              label: const Text('保存草稿'),
            ),
            TextButton.icon(
              onPressed: locked ? null : upload,
              icon: const Icon(Icons.attach_file, size: 17),
              label: Text('附件 ≤ ${widget.maxBytes ~/ 1048576} MiB'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '草稿需手动保存 · 仅支持纯文本正文',
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) requestClose();
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): requestClose,
      },
      child: Focus(
        focusNode: editorFocus,
        autofocus: true,
        child: widget.inline
            ? Container(
                key: const Key('inline-compose'),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xffd8e0eb)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: editor(),
              )
            : Dialog(
                insetPadding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 600 ? 8 : 20,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 780,
                    maxHeight: 760,
                  ),
                  child: editor(),
                ),
              ),
      ),
    ),
  );
}

/// Backwards-compatible modal used only for new messages and saved drafts.
class ComposeDialog extends ComposeEditor {
  const ComposeDialog({
    super.key,
    required super.api,
    required super.accounts,
    super.initialAccountId,
    super.reply,
    super.draft,
    super.forward,
    required super.maxBytes,
    required super.onSaved,
    super.onViewStatus,
    super.captureSessionGuard,
    super.runExternalPicker,
  });
}
