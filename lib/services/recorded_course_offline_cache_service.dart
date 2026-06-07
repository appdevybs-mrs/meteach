import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class RecordedCourseOfflineCache {
  const RecordedCourseOfflineCache({
    required this.uid,
    required this.courseKey,
    required this.courseId,
    required this.courseData,
    required this.recordedAccess,
    required this.paymentSummary,
    required this.recordedSyllabus,
    required this.cachedAt,
  });

  final String uid;
  final String courseKey;
  final String courseId;
  final Map<String, dynamic> courseData;
  final Map<String, dynamic> recordedAccess;
  final Map<String, dynamic> paymentSummary;
  final Map<String, dynamic> recordedSyllabus;
  final int cachedAt;

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'courseKey': courseKey,
    'courseId': courseId,
    'courseData': courseData,
    'recordedAccess': recordedAccess,
    'paymentSummary': paymentSummary,
    'recordedSyllabus': recordedSyllabus,
    'cachedAt': cachedAt,
  };

  factory RecordedCourseOfflineCache.fromJson(Map<String, dynamic> json) {
    return RecordedCourseOfflineCache(
      uid: (json['uid'] ?? '').toString(),
      courseKey: (json['courseKey'] ?? '').toString(),
      courseId: (json['courseId'] ?? '').toString(),
      courseData: _asMap(json['courseData']),
      recordedAccess: _asMap(json['recordedAccess']),
      paymentSummary: _asMap(json['paymentSummary']),
      recordedSyllabus: _asMap(json['recordedSyllabus']),
      cachedAt: _asInt(json['cachedAt']),
    );
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString()) ?? 0;
  }
}

class RecordedCourseOfflineCacheService {
  RecordedCourseOfflineCacheService._();

  static final RecordedCourseOfflineCacheService instance =
      RecordedCourseOfflineCacheService._();

  static const String _prefsPrefix = 'recorded_course_offline_cache_v1';

  Future<void> save(RecordedCourseOfflineCache cache) async {
    if (cache.uid.trim().isEmpty || cache.courseKey.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(cache.uid, cache.courseKey), jsonEncode(cache));
  }

  Future<RecordedCourseOfflineCache?> load({
    required String uid,
    required String courseKey,
  }) async {
    if (uid.trim().isEmpty || courseKey.trim().isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(uid, courseKey));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RecordedCourseOfflineCache.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return null;
    }
  }

  String _key(String uid, String courseKey) {
    return '$_prefsPrefix|${_safe(uid)}|${_safe(courseKey)}';
  }

  String _safe(String raw) {
    return raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
  }
}
