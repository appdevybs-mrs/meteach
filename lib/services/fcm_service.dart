import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();
    await FCMService.I._ensureLocalInit();
    await FCMService.I._showFromRemoteMessage(message);
  } catch (_) {}
}

class FCMService {
  FCMService._();
  static final FCMService I = FCMService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  bool _localInited = false;

  static const String chMessages = 'ch_messages';
  static const String chReminders = 'ch_reminders';
  static const String chMail = 'ch_mail';
  static const String chDefault = 'ch_default';

  /// Call once in main()
  Future<void> init() async {
    await _requestPermission();
    await _ensureLocalInit();

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Token may exist BEFORE login, so we still print it.
    final token = await _messaging.getToken();
    print("🔥 FCM TOKEN (startup): $token");

    // Try saving (may skip if not logged in yet)
    if (token != null && token.isNotEmpty) {
      await saveTokenToDatabase(token);
    }

    // Save again whenever token refreshes
    _messaging.onTokenRefresh.listen((newToken) async {
      print("🔄 FCM TOKEN REFRESH: $newToken");
      await saveTokenToDatabase(newToken);
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      await _showFromRemoteMessage(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      // navigation later
    });
  }

  /// ✅ IMPORTANT: call this after login (AuthGate)
  static Future<void> syncTokenAfterLogin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      print('⚠️ syncTokenAfterLogin: user is null');
      return;
    }

    final token = await FirebaseMessaging.instance.getToken();
    print('✅ syncTokenAfterLogin uid=$uid token=$token');

    if (token != null && token.isNotEmpty) {
      await saveTokenToDatabase(token);
    }
  }

  Future<void> _requestPermission() async {
    if (Platform.isIOS) {
      await _messaging.requestPermission(alert: true, badge: true, sound: true);
    } else {
      await _messaging.requestPermission();
    }
  }

  /// ✅ Save token under /fcm_tokens/{uid}
  static Future<void> saveTokenToDatabase(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      print('⚠️ saveTokenToDatabase skipped: user not logged in');
      return;
    }

    try {
      await FirebaseDatabase.instance.ref('fcm_tokens/$uid').update({
        'token': token,
        'platform': Platform.isAndroid ? 'android' : 'other',
        'updatedAt': ServerValue.timestamp,
      });
      print('✅ Token saved to RTDB: fcm_tokens/$uid');
    } catch (e) {
      print('❌ Token save failed: $e');
    }
  }

  Future<void> _ensureLocalInit() async {
    if (_localInited) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _local.initialize(settings: initSettings);

    final androidPlugin =
    _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chMessages,
          'Messages',
          description: 'Chat message notifications',
          importance: Importance.max,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chReminders,
          'Reminders',
          description: 'Reminders and class alerts',
          importance: Importance.max,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chMail,
          'Mail',
          description: 'Mail and inbox notifications',
          importance: Importance.high,
        ),
      );
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          chDefault,
          'General',
          description: 'General notifications',
          importance: Importance.high,
        ),
      );
    }

    _localInited = true;
  }

  Future<void> _showFromRemoteMessage(RemoteMessage message) async {
    final data = message.data;
    final type = (data['type'] ?? '').toString().toLowerCase();

    final title = (data['title'] ?? message.notification?.title ?? 'Notification').toString();
    final body = (data['body'] ?? message.notification?.body ?? '').toString();

    String channelId = chDefault;
    String channelName = 'General';

    if (type == 'message' || type == 'chat') {
      channelId = chMessages;
      channelName = 'Messages';
    } else if (type == 'reminder' || type == 'class') {
      channelId = chReminders;
      channelName = 'Reminders';
    } else if (type == 'mail' || type == 'email') {
      channelId = chMail;
      channelName = 'Mail';
    }

    await _local.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      payload: data.isEmpty ? null : data.toString(),
    );
  }
}
