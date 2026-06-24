import 'package:package_info_plus/package_info_plus.dart';

class AppFlavor {
  static String? _cached;

  static String get current {
    if (_cached != null) return _cached!;
    _cached = String.fromEnvironment('APP_FLAVOR', defaultValue: '');
    if (_cached!.isNotEmpty) return _cached!;
    return 'prod';
  }

  static bool get isProd => current == 'prod';
  static bool get isAdmin => current == 'admin';

  static Future<void> init() async {
    if (_cached != null && _cached!.isNotEmpty && _cached != 'prod') return;
    try {
      final info = await PackageInfo.fromPlatform();
      final pkg = info.packageName;
      if (pkg == 'com.dreamenglish.academy.dream_english_academy') {
        _cached = 'admin';
      } else {
        _cached = 'prod';
      }
    } catch (_) {
      _cached = 'prod';
    }
  }
}
