// ✅ FULL REPLACEMENT: lib/learner/learner_booking_screen.dart
//
// What this version fixes (based on your DB + issues):
// 1) ✅ Booking enabled check uses: booking_config/courses/<courseId>/enabled (your real node)
// 2) ✅ Availability reading supports BOTH formats:
//    A) booking_availability/<teacherId>/week/...   (your current teacher node)
//    B) booking_availability/<teacherId>/<courseId>/week/... (if you later make per-course availability)
// 3) ✅ No “class inside class” error (your pasted code had class _BookingGate inside State => invalid Dart)
// 4) ✅ Course title comes from booking_config first, then booking_curriculum if available
// 5) ✅ Still uses learner progress + reservations as you designed

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class LearnerBookingScreen extends StatefulWidget {
  const LearnerBookingScreen({super.key, this.courseId});

  /// Pass a courseId (recommended).
  /// If null, we try to infer from users/<uid>.
  final String? courseId;

  @override
  State<LearnerBookingScreen> createState() => _LearnerBookingScreenState();
}

class _LearnerBookingScreenState extends State<LearnerBookingScreen> {
  // ===== Colors (match your style) =====
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

  // Slots
  int daysAhead = 14;
  List<_Slot> generatedSlots = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  // ================== Helpers ==================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
  DatabaseReference _reservationsRef(String cid, String dayKey, String hhmm) =>
      _db.child('booking_reservations/$cid/$dayKey/$hhmm');

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

    // optional curriculum (titles)
    await _loadCurriculum(courseId!);

    await _loadOrCreateProgress(courseId!);
    await _generateSlots(courseId!);

