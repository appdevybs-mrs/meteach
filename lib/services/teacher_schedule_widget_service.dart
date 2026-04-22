import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../teacher/teacher_schedule_data_service.dart';

class TeacherScheduleWidgetService {
  TeacherScheduleWidgetService._();

  static final TeacherScheduleWidgetService instance =
      TeacherScheduleWidgetService._();

  static const MethodChannel _channel = MethodChannel(
    'dream_english/widget_bridge',
  );
  static const String _flutterPayloadKey = 'teacher_schedule_widget_payload';

  Future<void> publishSnapshot(TeacherScheduleWidgetSnapshot snapshot) async {
    final payload = jsonEncode(snapshot.toJson());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_flutterPayloadKey, payload);
    } catch (_) {
      // Keep native bridge as the primary path if shared preferences fail.
    }

    try {
      await _channel.invokeMethod<void>('saveTeacherScheduleWidgetData', {
        'payload': payload,
      });
    } catch (_) {
      // Keep the teacher screens usable even if widget sync fails.
    }
  }

  Future<void> clearSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_flutterPayloadKey);
    } catch (_) {
      // Ignore fallback storage failures.
    }

    try {
      await _channel.invokeMethod<void>('clearTeacherScheduleWidgetData');
    } catch (_) {
      // Ignore widget bridge failures.
    }
  }
}
