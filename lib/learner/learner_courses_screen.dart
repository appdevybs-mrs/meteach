import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/payment_status.dart';
import '../shared/watermark_background.dart';
import '../shared/learner_tour_guide.dart';
import '../shared/learner_web_layout.dart';
import '../shared/course_join_rules.dart';
import 'learner_course_detail_screen.dart';
import 'recorded_course_study_screen.dart';

class LearnerCoursesScreen extends StatefulWidget {
  const LearnerCoursesScreen({super.key, this.initialCourseKey});

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
  Timer? _joinTick;
  final Map<String, Future<_PrivateOnlineMeta?>> _privateMetaFutureByCourseKey =
      <String, Future<_PrivateOnlineMeta?>>{};

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _joinTick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _joinTick?.cancel();
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
      _privateMetaFutureByCourseKey.clear();
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
      list.sort(
        (a, b) => numVal(b['assignedAt']).compareTo(numVal(a['assignedAt'])),
      );

      setState(() {
        _courses = list;
        _busy = false;
      });

      _openInitialCourseIfNeeded();
    } catch (e) {
      setState(() {
        _error = toHumanError(e);
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

      final variantKey = _variantKeyOf(match);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => variantKey == 'recorded'
              ? RecordedCourseStudyScreen(
                  courseKey: targetKey,
                  courseData: match,
                )
              : LearnerCourseDetailScreen(
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

  String _studyModeOf(Map<String, dynamic> course) {
    final root = (course['studyMode'] ?? '').toString().trim().toLowerCase();
    if (root.isNotEmpty) return root;

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};
    final inClass = (cls['studyMode'] ?? cls['study_mode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (inClass.isNotEmpty) return inClass;

    final rootModeLabel = (course['studyModeLabel'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (rootModeLabel == 'online' || rootModeLabel == 'in-class') {
      return rootModeLabel == 'online' ? 'online' : 'inclass';
    }

    final classModeLabel =
        (cls['studyModeLabel'] ?? cls['study_mode_label'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    if (classModeLabel == 'online' || classModeLabel == 'in-class') {
      return classModeLabel == 'online' ? 'online' : 'inclass';
    }

    final variantLabel = (course['variantLabel'] ?? cls['variantLabel'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (variantLabel.contains('online')) return 'online';
    if (variantLabel.contains('in-class') ||
        variantLabel.contains('in class')) {
      return 'inclass';
    }

    final deliveryLabel =
        (course['deliveryLabel'] ?? cls['deliveryLabel'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    if (deliveryLabel.contains('online')) return 'online';

    return '';
  }

  bool _isPrivateOnline(Map<String, dynamic> course) {
    if (_variantKeyOf(course) != 'private') return false;
    final mode = _studyModeOf(course);
    return mode.isEmpty || mode == 'online';
  }

  String _readFirstNonEmpty(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = (m[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  int _weekdayFromShort(String day) {
    switch (day.trim().toLowerCase()) {
      case 'mon':
      case 'monday':
        return 1;
      case 'tue':
      case 'tues':
      case 'tuesday':
        return 2;
      case 'wed':
      case 'wednesday':
        return 3;
      case 'thu':
      case 'thur':
      case 'thurs':
      case 'thursday':
        return 4;
      case 'fri':
      case 'friday':
        return 5;
      case 'sat':
      case 'saturday':
        return 6;
      case 'sun':
      case 'sunday':
        return 7;
      default:
        return 0;
    }
  }

  String _weekdayShort(int weekday) {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    if (weekday < 1 || weekday > 7) return '-';
    return labels[weekday - 1];
  }

  ({int hour, int minute})? _parseHm(String raw) {
    final t = raw.trim();
    final parts = t.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return (hour: h, minute: m);
  }

  DateTime? _safeDate(String ymd) {
    try {
      final p = ymd.trim().split('-');
      if (p.length != 3) return null;
      final y = int.tryParse(p[0]);
      final m = int.tryParse(p[1]);
      final d = int.tryParse(p[2]);
      if (y == null || m == null || d == null) return null;
      return DateTime(y, m, d);
    } catch (_) {
      return null;
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _fmtHm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  String _fmtDateTime(DateTime d) {
    return '${_weekdayShort(d.weekday)} ${_two(d.day)}/${_two(d.month)} ${_fmtHm(d)}';
  }

  Future<void> _openExternalUrl(BuildContext context, String url) async {
    var u = url.trim();
    if (u.isEmpty) return;

    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }

    final uri = Uri.tryParse(u);
    if (uri == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid meeting link.')));
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link.')));
    }
  }

  Future<_PrivateOnlineMeta?> _loadPrivateOnlineMeta(
    Map<String, dynamic> course,
  ) async {
    if (!_isPrivateOnline(course)) return null;

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};
    final classId = (cls['class_id'] ?? '').toString().trim();

    Map<String, dynamic> classNode = <String, dynamic>{};
    if (classId.isNotEmpty) {
      final snap = await _db.child('classes/$classId').get();
      final raw = snap.value;
      if (raw is Map) {
        classNode = raw.map((k, v) => MapEntry(k.toString(), v));
      }
    }

    final rawSchedule = cls['schedule'] ?? classNode['schedule'];
    if (rawSchedule is! Map) {
      return const _PrivateOnlineMeta(
        slots: <_WeeklySlot>[],
        firstDate: null,
        meetUrl: '',
      );
    }

    final schedule = rawSchedule.map((k, v) => MapEntry(k.toString(), v));
    final firstDate = _safeDate(
      (schedule['first_session_date'] ?? '').toString(),
    );

    final slots = <_WeeklySlot>[];
    final sessionsRaw = schedule['sessions'];
    final sessionNodes = <Map<String, dynamic>>[];
    if (sessionsRaw is List) {
      for (final item in sessionsRaw) {
        if (item is! Map) continue;
        sessionNodes.add(item.map((k, v) => MapEntry(k.toString(), v)));
      }
    } else if (sessionsRaw is Map) {
      for (final entry in sessionsRaw.entries) {
        final item = entry.value;
        if (item is! Map) continue;
        sessionNodes.add(item.map((k, v) => MapEntry(k.toString(), v)));
      }
    }

    for (final s in sessionNodes) {
      final dayRaw = (s['day'] ?? '').toString();
      final weekday = _weekdayFromShort(dayRaw);
      if (weekday <= 0) continue;

      final hm = _parseHm((s['start_time'] ?? '').toString());
      if (hm == null) continue;

      final duration = _asInt(s['duration_min']);
      slots.add(
        _WeeklySlot(
          weekday: weekday,
          startHour: hm.hour,
          startMinute: hm.minute,
          durationMinutes: duration > 0 ? duration : 60,
        ),
      );
    }

    slots.sort((a, b) {
      final wd = a.weekday.compareTo(b.weekday);
      if (wd != 0) return wd;
      final ah = a.startHour.compareTo(b.startHour);
      if (ah != 0) return ah;
      return a.startMinute.compareTo(b.startMinute);
    });

    String teacherUid =
        _readFirstNonEmpty(cls, [
          'teacherUid',
          'teacher_uid',
          'teacherId',
          'teacher_id',
          'instructor_uid',
          'instructorUid',
        ]).isNotEmpty
        ? _readFirstNonEmpty(cls, [
            'teacherUid',
            'teacher_uid',
            'teacherId',
            'teacher_id',
            'instructor_uid',
            'instructorUid',
          ])
        : _readFirstNonEmpty(classNode, [
            'teacherUid',
            'teacher_uid',
            'teacherId',
            'teacher_id',
            'instructor_uid',
            'instructorUid',
          ]);

    if (teacherUid.isEmpty && classNode['instructor_current'] is Map) {
      final inst = Map<String, dynamic>.from(
        classNode['instructor_current'] as Map,
      );
      teacherUid = _readFirstNonEmpty(inst, const ['uid']);
    }

    if (teacherUid.isEmpty && classNode['attendance'] is Map) {
      final att = Map<dynamic, dynamic>.from(classNode['attendance'] as Map);
      int bestTs = 0;
      String bestUid = '';
      for (final e in att.entries) {
        if (e.value is! Map) continue;
        final m = Map<String, dynamic>.from(e.value as Map);
        final uid = _readFirstNonEmpty(m, [
          'teacherUid',
          'teacher_uid',
          'teacherId',
          'teacher_id',
        ]);
        if (uid.isEmpty) continue;
        final ts = _asInt(m['updatedAt']);
        if (ts >= bestTs) {
          bestTs = ts;
          bestUid = uid;
        }
      }
      if (bestUid.isNotEmpty) teacherUid = bestUid;
    }

    var meetUrl = '';
    if (teacherUid.isNotEmpty) {
      final meetSnap = await _usersRef
          .child(teacherUid)
          .child('google_meet_url')
          .get();
      meetUrl = (meetSnap.value ?? '').toString().trim();
    }

    return _PrivateOnlineMeta(
      slots: slots,
      firstDate: firstDate,
      meetUrl: meetUrl,
    );
  }

  Future<_PrivateOnlineMeta?> _privateMetaForCourse(
    Map<String, dynamic> course,
  ) {
    final key = (course['courseKey'] ?? '').toString().trim();
    if (key.isEmpty) {
      return _loadPrivateOnlineMeta(course);
    }
    return _privateMetaFutureByCourseKey.putIfAbsent(
      key,
      () => _loadPrivateOnlineMeta(course),
    );
  }

  _SessionOccurrence? _currentOccurrence(
    _PrivateOnlineMeta meta,
    DateTime now,
  ) {
    if (meta.slots.isEmpty) return null;

    for (int i = -1; i <= 14; i++) {
      final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      if (meta.firstDate != null) {
        final firstDay = DateTime(
          meta.firstDate!.year,
          meta.firstDate!.month,
          meta.firstDate!.day,
        );
        if (day.isBefore(firstDay)) continue;
      }

      for (final slot in meta.slots) {
        if (slot.weekday != day.weekday) continue;

        final start = DateTime(
          day.year,
          day.month,
          day.day,
          slot.startHour,
          slot.startMinute,
        );
        final openFrom = start.subtract(const Duration(minutes: 5));
        final openUntil = start.add(const Duration(minutes: 10));

        if (!now.isBefore(openFrom) && now.isBefore(openUntil)) {
          return _SessionOccurrence(start: start, end: openUntil);
        }
      }
    }

    return null;
  }

  _SessionOccurrence? _nextOccurrence(_PrivateOnlineMeta meta, DateTime now) {
    if (meta.slots.isEmpty) return null;

    _SessionOccurrence? best;

    for (int i = 0; i <= 30; i++) {
      final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      if (meta.firstDate != null) {
        final firstDay = DateTime(
          meta.firstDate!.year,
          meta.firstDate!.month,
          meta.firstDate!.day,
        );
        if (day.isBefore(firstDay)) continue;
      }

      for (final slot in meta.slots) {
        if (slot.weekday != day.weekday) continue;

        final start = DateTime(
          day.year,
          day.month,
          day.day,
          slot.startHour,
          slot.startMinute,
        );
        if (!start.isAfter(now)) continue;

        final end = start.add(Duration(minutes: slot.durationMinutes));
        final candidate = _SessionOccurrence(start: start, end: end);
        if (best == null || candidate.start.isBefore(best.start)) {
          best = candidate;
        }
      }
    }

    return best;
  }

  String _schedulePatternText(List<_WeeklySlot> slots) {
    if (slots.isEmpty) return 'Schedule: not set yet';
    final labels = slots
        .map(
          (s) =>
              '${_weekdayShort(s.weekday)} ${_two(s.startHour)}:${_two(s.startMinute)}',
        )
        .toList();
    return 'Schedule: ${labels.join(' • ')}';
  }

  ({Color bg, Color border, Color fg, IconData icon, String label})
  _variantStyle(String variantKey) {
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
          border: p.border.withValues(alpha: 0.85),
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
    final courseKey = (course['courseKey'] ?? '').toString().trim();

    if (courseId.isEmpty) return {'total': 0, 'covered': 0};

    final Set<String> covered = {};
    final Map<int, String> sessionIdByNumber = {};
    int totalSyllabiSessions = 0;

    if (variantKey == 'recorded') {
      try {
        final syllabusSnap = await _syllabiRef
            .child(courseId)
            .child('recorded')
            .get();

        final Map<String, Map<String, dynamic>> sessionMetaById = {};

        List<Map<String, dynamic>> asListOfMaps(dynamic node) {
          final out = <Map<String, dynamic>>[];

          if (node is List) {
            for (final item in node) {
              if (item is Map) {
                out.add(Map<String, dynamic>.from(item));
              }
            }
            return out;
          }

          if (node is Map) {
            final map = Map<dynamic, dynamic>.from(node);
            for (final entry in map.entries) {
              if (entry.value is Map) {
                out.add(Map<String, dynamic>.from(entry.value as Map));
              }
            }
          }

          return out;
        }

        bool asBool(dynamic v) {
          if (v is bool) return v;
          final s = (v ?? '').toString().trim().toLowerCase();
          return s == 'true' || s == '1';
        }

        if (syllabusSnap.exists && syllabusSnap.value is Map) {
          final root = Map<String, dynamic>.from(syllabusSnap.value as Map);
          final rawModules = asListOfMaps(root['modules']);
          if (rawModules.isNotEmpty) {
            for (final module in rawModules) {
              final rawUnits = asListOfMaps(module['units']);
              for (final unit in rawUnits) {
                final rawLessons = asListOfMaps(unit['lessons']);
                for (final lesson in rawLessons) {
                  final sessionId = (lesson['id'] ?? '').toString().trim();
                  final sessionNumber = _asInt(lesson['sessionNumber']);
                  final videoUrl = (lesson['videoUrl'] ?? '').toString().trim();
                  final materialsUrl = (lesson['materialsUrl'] ?? '')
                      .toString()
                      .trim();

                  final hasVideo = videoUrl.isNotEmpty;
                  final hasMaterials = materialsUrl.isNotEmpty;

                  totalSyllabiSessions += 1;

                  if (sessionId.isNotEmpty) {
                    sessionMetaById[sessionId] = {
                      'hasVideo': hasVideo,
                      'hasMaterials': hasMaterials,
                    };
                  }

                  if (sessionNumber > 0 && sessionId.isNotEmpty) {
                    sessionIdByNumber[sessionNumber] = sessionId;
                  }
                }
              }
            }
          } else {
            final rawUnits = asListOfMaps(root['units']);

            for (final unit in rawUnits) {
              final rawSessions = asListOfMaps(unit['sessions']);

              for (final session in rawSessions) {
                final sessionId = (session['id'] ?? '').toString().trim();
                final sessionNumber = _asInt(session['sessionNumber']);
                final videoUrl = (session['videoUrl'] ?? '').toString().trim();
                final materialsUrl = (session['materialsUrl'] ?? '')
                    .toString()
                    .trim();

                final hasVideo = videoUrl.isNotEmpty;
                final hasMaterials = materialsUrl.isNotEmpty;

                totalSyllabiSessions += 1;

                if (sessionId.isNotEmpty) {
                  sessionMetaById[sessionId] = {
                    'hasVideo': hasVideo,
                    'hasMaterials': hasMaterials,
                  };
                }

                if (sessionNumber > 0 && sessionId.isNotEmpty) {
                  sessionIdByNumber[sessionNumber] = sessionId;
                }
              }
            }
          }
        }

        if (courseKey.isEmpty) {
          return {'total': totalSyllabiSessions, 'covered': 0};
        }

        final progressSnap = await _usersRef
            .child(_uid)
            .child('courses')
            .child(courseKey)
            .child('recorded_progress')
            .get();

        if (progressSnap.exists && progressSnap.value is Map) {
          final rawProgress = Map<String, dynamic>.from(
            progressSnap.value as Map,
          );

          for (final entry in rawProgress.entries) {
            final sessionId = entry.key.toString().trim();
            final value = entry.value;

            if (sessionId.isEmpty || value is! Map) continue;

            final progress = Map<String, dynamic>.from(value);
            final meta =
                sessionMetaById[sessionId] ?? const <String, dynamic>{};

            final hasVideo = meta['hasVideo'] == true;
            final hasMaterials = meta['hasMaterials'] == true;

            final videoCompleted = asBool(progress['videoCompleted']);
            final materialsCompleted = asBool(progress['materialsCompleted']);

            bool isCompleted = false;

            if (hasVideo && hasMaterials) {
              isCompleted = videoCompleted || materialsCompleted;
            } else if (hasVideo) {
              isCompleted = videoCompleted;
            } else if (hasMaterials) {
              isCompleted = materialsCompleted;
            }

            if (isCompleted) {
              covered.add(sessionId);
            }
          }
        }

        return {'total': totalSyllabiSessions, 'covered': covered.length};
      } catch (_) {
        return {'total': totalSyllabiSessions, 'covered': covered.length};
      }
    }

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
    required String variantKey,
    required int sessionsDone,
    required Map<String, dynamic> summary,
  }) {
    final sessionsPaidTotalRaw = _asInt(summary['sessionsPaidTotal']);
    final totalPaid = _asInt(summary['totalPaid']);
    final lastAmount = _asInt(summary['lastAmount']);
    final lastPaymentAt = _asInt(summary['lastPaymentAt']);
    final hasPaymentHistory =
        totalPaid > 0 || lastAmount > 0 || lastPaymentAt > 0;

    final sessionsPaidTotal = sessionsPaidTotalRaw > 0
        ? sessionsPaidTotalRaw
        : (hasPaymentHistory &&
                  (variantKey == 'private' || variantKey == 'inclass')
              ? 8
              : 0);
    final remindBeforeSession = _asInt(summary['remindBeforeSession']);

    if (sessionsPaidTotal <= 0) return '';

    final overdue = isPaymentDueBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
    );
    final dueSoon = isPaymentWarningBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
      remindBeforeSession: remindBeforeSession,
    );

    if (overdue) return 'PAYMENT NEEDED';
    if (dueSoon) return 'PAYMENT SOON';

    return '';
  }

  bool _isExpiredMs(int ms) {
    if (ms <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch >= ms;
  }

  bool _isNearExpiryMs(int ms, {int days = 3}) {
    if (ms <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = ms - now;
    if (diff <= 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    LearnerTourGuide.schedule(
      context,
      screenId: 'learner_courses',
      hints: const [
        LearnerTourHint(
          title: 'الدورات المسندة',
          line: 'تعرض هذه الصفحة جميع دوراتك الحالية مع حالة كل دورة.',
        ),
        LearnerTourHint(
          title: 'فتح الدورة',
          line: 'اضغط زر فتح الدورة للدخول إلى التفاصيل أو المحتوى المسجل.',
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
        title: Text(
          'My Courses',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1520,
        child: WatermarkBackground(
          child: _busy
              ? Center(child: CircularProgressIndicator(color: p.primary))
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
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.85),
                        ),
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
                      ..._courses.map(_courseCard),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _courseCard(Map<String, dynamic> course) {
    final p = palette;
    final courseKey = (course['courseKey'] ?? '').toString();
    final title = (course['title'] ?? course['course_title'] ?? 'Course')
        .toString();
    final code = (course['course_code'] ?? '').toString();

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};
    final classId = (cls['class_id'] ?? '').toString().trim();
    final instructor = (cls['instructor'] ?? cls['teacher_name'] ?? '')
        .toString()
        .trim();
    final status = (cls['status'] ?? course['status'] ?? '').toString().trim();

    final variantKey = _variantKeyOf(course);
    final isOnline = _isOnlineCourse(course);
    final isRecorded = variantKey == 'recorded';
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
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
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
                          color: p.text.withValues(alpha: 0.66),
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
                if (!isRecorded)
                  FutureBuilder<DataSnapshot>(
                    future: _usersRef
                        .child(_uid)
                        .child('courses')
                        .child(courseKey)
                        .child('payment_summary')
                        .get(),
                    builder: (context, snap) {
                      final raw = snap.data?.value;
                      final sum = raw is Map
                          ? raw.map((k, v) => MapEntry(k.toString(), v))
                          : <String, dynamic>{};

                      Widget stateChipForDone(int sessionsDone) {
                        final state = _paymentStateFromSummary(
                          variantKey: variantKey,
                          sessionsDone: sessionsDone,
                          summary: sum,
                        );

                        Widget buildPill(String label, Color tone) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: tone.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: tone.withValues(alpha: 0.28),
                              ),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 11,
                                color: tone,
                              ),
                            ),
                          );
                        }

                        final flexAccess = course['flexible_access'];
                        final flexMap = flexAccess is Map
                            ? flexAccess.map(
                                (k, v) => MapEntry(k.toString(), v),
                              )
                            : <String, dynamic>{};
                        final flexExpiresAt = _asInt(flexMap['expiresAt']);
                        final expired =
                            variantKey == 'flexible' &&
                            _isExpiredMs(flexExpiresAt);
                        final nearExpiry =
                            variantKey == 'flexible' &&
                            _isNearExpiryMs(flexExpiresAt);

                        if (variantKey == 'flexible') {
                          final cues = <Widget>[];
                          if (state.isNotEmpty) {
                            final sessionTone = switch (state) {
                              'PAYMENT NEEDED' => Colors.red,
                              'PAYMENT SOON' => const Color(0xFFD97706),
                              _ => p.accent,
                            };
                            cues.add(buildPill(state, sessionTone));
                          }

                          if (expired) {
                            cues.add(buildPill('ACCESS EXPIRED', Colors.red));
                          } else if (nearExpiry) {
                            cues.add(
                              buildPill('EXPIRY SOON', const Color(0xFF7C3AED)),
                            );
                          }

                          if (cues.isEmpty) return const SizedBox.shrink();
                          return Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: cues,
                          );
                        }

                        if (state.isEmpty) return const SizedBox.shrink();
                        final tone = switch (state) {
                          'PAYMENT NEEDED' => Colors.red,
                          'PAYMENT SOON' => const Color(0xFFD97706),
                          _ => p.accent,
                        };
                        return buildPill(state, tone);
                      }

                      final inclassHeld = countHeldUniqueAttendanceDates(
                        course['attendance'],
                      );
                      final privatePresent = countPresentUniqueAttendanceDates(
                        course['attendance'],
                      );

                      if (variantKey == 'inclass') {
                        return stateChipForDone(inclassHeld);
                      }

                      if (variantKey == 'private') {
                        return stateChipForDone(privatePresent);
                      }

                      if (variantKey != 'flexible') {
                        return stateChipForDone(privatePresent);
                      }

                      final cid = _courseIdOf(course);
                      if (cid.isEmpty) return stateChipForDone(privatePresent);

                      return FutureBuilder<DataSnapshot>(
                        future: _db
                            .child(
                              '$bookingProgressNode/$_uid/$cid/online_attendance',
                            )
                            .get(),
                        builder: (context, onlineSnap) {
                          final onlinePresent = countPresentOnlineAttendance(
                            onlineSnap.data?.value,
                          );
                          return stateChipForDone(onlinePresent);
                        },
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
            if (isRecorded)
              FutureBuilder<Map<String, int>>(
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
              )
            else
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
                      builder: (_) => variantKey == 'recorded'
                          ? RecordedCourseStudyScreen(
                              courseKey: courseKey,
                              courseData: course,
                            )
                          : LearnerCourseDetailScreen(
                              courseKey: courseKey,
                              courseData: course,
                            ),
                    ),
                  );
                },
              ),
            ),
            if (_isPrivateOnline(course)) ...[
              const SizedBox(height: 10),
              FutureBuilder<_PrivateOnlineMeta?>(
                future: _privateMetaForCourse(course),
                builder: (context, snap) {
                  final meta = snap.data;
                  if (meta == null) {
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.soft,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.85),
                        ),
                      ),
                      child: Text(
                        'Loading private online session details...',
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    );
                  }

                  final now = DateTime.now();
                  final current = _currentOccurrence(meta, now);
                  final next = _nextOccurrence(meta, now);
                  final hasMeet = meta.meetUrl.trim().isNotEmpty;
                  final canJoin = current != null && hasMeet;

                  String timeLine;
                  if (current != null) {
                    timeLine =
                        'Join window open: ${_fmtDateTime(current.start)}';
                  } else if (next != null) {
                    timeLine = 'Next session: ${_fmtDateTime(next.start)}';
                  } else {
                    timeLine = 'No upcoming session found';
                  }

                  final joinLabel = current != null
                      ? joinButtonLabelForWindow(
                          openFrom: current.start.subtract(
                            const Duration(minutes: 5),
                          ),
                          openUntil: current.end,
                          hasMeetLink: hasMeet,
                          actionLabel: 'Join',
                          closedLabel: 'Join window closed',
                        )
                      : (next != null
                            ? joinButtonLabelForWindow(
                                openFrom: next.start.subtract(
                                  const Duration(minutes: 5),
                                ),
                                openUntil: next.start.add(
                                  const Duration(minutes: 10),
                                ),
                                hasMeetLink: hasMeet,
                                actionLabel: 'Join',
                                closedLabel: 'Join window closed',
                              )
                            : (hasMeet
                                  ? 'Join (no upcoming session)'
                                  : 'Meet link not set'));

                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: p.soft,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: p.border.withValues(alpha: 0.85),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _InfoLine(
                          palette: p,
                          icon: Icons.schedule_rounded,
                          text: _schedulePatternText(meta.slots),
                        ),
                        const SizedBox(height: 6),
                        _InfoLine(
                          palette: p,
                          icon: Icons.access_time_rounded,
                          text: timeLine,
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.video_call_rounded),
                            label: Text(joinLabel),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: canJoin
                                  ? variantStyle.fg
                                  : Colors.grey.shade500,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: canJoin
                                ? () => _openExternalUrl(context, meta.meetUrl)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
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
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        color: bgColor,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.55),
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
                    color: p.text.withValues(alpha: 0.68),
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

class _WeeklySlot {
  final int weekday;
  final int startHour;
  final int startMinute;
  final int durationMinutes;

  const _WeeklySlot({
    required this.weekday,
    required this.startHour,
    required this.startMinute,
    required this.durationMinutes,
  });
}

class _SessionOccurrence {
  final DateTime start;
  final DateTime end;

  const _SessionOccurrence({required this.start, required this.end});
}

class _PrivateOnlineMeta {
  final List<_WeeklySlot> slots;
  final DateTime? firstDate;
  final String meetUrl;

  const _PrivateOnlineMeta({
    required this.slots,
    required this.firstDate,
    required this.meetUrl,
  });
}

class _CoursesHeroCard extends StatelessWidget {
  const _CoursesHeroCard({required this.palette, required this.coursesCount});

  final _CoursesPalette palette;
  final int coursesCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.primary, palette.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha: 0.18),
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
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
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
                    color: Colors.white.withValues(alpha: 0.86),
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
        color: palette.soft.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border.withValues(alpha: 0.85)),
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
        Icon(icon, size: 16, color: palette.text.withValues(alpha: 0.62)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: palette.text.withValues(alpha: 0.72),
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
  const _EmptyCoursesState({required this.palette, required this.onRefresh});

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
            border: Border.all(color: palette.border.withValues(alpha: 0.85)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
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
                  color: palette.text.withValues(alpha: 0.68),
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
                  side: BorderSide(
                    color: palette.border.withValues(alpha: 0.9),
                  ),
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
