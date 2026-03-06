import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import 'learner_course_detail_screen.dart';

class LearnerCoursesScreen extends StatefulWidget {
  const LearnerCoursesScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    _load();
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
        final m = (e.value is Map) ? Map<String, dynamic>.from(e.value as Map) : <String, dynamic>{};
        return {'courseKey': e.key.toString(), ...m};
      }).toList();

      int numVal(dynamic v) => (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
      list.sort((a, b) => numVal(b['assignedAt']).compareTo(numVal(a['assignedAt'])));

      setState(() {
        _courses = list;
        _busy = false;
      });
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

  String _courseIdOf(Map<String, dynamic> course) {
    final cls = (course['class'] is Map) ? Map<String, dynamic>.from(course['class'] as Map) : <String, dynamic>{};
    return (cls['course_id'] ?? course['id'] ?? '').toString().trim();
  }

  String _variantKeyOf(Map<String, dynamic> course) {
    return (course['variantKey'] ?? course['variant'] ?? '').toString().trim().toLowerCase();
  }

  bool _isOnlineCourse(Map<String, dynamic> course) {
    return _variantKeyOf(course) == 'online';
  }

  ({Color bg, Color border, Color fg, IconData icon, String label}) _variantStyle(String variantKey) {
    switch (variantKey) {
      case 'online':
        return (
        bg: const Color(0xFFEAF4FF),
        border: const Color(0xFFB8D6FF),
        fg: const Color(0xFF2563EB),
        icon: Icons.wifi_tethering_rounded,
        label: 'ONLINE',
        );
      case 'in_class':
        return (
        bg: const Color(0xFFEAF7EE),
        border: const Color(0xFFBFE3C8),
        fg: const Color(0xFF1E8E3E),
        icon: Icons.groups_rounded,
        label: 'IN-CLASS',
        );
      case 'live':
        return (
        bg: const Color(0xFFFFF4E8),
        border: const Color(0xFFF7D3A8),
        fg: const Color(0xFFF98D28),
        icon: Icons.live_tv_rounded,
        label: 'LIVE',
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
        return (
        bg: UiK.primaryBlue.withOpacity(0.06),
        border: UiK.uiBorder.withOpacity(0.85),
        fg: UiK.primaryBlue,
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
          final taught = (rec['taught'] is Map) ? Map<String, dynamic>.from(rec['taught'] as Map) : <String, dynamic>{};
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
      final onlineSnap = await _db.child('$bookingProgressNode/$_uid/$courseId/online_attendance').get();
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
    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: const Text(
          'My Courses',
          style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: WatermarkBackground(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
          ),
        )
            : _courses.isEmpty
            ? const Center(
          child: Text(
            'No courses assigned yet.',
            style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800),
          ),
        )
            : ListView(
          padding: const EdgeInsets.all(16),
          children: _courses.map(_courseCard).toList(),
        ),
      ),
    );
  }

  Widget _courseCard(Map<String, dynamic> course) {
    final courseKey = (course['courseKey'] ?? '').toString();
    final title = (course['title'] ?? course['course_title'] ?? 'Course').toString();
    final code = (course['course_code'] ?? '').toString();

    final cls = (course['class'] is Map) ? Map<String, dynamic>.from(course['class'] as Map) : <String, dynamic>{};
    final classId = (cls['class_id'] ?? '').toString().trim();
    final instructor = (cls['instructor'] ?? cls['teacher_name'] ?? '').toString().trim();
    final status = (cls['status'] ?? course['status'] ?? '').toString().trim();

    final variantKey = _variantKeyOf(course);
    final isOnline = _isOnlineCourse(course);
    final variantStyle = _variantStyle(variantKey);

    final attCounts = _attendanceCounts(course);
    final total = attCounts['total'] ?? 0;
    final present = attCounts['present'] ?? 0;
    final attPct = total == 0 ? 0 : ((present / total) * 100).round();

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      margin: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: variantStyle.border.withOpacity(0.85)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: UiK.titleText())),
                  const SizedBox(width: 8),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: variantStyle.bg,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: variantStyle.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(variantStyle.icon, size: 14, color: variantStyle.fg),
                        const SizedBox(width: 6),
                        Text(
                          variantStyle.label,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            color: variantStyle.fg,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),

                  StreamBuilder<DatabaseEvent>(
                    stream: _usersRef.child(_uid).child('courses').child(courseKey).child('payment_summary').onValue,
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
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: (isDue ? Colors.red : UiK.actionOrange).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: (isDue ? Colors.red : UiK.actionOrange).withOpacity(0.28),
                          ),
                        ),
                        child: Text(
                          state,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                            color: isDue ? Colors.red : UiK.actionOrange,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),

              Text(
                'Code: ${code.isEmpty ? '-' : code}',
                style: UiK.subtleText(),
              ),

              if (!isOnline) ...[
                const SizedBox(height: 4),
                Text(
                  'Class: ${classId.isEmpty ? '-' : classId}',
                  style: UiK.subtleText(),
                ),
                const SizedBox(height: 4),
                Text(
                  'Teacher: ${instructor.isEmpty ? '-' : instructor} • Status: ${status.isEmpty ? '-' : status}',
                  style: UiK.subtleText(),
                ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  'Status: ${status.isEmpty ? 'Online course' : status}',
                  style: UiK.subtleText(),
                ),
              ],

              const SizedBox(height: 10),

              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _kpiChip(
                    icon: Icons.how_to_reg_rounded,
                    label: 'Attendance',
                    value: '$attPct%',
                    accent: variantStyle.fg,
                    tint: variantStyle.bg,
                  ),
                  FutureBuilder<Map<String, int>>(
                    future: _progressCounts(course),
                    builder: (_, snap) {
                      final data = snap.data ?? {'total': 0, 'covered': 0};
                      final t = data['total'] ?? 0;
                      final c = data['covered'] ?? 0;
                      final pct = t == 0 ? 0 : ((c / t) * 100).round();

                      return _kpiChip(
                        icon: Icons.insights_rounded,
                        label: 'Progress',
                        value: '$pct%',
                        accent: variantStyle.fg,
                        tint: variantStyle.bg,
                      );
                    },
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.visibility_rounded),
                      label: const Text('Open'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isOnline ? variantStyle.fg : UiK.actionOrange,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _kpiChip({
    required IconData icon,
    required String label,
    required String value,
    Color? accent,
    Color? tint,
  }) {
    final iconColor = accent ?? UiK.actionOrange;
    final bgColor = tint ?? UiK.primaryBlue.withOpacity(0.04);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        color: bgColor,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Text(value, style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: UiK.mainText.withOpacity(0.7), fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}