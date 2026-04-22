import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import 'audit_action_keys.dart';
import 'audit_log_service.dart';
import 'push_client.dart';

class PushErrorLogger {
  static String _clip(String input, int max) {
    final safe = input.trim();
    if (safe.length <= max) return safe;
    return safe.substring(0, max);
  }

  static String _tokenSuffix(String token) {
    final v = token.trim();
    if (v.isEmpty) return '';
    if (v.length <= 8) return v;
    return v.substring(v.length - 8);
  }

  static String _failureCategory({
    required Object error,
    int? statusCode,
    required String responseSnippet,
    required String message,
  }) {
    final msg = message.toLowerCase();
    final response = responseSnippet.toLowerCase();
    final combined = '$msg $response';

    if (msg.contains('timeout')) return 'network_timeout';
    if (msg.contains('invalid json response')) return 'invalid_json_response';
    if (msg.contains('success=false')) return 'api_success_false';

    if (statusCode != null && (statusCode < 200 || statusCode >= 300)) {
      if (statusCode == 403 && combined.contains('forbidden push type')) {
        return 'forbidden_push_type';
      }
      if (statusCode == 403 && combined.contains('learner topic not allowed')) {
        return 'learner_topic_forbidden';
      }
      if (statusCode == 400 && combined.contains('missing token')) {
        return 'missing_token';
      }
      if (statusCode == 400 &&
          combined.contains('missing notification target')) {
        return 'missing_target';
      }
      if (statusCode == 400 && combined.contains('invalid topic name')) {
        return 'invalid_topic';
      }
      if (statusCode == 400 &&
          combined.contains('invalid or missing data.type')) {
        return 'invalid_push_type';
      }
      return 'backend_non_2xx';
    }

    if (combined.contains('not a valid fcm registration token') ||
        combined.contains('invalid registration token')) {
      return 'fcm_token_invalid';
    }
    if (combined.contains('registration token is not registered') ||
        combined.contains('requested entity was not found') ||
        combined.contains('unregistered')) {
      return 'fcm_registration_not_found';
    }
    if (combined.contains('authentication') ||
        combined.contains('credentials') ||
        combined.contains('auth error')) {
      return 'fcm_auth_error';
    }
    if (combined.contains('quota') || combined.contains('too many requests')) {
      return 'fcm_quota_error';
    }

    return error is PushSendException
        ? 'unknown_backend_error'
        : 'unknown_client_error';
  }

  static String _recommendedFix(String category) {
    switch (category) {
      case 'network_timeout':
        return 'Retry the push and verify network connectivity between the app and secure API.';
      case 'invalid_json_response':
        return 'Inspect push_secure.php output for notices or malformed JSON before the API response.';
      case 'api_success_false':
        return 'Check the secure API response body and backend validation for this event.';
      case 'backend_non_2xx':
        return 'Inspect push_secure.php server logs and stored backend error for this eventId.';
      case 'invalid_topic':
        return 'Verify the topic format and send only allowed topic names.';
      case 'missing_token':
        return 'Refresh the recipient device token and confirm token sync completed.';
      case 'missing_target':
        return 'Ensure the send path provides a token or topic before dispatching.';
      case 'invalid_push_type':
        return 'Check the payload type and route mapping before dispatching the notification.';
      case 'forbidden_push_type':
      case 'learner_topic_forbidden':
        return 'Review role restrictions in push_secure.php for this sender and notification type.';
      case 'fcm_token_invalid':
      case 'fcm_registration_not_found':
        return 'Remove the stale token, let the device register again, and retry the push.';
      case 'fcm_auth_error':
        return 'Verify Firebase Admin credentials and server configuration.';
      case 'fcm_quota_error':
        return 'Retry later and review FCM quota usage or burst sending patterns.';
      case 'unknown_backend_error':
        return 'Inspect the backend error message and stack for this eventId.';
      default:
        return 'Review the stored error details for this event and correlate by eventId.';
    }
  }

  static String _attemptStage(String action) {
    final v = action.trim().toLowerCase();
    if (v.endsWith('_token_attempt_failed')) return 'token_send';
    if (v.endsWith('_topic_fallback_failed')) return 'topic_fallback';
    if (v.endsWith('_final_failure_after_token_error')) return 'final_failure';
    if (v.endsWith('_topic_failed')) return 'topic_send';
    if (v.endsWith('_user_topic_fallback_failed')) return 'user_topic_fallback';
    return 'send';
  }

