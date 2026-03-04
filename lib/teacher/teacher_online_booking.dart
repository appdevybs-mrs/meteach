// ✅ FULL REPLACEMENT: lib/teacher/teacher_online_booking.dart
//
// Goals (as requested):
// ✅ Keep SAME saving format + location (do not break logic):
//    booking_availability/<teacherUid>/<courseId>/week/<day> = ["08:00", ...]
// ✅ Cleaner UI (less clutter) + clearer steps
// ✅ Add rules/features for the new booking model:
//    1) Teacher must provide enough slots for the course to be "Ready":
//       requiredMonthlySlots = totalSessions (N) * minChoicesPerSession (K)
//       approxMonthlySlots   = weeklySlots * weeksTarget
//    2) Live "Coverage meter" shown.
//    3) Enforce coverage ON SAVE: if not enough, block saving and show message.
// ✅ Do NOT change slot editing logic (still weekly repeating 1-hour slots).
//
// Reads:
// - booking_config/courses/<courseId>/coverageTarget/{weeks, minChoicesPerSession}
// - booking_curriculum/<courseId>/totalSessions (+ title fallback)
// Writes (unchanged):
// - booking_availability/<teacherUid>/<courseId> {week: {mon:[...], ...}, ...}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherOnlineBookingScreen extends StatefulWidget {
  const TeacherOnlineBookingScreen({super.key});

  @override
  State<TeacherOnlineBookingScreen> createState() => _TeacherOnlineBookingScreenState();
}

class _TeacherOnlineBookingScreenState extends State<TeacherOnlineBookingScreen> {
  // ✅ Google Meet link (used by learner "Join")
  final TextEditingController _meetCtrl = TextEditingController();
  int _durationMinutes = 60;
  // ===== Brand colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const mainText = Color(0xFF2D2D2D);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final DatabaseReference _curriculumRef = FirebaseDatabase.instance.ref('booking_curriculum');
  final DatabaseReference _configRef = FirebaseDatabase.instance.ref('booking_config');

  // Teacher info
  String myUid = '';
  String myName = 'Teacher';

  // Courses
  bool loading = true;
  bool saving = false;
  List<_CoursePick> myCourses = [];
  String? selectedCourseId;

  // Course requirements (from admin)
  String selectedCourseTitle = '';
  int totalSessionsN = 0; // N
  int minChoicesK = 2; // K (per 4 weeks)
  int weeksTarget = 4;

  // Timetable range
  int startHour = 8; // inclusive
  int endHour = 21; // exclusive
  final int slotMinutes = 60;

