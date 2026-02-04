import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  NotificationService._();
  static final NotificationService I = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
  FlutterLocalNotificationsPlugin();

  bool _inited = false;

  static const int dailyReminderId = 900001;

  // Android channel (must be stable)
  static const String _channelId = 'class_reminders_channel';
  static const String _channelName = 'Class Reminders';
  static const String _channelDesc = 'Reminders for classes';

  Future<void> init() async {
    if (_inited) return;

    // Timezone init
    tz.initializeTimeZones();
    final tzInfo = await FlutterTimezone.getLocalTimezone(); // TimezoneInfo
    final tzName = tzInfo.name;
    tz.setLocalLocation(tz.getLocation(tzName));

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');

    const initSettings = InitializationSettings(
      android: androidInit,
    );

    // NEW API: named parameter
    await _plugin.initialize(
      initializationSettings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse resp) {
        // optional: handle taps
      },
    );

    _inited = true;
  }

  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // Android 13+ requires notification permission
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  NotificationDetails _details() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.high,
      ),
    );
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// Daily reminder: repeats every day at [hour]:[minute]
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);

    if (next.isBefore(now)) {
      next = next.add(const Duration(days: 1));
    }

    await _plugin.zonedSchedule(
      dailyReminderId,
      title,
      body,
      next,
      _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
      UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time, // repeat daily
    );
  }

  /// Session reminder: one notification at (sessionStart - minutesBefore)
  Future<void> scheduleSessionReminder({
    required String classId,
    required String title,
    required String body,
    required DateTime sessionStart,
    required int minutesBefore,
  }) async {
    final scheduledAt = sessionStart.subtract(Duration(minutes: minutesBefore));
    if (scheduledAt.isBefore(DateTime.now())) return;

    final tzTime = tz.TZDateTime.from(scheduledAt, tz.local);
    final id = _makeNotifId(classId, sessionStart);

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tzTime,
      _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
      UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  /// Compatibility for your older screen (if any code still calls scheduleReminder)
  Future<void> scheduleReminder({
    required String classId,
    required String title,
    required String body,
    required DateTime sessionStart,
    required int minutesBefore,
  }) async {
    return scheduleSessionReminder(
      classId: classId,
      title: title,
      body: body,
      sessionStart: sessionStart,
      minutesBefore: minutesBefore,
    );
  }

  int _makeNotifId(String classId, DateTime sessionStart) {
    final raw = '$classId|${sessionStart.toIso8601String()}';
    return raw.hashCode.abs() % 2147483647;
  }
}
