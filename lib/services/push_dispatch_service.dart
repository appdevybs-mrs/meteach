import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'push_client.dart';
import 'push_error_logger.dart';

enum PushIntent {
  adminTodo,
  reminder,
  flashMessage,
  mail,
  booking,
  recordedComment,
  jobApplication,
}

class PushDispatchContext {
  const PushDispatchContext({required this.screen, required this.action});

  final String screen;
  final String action;
}

class PushDispatchResult {
  const PushDispatchResult({
    required this.sent,
    required this.eventId,
    required this.hadAnyToken,
    required this.usedTopicFallback,
    required this.deliveredTokenCount,
  });

  final bool sent;
  final String eventId;
  final bool hadAnyToken;
  final bool usedTopicFallback;
  final int deliveredTokenCount;
}

class PushDispatchService {
  PushDispatchService._();

  static final DatabaseReference _db = FirebaseDatabase.instance.ref();

  static String _sanitizeEventPart(String raw) {
    final v = raw
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (v.length > 40) return v.substring(0, 40);
    return v;
  }

  static String _eventIdFrom(String prefix, List<String> parts) {
    final cleaned = parts
        .map(_sanitizeEventPart)
        .where((e) => e.isNotEmpty)
        .toList();
    final suffix = cleaned.isEmpty
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : cleaned.join('_');
    final base = '${_sanitizeEventPart(prefix)}_$suffix';
    if (base.length >= 8 && base.length <= 120) return base;
    final tail = DateTime.now().millisecondsSinceEpoch.toString();
    final clipped = base.length > 100 ? base.substring(0, 100) : base;
    return '${clipped}_$tail';
  }

  static String _canonicalType(PushIntent intent) {
    switch (intent) {
      case PushIntent.adminTodo:
        return 'admin_todo';
      case PushIntent.reminder:
        return 'reminder';
      case PushIntent.flashMessage:
        return 'flash_message';
      case PushIntent.mail:
        return 'mail';
      case PushIntent.booking:
        return 'booking';
      case PushIntent.recordedComment:
        return 'recorded_comment';
      case PushIntent.jobApplication:
        return 'job_application';
    }
  }

  static String _defaultRoute(PushIntent intent) {
    switch (intent) {
      case PushIntent.adminTodo:
        return 'admin_todos';
      case PushIntent.reminder:
        return 'learner';
      case PushIntent.flashMessage:
        return 'flash_messages';
      case PushIntent.mail:
        return 'mail_thread';
      case PushIntent.booking:
        return '';
      case PushIntent.recordedComment:
        return 'recorded_comment';
      case PushIntent.jobApplication:
        return 'job_applications';
    }
  }

  static Future<List<String>> _loadTokensForUid(String uid) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return const <String>[];

    final out = <String>[];
    final seen = <String>{};

    try {
      final v2Snap = await _db.child('fcm_tokens_v2/$safeUid').get();
      final v2Val = v2Snap.value;
      if (v2Val is Map) {
        for (final raw in v2Val.values) {
          if (raw is! Map) continue;
          final m = raw.map((k, v) => MapEntry(k.toString(), v));
          final token = (m['token'] ?? '').toString().trim();
          if (token.isEmpty || seen.contains(token)) continue;
          seen.add(token);
          out.add(token);
        }
      }
    } catch (_) {}

    try {
      final legacy = await _db.child('fcm_tokens/$safeUid/token').get();
      final token = (legacy.value ?? '').toString().trim();
      if (token.isNotEmpty && !seen.contains(token)) {
        out.add(token);
      }
    } catch (_) {}

