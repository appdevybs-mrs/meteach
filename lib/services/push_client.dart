import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Calls your PHP endpoint: https://www.yourbridgeschool.com/app/push.php
class PushClient {
  // ✅ Use the FINAL working URL (with www)
  static const String _endpoint = 'https://www.yourbridgeschool.com/app/push.php';

  // ✅ Must match your push.php $SHARED_SECRET exactly
  static const String _secret = 'dea_2026_SUPER_SECRET_9f2b7c3e1a8d4c6f7a9b0c2d';

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

    final res = await http
        .post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'X-App-Secret': _secret, // ✅ your PHP checks this header
      },
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

    final res = await http
        .post(
      Uri.parse(_endpoint),
      headers: {
        'Content-Type': 'application/json',
        'X-App-Secret': _secret,
      },
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

  /// ✅ Convenience helper: standard incoming call payload
  static Future<void> sendIncomingCall({
    required String token,
    required String callId,
    required String peerUid,
    required String peerName,
    String title = 'Incoming call',
    String? message,
  }) {
    return sendToToken(
      token: token,
      title: title,
      message: message ?? '$peerName is calling you',
      data: {
        'type': 'incoming_call',
        'callId': callId,
        'peerUid': peerUid,
        'peerName': peerName,
      },
    );
  }
}
