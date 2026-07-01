class WebVisibilitySubscription {
  const WebVisibilitySubscription();

  void cancel() {}
}

bool isWebPageVisible() => true;

WebVisibilitySubscription listenWebPageVisibility(
  void Function(bool visible) onChanged,
) {
  return const WebVisibilitySubscription();
}
