import 'dart:convert';
import 'package:http/http.dart' as http;

/// Calls your PHP endpoint: https://www.yourbridgeschool.com/app/push.php
class PushClient {
  // ✅ Use the FINAL working URL (with www)
  static const String _endpoint = 'https://www.yourbridgeschool.com/app/push.php';

  // ✅ Must match your push.php $SHARED_SECRET exactly
  static const String _secret = 'dea_2026_SUPER_SECRET_9f2b7c3e1a8d4c6f7a9b0c2d';

  /// Send to one device token
  static Future<void> sendToToken({
    required String token,
    required String title,
    required String message,
    Map<String, String> data = const {},
  }) async {
    final body = {
      'mode': 'token',
      'token': token,
      'title': title,
      'message': message,
      'data': data,
    };

    final res = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'X-App-Secret': _secret, // ✅ your PHP checks this header
      },
      body: jsonEncode(body),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Push failed HTTP ${res.statusCode}: ${res.body}');
    }

    final decoded = jsonDecode(res.body);
    if (decoded is Map && decoded['success'] != true) {
      throw Exception('Push failed: ${res.body}');
    }
  }

  /// (Optional) Send to topic like "admins"
  static Future<void> sendToTopic({
    required String topic,
    required String title,
    required String message,
    Map<String, String> data = const {},
  }) async {
    final body = {
      'mode': 'topic',
      'topic': topic,
      'title': title,
      'message': message,
      'data': data,
    };

    final res = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'X-App-Secret': _secret,
      },
      body: jsonEncode(body),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Push failed HTTP ${res.statusCode}: ${res.body}');
    }

    final decoded = jsonDecode(res.body);
    if (decoded is Map && decoded['success'] != true) {
      throw Exception('Push failed: ${res.body}');
    }
  }
}
