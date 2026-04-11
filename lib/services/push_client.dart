import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'backend_api.dart';

class PushSendException implements Exception {
  PushSendException({
    required this.message,
    required this.endpoint,
    required this.mode,
    required this.target,
    required this.eventId,
    this.statusCode,
    this.responseBody,
  });

  final String message;
  final Uri endpoint;
  final String mode;
  final String target;
  final String eventId;
  final int? statusCode;
  final String? responseBody;

  @override
  String toString() {
    final code = statusCode == null ? '' : ' HTTP $statusCode';
    return 'PushSendException($mode->$target$code): $message';
  }
}

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

  static Never _throwPushFailure({
    required String mode,
    required Uri endpoint,
    required String target,
    required Map<String, String> data,
    required String message,
    int? statusCode,
    String? responseBody,
  }) {
    throw PushSendException(
      message: message,
      endpoint: endpoint,
      mode: mode,
      target: target,
      eventId: (data['eventId'] ?? '').trim(),
      statusCode: statusCode,
      responseBody: responseBody,
    );
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
    final endpoint = await BackendApi.withAuthQuery(
      BackendApi.uri('push_secure.php'),
    );

    final res = await http
        .post(endpoint, headers: headers, body: jsonEncode(body))
        .timeout(_timeout);

    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwPushFailure(
        mode: 'token',
        endpoint: endpoint,
        target: token,
        data: body['data'] as Map<String, String>,
        message: 'Push failed with non-2xx response.',
        statusCode: res.statusCode,
        responseBody: res.body,
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      _throwPushFailure(
        mode: 'token',
        endpoint: endpoint,
        target: token,
        data: body['data'] as Map<String, String>,
        message: 'Push failed: invalid JSON response.',
        statusCode: res.statusCode,
        responseBody: res.body,
      );
    }

    if (decoded is Map && decoded['success'] != true) {
      _throwPushFailure(
        mode: 'token',
        endpoint: endpoint,
        target: token,
        data: body['data'] as Map<String, String>,
        message: 'Push failed: API returned success=false.',
        statusCode: res.statusCode,
        responseBody: res.body,
      );
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
    final endpoint = await BackendApi.withAuthQuery(
      BackendApi.uri('push_secure.php'),
    );

    final res = await http
        .post(endpoint, headers: headers, body: jsonEncode(body))
        .timeout(_timeout);

    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwPushFailure(
        mode: 'topic',
        endpoint: endpoint,
        target: topic,
        data: body['data'] as Map<String, String>,
        message: 'Push failed with non-2xx response.',
        statusCode: res.statusCode,
        responseBody: res.body,
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      _throwPushFailure(
        mode: 'topic',
        endpoint: endpoint,
        target: topic,
        data: body['data'] as Map<String, String>,
        message: 'Push failed: invalid JSON response.',
        statusCode: res.statusCode,
        responseBody: res.body,
      );
    }

    if (decoded is Map && decoded['success'] != true) {
      _throwPushFailure(
        mode: 'topic',
        endpoint: endpoint,
        target: topic,
        data: body['data'] as Map<String, String>,
        message: 'Push failed: API returned success=false.',
        statusCode: res.statusCode,
        responseBody: res.body,
      );
    }
  }
}
