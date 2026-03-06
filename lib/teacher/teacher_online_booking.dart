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
  // ===== Brand colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const mainText = Color(0xFF2D2D2D);

  final TextEditingController _meetCtrl = TextEditingController();

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final DatabaseReference _configRef = FirebaseDatabase.instance.ref('booking_config');

  // Teacher info
  String myUid = '';
  String myName = 'Teacher';

  // UI state
  bool loading = true;
  bool saving = false;
  bool togglingTeacher = false;
  bool togglingCourse = false;

  // Teacher-level online switch
  bool teacherOnlineEnabled = true;

  // Course list
  List<_CoursePick> myCourses = [];
  String? selectedCourseId;

  // Course-level online switch
  bool courseOnlineEnabled = true;

  // Course requirement info
  String selectedCourseTitle = '';
  int totalSessionsN = 0;
  int minChoicesK = 2;
  int weeksTarget = 4;

  // Saved meeting/session info
  int _durationMinutes = 60;

  // Timetable range
  int startHour = 8;
  int endHour = 21;
  final int slotMinutes = 60;

  // Days
  final List<String> dayKeys = const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  final List<String> dayLabels = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // Weekly slot map
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

  DatabaseReference _teacherRootRef() => _db.child('booking_availability/$myUid');
  DatabaseReference _teacherSettingsRef() => _db.child('booking_availability/$myUid/settings');
  DatabaseReference _availRef(String courseId) => _db.child('booking_availability/$myUid/$courseId');

  String _two(int n) => n < 10 ? '0$n' : '$n';
  String _fmt(TimeOfDay t) => '${_two(t.hour)}:${_two(t.minute)}';

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

  String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

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
    return (requiredMonthly / w).ceil();
  }

  String _coverageStatusLabel({
    required bool teacherOn,
    required bool courseOn,
    required int weeklySlots,
    required int requiredMonthly,
  }) {
    if (!teacherOn) return 'Teacher OFF';
    if (!courseOn) return 'Course OFF';
    if (requiredMonthly <= 0) return 'No target';
    final approxMonthly = weeklySlots * (weeksTarget <= 0 ? 4 : weeksTarget);
    if (approxMonthly >= requiredMonthly) return 'Ready ✅';
    return 'Draft';
  }

  bool get _slotEditingEnabled => teacherOnlineEnabled && courseOnlineEnabled;

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
    await _loadTeacherSettings();
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

  Future<void> _loadTeacherSettings() async {
    try {
      final snap = await _teacherSettingsRef().get();
      if (!snap.exists || snap.value is! Map) {
        teacherOnlineEnabled = true;
        return;
      }

      final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));
      teacherOnlineEnabled = _toBool(m['teacherOnlineEnabled'], fallback: true);
    } catch (_) {
      teacherOnlineEnabled = true;
    }
  }

  Future<Set<String>> _loadEnabledCourseIds() async {
    final enabled = <String>{};

    try {
      final snap = await _db.child('syllabi').get();
      final v = snap.value;

      if (v is Map) {
        final root = v.map((k, vv) => MapEntry(k.toString(), vv));

        root.forEach((courseId, courseNode) {
          if (courseNode is! Map) return;

          final courseMap = courseNode.map((k, vv) => MapEntry(k.toString(), vv));
          final onlineNode = courseMap['online'];

          if (onlineNode is Map) {
            enabled.add(courseId);
          }
        });
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

      final enabledIds = await _loadEnabledCourseIds();
      final filtered = out.where((c) => enabledIds.contains(c.id)).toList()
        ..sort((a, b) => a.title.compareTo(b.title));

      setState(() {
        myCourses = filtered;
        selectedCourseId = filtered.isNotEmpty ? filtered.first.id : null;
        selectedCourseTitle = filtered.isNotEmpty ? filtered.first.title : '';
      });

      if (out.isEmpty) {
        _toast('No courses assigned to you (users/$myUid/courses).');
      } else if (filtered.isEmpty) {
        _toast('No online syllabus found yet for your assigned courses.');
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

      final syllabusSnap = await _db.child('syllabi/$courseId/online').get();
      if (syllabusSnap.exists && syllabusSnap.value is Map) {
        final s = (syllabusSnap.value as Map).map((kk, vv) => MapEntry(kk.toString(), vv));

        title = (s['title'] ?? '').toString().trim();

        final unitsRaw = s['units'];
        if (unitsRaw is List) {
          for (final u in unitsRaw) {
            if (u is! Map) continue;
            final unit = u.map((kk, vv) => MapEntry(kk.toString(), vv));
            final sessionsRaw = unit['sessions'];

            if (sessionsRaw is List) {
              n += sessionsRaw.length;
            }
          }
        }
      }

      if (title.isEmpty) {
        final courseSnap = await _db.child('courses/$courseId').get();
        if (courseSnap.exists && courseSnap.value is Map) {
          final c = (courseSnap.value as Map).map((kk, vv) => MapEntry(kk.toString(), vv));
          title = (c['title'] ?? c['name'] ?? '').toString().trim();
        }
      }

      final cfgSnap = await _configRef.child('courses/$courseId').get();
      if (cfgSnap.exists && cfgSnap.value is Map) {
        final m = (cfgSnap.value as Map).map((kk, vv) => MapEntry(kk.toString(), vv));

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
    } catch (_) {}
  }

  Future<void> _loadAvailability(String courseId) async {
    for (final dk in dayKeys) {
      weekSlots[dk] = <int>{};
    }

    try {
      final snap = await _availRef(courseId).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        _meetCtrl.text = '';
        _durationMinutes = 60;
        courseOnlineEnabled = true;
        setState(() {});
        return;
      }

      final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));

      final meetUrl = (m['meetUrl'] ??
          m['meet_url'] ??
          m['googleMeetUrl'] ??
          m['google_meet_url'] ??
          '')
          .toString()
          .trim();
      _meetCtrl.text = meetUrl;

      final dur = _toInt(m['durationMinutes'], fallback: 0);
      _durationMinutes = dur > 0 ? dur : 60;

      final sh = _toInt(m['startHour'], fallback: startHour);
      final eh = _toInt(m['endHour'], fallback: endHour);
      if (sh > 0 && eh > sh) {
        startHour = sh;
        endHour = eh;
      }

      courseOnlineEnabled = _toBool(m['courseOnlineEnabled'], fallback: true);

      final weekNode = m['week'];
      if (weekNode is Map) {
        final wm = weekNode.map((k, vv) => MapEntry(k.toString(), vv));

        for (final dk in dayKeys) {
          final list = wm[dk];
          final set = <int>{};

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

  // ===================== Booking checks =====================

  Future<bool> _hasUpcomingBookingsForCourse(String courseId) async {
    final now = DateTime.now();

    try {
      final snap = await _db.child('booking_reservations/$courseId').get();
      if (!snap.exists || snap.value is! Map) return false;

      final daysMap = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));

      for (final dayEntry in daysMap.entries) {
        final dayKey = dayEntry.key;
        final slotsNode = dayEntry.value;
        if (slotsNode is! Map) continue;

        final slotsMap = slotsNode.map((k, vv) => MapEntry(k.toString(), vv));
        for (final slotEntry in slotsMap.entries) {
          final hhmm = slotEntry.key;
          final slotNode = slotEntry.value;
          if (slotNode is! Map) continue;

          final sm = slotNode.map((k, vv) => MapEntry(k.toString(), vv));
          final teacherId = (sm['teacherId'] ?? '').toString().trim();
          if (teacherId != myUid) continue;

          final start = _parseDateAndTime(dayKey, hhmm);
          if (start == null) continue;
          if (!start.isAfter(now)) continue;

          final learnersRaw = sm['learners'];
          if (learnersRaw is Map && learnersRaw.isNotEmpty) {
            return true;
          }
        }
      }
    } catch (_) {}

    return false;
  }

  Future<bool> _hasUpcomingBookingsForAnyCourse() async {
    for (final c in myCourses) {
      final has = await _hasUpcomingBookingsForCourse(c.id);
      if (has) return true;
    }
    return false;
  }

  DateTime? _parseDateAndTime(String dayKey, String hhmm) {
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

  // ===================== Status toggles =====================

  Future<void> _toggleTeacherOnline(bool nextValue) async {
    if (togglingTeacher) return;

    if (!nextValue) {
      final hasUpcoming = await _hasUpcomingBookingsForAnyCourse();
      if (hasUpcoming) {
        _toast('You have upcoming bookings. You cannot turn OFF teacher online status yet.');
        return;
      }
    }

    setState(() => togglingTeacher = true);

    try {
      await _teacherSettingsRef().update({
        'teacherOnlineEnabled': nextValue,
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      setState(() {
        teacherOnlineEnabled = nextValue;
      });

      _toast(nextValue ? 'Teacher online status turned ON.' : 'Teacher online status turned OFF.');
    } catch (e) {
      _toast('Could not update teacher status: $e');
    } finally {
      if (!mounted) return;
      setState(() => togglingTeacher = false);
    }
  }

  Future<void> _toggleCourseOnline(bool nextValue) async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty || togglingCourse) return;

    if (!nextValue) {
      final hasUpcoming = await _hasUpcomingBookingsForCourse(courseId);
      if (hasUpcoming) {
        _toast('This course has upcoming bookings. You cannot turn it OFF yet.');
        return;
      }
    }

    setState(() => togglingCourse = true);

    try {
      await _availRef(courseId).update({
        'courseOnlineEnabled': nextValue,
        'teacherId': myUid,
        'teacherName': myName,
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      setState(() {
        courseOnlineEnabled = nextValue;
      });

      _toast(nextValue ? 'Course online status turned ON.' : 'Course online status turned OFF.');
    } catch (e) {
      _toast('Could not update course status: $e');
    } finally {
      if (!mounted) return;
      setState(() => togglingCourse = false);
    }
  }

  // ===================== Save =====================

  Future<void> _saveAvailability() async {
    final courseId = selectedCourseId;
    if (courseId == null || courseId.isEmpty) {
      _toast('Select a course first.');
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
        'courseOnlineEnabled': courseOnlineEnabled,
        'updatedAt': ServerValue.timestamp,
        'week': payloadWeek,
      });

      await _teacherSettingsRef().update({
        'teacherOnlineEnabled': teacherOnlineEnabled,
        'updatedAt': ServerValue.timestamp,
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
    if (!_slotEditingEnabled) {
      _toast('Turn ON teacher and course online status to edit slots.');
      return;
    }

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
                      subtitle: 'Select weekly 1-hour teaching slots.',
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
    final reqWeekly = _requiredWeeklySlotsFromMonthly(requiredMonthly);

    final status = _coverageStatusLabel(
      teacherOn: teacherOnlineEnabled,
      courseOn: courseOnlineEnabled,
      weeklySlots: weeklySlots,
      requiredMonthly: requiredMonthly,
    );

    final double progress = (requiredMonthly <= 0)
        ? 0
        : (approxMonthly / requiredMonthly).clamp(0.0, 1.0);

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
            title: '1) Status',
            child: Column(
              children: [
                _ToggleRowCard(
                  title: 'Teacher online booking',
                  subtitle: teacherOnlineEnabled
                      ? 'You are open for online booking.'
                      : 'You are OFF for online booking.',
                  value: teacherOnlineEnabled,
                  busy: togglingTeacher,
                  onChanged: _toggleTeacherOnline,
                ),
                const SizedBox(height: 10),
                _ToggleRowCard(
                  title: 'This course',
                  subtitle: courseOnlineEnabled
                      ? 'This course is open for online booking.'
                      : 'This course is OFF for online booking.',
                  value: courseOnlineEnabled,
                  busy: togglingCourse,
                  onChanged: cid == null ? null : _toggleCourseOnline,
                ),
                const SizedBox(height: 10),
                _InfoBox(
                  text: 'Turning OFF is blocked if there is an upcoming booking.\n'
                      'Saved slots stay preserved.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _CardBox(
            title: '2) Course',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _courseDropdown(),
                const SizedBox(height: 10),
                _MeetLinkCard(
                  controller: _meetCtrl,
                  durationMinutes: _durationMinutes,
                  enabled: _slotEditingEnabled,
                  onDurationChanged: (v) => setState(() => _durationMinutes = v),
                ),
                const SizedBox(height: 10),
                _InfoBox(
                  text: cid == null
                      ? 'Select a course to set availability.'
                      : !_slotEditingEnabled
                      ? 'Turn ON teacher and course status to edit slots.'
                      : 'Pick a day and choose 1-hour slots.\nThis repeats every week.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _CardBox(
            title: '3) Readiness',
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
                        'Coverage estimate',
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
                            : 'This meter is informational. Saving is allowed even if not ready.',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: mainText.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _CardBox(
            title: '4) Weekly timetable',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DayChips(
                  dayKeys: dayKeys,
                  dayLabels: dayLabels,
                  weekSlots: weekSlots,
                  enabled: _slotEditingEnabled,
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
                    enabled: _slotEditingEnabled,
                    onTap: (saving || !_slotEditingEnabled) ? null : () => _openDayEditor(dk, label),
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
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
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

  _CoursePick({
    required this.id,
    required this.title,
    required this.code,
  });
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

class _ToggleRowCard extends StatelessWidget {
  const _ToggleRowCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool busy;
  final ValueChanged<bool>? onChanged;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Switch(
            value: value,
            onChanged: onChanged,
            activeColor: actionOrange,
          ),
        ],
      ),
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
    required this.enabled,
    required this.onTapDay,
  });

  final List<String> dayKeys;
  final List<String> dayLabels;
  final Map<String, Set<int>> weekSlots;
  final bool enabled;
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
          onTap: (!enabled || onTapDay == null) ? null : () => onTapDay!(dk, label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: enabled ? Colors.white : appBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: uiBorder.withOpacity(0.85)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: enabled ? primaryBlue : primaryBlue.withOpacity(0.5),
                  ),
                ),
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
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final int slotCount;
  final String preview;
  final bool enabled;
  final VoidCallback? onTap;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    final has = slotCount > 0;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(18),
      child: Opacity(
        opacity: enabled ? 1 : 0.65,
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
              ),
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
              Icon(
                Icons.chevron_right_rounded,
                color: enabled ? Colors.grey : Colors.grey.shade400,
              ),
            ],
          ),
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
    required this.enabled,
    required this.onDurationChanged,
  });

  final TextEditingController controller;
  final int durationMinutes;
  final bool enabled;
  final void Function(int v) onDurationChanged;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: Container(
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
              enabled: enabled,
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
                  onChanged: !enabled
                      ? null
                      : (v) {
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
      ),
    );
  }
}