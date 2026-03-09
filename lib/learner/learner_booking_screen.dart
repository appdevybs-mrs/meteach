// ✅ FULL REPLACEMENT: lib/learner/learner_booking_screen.dart
//
// UI-focused replacement:
// - Keeps your booking logic, Firebase logic, transaction logic, capacity logic, reminders, Meet logic
// - Reduces hierarchy and visual noise
// - Makes schedule the main focus
// - Removes the large legend block
// - Adds a compact header
// - Adds multilingual "How booking works" sheet
// - Keeps filters, but hides them behind expandable UI
// - Keeps multiple teachers per same day/time cell
//
// Notes:
// - Logic is intentionally preserved as much as possible
// - This file is mainly a UI/layout cleanup

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/push_client.dart';
import '../services/notification_service.dart';
import '../widgets/teacher_media_sheet.dart';

class LearnerBookingScreen extends StatefulWidget {
  const LearnerBookingScreen({super.key, this.courseId});

  /// Pass a REAL courseId (recommended).
  final String? courseId;

  @override
  State<LearnerBookingScreen> createState() => _LearnerBookingScreenState();
}

class _LearnerBookingScreenState extends State<LearnerBookingScreen> {
  // ===== Colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  // Simplified status colors
  static const peerBg = Color(0xFFE9F4FF);
  static const peerBorder = Color(0xFF9BC8FF);
  static const bookedBg = Color(0xFFEAF7EE);
  static const bookedBorder = Color(0xFFB9E2C5);
  static const otherSessionBg = Color(0xFFF1F3F5);
  static const otherSessionBorder = Color(0xFFCED4DA);
  static const emptyBg = Color(0xFFFFF1E3);
  static const emptyBorder = Color(0xFFF9C59D);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // optional classId inference
  String _classId = '';

  // Auth
  String myUid = '';
  bool loading = true;
  bool booking = false;

  // Course
  String? courseId;
  String courseTitle = '';

  // Curriculum (optional)
  int totalSessions = 0;
  Map<String, dynamic> curriculumSessions = {};

  // Progress
  int currentSession = 1;

  // Slots window / schedule
  int daysAhead = 14;
  static const int timetableDays = 7;
  List<_Slot> generatedSlots = [];

  // My bookings map: "yyyy-mm-dd|HH:MM" -> sessionNo
  Map<String, int> myBookedSlots = {};

  // Slot group summary: "yyyy-mm-dd|HH:MM" -> summary
  Map<String, _SlotSummary> slotSummary = {};

  // Filters
  String teacherFilter = 'all';
  String timeFilter = 'all'; // all | morning | afternoon
  bool onlyJoinable = false;
  bool onlyPeerGroups = false;

  // UI state
  bool filtersExpanded = false;
  String helpLang = 'en'; // en | ar | fr | tr | ur

  @override
  void initState() {
    super.initState();
    _init();
  }

  // ================== Helpers ==================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
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

  DatabaseReference _curriculumRef(String cid) =>
      _db.child('booking_curriculum/$cid');
  DatabaseReference _availabilityRootRef() =>
      _db.child('booking_availability');
  DatabaseReference _syllabiRef(String cid) => _db.child('syllabi/$cid');
  DatabaseReference _progressRef(String cid) =>
      _db.child('booking_progress/$myUid/$cid');
  DatabaseReference _reservationsRootRef(String cid) =>
      _db.child('booking_reservations/$cid');
  DatabaseReference _reservationsRef(String cid, String dayKey, String hhmm) =>
      _db.child('booking_reservations/$cid/$dayKey/$hhmm');

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

  bool _canOpenMeetNow(_Slot slot) {
    if (!slot.bookedByMe) return false;
    if (slot.meetUrl.trim().isEmpty) return false;

    final now = DateTime.now();
    final openFrom = slot.start.subtract(const Duration(minutes: 10));
    final dur = slot.durationMinutes <= 0 ? 60 : slot.durationMinutes;
    final openUntil = slot.start
        .add(Duration(minutes: dur))
        .add(const Duration(minutes: 15));

    return now.isAfter(openFrom) && now.isBefore(openUntil);
  }

  bool _isJoinable(_Slot s) {
    if (s.bookedByMe) return true;
    if (s.groupSessionNo == null) return true;
    if (s.groupSessionNo != currentSession) return false;
    if (s.isFull) return false;
    return true;
  }

