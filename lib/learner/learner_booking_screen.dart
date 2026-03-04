// ✅ FULL REPLACEMENT: lib/learner/learner_booking_screen.dart
//
// Includes your 6 requests + fixes the “already booked” change problem:
//
// 1) ✅ Timetable grid (days columns, times rows)
// 2) ✅ Tap slot → details popup (bottom sheet)
// 3) ✅ Confirmation dialog before booking
// 4) ✅ Learner cannot cancel within 24H (UI + logic enforced)
// 5) ✅ Booked sessions (by this learner) are colored differently
// 6) ✅ Notification hook placeholder (commented)
//
// EXTRA FIXES (from your problem list):
// ✅ (3) If learner already booked, allow “Change booking” (switch to another slot)
//    - Only if the existing booking is >24h away.
// ✅ (4) Bottom sheet buttons won’t be covered by phone bottom bar (SafeArea + padding).
// ✅ (5) Next required session shows a (!) button → opens session details sheet.
// ✅ (6) Simple schedule filters (teacher + time of day + available-only) without clutter.
//
// Keeps your important booking logic:
// - booking_config gate: booking_config/courses/<courseId>/enabled
// - curriculum optional
// - progress currentSession
// - reservation transaction + prevent duplicate booking
// - prevents duplicate booking in same slot
// - “already has booking” now becomes “offer switch” instead of hard block

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

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

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

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

  // Filters (simple, non-clutter)
  String teacherFilter = 'all'; // teacherId or "all"
  String timeFilter = 'all'; // all | morning | afternoon
  bool onlyAvailable = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  // ================== Helpers ==================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
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
  DatabaseReference _progressRef(String cid) => _db.child('booking_progress/$myUid/$cid');
  DatabaseReference _reservationsRootRef(String cid) => _db.child('booking_reservations/$cid');
  DatabaseReference _reservationsRef(String cid, String dayKey, String hhmm) => _db.child('booking_reservations/$cid/$dayKey/$hhmm');

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

    // ✅ Load my bookings first so generated slots can be marked "bookedByMe"
    await _loadMyBookingsForWindow(courseId!);
    await _generateSlots(courseId!);

    if (!mounted) return;
    setState(() => loading = false);
  }

  /// Tries common places where apps store learner current course/level.
  /// IMPORTANT: We DO NOT return map keys like "course_1/course_2".
  /// We only return REAL ids stored inside each course object: id / courseId.
  Future<String?> _inferLearnerCourseId() async {
    try {
      final snap = await _db.child('users/$myUid').get();
      final v = snap.value;
      if (v is! Map) return null;

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));

      final direct = (m['courseId'] ?? '').toString().trim();
      if (direct.isNotEmpty) return direct;

      final current = (m['currentCourseId'] ?? '').toString().trim();
      if (current.isNotEmpty) return current;

      final courses = m['courses'];

      // Map pattern users/<uid>/courses/course_1/{id: REALID}
      if (courses is Map) {
        final cm = courses.map((k, vv) => MapEntry(k.toString(), vv));
        for (final entry in cm.values) {
          if (entry is Map) {
            final em = entry.map((k, vv) => MapEntry(k.toString(), vv));
            final id = (em['id'] ?? em['courseId'] ?? em['course_id'] ?? '').toString().trim();
            if (id.isNotEmpty) return id;
          } else if (entry is String) {
            final s = entry.trim();
            if (s.isNotEmpty && !s.startsWith('course_')) return s;
          }
        }
      }

      // List pattern
      if (courses is List && courses.isNotEmpty) {
        for (final item in courses) {
          if (item is String && item.trim().isNotEmpty) return item.trim();
          if (item is Map) {
            final fm = item.map((k, vv) => MapEntry(k.toString(), vv));
            final id = (fm['id'] ?? fm['courseId'] ?? fm['course_id'] ?? '').toString().trim();
            if (id.isNotEmpty) return id;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ================== Booking Gate ==================

  Future<_BookingGate> _bookingGateForCourse(String cid) async {
    // ✅ Preferred: booking_config/courses/<courseId>
    try {
      final snap = await _db.child('booking_config/courses/$cid').get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

        return _BookingGate(
          enabled: _toBool(m['enabled']),
          totalSessions: _toInt(m['totalLessons'], fallback: 0),
          title: (m['title'] ?? '').toString().trim(),
          source: 'booking_config/courses',
        );
      }
    } catch (_) {}

    // Fallback: booking_curriculum/<courseId> (enabled if totalSessions > 0)
    try {
      final snap = await _db.child('booking_curriculum/$cid').get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final total = _toInt(m['totalSessions'], fallback: 0);

        return _BookingGate(
          enabled: total > 0,
          totalSessions: total,
          title: (m['courseTitle'] ?? '').toString().trim(),
          source: 'booking_curriculum',
        );
      }
    } catch (_) {}

    return const _BookingGate(enabled: false, totalSessions: 0, title: '', source: 'none');
  }

  // ================== Load Curriculum (optional titles/details) ==================

  Future<void> _loadCurriculum(String cid) async {
    try {
      final snap = await _curriculumRef(cid).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

      final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));

      final t = (m['courseTitle'] ?? '').toString().trim();
      if (courseTitle.isEmpty && t.isNotEmpty) courseTitle = t;

      final ts = _toInt(m['totalSessions'], fallback: 0);
      if (totalSessions <= 0 && ts > 0) totalSessions = ts;

      final sess = m['sessions'];
      if (sess is Map) {
        curriculumSessions = sess.map((k, vv) => MapEntry(k.toString(), vv));
      } else {
        curriculumSessions = {};
      }
    } catch (e) {
      _toast('Failed to load curriculum: $e');
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

  // ================== Load My Bookings (for coloring + cancel/switch) ==================

  Future<void> _loadMyBookingsForWindow(String cid) async {
    final now = DateTime.now();
    final Map<String, int> out = {};

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
          final learners = sm['learners'];
          if (learners is Map) {
            final lm = learners.map((k, vv) => MapEntry(k.toString(), vv));
            if (lm.containsKey(myUid)) {
              final sessionNo = _toInt(sm['sessionNo'], fallback: 0);
              out['$dk|$hhmm'] = sessionNo <= 0 ? currentSession : sessionNo;
            }
          }
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() => myBookedSlots = out);
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

          if (best == null || candidate.start.isBefore(best.start)) {
            best = candidate;
          }
        }
      }
    } catch (_) {}

    return best;
  }

  // ================== Availability -> Upcoming Slots ==================
  //
  // Strict per-course availability:
  // booking_availability/<teacherId>/<courseId>/week/<weekday> = ["HH:MM", ...]
  Future<void> _generateSlots(String cid) async {
    setState(() => generatedSlots = []);
    final now = DateTime.now();

    try {
      final snap = await _availabilityRootRef().get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

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
        (effective['teacherName'] ?? effective['teacher_name'] ?? tn['teacherName'] ?? tn['teacher_name'] ?? '')
            .toString()
            .trim();

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
            final bookedSessionNo = myBookedSlots[slotKey];

            out.add(
              _Slot(
                courseId: cid,
                dayKey: dayKey,
                time: hhmm,
                start: start,
                teacherId: t.teacherId,
                teacherName: t.teacherName,
                bookedByMe: bookedSessionNo != null,
                bookedSessionNo: bookedSessionNo,
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

  // ================== Booking (Switch-enabled) ==================

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

      await ref.runTransaction((Object? currentData) {
        final Map<String, dynamic> node =
        (currentData is Map) ? currentData.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};

        final Map<String, dynamic> learners = <String, dynamic>{};
        final existingLearners = node['learners'];
        if (existingLearners is Map) {
          learners.addAll(existingLearners.map((k, v) => MapEntry(k.toString(), v)));
        }

        // prevent duplicate booking of same slot
        if (learners.containsKey(myUid)) {
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

      _toast('Booked ✅ Session $currentSession');

      await _loadMyBookingsForWindow(cid);
      await _generateSlots(cid);

      // ✅ Notification hook (later)
      // await _db.child('notifications_queue/$myUid').push().set({
      //   'type': 'booking_confirmed',
      //   'courseId': cid,
      //   'dayKey': slot.dayKey,
      //   'time': slot.time,
      //   'teacherId': slot.teacherId,
      //   'createdAt': ServerValue.timestamp,
      // });
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

      await _loadMyBookingsForWindow(cid);
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

      if (onlyAvailable && s.bookedByMe) continue;

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

  // ================== Session details (Request #5) ==================

  Future<void> _openNextSessionDetails() async {
    final info = curriculumSessions['$currentSession'];
    if (info is! Map) {
      _toast('Session details not found (curriculum is optional).');
      return;
    }

    final m = info.map((k, v) => MapEntry(k.toString(), v));

    final title = (m['sessionTitle'] ?? m['title'] ?? 'Session $currentSession').toString().trim();
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
                    Text(objective, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade800)),
                    const SizedBox(height: 12),
                  ],
                  if (content.isNotEmpty) ...[
                    const Text('Content', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(content, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade800)),
                    const SizedBox(height: 12),
                  ],
                  if (homework.isNotEmpty) ...[
                    const Text('Homework', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(homework, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade800)),
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
                  'Session: ${slot.bookedSessionNo ?? currentSession} / $totalSessions',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                const SizedBox(height: 12),

                if (!slot.bookedByMe) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: actionOrange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: booking
                        ? null
                        : () async {
                      Navigator.pop(context);

                      // If learner already has a booking, offer switch instead of blocking
                      final existing = await _findMyNextBooking(courseId!);
                      final hasOther = existing != null && !(existing.dayKey == slot.dayKey && existing.time == slot.time);

                      final locked = existing != null && !existing.start.isAfter(DateTime.now().add(const Duration(hours: 24)));

                      final msg = hasOther
                          ? (locked
                          ? 'You already booked a class within 24 hours.\nYou can’t change it now.'
                          : 'You already booked a class.\nDo you want to change it to this new slot?\n\nOld: ${_friendlyDate(existing.start)} ${existing.time}\nNew: ${_friendlyDate(slot.start)} ${slot.time}')
                          : 'Book this session?\n\n${_friendlyDate(slot.start)} at ${slot.time}\nTeacher: ${slot.teacherName}';

                      if (hasOther && locked) {
                        _toast('You can’t change booking within 24 hours.');
                        return;
                      }

                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text(hasOther ? 'Change booking' : 'Confirm booking'),
                          content: Text(msg),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(hasOther ? 'Yes, Change' : 'Yes, Book'),
                            ),
                          ],
                        ),
                      );

                      if (ok == true) {
                        await _bookSlot(slot);
                      }
                    },
                    child: const Text('Book this slot', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF7EE),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: uiBorder.withOpacity(0.7)),
                    ),
                    child: const Text('You booked this slot ✅', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
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
                    child: Text(cancelLocked ? 'Cancel disabled (within 24h)' : 'Cancel booking', style: const TextStyle(fontWeight: FontWeight.w900)),
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
    Widget pill(Color c, String t) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: uiBorder.withOpacity(0.6)),
        ),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: primaryBlue)),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        pill(const Color(0xFFFFF1E3), 'Available'),
        pill(const Color(0xFFEAF7EE), 'Booked'),
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

        // Time chips + available toggle
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _chip('All day', timeFilter == 'all', () => setState(() => timeFilter = 'all')),
            _chip('Morning', timeFilter == 'morning', () => setState(() => timeFilter = 'morning')),
            _chip('Afternoon', timeFilter == 'afternoon', () => setState(() => timeFilter = 'afternoon')),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: uiBorder.withOpacity(0.9)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Only available', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 12)),
                  const SizedBox(width: 8),
                  Switch(
                    value: onlyAvailable,
                    onChanged: (v) => setState(() => onlyAvailable = v),
                    activeColor: actionOrange,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
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
        child: Text(label, style: TextStyle(fontWeight: FontWeight.w900, color: on ? actionOrange : primaryBlue, fontSize: 12)),
      ),
    );
  }

  Widget _buildTimetable(List<_Slot> rawSlots) {
    final slots = _applyFilters(rawSlots);

    final days = _nextDays(timetableDays);
    final times = _uniqueTimes(slots);

    // index: dayKey|time -> slot
    final Map<String, _Slot> index = {};
    for (final s in slots) {
      index[s.key] = s;
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
                  width: 120,
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
              width: 94.0 + (120.0 * timetableDays),
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
                    final s = index[key];

                    final hasSlot = s != null;
                    final bookedByMe = s?.bookedByMe == true;

                    final bg = !hasSlot
                        ? Colors.transparent
                        : bookedByMe
                        ? const Color(0xFFEAF7EE) // booked
                        : const Color(0xFFFFF1E3); // available

                    final border = !hasSlot
                        ? uiBorder.withOpacity(0.25)
                        : bookedByMe
                        ? const Color(0xFFB9E2C5)
                        : const Color(0xFFF9C59D);

                    return GestureDetector(
                      onTap: !hasSlot ? null : () => _onSlotTap(s!),
                      child: Container(
                        width: 120,
                        height: 56,
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: border),
                        ),
                        child: hasSlot
                            ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              bookedByMe ? 'Booked' : 'Available',
                              style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 12),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.teacherName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, fontSize: 11),
                            ),
                          ],
                        )
                            : const SizedBox.shrink(),
                      ),
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
    final sessionTitle = (sessionInfo is Map) ? (sessionInfo['sessionTitle'] ?? sessionInfo['title'] ?? '').toString() : '';

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
              await _loadMyBookingsForWindow(cid);
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
                        'Next required session: $currentSession / $totalSessions',
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
                            Text('Details', style: TextStyle(fontWeight: FontWeight.w900, color: actionOrange, fontSize: 12)),
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

  _TeacherAvail({
    required this.teacherId,
    required this.teacherName,
    required this.slotsByDay,
  });
}

class _Slot {
  final String courseId;
  final String dayKey; // yyyy-mm-dd
  final String time; // HH:MM
  final DateTime start;
  final String teacherId;
  final String teacherName;

  // reservation state
  final bool bookedByMe;
  final int? bookedSessionNo;

  _Slot({
    required this.courseId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
    this.bookedByMe = false,
    this.bookedSessionNo,
  });

  String get key => '$dayKey|$time';
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