import 'package:firebase_database/firebase_database.dart';

class LearnerNotificationSettings {
  const LearnerNotificationSettings({
    required this.masterEnabled,
    required this.appEnabled,
    required this.classEnabled,
    required this.classLeadMinutes,
  });

  final bool masterEnabled;
  final bool appEnabled;
  final bool classEnabled;
  final int classLeadMinutes;

  static const int defaultLeadMinutes = 10;

  factory LearnerNotificationSettings.defaults() {
    return const LearnerNotificationSettings(
      masterEnabled: true,
      appEnabled: true,
      classEnabled: true,
      classLeadMinutes: defaultLeadMinutes,
    );
  }

  factory LearnerNotificationSettings.fromMap(Map<String, dynamic> map) {
    bool readBool(List<String> keys, bool fallback) {
      for (final key in keys) {
        final raw = map[key];
        if (raw is bool) return raw;
        if (raw is num) return raw != 0;
        if (raw is String) {
          final v = raw.trim().toLowerCase();
          if (v == 'true' || v == '1' || v == 'yes' || v == 'on') return true;
          if (v == 'false' || v == '0' || v == 'no' || v == 'off') return false;
        }
      }
      return fallback;
    }

    int readInt(List<String> keys, int fallback) {
      for (final key in keys) {
        final raw = map[key];
        if (raw is int) return raw;
        if (raw is num) return raw.toInt();
        final parsed = int.tryParse((raw ?? '').toString().trim());
        if (parsed != null) return parsed;
      }
      return fallback;
    }

    return LearnerNotificationSettings(
      masterEnabled: readBool(const ['masterEnabled', 'enabled', 'on'], true),
      appEnabled: readBool(const ['appEnabled', 'app', 'mailEnabled'], true),
      classEnabled: readBool(const [
        'classEnabled',
        'class',
        'sessionEnabled',
      ], true),
      classLeadMinutes: readInt(const [
        'classLeadMinutes',
        'sessionLeadMinutes',
        'leadMinutes',
      ], defaultLeadMinutes),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'masterEnabled': masterEnabled,
      'appEnabled': appEnabled,
      'classEnabled': classEnabled,
      'classLeadMinutes': classLeadMinutes,
      'updatedAt': ServerValue.timestamp,
    };
  }

  LearnerNotificationSettings copyWith({
    bool? masterEnabled,
    bool? appEnabled,
    bool? classEnabled,
    int? classLeadMinutes,
  }) {
    return LearnerNotificationSettings(
      masterEnabled: masterEnabled ?? this.masterEnabled,
      appEnabled: appEnabled ?? this.appEnabled,
      classEnabled: classEnabled ?? this.classEnabled,
      classLeadMinutes: classLeadMinutes ?? this.classLeadMinutes,
    );
  }
}

class LearnerNotificationSettingsService {
  LearnerNotificationSettingsService._();

  static const String nodeName = 'notification_settings';
  static const List<int> leadOptions = [5, 10, 15, 20, 30, 60];

  static final DatabaseReference _db = FirebaseDatabase.instance.ref();

  static DatabaseReference refForUid(String uid) {
    return _db.child('users/$uid/$nodeName');
  }

  static Future<LearnerNotificationSettings> load(String uid) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return LearnerNotificationSettings.defaults();

    try {
      final snap = await refForUid(safeUid).get();
      final v = snap.value;
      if (v is Map) {
        final map = v.map((k, v) => MapEntry(k.toString(), v));
        return LearnerNotificationSettings.fromMap(map);
      }
    } catch (_) {}

    return LearnerNotificationSettings.defaults();
  }

  static Future<void> save(
    String uid,
    LearnerNotificationSettings settings,
  ) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return;
    await refForUid(safeUid).update(settings.toMap());
  }

  static Future<bool> appNotificationsEnabled(String uid) async {
    final settings = await load(uid);
    return settings.masterEnabled && settings.appEnabled;
  }

  static Future<bool> classNotificationsEnabled(String uid) async {
    final settings = await load(uid);
    return settings.masterEnabled && settings.classEnabled;
  }

  static Future<int> classLeadMinutes(String uid) async {
    final settings = await load(uid);
    return settings.classLeadMinutes;
  }
}
