import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

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

    final stackTop = stackTrace == null
        ? ''
        : _clip(stackTrace.toString().split('\n').first, 280);

    final record = <String, dynamic>{
      'createdAt': ServerValue.timestamp,
      'screen': _clip(screen, 80),
      'action': _clip(action, 120),
      'eventId': _clip(pushEventId, 160),
      'mode': _clip(mode, 20),
      'target': _clip(target, 180),
      'targetUid': _clip(targetUid?.trim() ?? '', 160),
      'topic': _clip(topic?.trim() ?? '', 160),
      'tokenSuffix': _clip(_tokenSuffix(token ?? ''), 32),
      'endpoint': _clip(endpoint, 240),
      'errorType': error.runtimeType.toString(),
      'errorMessage': _clip(error.toString(), 1200),
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
  }
}
