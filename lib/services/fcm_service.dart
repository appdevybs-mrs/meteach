import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../admin/admin_classes.dart';
import '../admin/admin_mail_inbox_screen.dart';
import '../admin/admin_payments.dart';
import '../admin/admin_priority_alerts_screen.dart';
import '../admin/admin_teacher_reminders_screen.dart';
import '../admin/mail_topic_thread_screen.dart';
import '../admin/admin_admin_todos_screen.dart';
import '../admin/admin_job_applications_screen.dart';
import '../learner/learner_booking_screen.dart';
import '../learner/learner_courses_screen.dart';
import '../learner/learner_mail_screen.dart';
import '../learner/learner_reminders_list_screen.dart';
import '../learner/learner_mail_thread_screen.dart';
import '../main.dart'; // appNavigatorKey + messengerKey
import '../teacher/teacher_reminder.dart';
import '../teacher/teacher_schedule.dart';
import '../teacher/teacher_mail.dart';
import '../teacher/teacher_mail_thread_screen.dart';
import 'mail_thread_by_id_screen.dart'; // safe fallback only
import 'route_state.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();
    await FCMService.I._ensureLocalInit();

    // If FCM includes "notification", Android already shows system notification in bg/killed.
    if (message.notification != null) return;

    await FCMService.I._showFromRemoteMessage(message);
  } catch (_) {}
}

class FCMService {
  FCMService._();
  static final FCMService I = FCMService._();
  static String? _lastSavedUid;
  static String? _lastSavedToken;

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _localInited = false;
  bool _initialized = false;
  final Set<String> _handledTapKeys = <String>{};

  static const String chMessages = 'ch_messages_v2';
  static const String chReminders = 'ch_reminders_v2';
  static const String chMail = 'ch_mail_v2';
  static const String chDefault = 'ch_default_v2';
  static const String _soundName = 'ybs_notify';
  static const String _iosSoundName = 'ybs_notify.caf';

  String _canonicalType(dynamic raw) {
    final type = (raw ?? '').toString().trim().toLowerCase();
    if (type == 'email') return 'mail';
    if (type == 'chat') return 'message';
    if (type == 'class') return 'reminder';
    return type;
  }

  String _eventIdFromData(Map<String, dynamic> data) {
    return (data['eventId'] ?? '').toString().trim();
  }

  /// REQUIRED by AuthGate (your app calls this)
  static Future<void> syncTokenAfterLogin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final token = await FirebaseMessaging.instance.getToken();

