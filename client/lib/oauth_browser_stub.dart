class OAuthBrowserFlow {
  String get id => '';
  bool open(String url) => false;
  void cancel() {}
}

OAuthBrowserFlow? prepareOAuthBrowser(void Function(bool) completed) => null;
bool consumeOAuthReturn() => false;
