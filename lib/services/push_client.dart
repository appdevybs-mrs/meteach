import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'backend_api.dart';

class PushClient {
  static const Duration _timeout = Duration(seconds: 12);

  static Map<String, String> _stringifyData(Map<String, dynamic> data) {
    final out = <String, String>{};
    data.forEach((k, v) {
      if (k.trim().isEmpty) return;
      if (v == null) return;
      out[k] = v.toString();
    });
    return out;
  }

  /// Send to one device token
  static Future<void> sendToToken({
    required String token,
    required String title,
    required String message,
    Map<String, dynamic> data = const {},
  }) async {
    final body = {
      'mode': 'token',
      'token': token,
      'title': title,
      'message': message,
      // ✅ PHP/FCM safest as strings
      'data': _stringifyData(data),
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
    Map<String, dynamic> data = const {},
  }) async {
    final body = {
      'mode': 'topic',
      'topic': topic,
      'title': title,
      'message': message,
      'data': _stringifyData(data),
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
