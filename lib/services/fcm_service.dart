import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../admin/admin_teacher_mail_thread_screen.dart';

import '../main.dart'; // appNavigatorKey
import '../calls/audio_call_screen.dart';

// ✅ ADD: open mail thread from notification
import 'mail_thread_by_id_screen.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();
    await FCMService.I._ensureLocalInit();

    // ✅ IMPORTANT: if FCM message has a "notification" payload,
    // Android will already show a system notification in background/killed.
    // Showing a local notification too causes duplicates.
    final type = (message.data['type'] ?? '').toString().toLowerCase();
    final hasSystemNotification = message.notification != null;

    if (hasSystemNotification) {
      // Avoid duplicate local notifications.
      // (Calls are the most visible problem, but we keep this safe for all types.)
      return;
    }

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
  static const String chCalls = 'ch_calls';
  static const String chDefault = 'ch_default';

  /// ✅ Prevent opening the same incoming call screen multiple times
  static String? _lastIncomingCallIdHandled;
  static DateTime? _lastIncomingCallHandledAt;

  /// Call once in main()
  Future<void> init() async {
    await _requestPermission();
    await _ensureLocalInit();

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // If app was opened from a SYSTEM notification (terminated state)
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      _handleNotificationTapPayload(jsonEncode(initial.data));
    }

    // Token may exist BEFORE login
    final token = await _messaging.getToken();
    debugPrint("🔥 FCM TOKEN (startup): $token");

    if (token != null && token.isNotEmpty) {
      await saveTokenToDatabase(token);
    }

    _messaging.onTokenRefresh.listen((newToken) async {
      debugPrint("🔄 FCM TOKEN REFRESH: $newToken");
      await saveTokenToDatabase(newToken);
    });

    // ✅ Foreground push (APP OPEN)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final type = (message.data['type'] ?? '').toString().toLowerCase();

      // ✅ Fix #2: If incoming call arrives while app is open, OPEN call screen.
      if (type == 'incoming_call') {
        _handleNotificationTapPayload(jsonEncode(message.data));

        // Optional: show a local heads-up notification too, but with a STABLE id (no spam).
        // If you prefer ZERO notifications while app is open, comment this line.
        await _showFromRemoteMessage(message);

        return;
      }

      // Non-call notifications: show local
      await _showFromRemoteMessage(message);
    });

    // Background -> user tapped system notification
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _handleNotificationTapPayload(jsonEncode(message.data));
    });
  }

  /// IMPORTANT: call this after login (AuthGate)
  static Future<void> syncTokenAfterLogin() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      debugPrint('⚠️ syncTokenAfterLogin: user is null');
      return;
    }

    final token = await FirebaseMessaging.instance.getToken();
    debugPrint('✅ syncTokenAfterLogin uid=$uid token=$token');

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

  /// Save token under /fcm_tokens/{uid}
  static Future<void> saveTokenToDatabase(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      debugPrint('⚠️ saveTokenToDatabase skipped: user not logged in');
      return;
    }

    try {
      await FirebaseDatabase.instance.ref('fcm_tokens/$uid').update({
        'token': token,
        'platform': Platform.isAndroid ? 'android' : 'other',
        'updatedAt': ServerValue.timestamp,
      });
      debugPrint('✅ Token saved to RTDB: fcm_tokens/$uid');
    } catch (e) {
      debugPrint('❌ Token save failed: $e');
    }
  }

  Future<void> _ensureLocalInit() async {
    if (_localInited) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _local.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        _handleNotificationTapPayload(payload);
      },
    );

    // If app was opened from a LOCAL notification (terminated state)
    final launch = await _local.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (payload != null && payload.isNotEmpty) {
      Future.microtask(() => _handleNotificationTapPayload(payload));
    }

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
          chCalls,
          'Calls',
          description: 'Incoming call notifications',
          importance: Importance.max,
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

  int _stableNotifIdForCall(String callId) {
    // Stable int id so the same call updates/overwrites instead of spamming many.
    // (hashCode can be negative, so normalize)
    final h = callId.hashCode;
    return h < 0 ? -h : h;
  }

  Future<void> _showFromRemoteMessage(RemoteMessage message) async {
    final data = Map<String, dynamic>.from(message.data);
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
    } else if (type == 'incoming_call') {
      channelId = chCalls;
      channelName = 'Calls';
    }

    // ✅ Notification ID:
    // - Calls: stable id from callId (prevents duplicates)
    // - Others: timestamp id
    int notifId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (type == 'incoming_call') {
      final callId = (data['callId'] ?? '').toString().trim();
      if (callId.isNotEmpty) {
        notifId = _stableNotifIdForCall(callId);
      }
    }

    await _local.show(
      id: notifId,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.max,
          priority: Priority.high,
          category: type == 'incoming_call' ? AndroidNotificationCategory.call : null,
          fullScreenIntent: type == 'incoming_call',
        ),
      ),
      payload: data.isEmpty ? null : jsonEncode(data),
    );
  }

  void _handleNotificationTapPayload(String payload) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = (data['type'] ?? '').toString().toLowerCase();

    // ✅ 1) KEEP existing working call logic untouched
    if (type == 'incoming_call') {
      final callId = (data['callId'] ?? '').toString().trim();
      final peerUid = (data['peerUid'] ?? '').toString().trim();
      final peerName = (data['peerName'] ?? 'Caller').toString().trim();

      if (callId.isEmpty) return;

      // ✅ Block duplicate opens for the same callId
      final now = DateTime.now();
      if (_lastIncomingCallIdHandled == callId &&
          _lastIncomingCallHandledAt != null &&
          now.difference(_lastIncomingCallHandledAt!).inSeconds < 10) {
        return;
      }
      _lastIncomingCallIdHandled = callId;
      _lastIncomingCallHandledAt = now;

      void go() {
        final nav = appNavigatorKey.currentState;
        if (nav == null) return;

        nav.push(
          MaterialPageRoute(
            builder: (_) => AudioCallScreen(
              peerUid: peerUid,
              peerName: peerName,
              isCaller: false,
              incomingCallId: callId,
            ),
          ),
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        go();
      });

      return;
    }

    // ✅ 2) ADD mail open (does not affect calls)
    if (type == 'mail' || type == 'email') {
      final threadId = (data['threadId'] ?? '').toString().trim();
      final peerUid = (data['peerUid'] ?? '').toString().trim();

      if (threadId.isEmpty || peerUid.isEmpty) return;

      void go() {
        final nav = appNavigatorKey.currentState;
        if (nav == null) return;

        nav.push(
          MaterialPageRoute(
            builder: (_) => MailThreadByIdScreen(
              threadId: threadId,
              peerUid: peerUid,
            ),
          ),
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        go();
      });

      return;
    }

    // ✅ ignore other types safely
    return;
  }
}
