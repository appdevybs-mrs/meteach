import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TopicService {
  TopicService._();

  static const String _prefsPrefix = 'fcm_topics_v2_';
  static final Set<String> _syncingUids = <String>{};

  static const Set<String> _knownRoleTopics = <String>{
    'admins',
    'teachers',
    'learners',
  };

  static String normalizeRole(String role) {
    final r = role.toLowerCase().trim();
    if ({
      'admin',
      'adin',
      'admn',
      'adm',
      'administrator',
      'administration',
    }.contains(r)) {
      return 'admin';
    }
    if ({
      'teacher',
      'teachers',
      'teacher(s)',
      'teach',
      'instructor',
      'prof',
    }.contains(r)) {
      return 'teacher';
    }
    if ({
      'learner',
      'learners',
      'learner(s)',
      'student',
      'pupil',
      'lerner',
    }.contains(r)) {
      return 'learner';
    }
    return '';
  }

  static Set<String> _targetTopics({
    required String normalizedRole,
    required String uid,
  }) {
    final topics = <String>{'all', 'user_$uid'};
    if (normalizedRole == 'admin') topics.add('admins');
    if (normalizedRole == 'teacher') topics.add('teachers');
    if (normalizedRole == 'learner') topics.add('learners');
    return topics;
  }

  /// Call this after you know the user's role (admin/teacher/learner)
  static Future<void> syncForCurrentUser({
    required String role,
    required String uid,
  }) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return;
    if (_syncingUids.contains(safeUid)) return;
    _syncingUids.add(safeUid);

    try {
      final prefs = await SharedPreferences.getInstance();
      final prefKey = '$_prefsPrefix$safeUid';

      final previousRaw = prefs.getString(prefKey) ?? '';
      final previous = previousRaw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();

      final normalizedRole = normalizeRole(role);
      final target = _targetTopics(
        normalizedRole: normalizedRole,
        uid: safeUid,
      );

      final toUnsubscribe = previous.difference(target);
      final toSubscribe = target.difference(previous);

      for (final topic in toUnsubscribe) {
        await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
      }

      for (final topic in toSubscribe) {
        await FirebaseMessaging.instance.subscribeToTopic(topic);
      }

      final next = target.toList()..sort();
      await prefs.setString(prefKey, next.join(','));
    } finally {
      _syncingUids.remove(safeUid);
    }
  }

  static Future<void> clearForUser(String uid) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final prefKey = '$_prefsPrefix$safeUid';
    final previousRaw = prefs.getString(prefKey) ?? '';
    final previous = previousRaw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();

    final fallback = <String>{'all', 'user_$safeUid', ..._knownRoleTopics};
    final allToRemove = {...previous, ...fallback};

    for (final topic in allToRemove) {
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
    }

    try {
      final token = (await FirebaseMessaging.instance.getToken() ?? '').trim();
      if (token.isNotEmpty) {
        final ref = FirebaseDatabase.instance.ref('fcm_tokens_v2/$safeUid');
        final snap = await ref.get();
        final raw = snap.value;
        if (raw is Map) {
          final entries = raw.entries.toList();
          for (final e in entries) {
            final key = e.key.toString().trim();
            if (key.isEmpty || e.value is! Map) continue;
            final m = (e.value as Map).map((k, v) => MapEntry(k.toString(), v));
            final rowToken = (m['token'] ?? '').toString().trim();
            if (rowToken == token) {
              await ref.child(key).remove();
            }
          }
        }
      }
    } catch (_) {}

    await prefs.remove(prefKey);
  }
}
