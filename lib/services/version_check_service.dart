import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:package_info_plus/package_info_plus.dart';

class VersionInfo {
  const VersionInfo({
    required this.appVersion,
    required this.minVersion,
    required this.androidUrl,
    required this.iosUrl,
  });

  final String appVersion;
  final String? minVersion;
  final String? androidUrl;
  final String? iosUrl;
}

class VersionCheckService {
  Future<VersionInfo> fetch() async {
    final appVersion = (await PackageInfo.fromPlatform()).version;
    String? minVersion;
    String? androidUrl;
    String? iosUrl;

    try {
      final snap = await FirebaseDatabase.instance
          .ref('/version')
          .get()
          .timeout(const Duration(seconds: 8));
      if (snap.exists && snap.value is Map) {
        final data = snap.value as Map;
        for (final key in data.keys) {
          final k = key.toString().trim();
          if (k == 'minVersion') {
            minVersion = data[key]?.toString().trim();
          } else if (k == 'androidUrl') {
            androidUrl = data[key]?.toString();
          } else if (k == 'iosUrl') {
            iosUrl = data[key]?.toString();
          }
        }
      }
    } catch (_) {
      // Ignore RTDB errors and return app version only.
    }

    if (Platform.isAndroid && androidUrl == null) {
      androidUrl = '';
    }
    if (Platform.isIOS && iosUrl == null) {
      iosUrl = '';
    }

    return VersionInfo(
      appVersion: appVersion,
      minVersion: minVersion,
      androidUrl: androidUrl,
      iosUrl: iosUrl,
    );
  }
}
