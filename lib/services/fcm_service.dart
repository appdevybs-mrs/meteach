import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../admin/admin_teacher_mail_thread_screen.dart'; // keep (project safety)
import '../admin/admin_payments.dart'; // keep (project safety)
import 'route_state.dart';

import '../main.dart'; // appNavigatorKey + messengerKey
import '../calls/audio_call_screen.dart';
import 'mail_thread_by_id_screen.dart';

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

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();

  bool _localInited = false;

  static const String chMessages = 'ch_messages';
  static const String chReminders = 'ch_reminders';
  static const String chMail = 'ch_mail';
  static const String chCalls = 'ch_calls';
  static const String chDefault = 'ch_default';

  // Prevent opening same call screen multiple times quickly
  static String? _lastIncomingCallIdHandled;
  static DateTime? _lastIncomingCallHandledAt;

  // Keep a watcher per callId so we can cancel notification when call ends
  final Map<String, StreamSubscription<DatabaseEvent>> _callWatchers = {};

  // Notification action ids
  static const String actionAccept = 'ACCEPT_CALL';
  static const String actionDecline = 'DECLINE_CALL';

  // Presence path (for busy feature)
  static const String _presenceInCallPath = 'presence/in_call';

  /// REQUIRED by AuthGate (your app calls this)
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

  /// Call once in main()
  Future<void> init() async {
    await _requestPermission();
    await _ensureLocalInit();

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // App opened from SYSTEM notification (terminated)
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

    // Foreground push
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final data = Map<String, dynamic>.from(message.data);
      final type = (data['type'] ?? '').toString().toLowerCase();

      // If already inside this mail thread, ignore notif
      if (type == 'mail' || type == 'email') {
        final threadId = (data['threadId'] ?? '').toString().trim();
        if (threadId.isNotEmpty && RouteState.currentMailThreadId == threadId) {
          return;
        }
      }

      // Calls: show call-style notif + start watcher to auto-cancel when status changes
      if (type == 'incoming_call') {
        final callId = (data['callId'] ?? '').toString().trim();
        if (callId.isNotEmpty) {
          _watchCallToAutoCancel(callId);
        }
        await _showFromRemoteMessage(message);
        return;
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
    if (uid == null) {
      debugPrint('⚠️ saveTokenToDatabase skipped: user not logged in');
      return;
    }

    try {
      await FirebaseDatabase.instance.ref('fcm_tokens/$uid').update({
        'token': token,
        'platform': kIsWeb ? 'web' : (Platform.isAndroid ? 'android' : 'other'),
        'updatedAt': ServerValue.timestamp,
      });
      debugPrint('✅ Token saved to RTDB: fcm_tokens/$uid');
    } catch (e) {
      debugPrint('❌ Token save failed: $e');
    }
  }

  Future<void> _ensureLocalInit() async {
    if (_localInited) return;
    if (kIsWeb) {
      _localInited = true;
      return;
    }
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _local.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;

        Map<String, dynamic> data;
        try {
          data = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          return;
        }

        final type = (data['type'] ?? '').toString().toLowerCase();
        final actionId = response.actionId;

        // Handle call actions
        if (type == 'incoming_call') {
          final callId = (data['callId'] ?? '').toString().trim();
          if (callId.isNotEmpty) {
            _watchCallToAutoCancel(callId);
          }

          if (actionId == actionDecline) {
            await _markCallStatus(callId, 'declined');
            await _cancelCallNotification(callId);
            return;
          }

          if (actionId == actionAccept) {
            // Accept: validate + busy check + mark accepted + open
            await _handleIncomingCallTap(data, fromAcceptAction: true);
            return;
          }
        }

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
    final h = callId.hashCode;
    return h < 0 ? -h : h;
  }

  Future<void> _cancelCallNotification(String callId) async {
    try {
      final id = _stableNotifIdForCall(callId);
      await _local.cancel(id: id);
    } catch (_) {}
  }

  void _watchCallToAutoCancel(String callId) {
    // cancel old watcher
    _callWatchers[callId]?.cancel();

    final sub = FirebaseDatabase.instance.ref('calls/$callId').onValue.listen((event) async {
      final v = event.snapshot.value;
      if (v is! Map) {
        // call deleted => cancel notif
        await _cancelCallNotification(callId);
        _callWatchers[callId]?.cancel();
        _callWatchers.remove(callId);
        return;
      }

      final status = (v['status'] ?? '').toString();
      if (status != 'ringing') {
        await _cancelCallNotification(callId);
        _callWatchers[callId]?.cancel();
        _callWatchers.remove(callId);
      }
    });

    _callWatchers[callId] = sub;
  }

  Future<void> _markCallStatus(String callId, String status) async {
    if (callId.trim().isEmpty) return;
    try {
      await FirebaseDatabase.instance.ref('calls/$callId').update({
        'status': status,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  Future<bool> _isMeBusyInCall() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;

    try {
      final snap = await FirebaseDatabase.instance.ref('$_presenceInCallPath/$uid').get();
      final v = snap.value;
      if (v is bool) return v;
      return v?.toString() == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<String?> _validateCallBeforeOpening(String callId) async {
    try {
      final snap = await FirebaseDatabase.instance.ref('calls/$callId').get();

      if (!snap.exists) return 'This call no longer exists.';
      final data = snap.value;
      if (data is! Map) return 'Invalid call data.';

      final status = (data['status'] ?? '').toString();
      if (status != 'ringing') return 'This call has already ended.';

      return null; // OK
    } catch (_) {
      return 'Unable to verify call status.';
    }
  }

  Future<void> _showFromRemoteMessage(RemoteMessage message) async {
    final data = Map<String, dynamic>.from(message.data);
    final type = (data['type'] ?? '').toString().toLowerCase();

    final title =
    (data['title'] ?? message.notification?.title ?? 'Notification').toString();
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

    // Notification ID:
    // - Calls: stable id from callId (prevents duplicates)
    // - Others: timestamp id
    int notifId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if (type == 'incoming_call') {
      final callId = (data['callId'] ?? '').toString().trim();
      if (callId.isNotEmpty) {
        notifId = _stableNotifIdForCall(callId);
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
            category: AndroidNotificationCategory.call,
            fullScreenIntent: true,
            autoCancel: false,
            ongoing: true,
            actions: const [
              AndroidNotificationAction(
                actionAccept,
                'Accept',
                showsUserInterface: true,
              ),
              AndroidNotificationAction(
                actionDecline,
                'Decline',
                showsUserInterface: false,
              ),
            ],
          ),
        ),
        payload: jsonEncode(data),
      );
      return;
    }

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
        ),
      ),
      payload: data.isEmpty ? null : jsonEncode(data),
    );
  }

  Future<void> _handleIncomingCallTap(
      Map<String, dynamic> data, {
        required bool fromAcceptAction,
      }) async {
    final callId = (data['callId'] ?? '').toString().trim();
    final peerUid = (data['peerUid'] ?? '').toString().trim();
    final peerName = (data['peerName'] ?? 'Caller').toString().trim();

    if (callId.isEmpty) return;

    // duplicate block
    final now = DateTime.now();
    if (_lastIncomingCallIdHandled == callId &&
        _lastIncomingCallHandledAt != null &&
        now.difference(_lastIncomingCallHandledAt!).inSeconds < 10) {
      return;
    }
    _lastIncomingCallIdHandled = callId;
    _lastIncomingCallHandledAt = now;

    // Busy check (receiver already in a call)
    final busy = await _isMeBusyInCall();
    if (busy) {
      await _markCallStatus(callId, 'busy');
      await _cancelCallNotification(callId);
      messengerKey.currentState?.showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('You are busy (already in a call).'),
        ),
      );
      return;
    }

    // Validate call is still ringing (fix old notifications)
    final err = await _validateCallBeforeOpening(callId);
    if (err != null) {
      await _cancelCallNotification(callId);
      messengerKey.currentState?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(err),
        ),
      );
      return;
    }

    // Mark accepted (optional but important)
    if (fromAcceptAction) {
      await FirebaseDatabase.instance.ref('calls/$callId').update({
        'status': 'accepted',
        'acceptedAt': ServerValue.timestamp,
      });
    }

    final nav = appNavigatorKey.currentState;
    if (nav == null) return;

    nav.push(
      MaterialPageRoute(
        builder: (_) => AudioCallScreen(
          peerUid: peerUid,
          peerName: peerName,
          isCaller: false,
          incomingCallId: callId,
          startWithVideo: false,
        ),
      ),
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

    // Calls: validate + busy check before opening
    if (type == 'incoming_call') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _handleIncomingCallTap(data, fromAcceptAction: false);
      });
      return;
    }

    // Mail
    if (type == 'mail' || type == 'email') {
      final threadId = (data['threadId'] ?? '').toString().trim();
      final peerUid = (data['peerUid'] ?? '').toString().trim();

      if (threadId.isEmpty || peerUid.isEmpty) return;
      if (RouteState.currentMailThreadId == threadId) return;

      void go() {
        final nav = appNavigatorKey.currentState;
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

        nav.push(
          MaterialPageRoute(
            settings: RouteSettings(name: targetName),
            builder: (_) => MailThreadByIdScreen(
              threadId: threadId,
              peerUid: peerUid,
            ),
          ),
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) => go());
      return;
    }

    // Payments
    if (type == 'payment') {
      void go() {
        final nav = appNavigatorKey.currentState;
        if (nav == null) return;
        nav.pushNamed('/payments');
      }

      WidgetsBinding.instance.addPostFrameCallback((_) => go());
      return;
    }

    return;
  }
}