  // Days
  final List<String> dayKeys = const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final List<String> dayLabels = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // Map dayKey -> set of selected slot start minutes (e.g., 08:00 = 480)
  final Map<String, Set<int>> weekSlots = {
    'mon': <int>{},
    'tue': <int>{},
    'wed': <int>{},
    'thu': <int>{},
    'fri': <int>{},
    'sat': <int>{},
    'sun': <int>{},
  };

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _meetCtrl.dispose();
    super.dispose();
  }
  // ===================== Helpers =====================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  DatabaseReference _availRef(String courseId) => _db.child('booking_availability/$myUid/$courseId');

  String _two(int n) => n < 10 ? '0$n' : '$n';
  String _fmt(TimeOfDay t) => '${_two(t.hour)}:${_two(t.minute)}';

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  int _tToMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  TimeOfDay _minutesToTime(int m) {
    final hh = (m ~/ 60) % 24;
    final mm = m % 60;
    return TimeOfDay(hour: hh, minute: mm);
  }

  TimeOfDay? _parseHHMM(String s) {
    final parts = s.split(':');
    if (parts.length != 2) return null;
    final hh = int.tryParse(parts[0]);
    final mm = int.tryParse(parts[1]);
    if (hh == null || mm == null) return null;
    if (hh < 0 || hh > 23) return null;
    if (mm < 0 || mm > 59) return null;
    return TimeOfDay(hour: hh, minute: mm);
  }

  List<int> _hoursInRange(int fromHour, int toHour) {
    final a = fromHour.clamp(startHour, endHour);
    final b = toHour.clamp(startHour, endHour);
    if (b <= a) return [];
    return List.generate(b - a, (i) => a + i);
  }

  int _totalWeeklySlots() {
    int sum = 0;
    for (final dk in dayKeys) {
      sum += (weekSlots[dk] ?? const <int>{}).length;
    }
    return sum;
  }

  int _requiredMonthlySlots() {
    final n = totalSessionsN <= 0 ? 0 : totalSessionsN;
    final k = minChoicesK <= 0 ? 1 : minChoicesK;
    return n * k;
  }

  int _requiredWeeklySlotsFromMonthly(int requiredMonthly) {
    final w = weeksTarget <= 0 ? 4 : weeksTarget;
    if (requiredMonthly <= 0) return 0;
    return (requiredMonthly / w).ceil(); // minimum weekly slots to meet the monthly target
  }

  String _coverageStatusLabel(int weeklySlots, int requiredMonthly) {
    if (requiredMonthly <= 0) return 'Unknown';
    final approxMonthly = weeklySlots * (weeksTarget <= 0 ? 4 : weeksTarget);
    if (approxMonthly >= requiredMonthly) return 'Ready ✅';
    return 'Not ready ❌';
  }

  // ===================== Init / Load =====================

  Future<void> _init() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => loading = false);
      _toast('Not logged in.');
      return;
    }

    myUid = uid;
    await _loadMyName();
    await _loadMyCourses();

    final cid = selectedCourseId;
    if (cid != null) {
      await _loadCourseRequirements(cid);
      await _loadAvailability(cid);
    }

    if (!mounted) return;
    setState(() => loading = false);
  }

  Future<void> _loadMyName() async {
    try {
      final snap = await _db.child('users/$myUid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        if (full.isNotEmpty) myName = full;
      }
    } catch (_) {}
  }

  Future<Set<String>> _loadEnabledCourseIds() async {
    // Original logic: courses are enabled if booking_curriculum exists
    final enabled = <String>{};
    try {
      final snap = await _curriculumRef.get();
      final v = snap.value;

      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        enabled.addAll(m.keys);
      }
    } catch (_) {}
    return enabled;
  }

  Future<void> _loadMyCourses() async {
    try {
      final snap = await _db.child('users/$myUid/courses').get();
      final v = snap.value;

      final out = <_CoursePick>[];

      if (v is Map) {
        final raw = Map<dynamic, dynamic>.from(v);
        for (final entry in raw.entries) {
          final val = entry.value;
          if (val is! Map) continue;
          final m = val.map((k, vv) => MapEntry(k.toString(), vv));

          final id = (m['id'] ?? '').toString().trim();
          if (id.isEmpty) continue;

          final title = (m['title'] ?? '').toString().trim();
          final code = (m['course_code'] ?? '').toString().trim();

          out.add(_CoursePick(
            id: id,
            title: title.isEmpty ? 'Untitled' : title,
            code: code,
          ));
        }
      }

      // Filter: only courses that exist in booking_curriculum (admin created plan)
      final enabledIds = await _loadEnabledCourseIds();
      final filtered = out.where((c) => enabledIds.contains(c.id)).toList();

      filtered.sort((a, b) => a.title.compareTo(b.title));

      setState(() {
        myCourses = filtered;
        selectedCourseId = filtered.isNotEmpty ? filtered.first.id : null;
        selectedCourseTitle = filtered.isNotEmpty ? filtered.first.title : '';
      });

      if (out.isEmpty) {
        _toast('No courses assigned to you (users/$myUid/courses).');
      } else if (filtered.isEmpty) {
        _toast('No booking-enabled courses yet. Ask admin to create booking plan first.');
      }
    } catch (e) {
      _toast('Failed loading courses: $e');
    }
  }

  Future<void> _loadCourseRequirements(String courseId) async {
    try {
      int n = 0;
      int k = 2;
      int w = 4;
      String title = '';

      final curSnap = await _curriculumRef.child(courseId).get();
      if (curSnap.exists && curSnap.value is Map) {
        final m = (curSnap.value as Map).map((kk, vv) => MapEntry(kk.toString(), vv));
        n = _toInt(m['totalSessions'], fallback: 0);
        title = (m['courseTitle'] ?? '').toString().trim();
      }

      final cfgSnap = await _configRef.child('courses/$courseId').get();
      if (cfgSnap.exists && cfgSnap.value is Map) {
        final m = (cfgSnap.value as Map).map((kk, vv) => MapEntry(kk.toString(), vv));
        title = title.isNotEmpty ? title : (m['title'] ?? '').toString().trim();

        final ct = m['coverageTarget'];
        if (ct is Map) {
          final cm = ct.map((kk, vv) => MapEntry(kk.toString(), vv));
          w = _toInt(cm['weeks'], fallback: 4);
          k = _toInt(cm['minChoicesPerSession'], fallback: 2);
          if (k <= 0) k = 1;
          if (w <= 0) w = 4;
        }
      }

      if (!mounted) return;
      setState(() {
        totalSessionsN = n;
        minChoicesK = k;
        weeksTarget = w;
        if (title.isNotEmpty) selectedCourseTitle = title;
      });
    } catch (_) {
      // keep defaults
    }
  }

  Future<void> _loadAvailability(String courseId) async {
    for (final dk in dayKeys) {
      weekSlots[dk] = <int>{};
    }

    try {
      final snap = await _availRef(courseId).get();
      if (!snap.exists || snap.value == null) {
        setState(() {});
        return;
      }

      final v = snap.value;
      if (v is! Map) {
        setState(() {});
        return;
      }

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      // ✅ Load Meet link + duration (so teacher can edit it)
      final meetUrl = (m['meetUrl'] ??
          m['meet_url'] ??
          m['googleMeetUrl'] ??
          m['google_meet_url'] ??
          '')
          .toString()
          .trim();

      _meetCtrl.text = meetUrl;

      final dur = _toInt(m['durationMinutes'], fallback: 0);
      _durationMinutes = (dur > 0) ? dur : 60;
      final sh = _toInt(m['startHour'], fallback: startHour);
      final eh = _toInt(m['endHour'], fallback: endHour);

      if (sh > 0 && eh > sh) {
        startHour = sh;
        endHour = eh;
      }

      final weekNode = m['week'];
      if (weekNode is Map) {
        final wm = weekNode.map((k, vv) => MapEntry(k.toString(), vv));

        for (final dk in dayKeys) {
          final list = wm[dk];
          final set = <int>{};

          // NEW FORMAT: list of "HH:MM"
          if (list is List && list.isNotEmpty && list.first is! Map) {
            for (final item in list) {
              final s = item.toString().trim();
              final t = _parseHHMM(s);
              if (t == null) continue;

              final minutes = _tToMinutes(t);
              if (minutes >= startHour * 60 && minutes <= (endHour - 1) * 60) {
                if (minutes % 60 == 0) set.add(minutes);
              }
            }
          }

          // OLD FORMAT: list of blocks [{start,end}]
          if (list is List && list.isNotEmpty && list.first is Map) {
            for (final item in list) {
              if (item is! Map) continue;
              final im = item.map((k, vv) => MapEntry(k.toString(), vv));
              final s = (im['start'] ?? '').toString().trim();
              final e = (im['end'] ?? '').toString().trim();
              final st = _parseHHMM(s);
              final en = _parseHHMM(e);
              if (st == null || en == null) continue;

              final sMin = _tToMinutes(st);
              final eMin = _tToMinutes(en);

              for (int cur = sMin; cur + 60 <= eMin; cur += 60) {
                if (cur >= startHour * 60 && cur <= (endHour - 1) * 60) {
                  if (cur % 60 == 0) set.add(cur);
                }
              }
            }
          }

          weekSlots[dk] = set;
        }
      }

      setState(() {});
    } catch (e) {
      _toast('Failed loading availability: $e');
      setState(() {});
    }
  }

  // ===================== Save (ENFORCED) =====================

  Future<void> _saveAvailability() async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty) {
      _toast('Select a course first.');
      return;
    }

    // ✅ enforcement (Problem #2)
    final weeklySlots = _totalWeeklySlots();
    final requiredMonthly = _requiredMonthlySlots();
    final w = weeksTarget <= 0 ? 4 : weeksTarget;
    final approxMonthly = weeklySlots * w;

    if (requiredMonthly > 0 && approxMonthly < requiredMonthly) {
      final needWeekly = _requiredWeeklySlotsFromMonthly(requiredMonthly);
      final missingWeekly = math.max(0, needWeekly - weeklySlots);

      _toast(
        'Not ready yet: add more slots.\n'
            'Need ~${needWeekly} weekly slots (you have $weeklySlots). '
            '${missingWeekly > 0 ? 'Add $missingWeekly more.' : ''}',
      );
      return;
    }

    final payloadWeek = <String, dynamic>{};
    for (final dk in dayKeys) {
      final slots = (weekSlots[dk] ?? <int>{}).toList()..sort();
      payloadWeek[dk] = slots.map((m) => _fmt(_minutesToTime(m))).toList();
    }

    setState(() => saving = true);
    try {
      await _availRef(courseId).set({
        'teacherId': myUid,
        'teacherName': myName,
        'meetUrl': _meetCtrl.text.trim(),
        'durationMinutes': _durationMinutes,
        'startHour': startHour,
        'endHour': endHour,
        'slotMinutes': 60,
        'updatedAt': ServerValue.timestamp,
        'week': payloadWeek,
      });

      _toast('Availability saved ✅');
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => saving = false);
    }
  }

  // ===================== Day Editor =====================

  Future<void> _openDayEditor(String dayKey, String label) async {
    final local = <int>{...(weekSlots[dayKey] ?? <int>{})};

    const splitHour = 13;
    final morningHours = _hoursInRange(startHour, splitHour);
    final afternoonHours = _hoursInRange(splitHour, endHour);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: appBg,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModal) {
            void toggleHour(int h) {
              final startM = h * 60;
              if (local.contains(startM)) {
                local.remove(startM);
              } else {
                if (h >= startHour && h < endHour) local.add(startM);
              }
            }

            Widget section(String title, List<int> hours) {
              if (hours.isEmpty) return const SizedBox.shrink();

              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: uiBorder.withOpacity(0.85)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 10),

                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: hours.map((h) {
                          final startM = h * 60;
                          final isOn = local.contains(startM);

                          return InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => setModal(() => toggleHour(h)),
                            child: Container(
                              width: 118,
                              margin: const EdgeInsets.only(right: 10),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isOn ? actionOrange.withOpacity(0.10) : appBg,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isOn ? actionOrange.withOpacity(0.35) : uiBorder.withOpacity(0.9),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: isOn,
                                    activeColor: actionOrange,
                                    onChanged: (_) => setModal(() => toggleHour(h)),
                                  ),
                                  Expanded(
                                    child: Text(
                                      '${_two(h)}-${_two(h + 1)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: isOn ? actionOrange : primaryBlue,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 14,
                  right: 14,
                  top: 8,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 14,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SheetHeader(
                      title: '$label availability',
                      subtitle: 'Select 1-hour slots you can teach (weekly repeating).',
                      count: local.length,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: primaryBlue,
                              side: BorderSide(color: uiBorder.withOpacity(0.9)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () {
                              final all = <int>{};
                              for (int h = startHour; h < endHour; h++) {
                                all.add(h * 60);
                              }
                              setModal(() {
                                local
                                  ..clear()
                                  ..addAll(all);
                              });
                            },
                            icon: const Icon(Icons.done_all_rounded),
                            label: const Text('Select all', style: TextStyle(fontWeight: FontWeight.w900)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: local.isEmpty ? null : () => setModal(() => local.clear()),
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Clear day', style: TextStyle(fontWeight: FontWeight.w900)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.55),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          section('Morning', morningHours),
                          const SizedBox(height: 12),
                          section('Afternoon / Evening', afternoonHours),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: actionOrange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () {
                          setState(() {
                            weekSlots[dayKey] = <int>{...local};
                          });
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.check_circle_rounded),
                        label: const Text('Done', style: TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ===================== UI =====================

  @override
  Widget build(BuildContext context) {
    final cid = selectedCourseId;

    final weeklySlots = _totalWeeklySlots();
    final requiredMonthly = _requiredMonthlySlots();
    final w = weeksTarget <= 0 ? 4 : weeksTarget;
    final approxMonthly = weeklySlots * w;

    final status = _coverageStatusLabel(weeklySlots, requiredMonthly);

    final double progress = (requiredMonthly <= 0) ? 0 : (approxMonthly / requiredMonthly).clamp(0.0, 1.0);

    final reqWeekly = _requiredWeeklySlotsFromMonthly(requiredMonthly);

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Teacher Availability',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: saving ? null : _saveAvailability,
            icon: saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_rounded, color: actionOrange),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _CardBox(
            title: '1) Course',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _courseDropdown(),
                const SizedBox(height: 10),
                _MeetLinkCard(
                  controller: _meetCtrl,
                  durationMinutes: _durationMinutes,
                  onDurationChanged: (v) => setState(() => _durationMinutes = v),
                ),
                const SizedBox(height: 10),
                _InfoBox(
                  text: cid == null
                      ? 'Select a course to set availability.'
                      : 'Pick a day → choose 1-hour slots.\nThis repeats every week.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _CardBox(
            title: '2) Coverage target',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CoverageHeader(
                  status: status,
                  courseTitle: selectedCourseTitle.isEmpty ? 'Course' : selectedCourseTitle,
                ),
                const SizedBox(height: 10),
                _StatRow(left: 'Total sessions (N)', right: totalSessionsN > 0 ? '$totalSessionsN' : '—'),
                const SizedBox(height: 8),
                _StatRow(left: 'Min choices per session (K)', right: '$minChoicesK'),
                const SizedBox(height: 8),
                _StatRow(left: 'Target window', right: '$w weeks'),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: uiBorder.withOpacity(0.85)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your availability (estimate)',
                        style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                      ),
                      const SizedBox(height: 8),
                      _StatRow(left: 'Weekly slots', right: '$weeklySlots'),
                      const SizedBox(height: 6),
                      _StatRow(left: 'Approx. slots in $w weeks', right: '$approxMonthly'),
                      const SizedBox(height: 6),
                      _StatRow(left: 'Required slots (N×K)', right: requiredMonthly > 0 ? '$requiredMonthly' : '—'),
                      const SizedBox(height: 6),
                      _StatRow(left: 'Suggested minimum weekly', right: requiredMonthly > 0 ? '$reqWeekly' : '—'),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 10,
                        backgroundColor: appBg,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        requiredMonthly <= 0
                            ? 'Admin has not set course requirements yet.'
                            : 'To be Ready, your weekly slots × $w weeks should reach N×K.',
                        style: TextStyle(fontWeight: FontWeight.w700, color: mainText.withOpacity(0.7)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          _CardBox(
            title: '3) Weekly timetable',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DayChips(
                  dayKeys: dayKeys,
                  dayLabels: dayLabels,
                  weekSlots: weekSlots,
                  onTapDay: saving ? null : (dk, label) => _openDayEditor(dk, label),
                ),
                const SizedBox(height: 12),
                ...List.generate(7, (i) {
                  final dk = dayKeys[i];
                  final label = dayLabels[i];
                  return _DayCard(
                    label: label,
                    slotCount: (weekSlots[dk] ?? <int>{}).length,
                    preview: _previewSlots(weekSlots[dk] ?? <int>{}),
                    onTap: saving ? null : () => _openDayEditor(dk, label),
                  );
                }),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: actionOrange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: saving ? null : _saveAvailability,
                    icon: const Icon(Icons.check_circle_rounded),
                    label: Text(
                        saving ? 'Saving…' : 'Save availability',
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Saved to: booking_availability/$myUid/<courseId>',
                  style: TextStyle(fontWeight: FontWeight.w800, color: mainText.withOpacity(0.75)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _previewSlots(Set<int> slots) {
    if (slots.isEmpty) return 'No slots selected';
    final sorted = slots.toList()..sort();
    final take = sorted.take(6).map((m) => _fmt(_minutesToTime(m))).toList();
    final more = sorted.length > 6 ? ' …' : '';
    return '${take.join(', ')}$more';
  }

  Widget _courseDropdown() {
    if (myCourses.isEmpty) {
      return const _InfoBox(text: 'No booking-enabled courses assigned to you.');
    }

    final safeValue = myCourses.any((x) => x.id == selectedCourseId) ? selectedCourseId : myCourses.first.id;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: DropdownButton<String>(
        value: safeValue,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.expand_more_rounded, color: primaryBlue),
        items: myCourses.map((c) {
          final label = c.code.isEmpty ? c.title : '${c.title}  —  ${c.code}';
          return DropdownMenuItem(
            value: c.id,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        }).toList(),
        onChanged: saving
            ? null
            : (v) async {
          if (v == null) return;

          final picked = myCourses.firstWhere(
                (x) => x.id == v,
            orElse: () => _CoursePick(id: v, title: '', code: ''),
          );

          setState(() {
            selectedCourseId = v;
            selectedCourseTitle = picked.title;
          });

          await _loadCourseRequirements(v);
          await _loadAvailability(v);
          _toast('Loaded ✅');
        },
      ),
    );
  }
}

// ===================== Models =====================

class _CoursePick {
  final String id;
  final String title;
  final String code;
  _CoursePick({required this.id, required this.title, required this.code});
}

// ===================== UI Components =====================

class _CardBox extends StatelessWidget {
  const _CardBox({required this.title, required this.child});

  final String title;
  final Widget child;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      padding: const EdgeInsets.all(12),
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

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.text});
  final String text;

  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: uiBorder),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class _CoverageHeader extends StatelessWidget {
  const _CoverageHeader({required this.status, required this.courseTitle});

  final String status;
  final String courseTitle;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: primaryBlue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: primaryBlue.withOpacity(0.12)),
            ),
            child: const Icon(Icons.assessment_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              courseTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F7F9),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: uiBorder.withOpacity(0.85)),
            ),
            child: Text(
              status,
              style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.left, required this.right});

  final String left;
  final String right;

  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(left, style: const TextStyle(fontWeight: FontWeight.w900))),
          const SizedBox(width: 10),
          Text(right, style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
        ],
      ),
    );
  }
}

class _DayChips extends StatelessWidget {
  const _DayChips({
    required this.dayKeys,
    required this.dayLabels,
    required this.weekSlots,
    required this.onTapDay,
  });

  final List<String> dayKeys;
  final List<String> dayLabels;
  final Map<String, Set<int>> weekSlots;
  final void Function(String dayKey, String label)? onTapDay;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(7, (i) {
        final dk = dayKeys[i];
        final label = dayLabels[i];
        final count = (weekSlots[dk] ?? <int>{}).length;

        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTapDay == null ? null : () => onTapDay!(dk, label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: uiBorder.withOpacity(0.85)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: count == 0 ? appBg : actionOrange.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: (count == 0 ? uiBorder : actionOrange).withOpacity(0.35)),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: count == 0 ? primaryBlue.withOpacity(0.6) : actionOrange,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.label,
    required this.slotCount,
    required this.preview,
    required this.onTap,
  });

  final String label;
  final int slotCount;
  final String preview;
  final VoidCallback? onTap;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    final has = slotCount > 0;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: uiBorder.withOpacity(0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 10,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: has ? actionOrange.withOpacity(0.10) : primaryBlue.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: has ? actionOrange.withOpacity(0.25) : uiBorder.withOpacity(0.85)),
              ),
              child: Icon(
                has ? Icons.check_circle_rounded : Icons.event_available_rounded,
                color: has ? actionOrange : primaryBlue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 15)),
                  const SizedBox(height: 6),
                  Text(
                    preview,
                    style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: has ? actionOrange.withOpacity(0.10) : const Color(0xFFF4F7F9),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: (has ? actionOrange : uiBorder).withOpacity(0.35)),
              ),
              child: Text(
                '$slotCount',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: has ? actionOrange : primaryBlue.withOpacity(0.6),
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right_rounded, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, required this.subtitle, required this.count});

  final String title;
  final String subtitle;
  final int count;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);
  static const actionOrange = Color(0xFFF98D28);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: primaryBlue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: uiBorder.withOpacity(0.85)),
            ),
            child: const Icon(Icons.view_week_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue, fontSize: 16)),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: actionOrange.withOpacity(0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: actionOrange.withOpacity(0.25)),
            ),
            child: Text(
              '$count slot${count == 1 ? '' : 's'}',
              style: const TextStyle(fontWeight: FontWeight.w900, color: actionOrange, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
class _MeetLinkCard extends StatelessWidget {
  const _MeetLinkCard({
    required this.controller,
    required this.durationMinutes,
    required this.onDurationChanged,
  });

  final TextEditingController controller;
  final int durationMinutes;
  final void Function(int v) onDurationChanged;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.video_call_rounded, color: primaryBlue, size: 18),
              SizedBox(width: 8),
              Text('Google Meet link', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://meet.google.com/xxx-xxxx-xxx',
              filled: true,
              fillColor: const Color(0xFFF4F7F9),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Duration', style: TextStyle(fontWeight: FontWeight.w900)),
              const Spacer(),
              DropdownButton<int>(
                value: durationMinutes,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 30, child: Text('30 min')),
                  DropdownMenuItem(value: 45, child: Text('45 min')),
                  DropdownMenuItem(value: 60, child: Text('60 min')),
                  DropdownMenuItem(value: 90, child: Text('90 min')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  onDurationChanged(v);
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'This link will be used for learners to join the booked session.',
            style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}