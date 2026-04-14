import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class BackendApi {
  static const String secureBaseUrl = String.fromEnvironment(
    'YBS_SECURE_API_BASE',
    defaultValue:
        'https://api.yourbridgeschool.com/apps/your-bridge-school/secure',
  );

  static const String mediaBaseUrl = String.fromEnvironment(
    'YBS_MEDIA_BASE',
    defaultValue:
        'https://api.yourbridgeschool.com/apps/your-bridge-school/storage',
  );

  static Uri uri(String path) => Uri.parse('$secureBaseUrl/$path');

  static String get mediaOrigin {
    final parsed = Uri.tryParse(mediaBaseUrl);
    if (parsed == null || parsed.scheme.isEmpty || parsed.host.isEmpty) {
      return mediaBaseUrl;
    }
    return '${parsed.scheme}://${parsed.host}${parsed.hasPort ? ':${parsed.port}' : ''}';
  }

  static Uri mediaUri({required String root, String path = ''}) {
    final rootPart = Uri.encodeComponent(root.trim());
    final pathPart = path
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final base = mediaBaseUrl.endsWith('/')
        ? mediaBaseUrl.substring(0, mediaBaseUrl.length - 1)
        : mediaBaseUrl;
    final full = pathPart.isEmpty
        ? '$base/$rootPart'
        : '$base/$rootPart/$pathPart';
    return Uri.parse(full);
  }

  static void _debug(String message) {
    // no-op in production build
  }

  static bool _looksLikeJwt(String token) {
    final t = token.trim();
    if (t.isEmpty) return false;
    final lower = t.toLowerCase();
    if (lower == 'null' ||
        lower == 'none' ||
        lower == 'undefined' ||
        lower == 'false' ||
        lower == 'true' ||
        lower == 'nan') {
      return false;
    }
    final parts = t.split('.');
    if (parts.length != 3) return false;
    final validPart = RegExp(r'^[A-Za-z0-9_-]+$');
    return validPart.hasMatch(parts[0]) &&
        validPart.hasMatch(parts[1]) &&
        validPart.hasMatch(parts[2]);
  }

  static Future<Uri> withAuthQuery(Uri original) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _debug('withAuthQuery failed: no current user for $original');
      throw Exception('Not logged in.');
    }

    final token = await authToken();
    if (!_looksLikeJwt(token)) {
      _debug('withAuthQuery failed: invalid token shape for ${original.path}');
      throw Exception('Session expired. Please log in again.');
    }
    _debug(
      'withAuthQuery path=${original.path} uid=${user.uid} tokenLen=${token.length}',
    );
    return original.replace(
      queryParameters: {
        ...original.queryParameters,
        'auth_token': token,
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
      if (token != null && _looksLikeJwt(token)) {
        final value = token.trim();
        _debug(
          'authToken cached success uid=${user.uid} tokenLen=${value.length}',
        );
        return value;
      }
    } catch (_) {}

    final refreshed = await user.getIdToken(true);
    if (refreshed == null || !_looksLikeJwt(refreshed)) {
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
    if (!_looksLikeJwt(token)) {
      throw Exception('Session expired. Please log in again.');
    }
    _debug('authFormFields ready uid=${user.uid} tokenLen=${token.length}');
    return <String, String>{'auth_token': token, 'auth_uid': user.uid};
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
