import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class AppConnectivity {
  AppConnectivity._();

  static final AppConnectivity instance = AppConnectivity._();

  final Connectivity _connectivity = Connectivity();
  final ValueNotifier<bool> isOfflineListenable = ValueNotifier<bool>(false);

  bool _started = false;

  bool get isOffline => isOfflineListenable.value;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    await _refreshCurrentState();
    _connectivity.onConnectivityChanged.listen((result) {
      _setOffline(_isOfflineResult(result));
    });
  }

  Future<void> _refreshCurrentState() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _setOffline(_isOfflineResult(result));
    } catch (_) {
      // Keep the previous state if the platform cannot report connectivity.
    }
  }

  void _setOffline(bool value) {
    if (isOfflineListenable.value == value) return;
    isOfflineListenable.value = value;
  }

  bool _isOfflineResult(Object? result) {
    if (result is ConnectivityResult) {
      return result == ConnectivityResult.none;
    }
    if (result is Iterable) {
      final values = result.whereType<ConnectivityResult>().toList();
      return values.isEmpty ||
          values.every((item) => item == ConnectivityResult.none);
    }
    return false;
  }
}
