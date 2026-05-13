import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/human_error.dart';
import '../services/push_dispatch_service.dart';
import '../services/notification_service.dart';
import '../services/audit_action_keys.dart';
import '../services/audit_log_service.dart';
import '../shared/app_feedback.dart';
import '../shared/ybs_busy_logo.dart';
import '../shared/learner_web_layout.dart';
import '../shared/payment_status.dart';

class LearnerBookingScreen extends StatefulWidget {
  const LearnerBookingScreen({super.key, this.courseId});

  /// Pass a REAL courseId (recommended).
  final String? courseId;

  @override
  State<LearnerBookingScreen> createState() => _LearnerBookingScreenState();
}

class _LearnerBookingScreenState extends State<LearnerBookingScreen>
    with SingleTickerProviderStateMixin {
  // ===== Colors =====
  static const primaryBlue = Color(0xFF0E7C86);
  static const actionOrange = Color(0xFFBF5D39);
  static const appBg = Color(0xFFF6F2E8);
  static const uiBorder = Color(0xFFD8CFC1);

  // Simplified status colors
  static const peerBg = Color(0xFFE9F4FF);
  static const peerBorder = Color(0xFF9BC8FF);
  static const bookedBg = Color(0xFFEAF7EE);
  static const bookedBorder = Color(0xFFB9E2C5);
  static const otherSessionBg = Color(0xFFF1F3F5);
  static const otherSessionBorder = Color(0xFFCED4DA);
  static const emptyBg = Color(0xFFFFF1E3);
  static const emptyBorder = Color(0xFFF9C59D);
  static const lockedBg = Color(0xFFF4F4F5);
  static const lockedBorder = Color(0xFFD7D7DB);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // Auth
  String myUid = '';
  bool loading = true;
  bool booking = false;
  bool refreshing = false;
  String progressLabel = '';

  // Course
  String? courseId;
  String courseTitle = '';

  // Curriculum (optional)
  int totalSessions = 0;
  Map<String, dynamic> curriculumSessions = {};

  // Progress
  int currentSession = 1;
  int studiedSessionsConsumed = 0;

  String studyMode = 'follow'; // follow | custom
  int selectedSessionNo = 1;
  bool lessonsExpanded = false;

  // Slots window / schedule
  int daysAhead = 14;
  List<_Slot> generatedSlots = [];

  // My bookings map: "yyyy-mm-dd|HH:MM|teacherId" -> sessionNo
  Map<String, int> myBookedSlots = {};

  // Slot group summary: "yyyy-mm-dd|HH:MM|teacherId" -> summary
  Map<String, _SlotSummary> slotSummary = {};

  // UI state
  _BookingFlowStep flowStep = _BookingFlowStep.lessonChoice;
  DateTime? selectedDay;
  String? selectedTime;
  String? selectedTeacherId;
  int? selectedLessonForFlow;
  String helpLang = 'en'; // en | ar | fr | tr | ur
  late final AnimationController _sessionPulseCtrl;
  Map<String, List<_BusyRange>>? _busyRangesCache;
  DateTime? _busyRangesCacheAt;
  static const Duration _busyRangesCacheTtl = Duration(seconds: 25);
  DateTime? _busyVisualSince;

  @override
  void initState() {
    super.initState();
    _sessionPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 980),
    )..repeat(reverse: true);
    _init();
  }

  @override
  void dispose() {
    _sessionPulseCtrl.dispose();
    super.dispose();
  }

  // ================== Helpers ==================

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<bool> _confirmWithLogo({
    required String title,
    required String message,
    required String confirmLabel,
    Color confirmColor = primaryBlue,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
        title: Row(
          children: [
            const YbsBusyLogo(size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        content: Text(message, style: const TextStyle(height: 1.35)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: confirmColor),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  String _weekdayKey(DateTime d) {
    switch (d.weekday) {
      case DateTime.monday:
        return 'mon';
      case DateTime.tuesday:
        return 'tue';
      case DateTime.wednesday:
        return 'wed';
      case DateTime.thursday:
        return 'thu';
      case DateTime.friday:
        return 'fri';
      case DateTime.saturday:
        return 'sat';
      default:
        return 'sun';
    }
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  bool _toBool(dynamic v, {bool fallback = false}) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return fallback;
  }

  Map<String, dynamic> _asStringKeyMap(dynamic value) {
    if (value is! Map) return const <String, dynamic>{};
    final out = <String, dynamic>{};
    value.forEach((k, v) {
      out[k.toString()] = v;
    });
    return out;
  }

  int _readSessionNoFromProgress(dynamic raw) {
    if (raw == null) return 0;

    if (raw is Map) {
      final m = _asStringKeyMap(raw);
      final direct = _toInt(m['currentSession'], fallback: 0);
      if (direct > 0) return direct;

      if (m.length == 1) {
        return _readSessionNoFromProgress(m.values.first);
      }
      return 0;
    }

    return _toInt(raw, fallback: 0);
  }

  int get _effectiveTotalSessions {
    if (totalSessions > 0) return totalSessions;
    if (curriculumSessions.isNotEmpty) return curriculumSessions.length;
    return currentSession > 0 ? currentSession : 1;
  }

  int get _targetSessionNo {
    final maxSessions = _effectiveTotalSessions;
    if (studyMode == 'custom') {
      return selectedSessionNo.clamp(1, maxSessions).toInt();
    }
    return currentSession.clamp(1, maxSessions).toInt();
  }

  DatabaseReference _availabilityRootRef() => _db.child('booking_availability');

  DatabaseReference _progressRef(String cid) =>
      _db.child('booking_progress/$myUid/$cid');

  DatabaseReference _reservationsRootRef(String cid) =>
      _db.child('booking_reservations/$cid');

  DatabaseReference _legacyReservationsRef(
    String cid,
    String dayKey,
    String hhmm,
  ) => _db.child('booking_reservations/$cid/$dayKey/$hhmm');

  DatabaseReference _reservationsRef(
    String cid,
    String dayKey,
    String hhmm,
    String teacherId,
  ) => _db.child('booking_reservations/$cid/$dayKey/$hhmm/$teacherId');

  String _slotSummaryKey(String dayKey, String hhmm, String teacherId) =>
      '$dayKey|$hhmm|$teacherId';

  String _bookingKey(String courseId, String dayKey, String hhmm) =>
      '$courseId|$dayKey|$hhmm';

  String _bilingual(String en, String ar) => '$en\n$ar';

  Future<bool> _hasPossibleMissingAttendanceForSession({
    required String cid,
    required int sessionNo,
  }) async {
    if (sessionNo <= 0) return false;

    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(hours: 2));
    const lookbackDays = 35;

    final attendanceByKey = <String, dynamic>{};
    try {
      final attSnap = await _progressRef(cid).child('online_attendance').get();
      if (attSnap.exists && attSnap.value is Map) {
        final m = (attSnap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        attendanceByKey.addAll(m);
      }
    } catch (_) {}

    bool hasMissingForBooking(String dayKey, String hhmm) {
      final bKey = _bookingKey(cid, dayKey, hhmm);
      final rec = attendanceByKey[bKey];
      if (rec is! Map) return true;
      return false;
    }

    try {
      for (int i = 1; i <= lookbackDays; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: i));
        final dayKey = _dateKey(day);

        final daySnap = await _reservationsRootRef(cid).child(dayKey).get();
        if (!daySnap.exists || daySnap.value is! Map) continue;

        final byTime = (daySnap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );

        for (final timeEntry in byTime.entries) {
          final hhmm = timeEntry.key;
          final timeNode = timeEntry.value;
          if (timeNode is! Map) continue;

          final start = _parseSlotStart(dayKey, hhmm);
          if (start == null || start.isAfter(cutoff)) continue;

          final m = timeNode.map((k, v) => MapEntry(k.toString(), v));

          bool matchesSlot(Map<dynamic, dynamic> slotNode) {
            final sm = slotNode.map((k, v) => MapEntry(k.toString(), v));
            final learnersRaw = sm['learners'];
            if (learnersRaw is! Map) return false;

            final learners = learnersRaw.map(
              (k, v) => MapEntry(k.toString(), v),
            );
            if (!learners.containsKey(myUid)) return false;

            final sNo = _toInt(sm['sessionNo'], fallback: 0);
            return sNo == sessionNo;
          }

          if (m['learners'] is Map) {
            if (matchesSlot(m) && hasMissingForBooking(dayKey, hhmm)) {
              return true;
            }
            continue;
          }

          for (final teacherEntry in m.entries) {
            final teacherNode = teacherEntry.value;
            if (teacherNode is! Map) continue;
            if (matchesSlot(teacherNode) &&
                hasMissingForBooking(dayKey, hhmm)) {
              return true;
            }
          }
        }
      }
    } catch (_) {}

    return false;
  }

  Future<bool?> _askSessionCheckBeforeBooking(int sessionNo) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Session check'),
        content: Text(
          'You may have already attended Session $sessionNo, but attendance is not confirmed yet.\n\n'
          'You can restudy this session, or choose another session manually.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Choose another'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restudy this'),
          ),
        ],
      ),
    );
  }

  DateTime? _parseSlotStart(String dayKey, String hhmm) {
    try {
      final dp = dayKey.split('-');
      if (dp.length != 3) return null;
      final y = int.tryParse(dp[0]);
      final m = int.tryParse(dp[1]);
      final d = int.tryParse(dp[2]);
      if (y == null || m == null || d == null) return null;

      final tp = hhmm.split(':');
      if (tp.length != 2) return null;
      final hh = int.tryParse(tp[0]);
      final mm = int.tryParse(tp[1]);
      if (hh == null || mm == null) return null;

      return DateTime(y, m, d, hh, mm);
    } catch (_) {
      return null;
    }
  }

  int _weekdayFromShort(String day) {
    switch (day.trim().toLowerCase()) {
      case 'mon':
      case 'monday':
        return DateTime.monday;
      case 'tue':
      case 'tues':
      case 'tuesday':
        return DateTime.tuesday;
      case 'wed':
      case 'wednesday':
        return DateTime.wednesday;
      case 'thu':
      case 'thur':
      case 'thurs':
      case 'thursday':
        return DateTime.thursday;
      case 'fri':
      case 'friday':
        return DateTime.friday;
      case 'sat':
      case 'saturday':
        return DateTime.saturday;
      case 'sun':
      case 'sunday':
        return DateTime.sunday;
      default:
        return DateTime.monday;
    }
  }

  String _busyKey(String teacherId, String dayKey) => '$teacherId|$dayKey';

  bool _hasTimeOverlap({
    required DateTime aStart,
    required DateTime aEnd,
    required DateTime bStart,
    required DateTime bEnd,
  }) {
    return aStart.isBefore(bEnd) && bStart.isBefore(aEnd);
  }

  String _readClassTeacherUid(Map<String, dynamic> classData) {
    final direct = [
      classData['teacherUid'],
      classData['teacher_uid'],
      classData['teacherId'],
      classData['teacher_id'],
      classData['instructorUid'],
      classData['instructor_uid'],
    ];

    for (final raw in direct) {
      final s = (raw ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }

    final current = classData['instructor_current'];
    if (current is Map) {
      final cm = current.map((k, v) => MapEntry(k.toString(), v));
      final fromCurrent =
          (cm['uid'] ?? cm['teacher_uid'] ?? cm['teacherId'] ?? cm['id'] ?? '')
              .toString()
              .trim();
      if (fromCurrent.isNotEmpty) return fromCurrent;
    }

    return '';
  }

  Future<Map<String, List<_BusyRange>>>
  _loadTeacherBusyRangesForWindow() async {
    final nowForCache = DateTime.now();
    if (_busyRangesCache != null && _busyRangesCacheAt != null) {
      final age = nowForCache.difference(_busyRangesCacheAt!);
      if (age <= _busyRangesCacheTtl) {
        return _busyRangesCache!;
      }
    }

    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final endOfWindow = startOfToday.add(Duration(days: daysAhead));

    final out = <String, List<_BusyRange>>{};

    try {
      final snap = await _db.child('classes').get();
      if (!snap.exists || snap.value is! Map) return out;

      final root = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

      for (final entry in root.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;

        final cls = raw.map((k, v) => MapEntry(k.toString(), v));
        final status = (cls['status'] ?? '').toString().trim().toLowerCase();
        if (status != 'active') continue;

        final teacherId = _readClassTeacherUid(cls);
        if (teacherId.isEmpty) continue;

        final schedule = cls['schedule'];
        if (schedule is! Map) continue;
        final sm = schedule.map((k, v) => MapEntry(k.toString(), v));

        final firstRaw = (sm['first_session_date'] ?? '').toString().trim();
        final firstDate = DateTime.tryParse(firstRaw);
        final firstDay = firstDate == null
            ? startOfToday
            : DateTime(firstDate.year, firstDate.month, firstDate.day);

        final sessionsRaw = sm['sessions'];
        final rows = <Map<String, dynamic>>[];
        if (sessionsRaw is List) {
          for (final item in sessionsRaw) {
            if (item is! Map) continue;
            rows.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        } else if (sessionsRaw is Map) {
          for (final item in sessionsRaw.values) {
            if (item is! Map) continue;
            rows.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
        if (rows.isEmpty) continue;

        for (int i = 0; i < daysAhead; i++) {
          final day = startOfToday.add(Duration(days: i));
          if (day.isBefore(firstDay)) continue;

          final dayKey = _dateKey(day);
          for (final row in rows) {
            final weekday = _weekdayFromShort((row['day'] ?? '').toString());
            if (weekday != day.weekday) continue;

            final hm = (row['start_time'] ?? '').toString().trim().split(':');
            if (hm.length != 2) continue;

            final h = int.tryParse(hm[0]);
            final m = int.tryParse(hm[1]);
            if (h == null || m == null) continue;
            if (h < 0 || h > 23 || m < 0 || m > 59) continue;

            final start = DateTime(day.year, day.month, day.day, h, m);
            if (!start.isBefore(endOfWindow)) continue;

            final duration = _toInt(row['duration_min'], fallback: 60);
            final safeDuration = duration > 0 ? duration : 60;
            final end = start.add(Duration(minutes: safeDuration));

            final key = _busyKey(teacherId, dayKey);
            out
                .putIfAbsent(key, () => <_BusyRange>[])
                .add(_BusyRange(start: start, end: end));
          }
        }
      }
    } catch (_) {}

    _busyRangesCache = out;
    _busyRangesCacheAt = DateTime.now();
    return out;
  }

  void _invalidateBusyRangesCache() {
    _busyRangesCache = null;
    _busyRangesCacheAt = null;
  }

  bool _hasClassConflict(
    Map<String, List<_BusyRange>> busyByTeacherDay,
    String teacherId,
    DateTime slotStart,
    int slotDurationMinutes,
  ) {
    final dayKey = _dateKey(slotStart);
    final busy = busyByTeacherDay[_busyKey(teacherId, dayKey)] ?? const [];
    if (busy.isEmpty) return false;

    final slotDuration = slotDurationMinutes > 0 ? slotDurationMinutes : 60;
    final slotEnd = slotStart.add(Duration(minutes: slotDuration));
    for (final b in busy) {
      if (_hasTimeOverlap(
        aStart: slotStart,
        aEnd: slotEnd,
        bStart: b.start,
        bEnd: b.end,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<String> _loadTeacherProfileMeetUrl(String teacherId) async {
    final id = teacherId.trim();
    if (id.isEmpty) return '';
    try {
      final snap = await _db.child('users/$id/google_meet_url').get();
      return (snap.value ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  bool _isWithin24Hours(_Slot slot) {
    return !slot.start.isAfter(DateTime.now().add(const Duration(hours: 24)));
  }

  bool _isBookingLockedForNewBooking(_Slot slot) {
    if (slot.bookedByMe) return false;
    return _isWithin24Hours(slot);
  }

  bool _isJoinable(_Slot s) {
    final targetSession = _targetSessionNo;
    if (_isBookingLockedForNewBooking(s)) return false;
    if (s.bookedByMe) return true;
    if (s.groupSessionNo == null) return true;
    if (s.groupSessionNo != targetSession) return false;
    if (s.isFull) return false;
    return true;
  }

  Future<String> _getMyFullName() async {
    try {
      final snap = await _db.child('users/$myUid').get();
      if (!snap.exists || snap.value is! Map) return 'Learner';

      final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();

      final full = '$first $last'.trim();
      if (full.isNotEmpty) return full;

      return 'Learner';
    } catch (_) {
      return 'Learner';
    }
  }

  Future<void> _sendBookingNotifications(_Slot slot) async {
    try {
      final learnerName = await _getMyFullName();

      final sessionNo = slot.groupSessionNo ?? _targetSessionNo;
      final safeCourseTitle = courseTitle.trim().isEmpty
          ? 'Course'
          : courseTitle.trim();

      final adminTitle = 'New learner booking';
      final adminBody =
          '$learnerName booked Session $sessionNo for $safeCourseTitle on ${slot.dayKey} at ${slot.time} with ${slot.teacherName}.';

      final adminEventId =
          'booking_admin_${slot.courseId}_${slot.teacherId}_${slot.dayKey}_${slot.time}_${myUid}_$sessionNo';
      final adminUids = await PushDispatchService.loadAdminUids();
      await PushDispatchService.dispatchAdminTopic(
        intent: PushIntent.booking,
        title: adminTitle,
        message: adminBody,
        context: const PushDispatchContext(
          screen: 'learner/learner_booking',
          action: 'booking_admin_push',
        ),
        eventParts: [adminEventId],
        fallbackAdminUids: adminUids,
        data: {
          'targetRole': 'admin',
          'courseId': slot.courseId,
          'courseTitle': safeCourseTitle,
          'teacherId': slot.teacherId,
          'teacherName': slot.teacherName,
          'learnerUid': myUid,
          'learnerName': learnerName,
          'dayKey': slot.dayKey,
          'time': slot.time,
          'sessionNo': sessionNo.toString(),
        },
      );

      final teacherTitle = 'New class booking';
      final teacherBody =
          '$learnerName booked Session $sessionNo for $safeCourseTitle on ${slot.dayKey} at ${slot.time}.';

      final teacherEventId =
          'booking_teacher_${slot.courseId}_${slot.teacherId}_${slot.dayKey}_${slot.time}_${myUid}_$sessionNo';

      await PushDispatchService.dispatchToUser(
        intent: PushIntent.booking,
        targetUid: slot.teacherId,
        title: teacherTitle,
        message: teacherBody,
        context: const PushDispatchContext(
          screen: 'learner/learner_booking',
          action: 'booking_teacher_push',
        ),
        eventParts: [teacherEventId],
        data: {
          'targetRole': 'teacher',
          'courseId': slot.courseId,
          'courseTitle': safeCourseTitle,
          'teacherId': slot.teacherId,
          'teacherName': slot.teacherName,
          'learnerUid': myUid,
          'learnerName': learnerName,
          'dayKey': slot.dayKey,
          'time': slot.time,
          'sessionNo': sessionNo.toString(),
        },
      );
    } catch (_) {}
  }

  Future<void> _scheduleLearnerLocalReminder(_Slot slot) async {
    try {
      await NotificationService.I.init();
      await NotificationService.I.requestPermissions();

      final sessionNo = slot.groupSessionNo ?? _targetSessionNo;
      final safeCourseTitle = courseTitle.trim().isEmpty
          ? 'Course'
          : courseTitle.trim();

      await NotificationService.I.scheduleSessionReminderSeries(
        classId: '${slot.courseId}_${slot.dayKey}_${slot.time}',
        title: 'Upcoming class',
        body:
            'Session $sessionNo for $safeCourseTitle with ${slot.teacherName}',
        sessionStart: slot.start,
        minutesBeforeList: const [60, 20, 5],
      );
    } catch (_) {}
  }

  Future<void> _runBusy(String label, Future<void> Function() action) async {
    _markBusyVisualStart();
    if (!mounted) return;
    setState(() {
      progressLabel = label;
    });

    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          progressLabel = '';
        });
        _clearBusyVisualIfIdle();
      }
    }
  }

  void _setProgressLabel(String label) {
    if (!mounted) return;
    if (label.isNotEmpty) {
      _markBusyVisualStart();
    }
    setState(() {
      progressLabel = label;
    });
    if (label.isEmpty) {
      _clearBusyVisualIfIdle();
    }
  }

  void _markBusyVisualStart() {
    _busyVisualSince ??= DateTime.now();
  }

  void _clearBusyVisualIfIdle() {
    final stillBusy =
        loading || booking || refreshing || progressLabel.isNotEmpty;
    if (!stillBusy) {
      _busyVisualSince = null;
    }
  }

  // ================== Init ==================

  Future<void> _init() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => loading = false);
      _toast('Not logged in.');
      return;
    }
    myUid = uid;

    if (widget.courseId != null && widget.courseId!.trim().isNotEmpty) {
      courseId = widget.courseId!.trim();
    } else {
      final courses = await _loadLearnerBookingCourses();
      if (courses.isEmpty) {
        courseId = null;
      } else if (courses.length == 1) {
        courseId = courses.first.id;
      } else {
        courseId = await _showCourseChooser(courses);
      }
    }
    if (courseId == null || courseId!.isEmpty) {
      setState(() => loading = false);
      _toast('No courseId found for this learner.');
      return;
    }

    final gate = await _bookingGateForCourse(courseId!);
    if (!gate.enabled) {
      setState(() => loading = false);
      _toast('Booking is not enabled for this course yet.');
      return;
    }

    if (gate.title.isNotEmpty) courseTitle = gate.title;
    if (gate.totalSessions > 0) totalSessions = gate.totalSessions;

    await _loadCurriculum(courseId!);
    await _loadOrCreateProgress(courseId!);
    await _loadStudiedSessions(courseId!);

    await _inferClassIdForCourse(courseId!);

    await _loadReservationsSummary(courseId!);
    await _generateSlots(courseId!);

    if (!mounted) return;
    setState(() => loading = false);
  }

  Future<List<_CourseChoice>> _loadLearnerBookingCourses() async {
    final out = <_CourseChoice>[];
    try {
      final snap = await _db.child('users/$myUid/courses').get();
      final v = snap.value;
      if (v is! Map) return out;

      final courses = v.map((k, vv) => MapEntry(k.toString(), vv));

      for (final entry in courses.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;

        final m = raw.map((k, vv) => MapEntry(k.toString(), vv));

        final id = (m['id'] ?? m['courseId'] ?? m['course_id'] ?? '')
            .toString()
            .trim();

        final variantKey = (m['variantKey'] ?? m['variant'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        final deliveryKey = (m['deliveryKey'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        final isBookingCourse =
            variantKey == 'flexible' || deliveryKey == 'flexible';

        if (id.isNotEmpty && isBookingCourse) {
          final title = (m['title'] ?? m['courseTitle'] ?? m['name'] ?? id)
              .toString()
              .trim();
          out.add(_CourseChoice(id: id, title: title.isEmpty ? id : title));
        }
      }
    } catch (_) {}

    final seen = <String>{};
    final unique = <_CourseChoice>[];
    for (final c in out) {
      if (seen.add(c.id)) unique.add(c);
    }
    return unique;
  }

  Future<String?> _showCourseChooser(List<_CourseChoice> courses) async {
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose your course',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  color: primaryBlue,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Select the course you want to book a class for.',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView.separated(
                  itemCount: courses.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final c = courses[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Navigator.pop(context, c.id),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBF5),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: uiBorder),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.menu_book_rounded,
                              color: primaryBlue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                c.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: primaryBlue,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward_rounded,
                              color: actionOrange,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _inferClassIdForCourse(String cid) async {
    try {
      final snap = await _db.child('classes').get();
      if (!snap.exists || snap.value is! Map) return '';

      final all = Map<dynamic, dynamic>.from(snap.value as Map);

      for (final entry in all.entries) {
        final classId = entry.key.toString();
        final val = entry.value;
        if (val is! Map) continue;

        final c = val.map((k, v) => MapEntry(k.toString(), v));
        final courseIdAny =
            (c['course_id'] ?? c['courseId'] ?? c['course'] ?? '')
                .toString()
                .trim();
        if (courseIdAny != cid) continue;

        final learners = c['learners'];
        if (learners is Map) {
          final lm = Map<dynamic, dynamic>.from(learners);
          if (lm.containsKey(myUid)) return classId;
        }
      }
    } catch (_) {}
    return '';
  }

  // ================== Booking Gate ==================

  Future<_BookingGate> _bookingGateForCourse(String cid) async {
    try {
      final snap = await _db.child('syllabi/$cid/flexible').get();

      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

        final String title = (m['title'] ?? '').toString().trim();
        int total = 0;

        final units = m['units'];
        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = u.map((k, v) => MapEntry(k.toString(), v));
            final sessions = unit['sessions'];

            if (sessions is List) {
              total += sessions.length;
            }
          }
        }

        return _BookingGate(
          enabled: true,
          totalSessions: total,
          title: title,
          source: 'syllabi/flexible',
        );
      }
    } catch (_) {}

    return const _BookingGate(
      enabled: false,
      totalSessions: 0,
      title: '',
      source: 'none',
    );
  }

  // ================== Load Curriculum ==================

  Future<void> _loadCurriculum(String cid) async {
    try {
      final snap = await _db.child('syllabi/$cid/flexible').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

      final root = (snap.value as Map).map(
        (k, vv) => MapEntry(k.toString(), vv),
      );

      final t = (root['title'] ?? '').toString().trim();
      if (t.isNotEmpty) courseTitle = t;

      final units = root['units'];
      final Map<String, dynamic> out = {};
      int fallbackNo = 1;

      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final unit = u.map((k, vv) => MapEntry(k.toString(), vv));
          final sessions = unit['sessions'];

          if (sessions is! List) continue;

          for (final s in sessions) {
            if (s is! Map) continue;
            final sess = s.map((k, vv) => MapEntry(k.toString(), vv));

            final sourceSessionNo = _toInt(sess['sessionNumber'], fallback: 0);
            final no = fallbackNo;

            out['$no'] = {
              'sessionNo': no,
              'sourceSessionNumber': sourceSessionNo,
              'sessionTitle': (sess['title'] ?? '').toString(),
              'objective': (sess['objective'] ?? '').toString(),
              'content': (sess['content'] ?? '').toString(),
              'homework': (sess['homework'] ?? '').toString(),
              'durationMinutes': _toInt(sess['durationMinutes'], fallback: 0),
              'source': 'syllabi/flexible',
            };

            fallbackNo++;
          }
        }
      }

      curriculumSessions = out;

      if (totalSessions <= 0) {
        totalSessions = out.length;
      }
    } catch (e) {
      _toast('Failed to load booking syllabus: $e');
    }
  }

  // ================== Load / Create Progress ==================

  Future<void> _loadOrCreateProgress(String cid) async {
    try {
      final ref = _progressRef(cid);
      final snap = await ref.get();
      final raw = snap.value;

      final sessionNo = _readSessionNoFromProgress(raw);
      currentSession = sessionNo > 0 ? sessionNo : 1;
      selectedSessionNo = currentSession;

      final needsCanonicalWrite =
          raw == null ||
          raw is! Map ||
          _asStringKeyMap(raw)['currentSession'] == null;

      if (needsCanonicalWrite) {
        await ref.set({
          'currentSession': currentSession,
          'updatedAt': ServerValue.timestamp,
        });
      }
    } catch (e) {
      currentSession = 1;
      selectedSessionNo = 1;
      try {
        await _progressRef(
          cid,
        ).set({'currentSession': 1, 'updatedAt': ServerValue.timestamp});
      } catch (writeError) {
        final lower = writeError.toString().toLowerCase();
        final denied =
            lower.contains('permission-denied') ||
            lower.contains('permission denied');
        if (!denied) {
          _toast(
            toHumanError(
              writeError,
              fallback: 'Could not load your booking progress.',
            ),
          );
        }
      }
    }
  }

  Future<void> _loadStudiedSessions(String cid) async {
    try {
      final snap = await _progressRef(cid).child('online_attendance').get();
      studiedSessionsConsumed = countPresentOnlineAttendance(snap.value);
    } catch (_) {
      studiedSessionsConsumed = 0;
    }
  }

  // ================== Load Reservations Summary ==================

  Future<void> _loadReservationsSummary(String cid) async {
    final now = DateTime.now();
    final Map<String, int> mine = {};
    final Map<String, _SlotSummary> summary = {};

    try {
      final dayKeys = <String>[];
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        dayKeys.add(_dateKey(day));
      }

      final snaps = await Future.wait(
        dayKeys.map((dk) => _reservationsRootRef(cid).child(dk).get()),
      );

      for (int i = 0; i < dayKeys.length; i++) {
        final dk = dayKeys[i];
        final snap = snaps[i];
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final m = (snap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final timeNode = e.value;
          if (timeNode is! Map) continue;

          final teachersAtTime = timeNode.map(
            (k, vv) => MapEntry(k.toString(), vv),
          );

          for (final teacherEntry in teachersAtTime.entries) {
            final teacherId = teacherEntry.key.toString();
            final slotNode = teacherEntry.value;
            if (slotNode is! Map) continue;

            final sm = slotNode.map((k, vv) => MapEntry(k.toString(), vv));

            final learnersRaw = sm['learners'];
            if (learnersRaw is! Map) continue;

            final learners = learnersRaw.map(
              (k, vv) => MapEntry(k.toString(), vv),
            );
            final count = learners.length;
            if (count <= 0) continue;

            final groupSessionNo = _toInt(sm['sessionNo'], fallback: 0);
            final groupSession = groupSessionNo <= 0 ? null : groupSessionNo;

            final key = _slotSummaryKey(dk, hhmm, teacherId);

            summary[key] = _SlotSummary(
              bookedCount: count,
              groupSessionNo: groupSession,
              bookedByMe: learners.containsKey(myUid),
            );

            if (learners.containsKey(myUid)) {
              mine[key] = groupSession ?? currentSession;
            }
          }
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      myBookedSlots = mine;
      slotSummary = summary;
    });
  }

  Future<List<_MyBooking>> _findMyUpcomingBookings(String cid) async {
    final now = DateTime.now();
    final byKey = <String, _MyBooking>{};

    try {
      final dayKeys = <String>[];
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        dayKeys.add(_dateKey(day));
      }

      final snaps = await Future.wait(
        dayKeys.map((dk) => _reservationsRootRef(cid).child(dk).get()),
      );

      for (int i = 0; i < dayKeys.length; i++) {
        final dk = dayKeys[i];
        final snap = snaps[i];
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final m = (snap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );

        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final timeNode = e.value;
          if (timeNode is! Map) continue;

          final start = _parseSlotStart(dk, hhmm);
          if (start == null) continue;
          if (!start.isAfter(now)) continue;

          void considerNode(Map<dynamic, dynamic> nodeLike, String teacherKey) {
            final sm = nodeLike.map((k, vv) => MapEntry(k.toString(), vv));
            final learners = sm['learners'];
            if (learners is! Map) return;

            final lm = learners.map((k, vv) => MapEntry(k.toString(), vv));
            if (!lm.containsKey(myUid)) return;

            final tIdRaw = (sm['teacherId'] ?? teacherKey).toString().trim();
            final tId = tIdRaw.isEmpty ? '__legacy__' : tIdRaw;
            final tName = (sm['teacherName'] ?? 'Teacher').toString().trim();
            final sNo = _toInt(sm['sessionNo'], fallback: 0);

            final candidate = _MyBooking(
              dayKey: dk,
              time: hhmm,
              start: start,
              teacherId: tId,
              teacherName: tName,
              sessionNo: sNo,
            );

            byKey['$dk|$hhmm|$tId'] = candidate;
          }

          final teachersAtTime = timeNode.map((k, vv) => MapEntry(k, vv));
          if (teachersAtTime['learners'] is Map) {
            considerNode(teachersAtTime, '');
            continue;
          }

          for (final teacherEntry in teachersAtTime.entries) {
            final teacherId = teacherEntry.key.toString();
            final node = teacherEntry.value;
            if (node is! Map) continue;
            considerNode(node, teacherId);
          }
        }
      }
    } catch (_) {}

    final out = byKey.values.toList();
    out.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      final byDay = a.dayKey.compareTo(b.dayKey);
      if (byDay != 0) return byDay;
      final byTime = a.time.compareTo(b.time);
      if (byTime != 0) return byTime;
      return a.teacherId.compareTo(b.teacherId);
    });
    return out;
  }

  // ================== Availability -> Upcoming Slots ==================

  Future<void> _generateSlots(String cid) async {
    setState(() => generatedSlots = []);
    final now = DateTime.now();

    try {
      final snap = await _availabilityRootRef().get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        return;
      }

      final root = (snap.value as Map).map(
        (k, vv) => MapEntry(k.toString(), vv),
      );
      final teacherIds = root.keys.toList();
      final teacherMeetUrls = <String, String>{};
      if (teacherIds.isNotEmpty) {
        final urls = await Future.wait(
          teacherIds.map(_loadTeacherProfileMeetUrl),
        );
        for (int i = 0; i < teacherIds.length; i++) {
          teacherMeetUrls[teacherIds[i]] = urls[i];
        }
      }
      final busyByTeacherDay = await _loadTeacherBusyRangesForWindow();
      final List<_TeacherAvail> teachers = [];

      for (final entry in root.entries) {
        final teacherId = entry.key.toString();
        final teacherNode = entry.value;
        if (teacherNode is! Map) continue;

        final tn = teacherNode.map((k, vv) => MapEntry(k.toString(), vv));

        bool teacherOnlineEnabled = true;
        final settingsNode = tn['settings'];
        if (settingsNode is Map) {
          final sm = settingsNode.map((k, vv) => MapEntry(k.toString(), vv));
          teacherOnlineEnabled = _toBool(
            sm['teacherOnlineEnabled'],
            fallback: true,
          );
        }
        if (!teacherOnlineEnabled) continue;

        final perCourse = tn[cid];
        if (perCourse is! Map) continue;

        final effective = perCourse.map((k, vv) => MapEntry(k.toString(), vv));

        final courseOnlineEnabled = _toBool(
          effective['courseOnlineEnabled'],
          fallback: true,
        );
        if (!courseOnlineEnabled) continue;

        final resolvedTeacherName =
            (effective['teacherName'] ??
                    effective['teacher_name'] ??
                    tn['teacherName'] ??
                    tn['teacher_name'] ??
                    '')
                .toString()
                .trim();

        final meetUrl = teacherMeetUrls[teacherId] ?? '';

        int durationMin = _toInt(effective['durationMinutes'], fallback: 0);
        if (durationMin <= 0) {
          durationMin = _toInt(effective['durationMin'], fallback: 0);
        }
        if (durationMin <= 0) durationMin = 60;

        int maxLearners = _toInt(effective['maxLearnersPerSlot'], fallback: 0);
        if (maxLearners <= 0) maxLearners = 6;

        final week = effective['week'];
        if (week is! Map) continue;

        final wm = week.map((k, vv) => MapEntry(k.toString(), vv));

        final Map<String, List<String>> slotsByDay = {};
        for (final dk in ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']) {
          final list = wm[dk];
          final out = <String>[];
          if (list is List) {
            for (final item in list) {
              final s = item.toString().trim();
              if (s.contains(':')) out.add(s);
            }
          }
          slotsByDay[dk] = out;
        }

        teachers.add(
          _TeacherAvail(
            teacherId: teacherId,
            teacherName: resolvedTeacherName.isEmpty
                ? 'Teacher'
                : resolvedTeacherName,
            slotsByDay: slotsByDay,
            meetUrl: meetUrl,
            durationMinutes: durationMin,
            maxLearnersPerSlot: maxLearners,
          ),
        );
      }

      if (teachers.isEmpty) return;

      final List<_Slot> out = [];
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        final wk = _weekdayKey(day);
        final dayKey = _dateKey(day);

        for (final t in teachers) {
          final list = t.slotsByDay[wk] ?? const [];
          for (final hhmm in list) {
            final start = _parseSlotStart(dayKey, hhmm);
            if (start == null) continue;
            if (start.isBefore(now.add(const Duration(minutes: 1)))) continue;
            if (_hasClassConflict(
              busyByTeacherDay,
              t.teacherId,
              start,
              t.durationMinutes,
            )) {
              continue;
            }

            final slotKey = _slotSummaryKey(dayKey, hhmm, t.teacherId);
            final summ = slotSummary[slotKey];

            final bookedCount = summ?.bookedCount ?? 0;
            final groupSessionNo = summ?.groupSessionNo;
            final bookedByMe = summ?.bookedByMe == true;

            out.add(
              _Slot(
                courseId: cid,
                dayKey: dayKey,
                time: hhmm,
                start: start,
                teacherId: t.teacherId,
                teacherName: t.teacherName,
                meetUrl: t.meetUrl,
                durationMinutes: t.durationMinutes,
                maxLearnersPerSlot: t.maxLearnersPerSlot,
                bookedByMe: bookedByMe,
                bookedCount: bookedCount,
                groupSessionNo: groupSessionNo,
              ),
            );
          }
        }
      }

      out.sort((a, b) => a.start.compareTo(b.start));
      if (!mounted) return;

      setState(() {
        generatedSlots = out;
      });
    } catch (e) {
      _toast('Failed to generate slots: $e');
      if (!mounted) return;
      setState(() => generatedSlots = []);
    }
  }

  // ================== Booking ==================

  Future<void> _bookSlot(_Slot slot) async {
    if (booking || refreshing) return;
    final cid = courseId;
    if (cid == null) return;
    _setProgressLabel('Checking slot...');

    if (_isBookingLockedForNewBooking(slot)) {
      _toast('Booking closes 24 hours before class.');
      return;
    }

    final latestBusyByTeacherDay = await _loadTeacherBusyRangesForWindow();
    if (_hasClassConflict(
      latestBusyByTeacherDay,
      slot.teacherId,
      slot.start,
      slot.durationMinutes,
    )) {
      _toast(
        'This teacher has an in-class session at this time. Please pick another slot.',
      );
      await _generateSlots(cid);
      return;
    }

    final targetSession = _targetSessionNo;

    final shouldWarn = await _hasPossibleMissingAttendanceForSession(
      cid: cid,
      sessionNo: targetSession,
    );
    if (!mounted) return;

    if (shouldWarn) {
      final decision = await _askSessionCheckBeforeBooking(targetSession);
      if (!mounted) return;

      if (decision == null) return;

      if (decision == false) {
        final maxSessions = _effectiveTotalSessions;
        final suggested = (targetSession + 1).clamp(1, maxSessions).toInt();

        setState(() {
          studyMode = 'custom';
          lessonsExpanded = true;
          selectedSessionNo = suggested;
        });

        _toast('Choose the session you want, then tap Book again.');
        return;
      }
    }

    if (_effectiveTotalSessions <= 0) {
      _toast('Booking enabled, but total lessons not set.');
      return;
    }

    if (targetSession > _effectiveTotalSessions) {
      _toast('You already finished this course.');
      return;
    }

    if (!_isJoinable(slot)) {
      if (_isBookingLockedForNewBooking(slot)) {
        _toast('Booking closes 24 hours before class.');
        return;
      }
      if (slot.groupSessionNo != null && slot.groupSessionNo != targetSession) {
        _toast('This slot is already a Session ${slot.groupSessionNo} group.');
        return;
      }
      if (slot.isFull) {
        _toast('This slot is full.');
        return;
      }
      _toast('You can’t join this slot.');
      return;
    }

    setState(() => booking = true);
    _markBusyVisualStart();

    try {
      final upcoming = await _findMyUpcomingBookings(cid);
      final existing = upcoming.isEmpty ? null : upcoming.first;
      final isCustomMode = studyMode == 'custom';
      final sameTimeDifferentTeacher = upcoming.any(
        (b) =>
            b.dayKey == slot.dayKey &&
            b.time == slot.time &&
            b.teacherId != slot.teacherId,
      );

      final sameExact = upcoming.any(
        (b) =>
            b.dayKey == slot.dayKey &&
            b.time == slot.time &&
            b.teacherId == slot.teacherId,
      );
      if (sameExact) {
        _toast('You already booked this teacher and slot ✅');
        return;
      }

      _MyBooking? sameSessionUpcoming;
      for (final b in upcoming) {
        if (b.sessionNo == targetSession) {
          sameSessionUpcoming = b;
          break;
        }
      }
      if (sameSessionUpcoming != null) {
        _toast(
          'You already booked Session $targetSession with ${sameSessionUpcoming.teacherName} on ${sameSessionUpcoming.dayKey} at ${sameSessionUpcoming.time}. Please choose another session.',
        );
        return;
      }

      if (isCustomMode) {
        if (sameTimeDifferentTeacher) {
          _toast(
            _bilingual(
              'You already booked this date and time with another teacher.',
              'لقد حجزت هذا التاريخ والوقت بالفعل مع معلم آخر.',
            ),
          );
          return;
        }

        final count = upcoming.length;
        if (count >= 3) {
          _toast(
            _bilingual(
              'You already booked 3 sessions. Please cancel one first.',
              'لقد حجزت 3 جلسات بالفعل. يرجى إلغاء واحدة أولاً.',
            ),
          );
          return;
        }

        if (count == 1 || count == 2) {
          _setProgressLabel('Preparing confirmation...');
          final ok = await _confirmWithLogo(
            title: 'Booking limit | حد الحجز',
            message:
                'You already booked $count ${count == 1 ? 'session' : 'sessions'}.\nYou can book up to 3 sessions.\n\nلقد حجزت $count ${count == 1 ? 'جلسة' : 'جلسات'} بالفعل.\nيمكنك حجز حتى 3 جلسات.\n\nContinue booking this slot?\nمتابعة حجز هذه الحصة؟',
            confirmLabel: 'Continue',
          );
          if (!mounted) return;
          if (ok != true) return;
        }
      }

      if (existing != null &&
          existing.dayKey == slot.dayKey &&
          existing.time == slot.time &&
          existing.teacherId == slot.teacherId) {
        _toast('You already booked this teacher and slot ✅');
        return;
      }

      if (!isCustomMode && existing != null) {
        final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
        final msg = sameTimeDifferentTeacher
            ? 'You already booked this time with another teacher.\nDo you want to change teacher?\n\nCurrent: ${existing.teacherName} — ${_friendlyDate(existing.start)} ${existing.time}\nNew: ${slot.teacherName} — ${_friendlyDate(slot.start)} ${slot.time}\n\nThis will keep the same date and time and only change the teacher.'
            : 'You already booked a class.\nDo you want to change it to this slot?\n\nOld: ${_friendlyDate(existing.start)} ${existing.time}\nNew: ${_friendlyDate(slot.start)} ${slot.time}\n\nThis will join Session ${slot.groupSessionNo ?? targetSession} (${slot.bookedCount}/$cap).';
        _setProgressLabel('Preparing confirmation...');
        final ok = await _confirmWithLogo(
          title: sameTimeDifferentTeacher ? 'Change teacher' : 'Change booking',
          message: msg,
          confirmLabel: sameTimeDifferentTeacher
              ? 'Yes, Change Teacher'
              : 'Yes, Change',
        );
        if (!mounted) return;
        if (ok != true) return;

        final locked = !existing.start.isAfter(
          DateTime.now().add(const Duration(hours: 24)),
        );
        if (locked) {
          _toast(
            'You already booked a class and it’s within 24 hours, so you can’t change it.',
          );
          return;
        }

        _setProgressLabel('Saving booking...');

        final cancelStatus = await _cancelBookingByKey(
          cid,
          existing.dayKey,
          existing.time,
          existing.teacherId,
        );
        if (cancelStatus == _CancelBookingStatus.locked) {
          _toast(
            'You already booked a class and it’s within 24 hours, so you can’t change it.',
          );
          return;
        }
        if (cancelStatus == _CancelBookingStatus.failed) {
          _toast('Could not change booking (cancel failed).');
          return;
        }

        final oldSlotStart = _parseSlotStart(existing.dayKey, existing.time);
        if (oldSlotStart != null) {
          try {
            await NotificationService.I.init();
            await NotificationService.I.cancelSessionReminderSeries(
              classId: '${cid}_${existing.dayKey}_${existing.time}',
              sessionStart: oldSlotStart,
              minutesBeforeList: const [60, 20, 5],
            );
          } catch (_) {}
        }
      }

      final ref = _reservationsRef(cid, slot.dayKey, slot.time, slot.teacherId);
      _setProgressLabel('Saving booking...');

      final pre = await ref.get();
      int? existingGroupSession;
      int existingCount = 0;

      if (pre.exists && pre.value is Map) {
        final m = (pre.value as Map).map((k, v) => MapEntry(k.toString(), v));
        existingGroupSession = _toInt(m['sessionNo'], fallback: 0);
        if (existingGroupSession <= 0) {
          existingGroupSession = null;
        }

        final learnersRaw = m['learners'];
        if (learnersRaw is Map) {
          existingCount = learnersRaw.length;
          final lm = learnersRaw.map((k, v) => MapEntry(k.toString(), v));
          if (lm.containsKey(myUid)) {
            _toast('You already booked this slot ✅');
            return;
          }
        }
      }

      if (existingGroupSession != null &&
          existingGroupSession != targetSession) {
        _toast(
          'This slot is a Session $existingGroupSession group. You selected Session $targetSession.',
        );
        return;
      }

      final maxCap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
      if (existingCount >= maxCap) {
        _toast('This slot is full ($maxCap learners).');
        return;
      }

      final tx = await ref.runTransaction((Object? currentData) {
        final Map<String, dynamic> node = (currentData is Map)
            ? currentData.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final Map<String, dynamic> learners = <String, dynamic>{};
        final existingLearners = node['learners'];
        if (existingLearners is Map) {
          learners.addAll(
            existingLearners.map((k, v) => MapEntry(k.toString(), v)),
          );
        }

        if (learners.containsKey(myUid)) {
          return Transaction.abort();
        }

        final cap = maxCap;
        if (learners.length >= cap) {
          return Transaction.abort();
        }

        final groupSessionNo = _toInt(node['sessionNo'], fallback: 0);
        if (groupSessionNo > 0 && groupSessionNo != targetSession) {
          return Transaction.abort();
        }

        learners[myUid] = true;

        node['teacherId'] = slot.teacherId;
        node['teacherName'] = slot.teacherName;
        node['sessionNo'] = targetSession;
        node['learners'] = learners;
        node['createdAt'] = ServerValue.timestamp;

        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast(
          'Could not join. The slot may be full or became a different session group.',
        );
        return;
      }

      final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
      final newCount = (existingCount + 1);
      if (existingCount == 0) {
        _toast('Booked ✅ Started Session $targetSession group');
      } else {
        _toast('Joined ✅ Session $targetSession group ($newCount/$cap)');
      }

      await _sendBookingNotifications(slot);
      await _scheduleLearnerLocalReminder(slot);

      await AuditLogService.logSuccess(
        actionKey: AuditActionKeys.learnerBookingCreate,
        domain: AuditDomain.booking,
        summary:
            'Learner booked ${slot.teacherName} ${slot.dayKey} ${slot.time}',
        actor: AuditActor(uid: myUid, role: 'learner'),
        target: AuditTarget(
          type: 'teacher',
          uid: slot.teacherId,
          id: _bookingKey(cid, slot.dayKey, slot.time),
          name: slot.teacherName,
        ),
        keywords: [cid, slot.dayKey, slot.time, '$targetSession'],
        context: {
          'courseId': cid,
          'teacherId': slot.teacherId,
          'dayKey': slot.dayKey,
          'time': slot.time,
          'sessionNo': targetSession,
        },
      );

      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
      _invalidateBusyRangesCache();
    } catch (e) {
      await AuditLogService.logFailure(
        actionKey: AuditActionKeys.learnerBookingCreate,
        domain: AuditDomain.booking,
        summary: 'Learner booking failed',
        actor: AuditActor(uid: myUid, role: 'learner'),
        target: AuditTarget(
          type: 'teacher',
          uid: slot.teacherId,
          name: slot.teacherName,
        ),
        keywords: [cid, slot.dayKey, slot.time],
        errorMessage: e.toString(),
      );
      _toast('Booking failed: $e');
    } finally {
      if (mounted) {
        setState(() => booking = false);
        _clearBusyVisualIfIdle();
      }
    }
  }

  Future<_CancelBookingStatus> _cancelBookingByKey(
    String cid,
    String dayKey,
    String hhmm,
    String teacherId,
  ) async {
    try {
      if (_parseSlotStart(dayKey, hhmm) == null) {
        return _CancelBookingStatus.failed;
      }

      Future<_CancelBookingStatus> cancelAtRef(DatabaseReference ref) async {
        const maxAttempts = 2;

        for (int attempt = 0; attempt < maxAttempts; attempt++) {
          try {
            final result = await ref.runTransaction((Object? currentData) {
              if (currentData is! Map) return Transaction.abort();

              final node = currentData.map((k, v) => MapEntry(k.toString(), v));
              final learnersRaw = node['learners'];
              if (learnersRaw is! Map) return Transaction.abort();

              final learners = learnersRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              if (!learners.containsKey(myUid)) return Transaction.abort();

              learners.remove(myUid);

              if (learners.isEmpty) {
                return Transaction.success(null);
              }

              node['learners'] = learners;
              return Transaction.success(node);
            });

            if (result.committed) {
              return _CancelBookingStatus.cancelled;
            }

            final snap = await ref.get();
            if (!snap.exists || snap.value == null) {
              return _CancelBookingStatus.notFound;
            }

            if (snap.value is! Map) {
              if (attempt < maxAttempts - 1) {
                await Future.delayed(const Duration(milliseconds: 250));
                continue;
              }
              return _CancelBookingStatus.failed;
            }

            final node = (snap.value as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            );
            final learnersRaw = node['learners'];

            if (learnersRaw is Map) {
              final learners = learnersRaw.map(
                (k, v) => MapEntry(k.toString(), v),
              );
              if (!learners.containsKey(myUid)) {
                return _CancelBookingStatus.notFound;
              }
            } else {
              final hasNestedLearners = node.values.any((v) {
                if (v is! Map) return false;
                final vm = v.map((k, vv) => MapEntry(k.toString(), vv));
                return vm['learners'] is Map;
              });
              if (hasNestedLearners) {
                return _CancelBookingStatus.notFound;
              }
            }

            if (attempt < maxAttempts - 1) {
              await Future.delayed(const Duration(milliseconds: 250));
              continue;
            }

            return _CancelBookingStatus.failed;
          } catch (_) {
            if (attempt < maxAttempts - 1) {
              await Future.delayed(const Duration(milliseconds: 250));
              continue;
            }
            return _CancelBookingStatus.failed;
          }
        }

        return _CancelBookingStatus.failed;
      }

      final newRef = _reservationsRef(cid, dayKey, hhmm, teacherId);
      final newStatus = await cancelAtRef(newRef);
      if (newStatus == _CancelBookingStatus.cancelled) {
        return _CancelBookingStatus.cancelled;
      }

      final legacyRef = _legacyReservationsRef(cid, dayKey, hhmm);
      final legacyStatus = await cancelAtRef(legacyRef);
      if (legacyStatus == _CancelBookingStatus.cancelled) {
        return _CancelBookingStatus.cancelled;
      }

      if (newStatus == _CancelBookingStatus.notFound ||
          legacyStatus == _CancelBookingStatus.notFound) {
        return _CancelBookingStatus.notFound;
      }

      return _CancelBookingStatus.failed;
    } catch (_) {
      return _CancelBookingStatus.failed;
    }
  }

  Future<void> _refreshSchedule() async {
    final cid = courseId;
    if (cid == null || loading || booking || refreshing) return;

    setState(() => refreshing = true);
    _markBusyVisualStart();
    try {
      _setProgressLabel('Refreshing schedule...');
      _invalidateBusyRangesCache();
      await _loadStudiedSessions(cid);
      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
    } finally {
      if (mounted) {
        setState(() => refreshing = false);
        _clearBusyVisualIfIdle();
      }
    }
  }

  // ================== Help Sheet ==================

  void _openHowBookingWorks() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        final isArabic = helpLang == 'ar';

        return StatefulBuilder(
          builder: (context, setLocalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottomPad),
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: isArabic
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Text(
                          _helpTitle(helpLang),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _langChip('English', 'en', setLocalState),
                            _langChip('العربية', 'ar', setLocalState),
                            _langChip('Français', 'fr', setLocalState),
                            _langChip('Türkçe', 'tr', setLocalState),
                            _langChip('اردو', 'ur', setLocalState),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _helpStep('1', _helpStep1(helpLang)),
                        _helpStep('2', _helpStep2(helpLang)),
                        _helpStep('3', _helpStep3(helpLang)),
                        _helpStep('4', _helpStep4(helpLang)),
                        const SizedBox(height: 18),
                        Text(
                          _helpRulesTitle(helpLang),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _ruleLine(_helpRule1(helpLang)),
                        _ruleLine(_helpRule2(helpLang)),
                        _ruleLine(_helpRule3(helpLang)),
                        _ruleLine(_helpRule4(helpLang)),
                        const SizedBox(height: 18),
                        Text(
                          _helpStatesTitle(helpLang),
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: emptyBg,
                          border: emptyBorder,
                          label: _helpStateBook(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: peerBg,
                          border: peerBorder,
                          label: _helpStateJoin(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: bookedBg,
                          border: bookedBorder,
                          label: _helpStateBooked(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: otherSessionBg,
                          border: otherSessionBorder,
                          label: _helpStateUnavailable(helpLang),
                        ),
                        const SizedBox(height: 8),
                        _stateExplain(
                          bg: lockedBg,
                          border: lockedBorder,
                          label: _helpStateClosed(helpLang),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: actionOrange,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: Text(
                              _helpClose(helpLang),
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _langChip(
    String label,
    String code,
    void Function(void Function()) setLocalState,
  ) {
    final selected = helpLang == code;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() => helpLang = code);
        setLocalState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? actionOrange.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? actionOrange.withValues(alpha: 0.40)
                : uiBorder.withValues(alpha: 0.95),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: selected ? actionOrange : primaryBlue,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _helpStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: actionOrange.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: actionOrange.withValues(alpha: 0.25)),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: actionOrange,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ruleLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '• $text',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: Colors.grey.shade800,
        ),
      ),
    );
  }

  Widget _stateExplain({
    required Color bg,
    required Color border,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _helpTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'كيفية الحجز';
      case 'fr':
        return 'Comment réserver';
      case 'tr':
        return 'Nasıl rezervasyon yapılır';
      case 'ur':
        return 'بکنگ کیسے کریں';
      default:
        return 'How booking works';
    }
  }

  String _helpRulesTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'ملاحظات مهمة';
      case 'fr':
        return 'Règles importantes';
      case 'tr':
        return 'Önemli kurallar';
      case 'ur':
        return 'اہم اصول';
      default:
        return 'Important rules';
    }
  }

  String _helpStatesTitle(String lang) {
    switch (lang) {
      case 'ar':
        return 'معاني الألوان والحالات';
      case 'fr':
        return 'Signification des états';
      case 'tr':
        return 'Durumların anlamı';
      case 'ur':
        return 'اسٹیٹس کا مطلب';
      default:
        return 'What slot labels mean';
    }
  }

  String _helpClose(String lang) {
    switch (lang) {
      case 'ar':
        return 'إغلاق';
      case 'fr':
        return 'Fermer';
      case 'tr':
        return 'Kapat';
      case 'ur':
        return 'بند کریں';
      default:
        return 'Close';
    }
  }

  String _helpStep1(String lang) {
    switch (lang) {
      case 'ar':
        return 'اختر اليوم والوقت المناسبين لك.';
      case 'fr':
        return 'Choisissez le jour et l’heure qui vous conviennent.';
      case 'tr':
        return 'Size uygun gün ve saati seçin.';
      case 'ur':
        return 'اپنے لیے مناسب دن اور وقت منتخب کریں۔';
      default:
        return 'Choose a day and time that works for you.';
    }
  }

  String _helpStep2(String lang) {
    switch (lang) {
      case 'ar':
        return 'اضغط على الحصة لمعرفة التفاصيل.';
      case 'fr':
        return 'Touchez le créneau pour voir les détails.';
      case 'tr':
        return 'Detayları görmek için saate dokunun.';
      case 'ur':
        return 'تفصیلات دیکھنے کے لیے سلاٹ پر ٹیپ کریں۔';
      default:
        return 'Tap a slot to view the details.';
    }
  }

  String _helpStep3(String lang) {
    switch (lang) {
      case 'ar':
        return 'أكد الحجز أو انضم إلى المجموعة إذا كانت من نفس حصتك.';
      case 'fr':
        return 'Confirmez la réservation ou rejoignez le groupe de votre même session.';
      case 'tr':
        return 'Rezervasyonu onaylayın veya aynı oturum grubuna katılın.';
      case 'ur':
        return 'بکنگ کنفرم کریں یا اپنی ہی سیشن گروپ میں شامل ہوں۔';
      default:
        return 'Confirm the booking or join a group from your same session.';
    }
  }

  String _helpStep4(String lang) {
    switch (lang) {
      case 'ar':
        return 'زر الانضمام يظهر قبل وقت الحصة بقليل.';
      case 'fr':
        return 'Le bouton rejoindre apparaît peu avant le cours.';
      case 'tr':
        return 'Katıl düğmesi derse yakın zamanda görünür.';
      case 'ur':
        return 'جوائن بٹن کلاس کے وقت کے قریب ظاہر ہوگا۔';
      default:
        return 'The join button appears near class time.';
    }
  }

  String _helpRule1(String lang) {
    switch (lang) {
      case 'ar':
        return 'يمكنك متابعة الترتيب أو اختيار أي حصة مخصصة من المنهج.';
      case 'fr':
        return 'Vous pouvez suivre la prochaine session ou choisir une session personnalisée.';
      case 'tr':
        return 'Sıradaki oturumu takip edebilir veya istediğiniz oturumu seçebilirsiniz.';
      case 'ur':
        return 'آپ اگلا سیشن فالو کر سکتے ہیں یا اپنی پسند کا سیشن منتخب کر سکتے ہیں۔';
      default:
        return 'You can follow the next session or choose a custom session to study.';
    }
  }

  String _helpRule2(String lang) {
    switch (lang) {
      case 'ar':
        return 'إذا كانت هناك مجموعة من نفس حصتك، يمكنك الانضمام إليها.';
      case 'fr':
        return 'Si un groupe de votre session existe, vous pouvez le rejoindre.';
      case 'tr':
        return 'Aynı oturumda bir grup varsa ona katılabilirsiniz.';
      case 'ur':
        return 'اگر آپ کے سیشن کا گروپ موجود ہے تو آپ اس میں شامل ہو سکتے ہیں۔';
      default:
        return 'If a group from your same session exists, you can join it.';
    }
  }

  String _helpRule3(String lang) {
    switch (lang) {
      case 'ar':
        return 'يمكنك الحجز أو التغيير أو الإلغاء قبل 24 ساعة فقط.';
      case 'fr':
        return 'Vous pouvez réserver, changer ou annuler seulement avant 24 heures.';
      case 'tr':
        return 'Rezervasyon, değişiklik veya iptal sadece 24 saatten önce yapılabilir.';
      case 'ur':
        return 'آپ صرف 24 گھنٹے پہلے بکنگ، تبدیلی یا منسوخی کر سکتے ہیں۔';
      default:
        return 'You can book, change, or cancel only before 24 hours.';
    }
  }

  String _helpRule4(String lang) {
    switch (lang) {
      case 'ar':
        return 'إذا كان المكان ممتلئًا أو لحصة مختلفة أو داخل 24 ساعة، فلن يكون متاحًا.';
      case 'fr':
        return 'Si le créneau est plein, pour une autre session ou dans les 24h, il sera indisponible.';
      case 'tr':
        return 'Saat doluysa, başka oturum içindeyse veya 24 saatten az kaldıysa kullanılamaz.';
      case 'ur':
        return 'اگر سلاٹ بھر گیا ہو، کسی اور سیشن کا ہو، یا 24 گھنٹوں کے اندر ہو تو دستیاب نہیں ہوگا۔';
      default:
        return 'If a slot is full, for another session, or within 24h, it will be unavailable.';
    }
  }

  String _helpStateBook(String lang) {
    switch (lang) {
      case 'ar':
        return 'احجز: الحصة فارغة ويمكنك بدء مجموعة جديدة.';
      case 'fr':
        return 'Réserver : créneau vide, vous pouvez commencer un groupe.';
      case 'tr':
        return 'Rezervasyon: boş saat, yeni grup başlatabilirsiniz.';
      case 'ur':
        return 'بک کریں: خالی سلاٹ، آپ نیا گروپ شروع کر سکتے ہیں۔';
      default:
        return 'Book: empty slot, you can start a new group.';
    }
  }

  String _helpStateJoin(String lang) {
    switch (lang) {
      case 'ar':
        return 'انضم للمجموعة: زملاؤك موجودون بالفعل في هذه الحصة.';
      case 'fr':
        return 'Rejoindre : vos pairs sont déjà dans ce créneau.';
      case 'tr':
        return 'Katıl: arkadaşlarınız bu grupta zaten var.';
      case 'ur':
        return 'گروپ جوائن کریں: آپ کے ساتھی پہلے سے اس گروپ میں ہیں۔';
      default:
        return 'Join group: your peers are already in this slot.';
    }
  }

  String _helpStateBooked(String lang) {
    switch (lang) {
      case 'ar':
        return 'محجوز: أنت بالفعل داخل هذه الحصة.';
      case 'fr':
        return 'Réservé : vous êtes déjà dans ce créneau.';
      case 'tr':
        return 'Rezerve edildi: bu saate zaten dahilsiniz.';
      case 'ur':
        return 'بک ہو چکا: آپ پہلے ہی اس سلاٹ میں شامل ہیں۔';
      default:
        return 'Booked: you are already in this slot.';
    }
  }

  String _helpStateUnavailable(String lang) {
    switch (lang) {
      case 'ar':
        return 'غير متاح: هذه الحصة لمستوى آخر أو ممتلئة.';
      case 'fr':
        return 'Indisponible : autre session ou créneau complet.';
      case 'tr':
        return 'Kullanılamaz: başka oturum ya da dolu.';
      case 'ur':
        return 'دستیاب نہیں: یہ کسی اور سیشن کا ہے یا بھر چکا ہے۔';
      default:
        return 'Unavailable: another session or already full.';
    }
  }

  String _helpStateClosed(String lang) {
    switch (lang) {
      case 'ar':
        return 'مغلق: يبدأ الدرس خلال أقل من 24 ساعة، لذلك لا يمكن الحجز.';
      case 'fr':
        return 'Fermé : le cours commence dans moins de 24h, réservation indisponible.';
      case 'tr':
        return 'Kapalı: ders 24 saatten kısa sürede başlıyor, rezervasyon kapalı.';
      case 'ur':
        return 'بند: کلاس 24 گھنٹوں سے کم میں شروع ہوگی، اس لیے بکنگ بند ہے۔';
      default:
        return 'Closed: class starts in less than 24 hours, booking is closed.';
    }
  }

  // ================== UI ==================

  int get _flowLessonNo => selectedLessonForFlow ?? _targetSessionNo;

  String _flowLessonTitle(int sessionNo) {
    final t = _sessionTitleFor(sessionNo).trim();
    return t.isEmpty ? 'Session $sessionNo' : 'Session $sessionNo - $t';
  }

  List<_Slot> _slotsForCurrentLesson() {
    final selected = _flowLessonNo;
    return generatedSlots.where((s) {
      if (s.groupSessionNo != null && s.groupSessionNo != selected) {
        return false;
      }
      return true;
    }).toList();
  }

  List<DateTime> _availableDaysForLesson() {
    final daysByKey = <String, DateTime>{};
    for (final s in _slotsForCurrentLesson()) {
      daysByKey[s.dayKey] = DateTime(s.start.year, s.start.month, s.start.day);
    }
    final out = daysByKey.values.toList();
    out.sort();
    return out;
  }

  List<String> _availableTimesForDay() {
    if (selectedDay == null) return const [];
    final dk = _dateKey(selectedDay!);
    final set = <String>{};
    for (final s in _slotsForCurrentLesson()) {
      if (s.dayKey != dk) continue;
      set.add(s.time);
    }
    final out = set.toList();
    out.sort();
    return out;
  }

  List<_Slot> _teachersForDayAndTime() {
    if (selectedDay == null || selectedTime == null) return const [];
    final dk = _dateKey(selectedDay!);
    final t = selectedTime!;
    final out = _slotsForCurrentLesson().where((s) {
      return s.dayKey == dk && s.time == t;
    }).toList();
    out.sort((a, b) => a.teacherName.compareTo(b.teacherName));
    return out;
  }

  void _resetScheduleSelections() {
    selectedDay = null;
    selectedTime = null;
    selectedTeacherId = null;
  }

  Widget _buildFlowShell(Widget child) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 920),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFAF7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE9DFD1)),
      ),
      child: child,
    );
  }

  Widget _buildPremiumActionCard({
    required String title,
    required String subtitle,
    required String cta,
    required VoidCallback onTap,
    bool primary = false,
    String? badge,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: primary
              ? const LinearGradient(
                  colors: [Color(0xFF0E7C86), Color(0xFF14616F)],
                )
              : null,
          color: primary ? null : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: primary ? const Color(0xFF14616F) : uiBorder,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primary ? Colors.white : primaryBlue,
                      fontSize: 17,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: primary
                          ? Colors.white.withValues(alpha: 0.16)
                          : actionOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: primary ? Colors.white : actionOrange,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              style: TextStyle(
                color: primary
                    ? Colors.white.withValues(alpha: 0.93)
                    : Colors.grey.shade700,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              cta,
              style: TextStyle(
                color: primary ? Colors.white : actionOrange,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLessonChoiceStep() {
    final nextTitle = _flowLessonTitle(currentSession);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What would you like to study?',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: primaryBlue,
          ),
        ),
        const SizedBox(height: 12),
        _buildPremiumActionCard(
          title: 'Book the next lesson',
          subtitle: '$nextTitle\nContinue with your recommended next session.',
          cta: 'Book next lesson',
          badge: 'Recommended',
          primary: true,
          onTap: () {
            setState(() {
              studyMode = 'follow';
              selectedLessonForFlow = currentSession;
              selectedSessionNo = currentSession;
              _resetScheduleSelections();
              flowStep = _BookingFlowStep.schedule;
            });
          },
        ),
        const SizedBox(height: 12),
        _buildPremiumActionCard(
          title: 'Pick your lesson',
          subtitle: 'Choose a specific lesson from the syllabus.',
          cta: 'Choose from syllabus',
          onTap: () {
            setState(() {
              studyMode = 'custom';
              flowStep = _BookingFlowStep.syllabus;
            });
          },
        ),
      ],
    );
  }

  Widget _buildSyllabusStep() {
    final total = _effectiveTotalSessions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () =>
                  setState(() => flowStep = _BookingFlowStep.lessonChoice),
              icon: const Icon(Icons.arrow_back_rounded, color: primaryBlue),
            ),
            const SizedBox(width: 4),
            const Text(
              'Choose a lesson',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
                fontSize: 21,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '$courseTitle - $studiedSessionsConsumed of $total sessions studied',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 12),
        ...List.generate(total, (i) {
          final no = i + 1;
          final title = _sessionTitleFor(no);
          final status = no < currentSession
              ? 'Studied'
              : (no == currentSession ? 'Next lesson' : 'Available');
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: uiBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Session $no${title.isEmpty ? '' : ' - $title'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Status: $status',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: actionOrange),
                  onPressed: () {
                    setState(() {
                      selectedLessonForFlow = no;
                      selectedSessionNo = no;
                      _resetScheduleSelections();
                      flowStep = _BookingFlowStep.schedule;
                    });
                  },
                  child: const Text('Select'),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Future<void> _onBookAnother() async {
    final cid = courseId;
    if (cid == null) return;
    await _refreshSchedule();
    if (!mounted) return;
    setState(() {
      selectedDay = null;
      selectedTime = null;
      selectedTeacherId = null;
      selectedLessonForFlow = null;
      flowStep = _BookingFlowStep.lessonChoice;
    });
  }

  Widget _buildScheduleStep() {
    final days = _availableDaysForLesson();
    final times = _availableTimesForDay();
    final teachers = _teachersForDayAndTime();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: uiBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                courseTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: primaryBlue,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _flowLessonTitle(_flowLessonNo),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Session $_flowLessonNo of $_effectiveTotalSessions',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () =>
                    setState(() => flowStep = _BookingFlowStep.lessonChoice),
                child: const Text(
                  'Change lesson',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: actionOrange,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Choose a day',
          style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: days.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final d = days[i];
              final on =
                  selectedDay != null && _dateKey(selectedDay!) == _dateKey(d);
              final count = _slotsForCurrentLesson()
                  .where((s) => s.dayKey == _dateKey(d))
                  .length;
              return InkWell(
                onTap: () => setState(() {
                  selectedDay = d;
                  selectedTime = null;
                  selectedTeacherId = null;
                }),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: on ? primaryBlue : Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: on ? primaryBlue : uiBorder),
                  ),
                  child: Center(
                    child: Text(
                      '${_friendlyDate(d)} - $count',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: on ? Colors.white : primaryBlue,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (selectedDay != null) ...[
          const SizedBox(height: 14),
          const Text(
            'Choose a time',
            style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in times)
                ChoiceChip(
                  label: Text(t),
                  selected: selectedTime == t,
                  onSelected: (_) => setState(() {
                    selectedTime = t;
                    selectedTeacherId = null;
                  }),
                ),
            ],
          ),
        ],
        if (selectedTime != null) ...[
          const SizedBox(height: 14),
          const Text(
            'Choose a teacher',
            style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
          ),
          const SizedBox(height: 8),
          ...teachers.map((s) {
            final cap = s.maxLearnersPerSlot <= 0 ? 6 : s.maxLearnersPerSlot;
            final left = (cap - s.bookedCount) < 0 ? 0 : (cap - s.bookedCount);
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: uiBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.teacherName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$left seats available',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: actionOrange,
                    ),
                    onPressed: () => setState(() {
                      selectedTeacherId = s.teacherId;
                      flowStep = _BookingFlowStep.confirm;
                    }),
                    child: const Text('Book'),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _buildConfirmStep() {
    final teachers = _teachersForDayAndTime();
    final chosen = teachers
        .where((e) => e.teacherId == selectedTeacherId)
        .toList();
    final slot = chosen.isEmpty ? null : chosen.first;
    if (slot == null || selectedDay == null || selectedTime == null) {
      return const Text('Selection expired. Please choose again.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Confirm your booking',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: primaryBlue,
            fontSize: 22,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: uiBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Course: $courseTitle'),
              Text('Lesson: ${_flowLessonTitle(_flowLessonNo)}'),
              Text('Day: ${_friendlyDate(selectedDay!)}'),
              Text('Time: $selectedTime'),
              Text('Teacher: ${slot.teacherName}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              onPressed: () =>
                  setState(() => flowStep = _BookingFlowStep.schedule),
              child: const Text('Back'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: primaryBlue),
              onPressed: () async {
                await _bookSlot(slot);
                if (!mounted) return;
                if (myBookedSlots.containsKey(slot.key)) {
                  setState(() => flowStep = _BookingFlowStep.success);
                }
              },
              child: const Text('Confirm booking'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccessStep() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your class has been booked.',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 22,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: actionOrange),
                onPressed: _onBookAnother,
                child: const Text('Book another class'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFlowContent() {
    switch (flowStep) {
      case _BookingFlowStep.lessonChoice:
        return _buildLessonChoiceStep();
      case _BookingFlowStep.syllabus:
        return _buildSyllabusStep();
      case _BookingFlowStep.schedule:
        return _buildScheduleStep();
      case _BookingFlowStep.confirm:
        return _buildConfirmStep();
      case _BookingFlowStep.success:
        return _buildSuccessStep();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cid = courseId;
    final busy = loading || booking || refreshing || progressLabel.isNotEmpty;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Book Your Class',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'How booking works',
            onPressed: _openHowBookingWorks,
            icon: const Icon(Icons.help_outline_rounded, color: primaryBlue),
          ),
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            onPressed: (loading || booking || refreshing || cid == null)
                ? null
                : () async {
                    await _runBusy('Refreshing schedule...', () async {
                      await _refreshSchedule();
                    });
                  },
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1500,
        child: Stack(
          children: [
            IgnorePointer(
              ignoring: busy,
              child: loading
                  ? const Center(
                      child: BrandedInlineLoader(
                        message: 'Loading booking schedule...',
                      ),
                    )
                  : (cid == null)
                  ? const Center(child: Text('No course selected.'))
                  : Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(bottom: 98),
                        child: _buildFlowShell(_buildFlowContent()),
                      ),
                    ),
            ),
            if (busy)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.16),
                  child: Center(
                    child: Container(
                      width: 220,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: uiBorder),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const YbsBusyLogo(size: 44),
                          const SizedBox(height: 10),
                          const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: primaryBlue,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            progressLabel.isEmpty
                                ? 'Please wait...'
                                : progressLabel,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: primaryBlue,
                            ),
                          ),
                          const SizedBox(height: 8),
                          StreamBuilder<int>(
                            stream: Stream.periodic(
                              const Duration(seconds: 1),
                              (x) => x,
                            ),
                            initialData: 0,
                            builder: (context, _) {
                              final since = _busyVisualSince;
                              if (since == null) {
                                return const SizedBox.shrink();
                              }
                              final elapsed = DateTime.now().difference(since);
                              if (elapsed <
                                  const Duration(milliseconds: 2500)) {
                                return const SizedBox.shrink();
                              }
                              final sec = elapsed.inSeconds;
                              return Text(
                                'Still working... ${sec}s',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey.shade700,
                                  fontSize: 12,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _sessionTitleFor(int sessionNo) {
    final info = curriculumSessions['$sessionNo'];
    if (info is Map) {
      final m = info.map((k, v) => MapEntry(k.toString(), v));
      final t = (m['sessionTitle'] ?? m['title'] ?? '').toString().trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  String _friendlyDate(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final wd = days[d.weekday - 1];
    final mo = months[d.month - 1];
    return '$wd, ${_two(d.day)} $mo';
  }
}

// ================== Models ==================

enum _CancelBookingStatus { cancelled, notFound, locked, failed }

enum _BookingFlowStep { lessonChoice, syllabus, schedule, confirm, success }

class _CourseChoice {
  final String id;
  final String title;

  const _CourseChoice({required this.id, required this.title});
}

class _BookingGate {
  final bool enabled;
  final int totalSessions;
  final String title;
  final String source;

  const _BookingGate({
    required this.enabled,
    required this.totalSessions,
    required this.title,
    required this.source,
  });
}

class _TeacherAvail {
  final String teacherId;
  final String teacherName;
  final Map<String, List<String>> slotsByDay;
  final String meetUrl;
  final int durationMinutes;
  final int maxLearnersPerSlot;

  _TeacherAvail({
    required this.teacherId,
    required this.teacherName,
    required this.slotsByDay,
    required this.meetUrl,
    required this.durationMinutes,
    required this.maxLearnersPerSlot,
  });
}

class _SlotSummary {
  final int bookedCount;
  final int? groupSessionNo;
  final bool bookedByMe;

  _SlotSummary({
    required this.bookedCount,
    required this.groupSessionNo,
    required this.bookedByMe,
  });
}

class _Slot {
  final String courseId;
  final String dayKey;
  final String time;
  final DateTime start;
  final String teacherId;
  final String teacherName;
  final String meetUrl;
  final int durationMinutes;
  final int maxLearnersPerSlot;
  final bool bookedByMe;
  final int bookedCount;
  final int? groupSessionNo;

  _Slot({
    required this.courseId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
    required this.meetUrl,
    required this.durationMinutes,
    required this.maxLearnersPerSlot,
    this.bookedByMe = false,
    this.bookedCount = 0,
    this.groupSessionNo,
  });

  String get key => '$dayKey|$time|$teacherId';

  bool get isFull {
    final cap = maxLearnersPerSlot <= 0 ? 6 : maxLearnersPerSlot;
    return bookedCount >= cap;
  }
}

class _BusyRange {
  final DateTime start;
  final DateTime end;

  const _BusyRange({required this.start, required this.end});
}

class _MyBooking {
  final String dayKey;
  final String time;
  final DateTime start;
  final String teacherId;
  final String teacherName;
  final int sessionNo;

  _MyBooking({
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
    required this.sessionNo,
  });
}
