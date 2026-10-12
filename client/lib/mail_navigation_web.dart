import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

// Disable the engine's competing single-entry history before runApp.
void configureBrowserNavigation() => ui_web.urlStrategy = null;
@JS('HarborNavigation.location')
external JSString _location();
@JS('HarborNavigation.listen')
external void _listen(JSFunction callback);
@JS('HarborNavigation.write')
external void _write(JSString route, JSBoolean replace);
@JS('HarborNavigation.protectDocument')
external void _protectDocument(JSFunction callback);
@JS('HarborNavigation.dispose')
external void _dispose();

class MailNavigation {
  String get location => _location().toDart;
  void listen(Future<bool> Function(String) onNavigate) {
    _listen(
      ((JSString route) => onNavigate(
            route.toDart,
          ).then((accepted) => accepted.toJS).toJS).toJS,
    );
  }

  void write(String route, {bool replace = false}) =>
      _write(route.toJS, replace.toJS);
  void protectDocument(bool Function() hasUnsavedWork) =>
      _protectDocument((() => hasUnsavedWork().toJS).toJS);
  void dispose() => _dispose();
}
