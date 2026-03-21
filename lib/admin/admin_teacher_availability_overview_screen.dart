import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  bool _toBool(dynamic v, {bool fallback = false}) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return fallback;
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

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
    final full = '$first $last'.trim();
    return full;
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

      final Map<String, dynamic> bookingRoot =
      bookingSnap.value is Map ? (bookingSnap.value as Map).map((k, v) => MapEntry(k.toString(), v)) : {};

      final Map<String, dynamic> usersRoot =
      usersSnap.value is Map ? (usersSnap.value as Map).map((k, v) => MapEntry(k.toString(), v)) : {};

      final Map<String, dynamic> syllabiRoot =
      syllabiSnap.value is Map ? (syllabiSnap.value as Map).map((k, v) => MapEntry(k.toString(), v)) : {};

      final Map<String, _CourseMeta> flexibleMap = {};
      final Map<String, _CourseMeta> fallbackCourseMap = {};

      // Build flexible courses from syllabi
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

      // Build fallback titles/codes from teacher user nodes
      usersRoot.forEach((uid, rawUser) {
        if (rawUser is! Map) return;
        final um = rawUser.map((k, v) => MapEntry(k.toString(), v));

        final coursesRaw = um['courses'];
        if (coursesRaw is! Map) return;

        final coursesMap =
        coursesRaw.map((k, v) => MapEntry(k.toString(), v));

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

      // Teachers from users with role teacher
      usersRoot.forEach((uid, rawUser) {
        if (rawUser is! Map) return;
        final um = rawUser.map((k, v) => MapEntry(k.toString(), v));
        final role = (um['role'] ?? '').toString().trim().toLowerCase();
        if (role == 'teacher') {
          teacherIds.add(uid);
        }
      });

      // Teachers from booking_availability
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

        final Set<String> activeCourseIds = {};
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

          activeCourseIds.add(key);

          final meta =
              flexibleMap[key] ??
                  fallbackCourseMap[key] ??
                  _CourseMeta(
                    id: key,
                    title: 'Course $key',
                    code: '',
                  );

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
        final covered = (courseCoverage[cid] ?? const <_TeacherCoverage>[]).isNotEmpty;
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
        coveredFlexibleCourses =
            flexibleMap.length - uncovered.length;
        uncoveredFlexibleCourses = uncovered.length;
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
    final shown = sorted.take(4).join(', ');
    return sorted.length > 4 ? '$shown …' : shown;
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                    color: primaryBlue,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
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

  Widget _sectionCard({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
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
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: primaryBlue,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _courseChip(_CourseMeta c, {Color? color}) {
    final chipColor = color ?? primaryBlue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: chipColor.withOpacity(0.20)),
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
              ? successGreen.withOpacity(0.08)
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
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.10),
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
                      course.code.isEmpty ? course.id : '${course.code} • ${course.id}',
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
                padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.10),
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
          color: successGreen.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: uiBorder),
        ),
        child: const Text(
          'No attention items right now.',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: primaryBlue,
          ),
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

  Widget _buildTeacherCard(_TeacherCoverage t) {
    final statusColor = _teacherStatusColor(t);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                      fontSize: 15,
                      color: primaryBlue,
                    ),
                  ),
                ),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.10),
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
                  value: t.status.isEmpty ? '—' : t.status,
                  color: successGreen,
                ),
              ],
            ),
            const SizedBox(height: 10),
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
                    .map((c) => _courseChip(c, color: primaryBlue))
                    .toList(),
              ),
            const SizedBox(height: 12),
            Text(
              'Weekly schedule',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: Colors.grey.shade800,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            ...dayKeys.map((dk) {
              final slots = t.mergedWeek[dk] ?? const <String>{};

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
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
                            : actionOrange.withOpacity(0.10),
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
            }),
          ],
        ),
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
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.18)),
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

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Teacher Availability',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: loading ? null : _loadAll,
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
        children: [
          _sectionCard(
            title: 'Overview',
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
                  childAspectRatio: 2.25,
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
          _sectionCard(
            title: 'Attention',
            child: _buildAttentionBox(),
          ),
          const SizedBox(height: 10),
          _sectionCard(
            title: 'Courses needing teacher',
            trailing: Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.10),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${_filteredUncoveredCourses().length}',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Colors.red,
                  fontSize: 11,
                ),
              ),
            ),
            child: _buildUncoveredCourses(),
          ),
          const SizedBox(height: 10),
          _sectionCard(
            title: 'Teachers',
            trailing: Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: primaryBlue.withOpacity(0.08),
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
            const SizedBox(height: 4),
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

  _CourseMeta({
    required this.id,
    required this.title,
    required this.code,
  });
}