import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../shared/human_error.dart';
import '../services/push_dispatch_service.dart';
import '../services/learner_join_signal_service.dart';
import '../services/notification_service.dart';
import '../services/audit_action_keys.dart';
import '../services/audit_log_service.dart';
import '../widgets/teacher_media_sheet.dart';
import '../shared/app_feedback.dart';
import '../shared/ybs_busy_logo.dart';
import '../shared/learner_web_layout.dart';
import '../shared/responsive_layout.dart';
import '../shared/course_join_rules.dart';
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
  static const int timetableDays = 7;
  List<_Slot> generatedSlots = [];

  // My bookings map: "yyyy-mm-dd|HH:MM|teacherId" -> sessionNo
  Map<String, int> myBookedSlots = {};

  // Slot group summary: "yyyy-mm-dd|HH:MM|teacherId" -> summary
  Map<String, _SlotSummary> slotSummary = {};

  // Filters
  String teacherFilter = 'all';
  String timeFilter = 'all'; // all | morning | afternoon
  bool onlyJoinable = false;
  bool onlyPeerGroups = false;

  // UI state
  bool filtersExpanded = false;
  String helpLang = 'en'; // en | ar | fr | tr | ur
  Timer? _modeLabelsTimer;
  int _modeLabelIndex = 0;
  bool _didShowFollowModeHint = false;
  bool _didShowCustomModeHint = false;
  late final AnimationController _sessionPulseCtrl;

  @override
  void initState() {
    super.initState();
    _sessionPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 980),
    )..repeat(reverse: true);
    _modeLabelsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() {
        _modeLabelIndex = (_modeLabelIndex + 1) % 3;
      });
    });
    _init();
  }

  @override
  void dispose() {
    _modeLabelsTimer?.cancel();
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

  int get _sessionsLeft {
    final left = _effectiveTotalSessions - studiedSessionsConsumed;
    return left < 0 ? 0 : left;
  }

  String _verticalTimeLabel(String time) {
    final cleaned = time.trim();
    if (cleaned.contains(':')) {
      final parts = cleaned.split(':');
      final hh = parts.isNotEmpty ? parts.first.trim() : cleaned;
      final mm = parts.length > 1 ? parts[1].trim() : '00';
      final hhNorm = hh.padLeft(2, '0');
      final mmNorm = mm.isEmpty ? '00' : mm.padLeft(2, '0');
      return '$hhNorm:$mmNorm';
    }
    final n = int.tryParse(cleaned);
    if (n != null) return '${n.toString().padLeft(2, '0')}:00';
    return cleaned;
  }

  String _shortTeacherName(String fullName) {
    final parts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'Teacher';
    if (parts.length == 1) return parts.first;
    final first = parts.first;
    final lastInitial = parts.last[0].toUpperCase();
    return '$first $lastInitial';
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

    return out;
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

  Future<void> _openExternalUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) {
      _toast('Missing meeting link.');
      return;
    }

    final uri = Uri.tryParse(u);
    if (uri == null) {
      _toast('Invalid meeting link.');
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _toast('Could not open the link.');
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

  Future<void> _notifyTeacherJoinTap(_Slot slot) async {
    try {
      final learnerUid = myUid.trim();
      if (learnerUid.isEmpty) return;

      final learnerName = await _getMyFullName();
      await LearnerJoinSignalService.notifyTeacherJoinTap(
        learnerUid: learnerUid,
        teacherUid: slot.teacherId,
        learnerName: learnerName,
        source: 'learner/learner_booking',
        courseId: slot.courseId,
        courseTitle: courseTitle.trim(),
        dayKey: slot.dayKey,
        time: slot.time,
        sessionStartMs: slot.start.millisecondsSinceEpoch,
      );
    } catch (_) {}
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

  bool _isPeerGroup(_Slot s) {
    final targetSession = _targetSessionNo;
    return !_isBookingLockedForNewBooking(s) &&
        (s.groupSessionNo == targetSession) &&
        (s.bookedCount > 0) &&
        !s.bookedByMe &&
        !s.isFull;
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

  Future<void> _cancelLearnerLocalReminder(_Slot slot) async {
    try {
      await NotificationService.I.init();

      await NotificationService.I.cancelSessionReminderSeries(
        classId: '${slot.courseId}_${slot.dayKey}_${slot.time}',
        sessionStart: slot.start,
        minutesBeforeList: const [60, 20, 5],
      );
    } catch (_) {}
  }

  Future<void> _runBusy(String label, Future<void> Function() action) async {
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
      }
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

    courseId = widget.courseId ?? await _inferLearnerCourseId();
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

  Future<String?> _inferLearnerCourseId() async {
    try {
      final snap = await _db.child('users/$myUid/courses').get();
      final v = snap.value;
      if (v is! Map) return null;

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
          return id;
        }
      }
    } catch (_) {}

    return null;
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

            int no = _toInt(sess['sessionNumber'], fallback: 0);
            if (no <= 0) no = fallbackNo;

            out['$no'] = {
              'sessionNo': no,
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
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        final dk = _dateKey(day);

        final snap = await _reservationsRootRef(cid).child(dk).get();
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
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        final dk = _dateKey(day);

        final snap = await _reservationsRootRef(cid).child(dk).get();
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

        final meetUrl = await _loadTeacherProfileMeetUrl(teacherId);

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

        final teachersInList = <String>{};
        for (final s in generatedSlots) {
          teachersInList.add(s.teacherId);
        }
        if (teacherFilter != 'all' && !teachersInList.contains(teacherFilter)) {
          teacherFilter = 'all';
        }
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

    try {
      final upcoming = await _findMyUpcomingBookings(cid);
      final existing = upcoming.isEmpty ? null : upcoming.first;
      final isCustomMode = studyMode == 'custom';

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

      if (isCustomMode) {
        final sameTimeDifferentTeacher = upcoming.any(
          (b) =>
              b.dayKey == slot.dayKey &&
              b.time == slot.time &&
              b.teacherId != slot.teacherId,
        );
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
        final locked = !existing.start.isAfter(
          DateTime.now().add(const Duration(hours: 24)),
        );
        if (locked) {
          _toast(
            'You already booked a class and it’s within 24 hours, so you can’t change it.',
          );
          return;
        }

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

  Future<void> _markLateCancelCreditUsed({
    required String cid,
    required _Slot slot,
  }) async {
    final bookingKey = _bookingKey(cid, slot.dayKey, slot.time);
    final slotKey = _slotSummaryKey(slot.dayKey, slot.time, slot.teacherId);
    final sessionNo =
        slot.groupSessionNo ?? myBookedSlots[slotKey] ?? _targetSessionNo;

    final ref = _progressRef(cid).child('online_attendance/$bookingKey');

    try {
      await ref.runTransaction((Object? currentData) {
        final node = (currentData is Map)
            ? currentData.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final alreadyPresent = node['present'] == true;
        final alreadyCounted = node['countedCredit'] == true;
        if (alreadyPresent || alreadyCounted) {
          return Transaction.success(node);
        }

        final createdAt = node['createdAt'];

        node['bookingKey'] = bookingKey;
        node['courseId'] = cid;
        node['dayKey'] = slot.dayKey;
        node['time'] = slot.time;
        node['sessionNo'] = sessionNo;
        node['teacherId'] = slot.teacherId;
        node['teacherName'] = slot.teacherName;
        node['present'] = false;
        node['countedCredit'] = true;
        node['creditCountReason'] = 'late_cancel_24h';
        node['updatedAt'] = ServerValue.timestamp;
        node['createdAt'] = createdAt ?? ServerValue.timestamp;

        return Transaction.success(node);
      });

      await AuditLogService.logSuccess(
        actionKey: AuditActionKeys.learnerBookingLateCancelCredit,
        domain: AuditDomain.booking,
        summary: 'Learner late-cancel credit counted',
        actor: AuditActor(uid: myUid, role: 'learner'),
        target: AuditTarget(
          type: 'booking',
          id: bookingKey,
          uid: slot.teacherId,
          name: slot.teacherName,
        ),
        keywords: [cid, slot.dayKey, slot.time, '$sessionNo'],
      );
    } catch (_) {}
  }

  Future<void> _cancelMyBooking(_Slot slot) async {
    final cid = courseId;
    if (cid == null) return;

    final lateCancel = _isWithin24Hours(slot);

    setState(() => booking = true);

    try {
      final status = await _cancelBookingByKey(
        cid,
        slot.dayKey,
        slot.time,
        slot.teacherId,
      );
      if (status == _CancelBookingStatus.failed) {
        _toast('Cancel failed. Please try again.');
        return;
      }

      await _cancelLearnerLocalReminder(slot);

      if (status == _CancelBookingStatus.cancelled && lateCancel) {
        await _markLateCancelCreditUsed(cid: cid, slot: slot);
      }

      if (status == _CancelBookingStatus.notFound) {
        _toast('This booking was already canceled. ✅');
      } else {
        _toast(
          lateCancel
              ? 'Booking canceled and counted as used credit ✅'
              : 'Booking canceled ✅',
        );
      }

      if (status == _CancelBookingStatus.cancelled ||
          status == _CancelBookingStatus.notFound) {
        await AuditLogService.logSuccess(
          actionKey: AuditActionKeys.learnerBookingCancel,
          domain: AuditDomain.booking,
          summary: 'Learner cancelled booking ${slot.dayKey} ${slot.time}',
          actor: AuditActor(uid: myUid, role: 'learner'),
          target: AuditTarget(
            type: 'teacher',
            uid: slot.teacherId,
            name: slot.teacherName,
          ),
          keywords: [cid, slot.dayKey, slot.time],
          meta: {'lateCancel': lateCancel, 'status': status.name},
        );
      }

      await _loadStudiedSessions(cid);
      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
    } catch (e) {
      await AuditLogService.logFailure(
        actionKey: AuditActionKeys.learnerBookingCancel,
        domain: AuditDomain.booking,
        summary: 'Learner booking cancel failed',
        actor: AuditActor(uid: myUid, role: 'learner'),
        target: AuditTarget(
          type: 'teacher',
          uid: slot.teacherId,
          name: slot.teacherName,
        ),
        keywords: [cid, slot.dayKey, slot.time],
        errorMessage: e.toString(),
      );
      _toast('Cancel failed: $e');
    } finally {
      if (mounted) {
        setState(() => booking = false);
      }
    }
  }

  Future<void> _refreshSchedule() async {
    final cid = courseId;
    if (cid == null || loading || booking || refreshing) return;

    setState(() => refreshing = true);
    try {
      await _loadStudiedSessions(cid);
      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
    } finally {
      if (mounted) {
        setState(() => refreshing = false);
      }
    }
  }

  // ================== Timetable UI helpers ==================

  List<_Slot> _applyFilters(List<_Slot> slots) {
    final out = <_Slot>[];

    for (final s in slots) {
      if (teacherFilter != 'all' && s.teacherId != teacherFilter) continue;

      if (timeFilter == 'morning') {
        if (s.start.hour >= 13) continue;
      } else if (timeFilter == 'afternoon') {
        if (s.start.hour < 13) continue;
      }

      if (onlyJoinable && !_isJoinable(s)) continue;
      if (onlyPeerGroups && !_isPeerGroup(s)) continue;

      out.add(s);
    }

    return out;
  }

  List<String> _uniqueTimes(List<_Slot> slots) {
    final set = <String>{};
    for (final s in slots) {
      set.add(s.time);
    }

    final list = set.toList();
    list.sort((a, b) {
      final ap = a.split(':');
      final bp = b.split(':');
      final ah = int.tryParse(ap[0]) ?? 0;
      final am = int.tryParse(ap[1]) ?? 0;
      final bh = int.tryParse(bp[0]) ?? 0;
      final bm = int.tryParse(bp[1]) ?? 0;
      return (ah * 60 + am).compareTo(bh * 60 + bm);
    });
    return list;
  }

  List<DateTime> _nextDays(int count) {
    final now = DateTime.now();
    return List.generate(
      count,
      (i) => DateTime(now.year, now.month, now.day).add(Duration(days: i)),
    );
  }

  // ================== Session details ==================

  Future<void> _openSessionDetails(int sessionNo) async {
    final info = curriculumSessions['$sessionNo'];
    if (info is! Map) {
      _toast('Session details not found (curriculum is optional).');
      return;
    }

    final m = info.map((k, v) => MapEntry(k.toString(), v));

    final rawTitle = (m['sessionTitle'] ?? m['title'] ?? '').toString().trim();
    final title = rawTitle.isEmpty
        ? 'Session $sessionNo'
        : 'Session $sessionNo — $rawTitle';
    final objective = (m['objective'] ?? '').toString().trim();
    final content = (m['content'] ?? '').toString().trim();
    final homework = (m['homework'] ?? '').toString().trim();
    final duration = _toInt(m['durationMinutes'], fallback: 0);

    final cid = courseId;
    if (cid == null || cid.trim().isEmpty) {
      _toast('Course info is missing. Please reopen this screen.');
      return;
    }

    String teacherName = '';
    bool attendedSession = false;
    int rating = 5;
    int existingCreatedAt = 0;

    try {
      final attendanceSnap = await _progressRef(
        cid,
      ).child('online_attendance').get();
      if (attendanceSnap.exists && attendanceSnap.value is Map) {
        final attendanceMap = _asStringKeyMap(attendanceSnap.value);
        for (final entry in attendanceMap.entries) {
          final raw = entry.value;
          if (raw is! Map) continue;
          final rec = _asStringKeyMap(raw);
          final recSessionNo = _toInt(rec['sessionNo'], fallback: 0);
          if (recSessionNo != sessionNo) continue;

          final recTeacherName =
              (rec['teacherName'] ?? rec['teacherNameFromBooking'] ?? '')
                  .toString()
                  .trim();
          if (teacherName.isEmpty && recTeacherName.isNotEmpty) {
            teacherName = recTeacherName;
          }

          final present = _toBool(rec['present']);
          if (present) {
            attendedSession = true;
            if (recTeacherName.isNotEmpty) teacherName = recTeacherName;
          }
        }
      }

      final reviewSnap = await _progressRef(
        cid,
      ).child('session_reviews/$sessionNo').get();
      if (reviewSnap.exists && reviewSnap.value is Map) {
        final review = _asStringKeyMap(reviewSnap.value);
        final savedRating = _toInt(review['rating'], fallback: 0);
        if (savedRating >= 1 && savedRating <= 5) rating = savedRating;
        existingCreatedAt = _toInt(review['createdAt'], fallback: 0);

        final savedTeacher = (review['teacherName'] ?? '').toString().trim();
        if (teacherName.isEmpty && savedTeacher.isNotEmpty) {
          teacherName = savedTeacher;
        }
      }
    } catch (_) {}

    if (!mounted) return;

    bool submitting = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setModalState) {
              Future<void> submitSessionReview() async {
                if (!attendedSession) {
                  AppToast.show(
                    context,
                    'You can review this session after attending it.',
                    type: AppToastType.error,
                  );
                  return;
                }

                if (rating < 1 || rating > 5) {
                  AppToast.show(
                    context,
                    'Please choose a rating from 1 to 5 stars.',
                    type: AppToastType.error,
                  );
                  return;
                }

                setModalState(() => submitting = true);
                try {
                  final payload = <String, dynamic>{
                    'sessionNo': sessionNo,
                    'rating': rating,
                    'teacherName': teacherName,
                    'updatedAt': ServerValue.timestamp,
                  };
                  if (existingCreatedAt > 0) {
                    payload['createdAt'] = existingCreatedAt;
                  } else {
                    payload['createdAt'] = ServerValue.timestamp;
                  }

                  await _progressRef(
                    cid,
                  ).child('session_reviews/$sessionNo').set(payload);

                  await AuditLogService.logSuccess(
                    actionKey: AuditActionKeys.learnerSessionReviewSubmit,
                    domain: AuditDomain.booking,
                    summary:
                        'Learner submitted session review for session $sessionNo',
                    actor: AuditActor(uid: myUid, role: 'learner'),
                    target: AuditTarget(
                      type: 'course',
                      id: cid,
                      name: teacherName,
                    ),
                    keywords: [cid, '$sessionNo', '$rating', teacherName],
                    context: {'courseId': cid, 'sessionNo': sessionNo},
                  );
                  existingCreatedAt = existingCreatedAt > 0
                      ? existingCreatedAt
                      : DateTime.now().millisecondsSinceEpoch;

                  if (!mounted) return;
                  AppToast.show(context, 'Session review submitted.');
                } catch (e) {
                  await AuditLogService.logFailure(
                    actionKey: AuditActionKeys.learnerSessionReviewSubmit,
                    domain: AuditDomain.booking,
                    summary: 'Learner session review submit failed',
                    actor: AuditActor(uid: myUid, role: 'learner'),
                    target: AuditTarget(type: 'course', id: cid),
                    keywords: [cid, '$sessionNo'],
                    errorMessage: e.toString(),
                  );
                  if (!mounted) return;
                  AppToast.show(
                    context,
                    toHumanError(e),
                    type: AppToastType.error,
                  );
                } finally {
                  if (mounted) {
                    setModalState(() => submitting = false);
                  }
                }
              }

              return Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _kv('Session', '$sessionNo / $_effectiveTotalSessions'),
                      if (duration > 0) _kv('Duration', '$duration min'),
                      _kv('Teacher', teacherName.isEmpty ? '-' : teacherName),
                      const SizedBox(height: 10),
                      if (objective.isNotEmpty) ...[
                        const Text(
                          'Objectives',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          objective,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (content.isNotEmpty) ...[
                        const Text(
                          'Content',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          content,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (homework.isNotEmpty) ...[
                        const Text(
                          'Homework',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          homework,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFB),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: uiBorder.withValues(alpha: 0.9),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Rate this session',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 2,
                              children: List.generate(5, (i) {
                                final star = i + 1;
                                return IconButton(
                                  tooltip: '$star star${star == 1 ? '' : 's'}',
                                  onPressed: attendedSession
                                      ? () => setModalState(() => rating = star)
                                      : null,
                                  icon: Icon(
                                    star <= rating
                                        ? Icons.star_rounded
                                        : Icons.star_border_rounded,
                                    color: const Color(0xFFF59E0B),
                                  ),
                                );
                              }),
                            ),
                            if (!attendedSession)
                              Text(
                                'You can review this session after attending it.',
                                style: TextStyle(
                                  color: Colors.grey.shade700,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: actionOrange,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: (!attendedSession || submitting)
                                    ? null
                                    : submitSessionReview,
                                child: Text(
                                  submitting
                                      ? 'Submitting...'
                                      : 'Submit review',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: actionOrange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            'Close',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              k,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.grey.shade700,
              ),
            ),
          ),
          Text(
            v,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
            ),
          ),
        ],
      ),
    );
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

  // ================== Slot tap -> details sheet ==================

  Future<void> _onSlotTap(_Slot slot) async {
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        final targetSession = _targetSessionNo;

        final canCancel = slot.bookedByMe && slot.start.isAfter(DateTime.now());
        final lateCancel = canCancel && _isWithin24Hours(slot);

        final newBookingLocked = _isBookingLockedForNewBooking(slot);

        final shownSessionNo = slot.groupSessionNo ?? targetSession;
        final topic = _sessionTitleFor(shownSessionNo);

        final joinable = _isJoinable(slot);
        final peerGroup = _isPeerGroup(slot);
        final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;

        String groupLine() {
          if (slot.bookedCount <= 0) {
            return 'No one booked yet';
          }
          final gs = slot.groupSessionNo;
          if (gs == null) {
            return '${slot.bookedCount} learners booked';
          }
          return '${slot.bookedCount} learners booked • Session $gs group';
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + bottomPad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_friendlyDate(slot.start)} • ${slot.time}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                    color: primaryBlue,
                  ),
                ),
                const SizedBox(height: 14),
                _sheetInfoRow(
                  icon: Icons.person_outline_rounded,
                  title: 'Teacher',
                  value: slot.teacherName,
                  trailing: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      Navigator.pop(context);
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        backgroundColor: Colors.white,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                        ),
                        builder: (_) => TeacherMediaSheet(
                          teacherUid: slot.teacherId,
                          teacherName: slot.teacherName,
                        ),
                      );
                    },
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: actionOrange.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: actionOrange.withValues(alpha: 0.25),
                        ),
                      ),
                      child: const Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: actionOrange,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _sheetInfoRow(
                  icon: Icons.menu_book_rounded,
                  title: 'Session',
                  value: topic.isEmpty
                      ? '$shownSessionNo / $_effectiveTotalSessions'
                      : '$shownSessionNo / $_effectiveTotalSessions • $topic',
                ),
                const SizedBox(height: 10),
                _sheetInfoRow(
                  icon: Icons.groups_rounded,
                  title: 'Group',
                  value: '${groupLine()} • Capacity ${slot.bookedCount}/$cap',
                ),
                const SizedBox(height: 14),
                if (newBookingLocked && !slot.bookedByMe) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: lockedBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: lockedBorder),
                    ),
                    child: const Text(
                      'Booking closed for this slot. Classes must be booked at least 24 hours in advance.',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: primaryBlue,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (peerGroup)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: peerBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: peerBorder),
                    ),
                    child: const Text(
                      '👥 Your peers are already here — you can join this group.',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: primaryBlue,
                      ),
                    ),
                  ),
                if (peerGroup) const SizedBox(height: 12),
                if (slot.bookedByMe && slot.meetUrl.trim().isNotEmpty) ...[
                  StreamBuilder<int>(
                    stream: Stream.periodic(
                      const Duration(seconds: 1),
                      (x) => x,
                    ),
                    initialData: 0,
                    builder: (context, _) {
                      final now = DateTime.now();
                      final openFrom = slot.start.subtract(
                        const Duration(minutes: 10),
                      );
                      final dur = slot.durationMinutes <= 0
                          ? 60
                          : slot.durationMinutes;
                      final openUntil = slot.start
                          .add(Duration(minutes: dur))
                          .add(const Duration(minutes: 15));

                      final dynamicCanJoin =
                          now.isAfter(openFrom) && now.isBefore(openUntil);
                      final joinLabel = joinButtonLabelForWindow(
                        openFrom: openFrom,
                        openUntil: openUntil,
                        hasMeetLink: true,
                        now: now,
                        actionLabel: 'Join Google Meet',
                        closedLabel: 'Join window closed',
                      );

                      return FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: actionOrange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          minimumSize: const Size(double.infinity, 48),
                        ),
                        onPressed: dynamicCanJoin
                            ? () {
                                Navigator.pop(context);
                                unawaited(_notifyTeacherJoinTap(slot));
                                _openExternalUrl(slot.meetUrl);
                              }
                            : null,
                        child: Text(
                          joinLabel,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                if (!slot.bookedByMe) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: joinable
                          ? actionOrange
                          : Colors.grey.shade400,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: (booking || refreshing || !joinable)
                        ? null
                        : () async {
                            Navigator.pop(context);

                            final upcoming = await _findMyUpcomingBookings(
                              courseId!,
                            );
                            final existing = upcoming.isEmpty
                                ? null
                                : upcoming.first;
                            final isCustomMode = studyMode == 'custom';

                            final isSameExactBooking = upcoming.any(
                              (b) =>
                                  b.dayKey == slot.dayKey &&
                                  b.time == slot.time &&
                                  b.teacherId == slot.teacherId,
                            );

                            final isSameTimeDifferentTeacher = upcoming.any(
                              (b) =>
                                  b.dayKey == slot.dayKey &&
                                  b.time == slot.time &&
                                  b.teacherId != slot.teacherId,
                            );

                            if (isCustomMode) {
                              if (isSameExactBooking) {
                                _toast('You already booked this slot ✅');
                                return;
                              }

                              if (isSameTimeDifferentTeacher) {
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
                                    'You already booked 3 sessions. Please cancel one to book another.',
                                    'لقد حجزت 3 جلسات بالفعل. يرجى إلغاء واحدة لحجز جلسة أخرى.',
                                  ),
                                );
                                return;
                              }

                              final prefix = count == 1
                                  ? 'You already booked 1 session. You can book up to 3 sessions.\nلقد حجزت جلسة واحدة بالفعل. يمكنك حجز حتى 3 جلسات.\n\n'
                                  : (count == 2
                                        ? 'You already booked 2 sessions. You can book up to 3 sessions.\nلقد حجزت جلستين بالفعل. يمكنك حجز حتى 3 جلسات.\n\n'
                                        : '');

                              final msg =
                                  '${prefix}Confirm booking?\n\n${_friendlyDate(slot.start)} at ${slot.time}\nTeacher: ${slot.teacherName}\n\nGroup: Session ${slot.groupSessionNo ?? targetSession}\nLearners: ${slot.bookedCount}/$cap';

                              final ok = await _confirmWithLogo(
                                title: 'Book this slot',
                                message: msg,
                                confirmLabel: 'Yes',
                              );

                              if (ok == true) {
                                await _runBusy('Saving booking...', () async {
                                  await _bookSlot(slot);
                                });
                              }
                              return;
                            }

                            final hasOther =
                                existing != null && !isSameExactBooking;

                            final locked =
                                existing != null &&
                                !existing.start.isAfter(
                                  DateTime.now().add(const Duration(hours: 24)),
                                );

                            final label = isSameTimeDifferentTeacher
                                ? 'Change teacher'
                                : ((slot.bookedCount > 0 &&
                                          slot.groupSessionNo == targetSession)
                                      ? 'Join group'
                                      : 'Book this slot');

                            final msg = hasOther
                                ? (locked
                                      ? 'You already booked a class within 24 hours.\nYou can’t change it now.'
                                      : isSameTimeDifferentTeacher
                                      ? 'You already booked this time with another teacher.\nDo you want to change teacher?\n\nCurrent: ${existing.teacherName} — ${_friendlyDate(existing.start)} ${existing.time}\nNew: ${slot.teacherName} — ${_friendlyDate(slot.start)} ${slot.time}\n\nThis will keep the same date and time and only change the teacher.'
                                      : 'You already booked a class.\nDo you want to change it to this slot?\n\nOld: ${_friendlyDate(existing.start)} ${existing.time}\nNew: ${_friendlyDate(slot.start)} ${slot.time}\n\nThis will join Session ${slot.groupSessionNo ?? targetSession} (${slot.bookedCount}/$cap).')
                                : 'Confirm booking?\n\n${_friendlyDate(slot.start)} at ${slot.time}\nTeacher: ${slot.teacherName}\n\nGroup: Session ${slot.groupSessionNo ?? targetSession}\nLearners: ${slot.bookedCount}/$cap';
                            if (hasOther && locked) {
                              _toast(
                                'You can’t change booking within 24 hours.',
                              );
                              return;
                            }

                            final ok = await _confirmWithLogo(
                              title: hasOther
                                  ? (isSameTimeDifferentTeacher
                                        ? 'Change teacher'
                                        : 'Change booking')
                                  : label,
                              message: msg,
                              confirmLabel: hasOther
                                  ? (isSameTimeDifferentTeacher
                                        ? 'Yes, Change Teacher'
                                        : 'Yes, Change')
                                  : 'Yes',
                            );

                            if (ok == true) {
                              await _runBusy('Saving booking...', () async {
                                await _bookSlot(slot);
                              });
                            }
                          },
                    child: Text(
                      joinable
                          ? ((slot.bookedCount > 0 &&
                                    slot.groupSessionNo == targetSession)
                                ? 'Join group'
                                : 'Book this slot')
                          : (newBookingLocked ? 'Closed' : 'Unavailable'),
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ] else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: bookedBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: bookedBorder),
                    ),
                    child: Text(
                      'You are booked in this slot ✅ (${slot.bookedCount}/$cap learners)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: primaryBlue,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: !canCancel
                          ? Colors.grey.shade400
                          : Colors.red.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: (booking || refreshing || !canCancel)
                        ? null
                        : () async {
                            Navigator.pop(context);

                            final isLate = _isWithin24Hours(slot);
                            final confirmLabel = isLate
                                ? 'Yes, cancel and count credit'
                                : 'Yes, Cancel';
                            final message = isLate
                                ? 'This cancellation is within 24 hours of the session.\n\nYou can cancel to free this slot for other learners.\n\nImportant: this session credit will still be counted as used.'
                                : 'Are you sure you want to cancel this booking?';

                            final ok = await _confirmWithLogo(
                              title: isLate
                                  ? 'Late cancellation (within 24h)'
                                  : 'Cancel booking',
                              message: message,
                              confirmLabel: confirmLabel,
                              confirmColor: Colors.red.shade600,
                            );

                            if (ok == true) {
                              await _runBusy('Cancelling booking...', () async {
                                await _cancelMyBooking(slot);
                              });
                            }
                          },
                    child: Text(
                      !canCancel
                          ? 'Cancel unavailable (class ended)'
                          : (lateCancel
                                ? 'Cancel (credit counted)'
                                : 'Cancel booking'),
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sheetInfoRow({
    required IconData icon,
    required String title,
    required String value,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: primaryBlue, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: primaryBlue,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing],
        ],
      ),
    );
  }

  // ================== More teachers sheet ==================

  Future<void> _openMoreTeachersSheet(
    List<_Slot> allSlots,
    List<_Slot> hiddenSlots,
  ) async {
    if (!mounted || hiddenSlots.isEmpty) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        final first = allSlots.first;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 16 + bottomPad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_friendlyDate(first.start)} • ${first.time}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: primaryBlue,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'More teachers for this slot',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (int i = 0; i < hiddenSlots.length; i++) ...[
                          _teacherMiniTile(hiddenSlots[i]),
                          if (i != hiddenSlots.length - 1)
                            const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openExpandedSchedule() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: appBg,
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            surfaceTintColor: Colors.white,
            iconTheme: const IconThemeData(color: primaryBlue),
            title: const Text(
              'Full Schedule',
              style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
            ),
          ),
          body: learnerWebBodyFrame(
            context: context,
            maxWidth: 1500,
            child: SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _buildTimetable(generatedSlots, expanded: true),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ================== Filters UI ==================

  Widget _buildFiltersInline() {
    final Map<String, String> teacherIdToName = {};
    for (final s in generatedSlots) {
      teacherIdToName[s.teacherId] = s.teacherName;
    }
    final teacherIds = teacherIdToName.keys.toList()
      ..sort(
        (a, b) =>
            (teacherIdToName[a] ?? '').compareTo(teacherIdToName[b] ?? ''),
      );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune_rounded, size: 16, color: primaryBlue),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Filters',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: primaryBlue,
                  ),
                ),
              ),
              if (teacherFilter != 'all' ||
                  timeFilter != 'all' ||
                  onlyJoinable ||
                  onlyPeerGroups)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: actionOrange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: actionOrange.withValues(alpha: 0.25),
                    ),
                  ),
                  child: const Text(
                    'Active',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: actionOrange,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
            ),
            child: DropdownButton<String>(
              value: teacherFilter,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              icon: const Icon(Icons.expand_more_rounded, color: primaryBlue),
              items: [
                const DropdownMenuItem(
                  value: 'all',
                  child: Text('All teachers'),
                ),
                ...teacherIds.map((id) {
                  final name = teacherIdToName[id] ?? 'Teacher';
                  return DropdownMenuItem(
                    value: id,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => teacherFilter = v);
              },
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip(
                  'All day',
                  timeFilter == 'all',
                  () => setState(() => timeFilter = 'all'),
                ),
                const SizedBox(width: 8),
                _chip(
                  'Morning',
                  timeFilter == 'morning',
                  () => setState(() => timeFilter = 'morning'),
                ),
                const SizedBox(width: 8),
                _chip(
                  'Afternoon',
                  timeFilter == 'afternoon',
                  () => setState(() => timeFilter = 'afternoon'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _togglePillCompact(
                label: 'Joinable',
                value: onlyJoinable,
                onChanged: (v) => setState(() => onlyJoinable = v),
              ),
              _togglePillCompact(
                label: 'Peer groups',
                value: onlyPeerGroups,
                onChanged: (v) => setState(() => onlyPeerGroups = v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _togglePillCompact({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: value ? actionOrange.withValues(alpha: 0.10) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: value
                ? actionOrange.withValues(alpha: 0.30)
                : uiBorder.withValues(alpha: 0.9),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: value ? actionOrange : primaryBlue,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: value ? actionOrange : primaryBlue,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: tap,
      child: Container(
        width: 132,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: on ? actionOrange.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: on
                ? actionOrange.withValues(alpha: 0.35)
                : uiBorder.withValues(alpha: 0.9),
          ),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: on ? actionOrange : primaryBlue,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const List<Map<String, String>> _modeLabels = [
    {'follow': 'Next lesson', 'custom': 'Choose lesson'},
    {'follow': 'Lecon suivante', 'custom': 'Choisir lecon'},
    {'follow': 'الدرس التالي', 'custom': 'اختر الدرس'},
  ];

  String get _followModeLabel => _modeLabels[_modeLabelIndex]['follow']!;
  String get _customModeLabel => _modeLabels[_modeLabelIndex]['custom']!;

  Future<void> _showModeHintDialog({required bool isCustom}) async {
    final lang = _modeLabelIndex;

    String title;
    String body;
    String action;

    if (lang == 1) {
      title = isCustom ? 'Choisir lecon' : 'Lecon suivante';
      body = isCustom
          ? 'Vous choisissez vous-meme la lecon a etudier maintenant. Utilisez ce mode pour reviser ou avancer.'
          : 'Nous choisissons automatiquement votre prochaine lecon selon votre progression confirmee.';
      action = 'Compris';
    } else if (lang == 2) {
      title = isCustom ? 'اختر الدرس' : 'الدرس التالي';
      body = isCustom
          ? 'في هذا الوضع تختار بنفسك الدرس الذي تريد دراسته الآن، للمراجعة أو التقدم.'
          : 'في هذا الوضع نحدد لك الدرس التالي تلقائيا حسب تقدمك المؤكد.';
      action = 'فهمت';
    } else {
      title = isCustom ? 'Choose lesson' : 'Next lesson';
      body = isCustom
          ? 'You choose the lesson to study now. Use this to review or jump ahead.'
          : 'We automatically choose your next lesson based on your confirmed progress.';
      action = 'Got it';
    }

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _onFollowModeTap() async {
    if (!_didShowFollowModeHint) {
      await _showModeHintDialog(isCustom: false);
      if (!mounted) return;
      _didShowFollowModeHint = true;
    }

    if (!mounted) return;
    setState(() {
      studyMode = 'follow';
      selectedSessionNo = currentSession;
      lessonsExpanded = false;
    });
  }

  Future<void> _onCustomModeTap() async {
    if (!_didShowCustomModeHint) {
      await _showModeHintDialog(isCustom: true);
      if (!mounted) return;
      _didShowCustomModeHint = true;
    }

    if (!mounted) return;
    setState(() {
      studyMode = 'custom';
      selectedSessionNo = _targetSessionNo;
      lessonsExpanded = true;
    });
  }

  Widget _modeInfoButton({required bool isCustom}) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () async {
        await _showModeHintDialog(isCustom: isCustom);
        if (!mounted) return;
        setState(() {
          if (isCustom) {
            _didShowCustomModeHint = true;
          } else {
            _didShowFollowModeHint = true;
          }
        });
      },
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
        ),
        child: const Center(
          child: Text(
            '!',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  // ================== Compact header ==================

  Widget _buildCompactHeader() {
    final targetSession = _targetSessionNo;
    final sessionInfo = curriculumSessions['$targetSession'];
    final sessionTitle = (sessionInfo is Map)
        ? (sessionInfo['sessionTitle'] ?? sessionInfo['title'] ?? '')
              .toString()
              .trim()
        : '';

    final total = _effectiveTotalSessions;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            courseTitle.isEmpty ? 'Course' : courseTitle,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 16,
              color: primaryBlue,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                'Session $targetSession / $total',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade800,
                  height: 1.25,
                ),
              ),
              _smallStatPill('Studied', '$studiedSessionsConsumed'),
              _smallStatPill('Left', '$_sessionsLeft'),
              _smallStatPill('Next', '$currentSession'),
            ],
          ),
          if (sessionTitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              sessionTitle,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700,
                height: 1.2,
              ),
            ),
          ],
          const SizedBox(height: 8),
          _buildStudyModeRow(),
          const SizedBox(height: 8),
          _buildLessonToolsRow(),
          if (studyMode == 'custom' && lessonsExpanded) ...[
            const SizedBox(height: 8),
            _buildLessonsPicker(),
          ],
        ],
      ),
    );
  }

  Widget _buildLessonToolsRow() {
    return Row(
      children: [
        Expanded(child: _buildLessonsCollapseHeader()),
        const SizedBox(width: 8),
        _smallActionButton(
          icon: Icons.menu_book_rounded,
          label: 'Session details',
          pulse: true,
          fixedWidth: 144,
          onTap: () => _openSessionDetails(_targetSessionNo),
        ),
      ],
    );
  }

  Widget _buildLessonsCollapseHeader() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (studyMode != 'custom') {
          _toast('Tap "Choose lesson" first.');
          return;
        }
        setState(() => lessonsExpanded = !lessonsExpanded);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
        ),
        child: Row(
          children: [
            const Icon(Icons.view_stream_rounded, size: 18, color: primaryBlue),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Lesson choices',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: primaryBlue,
                ),
              ),
            ),
            Icon(
              studyMode == 'custom' && lessonsExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: Colors.grey.shade700,
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallStatPill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: primaryBlue,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildStudyModeRow() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _chip(
              _followModeLabel,
              studyMode == 'follow',
              () => _onFollowModeTap(),
            ),
            const SizedBox(width: 6),
            _modeInfoButton(isCustom: false),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _chip(
              _customModeLabel,
              studyMode == 'custom',
              () => _onCustomModeTap(),
            ),
            const SizedBox(width: 6),
            _modeInfoButton(isCustom: true),
          ],
        ),
      ],
    );
  }

  Widget _buildLessonsPicker() {
    final total = _effectiveTotalSessions;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Lessons',
            style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: total,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final sessionNo = i + 1;
                final isTarget = sessionNo == _targetSessionNo;
                final done = sessionNo < currentSession;
                final title = _sessionTitleFor(sessionNo);
                final enabled = studyMode == 'custom';

                return SizedBox(
                  width: 130,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: enabled
                        ? () => setState(() => selectedSessionNo = sessionNo)
                        : null,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isTarget
                            ? actionOrange.withValues(alpha: 0.12)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isTarget
                              ? actionOrange.withValues(alpha: 0.4)
                              : uiBorder.withValues(alpha: 0.9),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Session $sessionNo',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: primaryBlue,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: () => _openSessionDetails(sessionNo),
                                child: Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: uiBorder.withValues(alpha: 0.9),
                                    ),
                                  ),
                                  child: const Center(
                                    child: Text(
                                      '!',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: primaryBlue,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            done
                                ? 'Done'
                                : (sessionNo == currentSession
                                      ? 'Next'
                                      : 'Upcoming'),
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: done
                                  ? const Color(0xFF157A3D)
                                  : actionOrange,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            title.isEmpty ? 'No title yet' : title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade700,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (studyMode != 'custom')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Tip: tap "Choose lesson" to pick a specific lesson.',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _smallActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool pulse = false,
    double? fixedWidth,
  }) {
    final button = InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: actionOrange.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: actionOrange.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: actionOrange),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: actionOrange,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );

    final scaled = pulse
        ? ScaleTransition(
            scale: Tween<double>(begin: 1.0, end: 1.06).animate(
              CurvedAnimation(
                parent: _sessionPulseCtrl,
                curve: Curves.easeInOut,
              ),
            ),
            child: button,
          )
        : button;

    if (fixedWidth == null) return scaled;
    return SizedBox(
      width: fixedWidth,
      child: Center(child: scaled),
    );
  }

  // ================== Timetable ==================

  Widget _teacherMiniTile(_Slot s) {
    final cap = s.maxLearnersPerSlot <= 0 ? 6 : s.maxLearnersPerSlot;
    final targetSession = _targetSessionNo;

    final bookedByMe = s.bookedByMe;
    final isClosed = _isBookingLockedForNewBooking(s);
    final peerGroup = _isPeerGroup(s);
    final otherSession =
        (s.groupSessionNo != null && s.groupSessionNo != targetSession) &&
        !bookedByMe;
    final fullButMySession =
        !bookedByMe && s.groupSessionNo == targetSession && s.isFull;

    final bg = bookedByMe
        ? bookedBg
        : isClosed
        ? lockedBg
        : peerGroup
        ? peerBg
        : otherSession || fullButMySession
        ? otherSessionBg
        : emptyBg;

    final border = bookedByMe
        ? bookedBorder
        : isClosed
        ? lockedBorder
        : peerGroup
        ? peerBorder
        : otherSession || fullButMySession
        ? otherSessionBorder
        : emptyBorder;

    final countText = '${s.bookedCount}/$cap';
    final teacherLine = '${_shortTeacherName(s.teacherName)}  ·  $countText';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _onSlotTap(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Text(
          teacherLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: Colors.grey.shade800,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildTimetable(List<_Slot> rawSlots, {bool expanded = false}) {
    final slots = _applyFilters(rawSlots);

    final days = _nextDays(timetableDays);
    final times = _uniqueTimes(slots);

    final Map<String, List<_Slot>> index = {};
    for (final s in slots) {
      final cellKey = '${s.dayKey}|${s.time}';
      index.putIfAbsent(cellKey, () => <_Slot>[]).add(s);
    }

    for (final k in index.keys) {
      index[k]!.sort((a, b) => a.teacherName.compareTo(b.teacherName));
    }
    const double fixedRowHeight = 158;

    final double timeColumnWidth = expanded ? 66 : 58;
    final double dayColumnWidth = expanded ? 202 : 154;

    // Fixed heights so the sticky time column stays aligned with the grid rows.
    const double headerHeight = 44;

    if (times.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
        ),
        child: const Text(
          'No slots match your filters.',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // LEFT STICKY TIME COLUMN
        SizedBox(
          width: timeColumnWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: headerHeight + 8),
              ...times.map((t) {
                const rowHeight = fixedRowHeight;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    height: rowHeight,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        _verticalTimeLabel(t),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                          fontSize: 12,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // HORIZONTALLY SCROLLABLE DAYS GRID
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: days.map((d) {
                    return Container(
                      width: dayColumnWidth,
                      height: headerHeight,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 8,
                      ),
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: uiBorder.withValues(alpha: 0.8),
                        ),
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.white,
                      ),
                      child: Text(
                        _friendlyDate(d),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                          fontSize: 12,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                ...times.map((t) {
                  const rowHeight = fixedRowHeight;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: days.map((d) {
                        final dk = _dateKey(d);
                        final key = '$dk|$t';
                        final list = index[key] ?? const <_Slot>[];

                        final hasSlot = list.isNotEmpty;
                        final visibleCount = list.length > 2 ? 2 : list.length;
                        final hiddenCount = list.length - visibleCount;

                        return Container(
                          width: dayColumnWidth,
                          height: rowHeight,
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: hasSlot ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: hasSlot
                                  ? uiBorder.withValues(alpha: 0.85)
                                  : uiBorder.withValues(alpha: 0.25),
                            ),
                          ),
                          child: hasSlot
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (int i = 0; i < visibleCount; i++) ...[
                                      _teacherMiniTile(list[i]),
                                      if (i != visibleCount - 1)
                                        const SizedBox(height: 8),
                                    ],
                                    if (hiddenCount > 0) ...[
                                      const SizedBox(height: 6),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        onTap: () => _openMoreTeachersSheet(
                                          list,
                                          list.sublist(visibleCount),
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 7,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF8FAFB),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            border: Border.all(
                                              color: uiBorder.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                          ),
                                          child: Text(
                                            '+$hiddenCount more',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 11,
                                              color: Colors.grey.shade800,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                )
                              : const SizedBox.shrink(),
                        );
                      }).toList(),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ================== UI ==================

  @override
  Widget build(BuildContext context) {
    final cid = courseId;
    final busy = loading || booking || refreshing || progressLabel.isNotEmpty;
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

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
                  : (desktopWorkspace
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 360,
                                  child: ListView(
                                    children: [
                                      _buildCompactHeader(),
                                      const SizedBox(height: 12),
                                      _SectionCard(
                                        title: 'Schedule filters',
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            _buildFiltersInline(),
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              width: double.infinity,
                                              child: OutlinedButton.icon(
                                                onPressed:
                                                    generatedSlots.isEmpty
                                                    ? null
                                                    : _openExpandedSchedule,
                                                icon: const Icon(
                                                  Icons.open_in_full_rounded,
                                                ),
                                                label: const Text(
                                                  'Open full schedule',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ListView(
                                    children: [
                                      _SectionCard(
                                        title: 'Available timetable',
                                        subtitle:
                                            'Choose a slot from the wider desktop schedule.',
                                        child: generatedSlots.isEmpty
                                            ? const Text(
                                                'No available slots found.\nAsk your teacher to set availability for this course.',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              )
                                            : Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  _buildTimetable(
                                                    generatedSlots,
                                                  ),
                                                  const SizedBox(height: 96),
                                                ],
                                              ),
                                      ),
                                      if (booking || refreshing)
                                        const Padding(
                                          padding: EdgeInsets.only(top: 14),
                                          child: Center(
                                            child: BrandedInlineLoader(
                                              message: 'Updating...',
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              _buildCompactHeader(),
                              const SizedBox(height: 12),
                              _SectionCard(
                                title: '',
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: generatedSlots.isEmpty
                                          ? null
                                          : _openExpandedSchedule,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: uiBorder.withValues(
                                              alpha: 0.9,
                                            ),
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.open_in_full_rounded,
                                              size: 16,
                                              color: primaryBlue,
                                            ),
                                            SizedBox(width: 6),
                                            Text(
                                              'Expand',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: primaryBlue,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: () => setState(
                                        () =>
                                            filtersExpanded = !filtersExpanded,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: uiBorder.withValues(
                                              alpha: 0.9,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.tune_rounded,
                                              size: 16,
                                              color: primaryBlue,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              filtersExpanded
                                                  ? 'Hide filters'
                                                  : 'Filters',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: primaryBlue,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                child: generatedSlots.isEmpty
                                    ? const Text(
                                        'No available slots found.\nAsk your teacher to set availability for this course.',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      )
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (filtersExpanded) ...[
                                            _buildFiltersInline(),
                                            const SizedBox(height: 12),
                                          ],
                                          _buildTimetable(generatedSlots),
                                          const SizedBox(height: 96),
                                        ],
                                      ),
                              ),
                              if (booking || refreshing)
                                const Padding(
                                  padding: EdgeInsets.only(top: 14),
                                  child: Center(
                                    child: BrandedInlineLoader(
                                      message: 'Updating...',
                                    ),
                                  ),
                                ),
                            ],
                          )),
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

// ================== Small UI helpers ==================

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    this.subtitle,
    required this.child,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    final hasTitle = title.trim().isNotEmpty;
    final hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;
    final showHeader = hasTitle || hasSubtitle || trailing != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader) ...[
            Row(
              children: [
                if (hasTitle || hasSubtitle)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasTitle)
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: primaryBlue,
                            ),
                          ),
                        if (hasSubtitle) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                else
                  const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}
