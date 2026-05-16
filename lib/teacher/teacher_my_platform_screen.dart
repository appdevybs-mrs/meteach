import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/course_feedback_service.dart';
import '../shared/study_variant.dart';
import 'teacher_recorded_course_comments_screen.dart';

class TeacherMyPlatformScreen extends StatefulWidget {
  const TeacherMyPlatformScreen({super.key});

  @override
  State<TeacherMyPlatformScreen> createState() =>
      _TeacherMyPlatformScreenState();
}

enum _MyPlatformMainTab { learners, courses }

class _MyPlatformItem {
  const _MyPlatformItem({
    required this.courseId,
    required this.lessonId,
    required this.entryId,
    required this.uid,
    required this.firstName,
    required this.displayName,
    required this.photoUrl,
    required this.abbr,
    required this.text,
    required this.status,
    required this.reportCount,
    required this.createdAt,
  });

  final String courseId;
  final String lessonId;
  final String entryId;
  final String uid;
  final String firstName;
  final String displayName;
  final String photoUrl;
  final String abbr;
  final String text;
  final String status;
  final int reportCount;
  final int createdAt;
}

class _LearnerRecordedProgressItem {
  const _LearnerRecordedProgressItem({
    required this.learnerUid,
    required this.learnerName,
    required this.courseKey,
    required this.courseId,
    required this.courseTitle,
    required this.completedSessions,
    required this.totalSessions,
    required this.progressPct,
  });

  final String learnerUid;
  final String learnerName;
  final String courseKey;
  final String courseId;
  final String courseTitle;
  final int completedSessions;
  final int totalSessions;
  final int progressPct;
}

class _RecordedCourseSummary {
  const _RecordedCourseSummary({
    required this.courseId,
    required this.courseTitle,
    required this.courseCode,
    required this.learnerCount,
    required this.completedLearnerCount,
    required this.commentCount,
    required this.pendingCommentCount,
    required this.reportedCommentCount,
    required this.hiddenCommentCount,
    required this.latestCommentAt,
  });

  final String courseId;
  final String courseTitle;
  final String courseCode;
  final int learnerCount;
  final int completedLearnerCount;
  final int commentCount;
  final int pendingCommentCount;
  final int reportedCommentCount;
  final int hiddenCommentCount;
  final int latestCommentAt;
}

class _RecordedSessionMeta {
  const _RecordedSessionMeta({
    required this.hasVideo,
    required this.hasMaterials,
  });

  final bool hasVideo;
  final bool hasMaterials;
}

class _RecordedLessonDetail {
  const _RecordedLessonDetail({
    required this.title,
    required this.unitTitle,
    required this.moduleTitle,
    required this.hasVideo,
    required this.hasMaterials,
    required this.videoDone,
    required this.materialsDone,
  });

  final String title;
  final String unitTitle;
  final String moduleTitle;
  final bool hasVideo;
  final bool hasMaterials;
  final bool videoDone;
  final bool materialsDone;

  bool get isDone {
    if (hasVideo && hasMaterials) return videoDone || materialsDone;
    if (hasVideo) return videoDone;
    if (hasMaterials) return materialsDone;
    return false;
  }
}

class _RecordedLearnerDetails {
  const _RecordedLearnerDetails({required this.studied, required this.left});

  final List<_RecordedLessonDetail> studied;
  final List<_RecordedLessonDetail> left;
}

