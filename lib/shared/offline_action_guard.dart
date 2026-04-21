import 'dart:async';

import 'package:flutter/material.dart';

import 'app_connectivity.dart';
import 'app_feedback.dart';

class OfflineActionGuard {
  static DateTime? _lastToastAt;

  static bool ensureOnline(
    BuildContext context, {
    String message =
        'No internet connection. Check your internet and try again.',
    Duration toastCooldown = const Duration(seconds: 2),
  }) {
    if (!AppConnectivity.instance.isOffline) return true;

    final now = DateTime.now();
    if (_lastToastAt == null ||
        now.difference(_lastToastAt!) >= toastCooldown) {
      _lastToastAt = now;
      AppToast.show(context, message, type: AppToastType.error);
    }
    return false;
  }

  static Future<void> run(
    BuildContext context,
    FutureOr<void> Function() action, {
    String message =
        'No internet connection. Check your internet and try again.',
    Duration toastCooldown = const Duration(seconds: 2),
  }) async {
    if (!ensureOnline(
      context,
      message: message,
      toastCooldown: toastCooldown,
    )) {
      return;
    }
    await action();
  }
}
