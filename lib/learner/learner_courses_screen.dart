import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/watermark_background.dart';
import 'learner_course_detail_screen.dart';

class LearnerCoursesScreen extends StatefulWidget {
  const LearnerCoursesScreen({
    super.key,
    this.initialCourseKey,
  });

  final String? initialCourseKey;

  @override
  State<LearnerCoursesScreen> createState() => _LearnerCoursesScreenState();
}

class _LearnerCoursesScreenState extends State<LearnerCoursesScreen> {
  static const usersNode = 'users';
  static const syllabiNode = 'syllabi';
  static const bookingProgressNode = 'booking_progress';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  bool _busy = true;
  String? _error;

  String _uid = '';
  List<Map<String, dynamic>> _courses = [];
  bool _didOpenInitialCourse = false;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  _CoursesPalette get palette => _toCoursesPalette(appThemeController.palette);

  _CoursesPalette _toCoursesPalette(AppPalette p) {
    return _CoursesPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _courses = [];
      _uid = '';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      final snap = await _usersRef.child(_uid).child('courses').get();
      if (!snap.exists || snap.value == null) {
        setState(() => _busy = false);
        return;
      }

      final raw = Map<String, dynamic>.from(snap.value as Map);
      final list = raw.entries.map((e) {
        final m = (e.value is Map)
            ? Map<String, dynamic>.from(e.value as Map)
            : <String, dynamic>{};
        return {'courseKey': e.key.toString(), ...m};
      }).toList();

      int numVal(dynamic v) =>
          (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
      list.sort((a, b) => numVal(b['assignedAt']).compareTo(numVal(a['assignedAt'])));

      setState(() {
        _courses = list;
        _busy = false;
      });

      _openInitialCourseIfNeeded();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  void _openInitialCourseIfNeeded() {
    if (_didOpenInitialCourse) return;

    final targetKey = (widget.initialCourseKey ?? '').trim();
    if (targetKey.isEmpty) return;
    if (_courses.isEmpty) return;
    if (!mounted) return;

    final match = _courses.cast<Map<String, dynamic>?>().firstWhere(
          (course) => (course?['courseKey'] ?? '').toString() == targetKey,
      orElse: () => null,
    );

    if (match == null) return;

    _didOpenInitialCourse = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LearnerCourseDetailScreen(
            courseKey: targetKey,
            courseData: match,
          ),
        ),
      );
    });
  }
  String _courseIdOf(Map<String, dynamic> course) {
    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};
    return (cls['course_id'] ?? course['id'] ?? '').toString().trim();
  }

  String _variantKeyOf(Map<String, dynamic> course) {
    final raw = (course['variantKey'] ?? course['variant'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    switch (raw) {
      case 'in_class':
      case 'inclass':
      case 'in-class':
      case 'in class':
        return 'inclass';

      case 'online':
      case 'flexible':
        return 'flexible';

      case 'live':
      case 'private':
        return 'private';

      case 'recorded':
        return 'recorded';

      default:
        return raw;
    }
  }

  bool _isOnlineCourse(Map<String, dynamic> course) {
    final key = _variantKeyOf(course);
    return key == 'flexible' || key == 'private' || key == 'recorded';
  }

  ({
  Color bg,
  Color border,
  Color fg,
  IconData icon,
  String label,
  }) _variantStyle(String variantKey) {
    switch (variantKey) {
      case 'flexible':
        return (
        bg: const Color(0xFFEAF4FF),
        border: const Color(0xFFB8D6FF),
        fg: const Color(0xFF2563EB),
        icon: Icons.swap_horiz_rounded,
        label: 'FLEXIBLE',
        );

      case 'inclass':
        return (
        bg: const Color(0xFFEAF7EE),
        border: const Color(0xFFBFE3C8),
        fg: const Color(0xFF1E8E3E),
        icon: Icons.groups_rounded,
        label: 'IN-CLASS',
        );

      case 'private':
        return (
        bg: const Color(0xFFFFF4E8),
        border: const Color(0xFFF7D3A8),
        fg: const Color(0xFFF98D28),
        icon: Icons.person_rounded,
        label: 'PRIVATE',
        );

      case 'recorded':
        return (
        bg: const Color(0xFFF3EEFF),
        border: const Color(0xFFD8C8FF),
        fg: const Color(0xFF7C3AED),
        icon: Icons.play_circle_rounded,
        label: 'RECORDED',
        );

      default:
        final p = palette;
        return (
        bg: p.soft,
        border: p.border.withOpacity(0.85),
        fg: p.primary,
        icon: Icons.school_rounded,
        label: 'COURSE',
        );
    }
  }

  Map<String, int> _attendanceCounts(Map<String, dynamic> course) {
    final att = course['attendance'];
    if (att is! Map) return {'total': 0, 'present': 0};

    final m = Map<String, dynamic>.from(att);
    int total = 0;
    int present = 0;

    for (final v in m.values) {
      if (v is! Map) continue;
      final rec = Map<String, dynamic>.from(v);
      total += 1;
      final status = (rec['status'] ?? '').toString().toLowerCase();
      if (status == 'present') present += 1;
    }

    return {'total': total, 'present': present};
  }

  Future<Map<String, int>> _progressCounts(Map<String, dynamic> course) async {
    final courseId = _courseIdOf(course);
    final variantKey = _variantKeyOf(course);

    if (courseId.isEmpty) return {'total': 0, 'covered': 0};

    final Set<String> covered = {};
    final Map<int, String> sessionIdByNumber = {};
    int totalSyllabiSessions = 0;

    try {
      DatabaseReference syllabusRef = _syllabiRef.child(courseId);
      if (variantKey.isNotEmpty) {
        syllabusRef = syllabusRef.child(variantKey);
      }

      final sSnap = await syllabusRef.get();
      if (sSnap.exists && sSnap.value != null && sSnap.value is Map) {
        final s = Map<String, dynamic>.from(sSnap.value as Map);
        final units = s['units'];

        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final sessions = unit['sessions'];

            if (sessions is List) {
              totalSyllabiSessions += sessions.length;

              for (final ss in sessions) {
                if (ss is! Map) continue;
                final sess = Map<String, dynamic>.from(ss);
                final sid = (sess['id'] ?? '').toString().trim();
                final sn = _asInt(sess['sessionNumber']);

                if (sn > 0 && sid.isNotEmpty) {
                  sessionIdByNumber[sn] = sid;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    final att = course['attendance'];
    if (att is Map) {
      final a = Map<String, dynamic>.from(att);

      for (final v in a.values) {
        if (v is! Map) continue;
        final rec = Map<String, dynamic>.from(v);

        final taughtItems = rec['taughtItems'];
        bool usedNewFormat = false;

        if (taughtItems is List) {
          usedNewFormat = true;

          for (final it in taughtItems) {
            if (it is! Map) continue;
            final item = Map<String, dynamic>.from(it);

            final type = (item['type'] ?? '').toString().trim().toLowerCase();
            if (type != 'syllabus') continue;

            final sid = (item['sessionId'] ?? '').toString().trim();
            final sn = _asInt(item['sessionNumber']);

            if (sid.isNotEmpty) {
              covered.add(sid);
            } else if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) covered.add(mapped);
            }
          }
        }

        if (!usedNewFormat) {
          final taught = (rec['taught'] is Map)
              ? Map<String, dynamic>.from(rec['taught'] as Map)
              : <String, dynamic>{};
          final sid = (taught['sessionId'] ?? '').toString().trim();
          final sn = _asInt(taught['sessionNumber']);

          if (sid.isNotEmpty) {
            covered.add(sid);
          } else if (sn > 0) {
            final mapped = sessionIdByNumber[sn];
            if (mapped != null && mapped.isNotEmpty) covered.add(mapped);
          }
        }
      }
    }

    try {
      final onlineSnap = await _db
          .child('$bookingProgressNode/$_uid/$courseId/online_attendance')
          .get();
      if (onlineSnap.exists && onlineSnap.value is Map) {
        final om = Map<String, dynamic>.from(onlineSnap.value as Map);

        for (final entry in om.entries) {
          final v = entry.value;
          if (v is! Map) continue;
          final rec = Map<String, dynamic>.from(v);

          final taughtItems = rec['taughtItems'];
          if (taughtItems is List) {
            for (final it in taughtItems) {
              if (it is! Map) continue;
              final item = Map<String, dynamic>.from(it);

              final type = (item['type'] ?? '').toString().trim().toLowerCase();
              if (type != 'syllabus') continue;

              final sid = (item['sessionId'] ?? '').toString().trim();
              final sn = _asInt(item['sessionNumber']);

              if (sid.isNotEmpty) {
                covered.add(sid);
              } else if (sn > 0) {
                final mapped = sessionIdByNumber[sn];
                if (mapped != null && mapped.isNotEmpty) covered.add(mapped);
              }
            }
          } else {
            final sn = _asInt(rec['sessionNo']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) covered.add(mapped);
            }
          }
        }
      }
    } catch (_) {}

    return {'total': totalSyllabiSessions, 'covered': covered.length};
  }

  String _paymentStateFromSummary({
    required int sessionsDone,
    required Map<String, dynamic> summary,
  }) {
    final sessionsPaidTotal = _asInt(summary['sessionsPaidTotal']);
    final remindBeforeSession = _asInt(summary['remindBeforeSession']);

    if (sessionsPaidTotal <= 0) return '';

    final warnBefore = (remindBeforeSession > 0) ? remindBeforeSession : 1;

    final overdue = sessionsDone >= sessionsPaidTotal;
    final dueSoon = !overdue && sessionsDone >= (sessionsPaidTotal - warnBefore);

    if (overdue) return 'PAYMENT NEEDED';
    if (dueSoon) return 'PAYMENT SOON';

    return '';
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Text(
          'My Courses',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: WatermarkBackground(
        child: _busy
            ? Center(
          child: CircularProgressIndicator(color: p.primary),
        )
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: p.cardBg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: p.border.withOpacity(0.85)),
              ),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        )
            : _courses.isEmpty
            ? _EmptyCoursesState(palette: p, onRefresh: _load)
            : RefreshIndicator(
          color: p.primary,
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            children: [
              _CoursesHeroCard(
                palette: p,
                coursesCount: _courses.length,
              ),
              const SizedBox(height: 16),
              ..._courses.map(_courseCard).toList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _courseCard(Map<String, dynamic> course) {
    final p = palette;
    final courseKey = (course['courseKey'] ?? '').toString();
    final title =
    (course['title'] ?? course['course_title'] ?? 'Course').toString();
    final code = (course['course_code'] ?? '').toString();

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};
    final classId = (cls['class_id'] ?? '').toString().trim();
    final instructor =
    (cls['instructor'] ?? cls['teacher_name'] ?? '').toString().trim();
    final status = (cls['status'] ?? course['status'] ?? '').toString().trim();

    final variantKey = _variantKeyOf(course);
    final isOnline = _isOnlineCourse(course);
    final variantStyle = _variantStyle(variantKey);

    final attCounts = _attendanceCounts(course);
    final total = attCounts['total'] ?? 0;
    final present = attCounts['present'] ?? 0;
    final attPct = total == 0 ? 0 : ((present / total) * 100).round();

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.border.withOpacity(0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: variantStyle.bg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: variantStyle.border),
                  ),
                  child: Icon(
                    variantStyle.icon,
                    color: variantStyle.fg,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        code.isEmpty ? 'Code: -' : 'Code: $code',
                        style: TextStyle(
                          color: p.text.withOpacity(0.66),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _BadgePill(
                  bg: variantStyle.bg,
                  border: variantStyle.border,
                  fg: variantStyle.fg,
                  icon: variantStyle.icon,
                  label: variantStyle.label,
                ),
                if (classId.isNotEmpty)
                  _NeutralPill(
                    palette: p,
                    icon: Icons.badge_rounded,
                    label: 'Class $classId',
                  ),
                if (status.isNotEmpty)
                  _NeutralPill(
                    palette: p,
                    icon: Icons.info_outline_rounded,
                    label: status,
                  ),
                StreamBuilder<DatabaseEvent>(
                  stream: _usersRef
                      .child(_uid)
                      .child('courses')
                      .child(courseKey)
                      .child('payment_summary')
                      .onValue,
                  builder: (context, snap) {
                    final raw = snap.data?.snapshot.value;
                    final sum = raw is Map
                        ? raw.map((k, v) => MapEntry(k.toString(), v))
                        : <String, dynamic>{};

                    final attCounts = _attendanceCounts(course);
                    final sessionsDone = attCounts['total'] ?? 0;

                    final state = _paymentStateFromSummary(
                      sessionsDone: sessionsDone,
                      summary: sum,
                    );

                    if (state.isEmpty) return const SizedBox.shrink();

                    final bool isDue = state == 'PAYMENT NEEDED';

                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: (isDue ? Colors.red : p.accent).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: (isDue ? Colors.red : p.accent).withOpacity(0.28),
                        ),
                      ),
                      child: Text(
                        state,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                          color: isDue ? Colors.red : p.accent,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            _InfoLine(
              palette: p,
              icon: Icons.person_outline_rounded,
              text: instructor.isEmpty ? 'Teacher: -' : 'Teacher: $instructor',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _kpiTile(
                    icon: Icons.how_to_reg_rounded,
                    label: 'Attendance',
                    value: '$attPct%',
                    accent: variantStyle.fg,
                    tint: variantStyle.bg,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FutureBuilder<Map<String, int>>(
                    future: _progressCounts(course),
                    builder: (_, snap) {
                      final data = snap.data ?? {'total': 0, 'covered': 0};
                      final t = data['total'] ?? 0;
                      final c = data['covered'] ?? 0;
                      final pct = t == 0 ? 0 : ((c / t) * 100).round();

                      return _kpiTile(
                        icon: Icons.insights_rounded,
                        label: 'Progress',
                        value: '$pct%',
                        accent: variantStyle.fg,
                        tint: variantStyle.bg,
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.visibility_rounded),
                label: const Text('Open Course'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isOnline ? variantStyle.fg : p.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LearnerCourseDetailScreen(
                        courseKey: courseKey,
                        courseData: course,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kpiTile({
    required IconData icon,
    required String label,
    required String value,
    Color? accent,
    Color? tint,
  }) {
    final p = palette;
    final iconColor = accent ?? p.accent;
    final bgColor = tint ?? p.soft;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withOpacity(0.85)),
        color: bgColor,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.55),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: p.text.withOpacity(0.68),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoursesHeroCard extends StatelessWidget {
  const _CoursesHeroCard({
    required this.palette,
    required this.coursesCount,
  });

  final _CoursesPalette palette;
  final int coursesCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.primary,
            palette.primary.withOpacity(0.88),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withOpacity(0.18),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: const Icon(
              Icons.menu_book_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'My Courses',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$coursesCount course${coursesCount == 1 ? '' : 's'} assigned',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.86),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({
    required this.bg,
    required this.border,
    required this.fg,
    required this.icon,
    required this.label,
  });

  final Color bg;
  final Color border;
  final Color fg;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 11,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

class _NeutralPill extends StatelessWidget {
  const _NeutralPill({
    required this.palette,
    required this.icon,
    required this.label,
  });

  final _CoursesPalette palette;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.soft.withOpacity(0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border.withOpacity(0.85)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: palette.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 11,
              color: palette.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.palette,
    required this.icon,
    required this.text,
  });

  final _CoursesPalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: palette.text.withOpacity(0.62)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: palette.text.withOpacity(0.72),
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyCoursesState extends StatelessWidget {
  const _EmptyCoursesState({
    required this.palette,
    required this.onRefresh,
  });

  final _CoursesPalette palette;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: palette.border.withOpacity(0.85)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: palette.soft,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(
                  Icons.menu_book_rounded,
                  color: palette.primary,
                  size: 30,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'No courses assigned yet.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'When courses are assigned to your account, they will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.text.withOpacity(0.68),
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Refresh'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.primary,
                  side: BorderSide(color: palette.border.withOpacity(0.9)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoursesPalette {
  const _CoursesPalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}
