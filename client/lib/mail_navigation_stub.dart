void configureBrowserNavigation() {}

class MailNavigation {
  String location = '/mail';
  void listen(Future<bool> Function(String) onNavigate) {}
  void write(String route, {bool replace = false}) {
    location = route;
  }

  void protectDocument(bool Function() hasUnsavedWork) {}
  void dispose() {}
}
