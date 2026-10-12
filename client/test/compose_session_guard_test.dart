import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_mail/api.dart';
import 'package:harbor_mail/compose_editor.dart';

class ControlledPicker extends FilePicker {
  Completer<FilePickerResult?>? _picked;
  Completer<FilePickerResult?> get picked =>
      _picked ??= Completer<FilePickerResult?>();

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) =>
      picked.future;
}

class ControlledApi extends MailApi {
  final calls = <String>[];
  Completer<dynamic>? persistResult, sendResult;
  Completer<Map<String, dynamic>>? uploadResult;

  ControlledApi() : super(base: 'https://mail.example.invalid/api/v1') {
    token = 'synthetic-original-session';
  }

  @override
  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    String? key,
    bool followRedirects = false,
  }) async {
    calls.add('$method $path');
    if (path.endsWith('/send')) {
      return sendResult?.future ?? {'status': 'QUEUED'};
    }
    if (method == 'GET') {
      return {
        'items': [
          {'id': 'draft', 'revision': 2},
        ],
      };
    }
    return persistResult?.future ?? {'id': 'draft', 'revision': 1};
  }

  @override
  Future<Map<String, dynamic>> upload(
    String draftId,
    String fileName,
    Uint8List bytes,
  ) async {
    calls.add('UPLOAD $draftId');
    return uploadResult?.future ?? <String, dynamic>{};
  }
}

class SessionEpoch {
  int epoch = 0;
  bool unlocked = true;
  bool Function() capture() {
    final startedAt = epoch;
    return () => unlocked && epoch == startedAt;
  }

  void lock() {
    epoch++;
    unlocked = false;
  }

  void unlock() {
    epoch++;
    unlocked = true;
  }
}

