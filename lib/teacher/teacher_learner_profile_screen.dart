import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'teacher_mail_thread_screen.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/teacher_web_layout.dart';

class TeacherLearnerProfileScreen extends StatefulWidget {
  const TeacherLearnerProfileScreen({
    super.key,
    required this.learnerUid,
    required this.learnerName,
    this.openReportComposerOnLoad = false,
    this.initialCourseTitle,
  });

  final String learnerUid;
  final String learnerName;
  final bool openReportComposerOnLoad;
  final String? initialCourseTitle;

  @override
  State<TeacherLearnerProfileScreen> createState() =>
      _TeacherLearnerProfileScreenState();
}

class _TeacherLearnerProfileScreenState
    extends State<TeacherLearnerProfileScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _busy = true;
  String? _error;
  Map<String, dynamic> _user = {};
  List<String> _photoUrls = [];
  String? _profilePhotoUrl;
  bool _reportOpenedOnce = false;

  int _statCourses = 0;
  int _statAttendancePct = 0;
  int _statLessonsCovered = 0;
  int _statHomeworkPending = 0;

  AppPalette get palette => appThemeController.palette;

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

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _safeStr(dynamic v) => (v ?? '').toString().trim();

  Future<Map<int, String>> _loadSessionIdByNumber({
    required String courseId,
    required String variantKey,
  }) async {
    final out = <int, String>{};
    if (courseId.trim().isEmpty) return out;

    try {
      DatabaseReference syllabusRef = _db.child('syllabi/$courseId');
      if (variantKey.trim().isNotEmpty) {
        syllabusRef = syllabusRef.child(variantKey.trim().toLowerCase());
      }

      final snap = await syllabusRef.get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return out;

      final data = Map<String, dynamic>.from(snap.value as Map);
      final modules = data['modules'];
      if (modules is List) {
        for (final m in modules) {
          if (m is! Map) continue;
          final module = Map<String, dynamic>.from(m);
          final units = module['units'];
          if (units is! List) continue;
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final lessons = unit['lessons'];
            if (lessons is! List) continue;
            for (final ss in lessons) {
              if (ss is! Map) continue;
              final sess = Map<String, dynamic>.from(ss);
              final sn = _toInt(sess['sessionNumber']);
              final sid = _safeStr(sess['id']);
              if (sn > 0 && sid.isNotEmpty) {
                out[sn] = sid;
              }
            }
          }
        }
      } else {
        final units = data['units'];

        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final sessions = unit['sessions'];

            if (sessions is List) {
              for (final ss in sessions) {
                if (ss is! Map) continue;
                final sess = Map<String, dynamic>.from(ss);
                final sn = _toInt(sess['sessionNumber']);
                final sid = _safeStr(sess['id']);
                if (sn > 0 && sid.isNotEmpty) {
                  out[sn] = sid;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    return out;
  }

  Future<Set<String>> _coveredSessionIdsFromCourse({
    required String learnerUid,
    required Map<String, dynamic> course,
  }) async {
    final covered = <String>{};

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    final courseId = _safeStr(cls['course_id'] ?? course['id']);
    final variantKey = _safeStr(
      course['variantKey'] ?? course['variant'],
    ).toLowerCase();

    final sessionIdByNumber = await _loadSessionIdByNumber(
      courseId: courseId,
      variantKey: variantKey,
    );

    final attendance = course['attendance'];
    if (attendance is Map) {
      final attMap = Map<String, dynamic>.from(attendance);

      for (final entry in attMap.entries) {
        final rec = entry.value;
        if (rec is! Map) continue;

        final m = Map<String, dynamic>.from(rec);
        final taughtItems = m['taughtItems'];
        bool usedNew = false;

        if (taughtItems is List) {
          usedNew = true;
          for (final it in taughtItems) {
            if (it is! Map) continue;
            final item = Map<String, dynamic>.from(it);
            final type = _safeStr(item['type']).toLowerCase();
            if (type != 'syllabus') continue;

            final sid = _safeStr(item['sessionId']);
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(item['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }

        if (!usedNew) {
          final taught = m['taught'];
          if (taught is Map) {
            final tm = Map<String, dynamic>.from(taught);
            final sid = _safeStr(tm['sessionId']);
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(tm['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }
      }
    }

    if (learnerUid.isNotEmpty && courseId.isNotEmpty) {
      try {
        final snap = await _db
            .child('booking_progress/$learnerUid/$courseId/online_attendance')
            .get();

        if (snap.exists && snap.value is Map) {
          final om = Map<dynamic, dynamic>.from(snap.value as Map);

          for (final e in om.entries) {
            final rec = e.value;
            if (rec is! Map) continue;
            final r = Map<String, dynamic>.from(rec);

            final taughtItems = r['taughtItems'];
            if (taughtItems is List) {
              for (final it in taughtItems) {
                if (it is! Map) continue;
                final item = Map<String, dynamic>.from(it);

                final type = _safeStr(item['type']).toLowerCase();
                if (type != 'syllabus') continue;

                final sid = _safeStr(item['sessionId']);
                if (sid.isNotEmpty) {
                  covered.add(sid);
                  continue;
                }

                final sn = _toInt(item['sessionNumber']);
                if (sn > 0) {
                  final mapped = sessionIdByNumber[sn];
                  if (mapped != null && mapped.isNotEmpty) {
                    covered.add(mapped);
                  }
                }
              }
            } else {
              final sn = _toInt(r['sessionNo']);
              if (sn > 0) {
                final mapped = sessionIdByNumber[sn];
                if (mapped != null && mapped.isNotEmpty) {
                  covered.add(mapped);
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    return covered;
  }

  Future<void> _loadSmallStats() async {
    _statCourses = 0;
    _statAttendancePct = 0;
    _statLessonsCovered = 0;
    _statHomeworkPending = 0;

    try {
      final snap = await _db.child('users/${widget.learnerUid}/courses').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

      final courses = Map<dynamic, dynamic>.from(snap.value as Map);

      int totalAttendance = 0;
      int totalPresent = 0;
      int totalLessonsCovered = 0;
      int homeworkPending = 0;

      for (final entry in courses.entries) {
        final courseVal = entry.value;
        if (courseVal is! Map) continue;

        final course = Map<String, dynamic>.from(courseVal);
        _statCourses += 1;

        final attendance = course['attendance'];
        if (attendance is Map) {
          final attMap = Map<dynamic, dynamic>.from(attendance);

          for (final v in attMap.values) {
            if (v is! Map) continue;
            final rec = Map<String, dynamic>.from(v);

            totalAttendance += 1;
            final status = _safeStr(rec['status']).toLowerCase();
            if (status == 'present') {
              totalPresent += 1;
            }

            final hwAny = rec['homework'];
            if (hwAny is Map) {
              final hw = Map<String, dynamic>.from(hwAny);
              final text = _safeStr(hw['text']);
              final due = _safeStr(hw['dueDate']);
              final doneAt = hw['doneAt'];
              final hasHomework = text.isNotEmpty || due.isNotEmpty;
              final isDone = doneAt != null;

              if (hasHomework && !isDone) {
                homeworkPending += 1;
              }
            }
          }
        }

        final cls = (course['class'] is Map)
            ? Map<String, dynamic>.from(course['class'] as Map)
            : <String, dynamic>{};

        final courseId = _safeStr(cls['course_id'] ?? course['id']);
        if (courseId.isNotEmpty) {
          try {
            final onlineSnap = await _db
                .child(
                  'booking_progress/${widget.learnerUid}/$courseId/online_attendance',
                )
                .get();

            if (onlineSnap.exists && onlineSnap.value is Map) {
              final om = Map<dynamic, dynamic>.from(onlineSnap.value as Map);
              for (final item in om.values) {
                if (item is! Map) continue;
                final rec = Map<String, dynamic>.from(item);

                totalAttendance += 1;
                final present = rec['present'] == true;
                if (present) totalPresent += 1;
              }
            }
          } catch (_) {}
        }

        final coveredSet = await _coveredSessionIdsFromCourse(
          learnerUid: widget.learnerUid,
          course: course,
        );
        totalLessonsCovered += coveredSet.length;
      }

      _statLessonsCovered = totalLessonsCovered;
      _statHomeworkPending = homeworkPending;
      _statAttendancePct = totalAttendance == 0
          ? 0
          : ((totalPresent / totalAttendance) * 100).round();
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _user = {};
      _photoUrls = [];
      _profilePhotoUrl = null;
    });

    try {
      final snap = await _db.child('users/${widget.learnerUid}').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        throw Exception('Learner profile not found.');
      }

      _user = Map<String, dynamic>.from(snap.value as Map);

      _profilePhotoUrl = _safeStr(_user['profile_photo']);
      if (_profilePhotoUrl != null && _profilePhotoUrl!.isEmpty) {
        _profilePhotoUrl = null;
      }

      _photoUrls.clear();
      final rawPhotos = _user['profile_photos'];
      if (rawPhotos is List) {
        for (final item in rawPhotos) {
          final url = _safeStr(item);
          if (url.isNotEmpty) _photoUrls.add(url);
        }
      } else if (rawPhotos is Map) {
        final map = Map<String, dynamic>.from(rawPhotos);
        final sortedKeys = map.keys.toList()..sort();
        for (final k in sortedKeys) {
          final url = _safeStr(map[k]);
          if (url.isNotEmpty) _photoUrls.add(url);
        }
      }

      await _loadSmallStats();
    } catch (e) {
      _error = toHumanError(e);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (widget.openReportComposerOnLoad && !_reportOpenedOnce) {
          _reportOpenedOnce = true;
          Future<void>.delayed(const Duration(milliseconds: 120), () {
            if (mounted) _openMonthlyReportComposer();
          });
        }
      }
    }
  }

  Future<List<Map<String, String>>> _loadLearnerCourseOptions() async {
    final out = <Map<String, String>>[];
    final snap = await _db.child('users/${widget.learnerUid}/courses').get();
    if (!snap.exists || snap.value is! Map) return out;
    final courses = Map<dynamic, dynamic>.from(snap.value as Map);
    for (final entry in courses.entries) {
      final key = _safeStr(entry.key);
      if (entry.value is! Map) continue;
      final m = Map<String, dynamic>.from(entry.value as Map);
      final cls = (m['class'] is Map)
          ? Map<String, dynamic>.from(m['class'] as Map)
          : <String, dynamic>{};
      final title = _safeStr(
        cls['course_title'] ?? m['course_title'] ?? m['title'] ?? key,
      );
      if (key.isEmpty && title.isEmpty) continue;
      out.add({'key': key, 'title': title.isEmpty ? key : title});
    }
    return out;
  }

  Future<String?> _pickCourseTitleForReport() async {
    final initial = _safeStr(widget.initialCourseTitle);
    if (initial.isNotEmpty) return initial;
    final options = await _loadLearnerCourseOptions();
    if (options.isEmpty) return null;
    if (options.length == 1) return _safeStr(options.first['title']);
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select course'),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (_, i) {
              final t = _safeStr(options[i]['title']);
              return ListTile(
                title: Text(t.isEmpty ? 'Course' : t),
                onTap: () => Navigator.pop(ctx, t),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  String _reportSubject(String courseTitle) {
    return 'Performance Card';
  }

  String _monthLabel() {
    const months = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final now = DateTime.now();
    return '${months[now.month - 1]} ${now.year}';
  }

  Future<String> _ensureReportThread({
    required String teacherUid,
    required String teacherName,
    required String learnerUid,
    required String learnerName,
    required String subject,
  }) async {
    final threadsSnap = await _db.child('mail_threads').get();
    if (threadsSnap.exists && threadsSnap.value is Map) {
      final raw = Map<dynamic, dynamic>.from(threadsSnap.value as Map);
      for (final e in raw.entries) {
        final threadId = _safeStr(e.key);
        if (threadId.isEmpty || e.value is! Map) continue;
        final t = Map<dynamic, dynamic>.from(e.value as Map);
        if (t['isGroup'] == true) continue;
        final tType = (t['type'] ?? '').toString().trim().toLowerCase();
        if (tType != 'report') continue;
        final participants = t['participants'];
        if (participants is! Map) continue;
        final pm = Map<dynamic, dynamic>.from(participants);
        final hasTeacher = pm[teacherUid] == true;
        final hasLearner = pm[learnerUid] == true;
        if (hasTeacher && hasLearner) return threadId;
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final threadId = _db.child('mail_threads').push().key;
    if (threadId == null || threadId.trim().isEmpty) {
      throw Exception('Could not create report thread.');
    }

    final updates = <String, dynamic>{
      'mail_threads/$threadId/subject': subject,
      'mail_threads/$threadId/type': 'report',
      'mail_threads/$threadId/isGroup': false,
      'mail_threads/$threadId/participants/$teacherUid': true,
      'mail_threads/$threadId/participants/$learnerUid': true,
      'mail_threads/$threadId/createdAt': now,
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/lastMessage': '',
      'mail_index/$teacherUid/$threadId/subject': subject,
      'mail_index/$teacherUid/$threadId/type': 'report',
      'mail_index/$teacherUid/$threadId/peerUid': learnerUid,
      'mail_index/$teacherUid/$threadId/peerName': learnerName,
      'mail_index/$teacherUid/$threadId/updatedAt': now,
      'mail_index/$teacherUid/$threadId/lastMessage': '',
      'mail_index/$teacherUid/$threadId/unreadCount': 0,
      'mail_index/$teacherUid/$threadId/deletedAt': null,
      'mail_index/$learnerUid/$threadId/subject': subject,
      'mail_index/$learnerUid/$threadId/type': 'report',
      'mail_index/$learnerUid/$threadId/peerUid': teacherUid,
      'mail_index/$learnerUid/$threadId/peerName': teacherName,
      'mail_index/$learnerUid/$threadId/updatedAt': now,
      'mail_index/$learnerUid/$threadId/lastMessage': '',
      'mail_index/$learnerUid/$threadId/unreadCount': 0,
      'mail_index/$learnerUid/$threadId/deletedAt': null,
      'mail_state/$teacherUid/$threadId/lastReadAt': now,
      'mail_state/$teacherUid/$threadId/lastDeliveredAt': now,
      'mail_state/$learnerUid/$threadId/lastDeliveredAt': now,
    };
    await _db.update(updates);
    return threadId;
  }

  Future<void> _sendReportMail({
    required String threadId,
    required String teacherUid,
    required String learnerUid,
    required String body,
    required String subject,
    required String learnerName,
    required String teacherName,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgRef = _db.child('mail_messages/$threadId').push();
    final msgKey = msgRef.key;
    if (msgKey == null || msgKey.trim().isEmpty) {
      throw Exception('Could not create report message.');
    }
    final preview = body.trim();
    final updates = <String, dynamic>{
      'mail_messages/$threadId/$msgKey': {
        'fromUid': teacherUid,
        'body': body,
        'toUids': {learnerUid: true},
        'ccUids': <String, bool>{},
        'bccUids': <String, bool>{},
        'attachments': <Map<String, dynamic>>[],
        'createdAt': now,
        'deletedFor': <String, bool>{},
        'type': 'report',
      },
      'mail_threads/$threadId/subject': subject,
      'mail_threads/$threadId/type': 'report',
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/lastMessage': preview,
      'mail_index/$teacherUid/$threadId/subject': subject,
      'mail_index/$teacherUid/$threadId/type': 'report',
      'mail_index/$teacherUid/$threadId/peerUid': learnerUid,
      'mail_index/$teacherUid/$threadId/peerName': learnerName,
      'mail_index/$teacherUid/$threadId/updatedAt': now,
      'mail_index/$teacherUid/$threadId/lastMessage': preview,
      'mail_index/$teacherUid/$threadId/unreadCount': 0,
      'mail_index/$teacherUid/$threadId/deletedAt': null,
      'mail_index/$teacherUid/$threadId/homeworkRef': null,
      'mail_index/$learnerUid/$threadId/subject': subject,
      'mail_index/$learnerUid/$threadId/type': 'report',
      'mail_index/$learnerUid/$threadId/peerUid': teacherUid,
      'mail_index/$learnerUid/$threadId/peerName': teacherName,
      'mail_index/$learnerUid/$threadId/updatedAt': now,
      'mail_index/$learnerUid/$threadId/lastMessage': preview,
      'mail_index/$learnerUid/$threadId/deletedAt': null,
      'mail_index/$learnerUid/$threadId/homeworkRef': null,
      'mail_index/$learnerUid/$threadId/unreadCount': ServerValue.increment(1),
      'mail_state/$teacherUid/$threadId/lastReadAt': now,
      'mail_state/$teacherUid/$threadId/lastDeliveredAt': now,
      'mail_state/$learnerUid/$threadId/lastDeliveredAt': now,
    };
    await _db.update(updates);
  }

  Future<void> _openMonthlyReportComposer() async {
    if (_busy) return;
    final courseTitle = await _pickCourseTitleForReport();
    if (courseTitle == null || courseTitle.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No course selected.')));
      }
      return;
    }

    final skills = <String, double>{
      'participation': 50,
      'behavior': 50,
      'punctuality': 50,
      'vocabulary': 50,
      'fluency': 50,
      'grammar': 50,
      'writing': 50,
      'listening': 50,
    };

    final noteC = TextEditingController();
    const skillLabels = <(String, String)>[
      ('Participation', 'participation'),
      ('Behavior / Conduct', 'behavior'),
      ('Punctuality', 'punctuality'),
      ('Vocabulary Range', 'vocabulary'),
      ('Speaking Fluency', 'fluency'),
      ('Grammar Accuracy', 'grammar'),
      ('Writing / Punctuation', 'writing'),
      ('Listening Comprehension', 'listening'),
    ];
    bool sending = false;

    Color scoreColor(double v) {
      if (v >= 90) return const Color(0xFF059669);
      if (v >= 70) return const Color(0xFF10B981);
      if (v >= 40) return const Color(0xFFF59E0B);
      return const Color(0xFFEF4444);
    }

    String scoreLabel(double v) {
      if (v >= 90) return 'Excellent';
      if (v >= 70) return 'Good';
      if (v >= 40) return 'Developing';
      return 'Needs Improvement';
    }

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          void generateReport() {
            final parts = <String>['Performance Summary:'];
            for (final (label, key) in skillLabels) {
              final v = skills[key] ?? 50;
              parts.add('  $label: ${scoreLabel(v)} (${v.round()}%)');
            }
            final text = parts.join('\n');
            noteC.text = text;
            noteC.selection = TextSelection.fromPosition(
              TextPosition(offset: text.length),
            );
          }

          return AlertDialog(
            title: const Text('Monthly Report Card'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    enabled: false,
                    decoration: InputDecoration(
                      labelText: 'Course',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      hintText: courseTitle,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Class Stats',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          children: [
                            _statChip(
                              'Attendance',
                              '$_statAttendancePct%',
                              _attendanceColor(_statAttendancePct),
                            ),
                            _statChip(
                              'Lessons',
                              '$_statLessonsCovered',
                              const Color(0xFF3B82F6),
                            ),
                            _statChip(
                              'Homework Pending',
                              '$_statHomeworkPending',
                              _statHomeworkPending > 0
                                  ? const Color(0xFFEF4444)
                                  : const Color(0xFF10B981),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Skill Evaluation',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (final (label, key) in skillLabels) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(left: 2),
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Row(
                                  children: [
                                    Expanded(
                                      child: SliderTheme(
                                        data:
                                            SliderTheme.of(context).copyWith(
                                          activeTrackColor: scoreColor(
                                            skills[key] ?? 50,
                                          ),
                                          inactiveTrackColor: scoreColor(
                                            skills[key] ?? 50,
                                          ).withAlpha(25),
                                          thumbColor: scoreColor(
                                            skills[key] ?? 50,
                                          ),
                                          overlayColor: scoreColor(
                                            skills[key] ?? 50,
                                          ).withAlpha(20),
                                          trackHeight: 6,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                            enabledThumbRadius: 8,
                                          ),
                                        ),
                                        child: Slider(
                                          value: skills[key] ?? 50,
                                          min: 0,
                                          max: 100,
                                          divisions: 100,
                                          onChanged: (val) => setLocal(
                                            () => skills[key] = val,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 48,
                                      child: Text(
                                        '${(skills[key] ?? 50).round()}%',
                                        textAlign: TextAlign.right,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 12,
                                          color:
                                              scoreColor(skills[key] ?? 50),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => setLocal(() => generateReport()),
                      icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                      label: const Text('Generate Report'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: noteC,
                    decoration: const InputDecoration(
                      labelText: 'Teacher Note',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    minLines: 3,
                    maxLines: 6,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: sending ? null : () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: sending
                    ? null
                    : () async {
                        setLocal(() => sending = true);
                        try {
                          final me = FirebaseAuth.instance.currentUser;
                          final meUid = _safeStr(me?.uid);
                          if (meUid.isEmpty) {
                            throw Exception('Teacher not signed in.');
                          }
                          final meName = _safeStr(me?.email).isEmpty
                              ? 'Teacher'
                              : _safeStr(me?.email).split('@').first;
                          final learnerName =
                              widget.learnerName.trim().isEmpty
                                  ? 'Learner'
                                  : widget.learnerName.trim();
                          final subject = _reportSubject(courseTitle);
                          final threadId = await _ensureReportThread(
                            teacherUid: meUid,
                            teacherName: meName,
                            learnerUid: widget.learnerUid,
                            learnerName: learnerName,
                            subject: subject,
                          );

                          final body = jsonEncode({
                            'v': 2,
                            'month': _monthLabel(),
                            'course': courseTitle,
                            'stats': {
                              'attendance': _statAttendancePct,
                              'lessonsCovered': _statLessonsCovered,
                              'homeworkPending': _statHomeworkPending,
                            },
                            'skills': skills.map(
                              (k, v) => MapEntry(k, v.round()),
                            ),
                            'note': noteC.text.trim().isEmpty
                                ? ''
                                : noteC.text.trim(),
                            'learnerName': learnerName,
                            'teacherName': meName,
                          });

                          await _sendReportMail(
                            threadId: threadId,
                            teacherUid: meUid,
                            learnerUid: widget.learnerUid,
                            body: body,
                            subject: subject,
                            learnerName: learnerName,
                            teacherName: meName,
                          );

                          final skillValues = skills.map(
                            (k, v) => MapEntry(k, v.round()),
                          );
                          _generateAndSaveDiagram(
                            courseTitle: courseTitle,
                            learnerName: learnerName,
                            teacherName: meName,
                            skillValues: skillValues,
                            note: noteC.text.trim(),
                          );

                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          setLocal(() => sending = false);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text(toHumanError(e))),
                            );
                          }
                        }
                      },
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: Text(sending ? 'Sending…' : 'Send report'),
              ),
            ],
          );
        },
      ),
    );

    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report sent successfully.')),
      );
    }
  }

  Future<void> _generateAndSaveDiagram({
    required String courseTitle,
    required String learnerName,
    required String teacherName,
    required Map<String, int> skillValues,
    required String note,
  }) async {
    try {
      final diagramUrl = await _generateReportDiagram(
        learnerName: learnerName,
        courseTitle: courseTitle,
        teacherName: teacherName,
        skills: skillValues,
        note: note,
      );

      final reportRef = _db.child('reports/${widget.learnerUid}').push();
      await reportRef.set({
        'v': 2,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'createdByName': teacherName,
        'courseTitle': courseTitle,
        'skills': skillValues,
        'stats': {
          'attendance': _statAttendancePct,
          'lessonsCovered': _statLessonsCovered,
          'homeworkPending': _statHomeworkPending,
        },
        'comment': note,
        'diagramUrl': diagramUrl ?? '',
      });
    } catch (_) {}
  }

  Future<String?> _generateReportDiagram({
    required String learnerName,
    required String courseTitle,
    required String teacherName,
    required Map<String, int> skills,
    required String note,
  }) async {
    if (!mounted) return null;
    final month = _monthLabel();
    final diagramKey = GlobalKey();

    final overlayEntry = OverlayEntry(
      builder: (_) => Center(
        child: RepaintBoundary(
          key: diagramKey,
          child: _ReportCardDiagramV3(
            schoolTitle: '',
            learnerName: learnerName,
            courseLabel: courseTitle,
            month: month,
            teacherName: teacherName,
            skills: skills,
            note: note,
          ),
        ),
      ),
    );

    Overlay.of(context).insert(overlayEntry);
    await Future.delayed(const Duration(milliseconds: 300));

    try {
      final ro = diagramKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;
      final image = await ro.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) return null;

      final bytes = byteData.buffer.asUint8List();
      final client = MailUploadClient.defaultClient();
      final name = 'report_${DateTime.now().millisecondsSinceEpoch}.png';
      return client.uploadBytes(bytes: bytes, filename: name);
    } catch (_) {
      return null;
    } finally {
      overlayEntry.remove();
    }
  }

  Widget _statChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(50)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color.withAlpha(180),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Color _attendanceColor(int pct) {
    if (pct >= 80) return const Color(0xFF10B981);
    if (pct >= 50) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  String _attendanceLabel(int pct) {
    if (pct >= 90) return 'Excellent';
    if (pct >= 80) return 'Strong';
    if (pct >= 60) return 'Fair';
    return 'Needs Support';
  }

  String _displayName() {
    final first = _safeStr(_user['first_name']);
    final last = _safeStr(_user['last_name']);
    final fullName = ('$first $last').trim();
    if (fullName.isNotEmpty) return fullName;
    if (widget.learnerName.trim().isNotEmpty) return widget.learnerName.trim();
    return 'Learner';
  }

  Widget _readonlyRow(AppPalette p, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(
                color: p.text.withValues(alpha: 0.7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallStatTile(
    AppPalette p, {
    required IconData icon,
    required String label,
    required String value,
    Color? tint,
  }) {
    final color = tint ?? p.accent;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        color: p.primary.withValues(alpha: 0.04),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: p.text.withValues(alpha: 0.72),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  Widget _buildMainProfileCard(AppPalette p) {
    final fullName = _displayName();
    final role = _safeStr(_user['role']).isEmpty
        ? 'Learner'
        : _safeStr(_user['role']);
    final serial = _safeStr(_user['serial']);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.primary, p.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: p.primary.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 2),
              color: Colors.white.withValues(alpha: 0.10),
            ),
            clipBehavior: Clip.antiAlias,
            child: (_profilePhotoUrl ?? '').isNotEmpty
                ? Image.network(
                    _profilePhotoUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.person_rounded,
                      size: 56,
                      color: Colors.white,
                    ),
                  )
                : const Icon(
                    Icons.person_rounded,
                    size: 56,
                    color: Colors.white,
                  ),
          ),
          const SizedBox(height: 14),
          Text(
            fullName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            role,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.84),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _heroChip(
                text: serial.isEmpty ? 'No serial' : 'ID: $serial',
                icon: Icons.badge_rounded,
              ),
              _heroChip(
                text: 'Attendance $_statAttendancePct%',
                icon: Icons.how_to_reg_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroChip({required String text, required IconData icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExtraPhotosCard(AppPalette p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Extra Photos',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          if (_photoUrls.isEmpty)
            Text(
              'No extra photos yet.',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.7),
                fontWeight: FontWeight.w700,
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _photoUrls.map((url) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    url,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 96,
                      height: 96,
                      color: p.soft,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: p.primary.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(AppPalette p) {
    final attendanceColor = _attendanceColor(_statAttendancePct);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Learning Summary',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.primary.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Attendance Health',
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      '$_statAttendancePct%',
                      style: TextStyle(
                        color: attendanceColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _attendanceLabel(_statAttendancePct),
                      style: TextStyle(
                        color: attendanceColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: (_statAttendancePct / 100).clamp(0, 1),
                    minHeight: 10,
                    backgroundColor: attendanceColor.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation(attendanceColor),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            p,
            icon: Icons.school_rounded,
            label: 'Courses',
            value: '$_statCourses',
            tint: p.accent,
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            p,
            icon: Icons.menu_book_rounded,
            label: 'Lessons Covered',
            value: '$_statLessonsCovered',
            tint: p.primary,
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            p,
            icon: Icons.assignment_late_rounded,
            label: 'Homework Pending',
            value: '$_statHomeworkPending',
            tint: _statHomeworkPending > 0 ? const Color(0xFFEF4444) : p.accent,
          ),
        ],
      ),
    );
  }

  Widget _buildAboutMeCard(AppPalette p) {
    final aboutMe = _safeStr(_user['about_me']);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'About Me',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            aboutMe.isEmpty ? 'No about me yet.' : aboutMe,
            style: TextStyle(
              color: p.text,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(AppPalette p) {
    final email = _safeStr(_user['email']);
    final serial = _safeStr(_user['serial']);
    final role = _safeStr(_user['role']);
    final status = _safeStr(_user['status']);
    final phone1 = _safeStr(_user['phone1']);
    final phone2 = _safeStr(_user['phone2']);
    final dob = _safeStr(_user['dob']);
    final gender = _safeStr(_user['gender']);
    final nationalIdNumber = _safeStr(
      _user['national_id_number'] ?? _user['nationalIdNumber'],
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Profile Info',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          _readonlyRow(p, 'Email', email),
          _readonlyRow(p, 'Serial', serial),
          _readonlyRow(p, 'Role', role),
          _readonlyRow(p, 'Status', status),
          _readonlyRow(p, 'National ID', nationalIdNumber),
          _readonlyRow(p, 'Phone 1', phone1),
          _readonlyRow(p, 'Phone 2', phone2),
          _readonlyRow(p, 'Gender', gender),
          _readonlyRow(p, 'DOB', dob),
        ],
      ),
    );
  }

  Widget _buildErrorState(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: const Color(0xFFEF4444).withValues(alpha: 0.20),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 56,
                color: Color(0xFFEF4444),
              ),
              const SizedBox(height: 12),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFEF4444),
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final title = widget.learnerName.isEmpty
        ? 'Learner Profile'
        : widget.learnerName;

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Text(
          title,
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Monthly report',
            icon: Icon(Icons.assessment_rounded, color: p.primary),
            onPressed: _busy ? null : _openMonthlyReportComposer,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1240,
        child: _busy
            ? Center(child: CircularProgressIndicator(color: p.primary))
            : _error != null
            ? _buildErrorState(p)
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildMainProfileCard(p),
                  const SizedBox(height: 14),
                  _buildExtraPhotosCard(p),
                  const SizedBox(height: 14),
                  _buildSummaryCard(p),
                  const SizedBox(height: 14),
                  _buildAboutMeCard(p),
                  const SizedBox(height: 14),
                  _buildAccountCard(p),
                ],
              ),
      ),
    );
  }
}

class _ReportCardDiagramV3 extends StatelessWidget {
  const _ReportCardDiagramV3({
    required this.schoolTitle,
    required this.learnerName,
    required this.courseLabel,
    required this.month,
    required this.teacherName,
    required this.skills,
    required this.note,
  });

  final String schoolTitle;
  final String learnerName;
  final String courseLabel;
  final String month;
  final String teacherName;
  final Map<String, int> skills;
  final String note;

  static const _skillLabels = <String, String>{
    'participation': 'Participation',
    'behavior': 'Behavior / Conduct',
    'punctuality': 'Punctuality',
    'vocabulary': 'Vocabulary Range',
    'fluency': 'Speaking Fluency',
    'grammar': 'Grammar Accuracy',
    'writing': 'Writing / Punctuation',
    'listening': 'Listening Comprehension',
  };

  static const _leftKeys = [
    'participation',
    'behavior',
    'punctuality',
    'vocabulary',
  ];

  int _toScore(int v) {
    if (v >= 80) return 5;
    if (v >= 60) return 4;
    if (v >= 40) return 3;
    if (v >= 20) return 2;
    return 1;
  }

  Color _dotColor(int score) {
    if (score >= 4) return const Color(0xFF10B981);
    if (score >= 3) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF1F4E79);
    const deepNavy = Color(0xFF163B5D);
    const slate = Color(0xFF334155);

    final avg = skills.values.isEmpty
        ? 0
        : (skills.values.reduce((a, b) => a + b) / skills.length).round();

    return Container(
      width: 360,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF7FBFF), Color(0xFFFFFAF2)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDBE6F2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: DefaultTextStyle(
          style: const TextStyle(color: Color(0xFF0F172A)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [deepNavy, navy],
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.school_rounded,
                        size: 28,
                        color: navy,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            schoolTitle.isNotEmpty
                                ? schoolTitle
                                : 'Your Bridge School',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.86),
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Learner Progress Report',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      learnerName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        color: Color(0xFF102A43),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Course: $courseLabel',
                      style: const TextStyle(
                        color: slate,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      'Date: $month',
                      style: const TextStyle(
                        color: slate,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      'Teacher: $teacherName',
                      style: const TextStyle(
                        color: slate,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _metricChip(
                          label: 'Avg Score',
                          value: '$avg/100',
                          background: navy.withAlpha(20),
                          foreground: navy,
                        ),
                        _metricChip(
                          label: 'Skills',
                          value: '${skills.length}',
                          background: const Color(0xFFE8F1FF),
                          foreground: const Color(0xFF2A5B9C),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (skills.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F8FF),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFD1E4F7)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _buildSkillColumn(_leftKeys),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildSkillColumn(
                                _skillLabels.keys
                                    .where((k) => !_leftKeys.contains(k))
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (note.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF8EC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFFD9A3)),
                        ),
                        child: Text(
                          note,
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1.28,
                            color: Color(0xFF3F2A04),
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metricChip({
    required String label,
    required String value,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: 0.22)),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                color: foreground.withValues(alpha: 0.80),
                fontWeight: FontWeight.w800,
                fontSize: 10,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w900,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scoreDots(int score, {required Color active}) {
    final s = score.clamp(1, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final on = i < s;
        return Container(
          width: 8,
          height: 8,
          margin: EdgeInsets.only(right: i == 4 ? 0 : 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? active : active.withValues(alpha: 0.20),
          ),
        );
      }),
    );
  }

  Widget _buildSkillColumn(List<String> keys) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final key in keys) ...[
          if (keys.indexOf(key) > 0) const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: Text(
                  _skillLabels[key] ?? key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    color: Color(0xFF1E293B),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _scoreDots(
                _toScore(skills[key] ?? 0),
                active: _dotColor(_toScore(skills[key] ?? 0)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
