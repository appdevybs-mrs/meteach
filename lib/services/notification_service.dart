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

  Future<void> init() async {
    if (_inited) return;

    // Timezone init
    tz.initializeTimeZones();
    final tzInfo = await FlutterTimezone.getLocalTimezone(); // TimezoneInfo
    tz.setLocalLocation(tz.getLocation(tzInfo.identifier));

    // Init notifications
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(
      settings: initSettings, // ✅ v20 uses "settings"
    );

    _inited = true;
  }

  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  NotificationDetails _details() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'class_reminders_channel',
        'Class Reminders',
        channelDescription: 'Reminders for classes',
        importance: Importance.max, // Required for heads-up
        priority: Priority.high,    // Required for heads-up
        fullScreenIntent: true,     // Helps show on lock screen
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

    if (next.isBefore(now)) {
      next = next.add(const Duration(days: 1));
    }

    await _plugin.zonedSchedule(
      id: dailyReminderId,
      title: title,
      body: body,
      scheduledDate: next,
      notificationDetails: _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time, // ✅ repeats daily
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

    // If 15 mins before has passed, but the class hasn't started yet...
    if (scheduledAt.isBefore(now) && sessionStart.isAfter(now)) {
      // Fire it in 2 seconds so you get the alert immediately
      scheduledAt = now.add(const Duration(seconds: 2));
    }
    // If the class already started, don't notify
    else if (sessionStart.isBefore(now)) {
      return;
    }

    final tzTime = tz.TZDateTime.from(scheduledAt, tz.local);
    final id = _makeNotifId(classId, sessionStart);

    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tzTime,
      notificationDetails: _details(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      // THE LINE WAS REMOVED HERE TO FIX THE COMPILER ERROR
    );
  }

  int _makeNotifId(String classId, DateTime sessionStart) {
    final raw = '$classId|${sessionStart.toIso8601String()}';
    return raw.hashCode.abs() % 2147483647;
  }
}
