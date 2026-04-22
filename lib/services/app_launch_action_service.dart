import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/app_globals.dart';
import '../teacher/teacher_schedule.dart';

class AppLaunchActionService with WidgetsBindingObserver {
  AppLaunchActionService._();

  static final AppLaunchActionService instance = AppLaunchActionService._();
  static const MethodChannel _channel = MethodChannel(
    'dream_english/widget_bridge',
  );
  static const String teacherScheduleAction = 'teacher_schedule';

  bool _initialized = false;
  bool _consumeInProgress = false;

  void init() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      maybeHandlePendingAction();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      maybeHandlePendingAction();
    }
  }

  Future<void> onResolvedRole(String role) async {
    final normalized = role.trim().toLowerCase();
    if (normalized == 'teacher') {
      await maybeHandlePendingAction();
    }
  }

  Future<void> maybeHandlePendingAction() async {
    if (_consumeInProgress) return;
    _consumeInProgress = true;
    try {
      final action = await _getPendingAction();
      if (action != teacherScheduleAction) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final roleSnap = await FirebaseDatabase.instance
          .ref('users/${user.uid}/role')
          .get();
      final role = (roleSnap.value ?? '').toString().trim().toLowerCase();
      if (role != 'teacher') return;

      final nav = appNavigatorKey.currentState;
      if (nav == null) return;
      await _clearPendingAction();
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const TeacherSchedule(),
          settings: const RouteSettings(name: 'teacher_schedule_widget'),
        ),
      );
    } catch (_) {
      // Ignore action routing failures and let normal app navigation continue.
    } finally {
      _consumeInProgress = false;
    }
  }

  Future<String> _getPendingAction() async {
    try {
      final action = await _channel.invokeMethod<String>(
        'getPendingLaunchAction',
      );
      return (action ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> _clearPendingAction() async {
    try {
      await _channel.invokeMethod<void>('clearPendingLaunchAction');
    } catch (_) {
      // Ignore bridge clear failures.
    }
  }
}
