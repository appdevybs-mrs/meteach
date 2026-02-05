import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

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

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _inited = false;

  static const int dailyReminderId = 900001;

  Future<void> init() async {
    if (_inited) return;

    // Timezone init
    tz.initializeTimeZones();
    final tzInfo = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(tzInfo.identifier));

    // Init notifications (v20 uses named param "settings")
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: handleNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    _inited = true;
  }

  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  /// Simple notification details (no actions)
  NotificationDetails _detailsSimple() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'class_reminders_channel',
        'Class Reminders',
        channelDescription: 'Reminders for classes',
        importance: Importance.max,
        priority: Priority.high,
        fullScreenIntent: true,
      ),
    );
  }

  /// Session notification details (with Snooze actions)
  NotificationDetails _detailsSession() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'class_reminders_channel',
        'Class Reminders',
        channelDescription: 'Reminders for classes',
        importance: Importance.max,
        priority: Priority.high,
        fullScreenIntent: true,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction('SNOOZE_5', 'Snooze 5m'),
          AndroidNotificationAction('SNOOZE_10', 'Snooze 10m'),
          AndroidNotificationAction('SNOOZE_15', 'Snooze 15m'),
        ],
      ),
    );
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (next.isBefore(now)) next = next.add(const Duration(days: 1));

    await _plugin.zonedSchedule(
      id: dailyReminderId,
      title: title,
      body: body,
      scheduledDate: next,
      notificationDetails: _detailsSimple(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time, // repeats daily
    );
  }

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

    final tzTime = tz.TZDateTime.from(scheduledAt, tz.local);
    final id = _makeNotifId(classId, sessionStart);

    final payloadJson = jsonEncode({
      'type': 'session',
      'classId': classId,
      'sessionStart': sessionStart.toIso8601String(),
      'title': title,
      'body': body,
      'kind': 'main',
    });

    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tzTime,
      notificationDetails: _detailsSession(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payloadJson,
    );
  }

  /// Handles notif tap + Snooze action taps (foreground + background)
  Future<void> handleNotificationResponse(NotificationResponse response) async {
    final actionId = response.actionId ?? '';
    final payload = response.payload;

    // Only snooze actions matter for us
    if (payload == null || payload.isEmpty) return;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (data['type'] != 'session') return;

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
    if (actionId == 'SNOOZE_5') snoozeMinutes = 5;
    if (actionId == 'SNOOZE_10') snoozeMinutes = 10;
    if (actionId == 'SNOOZE_15') snoozeMinutes = 15;

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
      notificationDetails: _detailsSimple(),
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
}
