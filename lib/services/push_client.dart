import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'backend_api.dart';

class PushClient {
  static const Duration _timeout = Duration(seconds: 12);
  static final Uuid _uuid = Uuid();

  static String _canonicalType(dynamic raw) {
    final type = (raw ?? '').toString().trim().toLowerCase();
    if (type == 'email') return 'mail';
    if (type == 'chat') return 'message';
    if (type == 'class') return 'reminder';
    return type;
  }

  static String _sanitizeEventId(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.length >= 8 && cleaned.length <= 120) {
      return cleaned;
    }
    return _uuid.v4();
  }

  static Map<String, String> _stringifyData(Map<String, dynamic> data) {
    final out = <String, String>{};
    data.forEach((k, v) {
      if (k.trim().isEmpty) return;
      if (v == null) return;
      out[k] = v.toString();
    });

    final canonical = _canonicalType(out['type']);
    if (canonical.isNotEmpty) {
      out['type'] = canonical;
    }

    final rawEventId = out['eventId'] ?? _uuid.v4();
    out['eventId'] = _sanitizeEventId(rawEventId);

    return out;
  }

  /// Send to one device token
  static Future<void> sendToToken({
    required String token,
    required String title,
    required String message,
    String? eventId,
    String? targetUid,
    Map<String, dynamic> data = const {},
  }) async {
    final merged = <String, dynamic>{...data};
    if (eventId != null && eventId.trim().isNotEmpty) {
      merged['eventId'] = eventId.trim();
    }
    if (targetUid != null && targetUid.trim().isNotEmpty) {
      merged['targetUid'] = targetUid.trim();
    }

    final body = {
      'mode': 'token',
      'token': token,
      'title': title,
      'message': message,
      // ✅ PHP/FCM safest as strings
      'data': _stringifyData(merged),
    };

    final headers = await BackendApi.authHeaders(json: true);

    final res = await http
        .post(
          BackendApi.uri('push_secure.php'),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Push failed HTTP ${res.statusCode}: ${res.body}');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      throw Exception('Push failed: invalid JSON response: ${res.body}');
    }

    if (decoded is Map && decoded['success'] != true) {
      throw Exception('Push failed: ${res.body}');
    }
  }

  /// (Optional) Send to topic like "admins"
  static Future<void> sendToTopic({
    required String topic,
    required String title,
    required String message,
    String? eventId,
    Map<String, dynamic> data = const {},
  }) async {
    final merged = <String, dynamic>{...data};
    if (eventId != null && eventId.trim().isNotEmpty) {
      merged['eventId'] = eventId.trim();
    }

    final body = {
      'mode': 'topic',
      'topic': topic,
      'title': title,
      'message': message,
      'data': _stringifyData(merged),
    };

    final headers = await BackendApi.authHeaders(json: true);

    final res = await http
        .post(
          BackendApi.uri('push_secure.php'),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Push failed HTTP ${res.statusCode}: ${res.body}');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      throw Exception('Push failed: invalid JSON response: ${res.body}');
    }

    if (decoded is Map && decoded['success'] != true) {
      throw Exception('Push failed: ${res.body}');
    }
  }
}
