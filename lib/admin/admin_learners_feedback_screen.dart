import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/homework_review_sync_service.dart';
import '../shared/admin_web_layout.dart';
import '../shared/profile_avatar.dart';

class AdminLearnersFeedbackScreen extends StatefulWidget {
  const AdminLearnersFeedbackScreen({super.key});

  @override
  State<AdminLearnersFeedbackScreen> createState() =>
      _AdminLearnersFeedbackScreenState();
}

class _AdminLearnersFeedbackScreenState
    extends State<AdminLearnersFeedbackScreen> {
  static const _primaryBlue = Color(0xFF0E7C86);
  static const _deepBlue = Color(0xFF135C7A);
  static const _actionOrange = Color(0xFFBF5D39);
  static const _appBg = Color(0xFFFAFCFF);
  static const _border = Color(0xFFD8CFC1);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late Future<List<_TeacherHomeworkStats>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadStats();
  }

  void _refresh() {
    setState(() => _future = _loadStats());
  }

  Map<String, dynamic> _safeMap(dynamic raw) {
    if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
    return <String, dynamic>{};
  }

  int _toInt(dynamic v) => HomeworkReviewSyncService.toInt(v);

  bool _isReviewed(Map<String, dynamic> hw) {
    return HomeworkReviewSyncService.isHomeworkReviewed(hw);
  }

  String _fullName(Map<String, dynamic> user, String fallback) {
    final first = (user['first_name'] ?? user['firstName'] ?? '')
        .toString()
        .trim();
    final last = (user['last_name'] ?? user['lastName'] ?? '')
        .toString()
        .trim();
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    final email = (user['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;
    return fallback;
  }

  String _classInstructorUid(Map<String, dynamic> cls) {
    final current = _safeMap(cls['instructor_current']);
    return (current['uid'] ?? '').toString().trim();
  }

  bool _homeworkHasAssignment(Map<String, dynamic> hw) {
    final text = (hw['text'] ?? hw['homeworkText'] ?? hw['note'] ?? '')
        .toString()
        .trim();
    final dueDate = (hw['dueDate'] ?? '').toString().trim();
    return text.isNotEmpty || dueDate.isNotEmpty;
  }

  String _courseKeyForClass({
    required Map<String, dynamic> users,
    required String learnerUid,
    required String classId,
  }) {
    final user = _safeMap(users[learnerUid]);
    final courses = _safeMap(user['courses']);
    for (final entry in courses.entries) {
      final course = _safeMap(entry.value);
      final cls = _safeMap(course['class']);
      final cid = (cls['class_id'] ?? '').toString().trim();
      if (cid == classId) return entry.key.toString().trim();
    }
    return '';
  }

  void _mergeHomeworkItem(
    Map<String, _HomeworkStatItem> itemsByRef, {
    required String homeworkRef,
    required String teacherUid,
    required bool sent,
    required Map<String, dynamic> homework,
  }) {
    final cleanRef = homeworkRef.trim();
    final cleanTeacher = teacherUid.trim();
    if (cleanRef.isEmpty || cleanTeacher.isEmpty) return;

    final existing = itemsByRef[cleanRef];
    if (existing == null) {
      itemsByRef[cleanRef] = _HomeworkStatItem(
        teacherUid: cleanTeacher,
        sent: sent,
        submitted: _toInt(homework['submittedAt']) > 0,
        reviewed: _isReviewed(homework),
        score: _scoreFromHomework(homework),
      );
      return;
    }

    if (existing.teacherUid != cleanTeacher) return;
    existing.sent = existing.sent || sent;
    existing.submitted =
        existing.submitted || _toInt(homework['submittedAt']) > 0;
    existing.reviewed = existing.reviewed || _isReviewed(homework);
    existing.score ??= _scoreFromHomework(homework);
  }

  int? _scoreFromHomework(Map<String, dynamic> homework) {
    final raw = homework['reviewScore'];
    if (raw is num) return raw.toInt().clamp(0, 100);
    final parsed = int.tryParse(raw?.toString() ?? '');
    if (parsed == null) return null;
    return parsed.clamp(0, 100);
  }

  Future<List<_TeacherHomeworkStats>> _loadStats() async {
    final usersSnap = await _db.child('users').get();
    final classesSnap = await _db.child('classes').get();
    final threadsSnap = await _db.child('mail_threads').get();

    final users = _safeMap(usersSnap.value);
    final teachers = <String, _TeacherHomeworkStats>{};

    for (final entry in users.entries) {
      final uid = entry.key.toString().trim();
      final user = _safeMap(entry.value);
      final role = (user['role'] ?? '').toString().trim().toLowerCase();
      if (uid.isEmpty || role != 'teacher') continue;
      teachers[uid] = _TeacherHomeworkStats(
        teacherUid: uid,
        teacherName: _fullName(user, 'Teacher'),
        photoUrl: ProfileAvatar.resolvePhotoFromMap(user),
      );
    }

    final itemsByRef = <String, _HomeworkStatItem>{};
    final classes = _safeMap(classesSnap.value);

    for (final classEntry in classes.entries) {
      final classId = classEntry.key.toString().trim();
      if (classId.isEmpty) continue;
      final cls = _safeMap(classEntry.value);
      final fallbackTeacherUid = _classInstructorUid(cls);
      final learners = _safeMap(cls['learners']);
      if (learners.isEmpty) continue;

      final attendance = _safeMap(cls['attendance']);
      for (final sessionEntry in attendance.entries) {
        final sessionId = sessionEntry.key.toString().trim();
        if (sessionId.isEmpty) continue;
        final session = _safeMap(sessionEntry.value);
        final classHomework = _safeMap(session['homework']);
        if (!_homeworkHasAssignment(classHomework)) continue;

        var teacherUid = (session['teacherUid'] ?? '').toString().trim();
        if (teacherUid.isEmpty) teacherUid = fallbackTeacherUid;
        if (teacherUid.isEmpty) continue;

        for (final learnerEntry in learners.entries) {
          final learnerUid = learnerEntry.key.toString().trim();
          if (learnerUid.isEmpty) continue;
          final courseKey = _courseKeyForClass(
            users: users,
            learnerUid: learnerUid,
            classId: classId,
          );
          if (courseKey.isEmpty) continue;

          final learnerUser = _safeMap(users[learnerUid]);
          final courses = _safeMap(learnerUser['courses']);
          final course = _safeMap(courses[courseKey]);
          final learnerAttendance = _safeMap(course['attendance']);
          final learnerSession = _safeMap(learnerAttendance[sessionId]);
          final learnerHomework = _safeMap(learnerSession['homework']);
          final homework = learnerHomework.isEmpty
              ? classHomework
              : <String, dynamic>{...classHomework, ...learnerHomework};
          if (!_homeworkHasAssignment(homework)) continue;

          _mergeHomeworkItem(
            itemsByRef,
            homeworkRef:
                'users/$learnerUid/courses/$courseKey/attendance/$sessionId/homework',
            teacherUid: teacherUid,
            sent: true,
            homework: homework,
          );
        }
      }
    }

    final threadRefsToLoad = <String, String>{};
    final threads = _safeMap(threadsSnap.value);
    for (final entry in threads.entries) {
      final thread = _safeMap(entry.value);
      final type = (thread['type'] ?? '').toString().trim().toLowerCase();
      final subject = (thread['subject'] ?? '').toString().trim().toLowerCase();
      final homeworkRef = (thread['homeworkRef'] ?? '').toString().trim();
      final looksHomework =
          type == 'homework' ||
          homeworkRef.isNotEmpty ||
          subject.startsWith('[hw]');
      if (!looksHomework || homeworkRef.isEmpty) continue;
      final teacherUid = (thread['teacherUid'] ?? '').toString().trim();
      if (teacherUid.isEmpty) continue;
      threadRefsToLoad[homeworkRef] = teacherUid;
    }

    for (final entry in threadRefsToLoad.entries) {
      final homeworkRef = entry.key;
      final teacherUid = entry.value;
      final snap = await _db.child(homeworkRef).get();
      final homework = _safeMap(snap.value);
      if (homework.isEmpty) continue;
      _mergeHomeworkItem(
        itemsByRef,
        homeworkRef: homeworkRef,
        teacherUid: teacherUid,
        sent: true,
        homework: homework,
      );
    }

    for (final item in itemsByRef.values) {
      final teacher = teachers.putIfAbsent(
        item.teacherUid,
        () => _TeacherHomeworkStats(
          teacherUid: item.teacherUid,
          teacherName: item.teacherUid,
          photoUrl: '',
        ),
      );
      if (item.sent) teacher.sent += 1;
      if (item.reviewed) teacher.reviewed += 1;
      if (item.submitted && !item.reviewed) teacher.pending += 1;
      if (item.reviewed && item.score != null) {
        teacher.scoreSum += item.score!;
        teacher.scoredReviews += 1;
      }
    }

    final list = teachers.values.where((t) => t.sent > 0).toList()
      ..sort((a, b) {
        final pending = b.pending.compareTo(a.pending);
        if (pending != 0) return pending;
        return a.teacherName.toLowerCase().compareTo(
          b.teacherName.toLowerCase(),
        );
      });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: _primaryBlue),
        title: const Text(
          "Learners' Feedback",
          style: TextStyle(color: _primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded, color: _actionOrange),
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1420,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
        child: FutureBuilder<List<_TeacherHomeworkStats>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                child: Text(
                  'Could not load learners feedback statistics.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }

            final rows = snap.data ?? const <_TeacherHomeworkStats>[];
            if (rows.isEmpty) {
              return const Center(
                child: Text(
                  'No homework feedback statistics yet.',
                  style: TextStyle(
                    color: _deepBlue,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              );
            }

            final totals = _Totals.fromRows(rows);
            return RefreshIndicator(
              onRefresh: () async => _refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  _HeaderStats(totals: totals),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final crossAxisCount = width >= 1100
                          ? 3
                          : (width >= 720 ? 2 : 1);
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: rows.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: width >= 720 ? 2.25 : 1.78,
                        ),
                        itemBuilder: (context, index) {
                          return _TeacherStatsCard(stats: rows[index]);
                        },
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HeaderStats extends StatelessWidget {
  const _HeaderStats({required this.totals});

  final _Totals totals;

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, String value, IconData icon, Color color) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _AdminLearnersFeedbackScreenState._border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(
              '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              value,
              style: TextStyle(color: color, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF7F8),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFB7DEE2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Homework feedback overview',
            style: TextStyle(
              color: _AdminLearnersFeedbackScreenState._deepBlue,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Counts are grouped by teacher from homework assignments and homework mail threads.',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.62),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              stat(
                'Teachers',
                '${totals.teachers}',
                Icons.groups_rounded,
                _AdminLearnersFeedbackScreenState._primaryBlue,
              ),
              stat(
                'Sent',
                '${totals.sent}',
                Icons.outbox_rounded,
                _AdminLearnersFeedbackScreenState._deepBlue,
              ),
              stat(
                'Reviewed',
                '${totals.reviewed}',
                Icons.fact_check_rounded,
                Colors.green.shade700,
              ),
              stat(
                'Pending',
                '${totals.pending}',
                Icons.pending_actions_rounded,
                _AdminLearnersFeedbackScreenState._actionOrange,
              ),
              stat(
                'Avg score',
                totals.averageScoreLabel,
                Icons.score_rounded,
                Colors.indigo.shade700,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TeacherStatsCard extends StatelessWidget {
  const _TeacherStatsCard({required this.stats});

  final _TeacherHomeworkStats stats;

  @override
  Widget build(BuildContext context) {
    Widget metric(String label, String value, Color color) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.58),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(
          color: _AdminLearnersFeedbackScreenState._border,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProfileAvatar(
                  name: stats.teacherName,
                  photoUrl: stats.photoUrl,
                  radius: 26,
                  fallbackBg: const Color(0xFFEAF7F8),
                  fallbackFg: _AdminLearnersFeedbackScreenState._primaryBlue,
                  borderColor: _AdminLearnersFeedbackScreenState._border,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stats.teacherName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _AdminLearnersFeedbackScreenState._deepBlue,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        stats.averageScoreLabel,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.58),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                metric(
                  'Sent',
                  '${stats.sent}',
                  _AdminLearnersFeedbackScreenState._deepBlue,
                ),
                const SizedBox(width: 8),
                metric('Reviewed', '${stats.reviewed}', Colors.green.shade700),
                const SizedBox(width: 8),
                metric(
                  'Pending',
                  '${stats.pending}',
                  _AdminLearnersFeedbackScreenState._actionOrange,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeworkStatItem {
  _HomeworkStatItem({
    required this.teacherUid,
    required this.sent,
    required this.submitted,
    required this.reviewed,
    required this.score,
  });

  final String teacherUid;
  bool sent;
  bool submitted;
  bool reviewed;
  int? score;
}

class _TeacherHomeworkStats {
  _TeacherHomeworkStats({
    required this.teacherUid,
    required this.teacherName,
    required this.photoUrl,
  });

  final String teacherUid;
  final String teacherName;
  final String photoUrl;
  int sent = 0;
  int reviewed = 0;
  int pending = 0;
  int scoreSum = 0;
  int scoredReviews = 0;

  int? get averageScore =>
      scoredReviews == 0 ? null : (scoreSum / scoredReviews).round();

  String get averageScoreLabel {
    final avg = averageScore;
    return avg == null ? 'Avg score: -' : 'Avg score: $avg/100';
  }
}

class _Totals {
  const _Totals({
    required this.teachers,
    required this.sent,
    required this.reviewed,
    required this.pending,
    required this.scoreSum,
    required this.scoredReviews,
  });

  final int teachers;
  final int sent;
  final int reviewed;
  final int pending;
  final int scoreSum;
  final int scoredReviews;

  static _Totals fromRows(List<_TeacherHomeworkStats> rows) {
    var sent = 0;
    var reviewed = 0;
    var pending = 0;
    var scoreSum = 0;
    var scoredReviews = 0;
    for (final row in rows) {
      sent += row.sent;
      reviewed += row.reviewed;
      pending += row.pending;
      scoreSum += row.scoreSum;
      scoredReviews += row.scoredReviews;
    }
    return _Totals(
      teachers: rows.length,
      sent: sent,
      reviewed: reviewed,
      pending: pending,
      scoreSum: scoreSum,
      scoredReviews: scoredReviews,
    );
  }

  String get averageScoreLabel {
    if (scoredReviews == 0) return '-';
    return '${(scoreSum / scoredReviews).round()}/100';
  }
}
