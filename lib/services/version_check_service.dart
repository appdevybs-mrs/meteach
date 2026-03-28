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

  bool get needsUpdate {
    final min = minVersion;
    if (min == null || min.trim().isEmpty) {
      return false;
    }
    return VersionCheckService.isUpdateRequired(appVersion, min);
  }

  String? get storeUrl {
    final fallback = VersionCheckService.fallbackStoreUrl;
    if (Platform.isIOS) {
      return VersionCheckService.normalizeStoreUrl(
        iosUrl,
        fallbackUrl: fallback,
      );
    }
    if (Platform.isAndroid) {
      return VersionCheckService.normalizeStoreUrl(
        androidUrl,
        fallbackUrl: fallback,
      );
    }
    return VersionCheckService.normalizeStoreUrl(
      androidUrl ?? iosUrl,
      fallbackUrl: fallback,
    );
  }
}

class VersionCheckService {
  static const String fallbackStoreUrl =
      'https://play.google.com/store/apps/details?id=com.intilak.taqyimdz';

  static String normalizeStoreUrl(String? raw, {String fallbackUrl = ''}) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) {
      return fallbackUrl;
    }
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return text;
    }
    return fallbackUrl;
  }

  static bool isUpdateRequired(String currentVersion, String minVersion) {
    return compareVersions(currentVersion, minVersion) < 0;
  }

  static int compareVersions(String a, String b) {
    final aParts = _parseVersion(a);
    final bParts = _parseVersion(b);
    final maxLength = aParts.length > bParts.length
        ? aParts.length
        : bParts.length;
    for (var i = 0; i < maxLength; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) {
        return av.compareTo(bv);
      }
    }
    return 0;
  }

  static List<int> _parseVersion(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return const <int>[0, 0, 0];
    }
    final clean = normalized.split('+').first.split('-').first;
    return clean
        .split('.')
        .map((part) => int.tryParse(part.trim()) ?? 0)
        .toList();
  }

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
