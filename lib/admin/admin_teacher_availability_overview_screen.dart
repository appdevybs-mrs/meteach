import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_tour_guide.dart';
import '../shared/screen_help_guide.dart';

class AdminTeacherAvailabilityOverviewScreen extends StatefulWidget {
  const AdminTeacherAvailabilityOverviewScreen({super.key});

  @override
  State<AdminTeacherAvailabilityOverviewScreen> createState() =>
      _AdminTeacherAvailabilityOverviewScreenState();
}

class _AdminTeacherAvailabilityOverviewScreenState
    extends State<AdminTeacherAvailabilityOverviewScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const successGreen = Color(0xFF2F9E44);
  static const mutedText = Color(0xFF6E7B8C);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool loading = true;
  String searchText = '';

  List<_TeacherCoverage> teachers = [];
  List<_CourseMeta> flexibleCourses = [];
  Map<String, List<_TeacherCoverage>> coveredByCourse = {};
  List<_CourseMeta> uncoveredCourses = [];

  int totalTeachers = 0;
  int teachersOn = 0;
  int teachersOff = 0;
  int teachersOnNoCourses = 0;
  int teachersOnNoSlots = 0;
  int coveredFlexibleCourses = 0;
  int uncoveredFlexibleCourses = 0;

  final TextEditingController searchC = TextEditingController();

  bool overviewExpanded = true;
  bool attentionExpanded = false;
  bool coursesExpanded = true;
  bool teachersExpanded = true;

  final Set<String> expandedTeacherIds = {};

  final List<String> dayKeys = const [
    'mon',
    'tue',
    'wed',
    'thu',
    'fri',
    'sat',
    'sun',
  ];

  final Map<String, String> dayLabels = const {
    'mon': 'Mon',
    'tue': 'Tue',
    'wed': 'Wed',
    'thu': 'Thu',
    'fri': 'Fri',
    'sat': 'Sat',
    'sun': 'Sun',
  };

  @override
  void initState() {
    super.initState();
    searchC.addListener(() {
      if (!mounted) return;
      setState(() {
        searchText = searchC.text.trim().toLowerCase();
      });
    });
    _loadAll();
  }

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  bool _toBool(dynamic v, {bool fallback = false}) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return fallback;
  }

  int _slotCountFromWeek(Map<String, Set<String>> week) {
    int count = 0;
    for (final dk in dayKeys) {
      count += (week[dk] ?? const <String>{}).length;
    }
    return count;
  }

  String _fullNameFromUserMap(Map<String, dynamic> m) {
    final first = (m['first_name'] ?? '').toString().trim();
    final last = (m['last_name'] ?? '').toString().trim();
    return '$first $last'.trim();
  }

  Future<void> _loadAll() async {
    setState(() => loading = true);

    try {
      final results = await Future.wait([
        _db.child('booking_availability').get(),
        _db.child('users').get(),
        _db.child('syllabi').get(),
      ]);

      final bookingSnap = results[0];
      final usersSnap = results[1];
      final syllabiSnap = results[2];

      final Map<String, dynamic> bookingRoot = bookingSnap.value is Map
          ? (bookingSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : {};

      final Map<String, dynamic> usersRoot = usersSnap.value is Map
          ? (usersSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : {};

      final Map<String, dynamic> syllabiRoot = syllabiSnap.value is Map
          ? (syllabiSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : {};

      final Map<String, _CourseMeta> flexibleMap = {};
      final Map<String, _CourseMeta> fallbackCourseMap = {};

      syllabiRoot.forEach((courseId, raw) {
        if (raw is! Map) return;
        final m = raw.map((k, v) => MapEntry(k.toString(), v));
        final flex = m['flexible'];
        if (flex is! Map) return;

        final fm = flex.map((k, v) => MapEntry(k.toString(), v));
        final realCourseId = (fm['courseId'] ?? courseId).toString().trim();
        if (realCourseId.isEmpty) return;

        flexibleMap[realCourseId] = _CourseMeta(
          id: realCourseId,
          title: (fm['title'] ?? 'Untitled').toString().trim().isEmpty
              ? 'Untitled'
              : (fm['title'] ?? 'Untitled').toString().trim(),
          code: (fm['courseCode'] ?? '').toString().trim(),
        );
      });

      usersRoot.forEach((uid, rawUser) {
        if (rawUser is! Map) return;
        final um = rawUser.map((k, v) => MapEntry(k.toString(), v));

        final coursesRaw = um['courses'];
        if (coursesRaw is! Map) return;

        final coursesMap = coursesRaw.map((k, v) => MapEntry(k.toString(), v));

        for (final entry in coursesMap.entries) {
          final val = entry.value;
          if (val is! Map) continue;

          final cm = val.map((k, v) => MapEntry(k.toString(), v));
          final id = (cm['id'] ?? '').toString().trim();
          if (id.isEmpty) continue;

          fallbackCourseMap[id] = _CourseMeta(
            id: id,
            title: (cm['title'] ?? '').toString().trim(),
            code: (cm['course_code'] ?? '').toString().trim(),
          );
        }
      });

      final Set<String> teacherIds = {};

      usersRoot.forEach((uid, rawUser) {
        if (rawUser is! Map) return;
        final um = rawUser.map((k, v) => MapEntry(k.toString(), v));
        final role = (um['role'] ?? '').toString().trim().toLowerCase();
        if (role == 'teacher') {
          teacherIds.add(uid);
        }
      });

      teacherIds.addAll(bookingRoot.keys);

      final List<_TeacherCoverage> builtTeachers = [];
      final Map<String, List<_TeacherCoverage>> courseCoverage = {};

      for (final teacherId in teacherIds) {
        final rawBooking = bookingRoot[teacherId];
        final bookingMap = rawBooking is Map
            ? rawBooking.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final rawUser = usersRoot[teacherId];
        final userMap = rawUser is Map
            ? rawUser.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final settingsRaw = bookingMap['settings'];
        final settingsMap = settingsRaw is Map
            ? settingsRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final teacherOnlineEnabled = _toBool(
          settingsMap['teacherOnlineEnabled'],
          fallback: false,
        );

        String teacherName = _fullNameFromUserMap(userMap);
        if (teacherName.isEmpty) {
          teacherName = (bookingMap['teacherName'] ?? '').toString().trim();
        }
        if (teacherName.isEmpty) {
          teacherName = 'Teacher';
        }

        final List<_CourseMeta> activeCourses = [];
        final Map<String, Set<String>> mergedWeek = {
          'mon': <String>{},
          'tue': <String>{},
          'wed': <String>{},
          'thu': <String>{},
          'fri': <String>{},
          'sat': <String>{},
          'sun': <String>{},
        };

        bookingMap.forEach((key, value) {
          if (key == 'settings' ||
              key == 'teacherId' ||
              key == 'teacherName' ||
              key == 'updatedAt') {
            return;
          }

          if (value is! Map) return;

          final cm = value.map((k, v) => MapEntry(k.toString(), v));
          final isCourseOn = _toBool(
            cm['courseOnlineEnabled'],
            fallback: false,
          );

          if (!teacherOnlineEnabled || !isCourseOn) return;

          final meta =
              flexibleMap[key] ??
              fallbackCourseMap[key] ??
              _CourseMeta(id: key, title: 'Course $key', code: '');

          activeCourses.add(meta);

          final weekRaw = cm['week'];
          if (weekRaw is Map) {
            final wm = weekRaw.map((k, v) => MapEntry(k.toString(), v));

            for (final dk in dayKeys) {
              final list = wm[dk];
              if (list is! List) continue;

              for (final item in list) {
                final hhmm = item.toString().trim();
                if (hhmm.isEmpty) continue;
                mergedWeek[dk]!.add(hhmm);
              }
            }
          }
        });

        activeCourses.sort((a, b) => a.title.compareTo(b.title));

        final slotCount = _slotCountFromWeek(mergedWeek);

        final teacher = _TeacherCoverage(
          teacherId: teacherId,
          teacherName: teacherName,
          teacherOnlineEnabled: teacherOnlineEnabled,
          activeCourses: activeCourses,
          mergedWeek: mergedWeek,
          slotCount: slotCount,
          email: (userMap['email'] ?? '').toString().trim(),
          status: (userMap['status'] ?? '').toString().trim(),
        );

        builtTeachers.add(teacher);

        for (final course in activeCourses) {
          courseCoverage.putIfAbsent(course.id, () => []);
          courseCoverage[course.id]!.add(teacher);
        }
      }

      builtTeachers.sort((a, b) {
        if (a.teacherOnlineEnabled != b.teacherOnlineEnabled) {
          return a.teacherOnlineEnabled ? -1 : 1;
        }
        return a.teacherName.toLowerCase().compareTo(
          b.teacherName.toLowerCase(),
        );
      });

      final uncovered = <_CourseMeta>[];
      for (final entry in flexibleMap.entries) {
        final cid = entry.key;
        final meta = entry.value;
        final covered =
            (courseCoverage[cid] ?? const <_TeacherCoverage>[]).isNotEmpty;
        if (!covered) uncovered.add(meta);
      }
      uncovered.sort((a, b) => a.title.compareTo(b.title));

      int on = 0;
      int off = 0;
      int onNoCourses = 0;
      int onNoSlots = 0;

      for (final t in builtTeachers) {
        if (t.teacherOnlineEnabled) {
          on++;
          if (t.activeCourses.isEmpty) onNoCourses++;
          if (t.activeCourses.isNotEmpty && t.slotCount == 0) onNoSlots++;
        } else {
          off++;
        }
      }

      if (!mounted) return;
      setState(() {
        teachers = builtTeachers;
        flexibleCourses = flexibleMap.values.toList()
          ..sort((a, b) => a.title.compareTo(b.title));
        coveredByCourse = courseCoverage;
        uncoveredCourses = uncovered;

        totalTeachers = builtTeachers.length;
        teachersOn = on;
        teachersOff = off;
        teachersOnNoCourses = onNoCourses;
        teachersOnNoSlots = onNoSlots;
        coveredFlexibleCourses = flexibleMap.length - uncovered.length;
        uncoveredFlexibleCourses = uncovered.length;

        expandedTeacherIds.removeWhere(
          (id) => !builtTeachers.any((t) => t.teacherId == id),
        );
      });
    } catch (e) {
      _toast('Failed loading teacher availability: $e');
    } finally {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  List<_TeacherCoverage> _filteredTeachers() {
    if (searchText.isEmpty) return teachers;

    return teachers.where((t) {
      final haystack = [
        t.teacherName,
        t.teacherId,
        t.email,
        t.status,
        t.teacherOnlineEnabled ? 'on' : 'off',
        ...t.activeCourses.map((e) => e.title),
        ...t.activeCourses.map((e) => e.code),
      ].join(' ').toLowerCase();

      return haystack.contains(searchText);
    }).toList();
  }

  List<_CourseMeta> _filteredUncoveredCourses() {
    if (searchText.isEmpty) return uncoveredCourses;

    return uncoveredCourses.where((c) {
      final haystack = '${c.title} ${c.code} ${c.id}'.toLowerCase();
      return haystack.contains(searchText);
    }).toList();
  }

  Color _teacherStatusColor(_TeacherCoverage t) {
    if (!t.teacherOnlineEnabled) return Colors.grey.shade700;
    if (t.activeCourses.isEmpty) return actionOrange;
    if (t.slotCount == 0) return actionOrange;
    return successGreen;
  }

  String _teacherStatusLabel(_TeacherCoverage t) {
    if (!t.teacherOnlineEnabled) return 'OFF';
    if (t.activeCourses.isEmpty) return 'ON • No course';
    if (t.slotCount == 0) return 'ON • No slots';
    return 'ON • Active';
  }

  String _dayPreview(Set<String> slots) {
    if (slots.isEmpty) return '—';
    final sorted = slots.toList()..sort();
    final shown = sorted.take(3).join(', ');
    return sorted.length > 3 ? '$shown …' : shown;
  }

  String _teacherCoursePreview(_TeacherCoverage t) {
    if (t.activeCourses.isEmpty) return 'No active courses';
    final names = t.activeCourses.map((e) => e.code.isEmpty ? e.title : e.code);
    final list = names.take(3).join(' • ');
    return t.activeCourses.length > 3 ? '$list …' : list;
  }

  List<String> _allVisibleTimeSlots(List<_TeacherCoverage> sourceTeachers) {
    final Set<String> slots = {};
    for (final teacher in sourceTeachers) {
      for (final dk in dayKeys) {
        slots.addAll(teacher.mergedWeek[dk] ?? const <String>{});
      }
    }
    final list = slots.toList()..sort();
    return list;
  }

  void _showCourseTeachersSheet(_CourseMeta course) {
    final list = (coveredByCourse[course.id] ?? <_TeacherCoverage>[])
      ..sort((a, b) => a.teacherName.compareTo(b.teacherName));

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                children: [
                  Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              course.title.isEmpty ? course.id : course.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                color: primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              course.code.isEmpty
                                  ? course.id
                                  : '${course.code} • ${course.id}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: mutedText,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: list.isEmpty
                              ? Colors.red.withValues(alpha: 0.10)
                              : successGreen.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          list.isEmpty
                              ? '0 teachers'
                              : '${list.length} teacher${list.length == 1 ? '' : 's'}',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: list.isEmpty ? Colors.red : successGreen,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: list.isEmpty
                        ? Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: uiBorder),
                            ),
                            child: const Text(
                              'No active teacher currently covers this course.',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: primaryBlue,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final t = list[index];
                              final statusColor = _teacherStatusColor(t);

                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: uiBorder),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            t.teacherName,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: primaryBlue,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: statusColor.withValues(
                                              alpha: 0.10,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            _teacherStatusLabel(t),
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              fontSize: 11,
                                              color: statusColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (t.email.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        t.email,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: Colors.grey.shade700,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _miniStat(
                                          label: 'Courses',
                                          value: '${t.activeCourses.length}',
                                          color: primaryBlue,
                                        ),
                                        _miniStat(
                                          label: 'Slots',
                                          value: '${t.slotCount}',
                                          color: actionOrange,
                                        ),
                                        _miniStat(
                                          label: 'Status',
                                          value: t.status.isEmpty
                                              ? '—'
                                              : t.status,
                                          color: successGreen,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    _buildWeeklyTimetable(
                                      t.mergedWeek,
                                      dense: true,
                                    ),
                                  ],
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
      },
    );
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: primaryBlue,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: mutedText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        color: primaryBlue,
                      ),
                    ),
                  ),
                  if (trailing != null) ...[trailing, const SizedBox(width: 8)],
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: primaryBlue,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: expanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: child,
            ),
            secondChild: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _courseChip(_CourseMeta c, {Color? color}) {
    final chipColor = color ?? primaryBlue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: chipColor.withValues(alpha: 0.20)),
      ),
      child: Text(
        c.code.isEmpty ? c.title : '${c.title} • ${c.code}',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 11,
          color: chipColor,
        ),
      ),
    );
  }

  Widget _buildUncoveredCourses() {
    final items = _filteredUncoveredCourses();

    if (items.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: uncoveredCourses.isEmpty
              ? successGreen.withValues(alpha: 0.08)
              : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder),
        ),
        child: Text(
          uncoveredCourses.isEmpty
              ? 'All flexible courses currently have at least one active teacher.'
              : 'No uncovered courses match your search.',
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: primaryBlue,
          ),
        ),
      );
    }

    return Column(
      children: items.map((course) {
        return InkWell(
          onTap: () => _showCourseTeachersSheet(course),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: uiBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.red,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        course.title.isEmpty ? course.id : course.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        course.code.isEmpty
                            ? course.id
                            : '${course.code} • ${course.id}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.grey.shade700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Needs teacher',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.red,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCoveredCourseCards() {
    if (flexibleCourses.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder),
        ),
        child: const Text(
          'No flexible courses found.',
          style: TextStyle(fontWeight: FontWeight.w800, color: primaryBlue),
        ),
      );
    }

    final filtered = flexibleCourses.where((c) {
      if (searchText.isEmpty) return true;
      final haystack = '${c.title} ${c.code} ${c.id}'.toLowerCase();
      return haystack.contains(searchText);
    }).toList();

    if (filtered.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder),
        ),
        child: const Text(
          'No course cards match your search.',
          style: TextStyle(fontWeight: FontWeight.w800, color: primaryBlue),
        ),
      );
    }

    return Column(
      children: filtered.map((course) {
        final list = (coveredByCourse[course.id] ?? <_TeacherCoverage>[])
          ..sort((a, b) => a.teacherName.compareTo(b.teacherName));
        final isCovered = list.isNotEmpty;

        return InkWell(
          onTap: () => _showCourseTeachersSheet(course),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: uiBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: (isCovered ? successGreen : Colors.red).withValues(
                      alpha: 0.10,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isCovered
                        ? Icons.check_circle_rounded
                        : Icons.error_outline_rounded,
                    color: isCovered ? successGreen : Colors.red,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        course.title.isEmpty ? course.id : course.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        course.code.isEmpty
                            ? course.id
                            : '${course.code} • ${course.id}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.grey.shade700,
                          fontSize: 12,
                        ),
                      ),
                      if (list.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          list.map((e) => e.teacherName).take(3).join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: mutedText,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: (isCovered ? successGreen : Colors.red)
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        isCovered
                            ? '${list.length} teacher${list.length == 1 ? '' : 's'}'
                            : '0 teachers',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: isCovered ? successGreen : Colors.red,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Icon(Icons.chevron_right_rounded, color: mutedText),
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildAttentionBox() {
    final List<_TeacherCoverage> attention = teachers.where((t) {
      if (!t.teacherOnlineEnabled) return true;
      if (t.activeCourses.isEmpty) return true;
      if (t.slotCount == 0) return true;
      return false;
    }).toList();

    if (attention.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: successGreen.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder),
        ),
        child: const Text(
          'No attention items right now.',
          style: TextStyle(fontWeight: FontWeight.w800, color: primaryBlue),
        ),
      );
    }

    return Column(
      children: attention.map((t) {
        String issue;
        Color color;

        if (!t.teacherOnlineEnabled) {
          issue = 'Teacher OFF';
          color = Colors.grey.shade700;
        } else if (t.activeCourses.isEmpty) {
          issue = 'ON but no active course';
          color = actionOrange;
        } else {
          issue = 'ON but no weekly slots';
          color = actionOrange;
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: uiBorder),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${t.teacherName} • $issue',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: primaryBlue,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildWeeklyTimetable(
    Map<String, Set<String>> mergedWeek, {
    bool dense = false,
  }) {
    final allSlots = <String>{};
    for (final dk in dayKeys) {
      allSlots.addAll(mergedWeek[dk] ?? const <String>{});
    }

    final sortedTimes = allSlots.toList()..sort();

    if (sortedTimes.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: uiBorder),
        ),
        child: const Text(
          'No weekly slots.',
          style: TextStyle(fontWeight: FontWeight.w700, color: mutedText),
        ),
      );
    }

    final visibleTimes = dense && sortedTimes.length > 10
        ? sortedTimes.take(10).toList()
        : sortedTimes;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder),
        ),
        child: Column(
          children: [
            Row(
              children: [
                _timeCell('Time', header: true, width: dense ? 64 : 72),
                ...dayKeys.map(
                  (dk) => _gridCell(
                    dayLabels[dk] ?? dk,
                    header: true,
                    width: dense ? 54 : 60,
                    height: dense ? 30 : 34,
                  ),
                ),
              ],
            ),
            ...visibleTimes.map((time) {
              return Row(
                children: [
                  _timeCell(time, width: dense ? 64 : 72),
                  ...dayKeys.map((dk) {
                    final hasSlot = (mergedWeek[dk] ?? const <String>{})
                        .contains(time);
                    return _gridCell(
                      hasSlot ? '●' : '',
                      width: dense ? 54 : 60,
                      height: dense ? 28 : 32,
                      active: hasSlot,
                    );
                  }),
                ],
              );
            }),
            if (dense && sortedTimes.length > 10)
              Container(
                width: (64 + (7 * 54)).toDouble(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: uiBorder)),
                ),
                child: Text(
                  'Showing first 10 time rows',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _gridCell(
    String text, {
    required double width,
    required double height,
    bool header = false,
    bool active = false,
  }) {
    final bg = header
        ? primaryBlue.withValues(alpha: 0.06)
        : active
        ? actionOrange.withValues(alpha: 0.12)
        : Colors.white;

    final textColor = header
        ? primaryBlue
        : active
        ? actionOrange
        : mutedText;

    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: uiBorder),
          top: BorderSide(color: uiBorder),
        ),
        color: Colors.transparent,
      ),
      child: Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        color: bg,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: header || active ? FontWeight.w900 : FontWeight.w700,
            fontSize: 11,
            color: textColor,
          ),
        ),
      ),
    );
  }

  Widget _timeCell(String text, {required double width, bool header = false}) {
    return Container(
      width: width,
      height: header ? 34 : 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: header
            ? primaryBlue.withValues(alpha: 0.06)
            : Colors.grey.shade50,
        border: const Border(top: BorderSide(color: uiBorder)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 11,
          color: primaryBlue,
        ),
      ),
    );
  }

  Widget _buildTeacherCard(_TeacherCoverage t) {
    final statusColor = _teacherStatusColor(t);
    final isExpanded = expandedTeacherIds.contains(t.teacherId);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              setState(() {
                if (isExpanded) {
                  expandedTeacherIds.remove(t.teacherId);
                } else {
                  expandedTeacherIds.add(t.teacherId);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.teacherName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: primaryBlue,
                          ),
                        ),
                        if (t.email.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            t.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _miniStat(
                              label: 'Courses',
                              value: '${t.activeCourses.length}',
                              color: primaryBlue,
                            ),
                            _miniStat(
                              label: 'Slots',
                              value: '${t.slotCount}',
                              color: actionOrange,
                            ),
                            _miniStat(
                              label: 'Status',
                              value: t.status.isEmpty ? '—' : t.status,
                              color: successGreen,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _teacherCoursePreview(t),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _teacherStatusLabel(t),
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            color: statusColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Icon(
                        isExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: primaryBlue,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: isExpanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Text(
                    'Active courses',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.grey.shade800,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (t.activeCourses.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: uiBorder),
                      ),
                      child: const Text(
                        'No active course coverage.',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: mutedText,
                        ),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: t.activeCourses
                          .map(
                            (c) => GestureDetector(
                              onTap: () => _showCourseTeachersSheet(c),
                              child: _courseChip(c, color: primaryBlue),
                            ),
                          )
                          .toList(),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Weekly timetable',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.grey.shade800,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildWeeklyTimetable(t.mergedWeek),
                  const SizedBox(height: 10),
                  Column(
                    children: dayKeys.map((dk) {
                      final slots = t.mergedWeek[dk] ?? const <String>{};

                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: uiBorder),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 44,
                              child: Text(
                                dayLabels[dk] ?? dk,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: primaryBlue,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _dayPreview(slots),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey.shade700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: slots.isEmpty
                                    ? Colors.grey.shade100
                                    : actionOrange.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${slots.length}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: slots.isEmpty
                                      ? Colors.grey.shade700
                                      : actionOrange,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            secondChild: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _miniStat({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 11,
          color: color,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredTeachers = _filteredTeachers();

    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_teacher_availability_overview',
      title: 'توفر المعلمين',
      line: 'تعرض هذه الشاشة تغطية توفر المعلمين للحجز اونلاين حسب الدورات.',
    );

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
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            onPressed: loading ? null : _loadAll,
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1620,
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
                children: [
                  _buildSection(
                    title: 'Overview',
                    expanded: overviewExpanded,
                    onToggle: () {
                      setState(() => overviewExpanded = !overviewExpanded);
                    },
                    child: Column(
                      children: [
                        TextField(
                          controller: searchC,
                          decoration: InputDecoration(
                            hintText: 'Search teacher / course / code / email',
                            isDense: true,
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: searchC.text.trim().isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () => searchC.clear(),
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: uiBorder),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        GridView.count(
                          crossAxisCount:
                              MediaQuery.of(context).size.width >= 900 ? 3 : 2,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 2.5,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            _summaryCard(
                              title: 'Total teachers',
                              value: '$totalTeachers',
                              icon: Icons.badge_rounded,
                              color: primaryBlue,
                            ),
                            _summaryCard(
                              title: 'Teachers ON',
                              value: '$teachersOn',
                              icon: Icons.toggle_on_rounded,
                              color: successGreen,
                            ),
                            _summaryCard(
                              title: 'Teachers OFF',
                              value: '$teachersOff',
                              icon: Icons.toggle_off_rounded,
                              color: Colors.grey.shade700,
                            ),
                            _summaryCard(
                              title: 'ON • no courses',
                              value: '$teachersOnNoCourses',
                              icon: Icons.warning_amber_rounded,
                              color: actionOrange,
                            ),
                            _summaryCard(
                              title: 'Covered flexible',
                              value: '$coveredFlexibleCourses',
                              icon: Icons.check_circle_rounded,
                              color: successGreen,
                            ),
                            _summaryCard(
                              title: 'Uncovered flexible',
                              value: '$uncoveredFlexibleCourses',
                              icon: Icons.error_outline_rounded,
                              color: Colors.red,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildSection(
                    title: 'Attention',
                    expanded: attentionExpanded,
                    onToggle: () {
                      setState(() => attentionExpanded = !attentionExpanded);
                    },
                    child: _buildAttentionBox(),
                  ),
                  const SizedBox(height: 10),
                  _buildSection(
                    title: 'Course coverage',
                    expanded: coursesExpanded,
                    onToggle: () {
                      setState(() => coursesExpanded = !coursesExpanded);
                    },
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: primaryBlue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${flexibleCourses.length}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Tap a course card to view teachers covering it.',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                            color: mutedText,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _buildCoveredCourseCards(),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: uiBorder),
                          ),
                          child: Text(
                            'Courses needing teacher • ${_filteredUncoveredCourses().length}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Colors.red,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildUncoveredCourses(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildSection(
                    title: 'Teachers',
                    expanded: teachersExpanded,
                    onToggle: () {
                      setState(() => teachersExpanded = !teachersExpanded);
                    },
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: primaryBlue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${filteredTeachers.length}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    child: filteredTeachers.isEmpty
                        ? Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: uiBorder),
                            ),
                            child: const Text(
                              'No teachers match your search.',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: primaryBlue,
                              ),
                            ),
                          )
                        : Column(
                            children: filteredTeachers
                                .map(_buildTeacherCard)
                                .toList(),
                          ),
                  ),
                  if (teachersOnNoSlots > 0) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        'Note: $teachersOnNoSlots teacher${teachersOnNoSlots == 1 ? '' : 's'} are ON with active courses but zero merged weekly slots.',
                        style: const TextStyle(
                          color: mutedText,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _TeacherCoverage {
  final String teacherId;
  final String teacherName;
  final bool teacherOnlineEnabled;
  final List<_CourseMeta> activeCourses;
  final Map<String, Set<String>> mergedWeek;
  final int slotCount;
  final String email;
  final String status;

  _TeacherCoverage({
    required this.teacherId,
    required this.teacherName,
    required this.teacherOnlineEnabled,
    required this.activeCourses,
    required this.mergedWeek,
    required this.slotCount,
    required this.email,
    required this.status,
  });
}

class _CourseMeta {
  final String id;
  final String title;
  final String code;

  _CourseMeta({required this.id, required this.title, required this.code});
}
