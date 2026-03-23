import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class BackendApi {
  static const String secureBaseUrl = String.fromEnvironment(
    'YBS_SECURE_API_BASE',
    defaultValue: 'https://www.yourbridgeschool.com/app/secure',
  );

  static Uri uri(String path) => Uri.parse('$secureBaseUrl/$path');

  static void _debug(String message) {
    // no-op in production build
  }

  static Future<Uri> withAuthQuery(Uri original) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _debug('withAuthQuery failed: no current user for $original');
      throw Exception('Not logged in.');
    }

    final token = await authToken();
    _debug(
      'withAuthQuery path=${original.path} uid=${user.uid} tokenLen=${token.length}',
    );
    return original.replace(
      queryParameters: {
        ...original.queryParameters,
        'auth_token': token,
        'token': token,
        'bearer_token': token,
        'auth_uid': user.uid,
      },
    );
  }

  static Future<String> authToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _debug('authToken failed: no current user');
      throw Exception('Not logged in.');
    }

    try {
      final token = await user.getIdToken(false);
      if (token != null && token.trim().isNotEmpty) {
        final value = token.trim();
        _debug(
          'authToken cached success uid=${user.uid} tokenLen=${value.length}',
        );
        return value;
      }
    } catch (_) {}

    final refreshed = await user.getIdToken(true);
    if (refreshed == null || refreshed.trim().isEmpty) {
      _debug('authToken refresh failed uid=${user.uid}');
      throw Exception('Could not get auth token.');
    }
    final value = refreshed.trim();
    _debug(
      'authToken refreshed success uid=${user.uid} tokenLen=${value.length}',
    );
    return value;
  }

  static Future<Map<String, String>> authFormFields() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Not logged in.');
    }

    final token = await authToken();
    _debug('authFormFields ready uid=${user.uid} tokenLen=${token.length}');
    return <String, String>{
      'auth_token': token,
      'token': token,
      'bearer_token': token,
      'auth_uid': user.uid,
    };
  }

  static Future<void> applyAuthToMultipart(http.MultipartRequest req) async {
    req.headers.addAll(await authHeaders());
    req.fields.addAll(await authFormFields());
    _debug('applyAuthToMultipart completed uri=${req.url}');
  }

  static Future<Map<String, String>> authHeaders({bool json = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _debug('authHeaders failed: no current user');
      throw Exception('Not logged in.');
    }
    final token = await authToken();
    _debug(
      'authHeaders ready uid=${user.uid} json=$json tokenLen=${token.length}',
    );
    return <String, String>{
      if (json) 'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      'Bearer-Token': token,
      'X-Auth-Token': token,
      'X-Auth-Uid': user.uid,
    };
  }
}