  bool _isPeerGroup(_Slot s) {
    return (s.groupSessionNo == currentSession) &&
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

  Future<String?> _getUserToken(String uid) async {
    try {
      final snap = await _db.child('fcm_tokens/$uid/token').get();
      if (!snap.exists || snap.value == null) return null;

      final token = snap.value.toString().trim();
      if (token.isEmpty) return null;

      return token;
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendBookingNotifications(_Slot slot) async {
    try {
      final learnerName = await _getMyFullName();

      final sessionNo = slot.groupSessionNo ?? currentSession;
      final safeCourseTitle =
      courseTitle.trim().isEmpty ? 'Course' : courseTitle.trim();

      final adminTitle = 'New learner booking';
      final adminBody =
          '$learnerName booked Session $sessionNo for $safeCourseTitle on ${slot.dayKey} at ${slot.time} with ${slot.teacherName}.';

      await PushClient.sendToTopic(
        topic: 'admins',
        title: adminTitle,
        message: adminBody,
        data: {
          'type': 'booking',
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

      final teacherToken = await _getUserToken(slot.teacherId);
      if (teacherToken == null || teacherToken.isEmpty) return;

      final teacherTitle = 'New class booking';
      final teacherBody =
          '$learnerName booked Session $sessionNo for $safeCourseTitle on ${slot.dayKey} at ${slot.time}.';

      await PushClient.sendToToken(
        token: teacherToken,
        title: teacherTitle,
        message: teacherBody,
        data: {
          'type': 'booking',
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
    } catch (e) {
      debugPrint('Booking notification failed: $e');
    }
  }

  Future<void> _scheduleLearnerLocalReminder(_Slot slot) async {
    try {
      await NotificationService.I.init();
      await NotificationService.I.requestPermissions();

      final sessionNo = slot.groupSessionNo ?? currentSession;
      final safeCourseTitle =
      courseTitle.trim().isEmpty ? 'Course' : courseTitle.trim();

      await NotificationService.I.scheduleSessionReminder(
        classId: '${slot.courseId}_${slot.dayKey}_${slot.time}',
        title: 'Upcoming class',
        body: 'Session $sessionNo for $safeCourseTitle with ${slot.teacherName}',
        sessionStart: slot.start,
        minutesBefore: 30,
      );
    } catch (e) {
      debugPrint('Local booking reminder failed: $e');
    }
  }

  Future<void> _cancelLearnerLocalReminder(_Slot slot) async {
    try {
      await NotificationService.I.init();

      await NotificationService.I.cancelSessionReminder(
        classId: '${slot.courseId}_${slot.dayKey}_${slot.time}',
        sessionStart: slot.start,
      );
    } catch (e) {
      debugPrint('Cancel local booking reminder failed: $e');
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

    _classId = await _inferClassIdForCourse(courseId!);

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

        final id =
        (m['id'] ?? m['courseId'] ?? m['course_id'] ?? '').toString().trim();

        final deliveryKey = (m['deliveryKey'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        final studyMode = (m['studyMode'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        final isBookingCourse = deliveryKey == 'flexible';

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

        String title = (m['title'] ?? '').toString().trim();
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

      final root =
      (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));

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
      final snap = await _progressRef(cid).get();
      if (!snap.exists || snap.value == null) {
        await _progressRef(cid).set({
          'currentSession': 1,
          'updatedAt': ServerValue.timestamp,
        });
        currentSession = 1;
        return;
      }

      if (snap.value is Map) {
        final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));
        currentSession = _toInt(m['currentSession'], fallback: 1);
        if (currentSession <= 0) currentSession = 1;
      } else {
        currentSession = 1;
      }
    } catch (e) {
      _toast('Failed to load progress: $e');
      currentSession = 1;
    }
  }

  // ================== Load Reservations Summary ==================

  Future<void> _loadReservationsSummary(String cid) async {
    final now = DateTime.now();
    final Map<String, int> mine = {};
    final Map<String, _SlotSummary> summary = {};

    try {
      for (int i = 0; i < daysAhead; i++) {
        final day =
        DateTime(now.year, now.month, now.day).add(Duration(days: i));
        final dk = _dateKey(day);

        final snap = await _reservationsRootRef(cid).child(dk).get();
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));

        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final slotNode = e.value;
          if (slotNode is! Map) continue;

          final sm = slotNode.map((k, vv) => MapEntry(k.toString(), vv));

          final learnersRaw = sm['learners'];
          if (learnersRaw is! Map) continue;

          final learners =
          learnersRaw.map((k, vv) => MapEntry(k.toString(), vv));
          final count = learners.length;
          if (count <= 0) continue;

          final groupSessionNo = _toInt(sm['sessionNo'], fallback: 0);
          final groupSession = groupSessionNo <= 0 ? null : groupSessionNo;

          final key = '$dk|$hhmm';

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
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      myBookedSlots = mine;
      slotSummary = summary;
    });
  }

  Future<_MyBooking?> _findMyNextBooking(String cid) async {
    final now = DateTime.now();
    _MyBooking? best;

    try {
      for (int i = 0; i < daysAhead; i++) {
        final day =
        DateTime(now.year, now.month, now.day).add(Duration(days: i));
        final dk = _dateKey(day);

        final snap = await _reservationsRootRef(cid).child(dk).get();
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));
        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final node = e.value;
          if (node is! Map) continue;

          final sm = node.map((k, vv) => MapEntry(k.toString(), vv));
          final learners = sm['learners'];
          if (learners is! Map) continue;

          final lm = learners.map((k, vv) => MapEntry(k.toString(), vv));
          if (!lm.containsKey(myUid)) continue;

          final start = _parseSlotStart(dk, hhmm);
          if (start == null) continue;
          if (!start.isAfter(now)) continue;

          final tId = (sm['teacherId'] ?? '').toString().trim();
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

          if (best == null || candidate.start.isBefore(best.start)) {
            best = candidate;
          }
        }
      }
    } catch (_) {}

    return best;
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

      final root = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));
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
          teacherOnlineEnabled =
              _toBool(sm['teacherOnlineEnabled'], fallback: true);
        }
        if (!teacherOnlineEnabled) continue;

        final perCourse = tn[cid];
        if (perCourse is! Map) continue;

        final effective =
        perCourse.map((k, vv) => MapEntry(k.toString(), vv));

        final courseOnlineEnabled =
        _toBool(effective['courseOnlineEnabled'], fallback: true);
        if (!courseOnlineEnabled) continue;

        final resolvedTeacherName = (effective['teacherName'] ??
            effective['teacher_name'] ??
            tn['teacherName'] ??
            tn['teacher_name'] ??
            '')
            .toString()
            .trim();

        final meetUrl = (effective['meetUrl'] ??
            effective['meet_url'] ??
            effective['googleMeetUrl'] ??
            effective['google_meet_url'] ??
            '')
            .toString()
            .trim();

        int durationMin = _toInt(effective['durationMinutes'], fallback: 0);
        if (durationMin <= 0) {
          durationMin = _toInt(effective['durationMin'], fallback: 0);
        }
        if (durationMin <= 0) durationMin = 60;

        int maxLearners =
        _toInt(effective['maxLearnersPerSlot'], fallback: 0);
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
            teacherName:
            resolvedTeacherName.isEmpty ? 'Teacher' : resolvedTeacherName,
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
        final day =
        DateTime(now.year, now.month, now.day).add(Duration(days: i));
        final wk = _weekdayKey(day);
        final dayKey = _dateKey(day);

        for (final t in teachers) {
          final list = t.slotsByDay[wk] ?? const [];
          for (final hhmm in list) {
            final start = _parseSlotStart(dayKey, hhmm);
            if (start == null) continue;
            if (start.isBefore(now.add(const Duration(minutes: 1)))) continue;

            final slotKey = '$dayKey|$hhmm';
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
        if (teacherFilter != 'all' &&
            !teachersInList.contains(teacherFilter)) {
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
    if (booking) return;
    final cid = courseId;
    if (cid == null) return;

    if (totalSessions <= 0) {
      _toast('Booking enabled, but total lessons not set.');
      return;
    }

    if (currentSession > totalSessions) {
      _toast('You already finished this course.');
      return;
    }

    if (!_isJoinable(slot)) {
      if (slot.groupSessionNo != null &&
          slot.groupSessionNo != currentSession) {
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
      final existing = await _findMyNextBooking(cid);

      if (existing != null &&
          existing.dayKey == slot.dayKey &&
          existing.time == slot.time) {
        _toast('You already booked this slot ✅');
        return;
      }

      if (existing != null) {
        final locked = !existing.start
            .isAfter(DateTime.now().add(const Duration(hours: 24)));
        if (locked) {
          _toast(
              'You already booked a class and it’s within 24 hours, so you can’t change it.');
          return;
        }

        final okCancel =
        await _cancelBookingByKey(cid, existing.dayKey, existing.time);
        if (!okCancel) {
          _toast('Could not change booking (cancel failed).');
          return;
        }

        final oldSlotStart = _parseSlotStart(existing.dayKey, existing.time);
        if (oldSlotStart != null) {
          try {
            await NotificationService.I.init();
            await NotificationService.I.cancelSessionReminder(
              classId: '${cid}_${existing.dayKey}_${existing.time}',
              sessionStart: oldSlotStart,
            );
          } catch (e) {
            debugPrint('Old reminder cancel failed: $e');
          }
        }
      }

      final ref = _reservationsRef(cid, slot.dayKey, slot.time);

      final pre = await ref.get();
      int? existingGroupSession;
      int existingCount = 0;

      if (pre.exists && pre.value is Map) {
        final m = (pre.value as Map).map((k, v) => MapEntry(k.toString(), v));
        existingGroupSession = _toInt(m['sessionNo'], fallback: 0);
        if (existingGroupSession != null && existingGroupSession <= 0) {
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
          existingGroupSession != currentSession) {
        _toast(
            'This slot is a Session $existingGroupSession group. You are on Session $currentSession.');
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
              existingLearners.map((k, v) => MapEntry(k.toString(), v)));
        }

        if (learners.containsKey(myUid)) {
          return Transaction.abort();
        }

        final cap = maxCap;
        if (learners.length >= cap) {
          return Transaction.abort();
        }

        final groupSessionNo = _toInt(node['sessionNo'], fallback: 0);
        if (groupSessionNo > 0 && groupSessionNo != currentSession) {
          return Transaction.abort();
        }

        learners[myUid] = true;

        node['teacherId'] = slot.teacherId;
        node['teacherName'] = slot.teacherName;
        node['sessionNo'] = currentSession;
        node['learners'] = learners;
        node['createdAt'] = ServerValue.timestamp;

        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast(
            'Could not join. The slot may be full or became a different session group.');
        return;
      }

      final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
      final newCount = (existingCount + 1);
      if (existingCount == 0) {
        _toast('Booked ✅ Started Session $currentSession group');
      } else {
        _toast('Joined ✅ Session $currentSession group ($newCount/$cap)');
      }

      await _sendBookingNotifications(slot);
      await _scheduleLearnerLocalReminder(slot);

      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
    } catch (e) {
      _toast('Booking failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => booking = false);
    }
  }

  Future<bool> _cancelBookingByKey(String cid, String dayKey, String hhmm) async {
    try {
      final start = _parseSlotStart(dayKey, hhmm);
      if (start == null) return false;

      final locked =
      !start.isAfter(DateTime.now().add(const Duration(hours: 24)));
      if (locked) return false;

      final ref = _reservationsRef(cid, dayKey, hhmm);

      final result = await ref.runTransaction((Object? currentData) {
        if (currentData is! Map) return Transaction.abort();

        final node = currentData.map((k, v) => MapEntry(k.toString(), v));
        final learnersRaw = node['learners'];
        if (learnersRaw is! Map) return Transaction.abort();

        final learners = learnersRaw.map((k, v) => MapEntry(k.toString(), v));
        if (!learners.containsKey(myUid)) return Transaction.abort();

        learners.remove(myUid);

        if (learners.isEmpty) {
          return Transaction.success(null);
        }

        node['learners'] = learners;
        return Transaction.success(node);
      });

      return result.committed;
    } catch (_) {
      return false;
    }
  }

  Future<void> _cancelMyBooking(_Slot slot) async {
    final cid = courseId;
    if (cid == null) return;

    final locked =
    !slot.start.isAfter(DateTime.now().add(const Duration(hours: 24)));
    if (locked) {
      _toast('You can’t cancel within 24 hours of the session.');
      return;
    }

    setState(() => booking = true);

    try {
      final ok = await _cancelBookingByKey(cid, slot.dayKey, slot.time);
      if (!ok) {
        _toast('Cancel failed.');
        return;
      }

      await _cancelLearnerLocalReminder(slot);

      _toast('Booking canceled ✅');

      await _loadReservationsSummary(cid);
      await _generateSlots(cid);
    } catch (e) {
      _toast('Cancel failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => booking = false);
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

  Future<void> _openNextSessionDetails() async {
    final info = curriculumSessions['$currentSession'];
    if (info is! Map) {
      _toast('Session details not found (curriculum is optional).');
      return;
    }

    final m = info.map((k, v) => MapEntry(k.toString(), v));

    final rawTitle = (m['sessionTitle'] ?? m['title'] ?? '').toString().trim();
    final title =
    rawTitle.isEmpty ? 'Session $currentSession' : 'Session $currentSession — $rawTitle';
    final objective = (m['objective'] ?? '').toString().trim();
    final content = (m['content'] ?? '').toString().trim();
    final homework = (m['homework'] ?? '').toString().trim();
    final duration = _toInt(m['durationMinutes'], fallback: 0);

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
          child: Padding(
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
                  _kv('Session', '$currentSession / $totalSessions'),
                  if (duration > 0) _kv('Duration', '$duration min'),
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
                  textDirection:
                  isArabic ? TextDirection.rtl : TextDirection.ltr,
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
                              style:
                              const TextStyle(fontWeight: FontWeight.w900),
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
          color: selected ? actionOrange.withOpacity(0.12) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? actionOrange.withOpacity(0.40)
                : uiBorder.withOpacity(0.95),
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
              color: actionOrange.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: actionOrange.withOpacity(0.25)),
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
        return 'يمكنك الحجز فقط في حصتك الحالية.';
      case 'fr':
        return 'Vous pouvez réserver seulement votre session actuelle.';
      case 'tr':
        return 'Sadece mevcut oturumunuz için rezervasyon yapabilirsiniz.';
      case 'ur':
        return 'آپ صرف اپنے موجودہ سیشن کے لیے بکنگ کر سکتے ہیں۔';
      default:
        return 'You can only book your current session.';
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
        return 'يمكنك تغيير أو إلغاء الحجز قبل 24 ساعة فقط.';
      case 'fr':
        return 'Vous pouvez changer ou annuler seulement avant 24 heures.';
      case 'tr':
        return 'Sadece 24 saatten önce değiştirebilir veya iptal edebilirsiniz.';
      case 'ur':
        return 'آپ صرف 24 گھنٹے پہلے بکنگ تبدیل یا منسوخ کر سکتے ہیں۔';
      default:
        return 'You can change or cancel only before 24 hours.';
    }
  }

  String _helpRule4(String lang) {
    switch (lang) {
      case 'ar':
        return 'إذا كان المكان ممتلئًا أو لحصة مختلفة، فلن يكون متاحًا.';
      case 'fr':
        return 'Si le créneau est plein ou pour une autre session, il sera indisponible.';
      case 'tr':
        return 'Saat doluysa veya başka oturum içindeyse kullanılamaz.';
      case 'ur':
        return 'اگر سلاٹ بھر گیا ہو یا کسی اور سیشن کا ہو تو دستیاب نہیں ہوگا۔';
      default:
        return 'If a slot is full or for another session, it will be unavailable.';
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

        final canCancel = slot.bookedByMe &&
            slot.start.isAfter(DateTime.now().add(const Duration(hours: 24)));
        final cancelLocked = slot.bookedByMe && !canCancel;

        final canJoinMeet = _canOpenMeetNow(slot);

        final shownSessionNo = slot.groupSessionNo ?? currentSession;
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
                          borderRadius:
                          BorderRadius.vertical(top: Radius.circular(24)),
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
                        color: actionOrange.withOpacity(0.10),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: actionOrange.withOpacity(0.25),
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
                      ? '$shownSessionNo / $totalSessions'
                      : '$shownSessionNo / $totalSessions • $topic',
                ),
                const SizedBox(height: 10),
                _sheetInfoRow(
                  icon: Icons.groups_rounded,
                  title: 'Group',
                  value: '${groupLine()} • Capacity ${slot.bookedCount}/$cap',
                ),
                const SizedBox(height: 14),
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
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: actionOrange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: canJoinMeet
                        ? () {
                      Navigator.pop(context);
                      _openExternalUrl(slot.meetUrl);
                    }
                        : null,
                    child: Text(
                      canJoinMeet
                          ? 'Join Google Meet'
                          : 'Join available near session time',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                if (!slot.bookedByMe) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                      joinable ? actionOrange : Colors.grey.shade400,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: (booking || !joinable)
                        ? null
                        : () async {
                      Navigator.pop(context);

                      final existing =
                      await _findMyNextBooking(courseId!);
                      final hasOther = existing != null &&
                          !(existing.dayKey == slot.dayKey &&
                              existing.time == slot.time);

                      final locked = existing != null &&
                          !existing.start.isAfter(
                            DateTime.now()
                                .add(const Duration(hours: 24)),
                          );

                      final label = (slot.bookedCount > 0 &&
                          slot.groupSessionNo == currentSession)
                          ? 'Join group'
                          : 'Book this slot';

                      final msg = hasOther
                          ? (locked
                          ? 'You already booked a class within 24 hours.\nYou can’t change it now.'
                          : 'You already booked a class.\nDo you want to change it to this slot?\n\nOld: ${_friendlyDate(existing.start)} ${existing.time}\nNew: ${_friendlyDate(slot.start)} ${slot.time}\n\nThis will join Session ${slot.groupSessionNo ?? currentSession} (${slot.bookedCount}/$cap).')
                          : 'Confirm booking?\n\n${_friendlyDate(slot.start)} at ${slot.time}\nTeacher: ${slot.teacherName}\n\nGroup: Session ${slot.groupSessionNo ?? currentSession}\nLearners: ${slot.bookedCount}/$cap';

                      if (hasOther && locked) {
                        _toast(
                            'You can’t change booking within 24 hours.');
                        return;
                      }

                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title:
                          Text(hasOther ? 'Change booking' : label),
                          content: Text(msg),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(context, false),
                              child: const Text('No'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(context, true),
                              child: Text(
                                  hasOther ? 'Yes, Change' : 'Yes'),
                            ),
                          ],
                        ),
                      );

                      if (ok == true) {
                        await _bookSlot(slot);
                      }
                    },
                    child: Text(
                      joinable
                          ? ((slot.bookedCount > 0 &&
                          slot.groupSessionNo == currentSession)
                          ? 'Join group'
                          : 'Book this slot')
                          : 'Unavailable',
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
                      backgroundColor:
                      cancelLocked ? Colors.grey.shade400 : Colors.red.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: (booking || !canCancel)
                        ? null
                        : () async {
                      Navigator.pop(context);

                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Cancel booking'),
                          content: const Text(
                            'Are you sure you want to cancel this booking?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(context, false),
                              child: const Text('No'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(context, true),
                              child: const Text('Yes, Cancel'),
                            ),
                          ],
                        ),
                      );

                      if (ok == true) {
                        await _cancelMyBooking(slot);
                      }
                    },
                    child: Text(
                      cancelLocked
                          ? 'Cancel disabled (within 24h)'
                          : 'Cancel booking',
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
        border: Border.all(color: uiBorder.withOpacity(0.85)),
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
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing,
          ],
        ],
      ),
    );
  }