    return out;
  }

  static Future<PushDispatchResult> dispatchToUser({
    required PushIntent intent,
    required String targetUid,
    required String title,
    required String message,
    required PushDispatchContext context,
    required List<String> eventParts,
    required Map<String, dynamic> data,
    String? route,
  }) async {
    final safeUid = targetUid.trim();
    if (safeUid.isEmpty) {
      return const PushDispatchResult(
        sent: false,
        eventId: '',
        hadAnyToken: false,
        usedTopicFallback: false,
        deliveredTokenCount: 0,
      );
    }

    final type = _canonicalType(intent);
    final effectiveRoute = (route ?? _defaultRoute(intent)).trim();
    final payload = <String, dynamic>{
      'type': type,
      if (effectiveRoute.isNotEmpty) 'route': effectiveRoute,
      ...data,
    };

    final eventId = _eventIdFrom(type, eventParts);
    final tokens = await _loadTokensForUid(safeUid);
    final topic = 'user_$safeUid';

    int sentViaToken = 0;
    Object? lastError;
    StackTrace? lastSt;

    for (final token in tokens) {
      try {
        await PushClient.sendToToken(
          token: token,
          targetUid: safeUid,
          eventId: eventId,
          title: title,
          message: message,
          data: payload,
        );
        sentViaToken += 1;
      } catch (e, st) {
        lastError = e;
        lastSt = st;
        await PushErrorLogger.logFailure(
          screen: context.screen,
          action: '${context.action}_token_attempt_failed',
          error: e,
          stackTrace: st,
          targetUid: safeUid,
          token: token,
          eventId: eventId,
          extra: {
            'topic': topic,
            'type': type,
            'route': effectiveRoute,
            'targetUid': safeUid,
          },
        );
      }
    }

    if (sentViaToken > 0) {
      return PushDispatchResult(
        sent: true,
        eventId: eventId,
        hadAnyToken: tokens.isNotEmpty,
        usedTopicFallback: false,
        deliveredTokenCount: sentViaToken,
      );
    }

    try {
      await PushClient.sendToTopic(
        topic: topic,
        eventId: eventId,
        title: title,
        message: message,
        data: payload,
      );
      return PushDispatchResult(
        sent: true,
        eventId: eventId,
        hadAnyToken: tokens.isNotEmpty,
        usedTopicFallback: true,
        deliveredTokenCount: 0,
      );
    } catch (e, st) {
      await PushErrorLogger.logFailure(
        screen: context.screen,
        action: '${context.action}_topic_fallback_failed',
        error: e,
        stackTrace: st,
        targetUid: safeUid,
        topic: topic,
        eventId: eventId,
        extra: {'type': type, 'route': effectiveRoute, 'targetUid': safeUid},
      );
      if (lastError != null) {
        await PushErrorLogger.logFailure(
          screen: context.screen,
          action: '${context.action}_final_failure_after_token_error',
          error: lastError,
          stackTrace: lastSt,
          targetUid: safeUid,
          eventId: eventId,
          extra: {'type': type, 'route': effectiveRoute, 'targetUid': safeUid},
        );
      }
      rethrow;
    }
  }

  static Future<PushDispatchResult> dispatchToTopic({
    required PushIntent intent,
    required String topic,
    required String title,
    required String message,
    required PushDispatchContext context,
    required List<String> eventParts,
    required Map<String, dynamic> data,
    String? route,
    List<String> fallbackUserUids = const <String>[],
  }) async {
    final safeTopic = topic.trim();
    if (safeTopic.isEmpty) {
      return const PushDispatchResult(
        sent: false,
        eventId: '',
        hadAnyToken: false,
        usedTopicFallback: false,
        deliveredTokenCount: 0,
      );
    }

    final type = _canonicalType(intent);
    final effectiveRoute = (route ?? _defaultRoute(intent)).trim();
    final payload = <String, dynamic>{
      'type': type,
      if (effectiveRoute.isNotEmpty) 'route': effectiveRoute,
      ...data,
    };

    final eventId = _eventIdFrom(type, eventParts);

    try {
      await PushClient.sendToTopic(
        topic: safeTopic,
        eventId: eventId,
        title: title,
        message: message,
        data: payload,
      );
      return PushDispatchResult(
        sent: true,
        eventId: eventId,
        hadAnyToken: false,
        usedTopicFallback: true,
        deliveredTokenCount: 0,
      );
    } catch (e, st) {
      await PushErrorLogger.logFailure(
        screen: context.screen,
        action: '${context.action}_topic_failed',
        error: e,
        stackTrace: st,
        topic: safeTopic,
        eventId: eventId,
        extra: {'type': type, 'route': effectiveRoute, 'topic': safeTopic},
      );

      if (fallbackUserUids.isNotEmpty) {
        int sent = 0;
        for (final uid in fallbackUserUids) {
          final safeUid = uid.trim();
          if (safeUid.isEmpty) continue;
          final userTopic = 'user_$safeUid';
          try {
            await PushClient.sendToTopic(
              topic: userTopic,
              eventId: eventId,
              title: title,
              message: message,
              data: {...payload, 'targetUid': safeUid},
            );
            sent += 1;
          } catch (ue, ust) {
            await PushErrorLogger.logFailure(
              screen: context.screen,
              action: '${context.action}_user_topic_fallback_failed',
              error: ue,
              stackTrace: ust,
              targetUid: safeUid,
              topic: userTopic,
              eventId: eventId,
              extra: {
                'type': type,
                'route': effectiveRoute,
                'topic': userTopic,
                'targetUid': safeUid,
              },
            );
          }
        }
        if (sent > 0) {
          return PushDispatchResult(
            sent: true,
            eventId: eventId,
            hadAnyToken: false,
            usedTopicFallback: true,
            deliveredTokenCount: 0,
          );
        }
      }

      rethrow;
    }
  }

  static Future<PushDispatchResult> dispatchMailToUser({
    required String targetUid,
    required String threadId,
    required String peerUid,
    required String title,
    required String preview,
    required int nowMs,
    required PushDispatchContext context,
  }) {
    return dispatchToUser(
      intent: PushIntent.mail,
      targetUid: targetUid,
      title: title.trim().isEmpty ? 'New mail' : title.trim(),
      message: preview.trim().isEmpty
          ? 'You received new mail'
          : preview.trim(),
      context: context,
      eventParts: ['mail', threadId, '$nowMs'],
      data: {'threadId': threadId, 'peerUid': peerUid},
      route: 'mail_thread',
    );
  }

  static Future<PushDispatchResult> dispatchAdminTopic({
    required PushIntent intent,
    required String title,
    required String message,
    required PushDispatchContext context,
    required List<String> eventParts,
    required Map<String, dynamic> data,
    List<String> fallbackAdminUids = const <String>[],
    String? route,
  }) {
    return dispatchToTopic(
      intent: intent,
      topic: 'admins',
      title: title,
      message: message,
      context: context,
      eventParts: eventParts,
      data: data,
      route: route,
      fallbackUserUids: fallbackAdminUids,
    );
  }

  static Future<List<String>> loadAdminUids() async {
    try {
      final snap = await _db.child('admins').get();
      if (!snap.exists || snap.value is! Map) return const <String>[];
      final m = (snap.value as Map).map((k, v) => MapEntry('$k', v));
      final out = <String>[];
      for (final e in m.entries) {
        final uid = e.key.trim();
        if (uid.isEmpty) continue;
        final val = e.value;
        if (val == true ||
            (val is num && val != 0) ||
            (val is String && val.trim().isNotEmpty)) {
          out.add(uid);
        }
      }
      return out;
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<void> syncCurrentDeviceTokenV2(String token) async {
    final uid = (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    if (uid.isEmpty || token.trim().isEmpty) return;

    final platform = _platformLabel();
    final seed = '${uid}_${platform}_${token.hashCode.abs()}';
    final deviceId = _sanitizeEventPart(seed);
    if (deviceId.isEmpty) return;

    try {
      await _db.child('fcm_tokens_v2/$uid/$deviceId').update({
        'token': token.trim(),
        'platform': platform,
        'updatedAt': ServerValue.timestamp,
        'lastSeenAt': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  static String _platformLabel() {
    return 'mobile';
  }
}
