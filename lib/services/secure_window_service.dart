import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SecureWindowService {
  SecureWindowService._();

  static const MethodChannel _channel = MethodChannel(
    'dream_english/secure_window',
  );

  static Future<void> setSecureEnabled(bool enabled) async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;

    try {
      await _channel.invokeMethod<void>(
        enabled ? 'enableSecureWindow' : 'disableSecureWindow',
      );
    } catch (_) {
      // Best-effort only; never block learner flow.
    }
  }
}