  static Future<void> logFailure({
    required String screen,
    required String action,
    required Object error,
    StackTrace? stackTrace,
    String? targetUid,
    String? topic,
    String? token,
    String? eventId,
    Map<String, dynamic>? extra,
  }) async {
    final actorUid = (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    final bucketUid = actorUid.isEmpty ? '_unknown' : actorUid;

    int? statusCode;
    String responseSnippet = '';
    String mode = '';
    String target = '';
    String pushEventId = eventId?.trim() ?? '';
    String endpoint = '';

    if (error is PushSendException) {
      statusCode = error.statusCode;
      responseSnippet = _clip(error.responseBody ?? '', 1000);
      mode = error.mode;
      target = error.target;
      if (pushEventId.isEmpty) {
        pushEventId = error.eventId.trim();
      }
      endpoint = error.endpoint.toString();
    }

    final errorMessage = _clip(error.toString(), 1200);
    final category = _failureCategory(
      error: error,
      statusCode: statusCode,
      responseSnippet: responseSnippet,
      message: errorMessage,
    );
    final recommendedFix = _recommendedFix(category);
    final extraType = _clip(extra?['type']?.toString() ?? '', 60);
    final extraRoute = _clip(extra?['route']?.toString() ?? '', 120);
    final attemptStage = _attemptStage(action);

    final stackTop = stackTrace == null
        ? ''
        : _clip(stackTrace.toString().split('\n').first, 280);

    final record = <String, dynamic>{
      'createdAt': ServerValue.timestamp,
      'screen': _clip(screen, 80),
      'action': _clip(action, 120),
      'eventId': _clip(pushEventId, 160),
      'failureCategory': category,
      'recommendedFix': recommendedFix,
      'attemptStage': attemptStage,
      'mode': _clip(mode, 20),
      'target': _clip(target, 180),
      'type': extraType,
      'route': extraRoute,
      'targetUid': _clip(targetUid?.trim() ?? '', 160),
      'topic': _clip(topic?.trim() ?? '', 160),
      'tokenSuffix': _clip(_tokenSuffix(token ?? ''), 32),
      'endpoint': _clip(endpoint, 240),
      'errorType': error.runtimeType.toString(),
      'errorMessage': errorMessage,
      'statusCode': statusCode,
      'responseSnippet': responseSnippet,
      'stackTop': stackTop,
    };

    if (extra != null && extra.isNotEmpty) {
      final extraSafe = <String, dynamic>{};
      extra.forEach((k, v) {
        final key = k.trim();
        if (key.isEmpty || key.length > 60) return;
        extraSafe[key] = _clip(v?.toString() ?? '', 240);
      });
      if (extraSafe.isNotEmpty) {
        record['extra'] = extraSafe;
      }
    }

    debugPrint(
      '[push_error] screen=$screen action=$action '
      'type=${record['errorType']} code=${statusCode ?? '-'} '
      'event=${record['eventId']} target=${record['target']}',
    );

    try {
      await FirebaseDatabase.instance
          .ref('push_client_errors/$bucketUid')
          .push()
          .set(record);
    } catch (_) {
      // Avoid recursive logging failures.
    }

    await AuditLogService.logFailure(
      actionKey: AuditActionKeys.systemPushFailed,
      domain: AuditDomain.push,
      summary: 'Push send failed in $screen: $action',
      actor: AuditActor(uid: actorUid, role: 'system', name: 'Push Client'),
      target: AuditTarget(uid: targetUid, id: topic, type: 'push_target'),
      errorCode: statusCode?.toString(),
      errorMessage: record['errorMessage']?.toString(),
      labels: const ['source:push_client'],
      keywords: [screen, action, pushEventId],
      context: {
        'eventId': pushEventId,
        'failureCategory': category,
        'attemptStage': attemptStage,
        'type': extraType,
        'route': extraRoute,
      },
      meta: {
        'mode': mode,
        'target': target,
        'topic': topic ?? '',
        'eventId': pushEventId,
        'recommendedFix': recommendedFix,
      },
    );
  }
}
