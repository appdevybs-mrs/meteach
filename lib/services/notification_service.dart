import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'fcm_service.dart';

/// Background handler for notification taps/actions (Android).
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await NotificationService.I.init();
    await NotificationService.I.handleNotificationResponse(response);
  } catch (_) {
    // ignore
  }
}

class NotificationService {
  NotificationService._();
  static final NotificationService I = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;

  static const int dailyReminderId = 900001;

  // Separate channels so users can control Daily vs Session alerts independently in Android settings.
  static const String _dailyChannelId = 'daily_reminders_channel';
  static const String _dailyChannelName = 'Daily Reminders';
  static const String _dailyChannelDesc = 'Daily reminder notifications';

  static const String _sessionChannelId = 'class_reminders_channel';
  static const String _sessionChannelName = 'Class Reminders';
  static const String _sessionChannelDesc = 'Reminders for classes';

  Future<void> init() async {
    if (_inited) return;

    // Timezone init
    tz.initializeTimeZones();

    // flutter_timezone versions differ: sometimes returns String, sometimes object w/ identifier.
    dynamic tzInfo = await FlutterTimezone.getLocalTimezone();
    final String tzName = (tzInfo is String)
        ? tzInfo
        : (tzInfo?.identifier?.toString() ?? 'UTC');

    try {
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (_) {
      // Fallback (won't crash app)
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    // Init notifications (v20 uses named param "settings")
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    // Create/update Android notification channels (safe to call repeatedly).
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _dailyChannelId,
          _dailyChannelName,
          description: _dailyChannelDesc,
          importance: Importance.defaultImportance,
        ),
      );

      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _sessionChannelId,
          _sessionChannelName,
          description: _sessionChannelDesc,
          importance: Importance.max,
        ),
      );
    }

    _inited = true;
  }

  Future<bool> requestPermissions() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  /// Daily reminder notification details (separate channel).
  NotificationDetails _detailsDaily() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _dailyChannelId,
        _dailyChannelName,
        channelDescription: _dailyChannelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    );
  }

  /// Simple notification details (session/simple, no actions).
  NotificationDetails _detailsSimpleSession() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _sessionChannelId,
        _sessionChannelName,
        channelDescription: _sessionChannelDesc,
        importance: Importance.max,
        priority: Priority.high,
      ),
    );
  }

  /// Session notification details with dynamic Snooze actions + a Dismiss action.
  ///
  /// We only show snooze options that would still fire BEFORE class starts.
  NotificationDetails _detailsSessionWithActions({
    required DateTime sessionStart,
    required DateTime scheduledAt, // when this notif will fire
  }) {
    final now = DateTime.now();
    // Estimate remaining time until class start when the notification is shown.
    // If the notif is scheduled in the future, use scheduledAt; else use now.
    final base = scheduledAt.isAfter(now) ? scheduledAt : now;

    final remaining = sessionStart.difference(base);
    final remainingMinutes = remaining.inMinutes;

    final actions = <AndroidNotificationAction>[];

    // Always provide a dismiss/ack action (does not reschedule anything).
    actions.add(const AndroidNotificationAction('DISMISS', 'Dismiss'));

    // Only add snooze actions that still fit before class start.
    void addSnooze(int mins, String label) {
      if (remainingMinutes > mins) {
        actions.add(AndroidNotificationAction('SNOOZE_$mins', label));
      }
    }

    addSnooze(5, 'Snooze 5m');
    addSnooze(10, 'Snooze 10m');
    addSnooze(15, 'Snooze 15m');

    return NotificationDetails(
      android: AndroidNotificationDetails(
        _sessionChannelId,
        _sessionChannelName,
        channelDescription: _sessionChannelDesc,
        importance: Importance.max,
        priority: Priority.high,
        actions: actions,
      ),
    );
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// Optional helper: cancel just the daily reminder.
  Future<void> cancelDailyReminder() async {
    await _plugin.cancel(id: dailyReminderId);
  }

  /// Coach reminder: unique daily reminder per goal.
  Future<void> scheduleCoachReminder({
    required String goalId,
    required String title,
    required String body,
    required int hour,
    required int minute,
  }) async {
    await init();

    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    if (next.isBefore(now)) {
      next = next.add(const Duration(days: 1));
    }

    await _plugin.zonedSchedule(
      id: _makeCoachNotifId(goalId),
      title: title,
      body: body,
      scheduledDate: next,
      notificationDetails: _detailsDaily(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: jsonEncode({'type': 'coach', 'goalId': goalId}),
    );
  }

  Future<void> cancelCoachReminder({required String goalId}) async {
    await _plugin.cancel(id: _makeCoachNotifId(goalId));
  }

  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (next.isBefore(now)) next = next.add(const Duration(days: 1));

    await _plugin.zonedSchedule(
      id: dailyReminderId,
      title: title,
      body: body,
      scheduledDate: next,
      notificationDetails: _detailsDaily(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time, // repeats daily
    );
  }

  /// Optional helper: cancel a specific session reminder (main notif).
  Future<void> cancelSessionReminder({
    required String classId,
    required DateTime sessionStart,
  }) async {
    final id = _makeNotifId(classId, sessionStart);
    await _plugin.cancel(id: id);
  }

  /// Optional helper: cancel a specific snooze reminder.
  Future<void> cancelSnoozeReminder({
    required String classId,
    required DateTime sessionStart,
    required int snoozeMinutes,
  }) async {
    final id = _makeSnoozeNotifId(classId, sessionStart, snoozeMinutes);
    await _plugin.cancel(id: id);
  }

  /// Improved: auto-enhance body with time info (does NOT change your method signature).
  Future<void> scheduleSessionReminder({
    required String classId,
    required String title,
    required String body,
    required DateTime sessionStart,
    required int minutesBefore,
  }) async {
    var scheduledAt = sessionStart.subtract(Duration(minutes: minutesBefore));
    final now = DateTime.now();

    // If "minutesBefore" already passed, but class hasn't started, fire quickly
    if (scheduledAt.isBefore(now) && sessionStart.isAfter(now)) {
      scheduledAt = now.add(const Duration(seconds: 2));
    } else if (sessionStart.isBefore(now)) {
      // Class already started -> no notif
      return;
    }

    // Add extra context to the body (safe; doesn't break callers).
    final enhancedBody = _enhanceSessionBody(
      originalBody: body,
      sessionStart: sessionStart,
      scheduledAt: scheduledAt,
    );

    final tzTime = tz.TZDateTime.from(scheduledAt, tz.local);
    final id = _makeNotifId(classId, sessionStart);

    final payloadJson = jsonEncode({
      'type': 'session',
      'classId': classId,
      'sessionStart': sessionStart.toIso8601String(),
      'title': title,
      'body': enhancedBody,
      'kind': 'main',
    });

    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: enhancedBody,
      scheduledDate: tzTime,
      notificationDetails: _detailsSessionWithActions(
        sessionStart: sessionStart,
        scheduledAt: scheduledAt,
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payloadJson,
    );
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _formatLocalTime(DateTime dt) {
    // Simple local HH:mm format (keeps this file dependency-free).
    return '${_two(dt.hour)}:${_two(dt.minute)}';
  }

  String _enhanceSessionBody({
    required String originalBody,
    required DateTime sessionStart,
    required DateTime scheduledAt,
  }) {
    final startTime = _formatLocalTime(sessionStart);
    final diff = sessionStart.difference(scheduledAt).inMinutes;

    // If original body is empty, create one. If not, append helpful info.
    final base = originalBody.trim().isEmpty
        ? 'Starts at $startTime'
        : originalBody.trim();

    if (diff <= 0) {
      return '$base • Starts at $startTime';
    }
    return '$base • Starts at $startTime • in $diff min';
  }

  /// Handles notif tap + action taps (foreground + background)
  Future<void> handleNotificationResponse(NotificationResponse response) async {
    final actionId = response.actionId ?? '';
    final payload = response.payload;

    // If user tapped "Dismiss" we do nothing (just closes notif).
    if (actionId == 'DISMISS') return;

    // Most actions need payload.
    if (payload == null || payload.isEmpty) return;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = (data['type'] ?? '').toString().trim().toLowerCase();

    // Normal notification tap (non-action button): open target screen.
    if (actionId.isEmpty) {
      await FCMService.I.handleLocalNotificationTapPayload(data);
      return;
    }

    if (type != 'session') return;

    final sessionStartStr = (data['sessionStart'] ?? '').toString();
    final classId = (data['classId'] ?? '').toString();
    final title = (data['title'] ?? 'Class Starting').toString();
    final body = (data['body'] ?? '').toString();

    DateTime sessionStart;
    try {
      sessionStart = DateTime.parse(sessionStartStr);
    } catch (_) {
      return;
    }

    int? snoozeMinutes;
    // Support both your original IDs and dynamic ones like SNOOZE_5 / SNOOZE_10 / SNOOZE_15
    if (actionId == 'SNOOZE_5' || actionId == 'SNOOZE_05') snoozeMinutes = 5;
    if (actionId == 'SNOOZE_10') snoozeMinutes = 10;
    if (actionId == 'SNOOZE_15') snoozeMinutes = 15;

    // Also allow future dynamic snooze actions (SNOOZE_30, etc.)
    if (snoozeMinutes == null && actionId.startsWith('SNOOZE_')) {
      final raw = actionId.replaceFirst('SNOOZE_', '');
      final parsed = int.tryParse(raw);
      if (parsed != null) snoozeMinutes = parsed;
    }

    if (snoozeMinutes == null) return;

    // Cutoff: do NOT allow snooze after class start
    if (!DateTime.now().isBefore(sessionStart)) return;

    await scheduleSnoozeOnce(
      classId: classId,
      title: title,
      body: body,
      sessionStart: sessionStart,
      snoozeMinutes: snoozeMinutes,
    );
  }

  Future<void> scheduleSnoozeOnce({
    required String classId,
    required String title,
    required String body,
    required DateTime sessionStart,
    required int snoozeMinutes,
  }) async {
    final now = DateTime.now();
    final scheduledAt = now.add(Duration(minutes: snoozeMinutes));

    // If snooze would fire at/after class start, block it
    if (!scheduledAt.isBefore(sessionStart)) return;

    final tzTime = tz.TZDateTime.from(scheduledAt, tz.local);
    final id = _makeSnoozeNotifId(classId, sessionStart, snoozeMinutes);

    final payloadJson = jsonEncode({
      'type': 'session',
      'classId': classId,
      'sessionStart': sessionStart.toIso8601String(),
      'title': title,
      'body': body,
      'kind': 'snooze',
      'mins': snoozeMinutes,
    });

    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tzTime,
      notificationDetails: _detailsSimpleSession(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payloadJson,
    );
  }

  int _makeNotifId(String classId, DateTime sessionStart) {
    final raw = '$classId|${sessionStart.toIso8601String()}';
    return raw.hashCode.abs() % 2147483647;
  }

  int _makeSnoozeNotifId(String classId, DateTime sessionStart, int mins) {
    final raw = 'SNOOZE|$classId|${sessionStart.toIso8601String()}|$mins';
    return raw.hashCode.abs() % 2147483647;
  }

  int _makeCoachNotifId(String goalId) {
    final raw = 'COACH|$goalId';
    return raw.hashCode.abs() % 2147483647;
  }
}