    if (token != null && token.isNotEmpty) {
      if (_lastSavedUid == uid && _lastSavedToken == token) return;
      await saveTokenToDatabase(token);
      _lastSavedUid = uid;
      _lastSavedToken = token;
    }
  }

  /// Call once in main()
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _requestPermission();
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    await _ensureLocalInit();

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // App opened from SYSTEM notification (terminated)
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      _handleNotificationTapPayload(jsonEncode(initial.data));
    }

    // Token may exist BEFORE login
    final token = await _messaging.getToken();
    if (token != null && token.isNotEmpty) {
      await saveTokenToDatabase(token);
    }

    _messaging.onTokenRefresh.listen((newToken) async {
      await saveTokenToDatabase(newToken);
      _lastSavedUid = FirebaseAuth.instance.currentUser?.uid;
      _lastSavedToken = newToken;
    });

    // Foreground push
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final data = Map<String, dynamic>.from(message.data);
      final type = _canonicalType(data['type']);

      // If already inside this mail thread, ignore notif
      if (type == 'mail') {
        final threadId = (data['threadId'] ?? '').toString().trim();
        if (threadId.isNotEmpty && RouteState.currentMailThreadId == threadId) {
          return;
        }
      }

      // Others
      await _showFromRemoteMessage(message);
    });

    // Background -> user tapped SYSTEM notification
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _handleNotificationTapPayload(jsonEncode(message.data));
    });
  }

  Future<void> _requestPermission() async {
    if (kIsWeb) {
      // Web: do NOT use Platform.* and iOS options don't apply
      await _messaging.requestPermission();
      return;
    }

    if (Platform.isIOS) {
      await _messaging.requestPermission(alert: true, badge: true, sound: true);
    } else {
      await _messaging.requestPermission();
    }
  }

  /// Save token under /fcm_tokens/{uid}
  static Future<void> saveTokenToDatabase(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseDatabase.instance.ref('fcm_tokens/$uid').update({
        'token': token,
        'platform': kIsWeb ? 'web' : (Platform.isAndroid ? 'android' : 'other'),
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  Future<void> _ensureLocalInit() async {
    if (_localInited) return;
    if (kIsWeb) {
      _localInited = true;
      return;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
    );

    await _local.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;

        // Default tap handling
        _handleNotificationTapPayload(payload);
      },
    );

    // If app was opened from LOCAL notification (terminated)
    final launch = await _local.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (payload != null && payload.isNotEmpty) {
      Future.microtask(() => _handleNotificationTapPayload(payload));
    }

    final androidPlugin = _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chMessages,
          'Messages',
          description: 'Chat message notifications',
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound(_soundName),
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chReminders,
          'Reminders',
          description: 'Reminders and class alerts',
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound(_soundName),
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chMail,
          'Mail',
          description: 'Mail and inbox notifications',
          importance: Importance.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound(_soundName),
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chDefault,
          'General',
          description: 'General notifications',
          importance: Importance.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound(_soundName),
        ),
      );
    }

    _localInited = true;
  }

  Future<void> _showFromRemoteMessage(RemoteMessage message) async {
    if (kIsWeb) return;

    final data = Map<String, dynamic>.from(message.data);
    final type = _canonicalType(data['type']);
    if (type.isNotEmpty) {
      data['type'] = type;
    }

    final title =
        (data['title'] ?? message.notification?.title ?? 'Notification')
            .toString();
    final body = (data['body'] ?? message.notification?.body ?? '').toString();

    String channelId = chDefault;
    String channelName = 'General';

    if (type == 'message') {
      channelId = chMessages;
      channelName = 'Messages';
    } else if (type == 'reminder' ||
        type == 'admin_todo' ||
        type == 'flash_message' ||
        type == 'recorded_comment' ||
        type == 'job_application') {
      channelId = chReminders;
      channelName = 'Reminders';
    } else if (type == 'mail') {
      channelId = chMail;
      channelName = 'Mail';
    }

    final eventId = _eventIdFromData(data);

    final String seed = [
      (data['type'] ?? '').toString(),
      eventId,
      (data['threadId'] ?? '').toString(),
      (data['reminderId'] ?? '').toString(),
      (data['courseId'] ?? '').toString(),
      (message.messageId ?? '').toString(),
      DateTime.now().millisecondsSinceEpoch.toString(),
    ].join('|');
    final int notifId = seed.hashCode.abs() % 2147483647;

    await _local.show(
      id: notifId,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          sound: const RawResourceAndroidNotificationSound(_soundName),
        ),
        iOS: const DarwinNotificationDetails(sound: _iosSoundName),
      ),
      payload: data.isEmpty ? null : jsonEncode(data),
    );
  }

  String _normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();

    if (s == 'admin' ||
        s == 'adin' ||
        s == 'admn' ||
        s == 'adm' ||
        s == 'administration' ||
        s == 'administrator') {
      return 'admin';
    }

    if (s == 'teacher' ||
        s == 'teachers' ||
        s == 'teacher(s)' ||
        s == 'teach' ||
        s == 'instructor' ||
        s == 'prof') {
      return 'teacher';
    }

    if (s == 'learner' ||
        s == 'learners' ||
        s == 'learner(s)' ||
        s == 'lerner' ||
        s == 'student' ||
        s == 'pupil') {
      return 'learner';
    }

    return '';
  }

  Future<String> _fetchCurrentUserRole() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    if (uid == null || uid.trim().isEmpty) return '';

    try {
      final token = await user?.getIdTokenResult(true);
      final claimRole = token?.claims?['role'];
      final normalizedClaimRole = _normalizeRole(claimRole);
      if (normalizedClaimRole.isNotEmpty) return normalizedClaimRole;
    } catch (_) {}

    try {
      final snap = await FirebaseDatabase.instance.ref('users/$uid/role').get();
      return _normalizeRole(snap.value);
    } catch (_) {
      return '';
    }
  }

  Future<String> _fetchMailSubject(String threadId) async {
    if (threadId.trim().isEmpty) return '';

    try {
      final threadSnap = await FirebaseDatabase.instance
          .ref('mail_threads/$threadId/subject')
          .get();
      final threadSubject = (threadSnap.value ?? '').toString().trim();
      if (threadSubject.isNotEmpty) return threadSubject;
    } catch (_) {}

    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null || myUid.trim().isEmpty) return '';

    try {
      final indexSnap = await FirebaseDatabase.instance
          .ref('mail_index/$myUid/$threadId/subject')
          .get();
      return (indexSnap.value ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  Future<String> _fetchPeerName(String peerUid, {String seed = ''}) async {
    final seeded = seed.trim();
    if (seeded.isNotEmpty) return seeded;
    if (peerUid.trim().isEmpty) return '';

    try {
      final snap = await FirebaseDatabase.instance.ref('users/$peerUid').get();
      if (!snap.exists || snap.value is! Map) return '';

      final m = Map<String, dynamic>.from(snap.value as Map);
      final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$fn $ln').trim();
      if (full.isNotEmpty) return full;

      final email = (m['email'] ?? '').toString().trim();
      return email;
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, dynamic>?> _fetchAdminTeacherMap(String peerUid) async {
    if (peerUid.trim().isEmpty) return null;

    try {
      final userSnap = await FirebaseDatabase.instance
          .ref('users/$peerUid')
          .get();
      final v = userSnap.value;

      if (v is! Map) return null;

      return Map<String, dynamic>.from(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openMailNotificationByRole(Map<String, dynamic> data) async {
    final threadId = (data['threadId'] ?? '').toString().trim();
    final peerUid = (data['peerUid'] ?? '').toString().trim();
    final seededPeerName = (data['peerName'] ?? '').toString().trim();

    if (threadId.isEmpty || peerUid.isEmpty) {
      await _openMessageCenterByRole();
      return;
    }
    if (RouteState.currentMailThreadId == threadId) return;

    final nav = await _waitForNavigator();
    if (nav == null) return;

    final targetName = '/mail/thread/$threadId';

    bool found = false;
    nav.popUntil((route) {
      if (route.settings.name == targetName) {
        found = true;
        return true;
      }
      return route.isFirst;
    });

    if (found) return;

    final role = await _fetchCurrentUserRole();
    final subject = await _fetchMailSubject(threadId);
    final peerName = await _fetchPeerName(peerUid, seed: seededPeerName);

    if (role == 'teacher') {
      nav.push(
        MaterialPageRoute(
          settings: RouteSettings(name: targetName),
          builder: (_) => TeacherMailThreadScreen(
            threadId: threadId,
            peerUid: peerUid,
            peerName: peerName.isEmpty ? 'User' : peerName,
            subject: subject,
          ),
        ),
      );
      return;
    }

    if (role == 'learner') {
      nav.push(
        MaterialPageRoute(
          settings: RouteSettings(name: targetName),
          builder: (_) => LearnerMailThreadScreen(
            threadId: threadId,
            peerUid: peerUid,
            peerName: peerName.isEmpty ? 'User' : peerName,
            subject: subject,
          ),
        ),
      );
      return;
    }

    if (role == 'admin') {
      final userMap = await _fetchAdminTeacherMap(peerUid);
      if (userMap == null) {
        nav.push(
          MaterialPageRoute(builder: (_) => const AdminMailInboxScreen()),
        );
        return;
      }

      nav.push(
        MaterialPageRoute(
          settings: RouteSettings(name: targetName),
          builder: (_) => MailTopicThreadScreen(
            threadId: threadId,
            peerUid: peerUid,
            peerName: peerName.isEmpty ? 'User' : peerName,
          ),
        ),
      );
      return;
    }

    // Safe fallback only if role is missing/unknown
    nav.push(
      MaterialPageRoute(
        settings: RouteSettings(name: targetName),
        builder: (_) =>
            MailThreadByIdScreen(threadId: threadId, peerUid: peerUid),
      ),
    );
  }

  Future<NavigatorState?> _waitForNavigator() async {
    for (int i = 0; i < 8; i++) {
      final nav = appNavigatorKey.currentState;
      if (nav != null) return nav;
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    return appNavigatorKey.currentState;
  }

  Future<void> _openReminderByRole(Map<String, dynamic> data) async {
    final role = await _fetchCurrentUserRole();
    final route = (data['route'] ?? '').toString().trim().toLowerCase();
    final nav = await _waitForNavigator();
    if (nav == null) return;

    if (role == 'teacher' || route == 'teacher_reminders') {
      nav.push(
        MaterialPageRoute(builder: (_) => const TeacherReminderScreen()),
      );
      return;
    }

    if (role == 'learner' || route == 'learner') {
      nav.push(
        MaterialPageRoute(builder: (_) => const LearnerRemindersListScreen()),
      );
      return;
    }

    if (role == 'admin') {
      nav.push(
        MaterialPageRoute(builder: (_) => const AdminTeacherRemindersScreen()),
      );
    }
  }

  Future<void> _openAdminTodoByRole(Map<String, dynamic> data) async {
    final role = await _fetchCurrentUserRole();
    final nav = await _waitForNavigator();
    if (nav == null) return;
    if (role != 'admin') return;

    nav.push(MaterialPageRoute(builder: (_) => const AdminAdminTodosScreen()));
  }

  Future<void> _openBookingByRole(Map<String, dynamic> data) async {
    final role = await _fetchCurrentUserRole();
    final targetRole = _normalizeRole(data['targetRole']);
    final nav = await _waitForNavigator();
    if (nav == null) return;

    if (role == 'admin' || targetRole == 'admin') {
      nav.push(MaterialPageRoute(builder: (_) => const AdminClassesScreen()));
      return;
    }

    if (role == 'teacher' || targetRole == 'teacher') {
      nav.push(MaterialPageRoute(builder: (_) => const TeacherSchedule()));
      return;
    }

    final courseId = (data['courseId'] ?? '').toString().trim();
    nav.push(
      MaterialPageRoute(
        builder: (_) =>
            LearnerBookingScreen(courseId: courseId.isEmpty ? null : courseId),
      ),
    );
  }

  Future<void> _openPaymentByRole(Map<String, dynamic> data) async {
    final role = await _fetchCurrentUserRole();
    final nav = await _waitForNavigator();
    if (nav == null) return;

    if (role == 'admin') {
      nav.push(MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()));
      return;
    }

    final courseKey = (data['courseId'] ?? data['courseKey'] ?? '')
        .toString()
        .trim();

    nav.push(
      MaterialPageRoute(
        builder: (_) => LearnerCoursesScreen(
          initialCourseKey: courseKey.isEmpty ? null : courseKey,
        ),
      ),
    );
  }

  Future<void> _openRecordedCommentByRole(Map<String, dynamic> data) async {
    final role = await _fetchCurrentUserRole();
    final nav = await _waitForNavigator();
    if (nav == null) return;

    if (role == 'admin') {
      nav.push(MaterialPageRoute(builder: (_) => const AdminClassesScreen()));
      return;
    }

    if (role == 'teacher') {
      nav.push(MaterialPageRoute(builder: (_) => const TeacherSchedule()));
      return;
    }

    final courseId = (data['courseId'] ?? '').toString().trim();
    nav.push(
      MaterialPageRoute(
        builder: (_) => LearnerCoursesScreen(
          initialCourseKey: courseId.isEmpty ? null : courseId,
        ),
      ),
    );
  }

  Future<void> _openJobApplicationsByRole() async {
    final role = await _fetchCurrentUserRole();
    if (role != 'admin') return;
    final nav = await _waitForNavigator();
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(builder: (_) => const AdminJobApplicationsScreen()),
    );
  }

  String _payloadAction(Map<String, dynamic> data) {
    final route = (data['route'] ?? '').toString().trim().toLowerCase();
    final type = _canonicalType(data['type']);

    if (route == 'mail_thread' || type == 'mail' || type == 'message') {
      return 'mail';
    }
    if (route == 'teacher_reminders' || type == 'reminder') {
      return 'reminder';
    }
    if (route == 'admin_todos' || type == 'admin_todo') {
      return 'admin_todo';
    }
    if (type == 'booking') {
      return 'booking';
    }
    if (type == 'payment') {
      return 'payment';
    }
    if (route == 'recorded_comment' || type == 'recorded_comment') {
      return 'recorded_comment';
    }
    if (route == 'job_applications' || type == 'job_application') {
      return 'job_application';
    }
    if (route == 'flash_messages' || type == 'flash_message') {
      return 'flash_message';
    }
    return '';
  }

  Future<void> _openMessageCenterByRole() async {
    final role = await _fetchCurrentUserRole();
    final nav = await _waitForNavigator();
    if (nav == null) return;

    if (role == 'teacher') {
      nav.push(MaterialPageRoute(builder: (_) => const TeacherMailScreen()));
      return;
    }
    if (role == 'learner') {
      nav.push(MaterialPageRoute(builder: (_) => const LearnerMailScreen()));
      return;
    }
    if (role == 'admin') {
      nav.push(MaterialPageRoute(builder: (_) => const AdminMailInboxScreen()));
    }
  }

  Future<void> _openFlashAlertByRole() async {
    final role = await _fetchCurrentUserRole();
    final nav = await _waitForNavigator();
    if (nav == null) return;

    if (role == 'admin') {
      nav.push(
        MaterialPageRoute(builder: (_) => const AdminPriorityAlertsScreen()),
      );
      return;
    }

    nav.popUntil((route) => route.isFirst);
  }

  String _tapDedupKey(Map<String, dynamic> data) {
    final eventId = _eventIdFromData(data);
    if (eventId.isNotEmpty) {
      return 'event:$eventId';
    }

    final action = _payloadAction(data);
    if (action.isEmpty) return '';

    final id = [
      action,
      (data['threadId'] ?? '').toString(),
      (data['reminderId'] ?? '').toString(),
      (data['courseId'] ?? '').toString(),
      (data['teacherUid'] ?? '').toString(),
      (data['learnerUid'] ?? '').toString(),
      (data['time'] ?? '').toString(),
      (data['dayKey'] ?? '').toString(),
    ].join('|');

    return id;
  }

  void _handleNotificationTapPayload(String payload) {
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    final dedupKey = _tapDedupKey(data);
    if (dedupKey.isNotEmpty && _handledTapKeys.contains(dedupKey)) {
      return;
    }

    if (dedupKey.isNotEmpty) {
      _handledTapKeys.add(dedupKey);
      if (_handledTapKeys.length > 60) {
        _handledTapKeys.remove(_handledTapKeys.first);
      }
    }

    final action = _payloadAction(data);

    final uid = FirebaseAuth.instance.currentUser?.uid;
    final eventId = _eventIdFromData(data);
    if (uid != null && uid.trim().isNotEmpty && eventId.isNotEmpty) {
      FirebaseDatabase.instance
          .ref('notifications_inbox/$uid/$eventId')
          .update({'status': 'opened', 'openedAt': ServerValue.timestamp})
          .catchError((_) {});
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (action == 'mail') {
        await _openMailNotificationByRole(data);
        return;
      }
      if (action == 'reminder') {
        await _openReminderByRole(data);
        return;
      }
      if (action == 'admin_todo') {
        await _openAdminTodoByRole(data);
        return;
      }
      if (action == 'booking') {
        await _openBookingByRole(data);
        return;
      }
      if (action == 'payment') {
        await _openPaymentByRole(data);
        return;
      }
      if (action == 'recorded_comment') {
        await _openRecordedCommentByRole(data);
        return;
      }
      if (action == 'job_application') {
        await _openJobApplicationsByRole();
        return;
      }
      if (action == 'flash_message') {
        await _openFlashAlertByRole();
      }
    });
  }

  Future<void> handleLocalNotificationTapPayload(
    Map<String, dynamic> data,
  ) async {
    final type = _canonicalType(data['type']);
    final nav = await _waitForNavigator();
    if (nav == null) return;

    if (type == 'session') {
      final role = await _fetchCurrentUserRole();
      if (role == 'teacher') {
        nav.push(MaterialPageRoute(builder: (_) => const TeacherSchedule()));
      } else {
        final classId = (data['classId'] ?? '').toString();
        final maybeCourseId = classId.split('_').first.trim();
        nav.push(
          MaterialPageRoute(
            builder: (_) => LearnerBookingScreen(
              courseId: maybeCourseId.isEmpty ? null : maybeCourseId,
            ),
          ),
        );
      }
      return;
    }

    if (type == 'coach') {
      nav.push(
        MaterialPageRoute(builder: (_) => const LearnerRemindersListScreen()),
      );
    }
  }
}