class _TeacherMyPlatformScreenState extends State<TeacherMyPlatformScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _busy = true;
  String? _error;
  bool _learnersBusy = true;
  String? _learnersError;
  _MyPlatformMainTab _mainTab = _MyPlatformMainTab.learners;

  List<_MyPlatformItem> _all = const [];
  List<_LearnerRecordedProgressItem> _learnerProgressRows = const [];
  Set<String> _assignedCourseIds = const <String>{};
  final Map<String, String> _courseLabelById = <String, String>{};
  final Map<String, Map<String, _RecordedSessionMeta>> _recordedMetaCache =
      <String, Map<String, _RecordedSessionMeta>>{};
  final Set<String> _expandedRecordedRows = <String>{};
  final Map<String, Future<_RecordedLearnerDetails>>
  _recordedDetailsFutureByRow = <String, Future<_RecordedLearnerDetails>>{};

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _learnersBusy = true;
      _learnersError = null;
    });
    try {
      final assignedMap = await _loadAssignedCourses();
      final assigned = assignedMap.keys.toSet();
      final items = await _loadFeedbackItems(assigned);
      _recordedMetaCache.clear();
      final learnerRows = await _loadRecordedLearnerProgress(
        assignedCourseKeys: assigned,
      );

      if (!mounted) return;
      setState(() {
        _assignedCourseIds = assigned;
        _courseLabelById
          ..clear()
          ..addAll(assignedMap);
        _all = items;
        _learnerProgressRows = learnerRows;
        _expandedRecordedRows.clear();
        _recordedDetailsFutureByRow.clear();
        _busy = false;
        _learnersBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
        _learnersError = e.toString();
        _learnersBusy = false;
      });
    }
  }

  Future<Map<String, String>> _loadAssignedCourses() async {
    final out = <String, String>{};

    final userCoursesSnap = await _db
        .child('users')
        .child(_uid)
        .child('courses')
        .get();
    if (userCoursesSnap.exists && userCoursesSnap.value is Map) {
      final courses = Map<dynamic, dynamic>.from(userCoursesSnap.value as Map);
      for (final entry in courses.entries) {
        if (entry.value is! Map) continue;
        final nodeKey = entry.key.toString().trim();
        final m = (entry.value as Map).map((k, v) => MapEntry('$k', v));

        final id = (m['id'] ?? '').toString().trim();
        final title = (m['title'] ?? '').toString().trim();
        final code = (m['course_code'] ?? '').toString().trim();
        final label = title.isEmpty
            ? (code.isEmpty ? (id.isEmpty ? nodeKey : id) : code)
            : (code.isEmpty ? title : '$title ($code)');

        if (id.isNotEmpty) out[id] = label;
        if (nodeKey.isNotEmpty) out[nodeKey] = label;
      }
    }

    if (out.isEmpty) {
      final classesSnap = await _db.child('classes').get();
      if (classesSnap.exists && classesSnap.value is Map) {
        final classes = Map<dynamic, dynamic>.from(classesSnap.value as Map);
        for (final entry in classes.entries) {
          if (entry.value is! Map) continue;
          final m = (entry.value as Map).map((k, v) => MapEntry('$k', v));
          final cur = m['instructor_current'];
          final currentUid = cur is Map
              ? (cur['uid'] ?? '').toString().trim()
              : '';
          if (currentUid != _uid) continue;

          final cid = (m['course_id'] ?? '').toString().trim();
          if (cid.isNotEmpty) {
            out[cid] = (m['course_title'] ?? cid).toString();
          }
        }
      }
    }

    return out;
  }

  Future<List<_MyPlatformItem>> _loadFeedbackItems(
    Set<String> courseIds,
  ) async {
    if (courseIds.isEmpty) return const [];

    final out = <_MyPlatformItem>[];

    for (final courseId in courseIds) {
      final commentsSnap = await _db
          .child('lesson_comments')
          .child(courseId)
          .get();
      if (!commentsSnap.exists || commentsSnap.value is! Map) continue;

      final lessons = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
      for (final lesson in lessons.entries) {
        final lessonId = lesson.key.toString();
        if (lesson.value is! Map) continue;

        final comments = Map<dynamic, dynamic>.from(lesson.value as Map);
        for (final entry in comments.entries) {
          if (entry.value is! Map) continue;
          final m = (entry.value as Map).map((k, v) => MapEntry('$k', v));
          final item = LessonCommentItem.fromMap(entry.key.toString(), m);
          out.add(
            _MyPlatformItem(
              courseId: courseId,
              lessonId: lessonId,
              entryId: item.id,
              uid: item.uid,
              firstName: item.firstName,
              displayName: item.displayName,
              photoUrl: item.photoUrl,
              abbr: item.abbr,
              text: item.text,
              status: item.status,
              reportCount: item.reportCount,
              createdAt: item.createdAt,
            ),
          );
        }
      }
    }

    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<Map<String, _RecordedSessionMeta>> _loadRecordedSessionMeta(
    String courseId,
  ) async {
    final cid = courseId.trim();
    if (cid.isEmpty) return const <String, _RecordedSessionMeta>{};

    final cached = _recordedMetaCache[cid];
    if (cached != null) return cached;

    final out = <String, _RecordedSessionMeta>{};

    try {
      final snap = await _db
          .child('syllabi')
          .child(cid)
          .child('recorded')
          .get();
      if (snap.exists && snap.value is Map) {
        final root = Map<dynamic, dynamic>.from(snap.value as Map);

        void addSession(dynamic raw) {
          if (raw is! Map) return;
          final m = Map<String, dynamic>.from(raw);
          final sessionId = (m['id'] ?? '').toString().trim();
          if (sessionId.isEmpty) return;

          out[sessionId] = _RecordedSessionMeta(
            hasVideo: (m['videoUrl'] ?? '').toString().trim().isNotEmpty,
            hasMaterials: (m['materialsUrl'] ?? '')
                .toString()
                .trim()
                .isNotEmpty,
          );
        }

        final modulesRaw = root['modules'];
        if (modulesRaw is List) {
          for (final module in modulesRaw) {
            if (module is! Map) continue;
            final moduleMap = Map<dynamic, dynamic>.from(module);
            final unitsRaw = moduleMap['units'];
            if (unitsRaw is! List) continue;
            for (final unit in unitsRaw) {
              if (unit is! Map) continue;
              final unitMap = Map<dynamic, dynamic>.from(unit);
              final lessonsRaw = unitMap['lessons'];
              if (lessonsRaw is! List) continue;
              for (final lesson in lessonsRaw) {
                addSession(lesson);
              }
            }
          }
        } else {
          final unitsRaw = root['units'];
          if (unitsRaw is List) {
            for (final unit in unitsRaw) {
              if (unit is! Map) continue;
              final unitMap = Map<dynamic, dynamic>.from(unit);
              final sessionsRaw = unitMap['sessions'];
              if (sessionsRaw is! List) continue;
              for (final session in sessionsRaw) {
                addSession(session);
              }
            }
          }
        }
      }
    } catch (_) {}

    _recordedMetaCache[cid] = out;
    return out;
  }

  bool _isRecordedSessionDone({
    required _RecordedSessionMeta meta,
    required Map<String, dynamic> progress,
  }) {
    bool asBool(dynamic v) {
      if (v is bool) return v;
      final s = (v ?? '').toString().trim().toLowerCase();
      return s == 'true' || s == '1';
    }

    final videoDone = asBool(progress['videoCompleted']);
    final materialsDone = asBool(progress['materialsCompleted']);

    if (meta.hasVideo && meta.hasMaterials) {
      return videoDone || materialsDone;
    }
    if (meta.hasVideo) return videoDone;
    if (meta.hasMaterials) return materialsDone;
    return false;
  }

  Future<List<_LearnerRecordedProgressItem>> _loadRecordedLearnerProgress({
    required Set<String> assignedCourseKeys,
  }) async {
    final out = <_LearnerRecordedProgressItem>[];

    final usersSnap = await _db.child('users').get();
    if (!usersSnap.exists || usersSnap.value is! Map) return out;

    final users = Map<dynamic, dynamic>.from(usersSnap.value as Map);

    for (final userEntry in users.entries) {
      final learnerUid = userEntry.key.toString().trim();
      if (learnerUid.isEmpty || userEntry.value is! Map) continue;

      final user = Map<String, dynamic>.from(userEntry.value as Map);
      final role = (user['role'] ?? '').toString().trim().toLowerCase();
      if (role != 'learner' && role != 'learners' && role != 'learner(s)') {
        continue;
      }

      final first = (user['first_name'] ?? '').toString().trim();
      final last = (user['last_name'] ?? '').toString().trim();
      final email = (user['email'] ?? '').toString().trim();
      final learnerName = ('$first $last').trim().isNotEmpty
          ? ('$first $last').trim()
          : (email.isNotEmpty ? email : 'Learner');

      final coursesRaw = user['courses'];
      if (coursesRaw is! Map) continue;
      final courses = Map<dynamic, dynamic>.from(coursesRaw);

      for (final cEntry in courses.entries) {
        final courseKey = cEntry.key.toString().trim();
        if (courseKey.isEmpty || cEntry.value is! Map) continue;

        final course = Map<String, dynamic>.from(cEntry.value as Map);
        final variant = normalizeVariantKey(
          (course['variantKey'] ?? course['variant'] ?? '').toString(),
        );
        if (variant != 'recorded') continue;

        final courseId =
            (course['id'] ?? course['courseId'] ?? course['course_id'] ?? '')
                .toString()
                .trim();
        if (courseId.isEmpty) continue;

        if (assignedCourseKeys.isNotEmpty &&
            !assignedCourseKeys.contains(courseId) &&
            !assignedCourseKeys.contains(courseKey)) {
          continue;
        }

        final courseTitle = (course['title'] ?? '').toString().trim().isNotEmpty
            ? (course['title'] ?? '').toString().trim()
            : (courseId.isNotEmpty ? courseId : 'Recorded course');

        final progressRaw = course['recorded_progress'];
        final progressMap = progressRaw is Map
            ? progressRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final sessionMeta = await _loadRecordedSessionMeta(courseId);

        int totalSessions = sessionMeta.length;
        int completedSessions = 0;

        if (sessionMeta.isNotEmpty) {
          for (final sessionEntry in sessionMeta.entries) {
            final raw = progressMap[sessionEntry.key];
            if (raw is! Map) continue;
            final progress = raw.map((k, v) => MapEntry('$k', v));
            if (_isRecordedSessionDone(
              meta: sessionEntry.value,
              progress: progress,
            )) {
              completedSessions += 1;
            }
          }
        } else if (progressMap.isNotEmpty) {
          totalSessions = progressMap.length;
          for (final raw in progressMap.values) {
            if (raw is! Map) continue;
            final progress = raw.map((k, v) => MapEntry('$k', v));
            if ((progress['videoCompleted'] == true) ||
                (progress['materialsCompleted'] == true)) {
              completedSessions += 1;
            }
          }
        }

        final pct = totalSessions > 0
            ? ((completedSessions / totalSessions) * 100).round().clamp(0, 100)
            : 0;

        out.add(
          _LearnerRecordedProgressItem(
            learnerUid: learnerUid,
            learnerName: learnerName,
            courseKey: courseKey,
            courseId: courseId,
            courseTitle: courseTitle,
            completedSessions: completedSessions,
            totalSessions: totalSessions,
            progressPct: pct,
          ),
        );
      }
    }

    out.sort((a, b) {
      final cmp = a.learnerName.toLowerCase().compareTo(
        b.learnerName.toLowerCase(),
      );
      if (cmp != 0) return cmp;
      return a.courseTitle.toLowerCase().compareTo(b.courseTitle.toLowerCase());
    });
    return out;
  }

  String _recordedRowKey(_LearnerRecordedProgressItem item) {
    return '${item.learnerUid}__${item.courseKey}__${item.courseId}';
  }

  List<Map<String, dynamic>> _asListOfMaps(dynamic node) {
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

  bool _asBool(dynamic v) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1';
  }

  Future<_RecordedLearnerDetails> _loadRecordedLearnerDetails(
    _LearnerRecordedProgressItem item,
  ) async {
    final courseId = item.courseId.trim();
    final courseKey = item.courseKey.trim();
    final learnerUid = item.learnerUid.trim();
    if (courseId.isEmpty || courseKey.isEmpty || learnerUid.isEmpty) {
      return const _RecordedLearnerDetails(studied: [], left: []);
    }

    final syllabusSnap = await _db
        .child('syllabi')
        .child(courseId)
        .child('recorded')
        .get();
    final progressSnap = await _db
        .child('users')
        .child(learnerUid)
        .child('courses')
        .child(courseKey)
        .child('recorded_progress')
        .get();

    final progressMap = (progressSnap.exists && progressSnap.value is Map)
        ? Map<dynamic, dynamic>.from(progressSnap.value as Map)
        : <dynamic, dynamic>{};

    final sessionItems = <Map<String, dynamic>>[];
    if (syllabusSnap.exists && syllabusSnap.value is Map) {
      final root = Map<String, dynamic>.from(syllabusSnap.value as Map);
      final rawModules = _asListOfMaps(root['modules']);
      if (rawModules.isNotEmpty) {
        for (int mi = 0; mi < rawModules.length; mi++) {
          final module = rawModules[mi];
          final moduleLabel =
              (module['otherTitle'] ?? '').toString().trim().isNotEmpty
              ? (module['otherTitle'] ?? '').toString().trim()
              : ((module['title'] ?? '').toString().trim().isNotEmpty
                    ? (module['title'] ?? '').toString().trim()
                    : 'M${mi + 1}');
          final rawUnits = _asListOfMaps(module['units']);
          for (final unit in rawUnits) {
            final unitTitle = (unit['title'] ?? '').toString().trim();
            final rawLessons = _asListOfMaps(unit['lessons']);
            for (final lesson in rawLessons) {
              sessionItems.add({
                'moduleTitle': moduleLabel,
                'unitTitle': unitTitle,
                ...lesson,
              });
            }
          }
        }
      } else {
        final rawUnits = _asListOfMaps(root['units']);
        for (final unit in rawUnits) {
          final unitTitle = (unit['title'] ?? '').toString().trim();
          final rawSessions = _asListOfMaps(unit['sessions']);
          for (final session in rawSessions) {
            sessionItems.add({
              'moduleTitle': '',
              'unitTitle': unitTitle,
              ...session,
            });
          }
        }
      }
    }

    int orderOf(Map<String, dynamic> s) {
      final n = int.tryParse((s['sessionNumber'] ?? '').toString()) ?? 0;
      if (n > 0) return n;
      return int.tryParse((s['order'] ?? '').toString()) ?? 0;
    }

    sessionItems.sort((a, b) => orderOf(a).compareTo(orderOf(b)));

    final studied = <_RecordedLessonDetail>[];
    final left = <_RecordedLessonDetail>[];

    for (int i = 0; i < sessionItems.length; i++) {
      final session = sessionItems[i];
      final sessionId = (session['id'] ?? '').toString().trim();
      final titleRaw = (session['title'] ?? '').toString().trim();
      final title = titleRaw.isNotEmpty ? titleRaw : 'Session ${i + 1}';
      final unitTitle = (session['unitTitle'] ?? '').toString().trim();
      final moduleTitle = (session['moduleTitle'] ?? '').toString().trim();

      final hasVideo = (session['videoUrl'] ?? '').toString().trim().isNotEmpty;
      final hasMaterials = (session['materialsUrl'] ?? '')
          .toString()
          .trim()
          .isNotEmpty;

      final raw = progressMap[sessionId];
      final progress = raw is Map
          ? Map<dynamic, dynamic>.from(raw)
          : <dynamic, dynamic>{};
      final videoDone = _asBool(progress['videoCompleted']);
      final materialsDone = _asBool(progress['materialsCompleted']);

      final detail = _RecordedLessonDetail(
        title: title,
        unitTitle: unitTitle,
        moduleTitle: moduleTitle,
        hasVideo: hasVideo,
        hasMaterials: hasMaterials,
        videoDone: videoDone,
        materialsDone: materialsDone,
      );

      if (detail.isDone) {
        studied.add(detail);
      } else {
        left.add(detail);
      }
    }

    return _RecordedLearnerDetails(studied: studied, left: left);
  }

  Widget _compactStatusChip({
    required IconData icon,
    required String label,
    required bool done,
  }) {
    final fg = done ? const Color(0xFF15803D) : const Color(0xFF64748B);
    final bg = done ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _lessonCompactRow(_RecordedLessonDetail item, {required bool done}) {
    final contextBits = <String>[];
    if (item.moduleTitle.isNotEmpty) contextBits.add(item.moduleTitle);
    if (item.unitTitle.isNotEmpty) contextBits.add(item.unitTitle);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFF0FDF4) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          if (contextBits.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              contextBits.join(' • '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF64748B),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              if (item.hasVideo)
                _compactStatusChip(
                  icon: Icons.play_circle_fill_rounded,
                  label: item.videoDone ? 'VD' : 'VP',
                  done: item.videoDone,
                ),
              if (item.hasMaterials)
                _compactStatusChip(
                  icon: Icons.description_rounded,
                  label: item.materialsDone ? 'MD' : 'MP',
                  done: item.materialsDone,
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _courseLabel(String id) => _courseLabelById[id] ?? id;

  Color _courseAccent(String courseId) {
    const accents = [
      Color(0xFF2563EB),
      Color(0xFF7C3AED),
      Color(0xFFF97316),
      Color(0xFF0EA5A4),
      Color(0xFFEC4899),
      Color(0xFF14B8A6),
    ];
    return accents[courseId.hashCode.abs() % accents.length];
  }

  List<_RecordedCourseSummary> get _recordedCourseSummaries {
    final learnerSets = <String, Set<String>>{};
    final completedSets = <String, Set<String>>{};
    final commentCounts = <String, int>{};
    final pendingCounts = <String, int>{};
    final reportedCounts = <String, int>{};
    final hiddenCounts = <String, int>{};
    final lastCommentAt = <String, int>{};
    final titles = <String, String>{};

    for (final row in _learnerProgressRows) {
      learnerSets
          .putIfAbsent(row.courseId, () => <String>{})
          .add(row.learnerUid);
      if (row.progressPct >= 100) {
        completedSets
            .putIfAbsent(row.courseId, () => <String>{})
            .add(row.learnerUid);
      }
      titles[row.courseId] = row.courseTitle;
    }

    for (final item in _all) {
      commentCounts[item.courseId] = (commentCounts[item.courseId] ?? 0) + 1;
      if (item.status == 'pending') {
        pendingCounts[item.courseId] = (pendingCounts[item.courseId] ?? 0) + 1;
      }
      if (item.reportCount > 0 && item.status != 'removed') {
        reportedCounts[item.courseId] =
            (reportedCounts[item.courseId] ?? 0) + 1;
      }
      if (item.status == 'hidden' || item.status == 'removed') {
        hiddenCounts[item.courseId] = (hiddenCounts[item.courseId] ?? 0) + 1;
      }
      final prev = lastCommentAt[item.courseId] ?? 0;
      if (item.createdAt > prev) lastCommentAt[item.courseId] = item.createdAt;
    }

    final courseIds = learnerSets.keys.where((courseId) {
      if (_assignedCourseIds.isEmpty) return true;
      return _assignedCourseIds.contains(courseId);
    }).toList()..sort();
    return courseIds.map((courseId) {
      return _RecordedCourseSummary(
        courseId: courseId,
        courseTitle: titles[courseId] ?? _courseLabel(courseId),
        courseCode: _courseLabelById[courseId] ?? courseId,
        learnerCount: learnerSets[courseId]?.length ?? 0,
        completedLearnerCount: completedSets[courseId]?.length ?? 0,
        commentCount: commentCounts[courseId] ?? 0,
        pendingCommentCount: pendingCounts[courseId] ?? 0,
        reportedCommentCount: reportedCounts[courseId] ?? 0,
        hiddenCommentCount: hiddenCounts[courseId] ?? 0,
        latestCommentAt: lastCommentAt[courseId] ?? 0,
      );
    }).toList();
  }

  void _openRecordedCourseComments(_RecordedCourseSummary course) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeacherRecordedCourseCommentsScreen(
          courseId: course.courseId,
          courseTitle: course.courseTitle,
          courseCode: course.courseCode,
        ),
      ),
    );
  }

  Widget _buildRecordedCoursesBody() {
    final summaries =
        _recordedCourseSummaries
            .where((course) => course.learnerCount > 0)
            .toList()
          ..sort((a, b) {
            final cmp = b.latestCommentAt.compareTo(a.latestCommentAt);
            if (cmp != 0) return cmp;
            return a.courseTitle.toLowerCase().compareTo(
              b.courseTitle.toLowerCase(),
            );
          });

    if (summaries.isEmpty) {
      return const Center(
        child: Text('No recorded courses with learners yet.'),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: summaries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final course = summaries[index];
        final accent = _courseAccent(course.courseId);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => _openRecordedCourseComments(course),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: accent.withValues(alpha: 0.16)),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.05),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.video_library_rounded,
                          color: accent,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              course.courseTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              course.courseCode.isEmpty
                                  ? course.courseId
                                  : course.courseCode,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.w700,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFDE68A),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          '!',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            color: Color(0xFF92400E),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _courseStatChip(
                        'Learners',
                        course.learnerCount,
                        const Color(0xFFE0F2FE),
                        const Color(0xFF0369A1),
                      ),
                      _courseStatChip(
                        'Comments',
                        course.commentCount,
                        const Color(0xFFEDE9FE),
                        const Color(0xFF6D28D9),
                      ),
                      _courseStatChip(
                        'Pending',
                        course.pendingCommentCount,
                        const Color(0xFFFEF3C7),
                        const Color(0xFFB45309),
                      ),
                      _courseStatChip(
                        'Reported',
                        course.reportedCommentCount,
                        const Color(0xFFFEE2E2),
                        const Color(0xFFB91C1C),
                      ),
                      _courseStatChip(
                        'Completed',
                        course.completedLearnerCount,
                        const Color(0xFFD1FAE5),
                        const Color(0xFF047857),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: () => _openRecordedCourseComments(course),
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Open comments'),
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

  Widget _courseStatChip(String label, int value, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 11),
      ),
    );
  }

  Widget _mainTabChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        fontWeight: FontWeight.w800,
        color: selected ? const Color(0xFF0F172A) : const Color(0xFF475569),
      ),
      selectedColor: const Color(0xFFE2E8F0),
      backgroundColor: const Color(0xFFF8FAFC),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    );
  }

  Widget _buildLearnersProgressBody() {
    if (_learnersBusy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_learnersError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_learnersError!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_learnerProgressRows.isEmpty) {
      return const Center(child: Text('No recorded learner progress found.'));
    }

    final totalCompleted = _learnerProgressRows.fold<int>(
      0,
      (sum, item) => sum + item.completedSessions,
    );
    final totalSessions = _learnerProgressRows.fold<int>(
      0,
      (sum, item) => sum + item.totalSessions,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Text(
            'Recorded learners: ${_learnerProgressRows.length} • Completed: $totalCompleted / $totalSessions',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Color(0xFF334155),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            itemCount: _learnerProgressRows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final item = _learnerProgressRows[i];
              final rowKey = _recordedRowKey(item);
              final expanded = _expandedRecordedRows.contains(rowKey);
              final progress = item.totalSessions > 0
                  ? (item.completedSessions / item.totalSessions).clamp(
                      0.0,
                      1.0,
                    )
                  : 0.0;
              return Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.learnerName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          splashRadius: 16,
                          tooltip: expanded ? 'Hide details' : 'Show details',
                          icon: Icon(
                            expanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            color: const Color(0xFF334155),
                          ),
                          onPressed: () {
                            setState(() {
                              if (expanded) {
                                _expandedRecordedRows.remove(rowKey);
                              } else {
                                _expandedRecordedRows.add(rowKey);
                                _recordedDetailsFutureByRow[rowKey] ??=
                                    _loadRecordedLearnerDetails(item);
                              }
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Course: ${item.courseTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF334155),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Recorded progress: ${item.completedSessions} / ${item.totalSessions}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Progress: ${item.progressPct}%',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 9,
                        backgroundColor: const Color(0xFFE2E8F0),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF0EA5A4),
                        ),
                      ),
                    ),
                    if (expanded) ...[
                      const SizedBox(height: 10),
                      FutureBuilder<_RecordedLearnerDetails>(
                        future: _recordedDetailsFutureByRow[rowKey],
                        builder: (context, snap) {
                          if (snap.hasError) {
                            return const Text(
                              'Could not load lesson details.',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFFB91C1C),
                                fontWeight: FontWeight.w700,
                              ),
                            );
                          }
                          if (!snap.hasData) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          }

                          final details = snap.data!;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Studied lessons',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF166534),
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (details.studied.isEmpty)
                                const Text(
                                  'No studied lessons yet.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF64748B),
                                  ),
                                )
                              else
                                ...details.studied.map(
                                  (x) => _lessonCompactRow(x, done: true),
                                ),
                              const SizedBox(height: 8),
                              const Text(
                                'Left lessons',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF9A3412),
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (details.left.isEmpty)
                                const Text(
                                  'No pending lessons.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF64748B),
                                  ),
                                )
                              else
                                ...details.left.map(
                                  (x) => _lessonCompactRow(x, done: false),
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Platform'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                _mainTabChip(
                  label: 'Learners',
                  selected: _mainTab == _MyPlatformMainTab.learners,
                  onTap: () {
                    setState(() => _mainTab = _MyPlatformMainTab.learners);
                  },
                ),
                const SizedBox(width: 8),
                _mainTabChip(
                  label: 'Courses',
                  selected: _mainTab == _MyPlatformMainTab.courses,
                  onTap: () {
                    setState(() => _mainTab = _MyPlatformMainTab.courses);
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: _mainTab == _MyPlatformMainTab.learners
                ? _buildLearnersProgressBody()
                : (_busy
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(_error!, textAlign: TextAlign.center),
                          ),
                        )
                      : _buildRecordedCoursesBody()),
          ),
        ],
      ),
    );
  }
}
