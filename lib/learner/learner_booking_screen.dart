// ✅ FULL REPLACEMENT: lib/learner/learner_booking_screen.dart
//
// Keeps your booking logic + timetable UI.
// ✅ Adds "group booking by same session level":
//    - A slot can have multiple learners, BUT ONLY for the SAME sessionNo.
//    - If first learner books (Session 2/18), the slot becomes a "Session 2 group slot".
//    - Other learners on Session 2 can join it (until capacity).
//    - Learners on other sessions see it as "Session X" (not joinable).
//
// ✅ Adds visual effects + filters:
//    - "Join peers" slots (same session + already has learners) are highlighted and show a 👥 badge.
//    - Filters:
//       • Only joinable
//       • Only peer groups
//
// ✅ FIX (Option A): show ALL teachers if multiple teachers share the same day+time
//    - Each grid cell can contain multiple teacher cards (tap one to open details).
//
// ✅ Capacity:
//    - Reads optional maxLearnersPerSlot from booking_availability/<teacherId>/<courseId>/maxLearnersPerSlot
//    - Fallback is 6.
//
// Data expected (per teacher per course):
// booking_availability/<teacherId>/<courseId>/
//   teacherName: "Mr X" (optional)
//   meetUrl: "https://meet.google.com/xxx-xxxx-xxx" (optional)
//   durationMinutes: 60 (optional)
//   maxLearnersPerSlot: 6 (optional)
//   week/mon: ["10:00", "11:00"]
//
// Notes:
// - If meetUrl missing → Join button hidden/disabled.
// - Join is allowed only within:
//   10 min before start  →  (duration + 15 min) after start.

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';

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

  // Group visuals
  static const peerBg = Color(0xFFE9F4FF); // light blue
  static const peerBorder = Color(0xFF9BC8FF);
  static const otherSessionBg = Color(0xFFF1F3F5); // light grey
  static const otherSessionBorder = Color(0xFFCED4DA);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // ✅ (optional) classId inference (safe even if unused for now)
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
  Map<String, dynamic> curriculumSessions = {}; // "1": {...}

  // Progress
  int currentSession = 1;

  // Slots window / schedule
  int daysAhead = 14; // used for reservations scan + "has booking"
  static const int timetableDays = 7; // UI schedule (week view)
  List<_Slot> generatedSlots = [];

  // My bookings map: "yyyy-mm-dd|HH:MM" -> sessionNo
  Map<String, int> myBookedSlots = {};

  // Slot group summary (any learner): "yyyy-mm-dd|HH:MM" -> {_SlotSummary}
  Map<String, _SlotSummary> slotSummary = {};

  // Filters (simple, non-clutter)
  String teacherFilter = 'all'; // teacherId or "all"
  String timeFilter = 'all'; // all | morning | afternoon
  bool onlyJoinable = false; // hide slots learner cannot join
  bool onlyPeerGroups = false; // show only slots where my session already has peers

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

  bool _toBool(dynamic v) {
    if (v == true) return true;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  DatabaseReference _curriculumRef(String cid) => _db.child('booking_curriculum/$cid');
  DatabaseReference _availabilityRootRef() => _db.child('booking_availability');
  DatabaseReference _syllabiRef(String cid) => _db.child('syllabi/$cid');
  DatabaseReference _progressRef(String cid) => _db.child('booking_progress/$myUid/$cid');
  DatabaseReference _reservationsRootRef(String cid) => _db.child('booking_reservations/$cid');
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
    final openUntil = slot.start.add(Duration(minutes: dur)).add(const Duration(minutes: 15));

    return now.isAfter(openFrom) && now.isBefore(openUntil);
  }

  // ✅ joinable rules:
  // - if I already booked => joinable (for meet/cancel rules)
  // - if slot has no group yet => joinable (start my session group)
  // - if slot group is same session as me => joinable (until full)
  // - otherwise not joinable
  bool _isJoinable(_Slot s) {
    if (s.bookedByMe) return true;
    if (s.groupSessionNo == null) return true;
    if (s.groupSessionNo != currentSession) return false;
    if (s.isFull) return false;
    return true;
  }

  bool _isPeerGroup(_Slot s) {
    return (s.groupSessionNo == currentSession) && (s.bookedCount > 0) && !s.bookedByMe && !s.isFull;
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

    // ✅ Gate by booking_config/courses/<courseId>
    final gate = await _bookingGateForCourse(courseId!);
    if (!gate.enabled) {
      setState(() => loading = false);
      _toast('Booking is not enabled for this course yet.');
      return;
    }

    // prefer title/total from booking_config
    if (gate.title.isNotEmpty) courseTitle = gate.title;
    if (gate.totalSessions > 0) totalSessions = gate.totalSessions;

    // optional curriculum (titles/details)
    await _loadCurriculum(courseId!);

    await _loadOrCreateProgress(courseId!);

    // ✅ optional classId inference (safe)
    _classId = await _inferClassIdForCourse(courseId!);

    // ✅ Load reservations summary + my bookings first, then generate slots
    await _loadReservationsSummary(courseId!);
    await _generateSlots(courseId!);

    if (!mounted) return;
    setState(() => loading = false);
  }

  /// Tries common places where apps store learner current course/level.
  /// IMPORTANT: We DO NOT return map keys like "course_1/course_2".
  /// We only return REAL ids stored inside each course object: id / courseId.

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

        final id = (m['id'] ?? m['courseId'] ?? m['course_id'] ?? '').toString().trim();
        final variantKey = (m['variantKey'] ?? m['variant'] ?? '').toString().trim().toLowerCase();

        if (id.isNotEmpty && variantKey == 'online') {
          return id;
        }
      }
    } catch (_) {}

    return null;
  }

  Future<String> _inferClassIdForCourse(String cid) async {
    // Finds the class where:
    // - classes/<classId>/course_id == cid (or variants)
    // - and learner is in classes/<classId>/learners/<myUid>
    try {
      final snap = await _db.child('classes').get();
      if (!snap.exists || snap.value is! Map) return '';

      final all = Map<dynamic, dynamic>.from(snap.value as Map);

      for (final entry in all.entries) {
        final classId = entry.key.toString();
        final val = entry.value;
        if (val is! Map) continue;

        final c = val.map((k, v) => MapEntry(k.toString(), v));
        final courseIdAny = (c['course_id'] ?? c['courseId'] ?? c['course'] ?? '').toString().trim();
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
      final snap = await _db.child('syllabi/$cid/online').get();

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
          source: 'syllabi/online',
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

  // ================== Load Curriculum (optional titles/details) ==================



  Future<void> _loadCurriculum(String cid) async {
    try {
      final snap = await _db.child('syllabi/$cid/online').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

      final root = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));

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
              'source': 'syllabi/online',
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
      _toast('Failed to load online syllabus: $e');
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

  // ================== Load Reservations Summary (group counts + my bookings) ==================

  Future<void> _loadReservationsSummary(String cid) async {
    final now = DateTime.now();
    final Map<String, int> mine = {};
    final Map<String, _SlotSummary> summary = {};

    try {
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
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

          final learners = learnersRaw.map((k, vv) => MapEntry(k.toString(), vv));
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
        final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
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

          if (best == null || candidate.start.isBefore(best.start)) best = candidate;
        }
      }
    } catch (_) {}

    return best;
  }

  // ================== Availability -> Upcoming Slots ==================
  //
  // booking_availability/<teacherId>/<courseId>/week/<weekday> = ["HH:MM", ...]
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

        final perCourse = tn[cid];
        if (perCourse is! Map) continue;

        final effective = perCourse.map((k, vv) => MapEntry(k.toString(), vv));

        final resolvedTeacherName =
        (effective['teacherName'] ??
            effective['teacher_name'] ??
            tn['teacherName'] ??
            tn['teacher_name'] ??
            '')
            .toString()
            .trim();

        // ✅ Meet + Duration (per teacher+course)
        final meetUrl = (effective['meetUrl'] ??
            effective['meet_url'] ??
            effective['googleMeetUrl'] ??
            effective['google_meet_url'] ??
            '')
            .toString()
            .trim();

        int durationMin = _toInt(effective['durationMinutes'], fallback: 0);
        if (durationMin <= 0) durationMin = _toInt(effective['durationMin'], fallback: 0);
        if (durationMin <= 0) durationMin = 60;

        // ✅ Capacity (optional)
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
            teacherName: resolvedTeacherName.isEmpty ? 'Teacher' : resolvedTeacherName,
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
        final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
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

        // keep filter valid
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

  // ================== Booking (Group by session + Switch-enabled) ==================

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

    // ✅ quick joinability check (prevents bad transactions)
    if (!_isJoinable(slot)) {
      if (slot.groupSessionNo != null && slot.groupSessionNo != currentSession) {
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

      // If already booked THIS slot, just tell them.
      if (existing != null && existing.dayKey == slot.dayKey && existing.time == slot.time) {
        _toast('You already booked this slot ✅');
        return;
      }

      // If has another booking, we allow switch (only if cancellable)
      if (existing != null) {
        final locked = !existing.start.isAfter(DateTime.now().add(const Duration(hours: 24)));
        if (locked) {
          _toast('You already booked a class and it’s within 24 hours, so you can’t change it.');
          return;
        }

        // cancel old first
        final okCancel = await _cancelBookingByKey(cid, existing.dayKey, existing.time);
        if (!okCancel) {
          _toast('Could not change booking (cancel failed).');
          return;
        }
      }

      final ref = _reservationsRef(cid, slot.dayKey, slot.time);

      // ✅ pre-read for better messages
      final pre = await ref.get();
      int? existingGroupSession;
      int existingCount = 0;

      if (pre.exists && pre.value is Map) {
        final m = (pre.value as Map).map((k, v) => MapEntry(k.toString(), v));
        existingGroupSession = _toInt(m['sessionNo'], fallback: 0);
        if (existingGroupSession != null && existingGroupSession <= 0) existingGroupSession = null;

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

      // session mismatch
      if (existingGroupSession != null && existingGroupSession != currentSession) {
        _toast('This slot is a Session $existingGroupSession group. You are on Session $currentSession.');
        return;
      }

      // capacity
      final maxCap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
      if (existingCount >= maxCap) {
        _toast('This slot is full ($maxCap learners).');
        return;
      }

      // ✅ transactional join (enforces same session + capacity)
      final tx = await ref.runTransaction((Object? currentData) {
        final Map<String, dynamic> node =
        (currentData is Map) ? currentData.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};

        final Map<String, dynamic> learners = <String, dynamic>{};
        final existingLearners = node['learners'];
        if (existingLearners is Map) {
          learners.addAll(existingLearners.map((k, v) => MapEntry(k.toString(), v)));
        }

        // already joined
        if (learners.containsKey(myUid)) {
          return Transaction.abort();
        }

        // capacity check
        final cap = maxCap;
        if (learners.length >= cap) {
          return Transaction.abort();
        }

        // group session rule:
        // - if slot already has sessionNo, it must match currentSession
        final groupSessionNo = _toInt(node['sessionNo'], fallback: 0);
        if (groupSessionNo > 0 && groupSessionNo != currentSession) {
          return Transaction.abort();
        }

        learners[myUid] = true;

        // set group session if first join
        node['teacherId'] = slot.teacherId;
        node['teacherName'] = slot.teacherName;
        node['sessionNo'] = currentSession;
        node['learners'] = learners;
        node['createdAt'] = ServerValue.timestamp;

        return Transaction.success(node);
      });

      if (!tx.committed) {
        _toast('Could not join. The slot may be full or became a different session group.');
        return;
      }

      final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;
      final newCount = (existingCount + 1);
      if (existingCount == 0) {
        _toast('Booked ✅ Started Session $currentSession group');
      } else {
        _toast('Joined ✅ Session $currentSession group ($newCount/$cap)');
      }

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

      // ✅ 24h rule enforced
      final locked = !start.isAfter(DateTime.now().add(const Duration(hours: 24)));
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
          return Transaction.success(null); // delete slot if empty
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

    final locked = !slot.start.isAfter(DateTime.now().add(const Duration(hours: 24)));
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
    for (final s in slots) set.add(s.time);

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
    return List.generate(count, (i) => DateTime(now.year, now.month, now.day).add(Duration(days: i)));
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
    final title = rawTitle.isEmpty ? 'Session $currentSession' : 'Session $currentSession — $rawTitle';
    final objective = (m['objective'] ?? '').toString().trim();
    final content = (m['content'] ?? '').toString().trim();
    final homework = (m['homework'] ?? '').toString().trim();
    final duration = _toInt(m['durationMinutes'], fallback: 0);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: primaryBlue)),
                  const SizedBox(height: 8),
                  _kv('Session', '$currentSession / $totalSessions'),
                  if (duration > 0) _kv('Duration', '$duration min'),
                  const SizedBox(height: 10),
                  if (objective.isNotEmpty) ...[
                    const Text('Objectives', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(objective, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey)),
                    const SizedBox(height: 12),
                  ],
                  if (content.isNotEmpty) ...[
                    const Text('Content', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(content, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey)),
                    const SizedBox(height: 12),
                  ],
                  if (homework.isNotEmpty) ...[
                    const Text('Homework', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(homework, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey)),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: actionOrange,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w900)),
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
          Expanded(child: Text(k, style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700))),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
        ],
      ),
    );
  }

  // ================== Slot tap -> details sheet ==================

  Future<void> _onSlotTap(_Slot slot) async {
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;

        final canCancel = slot.bookedByMe && slot.start.isAfter(DateTime.now().add(const Duration(hours: 24)));
        final cancelLocked = slot.bookedByMe && !canCancel;

        final canJoinMeet = _canOpenMeetNow(slot);

        final shownSessionNo = slot.groupSessionNo ?? currentSession;
        final topic = _sessionTitleFor(shownSessionNo);

        final joinable = _isJoinable(slot);
        final peerGroup = _isPeerGroup(slot);
        final cap = slot.maxLearnersPerSlot <= 0 ? 6 : slot.maxLearnersPerSlot;

        String groupLine() {
          if (slot.bookedCount <= 0) {
            return 'No one booked yet — be the first for Session $currentSession';
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
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: primaryBlue),
                ),
                const SizedBox(height: 6),
                Text('Teacher: ${slot.teacherName}', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
                const SizedBox(height: 6),
                Text(
                  topic.isEmpty
                      ? 'Session group: $shownSessionNo / $totalSessions'
                      : 'Session group: $shownSessionNo / $totalSessions — $topic',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                const SizedBox(height: 6),
                Text(
                  'Group: ${groupLine()}  •  Capacity: ${slot.bookedCount}/$cap',
                  style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 6),
                if (peerGroup)
                  Text(
                    '👥 Your peers are here — join them!',
                    style: TextStyle(fontWeight: FontWeight.w900, color: actionOrange.withOpacity(0.95)),
                  ),
                const SizedBox(height: 12),

                // Meet button (only meaningful if bookedByMe)
                if (slot.bookedByMe && slot.meetUrl.trim().isNotEmpty) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: actionOrange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: canJoinMeet
                        ? () {
                      Navigator.pop(context);
                      _openExternalUrl(slot.meetUrl);
                    }
                        : null,
                    child: Text(
                      canJoinMeet ? 'Join Google Meet' : 'Join available near session time',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                if (!slot.bookedByMe) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: joinable ? actionOrange : Colors.grey.shade400,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: (booking || !joinable)
                        ? null
                        : () async {
                      Navigator.pop(context);

                      // If learner already has a booking, offer switch
                      final existing = await _findMyNextBooking(courseId!);
                      final hasOther =
                          existing != null && !(existing.dayKey == slot.dayKey && existing.time == slot.time);

                      final locked = existing != null &&
                          !existing.start.isAfter(DateTime.now().add(const Duration(hours: 24)));

                      final label = (slot.bookedCount > 0 && slot.groupSessionNo == currentSession)
                          ? 'Join group'
                          : 'Book / Start group';

                      final msg = hasOther
                          ? (locked
                          ? 'You already booked a class within 24 hours.\nYou can’t change it now.'
                          : 'You already booked a class.\nDo you want to change it to this slot?\n\nOld: ${_friendlyDate(existing.start)} ${existing.time}\nNew: ${_friendlyDate(slot.start)} ${slot.time}\n\nThis will join Session ${slot.groupSessionNo ?? currentSession} (${slot.bookedCount}/$cap).')
                          : 'Confirm?\n\n${_friendlyDate(slot.start)} at ${slot.time}\nTeacher: ${slot.teacherName}\n\nGroup: Session ${slot.groupSessionNo ?? currentSession}\nLearners: ${slot.bookedCount}/$cap';

                      if (hasOther && locked) {
                        _toast('You can’t change booking within 24 hours.');
                        return;
                      }

                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text(hasOther ? 'Change booking' : label),
                          content: Text(msg),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(hasOther ? 'Yes, Change' : 'Yes'),
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
                          ? ((slot.bookedCount > 0 && slot.groupSessionNo == currentSession) ? 'Join peers' : 'Book this slot')
                          : 'Not joinable (different session / full)',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF7EE),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: uiBorder.withOpacity(0.7)),
                    ),
                    child: Text(
                      'You’re in this group ✅  (${slot.bookedCount}/$cap learners)',
                      style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: cancelLocked ? Colors.grey.shade400 : Colors.red.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                          content: const Text('Are you sure you want to cancel this booking?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes, Cancel')),
                          ],
                        ),
                      );

                      if (ok == true) {
                        await _cancelMyBooking(slot);
                      }
                    },
                    child: Text(
                      cancelLocked ? 'Cancel disabled (within 24h)' : 'Cancel booking',
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

  // ================== Timetable UI ==================

  Widget _buildLegend() {
    Widget pill(Color c, String t, {Color? border}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border ?? uiBorder.withOpacity(0.6)),
        ),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: primaryBlue)),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        pill(const Color(0xFFFFF1E3), 'Empty (start group)'),
        pill(peerBg, 'Peers (join group)', border: peerBorder),
        pill(const Color(0xFFEAF7EE), 'Your booking'),
        pill(otherSessionBg, 'Other session', border: otherSessionBorder),
      ],
    );
  }

  Widget _buildFilters() {
    // teacher list from generated slots
    final Map<String, String> teacherIdToName = {};
    for (final s in generatedSlots) {
      teacherIdToName[s.teacherId] = s.teacherName;
    }
    final teacherIds = teacherIdToName.keys.toList()
      ..sort((a, b) => (teacherIdToName[a] ?? '').compareTo(teacherIdToName[b] ?? ''));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Teacher dropdown
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
            icon: const Icon(Icons.expand_more_rounded, color: primaryBlue),
            items: [
              const DropdownMenuItem(value: 'all', child: Text('All teachers')),
              ...teacherIds.map((id) {
                final name = teacherIdToName[id] ?? 'Teacher';
                return DropdownMenuItem(value: id, child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis));
              }),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => teacherFilter = v);
            },
          ),
        ),
        const SizedBox(height: 10),

        // Time chips + joinable toggles
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _chip('All day', timeFilter == 'all', () => setState(() => timeFilter = 'all')),
            _chip('Morning', timeFilter == 'morning', () => setState(() => timeFilter = 'morning')),
            _chip('Afternoon', timeFilter == 'afternoon', () => setState(() => timeFilter = 'afternoon')),
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
    );
  }

  Widget _togglePill({required String label, required bool value, required ValueChanged<bool> onChanged}) {
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
          Text(label, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 12)),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged, activeColor: actionOrange),
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
          border: Border.all(color: on ? actionOrange.withOpacity(0.35) : uiBorder.withOpacity(0.9)),
        ),
        child: Text(
          label,
          style: TextStyle(fontWeight: FontWeight.w900, color: on ? actionOrange : primaryBlue, fontSize: 12),
        ),
      ),
    );
  }

  Widget _badge(String text, {Color bg = Colors.black, Color fg = Colors.white, IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(text, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 10, color: fg)),
        ],
      ),
    );
  }

  // ✅ mini card for each teacher INSIDE a single timetable cell
  Widget _teacherMiniTile(_Slot s) {
    final cap = s.maxLearnersPerSlot <= 0 ? 6 : s.maxLearnersPerSlot;

    final bookedByMe = s.bookedByMe;
    final peerGroup = _isPeerGroup(s);
    final otherSession = (s.groupSessionNo != null && s.groupSessionNo != currentSession) && !bookedByMe;

    final bg = bookedByMe
        ? const Color(0xFFEAF7EE)
        : peerGroup
        ? peerBg
        : otherSession
        ? otherSessionBg
        : const Color(0xFFFFF1E3);

    final border = bookedByMe
        ? const Color(0xFFB9E2C5)
        : peerGroup
        ? peerBorder
        : otherSession
        ? otherSessionBorder
        : const Color(0xFFF9C59D);

    String topLabel;
    if (bookedByMe) {
      topLabel = 'You’re in';
    } else if (peerGroup) {
      topLabel = 'Join peers';
    } else if (otherSession) {
      topLabel = 'Session ${s.groupSessionNo}';
    } else {
      topLabel = 'Start group';
    }

    final countText = '${s.bookedCount}/$cap';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _onSlotTap(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    topLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.teacherName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (bookedByMe)
              _badge(countText, bg: const Color(0xFF2F9E44))
            else if (peerGroup)
              _badge(countText, bg: actionOrange, icon: Icons.groups_rounded)
            else if (otherSession)
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

    // ✅ FIX: index dayKey|time -> List<_Slot> (multiple teachers per cell)
    final Map<String, List<_Slot>> index = {};
    for (final s in slots) {
      index.putIfAbsent(s.key, () => <_Slot>[]).add(s);
    }

    // stable order inside a cell (by teacher name)
    for (final k in index.keys) {
      index[k]!.sort((a, b) => a.teacherName.compareTo(b.teacherName));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              const SizedBox(width: 86), // left time column
              ...days.map((d) {
                return Container(
                  width: 160,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: uiBorder.withOpacity(0.8)),
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white,
                  ),
                  child: Text(
                    _friendlyDate(d),
                    style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 12),
                  ),
                );
              }).toList(),
            ],
          ),
          const SizedBox(height: 8),

          if (times.isEmpty)
            Container(
              width: 94.0 + (160.0 * timetableDays),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: uiBorder.withOpacity(0.85)),
              ),
              child: const Text('No slots match your filters.', style: TextStyle(fontWeight: FontWeight.w900)),
            ),

          // Grid
          ...times.map((t) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // time label
                  Container(
                    width: 86,
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                    child: Text(t, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                  ),
                  ...days.map((d) {
                    final dk = _dateKey(d);
                    final key = '$dk|$t';
                    final list = index[key] ?? const <_Slot>[];

                    final hasSlot = list.isNotEmpty;

                    // cell frame is neutral; inside we show per-teacher tiles
                    return Container(
                      width: 160,
                      constraints: const BoxConstraints(minHeight: 72),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: hasSlot ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: hasSlot ? uiBorder.withOpacity(0.85) : uiBorder.withOpacity(0.25)),
                      ),
                      child: hasSlot
                          ? Column(
                        children: [
                          // show up to 2 teacher tiles for readability
                          for (int i = 0; i < (list.length > 2 ? 2 : list.length); i++) ...[
                            _teacherMiniTile(list[i]),
                            if (i != (list.length > 2 ? 1 : list.length - 1)) const SizedBox(height: 8),
                          ],
                          if (list.length > 2) ...[
                            const SizedBox(height: 6),
                            Text(
                              '+${list.length - 2} more teachers',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11, color: Colors.grey.shade700),
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

    final sessionInfo = curriculumSessions['$currentSession'];
    final sessionTitle =
    (sessionInfo is Map) ? (sessionInfo['sessionTitle'] ?? sessionInfo['title'] ?? '').toString() : '';

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text('Book Your Class', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
        actions: [
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
          const SizedBox(width: 6),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : (cid == null)
          ? const Center(child: Text('No course selected.'))
          : ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Card(
            title: courseTitle.isEmpty ? 'Course' : courseTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Your current session: $currentSession / $totalSessions',
                        style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: _openNextSessionDetails,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: actionOrange.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: actionOrange.withOpacity(0.25)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.info_outline_rounded, size: 16, color: actionOrange),
                            SizedBox(width: 6),
                            Text('Details',
                                style: TextStyle(fontWeight: FontWeight.w900, color: actionOrange, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  sessionTitle.isEmpty ? 'Session title not found (curriculum optional)' : sessionTitle,
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 10),
                _buildLegend(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Card(
            title: 'Schedule (tap a slot)',
            child: generatedSlots.isEmpty
                ? const Text(
              'No available slots found.\nAsk your teacher to set availability for this course.',
              style: TextStyle(fontWeight: FontWeight.w800),
            )
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildFilters(),
                const SizedBox(height: 12),
                _buildTimetable(generatedSlots),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (booking)
            const Padding(
              padding: EdgeInsets.only(top: 10),
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
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
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
  final String dayKey; // yyyy-mm-dd
  final String time; // HH:MM
  final DateTime start;
  final String teacherId;
  final String teacherName;

  final String meetUrl;
  final int durationMinutes;

  final int maxLearnersPerSlot;

  final bool bookedByMe;
  final int bookedCount;
  final int? groupSessionNo; // session this slot is grouped for

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

// ================== Small UI helper ==================

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

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
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}