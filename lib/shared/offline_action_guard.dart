import 'dart:async';

import 'package:flutter/material.dart';

import 'app_connectivity.dart';
import 'app_feedback.dart';

class OfflineActionGuard {
  static DateTime? _lastToastAt;
  static const int _exclusiveCooldownMs = 700;
  static final Set<String> _exclusiveInFlight = <String>{};
  static final Map<String, int> _exclusiveLastAttemptAt = <String, int>{};

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

  static Future<void> runExclusive(
    BuildContext context,
    String key,
    FutureOr<void> Function() action, {
    String message =
        'No internet connection. Check your internet and try again.',
    Duration toastCooldown = const Duration(seconds: 2),
    bool requireOnline = true,
  }) async {
    if (requireOnline) {
      if (!ensureOnline(
        context,
        message: message,
        toastCooldown: toastCooldown,
      )) {
        return;
      }
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastAttemptMs = _exclusiveLastAttemptAt[key];
    if (lastAttemptMs != null && nowMs - lastAttemptMs < _exclusiveCooldownMs) {
      return;
    }
    if (_exclusiveInFlight.contains(key)) {
      return;
    }

    _exclusiveLastAttemptAt[key] = nowMs;
    _exclusiveInFlight.add(key);

    try {
      await action();
    } finally {
      _exclusiveInFlight.remove(key);
    }
  }
}
