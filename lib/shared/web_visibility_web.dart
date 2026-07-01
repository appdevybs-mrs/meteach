// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;

bool _windowFocused = true;

class WebVisibilitySubscription {
  WebVisibilitySubscription(this._subscriptions);

  final List<StreamSubscription<html.Event>> _subscriptions;

  void cancel() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
  }
}

bool isWebPageVisible() {
  return html.document.visibilityState != 'hidden' && _windowFocused;
}

WebVisibilitySubscription listenWebPageVisibility(
  void Function(bool visible) onChanged,
) {
  void notify(_) => onChanged(isWebPageVisible());
  void focus(html.Event event) {
    _windowFocused = true;
    notify(event);
  }

  void blur(html.Event event) {
    _windowFocused = false;
    notify(event);
  }

  return WebVisibilitySubscription([
    html.document.onVisibilityChange.listen(notify),
    html.window.onFocus.listen(focus),
    html.window.onBlur.listen(blur),
  ]);
}