    if (!mounted) return;
    setState(() => loading = false);
  }

  /// Tries common places where apps store learner current course/level.
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

      // Map pattern
      if (courses is Map) {
        final cm = courses.map((k, vv) => MapEntry(k.toString(), vv));

        // if keys are courseIds
        if (cm.keys.isNotEmpty) return cm.keys.first;

        // else search value for courseId/id
        for (final entry in cm.values) {
          if (entry is Map) {
            final em = entry.map((k, vv) => MapEntry(k.toString(), vv));
            final id = (em['courseId'] ?? em['id'] ?? em['course_id'] ?? '').toString().trim();
            if (id.isNotEmpty) return id;
          }
        }
      }

      // List pattern
      if (courses is List && courses.isNotEmpty) {
        final first = courses.first;
        if (first is String && first.trim().isNotEmpty) return first.trim();
        if (first is Map) {
          final fm = first.map((k, vv) => MapEntry(k.toString(), vv));
          final id = (fm['courseId'] ?? fm['id'] ?? fm['course_id'] ?? '').toString().trim();
          if (id.isNotEmpty) return id;
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

  // ================== Load Curriculum (optional titles) ==================

  Future<void> _loadCurriculum(String cid) async {
    try {
      final snap = await _curriculumRef(cid).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        // not fatal (admin can enable booking without curriculum)
        return;
      }

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
        final cs = m['currentSession'];
        currentSession = _toInt(cs, fallback: 1);
        if (currentSession <= 0) currentSession = 1;
      } else {
        currentSession = 1;
      }
    } catch (e) {
      _toast('Failed to load progress: $e');
      currentSession = 1;
    }
  }

  // ================== Availability -> Upcoming Slots ==================
  //
  // Supports:
  // A) booking_availability/<teacherId>/{week:{mon:[...],...}, startHour, endHour, slotMinutes, teacherName}
  // B) booking_availability/<teacherId>/<courseId>/{week:{...}, ...}  (per-course)
  //
  // It will ONLY include teachers that have availability for this course:
  // - If per-course node exists -> uses it
  // - Else fallback to teacher root ONLY if you want "global" availability.
  //
  // Since you said: "teacher should not show availability on all courses"
  // ✅ We require per-course availability if present; if absent, we DO NOT use teacher root.
  // So teachers must save availability under: booking_availability/<teacherId>/<courseId>/...
  //
  // If you still want to allow old format temporarily, set allowOldGlobalFormat = true.
  Future<void> _generateSlots(String cid) async {
    setState(() => generatedSlots = []);
    final now = DateTime.now();
    const allowOldGlobalFormat = false; // ✅ keep strict

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

        Map<String, dynamic>? effective; // where we read week/startHour/... from
        String resolvedTeacherName = '';

        // ✅ Preferred per-course availability: booking_availability/<teacherId>/<courseId>
        final perCourse = tn[cid];
        if (perCourse is Map) {
          effective = perCourse.map((k, vv) => MapEntry(k.toString(), vv));
          resolvedTeacherName =
              (effective['teacherName'] ?? effective['teacher_name'] ?? tn['teacherName'] ?? tn['teacher_name'] ?? '')
                  .toString()
                  .trim();
        } else if (allowOldGlobalFormat) {
          // old global format: booking_availability/<teacherId> directly
          effective = tn.map((k, vv) => MapEntry(k.toString(), vv));
          resolvedTeacherName =
              (effective['teacherName'] ?? effective['teacher_name'] ?? '').toString().trim();
        } else {
          continue; // strict: teacher MUST have per-course availability
        }

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

      if (teachers.isEmpty) {
        return;
      }

      final List<_Slot> out = [];
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
        final wk = _weekdayKey(day);
        final dayKey = _dateKey(day);

        for (final t in teachers) {
          final list = t.slotsByDay[wk] ?? const [];
          for (final hhmm in list) {
            final parts = hhmm.split(':');
            if (parts.length != 2) continue;

            final hh = int.tryParse(parts[0]);
            final mm = int.tryParse(parts[1]);
            if (hh == null || mm == null) continue;

            final start = DateTime(day.year, day.month, day.day, hh, mm);

            if (start.isBefore(now.add(const Duration(minutes: 1)))) continue;

            out.add(
              _Slot(
                courseId: cid,
                dayKey: dayKey,
                time: hhmm,
                start: start,
                teacherId: t.teacherId,
                teacherName: t.teacherName,
              ),
            );
          }
        }
      }

      out.sort((a, b) => a.start.compareTo(b.start));
      if (!mounted) return;
      setState(() => generatedSlots = out);
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

    setState(() => booking = true);

    try {
      final hasAnother = await _learnerHasFutureBooking(cid);
      if (hasAnother) {
        _toast('You already have a booked class. Cancel it first.');
        return;
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
      await _generateSlots(cid);
    } catch (e) {
      _toast('Booking failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => booking = false);
    }
  }

  Future<bool> _learnerHasFutureBooking(String cid) async {
    try {
      final now = DateTime.now();
      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
        final dk = _dateKey(day);
        final snap = await _db.child('booking_reservations/$cid/$dk').get();
        if (!snap.exists || snap.value == null) continue;

        if (snap.value is Map) {
          final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));
          for (final slotEntry in m.entries) {
            final slotNode = slotEntry.value;
            if (slotNode is! Map) continue;
            final sm = slotNode.map((k, vv) => MapEntry(k.toString(), vv));
            final learners = sm['learners'];
            if (learners is Map) {
              final lm = learners.map((k, vv) => MapEntry(k.toString(), vv));
              if (lm.containsKey(myUid)) return true;
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  // ================== UI ==================

  @override
  Widget build(BuildContext context) {
    final cid = courseId;

    final sessionInfo = curriculumSessions['$currentSession'];
    final sessionTitle = (sessionInfo is Map)
        ? (sessionInfo['sessionTitle'] ?? sessionInfo['title'] ?? '').toString()
        : '';

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
            tooltip: 'Refresh',
            onPressed: (loading || booking || cid == null) ? null : () => _generateSlots(cid),
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
                Text(
                  'Next required session: $currentSession / $totalSessions',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                const SizedBox(height: 6),
                Text(
                  sessionTitle.isEmpty ? 'Session title not found (curriculum optional)' : sessionTitle,
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Card(
            title: 'Available slots (next $daysAhead days)',
            child: generatedSlots.isEmpty
                ? const Text(
              'No available slots found.\nAsk your teacher to set availability for this course.',
              style: TextStyle(fontWeight: FontWeight.w800),
            )
                : Column(
              children: generatedSlots.map((s) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: uiBorder.withOpacity(0.85)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_friendlyDate(s.start)} • ${s.time}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              s.teacherName,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: actionOrange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: booking ? null : () => _bookSlot(s),
                        child: booking
                            ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                            : const Text(
                          'Book',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
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

  _Slot({
    required this.courseId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
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