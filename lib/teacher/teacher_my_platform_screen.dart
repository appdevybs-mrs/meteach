import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/course_feedback_service.dart';
import '../services/internal_mail_service.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/profile_avatar.dart';
import '../shared/study_variant.dart';
import 'teacher_learner_profile_screen.dart';
import 'teacher_mail_thread_screen.dart';
import 'teacher_reminder.dart';
import 'teacher_recorded_course_comments_screen.dart';

class TeacherMyPlatformScreen extends StatefulWidget {
  const TeacherMyPlatformScreen({super.key});

  @override
  State<TeacherMyPlatformScreen> createState() =>
      _TeacherMyPlatformScreenState();
}

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
    required this.photoUrl,
    required this.courseKey,
    required this.courseId,
    required this.courseTitle,
    required this.completedSessions,
    required this.totalSessions,
    required this.progressPct,
  });

  final String learnerUid;
  final String learnerName;
  final String photoUrl;
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
    required this.lessonId,
    required this.title,
    required this.unitTitle,
    required this.moduleTitle,
    required this.moduleOrder,
    required this.unitOrder,
    required this.lessonOrder,
    required this.hasVideo,
    required this.hasMaterials,
    required this.videoDone,
    required this.materialsDone,
    this.commentStatus,
    this.commentText,
    this.commentId,
  });

  final String lessonId;
  final String title;
  final String unitTitle;
  final String moduleTitle;
  final int moduleOrder;
  final int unitOrder;
  final int lessonOrder;
  final bool hasVideo;
  final bool hasMaterials;
  final bool videoDone;
  final bool materialsDone;
  final String? commentStatus;
  final String? commentText;
  final String? commentId;

  bool get isDone {
    if (hasVideo && hasMaterials && !videoDone) return false;
    if (hasVideo && !videoDone) return false;
    if (hasMaterials && !materialsDone) return false;
    final cs = commentStatus;
    if (cs == null) return false;
    return CourseFeedbackService.normalizeLessonCommentStatus(cs) ==
        CourseFeedbackService.statusVisible;
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

  List<_MyPlatformItem> _all = const [];
  List<_LearnerRecordedProgressItem> _learnerProgressRows = const [];
  Set<String> _assignedCourseIds = const <String>{};
  final Map<String, String> _courseLabelById = <String, String>{};
  final Map<String, String> _courseThumbnailById = <String, String>{};
  final Set<String> _expandedCourseIds = <String>{};
  final Map<String, String> _learnerSearchByCourse = <String, String>{};
  final Map<String, Set<String>> _assignedCourseKeysByLearnerUid =
      <String, Set<String>>{};
  final Map<String, Map<String, Map<String, String>>> _commentCacheByCourse =
      <String, Map<String, Map<String, String>>>{};
  final Map<String, Map<String, _RecordedSessionMeta>> _recordedMetaCache =
      <String, Map<String, _RecordedSessionMeta>>{};
  final Map<String, Future<_RecordedLearnerDetails>>
  _recordedDetailsFutureByRow = <String, Future<_RecordedLearnerDetails>>{};
  final Map<String, StreamSubscription<DatabaseEvent>>
  _lessonCommentSubscriptions = <String, StreamSubscription<DatabaseEvent>>{};
  Timer? _debounceLoadTimer;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final sub in _lessonCommentSubscriptions.values) {
      sub.cancel();
    }
    _lessonCommentSubscriptions.clear();
    _debounceLoadTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _learnersBusy = true;
      _learnersError = null;
    });
    try {
      _assignedCourseKeysByLearnerUid.clear();
      _commentCacheByCourse.clear();
      _courseThumbnailById.clear();
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
        _recordedDetailsFutureByRow.clear();
        _busy = false;
        _learnersBusy = false;
      });
      _setupLessonCommentSubscriptions(assigned);
      _silentLegacyCleanup();
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

  void _setupLessonCommentSubscriptions(Set<String> courseIds) {
    for (final sub in _lessonCommentSubscriptions.values) {
      sub.cancel();
    }
    _lessonCommentSubscriptions.clear();
    for (final courseId in courseIds) {
      if (courseId.trim().isEmpty) continue;
      final sub = _db.child('lesson_comments').child(courseId).onValue.listen((
        _,
      ) {
        _debouncedLoad();
      });
      _lessonCommentSubscriptions[courseId] = sub;
    }
  }

  void _debouncedLoad() {
    _debounceLoadTimer?.cancel();
    _debounceLoadTimer = Timer(const Duration(milliseconds: 800), () {
      _load();
    });
  }

  void _silentLegacyCleanup() {
    Future(
      () => CourseFeedbackService.approveLegacyLessonCommentsGlobally(),
    ).catchError((_) => <String, int>{});
  }

  Future<Map<String, String>> _loadAssignedCourses() async {
    final out = <String, String>{};

    void addCourse({
      required String id,
      String title = '',
      String code = '',
      String fallback = '',
      String thumbnail = '',
    }) {
      final cleanId = id.trim();
      if (cleanId.isEmpty) return;
      final cleanTitle = title.trim();
      final cleanCode = code.trim();
      final cleanFallback = fallback.trim();
      final label = cleanTitle.isEmpty
          ? (cleanCode.isEmpty
                ? (cleanFallback.isEmpty ? cleanId : cleanFallback)
                : cleanCode)
          : (cleanCode.isEmpty ? cleanTitle : '$cleanTitle ($cleanCode)');
      out[cleanId] = label;
      final cleanThumb = thumbnail.trim();
      if (cleanThumb.isNotEmpty) _courseThumbnailById[cleanId] = cleanThumb;
    }

    void addLearnerCandidate(String uid, String courseKeyOrId) {
      final cleanUid = uid.trim();
      final cleanCourse = courseKeyOrId.trim();
      if (cleanUid.isEmpty || cleanCourse.isEmpty) return;
      _assignedCourseKeysByLearnerUid
          .putIfAbsent(cleanUid, () => <String>{})
          .add(cleanCourse);
    }

    bool teacherMatches(dynamic raw) {
      if (raw == null) return false;
      if (raw is String || raw is num || raw is bool) {
        return raw.toString().trim() == _uid;
      }
      if (raw is List) {
        return raw.any(teacherMatches);
      }
      if (raw is Map) {
        final m = raw.map((k, v) => MapEntry(k.toString(), v));
        final uid =
            (m['uid'] ??
                    m['teacherUid'] ??
                    m['teacher_uid'] ??
                    m['teacherId'] ??
                    m['teacher_id'] ??
                    m['instructorUid'] ??
                    m['instructor_uid'])
                .toString()
                .trim();
        if (uid == _uid) return true;
        return m.values.any(teacherMatches);
      }
      return false;
    }

    String labelFromCourseMap(Map<String, dynamic> m, String fallback) {
      final title = (m['title'] ?? m['course_title'] ?? '').toString().trim();
      final code = (m['course_code'] ?? m['courseCode'] ?? '')
          .toString()
          .trim();
      if (title.isEmpty) return code.isEmpty ? fallback : code;
      return code.isEmpty ? title : '$title ($code)';
    }

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

        final id = _extractCourseId(m);
        addCourse(
          id: id,
          title: (m['title'] ?? '').toString(),
          code: (m['course_code'] ?? m['courseCode'] ?? '').toString(),
          thumbnail: (m['thumbnail'] ?? m['thumbnailUrl'] ?? '').toString(),
          fallback: id.isEmpty ? nodeKey : id,
        );
        addCourse(
          id: nodeKey,
          title: (m['title'] ?? '').toString(),
          code: (m['course_code'] ?? m['courseCode'] ?? '').toString(),
          thumbnail: (m['thumbnail'] ?? m['thumbnailUrl'] ?? '').toString(),
          fallback: id.isEmpty ? nodeKey : id,
        );
      }
    }

    final coursesSnap = await _db.child('courses').get();
    if (coursesSnap.exists && coursesSnap.value is Map) {
      final courses = Map<dynamic, dynamic>.from(coursesSnap.value as Map);
      for (final entry in courses.entries) {
        if (entry.value is! Map) continue;
        final courseId = entry.key.toString().trim();
        final m = (entry.value as Map).map((k, v) => MapEntry('$k', v));
        if (!teacherMatches(m['instructors_map']) &&
            !teacherMatches(m['instructors'])) {
          continue;
        }
        addCourse(
          id: courseId,
          title: (m['title'] ?? '').toString(),
          code: (m['course_code'] ?? m['courseCode'] ?? '').toString(),
          thumbnail: (m['thumbnail'] ?? m['thumbnailUrl'] ?? '').toString(),
        );
      }
    }

    final classesSnap = await _db.child('classes').get();
    if (classesSnap.exists && classesSnap.value is Map) {
      final classes = Map<dynamic, dynamic>.from(classesSnap.value as Map);
      for (final entry in classes.entries) {
        if (entry.value is! Map) continue;
        final m = (entry.value as Map).map((k, v) => MapEntry('$k', v));
        if (!teacherMatches(m['instructor_current']) &&
            !teacherMatches(m['teacherUid']) &&
            !teacherMatches(m['teacher_uid']) &&
            !teacherMatches(m['teacherId']) &&
            !teacherMatches(m['teacher_id']) &&
            !teacherMatches(m['instructorUid']) &&
            !teacherMatches(m['instructor_uid'])) {
          continue;
        }

        addCourse(
          id: (m['course_id'] ?? m['courseId'] ?? '').toString(),
          title: (m['course_title'] ?? m['courseTitle'] ?? '').toString(),
        );

        final classCourseId = (m['course_id'] ?? m['courseId'] ?? '')
            .toString()
            .trim();
        final learners = m['learners'];
        if (learners is Map) {
          final learnerMap = Map<dynamic, dynamic>.from(learners);
          for (final learnerEntry in learnerMap.entries) {
            addLearnerCandidate(learnerEntry.key.toString(), classCourseId);
          }
        } else if (learners is List) {
          for (final learner in learners) {
            if (learner is Map) {
              addLearnerCandidate(
                (learner['uid'] ?? '').toString(),
                classCourseId,
              );
            } else {
              addLearnerCandidate(learner.toString(), classCourseId);
            }
          }
        }
      }
    }

    final paymentsSnap = await _db.child('payments').get();
    if (paymentsSnap.exists && paymentsSnap.value is Map) {
      final payments = Map<dynamic, dynamic>.from(paymentsSnap.value as Map);
      for (final entry in payments.entries) {
        if (entry.value is! Map) continue;
        final m = (entry.value as Map).map((k, v) => MapEntry('$k', v));
        if (!teacherMatches(m['teacherId']) &&
            !teacherMatches(m['teacher_id']) &&
            !teacherMatches(m['teacherUid']) &&
            !teacherMatches(m['teacher_uid'])) {
          continue;
        }
        final variant = _extractVariantKey(m);
        if (variant != 'recorded') continue;
        addCourse(
          id: _extractCourseId(m),
          title: (m['courseTitle'] ?? m['course_title'] ?? '').toString(),
        );
        addCourse(
          id: (m['courseKey'] ?? m['course_key'] ?? '').toString(),
          title: (m['courseTitle'] ?? m['course_title'] ?? '').toString(),
        );
        final learnerUid =
            (m['uid'] ??
                    m['learnerUid'] ??
                    m['learner_uid'] ??
                    m['studentUid'] ??
                    m['student_uid'] ??
                    '')
                .toString();
        addLearnerCandidate(learnerUid, _extractCourseId(m));
        addLearnerCandidate(
          learnerUid,
          (m['courseKey'] ?? m['course_key'] ?? '').toString(),
        );
      }
    }

    if (out.isNotEmpty) {
      try {
        final coursesSnap = await _db.child('courses').get();
        if (coursesSnap.exists && coursesSnap.value is Map) {
          final courses = Map<dynamic, dynamic>.from(coursesSnap.value as Map);
          for (final courseId in out.keys.toList()) {
            final raw = courses[courseId];
            if (raw is! Map) continue;
            final m = Map<String, dynamic>.from(raw);
            out[courseId] = labelFromCourseMap(m, out[courseId] ?? courseId);
            final thumb = (m['thumbnail'] ?? m['thumbnailUrl'] ?? '')
                .toString()
                .trim();
            if (thumb.isNotEmpty) _courseThumbnailById[courseId] = thumb;
          }
        }
      } catch (_) {}
    }

    return out;
  }

  String _extractVariantKey(Map<String, dynamic> node) {
    final nestedClass = node['class'];
    final classMap = nestedClass is Map
        ? nestedClass.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};
    return normalizeVariantKey(
      (node['variantKey'] ??
              node['variant_key'] ??
              node['deliveryKey'] ??
              node['delivery_key'] ??
              node['variant'] ??
              classMap['variantKey'] ??
              classMap['variant_key'] ??
              classMap['deliveryKey'] ??
              classMap['delivery_key'] ??
              classMap['variant'] ??
              '')
          .toString(),
    );
  }

  bool _isRecordedLearnerCourse(Map<String, dynamic> course) {
    final variant = _extractVariantKey(course);
    if (variant == 'recorded') return true;
    if (course['recorded_access'] is Map ||
        course['recorded_progress'] is Map) {
      return true;
    }
    return false;
  }

  bool _isClearlyNonLearnerRole(String role) {
    final clean = role.trim().toLowerCase();
    if (clean.isEmpty) return false;
    return clean == 'teacher' ||
        clean == 'teachers' ||
        clean == 'teacher(s)' ||
        clean == 'admin' ||
        clean == 'admins' ||
        clean == 'staff' ||
        clean == 'superadmin' ||
        clean == 'super_admin';
  }

  String _extractCourseId(Map<String, dynamic> course) {
    final nestedClass = course['class'];
    final classMap = nestedClass is Map
        ? nestedClass.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};
    return (course['id'] ??
            course['courseId'] ??
            course['course_id'] ??
            classMap['course_id'] ??
            classMap['courseId'] ??
            '')
        .toString()
        .trim();
  }

  Future<List<_MyPlatformItem>> _loadFeedbackItems(
    Set<String> courseIds,
  ) async {
    if (courseIds.isEmpty) return const [];

    final out = <_MyPlatformItem>[];

    for (final courseId in courseIds) {
      final courseCommentCache = <String, Map<String, String>>{};
      final commentsSnap = await _db
          .child('lesson_comments')
          .child(courseId)
          .get();
      if (!commentsSnap.exists || commentsSnap.value is! Map) {
        _commentCacheByCourse[courseId] = courseCommentCache;
        continue;
      }

      final lessons = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
      for (final lesson in lessons.entries) {
        final lessonId = lesson.key.toString();
        if (lesson.value is! Map) continue;

        final comments = Map<dynamic, dynamic>.from(lesson.value as Map);
        for (final entry in comments.entries) {
          if (entry.value is! Map) continue;
          final m = (entry.value as Map).map((k, v) => MapEntry('$k', v));
          final item = LessonCommentItem.fromMap(entry.key.toString(), m);
          final status = CourseFeedbackService.normalizeLessonCommentStatus(
            item.status,
          );
          if (status == CourseFeedbackService.statusRemoved ||
              status == CourseFeedbackService.statusNotApproved ||
              status == 'hidden') {
            continue;
          }
          final cacheKey = '${lessonId}__${item.uid}';
          courseCommentCache[cacheKey] = {
            'status': status,
            'text': item.text,
            'id': item.id,
          };
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
      _commentCacheByCourse[courseId] = courseCommentCache;
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

          final matUrl = (m['materialsUrl'] ?? '').toString().trim();
          final matHidden = (m['materialsHidden'] ?? false) is bool
              ? (m['materialsHidden'] as bool)
              : (m['materialsHidden'] ?? '').toString().trim().toLowerCase() ==
                    'true';
          out[sessionId] = _RecordedSessionMeta(
            hasVideo: (m['videoUrl'] ?? '').toString().trim().isNotEmpty,
            hasMaterials: matUrl.isNotEmpty && !matHidden,
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
      return videoDone;
    }
    if (meta.hasVideo) return videoDone;
    if (meta.hasMaterials) return materialsDone;
    return false;
  }

  Future<List<_LearnerRecordedProgressItem>> _loadRecordedLearnerProgress({
    required Set<String> assignedCourseKeys,
  }) async {
    final out = <_LearnerRecordedProgressItem>[];

    final users = <String, Map<String, dynamic>>{};
    final usersSnap = await _db.child('users').get();
    if (usersSnap.exists && usersSnap.value is Map) {
      final rawUsers = Map<dynamic, dynamic>.from(usersSnap.value as Map);
      for (final entry in rawUsers.entries) {
        if (entry.value is Map) {
          users[entry.key.toString()] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
    }
    if (users.isEmpty) return out;

    for (final userEntry in users.entries) {
      final learnerUid = userEntry.key.toString().trim();
      if (learnerUid.isEmpty) continue;

      final user = userEntry.value;
      if (_isClearlyNonLearnerRole((user['role'] ?? '').toString())) continue;

      final first = (user['first_name'] ?? '').toString().trim();
      final last = (user['last_name'] ?? '').toString().trim();
      final email = (user['email'] ?? '').toString().trim();
      final fullName = '$first $last'.trim();
      final learnerName = fullName.isNotEmpty
          ? fullName
          : (email.isNotEmpty ? email : 'Learner');
      final photoUrl = ProfileAvatar.resolvePhotoFromMap(user);

      final coursesRaw = user['courses'];
      if (coursesRaw is! Map) continue;
      final courses = Map<dynamic, dynamic>.from(coursesRaw);

      for (final cEntry in courses.entries) {
        final courseKey = cEntry.key.toString().trim();
        if (courseKey.isEmpty || cEntry.value is! Map) continue;

        final course = Map<String, dynamic>.from(cEntry.value as Map);
        if (!_isRecordedLearnerCourse(course)) continue;

        final courseId = _extractCourseId(course);
        if (courseId.isEmpty) continue;

        final candidateCourses = _assignedCourseKeysByLearnerUid[learnerUid];
        if (candidateCourses != null &&
            candidateCourses.isNotEmpty &&
            !candidateCourses.contains(courseId) &&
            !candidateCourses.contains(courseKey)) {
          continue;
        }

        if (assignedCourseKeys.isNotEmpty &&
            !assignedCourseKeys.contains(courseId) &&
            !assignedCourseKeys.contains(courseKey)) {
          continue;
        }

        final courseTitle = (course['title'] ?? '').toString().trim().isNotEmpty
            ? (course['title'] ?? '').toString().trim()
            : _courseLabelById[courseId] ??
                  _courseLabelById[courseKey] ??
                  (courseId.isNotEmpty ? courseId : 'Recorded course');

        final progressRaw = course['recorded_progress'];
        final progressMap = progressRaw is Map
            ? progressRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final sessionMeta = await _loadRecordedSessionMeta(courseId);

        int totalSessions = sessionMeta.length;
        int completedSessions = 0;

        final courseCommentCache = _commentCacheByCourse[courseId];
        if (sessionMeta.isNotEmpty) {
          for (final sessionEntry in sessionMeta.entries) {
            final raw = progressMap[sessionEntry.key];
            if (raw is! Map) continue;
            final progress = raw.map((k, v) => MapEntry('$k', v));
            if (!_isRecordedSessionDone(
              meta: sessionEntry.value,
              progress: progress,
            )) {
              continue;
            }
            final cacheKey = '${sessionEntry.key}__$learnerUid';
            final cached = courseCommentCache?[cacheKey];
            final status = cached != null
                ? CourseFeedbackService.normalizeLessonCommentStatus(
                    cached['status'],
                  )
                : null;
            if (status == CourseFeedbackService.statusVisible) {
              completedSessions += 1;
            }
          }
        } else if (progressMap.isNotEmpty) {
          totalSessions = progressMap.length;
          for (final raw in progressMap.values) {
            if (raw is! Map) continue;
            final progress = raw.map((k, v) => MapEntry('$k', v));
            final videoDone = _asBool(progress['videoCompleted']);
            final materialsDone = _asBool(progress['materialsCompleted']);
            if ((videoDone ||
                    (!progress.containsKey('videoCompleted') &&
                        materialsDone)) &&
                courseCommentCache != null) {
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
            photoUrl: photoUrl,
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

  int _asInt(dynamic v) => CourseFeedbackService.asInt(v);

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

    final commentDataByLesson = <String, Map<String, String>>{};
    final cachedCourseComments = _commentCacheByCourse[courseId];
    if (cachedCourseComments != null) {
      cachedCourseComments.forEach((key, value) {
        final parts = key.split('__');
        if (parts.length != 2 || parts[1] != learnerUid) return;
        commentDataByLesson[parts[0]] = value;
      });
    } else {
      final commentsSnap = await _db
          .child('lesson_comments')
          .child(courseId)
          .get();
      if (commentsSnap.exists && commentsSnap.value is Map) {
        final lessons = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
        for (final lessonEntry in lessons.entries) {
          final lessonId = lessonEntry.key.toString();
          if (lessonEntry.value is! Map) continue;
          final comments = Map<dynamic, dynamic>.from(lessonEntry.value as Map);
          for (final commentEntry in comments.entries) {
            if (commentEntry.value is! Map) continue;
            final m = Map<dynamic, dynamic>.from(commentEntry.value as Map);
            final status = CourseFeedbackService.normalizeLessonCommentStatus(
              m['status'],
            );
            if (status == CourseFeedbackService.statusRemoved ||
                status == 'hidden') {
              continue;
            }
            if ((m['uid'] ?? '').toString().trim() == learnerUid) {
              commentDataByLesson[lessonId] = {
                'status': status,
                'text': (m['text'] ?? '').toString(),
                'id': commentEntry.key.toString(),
              };
            }
          }
        }
      }
    }

    final sessionItems = <Map<String, dynamic>>[];
    if (syllabusSnap.exists && syllabusSnap.value is Map) {
      final root = Map<String, dynamic>.from(syllabusSnap.value as Map);
      final rawModules = _asListOfMaps(root['modules']);
      if (rawModules.isNotEmpty) {
        for (int mi = 0; mi < rawModules.length; mi++) {
          final module = rawModules[mi];
          final moduleOrder = _asInt(module['order']) > 0
              ? _asInt(module['order'])
              : (mi + 1);
          final moduleLabel =
              (module['otherTitle'] ?? '').toString().trim().isNotEmpty
              ? (module['otherTitle'] ?? '').toString().trim()
              : ((module['title'] ?? '').toString().trim().isNotEmpty
                    ? (module['title'] ?? '').toString().trim()
                    : 'M${mi + 1}');
          final rawUnits = _asListOfMaps(module['units']);
          for (int ui = 0; ui < rawUnits.length; ui++) {
            final unit = rawUnits[ui];
            final unitOrder = _asInt(unit['order']) > 0
                ? _asInt(unit['order'])
                : (ui + 1);
            final unitTitle = (unit['title'] ?? '').toString().trim();
            final rawLessons = _asListOfMaps(unit['lessons']);
            for (int li = 0; li < rawLessons.length; li++) {
              final lesson = rawLessons[li];
              sessionItems.add({
                'moduleTitle': moduleLabel,
                'moduleOrder': moduleOrder,
                'unitTitle': unitTitle,
                'unitOrder': unitOrder,
                'lessonOrder': _asInt(lesson['order']) > 0
                    ? _asInt(lesson['order'])
                    : (li + 1),
                ...lesson,
              });
            }
          }
        }
      } else {
        final rawUnits = _asListOfMaps(root['units']);
        for (int ui = 0; ui < rawUnits.length; ui++) {
          final unit = rawUnits[ui];
          final unitOrder = _asInt(unit['order']) > 0
              ? _asInt(unit['order'])
              : (ui + 1);
          final unitTitle = (unit['title'] ?? '').toString().trim();
          final rawSessions = _asListOfMaps(unit['sessions']);
          for (int si = 0; si < rawSessions.length; si++) {
            final session = rawSessions[si];
            sessionItems.add({
              'moduleTitle': '',
              'moduleOrder': 1,
              'unitTitle': unitTitle,
              'unitOrder': unitOrder,
              'lessonOrder': _asInt(session['order']) > 0
                  ? _asInt(session['order'])
                  : (si + 1),
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

    sessionItems.sort((a, b) {
      final moduleCmp = _asInt(
        a['moduleOrder'],
      ).compareTo(_asInt(b['moduleOrder']));
      if (moduleCmp != 0) return moduleCmp;
      final unitCmp = _asInt(a['unitOrder']).compareTo(_asInt(b['unitOrder']));
      if (unitCmp != 0) return unitCmp;
      final lessonCmp = _asInt(
        a['lessonOrder'],
      ).compareTo(_asInt(b['lessonOrder']));
      if (lessonCmp != 0) return lessonCmp;
      return orderOf(a).compareTo(orderOf(b));
    });

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

      final cd = commentDataByLesson[sessionId];
      final detail = _RecordedLessonDetail(
        lessonId: sessionId,
        title: title,
        unitTitle: unitTitle,
        moduleTitle: moduleTitle,
        moduleOrder: _asInt(session['moduleOrder']),
        unitOrder: _asInt(session['unitOrder']),
        lessonOrder: _asInt(session['lessonOrder']),
        hasVideo: hasVideo,
        hasMaterials: hasMaterials,
        videoDone: videoDone,
        materialsDone: materialsDone,
        commentStatus: cd?['status'],
        commentText: cd?['text'],
        commentId: cd?['id'],
      );

      if (detail.isDone) {
        studied.add(detail);
      } else {
        left.add(detail);
      }
    }

    return _RecordedLearnerDetails(studied: studied, left: left);
  }

  String _courseLabel(String id) => _courseLabelById[id] ?? id;

  String _threadIdFor(String a, String b, String scope) {
    final ids = [a.trim(), b.trim()]..sort();
    return 'support_${scope}_${ids[0]}_${ids[1]}';
  }

  Future<void> _openLearnerProfile(_LearnerRecordedProgressItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeacherLearnerProfileScreen(
          learnerUid: item.learnerUid,
          learnerName: item.learnerName,
          initialCourseTitle: item.courseTitle,
        ),
      ),
    );
  }

  Future<void> _openLearnerMail(_LearnerRecordedProgressItem item) async {
    final meUid = _uid;
    if (meUid.isEmpty || item.learnerUid.trim().isEmpty) return;

    final subject = 'Course support: ${item.courseTitle}';
    final threadId = _threadIdFor(meUid, item.learnerUid, item.courseId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final threadRef = _db.child('mail_threads').child(threadId);
    final snap = await threadRef.get();
    if (!snap.exists) {
      await threadRef.set({
        'participants': {meUid: true, item.learnerUid: true},
        'subject': subject,
        'type': 'mail',
        'createdAt': now,
        'updatedAt': now,
        'lastMessage':
            'Hi ${item.learnerName}, I wanted to help with your progress.',
        'lastMessageAt': now,
      });
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeacherMailThreadScreen(
          threadId: threadId,
          peerUid: item.learnerUid,
          peerName: item.learnerName,
          subject: subject,
        ),
      ),
    );
  }

  Future<void> _openLearnerReminder(_LearnerRecordedProgressItem item) async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const TeacherReminderScreen()));
  }

  Future<void> _resetLearnerRecordedCourse(
    _LearnerRecordedProgressItem item,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset learner course?'),
        content: Text(
          'This will clear ${item.learnerName}\'s recorded progress for ${item.courseTitle} and archive/remove their active reflections for this course. The learner will start fresh.',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final teacher = FirebaseAuth.instance.currentUser;
      final result = await CourseFeedbackService.resetRecordedCourseForLearner(
        learnerUid: item.learnerUid,
        courseId: item.courseId,
        courseKey: item.courseKey,
        actorUid: teacher?.uid ?? _uid,
        actorName: teacher?.displayName ?? 'Teacher',
      );
      if (!mounted) return;
      AppToast.show(
        context,
        'Progress reset. Archived ${result['archivedComments'] ?? 0} reflections.',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, toHumanError(e), type: AppToastType.error);
    }
  }

  void _showLearnerActions(_LearnerRecordedProgressItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ProfileAvatar(
                    name: item.learnerName,
                    photoUrl: item.photoUrl,
                    radius: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.learnerName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0F2FE),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${item.progressPct}%',
                      style: const TextStyle(
                        color: Color(0xFF0369A1),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _sheetAction(
                icon: Icons.person_outline_rounded,
                title: 'Open profile',
                subtitle: 'View learner profile and history',
                color: const Color(0xFF2563EB),
                onTap: () {
                  Navigator.pop(ctx);
                  _openLearnerProfile(item);
                },
              ),
              _sheetAction(
                icon: Icons.mail_outline_rounded,
                title: 'Send message',
                subtitle: 'Open teacher mail thread',
                color: const Color(0xFF7C3AED),
                onTap: () {
                  Navigator.pop(ctx);
                  _openLearnerMail(item);
                },
              ),
              _sheetAction(
                icon: Icons.alarm_rounded,
                title: 'Send reminder',
                subtitle: 'Open reminder center',
                color: const Color(0xFFF97316),
                onTap: () {
                  Navigator.pop(ctx);
                  _openLearnerReminder(item);
                },
              ),
              _sheetAction(
                icon: Icons.restart_alt_rounded,
                title: 'Clean up',
                subtitle: 'Clear corrupted progress and start fresh',
                color: const Color(0xFFB91C1C),
                onTap: () {
                  Navigator.pop(ctx);
                  _resetLearnerRecordedCourse(item);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }

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
      final status = CourseFeedbackService.normalizeLessonCommentStatus(
        item.status,
      );
      commentCounts[item.courseId] = (commentCounts[item.courseId] ?? 0) + 1;
      learnerSets.putIfAbsent(item.courseId, () => <String>{}).add(item.uid);
      if (status == CourseFeedbackService.statusPending) {
        pendingCounts[item.courseId] = (pendingCounts[item.courseId] ?? 0) + 1;
      }
      if (item.reportCount > 0 &&
          status != CourseFeedbackService.statusRemoved) {
        reportedCounts[item.courseId] =
            (reportedCounts[item.courseId] ?? 0) + 1;
      }
      if (status == 'hidden' || status == CourseFeedbackService.statusRemoved) {
        hiddenCounts[item.courseId] = (hiddenCounts[item.courseId] ?? 0) + 1;
      }
      final prev = lastCommentAt[item.courseId] ?? 0;
      if (item.createdAt > prev) lastCommentAt[item.courseId] = item.createdAt;
    }

    final courseIds =
        <String>{
            ..._assignedCourseIds,
            ...learnerSets.keys,
            ...commentCounts.keys,
          }.where((courseId) {
            if (courseId.trim().isEmpty) return false;
            if (_assignedCourseIds.isEmpty) return true;
            return _assignedCourseIds.contains(courseId) ||
                learnerSets.containsKey(courseId) ||
                commentCounts.containsKey(courseId);
          }).toList()
          ..sort();
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

  void _openRecordedCourseComments(
    _RecordedCourseSummary course, {
    bool pendingFirst = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeacherRecordedCourseCommentsScreen(
          courseId: course.courseId,
          courseTitle: course.courseTitle,
          courseCode: course.courseCode,
          initialFilterPending: pendingFirst,
        ),
      ),
    );
  }

  int _pendingReflectionCountForLearner(_LearnerRecordedProgressItem learner) {
    final comments = _commentCacheByCourse[learner.courseId];
    if (comments == null) return 0;
    var count = 0;
    comments.forEach((key, value) {
      if (!key.endsWith('__${learner.learnerUid}')) return;
      if (value['status'] == CourseFeedbackService.statusPending) count += 1;
    });
    return count;
  }

  List<_LearnerRecordedProgressItem> _learnersForCourse(
    String courseId,
    String search,
  ) {
    final q = search.trim().toLowerCase();
    final out = <_LearnerRecordedProgressItem>[];
    final seen = <String>{};

    for (final row in _learnerProgressRows) {
      if (row.courseId != courseId && row.courseKey != courseId) continue;
      if (q.isNotEmpty &&
          !row.learnerName.toLowerCase().contains(q) &&
          !row.courseTitle.toLowerCase().contains(q)) {
        continue;
      }
      out.add(row);
      seen.add(row.learnerUid);
    }

    for (final item in _all) {
      if (item.courseId != courseId || seen.contains(item.uid)) continue;
      final name = item.displayName.trim().isEmpty
          ? (item.firstName.trim().isEmpty ? 'Learner' : item.firstName.trim())
          : item.displayName.trim();
      if (q.isNotEmpty && !name.toLowerCase().contains(q)) continue;
      out.add(
        _LearnerRecordedProgressItem(
          learnerUid: item.uid,
          learnerName: name,
          photoUrl: item.photoUrl,
          courseKey: courseId,
          courseId: courseId,
          courseTitle: _courseLabel(courseId),
          completedSessions: 0,
          totalSessions: 0,
          progressPct: 0,
        ),
      );
      seen.add(item.uid);
    }

    out.sort((a, b) {
      final pendingCmp = _pendingReflectionCountForLearner(
        b,
      ).compareTo(_pendingReflectionCountForLearner(a));
      if (pendingCmp != 0) return pendingCmp;
      final progressCmp = a.progressPct.compareTo(b.progressPct);
      if (progressCmp != 0) return progressCmp;
      return a.learnerName.toLowerCase().compareTo(b.learnerName.toLowerCase());
    });
    return out;
  }

  Widget _courseThumbnail(String courseId, Color accent) {
    final url = (_courseThumbnailById[courseId] ?? '').trim();
    if (url.isEmpty) {
      return Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.video_library_rounded, color: accent, size: 26),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.network(
        url,
        width: 62,
        height: 62,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: 62,
          height: 62,
          color: accent.withValues(alpha: 0.14),
          child: Icon(Icons.video_library_rounded, color: accent),
        ),
      ),
    );
  }

  Widget _buildRecordedCoursesBody() {
    final summaries =
        _recordedCourseSummaries
            .where(
              (course) => course.learnerCount > 0 || course.commentCount > 0,
            )
            .toList()
          ..sort((a, b) {
            var cmp = b.pendingCommentCount.compareTo(a.pendingCommentCount);
            if (cmp != 0) return cmp;
            cmp = b.reportedCommentCount.compareTo(a.reportedCommentCount);
            if (cmp != 0) return cmp;
            cmp = b.latestCommentAt.compareTo(a.latestCommentAt);
            if (cmp != 0) return cmp;
            return a.courseTitle.toLowerCase().compareTo(
              b.courseTitle.toLowerCase(),
            );
          });

    if (summaries.isEmpty) {
      return const Center(child: Text('No reflections need review right now.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: summaries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final course = summaries[index];
        final accent = _courseAccent(course.courseId);

        final expanded = _expandedCourseIds.contains(course.courseId);
        final search = _learnerSearchByCourse[course.courseId] ?? '';
        final learners = _learnersForCourse(course.courseId, search);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              setState(() {
                if (expanded) {
                  _expandedCourseIds.remove(course.courseId);
                } else {
                  _expandedCourseIds.add(course.courseId);
                }
              });
            },
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
                      _courseThumbnail(course.courseId, accent),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: course.pendingCommentCount > 0
                              ? const Color(0xFFFEF3C7)
                              : const Color(0xFFD1FAE5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          course.pendingCommentCount > 0
                              ? '${course.pendingCommentCount} pending'
                              : 'All caught up',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                            color: course.pendingCommentCount > 0
                                ? const Color(0xFF92400E)
                                : const Color(0xFF047857),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: const Color(0xFF64748B),
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
                        'Total',
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
                        'Completed learners',
                        course.completedLearnerCount,
                        const Color(0xFFD1FAE5),
                        const Color(0xFF047857),
                      ),
                    ],
                  ),
                  if (expanded) ...[
                    const SizedBox(height: 12),
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search learners',
                        prefixIcon: const Icon(Icons.search_rounded),
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(
                            color: Color(0xFFE2E8F0),
                          ),
                        ),
                      ),
                      onChanged: (value) => setState(() {
                        _learnerSearchByCourse[course.courseId] = value;
                      }),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 620),
                      child: learners.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: Text('No learners found for this course.'),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: learners.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, learnerIndex) {
                                final learner = learners[learnerIndex];
                                final pending =
                                    _pendingReflectionCountForLearner(learner);
                                return _expandedCourseLearnerTile(
                                  learner,
                                  pending,
                                  accent,
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => _openRecordedCourseComments(course),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open Course Reflection'),
                    ),
                    SizedBox(height: MediaQuery.of(context).padding.bottom),
                  ],
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

  Widget _expandedCourseLearnerTile(
    _LearnerRecordedProgressItem learner,
    int pendingCount,
    Color accent,
  ) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pendingCount > 0
            ? const Color(0xFFFFFBEB)
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: pendingCount > 0
              ? const Color(0xFFFDE68A)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () => _showLearnerActions(learner),
            borderRadius: BorderRadius.circular(999),
            child: ProfileAvatar(
              name: learner.learnerName,
              photoUrl: learner.photoUrl,
              radius: 18,
              borderColor: const Color(0xFFE0E7FF),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  learner.learnerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w900,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${learner.completedSessions}/${learner.totalSessions} lessons • ${learner.progressPct}%',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          if (pendingCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$pendingCount pending',
                style: const TextStyle(
                  color: Color(0xFF92400E),
                  fontWeight: FontWeight.w900,
                  fontSize: 10.5,
                ),
              ),
            ),
          IconButton(
            tooltip: 'View lessons',
            onPressed: () => _openLearnerProgressPopup(learner),
            icon: Icon(Icons.account_tree_rounded, color: accent),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _mainTabChip({
    required String label,
    required IconData icon,
    required bool selected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? accent : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? accent : accent.withValues(alpha: 0.22),
              width: selected ? 0 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : const [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? Colors.white : accent),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13.5,
                  color: selected ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
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

    final overallPct = totalSessions > 0
        ? (totalCompleted / totalSessions * 100).round()
        : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF0EA5A4), Color(0xFF059669)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0EA5A4).withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.groups_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_learnerProgressRows.length} learners',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$totalCompleted / $totalSessions lessons completed ($overallPct%)',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            itemCount: _learnerProgressRows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final item = _learnerProgressRows[i];
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
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0F172A).withValues(alpha: 0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        InkWell(
                          onTap: () => _showLearnerActions(item),
                          borderRadius: BorderRadius.circular(999),
                          child: ProfileAvatar(
                            name: item.learnerName,
                            photoUrl: item.photoUrl,
                            radius: 18,
                            borderColor: const Color(0xFFE0E7FF),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
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
                                        fontSize: 14.5,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE0F2FE),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '${item.progressPct}%',
                                      style: const TextStyle(
                                        color: Color(0xFF0369A1),
                                        fontWeight: FontWeight.w900,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Course: ${item.courseTitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF475569),
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          splashRadius: 16,
                          tooltip: 'View progress',
                          icon: const Icon(
                            Icons.open_in_new_rounded,
                            color: Color(0xFF334155),
                          ),
                          onPressed: () => _openLearnerProgressPopup(item),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: 0, end: progress),
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) {
                          return Container(
                            height: 7,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE2E8F0),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: value.clamp(0.0, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF14B8A6),
                                      Color(0xFF0EA5A4),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openLearnerProgressPopup(
    _LearnerRecordedProgressItem item,
  ) async {
    final rowKey = _recordedRowKey(item);
    var future = _recordedDetailsFutureByRow[rowKey] ??=
        _loadRecordedLearnerDetails(item);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFFF8FAFC),
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> refreshDetails() async {
              final fresh = _loadRecordedLearnerDetails(item);
              _recordedDetailsFutureByRow[rowKey] = fresh;
              setModalState(() => future = fresh);
              await fresh;
            }

            return SizedBox(
              height: media.size.height * 0.88,
              child: FutureBuilder<_RecordedLearnerDetails>(
                future: future,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const Center(
                      child: Text(
                        'Could not load lesson details.',
                        style: TextStyle(
                          color: Color(0xFFB91C1C),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return _buildLearnerProgressPopup(
                    item,
                    snap.data!,
                    onDetailsChanged: refreshDetails,
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLearnerProgressPopup(
    _LearnerRecordedProgressItem learner,
    _RecordedLearnerDetails details, {
    required Future<void> Function() onDetailsChanged,
  }) {
    final lessons = <_RecordedLessonDetail>[...details.left, ...details.studied]
      ..sort((a, b) {
        final moduleCmp = a.moduleOrder.compareTo(b.moduleOrder);
        if (moduleCmp != 0) return moduleCmp;
        final unitCmp = a.unitOrder.compareTo(b.unitOrder);
        if (unitCmp != 0) return unitCmp;
        return a.lessonOrder.compareTo(b.lessonOrder);
      });
    final byModule = <String, Map<String, List<_RecordedLessonDetail>>>{};
    for (final lesson in lessons) {
      final module = lesson.moduleTitle.trim().isEmpty
          ? 'Module'
          : lesson.moduleTitle.trim();
      final unit = lesson.unitTitle.trim().isEmpty
          ? 'Unit'
          : lesson.unitTitle.trim();
      byModule
          .putIfAbsent(module, () => <String, List<_RecordedLessonDetail>>{})
          .putIfAbsent(unit, () => <_RecordedLessonDetail>[])
          .add(lesson);
    }

    final progress = learner.totalSessions > 0
        ? learner.completedSessions / learner.totalSessions
        : 0.0;
    final selectedUnitByModule = <String, String>{
      for (final entry in byModule.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.keys.first,
    };

    return StatefulBuilder(
      builder: (context, setSheetState) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0F766E), Color(0xFF2563EB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  ProfileAvatar(
                    name: learner.learnerName,
                    photoUrl: learner.photoUrl,
                    radius: 24,
                    borderColor: Colors.white,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          learner.learnerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 17,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          learner.courseTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.86),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            minHeight: 7,
                            value: progress.clamp(0.0, 1.0),
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.24,
                            ),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFFA7F3D0),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${learner.completedSessions}/${learner.totalSessions}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: byModule.isEmpty
                  ? const Center(child: Text('No recorded lessons found.'))
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        0,
                        16,
                        18 + MediaQuery.of(context).padding.bottom,
                      ),
                      itemCount: byModule.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final moduleEntry = byModule.entries.elementAt(index);
                        final moduleTitle = moduleEntry.key;
                        final units = moduleEntry.value;
                        final selectedUnit = selectedUnitByModule[moduleTitle];
                        final unitLessons =
                            units[selectedUnit] ??
                            (units.isEmpty
                                ? const <_RecordedLessonDetail>[]
                                : units.values.first);
                        final moduleLessons = units.values
                            .expand((items) => items)
                            .toList(growable: false);
                        final done = moduleLessons
                            .where((e) => e.isDone)
                            .length;

                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF0F172A,
                                ).withValues(alpha: 0.04),
                                blurRadius: 14,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      moduleTitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 15,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$done/${moduleLessons.length} lessons',
                                    style: const TextStyle(
                                      color: Color(0xFF64748B),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 56,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: units.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 8),
                                  itemBuilder: (context, unitIndex) {
                                    final unitEntry = units.entries.elementAt(
                                      unitIndex,
                                    );
                                    final isSelected =
                                        unitEntry.key == selectedUnit;
                                    final unitDone = unitEntry.value
                                        .where((lesson) => lesson.isDone)
                                        .length;
                                    return InkWell(
                                      borderRadius: BorderRadius.circular(13),
                                      onTap: () {
                                        setSheetState(() {
                                          selectedUnitByModule[moduleTitle] =
                                              unitEntry.key;
                                        });
                                      },
                                      child: Container(
                                        constraints: const BoxConstraints(
                                          minWidth: 108,
                                          maxWidth: 220,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? const Color(0xFFEEF2FF)
                                              : const Color(0xFFF8FAFC),
                                          borderRadius: BorderRadius.circular(
                                            13,
                                          ),
                                          border: Border.all(
                                            color: isSelected
                                                ? const Color(0xFF4F46E5)
                                                : const Color(0xFFE2E8F0),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              unitDone == unitEntry.value.length
                                                  ? Icons.check_circle_rounded
                                                  : Icons
                                                        .radio_button_unchecked_rounded,
                                              size: 15,
                                              color:
                                                  unitDone ==
                                                      unitEntry.value.length
                                                  ? const Color(0xFF16A34A)
                                                  : const Color(0xFF64748B),
                                            ),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                unitEntry.key,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: const Color(
                                                    0xFF1E293B,
                                                  ),
                                                  fontWeight: isSelected
                                                      ? FontWeight.w900
                                                      : FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 10),
                              for (final lesson in unitLessons)
                                _popupLessonRow(
                                  lesson,
                                  learner,
                                  onDetailsChanged,
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _popupLessonRow(
    _RecordedLessonDetail lesson,
    _LearnerRecordedProgressItem learner,
    Future<void> Function() onDetailsChanged,
  ) {
    final done = lesson.isDone;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: done ? const Color(0xFFF0FDF4) : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: done ? const Color(0xFFBBF7D0) : const Color(0xFFFDE68A),
        ),
      ),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle_rounded : Icons.pending_actions_rounded,
            color: done ? const Color(0xFF16A34A) : const Color(0xFFD97706),
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lesson.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (lesson.hasVideo)
                      lesson.videoDone ? 'Video done' : 'Video left',
                    if (lesson.hasMaterials)
                      lesson.materialsDone
                          ? 'Materials done'
                          : 'Materials left',
                  ].join(' • '),
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          _commentStatusIcon(lesson, learner, onDetailsChanged),
        ],
      ),
    );
  }

  Widget _commentStatusIcon(
    _RecordedLessonDetail item,
    _LearnerRecordedProgressItem learnerItem,
    Future<void> Function() onDetailsChanged,
  ) {
    final status = _normalizedReflectionStatus(item.commentStatus);
    IconData icon;
    Color color;
    Color bgColor;
    String tooltip;

    if (status == null) {
      icon = Icons.chat_bubble_outline_rounded;
      color = const Color(0xFFCBD5E1);
      bgColor = const Color(0xFFF1F5F9);
      tooltip = 'No reflection written';
    } else if (status == CourseFeedbackService.statusVisible) {
      icon = Icons.check_circle_rounded;
      color = const Color(0xFF2563EB);
      bgColor = const Color(0xFFDBEAFE);
      tooltip = 'Reflection approved';
    } else if (status == CourseFeedbackService.statusNotApproved) {
      icon = Icons.cancel_rounded;
      color = const Color(0xFFDC2626);
      bgColor = const Color(0xFFFEE2E2);
      tooltip = 'Reflection not approved';
    } else {
      icon = Icons.hourglass_bottom_rounded;
      color = const Color(0xFFD97706);
      bgColor = const Color(0xFFFEF3C7);
      tooltip = 'Reflection pending review';
    }

    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: () => _showCommentModerationSheet(
              item,
              learnerItem,
              onDetailsChanged,
            ),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(icon, size: 18, color: color),
            ),
          ),
        ),
      ),
    );
  }

  String? _normalizedReflectionStatus(String? raw) {
    final rawStatus = (raw ?? '').trim();
    if (rawStatus.isEmpty) return null;
    final status = CourseFeedbackService.normalizeLessonCommentStatus(
      rawStatus,
    );
    if (status == CourseFeedbackService.statusRemoved || status == 'hidden') {
      return null;
    }
    return status;
  }

  Future<void> _moderateComment({
    required _RecordedLessonDetail lesson,
    required _LearnerRecordedProgressItem learner,
    required bool approve,
  }) async {
    final commentId = lesson.commentId;
    if (commentId == null || commentId.isEmpty) return;

    if (approve) {
      await CourseFeedbackService.moderateLessonComment(
        courseId: learner.courseId,
        lessonId: lesson.lessonId,
        commentId: commentId,
        status: CourseFeedbackService.statusVisible,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Reflection approved.')));
      }
    } else {
      final teacher = FirebaseAuth.instance.currentUser;
      final teacherName = teacher?.displayName ?? 'Teacher';
      final teacherUid = teacher?.uid ?? _uid;
      final contextBits = <String>[];
      if (lesson.moduleTitle.isNotEmpty) contextBits.add(lesson.moduleTitle);
      if (lesson.unitTitle.isNotEmpty) contextBits.add(lesson.unitTitle);
      final lessonPath = contextBits.isEmpty
          ? lesson.title
          : '${contextBits.join(' / ')} / ${lesson.title}';

      await CourseFeedbackService.archiveAndDeleteLessonComment(
        courseId: learner.courseId,
        lessonId: lesson.lessonId,
        commentId: commentId,
        actorUid: teacherUid,
        actorName: teacherName,
        reason: 'not_approved',
        context: <String, dynamic>{
          'learnerUid': learner.learnerUid,
          'learnerName': learner.learnerName,
          'courseTitle': learner.courseTitle,
          'moduleTitle': lesson.moduleTitle,
          'unitTitle': lesson.unitTitle,
          'lessonTitle': lesson.title,
        },
      );

      try {
        await InternalMailService.sendAutoMail(
          senderUid: teacherUid,
          senderName: teacherName,
          senderRole: 'teacher',
          receiverUid: learner.learnerUid,
          receiverName: learner.learnerName,
          receiverRole: 'learner',
          subject: 'Learning Reflection Needs Improvement',
          body:
              '$lessonPath\n\n'
              'Dear ${learner.learnerName},\n\n'
              'Thank you for writing your learning reflection.\n\n'
              'It appears that your reflection does not fully align with the lesson topic. '
              'Please watch the lesson carefully and submit a revised reflection.\n\n'
              'A thoughtful reflection helps you get the most out of your learning journey.\n\n'
              'Best regards,\n$teacherName',
        );
      } catch (_) {
        // Mail sending is best-effort
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Reflection rejected, removed, and learner notified.',
            ),
          ),
        );
      }
    }

    // Refresh the learner details so the icon updates
    final rowKey = _recordedRowKey(learner);
    if (mounted) {
      setState(() {
        final cacheKey = '${lesson.lessonId}__${learner.learnerUid}';
        if (approve) {
          _commentCacheByCourse[learner.courseId]?[cacheKey]?['status'] =
              CourseFeedbackService.statusVisible;
        } else {
          _commentCacheByCourse[learner.courseId]?[cacheKey]?['status'] =
              CourseFeedbackService.statusNotApproved;
        }
        _all = _all
            .map((item) {
              if (item.courseId != learner.courseId ||
                  item.lessonId != lesson.lessonId ||
                  item.entryId != commentId) {
                return item;
              }
              if (!approve) return null;
              return _MyPlatformItem(
                courseId: item.courseId,
                lessonId: item.lessonId,
                entryId: item.entryId,
                uid: item.uid,
                firstName: item.firstName,
                displayName: item.displayName,
                photoUrl: item.photoUrl,
                abbr: item.abbr,
                text: item.text,
                status: CourseFeedbackService.statusVisible,
                reportCount: item.reportCount,
                createdAt: item.createdAt,
              );
            })
            .whereType<_MyPlatformItem>()
            .toList();
        _recordedDetailsFutureByRow[rowKey] = _loadRecordedLearnerDetails(
          learner,
        );
      });
    }
  }

  Future<void> _moderateCommentWithProgress({
    required _RecordedLessonDetail lesson,
    required _LearnerRecordedProgressItem learner,
    required bool approve,
    required Future<void> Function() onDetailsChanged,
  }) async {
    if (!mounted) return;
    final message = approve
        ? 'Approving reflection...'
        : 'Marking reflection for revision...';
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      await _moderateComment(
        lesson: lesson,
        learner: learner,
        approve: approve,
      );
      await onDetailsChanged();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update reflection: $e')),
        );
      }
    } finally {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  void _showCommentModerationSheet(
    _RecordedLessonDetail lesson,
    _LearnerRecordedProgressItem learner,
    Future<void> Function() onDetailsChanged,
  ) {
    final status = _normalizedReflectionStatus(lesson.commentStatus);
    final hasComment = status != null;
    final isApproved = status == CourseFeedbackService.statusVisible;
    final isRejected = status == CourseFeedbackService.statusNotApproved;
    final isRemoved = status == CourseFeedbackService.statusRemoved;
    final canModerate = hasComment && !isRemoved;

    final contextBits = <String>[];
    if (lesson.moduleTitle.isNotEmpty) contextBits.add(lesson.moduleTitle);
    if (lesson.unitTitle.isNotEmpty) contextBits.add(lesson.unitTitle);

    String statusLabel;
    Color statusColor;
    if (!hasComment) {
      statusLabel = 'No reflection yet';
      statusColor = const Color(0xFF64748B);
    } else if (isApproved) {
      statusLabel = 'Approved';
      statusColor = const Color(0xFF2563EB);
    } else if (isRejected) {
      statusLabel = 'Not approved';
      statusColor = const Color(0xFFDC2626);
    } else if (isRemoved) {
      statusLabel = 'Removed';
      statusColor = const Color(0xFF64748B);
    } else if (status == 'hidden') {
      statusLabel = 'Hidden';
      statusColor = const Color(0xFF64748B);
    } else {
      statusLabel = 'Pending review';
      statusColor = const Color(0xFFD97706);
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                8,
                20,
                24 + MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              lesson.title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            if (contextBits.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                contextBits.join(' • '),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (hasComment) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        lesson.commentText ?? '',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1E293B),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                  if (!hasComment) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'This learner has not written a learning reflection for this lesson yet.',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                  if (canModerate) ...[
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        if (!isApproved)
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () async {
                                if (ctx.mounted) Navigator.pop(ctx);
                                await _moderateCommentWithProgress(
                                  lesson: lesson,
                                  learner: learner,
                                  approve: true,
                                  onDetailsChanged: onDetailsChanged,
                                );
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(
                                Icons.check_circle_rounded,
                                size: 18,
                              ),
                              label: const Text(
                                'Approve',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        if (!isApproved && !isRejected)
                          const SizedBox(width: 10),
                        if (!isRejected)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                if (ctx.mounted) Navigator.pop(ctx);
                                await _moderateCommentWithProgress(
                                  lesson: lesson,
                                  learner: learner,
                                  approve: false,
                                  onDetailsChanged: onDetailsChanged,
                                );
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFDC2626),
                                side: const BorderSide(
                                  color: Color(0xFFFECACA),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(
                                Icons.error_outline_rounded,
                                size: 18,
                              ),
                              label: const Text(
                                'Not approve',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Platform'), actions: const []),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                ],
              )
            : _buildRecordedCoursesBody(),
      ),
    );
  }
}
