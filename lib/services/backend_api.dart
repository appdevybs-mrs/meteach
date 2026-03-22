import 'package:firebase_auth/firebase_auth.dart';

class BackendApi {
  static const String secureBaseUrl = String.fromEnvironment(
    'YBS_SECURE_API_BASE',
    defaultValue: 'https://www.yourbridgeschool.com/app/secure',
  );

  static Uri uri(String path) => Uri.parse('$secureBaseUrl/$path');

  static Future<String> authToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Not logged in.');
    }

    try {
      final token = await user.getIdToken(false);
      if (token != null && token.trim().isNotEmpty) return token.trim();
    } catch (_) {}

    final refreshed = await user.getIdToken(true);
    if (refreshed == null || refreshed.trim().isEmpty) {
      throw Exception('Could not get auth token.');
    }
    return refreshed.trim();
  }

  static Future<Map<String, String>> authFormFields() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Not logged in.');
    }

    final token = await authToken();
    return <String, String>{'auth_token': token, 'auth_uid': user.uid};
  }

  static Future<Map<String, String>> authHeaders({bool json = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Not logged in.');
    }
    final token = await authToken();
    return <String, String>{
      if (json) 'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'X-Auth-Token': token,
      'X-Auth-Uid': user.uid,
    };
  }
}
