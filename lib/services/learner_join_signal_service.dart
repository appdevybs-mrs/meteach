import 'package:firebase_database/firebase_database.dart';

import 'push_dispatch_service.dart';

class LearnerJoinSignalService {
  LearnerJoinSignalService._();

  static final DatabaseReference _db = FirebaseDatabase.instance.ref();
  static final Map<String, int> _lastSignalMsByKey = <String, int>{};

  static String _sanitize(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  static String _clip(String raw, {int max = 160}) {
    final v = raw.trim();
    if (v.length <= max) return v;
    return v.substring(0, max);
  }

  static Future<void> notifyTeacherJoinTap({
    required String learnerUid,
    required String teacherUid,
    required String learnerName,
    required String source,
    String courseId = '',
    String courseTitle = '',
    String dayKey = '',
    String time = '',
    int sessionStartMs = 0,
  }) async {
    final safeLearnerUid = learnerUid.trim();
    final safeTeacherUid = teacherUid.trim();
    if (safeLearnerUid.isEmpty || safeTeacherUid.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final throttledKey = [
      safeLearnerUid,
      safeTeacherUid,
      _sanitize(courseId),
      _sanitize(dayKey),
      _sanitize(time),
      sessionStartMs.toString(),
      _sanitize(source),
    ].join('|');

    final lastMs = _lastSignalMsByKey[throttledKey] ?? 0;
    if (nowMs - lastMs < 60000) return;
    _lastSignalMsByKey[throttledKey] = nowMs;
    if (_lastSignalMsByKey.length > 300) {
      _lastSignalMsByKey.remove(_lastSignalMsByKey.keys.first);
    }

    final safeLearnerName = learnerName.trim().isEmpty
        ? 'Learner'
        : learnerName.trim();
    final safeCourseTitle = courseTitle.trim();
    final safeCourseId = courseId.trim();
    final safeDayKey = dayKey.trim();
    final safeTime = time.trim();

    final whereText = (safeDayKey.isNotEmpty && safeTime.isNotEmpty)
        ? ' on $safeDayKey at $safeTime'
        : '';
    final courseText = safeCourseTitle.isNotEmpty
        ? ' for $safeCourseTitle'
        : (safeCourseId.isNotEmpty ? ' for course $safeCourseId' : '');

    final title = 'Learner is trying to join';
    final message = '$safeLearnerName tapped Join$courseText$whereText.';

    final signalRef = _db.child('join_tap_signals/$safeTeacherUid').push();

    try {
      await signalRef.set({
        'type': 'learner_join_tap',
        'source': _clip(source, max: 80),
        'learnerUid': safeLearnerUid,
        'learnerName': _clip(safeLearnerName),
        'teacherUid': safeTeacherUid,
        'courseId': _clip(safeCourseId, max: 80),
        'courseTitle': _clip(safeCourseTitle),
        'dayKey': _clip(safeDayKey, max: 32),
        'time': _clip(safeTime, max: 32),
        'sessionStartMs': sessionStartMs,
        'createdAt': ServerValue.timestamp,
      });
    } catch (_) {}

    try {
      await PushDispatchService.dispatchToUser(
        intent: PushIntent.booking,
        targetUid: safeTeacherUid,
        title: title,
        message: message,
        context: PushDispatchContext(
          screen: source,
          action: 'learner_join_tap_push',
        ),
        eventParts: [
          'learner_join_tap',
          safeLearnerUid,
          safeTeacherUid,
          safeCourseId,
          safeDayKey,
          safeTime,
          if (sessionStartMs > 0) sessionStartMs.toString(),
        ],
        data: {
          'targetRole': 'teacher',
          'targetUid': safeTeacherUid,
          'source': source,
          'joinTap': '1',
          'learnerUid': safeLearnerUid,
          'learnerName': safeLearnerName,
          'teacherUid': safeTeacherUid,
          'courseId': safeCourseId,
          'courseTitle': safeCourseTitle,
          'dayKey': safeDayKey,
          'time': safeTime,
          if (sessionStartMs > 0) 'sessionStartMs': sessionStartMs.toString(),
          if (signalRef.key != null) 'signalId': signalRef.key,
        },
      );
    } catch (_) {}
  }
}
