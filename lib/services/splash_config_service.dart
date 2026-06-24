import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SplashConfig {
  final String type;
  final String url;
  final String thumbnailUrl;
  final int updatedAt;

  const SplashConfig({
    this.type = 'none',
    this.url = '',
    this.thumbnailUrl = '',
    this.updatedAt = 0,
  });

  static const _prefsTypeKey = 'cached_splash_type';
  static const _prefsUrlKey = 'cached_splash_url';
  static const _prefsThumbKey = 'cached_splash_thumb';
  static const _prefsUpdatedKey = 'cached_splash_updated';

  static const SplashConfig empty = SplashConfig();

  bool get hasMedia => type == 'image' || type == 'video';
  bool get isVideo => type == 'video';
  bool get isImage => type == 'image' || type == 'gif';

  factory SplashConfig.fromSnapshot(DataSnapshot? snap) {
    if (snap?.value == null || snap!.value is! Map) return SplashConfig.empty;
    final data = snap.value as Map<dynamic, dynamic>;
    return SplashConfig(
      type: (data['type'] as String?)?.trim().toLowerCase() ?? 'none',
      url: (data['url'] as String?)?.trim() ?? '',
      thumbnailUrl: (data['thumbnailUrl'] as String?)?.trim() ?? '',
      updatedAt: ((data['updatedAt'] as num?)?.toInt()) ?? 0,
    );
  }

  static Future<SplashConfig> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final type = prefs.getString(_prefsTypeKey) ?? 'none';
    final url = prefs.getString(_prefsUrlKey) ?? '';
    final thumb = prefs.getString(_prefsThumbKey) ?? '';
    final updated = prefs.getInt(_prefsUpdatedKey) ?? 0;
    if (url.isEmpty) return SplashConfig.empty;
    return SplashConfig(type: type, url: url, thumbnailUrl: thumb, updatedAt: updated);
  }

  Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsTypeKey, type);
    await prefs.setString(_prefsUrlKey, url);
    await prefs.setString(_prefsThumbKey, thumbnailUrl);
    await prefs.setInt(_prefsUpdatedKey, updatedAt);
  }

  static Future<void> clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsTypeKey);
    await prefs.remove(_prefsUrlKey);
    await prefs.remove(_prefsThumbKey);
    await prefs.remove(_prefsUpdatedKey);
  }
}

class SplashConfigService {
  static const _rtdbPath = 'appConfig/splashScreen';

  static Future<SplashConfig> fetch() async {
    try {
      final snap = await FirebaseDatabase.instance.ref(_rtdbPath).get();
      return SplashConfig.fromSnapshot(snap);
    } catch (_) {
      return SplashConfig.empty;
    }
  }

  static Future<void> save({
    required String type,
    required String url,
    String thumbnailUrl = '',
  }) async {
    await FirebaseDatabase.instance.ref(_rtdbPath).set({
      'type': type,
      'url': url,
      'thumbnailUrl': thumbnailUrl,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> clear() async {
    await FirebaseDatabase.instance.ref(_rtdbPath).set({
      'type': 'none',
      'url': '',
      'thumbnailUrl': '',
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
