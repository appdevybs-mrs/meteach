import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';
import '../shared/teacher_web_layout.dart';

class TeacherOnlineBookingScreen extends StatefulWidget {
  const TeacherOnlineBookingScreen({super.key});

  @override
  State<TeacherOnlineBookingScreen> createState() =>
      _TeacherOnlineBookingScreenState();
}

class _TeacherOnlineBookingScreenState
    extends State<TeacherOnlineBookingScreen> {
  final TextEditingController _meetCtrl = TextEditingController();

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String myUid = '';
  String myName = 'Teacher';

  bool loading = true;
  bool saving = false;
  bool togglingTeacher = false;

  bool teacherOnlineEnabled = true;

  List<_CoursePick> myCourses = [];
  final Set<String> selectedCourseIds = <String>{};
  bool _coursesExpanded = false;

  int _durationMinutes = 60;

  int startHour = 8;
  int endHour = 21;

  final List<String> dayKeys = const [
    'mon',
    'tue',
    'wed',
    'thu',
    'fri',
    'sat',
    'sun',
  ];

  final List<String> dayLabels = const [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

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
    appThemeController.addListener(_onThemeChanged);
    _init();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _meetCtrl.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(
        content: Text(humanizeUiMessage(msg)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  DatabaseReference _teacherRootRef() =>
      _db.child('booking_availability/$myUid');

  DatabaseReference _teacherSettingsRef() =>
      _db.child('booking_availability/$myUid/settings');

  DatabaseReference _availRef(String courseId) =>
      _db.child('booking_availability/$myUid/$courseId');

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

  int _totalWeeklySlots() {
    int sum = 0;
    for (final dk in dayKeys) {
      sum += (weekSlots[dk] ?? const <int>{}).length;
    }
    return sum;
  }

  int _selectedCoursesCount() => selectedCourseIds.length;
  String _selectedCoursesLabel() {
    final count = selectedCourseIds.length;
    if (count == 0) return 'No course selected';
    if (count == 1) return '1 course selected';
    return '$count courses selected';
  }

  bool get _slotEditingEnabled =>
      teacherOnlineEnabled && selectedCourseIds.isNotEmpty;

  String get _selectedCoursesSummary {
    if (selectedCourseIds.isEmpty) return 'No course selected';
    final picks = myCourses
        .where((c) => selectedCourseIds.contains(c.id))
        .toList();
    if (picks.isEmpty) return 'No course selected';
    if (picks.length == 1) return picks.first.title;
    if (picks.length == 2) return '${picks[0].title} + ${picks[1].title}';
    return '${picks[0].title} + ${picks.length - 1} more';
  }

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
    await _loadSelectedCoursesAndSharedSchedule();

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

          final courseMap = courseNode.map(
            (k, vv) => MapEntry(k.toString(), vv),
          );
          final flexibleNode = courseMap['flexible'];

          if (flexibleNode is Map) {
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

          out.add(
            _CoursePick(
              id: id,
              title: title.isEmpty ? 'Untitled' : title,
              code: code,
            ),
          );
        }
      }

      final enabledIds = await _loadEnabledCourseIds();
      final filtered = out.where((c) => enabledIds.contains(c.id)).toList()
        ..sort((a, b) => a.title.compareTo(b.title));

      if (!mounted) return;
      setState(() {
        myCourses = filtered;
      });

      if (out.isEmpty) {
        _toast('No courses assigned to you (users/$myUid/courses).');
      } else if (filtered.isEmpty) {
        _toast('No flexible syllabus found yet for your assigned courses.');
      }
    } catch (e) {
      _toast('Failed loading courses: $e');
    }
  }

  void _resetEditorValues() {
    _meetCtrl.text = '';
    _durationMinutes = 60;
    startHour = 8;
    endHour = 21;
    for (final dk in dayKeys) {
      weekSlots[dk] = <int>{};
    }
  }

  Future<void> _loadSelectedCoursesAndSharedSchedule() async {
    selectedCourseIds.clear();

    String? sourceCourseId;
    bool foundEnabledSource = false;

    for (final course in myCourses) {
      try {
        final snap = await _availRef(course.id).get();
        if (!snap.exists || snap.value is! Map) continue;

        final m = (snap.value as Map).map(
          (k, vv) => MapEntry(k.toString(), vv),
        );
        final isOn = _toBool(m['courseOnlineEnabled'], fallback: false);

        if (isOn) {
          selectedCourseIds.add(course.id);
          if (!foundEnabledSource) {
            foundEnabledSource = true;
            sourceCourseId = course.id;
          }
        } else if (sourceCourseId == null) {
          final hasWeek = m['week'] is Map;
          final hasMeet = ((m['meetUrl'] ?? '').toString().trim()).isNotEmpty;
          if (hasWeek || hasMeet) {
            sourceCourseId = course.id;
          }
        }
      } catch (_) {}
    }

    if (sourceCourseId != null) {
      await _loadAvailability(sourceCourseId);
    } else {
      _resetEditorValues();
      if (mounted) setState(() {});
    }
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
        startHour = 8;
        endHour = 21;
        setState(() {});
        return;
      }

      final m = (snap.value as Map).map((k, vv) => MapEntry(k.toString(), vv));

      final meetUrl =
          (m['meetUrl'] ??
                  m['meet_url'] ??
                  m['googleMeetUrl'] ??
                  m['google_meet_url'] ??
                  '')
              .toString()
              .trim();
      _meetCtrl.text = meetUrl;

      final dur = _toInt(m['durationMinutes'], fallback: 0);
      _durationMinutes = dur > 0 ? dur : 60;

      final sh = _toInt(m['startHour'], fallback: 8);
      final eh = _toInt(m['endHour'], fallback: 21);
      if (sh > 0 && eh > sh) {
        startHour = sh;
        endHour = eh;
      } else {
        startHour = 8;
        endHour = 21;
      }

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

  Future<bool> _hasUpcomingBookingsForCourse(String courseId) async {
    final now = DateTime.now();

    try {
      final snap = await _db.child('booking_reservations/$courseId').get();
      if (!snap.exists || snap.value is! Map) return false;

      final daysMap = (snap.value as Map).map(
        (k, vv) => MapEntry(k.toString(), vv),
      );

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

  Future<void> _toggleTeacherOnline(bool nextValue) async {
    if (togglingTeacher) return;

    if (!nextValue) {
      final hasUpcoming = await _hasUpcomingBookingsForAnyCourse();
      if (hasUpcoming) {
        _toast(
          'You have upcoming bookings. You cannot turn OFF teacher online status yet.',
        );
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

      _toast(
        nextValue
            ? 'Teacher online status turned ON.'
            : 'Teacher online status turned OFF.',
      );
    } catch (e) {
      _toast('Could not update teacher status: $e');
    } finally {
      if (!mounted) return;
      setState(() => togglingTeacher = false);
    }
  }

  Future<void> _saveAvailability() async {
    if (selectedCourseIds.isEmpty) {
      _toast('Select at least one course.');
      return;
    }

    final payloadWeek = <String, dynamic>{};
    for (final dk in dayKeys) {
      final slots = (weekSlots[dk] ?? <int>{}).toList()..sort();
      payloadWeek[dk] = slots.map((m) => _fmt(_minutesToTime(m))).toList();
    }

    setState(() => saving = true);

    final skippedDisableTitles = <String>[];

    try {
      await _teacherRootRef().update({
        'teacherId': myUid,
        'teacherName': myName,
        'updatedAt': ServerValue.timestamp,
      });

      for (final course in myCourses) {
        final isSelected = selectedCourseIds.contains(course.id);

        if (isSelected) {
          await _availRef(course.id).set({
            'teacherId': myUid,
            'teacherName': myName,
            'meetUrl': _meetCtrl.text.trim(),
            'durationMinutes': _durationMinutes,
            'startHour': startHour,
            'endHour': endHour,
            'slotMinutes': 60,
            'courseOnlineEnabled': true,
            'updatedAt': ServerValue.timestamp,
            'week': payloadWeek,
          });
        } else {
          final hasUpcoming = await _hasUpcomingBookingsForCourse(course.id);
          if (hasUpcoming) {
            skippedDisableTitles.add(course.title);
            continue;
          }

          final existing = await _availRef(course.id).get();
          if (existing.exists) {
            await _availRef(course.id).update({
              'teacherId': myUid,
              'teacherName': myName,
              'courseOnlineEnabled': false,
              'updatedAt': ServerValue.timestamp,
            });
          }
        }
      }

      await _teacherSettingsRef().update({
        'teacherOnlineEnabled': teacherOnlineEnabled,
        'updatedAt': ServerValue.timestamp,
      });

      if (skippedDisableTitles.isEmpty) {
        _toast('Availability saved ✅');
      } else {
        _toast(
          'Saved, but some courses stayed ON because they have upcoming bookings.',
        );
      }
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (!mounted) return;
      setState(() => saving = false);
    }
  }

  void _toggleCourseSelection(String courseId, bool nextValue) {
    setState(() {
      if (nextValue) {
        selectedCourseIds.add(courseId);
      } else {
        selectedCourseIds.remove(courseId);
      }
    });
  }

  Future<void> _openDayEditor(String dayKey, String label) async {
    if (!_slotEditingEnabled) {
      _toast('Turn ON teacher booking and select at least one course.');
      return;
    }

    final local = <int>{...(weekSlots[dayKey] ?? <int>{})};

    const splitHour = 13;
    final morningHours = _hoursInRange(startHour, splitHour);
    final afternoonHours = _hoursInRange(splitHour, endHour);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.appBg,
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
                  color: p.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.border.withValues(alpha: 0.85)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: p.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: hours.map((h) {
                          final startM = h * 60;
                          final isOn = local.contains(startM);

                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => setModal(() => toggleHour(h)),
                            child: Container(
                              width: 118,
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isOn
                                    ? p.accent.withValues(alpha: 0.10)
                                    : p.soft.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isOn
                                      ? p.accent.withValues(alpha: 0.35)
                                      : p.border.withValues(alpha: 0.9),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: isOn,
                                    activeColor: p.accent,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (_) =>
                                        setModal(() => toggleHour(h)),
                                  ),
                                  Expanded(
                                    child: Text(
                                      '${_two(h)}-${_two(h + 1)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: isOn ? p.accent : p.primary,
                                        fontSize: 12,
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
                      palette: p,
                      title: label,
                      subtitle: '1-hour slots',
                      count: local.length,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: p.primary,
                              side: BorderSide(
                                color: p.border.withValues(alpha: 0.9),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 11),
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
                            icon: const Icon(Icons.done_all_rounded, size: 18),
                            label: const Text(
                              'All',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                            ),
                            onPressed: local.isEmpty
                                ? null
                                : () => setModal(() => local.clear()),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                            label: const Text(
                              'Clear',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(ctx).size.height * 0.55,
                      ),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          section('Morning', morningHours),
                          const SizedBox(height: 10),
                          section('Afternoon / Evening', afternoonHours),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: p.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        onPressed: () {
                          setState(() {
                            weekSlots[dayKey] = <int>{...local};
                          });
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.check_circle_rounded),
                        label: const Text(
                          'Done',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
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

  String _previewSlots(Set<int> slots) {
    if (slots.isEmpty) return 'No slots';
    final sorted = slots.toList()..sort();
    final take = sorted.take(6).map((m) => _fmt(_minutesToTime(m))).toList();
    final more = sorted.length > 6 ? ' …' : '';
    return '${take.join(', ')}$more';
  }

  void _showHelp(String title, String text) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: p.cardBg,
        title: Text(
          title,
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          text,
          style: TextStyle(
            color: p.text,
            fontWeight: FontWeight.w700,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'OK',
              style: TextStyle(color: p.accent, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final weeklySlots = _totalWeeklySlots();
    final selectedCount = _selectedCoursesCount();

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_online_booking',
      hints: const [
        TeacherTourHint(
          title: 'Online availability',
          line:
              'Turn booking on, choose courses, and define your weekly slots.',
        ),
        TeacherTourHint(
          title: 'Save setup',
          line:
              'Save your availability after changing days, hours, or meeting link.',
        ),
      ],
    );

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        titleSpacing: 12,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Teacher Availability',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            Text(
              'Courses + weekly schedule',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Save',
            onPressed: saving ? null : _saveAvailability,
            icon: saving
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.accent,
                    ),
                  )
                : Icon(Icons.save_rounded, color: p.accent),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1320,
        child: loading
            ? Center(child: CircularProgressIndicator(color: p.accent))
            : ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _HeroAvailabilityCard(
                    palette: p,
                    teacherName: myName,
                    selectedCourseTitle: _selectedCoursesSummary,
                    teacherOnlineEnabled: teacherOnlineEnabled,
                    selectedCourseCount: selectedCount,
                    weeklySlots: weeklySlots,
                  ),
                  const SizedBox(height: 12),
                  _CardBox(
                    palette: p,
                    title: '1) Status',
                    trailing: _MiniHelpButton(
                      palette: p,
                      onTap: () => _showHelp(
                        'Teacher status',
                        'Turn this ON to accept bookings.\n'
                            'Turning it OFF is blocked if you still have upcoming bookings.',
                      ),
                    ),
                    child: Column(
                      children: [
                        _ToggleRowCard(
                          palette: p,
                          title: 'Teacher booking',
                          subtitle: teacherOnlineEnabled ? 'ON' : 'OFF',
                          value: teacherOnlineEnabled,
                          busy: togglingTeacher,
                          onChanged: _toggleTeacherOnline,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _CardBox(
                    palette: p,
                    title: '2) Courses',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MiniHelpButton(
                          palette: p,
                          onTap: () => _showHelp(
                            'Courses',
                            'Tick the courses you want to teach.\n'
                                'All checked courses will use the same schedule and Meet link when you save.',
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () {
                            setState(() {
                              _coursesExpanded = !_coursesExpanded;
                            });
                          },
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: p.soft.withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: p.border.withValues(alpha: 0.85),
                              ),
                            ),
                            child: Icon(
                              _coursesExpanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 20,
                              color: p.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    child: myCourses.isEmpty
                        ? _InfoBox(
                            palette: p,
                            text: 'No booking-enabled courses assigned to you.',
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  setState(() {
                                    _coursesExpanded = !_coursesExpanded;
                                  });
                                },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: p.cardBg,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: p.border.withValues(alpha: 0.85),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _selectedCoursesLabel(),
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: p.primary,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        _coursesExpanded
                                            ? Icons.keyboard_arrow_up_rounded
                                            : Icons.keyboard_arrow_down_rounded,
                                        color: p.primary,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_coursesExpanded) ...[
                                const SizedBox(height: 8),
                                _CoursesChecklist(
                                  palette: p,
                                  courses: myCourses,
                                  selectedCourseIds: selectedCourseIds,
                                  enabled: !saving,
                                  onChanged: _toggleCourseSelection,
                                ),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 10),
                  _CardBox(
                    palette: p,
                    title: '3) Session setup',
                    trailing: _MiniHelpButton(
                      palette: p,
                      onTap: () => _showHelp(
                        'Session setup',
                        'This Meet link and duration are saved for all checked courses.',
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _MeetLinkCard(
                          palette: p,
                          controller: _meetCtrl,
                          durationMinutes: _durationMinutes,
                          enabled: _slotEditingEnabled,
                          onDurationChanged: (v) =>
                              setState(() => _durationMinutes = v),
                        ),
                        if (!_slotEditingEnabled) ...[
                          const SizedBox(height: 8),
                          _InfoBox(
                            palette: p,
                            text: teacherOnlineEnabled
                                ? 'Select at least one course to edit the schedule.'
                                : 'Turn ON teacher booking first.',
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _CardBox(
                    palette: p,
                    title: '4) Weekly timetable',
                    trailing: _MiniHelpButton(
                      palette: p,
                      onTap: () => _showHelp(
                        'Weekly timetable',
                        'Pick the 1-hour slots you want to offer every week.\n'
                            'There is no minimum coverage rule here anymore.',
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _DayChips(
                          palette: p,
                          dayKeys: dayKeys,
                          dayLabels: dayLabels,
                          weekSlots: weekSlots,
                          enabled: _slotEditingEnabled,
                          onTapDay: saving
                              ? null
                              : (dk, label) => _openDayEditor(dk, label),
                        ),
                        const SizedBox(height: 10),
                        ...List.generate(7, (i) {
                          final dk = dayKeys[i];
                          final label = dayLabels[i];
                          return _DayCard(
                            palette: p,
                            label: label,
                            slotCount: (weekSlots[dk] ?? <int>{}).length,
                            preview: _previewSlots(weekSlots[dk] ?? <int>{}),
                            enabled: _slotEditingEnabled,
                            onTap: (saving || !_slotEditingEnabled)
                                ? null
                                : () => _openDayEditor(dk, label),
                          );
                        }),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: p.accent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: saving ? null : _saveAvailability,
                            icon: const Icon(Icons.check_circle_rounded),
                            label: Text(
                              saving ? 'Saving…' : 'Save',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _CoursePick {
  final String id;
  final String title;
  final String code;

  _CoursePick({required this.id, required this.title, required this.code});
}

class _HeroAvailabilityCard extends StatelessWidget {
  const _HeroAvailabilityCard({
    required this.palette,
    required this.teacherName,
    required this.selectedCourseTitle,
    required this.teacherOnlineEnabled,
    required this.selectedCourseCount,
    required this.weeklySlots,
  });

  final AppPalette palette;
  final String teacherName;
  final String selectedCourseTitle;
  final bool teacherOnlineEnabled;
  final int selectedCourseCount;
  final int weeklySlots;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.primary, palette.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Online Booking',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            teacherName.trim().isEmpty ? 'Teacher' : teacherName,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 21,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            selectedCourseTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.88),
              fontWeight: FontWeight.w700,
              fontSize: 13,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeroPill(
                label: teacherOnlineEnabled ? 'Teacher ON' : 'Teacher OFF',
              ),
              _HeroPill(
                label:
                    '$selectedCourseCount course${selectedCourseCount == 1 ? '' : 's'}',
              ),
              _HeroPill(
                label: '$weeklySlots slot${weeklySlots == 1 ? '' : 's'} / week',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _CardBox extends StatelessWidget {
  const _CardBox({
    required this.palette,
    required this.title,
    required this.child,
    this.trailing,
  });

  final AppPalette palette;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border.withValues(alpha: 0.88)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(12),
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
                    color: palette.primary,
                    fontSize: 14,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _MiniHelpButton extends StatelessWidget {
  const _MiniHelpButton({required this.palette, required this.onTap});

  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.palette, required this.text});

  final AppPalette palette;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.soft.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border.withValues(alpha: 0.85)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: palette.text.withValues(alpha: 0.85),
          height: 1.3,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _ToggleRowCard extends StatelessWidget {
  const _ToggleRowCard({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final AppPalette palette;
  final String title;
  final String subtitle;
  final bool value;
  final bool busy;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              value ? Icons.wifi_tethering_rounded : Icons.wifi_off_rounded,
              color: palette.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: palette.text.withValues(alpha: 0.68),
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          busy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: palette.accent,
                  ),
                )
              : Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: palette.accent,
                ),
        ],
      ),
    );
  }
}

class _CoursesChecklist extends StatelessWidget {
  const _CoursesChecklist({
    required this.palette,
    required this.courses,
    required this.selectedCourseIds,
    required this.enabled,
    required this.onChanged,
  });

  final AppPalette palette;
  final List<_CoursePick> courses;
  final Set<String> selectedCourseIds;
  final bool enabled;
  final void Function(String courseId, bool nextValue) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: courses.map((course) {
        final checked = selectedCourseIds.contains(course.id);
        final subtitle = course.code.isEmpty
            ? course.title
            : '${course.title} • ${course.code}';

        return Opacity(
          opacity: enabled ? 1 : 0.7,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: palette.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.border.withValues(alpha: 0.85)),
            ),
            child: CheckboxListTile(
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: checked,
              activeColor: palette.accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 0,
              ),
              title: Text(
                subtitle,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: palette.primary,
                  fontSize: 13,
                ),
              ),
              onChanged: !enabled
                  ? null
                  : (v) {
                      if (v == null) return;
                      onChanged(course.id, v);
                    },
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _DayChips extends StatelessWidget {
  const _DayChips({
    required this.palette,
    required this.dayKeys,
    required this.dayLabels,
    required this.weekSlots,
    required this.enabled,
    required this.onTapDay,
  });

  final AppPalette palette;
  final List<String> dayKeys;
  final List<String> dayLabels;
  final Map<String, Set<int>> weekSlots;
  final bool enabled;
  final void Function(String dayKey, String label)? onTapDay;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: List.generate(7, (i) {
        final dk = dayKeys[i];
        final label = dayLabels[i];
        final count = (weekSlots[dk] ?? <int>{}).length;

        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: (!enabled || onTapDay == null)
              ? null
              : () => onTapDay!(dk, label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              color: enabled
                  ? palette.cardBg
                  : palette.soft.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.border.withValues(alpha: 0.85)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: enabled
                        ? palette.primary
                        : palette.primary.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 7),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: count == 0
                        ? palette.soft.withValues(alpha: 0.7)
                        : palette.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: (count == 0 ? palette.border : palette.accent)
                          .withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: count == 0
                          ? palette.primary.withValues(alpha: 0.6)
                          : palette.accent,
                      fontSize: 11,
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
    required this.palette,
    required this.label,
    required this.slotCount,
    required this.preview,
    required this.enabled,
    required this.onTap,
  });

  final AppPalette palette;
  final String label;
  final int slotCount;
  final String preview;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final has = slotCount > 0;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Opacity(
        opacity: enabled ? 1 : 0.65,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.border.withValues(alpha: 0.85)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: has
                      ? palette.accent.withValues(alpha: 0.10)
                      : palette.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: has
                        ? palette.accent.withValues(alpha: 0.25)
                        : palette.border.withValues(alpha: 0.85),
                  ),
                ),
                child: Icon(
                  has
                      ? Icons.check_circle_rounded
                      : Icons.event_available_rounded,
                  color: has ? palette.accent : palette.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: palette.primary,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: palette.text.withValues(alpha: 0.68),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: has
                      ? palette.accent.withValues(alpha: 0.10)
                      : palette.soft.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: (has ? palette.accent : palette.border).withValues(
                      alpha: 0.35,
                    ),
                  ),
                ),
                child: Text(
                  '$slotCount',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: has
                        ? palette.accent
                        : palette.primary.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: enabled
                    ? palette.text.withValues(alpha: 0.45)
                    : Colors.grey.shade400,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.count,
  });

  final AppPalette palette;
  final String title;
  final String subtitle;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.border.withValues(alpha: 0.85)),
            ),
            child: Icon(
              Icons.view_week_rounded,
              color: palette.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.primary,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: palette.text.withValues(alpha: 0.65),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.accent.withValues(alpha: 0.25)),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.accent,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeetLinkCard extends StatelessWidget {
  const _MeetLinkCard({
    required this.palette,
    required this.controller,
    required this.durationMinutes,
    required this.enabled,
    required this.onDurationChanged,
  });

  final AppPalette palette;
  final TextEditingController controller;
  final int durationMinutes;
  final bool enabled;
  final void Function(int v) onDurationChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: palette.cardBg,

          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.border.withValues(alpha: 0.85)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Meet link',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              enabled: enabled,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'https://meet.google.com/xxx-xxxx-xxx',
                filled: true,
                fillColor: palette.soft.withValues(alpha: 0.55),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  'Duration',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.text,
                  ),
                ),
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
          ],
        ),
      ),
    );
  }
}
