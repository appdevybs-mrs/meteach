import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/course_feedback_service.dart';
import '../shared/profile_avatar.dart';
import '../shared/study_variant.dart';
import 'teacher_mail_thread_screen.dart';

class TeacherMyPlatformScreen extends StatefulWidget {
  const TeacherMyPlatformScreen({super.key});

  @override
  State<TeacherMyPlatformScreen> createState() =>
      _TeacherMyPlatformScreenState();
}

enum _MyPlatformTab { needsReply, reported, recent, hidden }

enum _MyPlatformMainTab { comments, learners }

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

class _RecordedSessionMeta {
  const _RecordedSessionMeta({
    required this.hasVideo,
    required this.hasMaterials,
  });

  final bool hasVideo;
  final bool hasMaterials;
}

class _TeacherMyPlatformScreenState extends State<TeacherMyPlatformScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _busy = true;
  String? _error;
  bool _learnersBusy = true;
  String? _learnersError;
  _MyPlatformMainTab _mainTab = _MyPlatformMainTab.comments;
  _MyPlatformTab _tab = _MyPlatformTab.needsReply;
  String _courseFilter = 'all';

  List<_MyPlatformItem> _all = const [];
  List<_LearnerRecordedProgressItem> _learnerProgressRows = const [];
  Set<String> _assignedCourseIds = const <String>{};
  final Map<String, String> _courseLabelById = <String, String>{};
  final Map<String, Map<String, _RecordedSessionMeta>> _recordedMetaCache =
      <String, Map<String, _RecordedSessionMeta>>{};

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

    final classesSnap = await _db.child('classes').get();
    final learnerUids = <String>{};
    final classCourseIds = <String>{};

    if (classesSnap.exists && classesSnap.value is Map) {
      final classes = Map<dynamic, dynamic>.from(classesSnap.value as Map);
      for (final entry in classes.entries) {
        if (entry.value is! Map) continue;
        final c = Map<String, dynamic>.from(entry.value as Map);

        final cur = c['instructor_current'];
        final currentUid = cur is Map
            ? (cur['uid'] ?? '').toString().trim()
            : '';
        if (currentUid != _uid) continue;

        final classCourseId = (c['course_id'] ?? '').toString().trim();
        if (classCourseId.isNotEmpty) {
          classCourseIds.add(classCourseId);
        }

        final learnersMap = c['learners'];
        if (learnersMap is Map) {
          for (final uidAny in learnersMap.keys) {
            final learnerUid = uidAny.toString().trim();
            if (learnerUid.isNotEmpty) {
              learnerUids.add(learnerUid);
            }
          }
        }
      }
    }

    if (learnerUids.isEmpty) return out;

    final usersSnap = await _db.child('users').get();
    if (!usersSnap.exists || usersSnap.value is! Map) return out;

    final users = Map<dynamic, dynamic>.from(usersSnap.value as Map);

    for (final learnerUid in learnerUids) {
      final userRaw = users[learnerUid];
      if (userRaw is! Map) continue;
      final user = Map<String, dynamic>.from(userRaw);

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
            !assignedCourseKeys.contains(courseKey) &&
            !classCourseIds.contains(courseId)) {
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

  List<_MyPlatformItem> get _filtered {
    return _all.where((x) {
      if (_courseFilter != 'all' && x.courseId != _courseFilter) return false;

      switch (_tab) {
        case _MyPlatformTab.needsReply:
          return x.status == 'visible' || x.status == 'pending';
        case _MyPlatformTab.reported:
          return x.reportCount > 0 && x.status != 'removed';
        case _MyPlatformTab.recent:
          return x.status != 'removed';
        case _MyPlatformTab.hidden:
          return x.status == 'hidden' || x.status == 'removed';
      }
    }).toList();
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _courseLabel(String id) => _courseLabelById[id] ?? id;

  Future<void> _moderate(_MyPlatformItem item, String status) async {
    await CourseFeedbackService.moderateLessonComment(
      courseId: item.courseId,
      lessonId: item.lessonId,
      commentId: item.entryId,
      status: status,
    );
    await _load();
  }

  Future<void> _reply(_MyPlatformItem item) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reply to learner'),
        content: TextField(
          controller: c,
          maxLength: 400,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Write your reply',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final text = c.text.trim();
    if (text.isEmpty) return;

    await CourseFeedbackService.addLessonReply(
      courseId: item.courseId,
      lessonId: item.lessonId,
      commentId: item.entryId,
      uid: _uid,
      text: text,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Reply posted.')));
  }

  Future<String> _resolveLearnerName(String uid, String fallback) async {
    final snap = await _db.child('users').child(uid).get();
    if (snap.exists && snap.value is Map) {
      final m = Map<String, dynamic>.from(snap.value as Map);
      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();
      final full = '$first $last'.trim();
      if (full.isNotEmpty) return full;
      final email = (m['email'] ?? '').toString().trim();
      if (email.isNotEmpty) return email;
    }
    if (fallback.trim().isNotEmpty) return fallback.trim();
    return 'Learner';
  }

  Future<void> _messageLearner(_MyPlatformItem item) async {
    final subject = 'Course support: ${_courseLabel(item.courseId)}';
    final threadId = _threadIdFor(_uid, item.uid, item.courseId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final learnerName = await _resolveLearnerName(item.uid, item.firstName);

    final threadRef = _db.child('mail_threads').child(threadId);
    final tSnap = await threadRef.get();
    if (!tSnap.exists) {
      await threadRef.set({
        'participants': {_uid: true, item.uid: true},
        'subject': subject,
        'createdAt': now,
        'updatedAt': now,
        'lastMessageAt': now,
        'lastMessagePreview': 'Started from My Platform',
      });
    }

    final msgId = _db.child('mail_messages').child(threadId).push().key;
    if (msgId != null) {
      await _db.child('mail_messages').child(threadId).child(msgId).set({
        'fromUid': _uid,
        'body': 'Hi $learnerName, I saw your comment and wanted to help.',
        'createdAt': now,
      });
    }

    await _db.child('mail_index').child(_uid).child(threadId).update({
      'subject': subject,
      'updatedAt': now,
      'unread': 0,
    });
    await _db.child('mail_index').child(item.uid).child(threadId).update({
      'subject': subject,
      'updatedAt': now,
      'unread': 1,
    });

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeacherMailThreadScreen(
          threadId: threadId,
          peerUid: item.uid,
          peerName: learnerName,
          subject: subject,
        ),
      ),
    );
  }

  String _threadIdFor(String a, String b, String scope) {
    final ids = [a.trim(), b.trim()]..sort();
    return 'support_${scope}_${ids[0]}_${ids[1]}';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'pending':
        return const Color(0xFFD97706);
      case 'visible':
        return const Color(0xFF047857);
      case 'hidden':
        return const Color(0xFF64748B);
      case 'removed':
        return const Color(0xFFB91C1C);
      default:
        return const Color(0xFF475569);
    }
  }

  Widget _statusChip(String status) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.24)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 10,
        ),
      ),
    );
  }

  PopupMenuButton<String> _actionsMenu(_MyPlatformItem item) {
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      icon: const Text(
        '!',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 18,
          color: Color(0xFF0F172A),
        ),
      ),
      onSelected: (v) async {
        if (v == 'visible' || v == 'hidden' || v == 'removed') {
          await _moderate(item, v);
          return;
        }
        if (v == 'reply') {
          await _reply(item);
          return;
        }
        if (v == 'message') {
          await _messageLearner(item);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'visible', child: Text('Accept')),
        PopupMenuItem(value: 'hidden', child: Text('Hide')),
        PopupMenuItem(value: 'removed', child: Text('Remove')),
        PopupMenuItem(value: 'reply', child: Text('Answer')),
        PopupMenuItem(value: 'message', child: Text('Message learner')),
      ],
    );
  }

  String _tabLabel(_MyPlatformTab tab) {
    switch (tab) {
      case _MyPlatformTab.needsReply:
        return 'Needs reply';
      case _MyPlatformTab.reported:
        return 'Reported';
      case _MyPlatformTab.recent:
        return 'Recent';
      case _MyPlatformTab.hidden:
        return 'Hidden';
    }
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
                    Text(
                      item.learnerName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                      ),
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
    final rows = _filtered;
    final courses = _assignedCourseIds.toList()..sort();

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
                  label: 'Comments',
                  selected: _mainTab == _MyPlatformMainTab.comments,
                  onTap: () {
                    setState(() => _mainTab = _MyPlatformMainTab.comments);
                  },
                ),
                const SizedBox(width: 8),
                _mainTabChip(
                  label: 'Learners',
                  selected: _mainTab == _MyPlatformMainTab.learners,
                  onTap: () {
                    setState(() => _mainTab = _MyPlatformMainTab.learners);
                  },
                ),
              ],
            ),
          ),
          if (_mainTab == _MyPlatformMainTab.comments)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<_MyPlatformTab>(
                      initialValue: _tab,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'View',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: _MyPlatformTab.values
                          .map(
                            (t) => DropdownMenuItem(
                              value: t,
                              child: Text(_tabLabel(t)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _tab = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _courseFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Course',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'all',
                          child: Text('All courses'),
                        ),
                        ...courses.map(
                          (c) => DropdownMenuItem(
                            value: c,
                            child: Text(
                              _courseLabel(c),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ),
                      ],
                      selectedItemBuilder: (_) {
                        final labels = [
                          'All courses',
                          ...courses.map(_courseLabel),
                        ];
                        return labels
                            .map(
                              (x) => Text(
                                x,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            )
                            .toList();
                      },
                      onChanged: (v) =>
                          setState(() => _courseFilter = v ?? 'all'),
                    ),
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
                      : rows.isEmpty
                      ? const Center(
                          child: Text('No comments in this view yet.'),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (context, i) {
                            final item = rows[i];
                            final lessonMeta =
                                'Lesson: ${item.lessonId.isEmpty ? '-' : item.lessonId}';

                            return Container(
                              padding: const EdgeInsets.fromLTRB(9, 7, 7, 7),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(
                                  color: const Color(0xFFE5E7EB),
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      ProfileAvatar(
                                        name: item.displayName,
                                        photoUrl: item.photoUrl,
                                        radius: 11,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          item.firstName.isEmpty
                                              ? 'Learner'
                                              : item.firstName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        _fmtDate(item.createdAt),
                                        style: TextStyle(
                                          color: Colors.black.withValues(
                                            alpha: 0.52,
                                          ),
                                          fontWeight: FontWeight.w600,
                                          fontSize: 10,
                                        ),
                                      ),
                                      _actionsMenu(item),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      _statusChip(item.status),
                                      const SizedBox(width: 8),
                                      if (item.reportCount > 0)
                                        Text(
                                          'Reports ${item.reportCount}',
                                          style: const TextStyle(
                                            color: Color(0xFFB45309),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      const Spacer(),
                                      Flexible(
                                        child: Text(
                                          lessonMeta,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.black.withValues(
                                              alpha: 0.58,
                                            ),
                                            fontWeight: FontWeight.w700,
                                            fontSize: 10.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.text,
                                    style: TextStyle(
                                      fontStyle: FontStyle.italic,
                                      color: Colors.black.withValues(
                                        alpha: 0.78,
                                      ),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        )),
          ),
        ],
      ),
    );
  }
}