Future<GlobalKey<ComposeEditorState>> mountEditor(
  WidgetTester tester,
  ControlledApi api,
  SessionEpoch session, {
  GlobalKey<ComposeEditorState>? key,
  void Function(String)? onSaved,
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = const Size(1000, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final editorKey = key ?? GlobalKey<ComposeEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ComposeEditor(
            key: editorKey,
            api: api,
            accounts: const [
              {'id': 'account', 'email': 'sender@example.invalid'},
            ],
            inline: true,
            maxBytes: 10485760,
            captureSessionGuard: session.capture,
            onSaved: onSaved ?? (_) {},
            onClose: onClose ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  editorKey.currentState!.to.text = 'recipient@example.invalid';
  editorKey.currentState!.body.text = 'Synthetic message only';
  return editorKey;
}

FilePickerResult syntheticFile({Stream<List<int>>? stream}) =>
    FilePickerResult([
      PlatformFile(
        name: 'synthetic.txt',
        size: 3,
        bytes: stream == null ? Uint8List.fromList([1, 2, 3]) : null,
        readStream: stream,
      ),
    ]);

Future<void> confirmSend(
  WidgetTester tester,
  GlobalKey<ComposeEditorState> key,
) async {
  unawaited(key.currentState!.send());
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '发送').last);
  await tester.pumpAndSettle();
}

void main() {
  late ControlledPicker picker;
  setUp(() {
    picker = ControlledPicker();
    FilePicker.platform = picker;
  });

  for (final invalidation in [
    'logout',
    'replacement',
    'lock',
    'lock-unlock',
    'dispose',
  ]) {
    testWidgets('file picker cannot resume upload after $invalidation', (
      tester,
    ) async {
      final api = ControlledApi();
      final session = SessionEpoch();
      final key = await mountEditor(tester, api, session);
      final upload = key.currentState!.upload();
      await tester.pump();
      switch (invalidation) {
        case 'logout':
          api.token = null;
        case 'replacement':
          api.token = 'synthetic-replacement-session';
        case 'lock':
          session.lock();
        case 'lock-unlock':
          session.lock();
          session.unlock();
        case 'dispose':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      picker.picked.complete(syntheticFile());
      await tester.pumpAndSettle();
      await upload;
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('file stream cannot persist after lock and unlock', (tester) async {
    final api = ControlledApi();
    final session = SessionEpoch();
    final key = await mountEditor(tester, api, session);
    final bytes = Stream<List<int>>.fromIterable([[1, 2, 3]]).map((chunk) {
      session.lock();
      session.unlock();
      return chunk;
    });
    final upload = key.currentState!.upload();
    picker.picked.complete(syntheticFile(stream: bytes));
    await tester.pumpAndSettle();
    await upload;
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final action in ['upload', 'send', 'save']) {
    for (final invalidation in ['replacement', 'lock-unlock', 'dispose']) {
      testWidgets(
        '$action cannot continue stale draft save after $invalidation',
        (tester) async {
          final api = ControlledApi()..persistResult = Completer<dynamic>();
          final session = SessionEpoch();
          var saved = 0;
          final key = await mountEditor(
            tester,
            api,
            session,
            onSaved: (_) => saved++,
          );
          Future<void>? pending;
          if (action == 'upload') {
            pending = key.currentState!.upload();
            picker.picked.complete(syntheticFile());
            await tester.pumpAndSettle();
          } else if (action == 'save') {
            pending = key.currentState!.save();
            await tester.pumpAndSettle();
          } else {
            await confirmSend(tester, key);
          }
          expect(api.calls, ['POST /drafts']);
          switch (invalidation) {
            case 'replacement':
              api.token = 'synthetic-replacement-session';
            case 'lock-unlock':
              session.lock();
              session.unlock();
            case 'dispose':
              await tester.pumpWidget(const SizedBox.shrink());
          }
          api.persistResult!.complete({'id': 'draft', 'revision': 1});
          await tester.pumpAndSettle();
          if (pending != null) await pending;
          expect(api.calls, ['POST /drafts']);
          expect(saved, 0);
          expect(key.currentState?.id, isNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('replacement API is not used after pending original save', (
    tester,
  ) async {
    final originalApi = ControlledApi()..persistResult = Completer<dynamic>();
    final replacementApi = ControlledApi();
    final session = SessionEpoch();
    final key = await mountEditor(tester, originalApi, session);
    final pending = key.currentState!.upload();
    picker.picked.complete(syntheticFile());
    await tester.pumpAndSettle();
    await mountEditor(tester, replacementApi, session, key: key);
    originalApi.persistResult!.complete({'id': 'draft', 'revision': 1});
    await tester.pumpAndSettle();
    await pending;
    expect(originalApi.calls, ['POST /drafts']);
    expect(replacementApi.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending upload cannot refresh drafts after session replacement',
    (tester) async {
      final api = ControlledApi()
        ..uploadResult = Completer<Map<String, dynamic>>();
      final session = SessionEpoch();
      final key = await mountEditor(tester, api, session);
      final upload = key.currentState!.upload();
      picker.picked.complete(syntheticFile());
      await tester.pumpAndSettle();
      expect(api.calls, ['POST /drafts', 'UPLOAD draft']);
      api.token = 'synthetic-replacement-session';
      api.uploadResult!.complete({});
      await tester.pumpAndSettle();
      await upload;
      await tester.pumpAndSettle();
      expect(api.calls, ['POST /drafts', 'UPLOAD draft']);
      expect(key.currentState!.attachments, isEmpty);
    },
  );

  testWidgets('send confirmation cannot authorize a later session', (
    tester,
  ) async {
    final api = ControlledApi();
    final session = SessionEpoch();
    final key = await mountEditor(tester, api, session);
    final send = key.currentState!.send();
    await tester.pumpAndSettle();
    session.lock();
    session.unlock();
    await tester.tap(find.widgetWithText(FilledButton, '发送').last);
    await tester.pumpAndSettle();
    await send;
    expect(api.calls, isEmpty);
  });

  for (final result in ['success', 'network-error']) {
    testWidgets(
      'already submitted send remains guarded after lock-unlock and $result',
      (tester) async {
        final api = ControlledApi()..sendResult = Completer<dynamic>();
        final session = SessionEpoch();
        var saved = 0, closed = 0;
        final key = await mountEditor(
          tester,
          api,
          session,
          onSaved: (_) => saved++,
          onClose: () => closed++,
        );
        await confirmSend(tester, key);
        expect(api.calls, ['POST /drafts', 'POST /drafts/draft/send']);
        session.lock();
        session.unlock();
        if (result == 'success') {
          api.sendResult!.complete({'status': 'QUEUED'});
        } else {
          api.sendResult!.completeError(
            ApiException('NETWORK', 'Synthetic failure'),
          );
        }
        await tester.pumpAndSettle();
        expect(key.currentState!.sendUncertain, isTrue);
        expect(saved, 0);
        expect(closed, 0);
        expect(find.text('关闭并查看发件状态'), findsOneWidget);
        expect(find.textContaining('提交结果暂不确定'), findsOneWidget);
        await key.currentState!.send();
        await key.currentState!.save();
        await key.currentState!.upload();
        await tester.pumpAndSettle();
        expect(api.calls, ['POST /drafts', 'POST /drafts/draft/send']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('preserved editor can start a fresh action after unlock', (
    tester,
  ) async {
    final api = ControlledApi();
    final session = SessionEpoch();
    var saved = 0;
    final key = await mountEditor(
      tester,
      api,
      session,
      onSaved: (_) => saved++,
    );
    session.lock();
    await key.currentState!.save();
    expect(api.calls, isEmpty);
    session.unlock();
    await key.currentState!.save();
    await tester.pumpAndSettle();
    expect(api.calls, ['POST /drafts']);
    expect(saved, 1);
    expect(key.currentState!.dirty, isFalse);
  });
}
