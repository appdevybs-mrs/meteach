import 'package:firebase_database/firebase_database.dart';

class StudyStreakService {
  StudyStreakService._();
  static final StudyStreakService instance = StudyStreakService._();

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Future<Map<String, dynamic>> getStreakData({
    required String uid,
    required String courseKey,
  }) async {
    try {
      final snap = await _db
          .child('users/$uid/courses/$courseKey/streak_data')
          .get();
      if (snap.exists && snap.value is Map) {
        return Map<String, dynamic>.from(snap.value as Map);
      }
    } catch (_) {}
    return {
      'currentStreak': 0,
      'longestStreak': 0,
      'lastStudyDate': '',
      'weeklySessions': 0,
      'weekStart': '',
    };
  }

  Future<void> updateStreak({
    required String uid,
    required String courseKey,
  }) async {
    final data = await getStreakData(uid: uid, courseKey: courseKey);
    final now = DateTime.now();
    final today = _fmtDate(now);

    final lastDate = (data['lastStudyDate'] ?? '').toString();

    final currentStreak = (data['currentStreak'] as num?)?.toInt() ?? 0;
    final longestStreak = (data['longestStreak'] as num?)?.toInt() ?? 0;
    var weeklySessions = (data['weeklySessions'] as num?)?.toInt() ?? 0;
    var weekStart = (data['weekStart'] ?? '').toString();

    if (lastDate == today) return;

    final yesterday = _fmtDate(DateTime(now.year, now.month, now.day - 1));
    final newStreak = lastDate == yesterday ? currentStreak + 1 : 1;
    final newLongest = newStreak > longestStreak ? newStreak : longestStreak;

    final thisMonday = _fmtDate(_mondayOfWeek(now));
    if (weekStart != thisMonday) {
      weeklySessions = 1;
      weekStart = thisMonday;
    } else {
      weeklySessions++;
    }

    await _db
        .child('users/$uid/courses/$courseKey/streak_data')
        .update({
      'currentStreak': newStreak,
      'longestStreak': newLongest,
      'lastStudyDate': today,
      'weeklySessions': weeklySessions,
      'weekStart': weekStart,
    });
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  DateTime _mondayOfWeek(DateTime date) {
    final diff = date.weekday - DateTime.monday;
    return DateTime(date.year, date.month, date.day - diff);
  }
}
