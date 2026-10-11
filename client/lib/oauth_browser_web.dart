import 'dart:js_interop';

@JS('HarborOAuth.prepare')
external JSString _prepare(JSFunction completed);
@JS('HarborOAuth.open')
external JSBoolean _open(JSString id, JSString url);
@JS('HarborOAuth.cancel')
external void _cancel(JSString id);
@JS('HarborOAuth.consumeReturn')
external JSBoolean _consumeReturn();

class OAuthBrowserFlow {
  final String id;
  OAuthBrowserFlow(this.id);
  bool open(String url) => _open(id.toJS, url.toJS).toDart;
  void cancel() => _cancel(id.toJS);
}

OAuthBrowserFlow? prepareOAuthBrowser(void Function(bool) completed) {
  final id = _prepare(((JSBoolean success) => completed(success.toDart)).toJS)
      .toDart;
  if (id.isEmpty) {
    throw StateError('授权窗口被浏览器拦截，请允许此站点弹出窗口后重试');
  }
  return OAuthBrowserFlow(id);
}

bool consumeOAuthReturn() => _consumeReturn().toDart;