  // ================== Filters UI ==================

  Widget _buildFiltersCard() {
    final Map<String, String> teacherIdToName = {};
    for (final s in generatedSlots) {
      teacherIdToName[s.teacherId] = s.teacherName;
    }
    final teacherIds = teacherIdToName.keys.toList()
      ..sort((a, b) =>
          (teacherIdToName[a] ?? '').compareTo(teacherIdToName[b] ?? ''));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => setState(() => filtersExpanded = !filtersExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, color: primaryBlue, size: 18),
                  const SizedBox(width: 8),
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
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: actionOrange.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: actionOrange.withOpacity(0.25),
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
                  const SizedBox(width: 10),
                  Icon(
                    filtersExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: primaryBlue,
                  ),
                ],
              ),
            ),
          ),
          if (filtersExpanded) ...[
            const Divider(height: 1, color: uiBorder),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Teacher',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: uiBorder.withOpacity(0.9)),
                    ),
                    child: DropdownButton<String>(
                      value: teacherFilter,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      icon: const Icon(
                        Icons.expand_more_rounded,
                        color: primaryBlue,
                      ),
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
                  const SizedBox(height: 12),
                  const Text(
                    'Time',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _chip(
                        'All day',
                        timeFilter == 'all',
                            () => setState(() => timeFilter = 'all'),
                      ),
                      _chip(
                        'Morning',
                        timeFilter == 'morning',
                            () => setState(() => timeFilter = 'morning'),
                      ),
                      _chip(
                        'Afternoon',
                        timeFilter == 'afternoon',
                            () => setState(() => timeFilter = 'afternoon'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _togglePill(
                        label: 'Only joinable',
                        value: onlyJoinable,
                        onChanged: (v) => setState(() => onlyJoinable = v),
                      ),
                      _togglePill(
                        label: 'Only peer groups',
                        value: onlyPeerGroups,
                        onChanged: (v) => setState(() => onlyPeerGroups = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _togglePill({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: uiBorder.withOpacity(0.9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: actionOrange,
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: on ? actionOrange.withOpacity(0.12) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: on
                ? actionOrange.withOpacity(0.35)
                : uiBorder.withOpacity(0.9),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: on ? actionOrange : primaryBlue,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _badge(
      String text, {
        required Color bg,
        Color fg = Colors.white,
        IconData? icon,
      }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 10,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  // ================== Compact header ==================

  Widget _buildCompactHeader() {
    final sessionInfo = curriculumSessions['$currentSession'];
    final sessionTitle = (sessionInfo is Map)
        ? (sessionInfo['sessionTitle'] ?? sessionInfo['title'] ?? '')
        .toString()
        .trim()
        : '';

    return Container(
      padding: const EdgeInsets.all(14),
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
          Text(
            sessionTitle.isEmpty
                ? 'Session $currentSession / $totalSessions'
                : 'Session $currentSession / $totalSessions • $sessionTitle',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: Colors.grey.shade800,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _smallActionButton(
                icon: Icons.help_outline_rounded,
                label: 'How booking works',
                onTap: _openHowBookingWorks,
              ),
              _smallActionButton(
                icon: Icons.menu_book_rounded,
                label: 'Session details',
                onTap: _openNextSessionDetails,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _smallActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: actionOrange.withOpacity(0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: actionOrange.withOpacity(0.25)),
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
  }

  Widget _buildQuickHints() {
    Widget pill(IconData icon, String text) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: uiBorder.withOpacity(0.9)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: primaryBlue),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: primaryBlue,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        pill(Icons.calendar_month_rounded, 'Tap a slot to book'),
        pill(Icons.groups_rounded, 'Join your session group'),
        pill(Icons.lock_clock_rounded, 'Change only before 24h'),
      ],
    );
  }

  // ================== Timetable ==================

  Widget _teacherMiniTile(_Slot s) {
    final cap = s.maxLearnersPerSlot <= 0 ? 6 : s.maxLearnersPerSlot;

    final bookedByMe = s.bookedByMe;
    final peerGroup = _isPeerGroup(s);
    final otherSession =
        (s.groupSessionNo != null && s.groupSessionNo != currentSession) &&
            !bookedByMe;
    final fullButMySession =
        !bookedByMe && s.groupSessionNo == currentSession && s.isFull;

    final bg = bookedByMe
        ? bookedBg
        : peerGroup
        ? peerBg
        : otherSession || fullButMySession
        ? otherSessionBg
        : emptyBg;

    final border = bookedByMe
        ? bookedBorder
        : peerGroup
        ? peerBorder
        : otherSession || fullButMySession
        ? otherSessionBorder
        : emptyBorder;

    String topLabel;
    if (bookedByMe) {
      topLabel = 'Booked';
    } else if (peerGroup) {
      topLabel = 'Join group';
    } else if (fullButMySession) {
      topLabel = 'Full';
    } else if (otherSession) {
      topLabel = 'Session ${s.groupSessionNo}';
    } else {
      topLabel = 'Book';
    }

    final countText = '${s.bookedCount}/$cap';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _onSlotTap(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    topLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.teacherName,
                    maxLines: 1,
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
            const SizedBox(width: 6),
            if (bookedByMe)
              _badge(countText, bg: const Color(0xFF2F9E44))
            else if (peerGroup)
              _badge(
                countText,
                bg: actionOrange,
                icon: Icons.groups_rounded,
              )
            else if (otherSession || fullButMySession)
                _badge(countText, bg: Colors.grey.shade600)
              else
                _badge(countText, bg: Colors.grey.shade800),
          ],
        ),
      ),
    );
  }

  Widget _buildTimetable(List<_Slot> rawSlots) {
    final slots = _applyFilters(rawSlots);

    final days = _nextDays(timetableDays);
    final times = _uniqueTimes(slots);

    final Map<String, List<_Slot>> index = {};
    for (final s in slots) {
      index.putIfAbsent(s.key, () => <_Slot>[]).add(s);
    }

    for (final k in index.keys) {
      index[k]!.sort((a, b) => a.teacherName.compareTo(b.teacherName));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(width: 84),
              ...days.map((d) {
                return Container(
                  width: 164,
                  padding:
                  const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: uiBorder.withOpacity(0.8)),
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
            ],
          ),
          const SizedBox(height: 8),
          if (times.isEmpty)
            Container(
              width: 94.0 + (164.0 * timetableDays),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: uiBorder.withOpacity(0.85)),
              ),
              child: const Text(
                'No slots match your filters.',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ...times.map((t) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 84,
                    padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                    child: Text(
                      t,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: primaryBlue,
                      ),
                    ),
                  ),
                  ...days.map((d) {
                    final dk = _dateKey(d);
                    final key = '$dk|$t';
                    final list = index[key] ?? const <_Slot>[];

                    final hasSlot = list.isNotEmpty;

                    return Container(
                      width: 164,
                      constraints: const BoxConstraints(minHeight: 72),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: hasSlot ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: hasSlot
                              ? uiBorder.withOpacity(0.85)
                              : uiBorder.withOpacity(0.25),
                        ),
                      ),
                      child: hasSlot
                          ? Column(
                        children: [
                          for (int i = 0;
                          i < (list.length > 2 ? 2 : list.length);
                          i++) ...[
                            _teacherMiniTile(list[i]),
                            if (i !=
                                (list.length > 2
                                    ? 1
                                    : list.length - 1))
                              const SizedBox(height: 8),
                          ],
                          if (list.length > 2) ...[
                            const SizedBox(height: 6),
                            Text(
                              '+${list.length - 2} more',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ],
                      )
                          : const SizedBox.shrink(),
                    );
                  }).toList(),
                ],
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  // ================== UI ==================

  @override
  Widget build(BuildContext context) {
    final cid = courseId;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Book Your Class',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'How booking works',
            onPressed: _openHowBookingWorks,
            icon: const Icon(Icons.help_outline_rounded, color: primaryBlue),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: (loading || booking || cid == null)
                ? null
                : () async {
              await _loadReservationsSummary(cid);
              await _generateSlots(cid);
            },
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : (cid == null)
          ? const Center(child: Text('No course selected.'))
          : ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _buildCompactHeader(),
          const SizedBox(height: 10),
          _buildQuickHints(),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Schedule',
            subtitle: 'Tap a slot to book or join a group',
            trailing: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () =>
                  setState(() => filtersExpanded = !filtersExpanded),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: uiBorder.withOpacity(0.9),
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
                      filtersExpanded ? 'Hide filters' : 'Filters',
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
            child: generatedSlots.isEmpty
                ? const Text(
              'No available slots found.\nAsk your teacher to set availability for this course.',
              style: TextStyle(fontWeight: FontWeight.w800),
            )
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (filtersExpanded) ...[
                  _buildFiltersCard(),
                  const SizedBox(height: 12),
                ],
                _buildTimetable(generatedSlots),
              ],
            ),
          ),
          if (booking)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
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
      'Dec'
    ];
    final wd = days[d.weekday - 1];
    final mo = months[d.month - 1];
    return '$wd, ${_two(d.day)} $mo';
  }
}

// ================== Models ==================

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

  String get key => '$dayKey|$time';

  bool get isFull {
    final cap = maxLearnersPerSlot <= 0 ? 6 : maxLearnersPerSlot;
    return bookedCount >= cap;
  }
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
    required this.child,
    this.subtitle,
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
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: primaryBlue,
                      ),
                    ),
                    if (subtitle != null) ...[
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
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}