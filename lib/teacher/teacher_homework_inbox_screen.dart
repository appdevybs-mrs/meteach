import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/human_error.dart';
import '../shared/teacher_web_layout.dart';
import 'teacher_mail_thread_screen.dart';

enum _HomeworkFilter { all, notReviewed, reviewed, sent }

enum _HomeworkSource { inbox, sent }

class TeacherHomeworkInboxScreen extends StatefulWidget {
  const TeacherHomeworkInboxScreen({super.key});

  @override
  State<TeacherHomeworkInboxScreen> createState() =>
      _TeacherHomeworkInboxScreenState();
}

class _TeacherHomeworkInboxScreenState
    extends State<TeacherHomeworkInboxScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String _meUid = '';
  Stream<DatabaseEvent>? _indexStream;
  _HomeworkFilter _filter = _HomeworkFilter.notReviewed;

  Future<List<_HomeworkThreadView>>? _viewsFuture;
  String _rowsSignature = '';

  @override
  void initState() {
    super.initState();
    _meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (_meUid.isNotEmpty) {
      _indexStream = _db.child('mail_index/$_meUid').onValue;
    }
  }

  bool _isHomework(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'homework') return true;

    final subject = (m['subject'] ?? '').toString().trim().toLowerCase();
    if (subject.startsWith('[hw]')) return true;
    if (subject.contains('homework')) return true;
    return false;
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Map<String, dynamic> _safeMap(dynamic v) {
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), val));
    }
    return <String, dynamic>{};
  }

  String _short(String s, int max) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    if (max <= 1) return '…';
    return '${t.substring(0, max - 1)}…';
  }

  String _normalizeHomeworkStatus(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'approved') return 'pass';
    if (s == 'needs_work') return 'redo';
    return s;
  }

  List<_HomeworkThreadRow> _rowsFromSnapshot(dynamic value) {
    if (value is! Map) return const <_HomeworkThreadRow>[];
    final out = <_HomeworkThreadRow>[];

    value.forEach((threadIdRaw, rowRaw) {
      if (rowRaw is! Map) return;
      final m = rowRaw.map((k, v) => MapEntry(k.toString(), v));
      if (!_isHomework(m)) return;

      final threadId = threadIdRaw.toString().trim();
      if (threadId.isEmpty) return;

      out.add(
        _HomeworkThreadRow(
          threadId: threadId,
          peerUid: (m['peerUid'] ?? '').toString().trim(),
          peerName: ((m['peerName'] ?? '').toString().trim().isEmpty)
              ? 'Learner'
              : (m['peerName'] ?? '').toString().trim(),
          subject: ((m['subject'] ?? '').toString().trim().isEmpty)
              ? 'Homework'
              : (m['subject'] ?? '').toString().trim(),
          lastMessage: (m['lastMessage'] ?? '').toString().trim(),
          updatedAtMs: _toInt(m['updatedAt']),
          unreadCount: _toInt(m['unreadCount']),
          deletedAtMs: (m['deletedAt'] == null) ? null : _toInt(m['deletedAt']),
        ),
      );
    });

    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$dd/$mo ${dt.year} $hh:$mm';
  }

  String _signatureForRows(List<_HomeworkThreadRow> rows) {
    return rows
        .map((r) => '${r.threadId}:${r.updatedAtMs}:${r.unreadCount}')
        .join('|');
  }

  Future<List<_HomeworkThreadView>> _ensureViews(
    List<_HomeworkThreadRow> rows,
  ) {
    final sig = _signatureForRows(rows);
    if (_viewsFuture != null && sig == _rowsSignature) return _viewsFuture!;

    _rowsSignature = sig;
    _viewsFuture = _composeViews(rows);
    return _viewsFuture!;
  }

  Future<List<_HomeworkThreadView>> _composeViews(
    List<_HomeworkThreadRow> rows,
  ) async {
    final inboxViews = await Future.wait(rows.map(_loadView));
    final existingHomeworkRefs = inboxViews
        .map((v) => v.homeworkRefPath.trim())
        .where((p) => p.isNotEmpty)
        .toSet();
    final sentViews = await _loadSentViews(existingHomeworkRefs);

    final merged = <_HomeworkThreadView>[...inboxViews, ...sentViews];
    merged.sort((a, b) => b.row.updatedAtMs.compareTo(a.row.updatedAtMs));
    return merged;
  }

  Future<String> _learnerName(String uid) async {
    try {
      final snap = await _db.child('users/$uid').get();
      if (!snap.exists || snap.value is! Map) return uid;
      final m = _safeMap(snap.value);
      final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$fn $ln').trim();
      if (full.isNotEmpty) return full;
      final email = (m['email'] ?? '').toString().trim();
      if (email.isNotEmpty) return email;
    } catch (_) {}
    return uid;
  }

  Future<List<_HomeworkThreadView>> _loadSentViews(
    Set<String> existingHomeworkRefs,
  ) async {
    if (_meUid.isEmpty) return const <_HomeworkThreadView>[];

    final out = <_HomeworkThreadView>[];
    final classSnap = await _db.child('classes').get();
    if (!classSnap.exists || classSnap.value is! Map) return out;

    final classes = _safeMap(classSnap.value);

    final courseKeyByLearnerAndClass = <String, String>{};
    final learnerNameCache = <String, String>{};

    Future<String> resolveCourseKey(String learnerUid, String classId) async {
      final cacheKey = '$learnerUid|$classId';
      if (courseKeyByLearnerAndClass.containsKey(cacheKey)) {
        return courseKeyByLearnerAndClass[cacheKey] ?? '';
      }

      try {
        final cSnap = await _db.child('users/$learnerUid/courses').get();
        if (!cSnap.exists || cSnap.value is! Map) {
          courseKeyByLearnerAndClass[cacheKey] = '';
          return '';
        }
        final courses = _safeMap(cSnap.value);
        for (final e in courses.entries) {
          final c = _safeMap(e.value);
          final cls = _safeMap(c['class']);
          final cid = (cls['class_id'] ?? '').toString().trim();
          if (cid == classId) {
            final key = e.key.toString().trim();
            courseKeyByLearnerAndClass[cacheKey] = key;
            return key;
          }
        }
      } catch (_) {}

      courseKeyByLearnerAndClass[cacheKey] = '';
      return '';
    }

    for (final cEntry in classes.entries) {
      final classId = cEntry.key.toString().trim();
      if (classId.isEmpty) continue;

      final classMap = _safeMap(cEntry.value);
      final learnersMap = _safeMap(classMap['learners']);
      if (learnersMap.isEmpty) continue;

      final attendanceMap = _safeMap(classMap['attendance']);
      if (attendanceMap.isEmpty) continue;

      final sessionsById = <String, Map<String, dynamic>>{};
      for (final aEntry in attendanceMap.entries) {
        final sid = aEntry.key.toString().trim();
        if (sid.isEmpty) continue;
        final rec = _safeMap(aEntry.value);
        if (rec.isEmpty) continue;

        final owner = (rec['teacherUid'] ?? '').toString().trim();
        if (owner.isNotEmpty && owner != _meUid) continue;

        final hw = _safeMap(rec['homework']);
        final text = (hw['text'] ?? '').toString().trim();
        final dueDate = (hw['dueDate'] ?? '').toString().trim();
        if (text.isEmpty && dueDate.isEmpty) continue;

        sessionsById[sid] = rec;
      }

      if (sessionsById.isEmpty) continue;

      for (final learnerUidRaw in learnersMap.keys) {
        final learnerUid = learnerUidRaw.toString().trim();
        if (learnerUid.isEmpty) continue;

        final courseKey = await resolveCourseKey(learnerUid, classId);
        if (courseKey.isEmpty) continue;

        final learnerName = learnerNameCache.putIfAbsent(
          learnerUid,
          () => learnerUid,
        );
        if (learnerName == learnerUid) {
          learnerNameCache[learnerUid] = await _learnerName(learnerUid);
        }

        final learnerAttendanceSnap = await _db
            .child('users/$learnerUid/courses/$courseKey/attendance')
            .get();
        final learnerAttendance = _safeMap(learnerAttendanceSnap.value);

        for (final sEntry in sessionsById.entries) {
          final sessionId = sEntry.key;
          final classRec = sEntry.value;

          final learnerRec = _safeMap(learnerAttendance[sessionId]);
          final classHw = _safeMap(classRec['homework']);
          final learnerHw = _safeMap(learnerRec['homework']);

          final text = (learnerHw['text'] ?? classHw['text'] ?? '')
              .toString()
              .trim();
          final dueDate = (learnerHw['dueDate'] ?? classHw['dueDate'] ?? '')
              .toString()
              .trim();
          if (text.isEmpty && dueDate.isEmpty) continue;

          final homeworkRefPath =
              'users/$learnerUid/courses/$courseKey/attendance/$sessionId/homework';
          if (existingHomeworkRefs.contains(homeworkRefPath)) continue;

          final reviewedAt = _toInt(learnerHw['reviewedAt']);
          final reviewStatus = _normalizeHomeworkStatus(
            learnerHw['reviewStatus'],
          );

          int updatedAt = _toInt(learnerHw['updatedAt']);
          if (updatedAt <= 0) updatedAt = _toInt(learnerRec['updatedAt']);
          if (updatedAt <= 0) updatedAt = _toInt(classRec['updatedAt']);
          if (updatedAt <= 0) updatedAt = _toInt(classRec['createdAt']);

          final courseTitle = (classRec['course_title'] ?? '')
              .toString()
              .trim();
          final date = (classRec['date'] ?? '').toString().trim();
          final taught = _safeMap(classRec['taught']);
          final taughtTitle = (taught['title'] ?? '').toString().trim();

          final subjectParts = <String>['Sent Homework'];
          if (courseTitle.isNotEmpty) subjectParts.add(courseTitle);
          if (date.isNotEmpty) subjectParts.add(date);
          final subject = subjectParts.join(' • ');

          out.add(
            _HomeworkThreadView(
              row: _HomeworkThreadRow(
                threadId: '',
                peerUid: learnerUid,
                peerName: learnerNameCache[learnerUid] ?? learnerUid,
                subject: subject,
                lastMessage: _short(text, 120),
                updatedAtMs: updatedAt,
                unreadCount: 0,
                deletedAtMs: null,
              ),
              source: _HomeworkSource.sent,
              courseTitle: courseTitle.isEmpty ? 'Course not set' : courseTitle,
              courseKey: courseKey,
              sessionId: sessionId,
              classId: classId,
              homeworkRefPath: homeworkRefPath,
              homeworkText: text,
              homeworkDueDate: dueDate,
              submittedAtMs: _toInt(learnerHw['submittedAt']),
              reviewed: reviewedAt > 0 || reviewStatus.isNotEmpty,
              needsRedo:
                  learnerHw['needsRedo'] == true || reviewStatus == 'redo',
              reviewedAtMs: reviewedAt,
              reviewScore: _toInt(learnerHw['reviewScore']),
              reviewGrade: (learnerHw['reviewGrade'] ?? '').toString().trim(),
              reviewStatus: reviewStatus,
              taughtTitle: taughtTitle,
            ),
          );
        }
      }
    }

    return out;
  }

  Future<_HomeworkThreadView> _loadView(_HomeworkThreadRow row) async {
    String courseTitle = '';
    String courseKey = '';
    String sessionId = '';
    String classId = '';
    String homeworkRefPath = '';
    String homeworkText = '';
    String homeworkDueDate = '';
    String taughtTitle = '';
    int submittedAtMs = 0;
    bool reviewed = false;
    bool needsRedo = false;
    int reviewedAt = 0;
    int score = 0;
    String grade = '';
    String reviewStatus = '';

    try {
      final tSnap = await _db.child('mail_threads/${row.threadId}').get();
      if (tSnap.exists && tSnap.value is Map) {
        final t = (tSnap.value as Map).map((k, v) => MapEntry('$k', v));
        courseKey = (t['courseKey'] ?? '').toString().trim();
        sessionId = (t['sessionId'] ?? '').toString().trim();
        classId = (t['classId'] ?? '').toString().trim();
        taughtTitle = (t['taughtTitle'] ?? '').toString().trim();

        final tCourseTitle = (t['courseTitle'] ?? '').toString().trim();
        courseTitle = tCourseTitle.isNotEmpty
            ? tCourseTitle
            : (courseKey.isNotEmpty ? courseKey : 'Course not set');

        homeworkRefPath = (t['homeworkRef'] ?? '').toString().trim();
        if (homeworkRefPath.isNotEmpty) {
          final hwSnap = await _db.child(homeworkRefPath).get();
          if (hwSnap.exists && hwSnap.value is Map) {
            final hw = (hwSnap.value as Map).map((k, v) => MapEntry('$k', v));
            reviewedAt = _toInt(hw['reviewedAt']);
            submittedAtMs = _toInt(hw['submittedAt']);
            reviewStatus = _normalizeHomeworkStatus(hw['reviewStatus']);
            score = _toInt(hw['reviewScore']);
            grade = (hw['reviewGrade'] ?? '').toString().trim();
            needsRedo = hw['needsRedo'] == true || reviewStatus == 'redo';
            reviewed = reviewedAt > 0 || reviewStatus.isNotEmpty;
            homeworkText =
                (hw['text'] ?? hw['homeworkText'] ?? hw['note'] ?? '')
                    .toString()
                    .trim();
            homeworkDueDate = (hw['dueDate'] ?? '').toString().trim();
          }
        }

        if ((courseTitle.isEmpty || courseTitle == courseKey) &&
            row.peerUid.isNotEmpty &&
            courseKey.isNotEmpty) {
          final cSnap = await _db
              .child('users/${row.peerUid}/courses/$courseKey')
              .get();
          if (cSnap.exists && cSnap.value is Map) {
            final c = (cSnap.value as Map).map((k, v) => MapEntry('$k', v));
            final title = (c['title'] ?? c['course_title'] ?? '')
                .toString()
                .trim();
            if (title.isNotEmpty) courseTitle = title;

            if (classId.isEmpty && c['class'] is Map) {
              final cls = (c['class'] as Map).map((k, v) => MapEntry('$k', v));
              classId = (cls['class_id'] ?? '').toString().trim();
              final classTitle = (cls['course_title'] ?? '').toString().trim();
              if (courseTitle.isEmpty && classTitle.isNotEmpty) {
                courseTitle = classTitle;
              }
            }
          }
        }

        if (classId.isNotEmpty &&
            (courseTitle.isEmpty || courseTitle == 'Course not set')) {
          final clsSnap = await _db.child('classes/$classId').get();
          if (clsSnap.exists && clsSnap.value is Map) {
            final c = (clsSnap.value as Map).map((k, v) => MapEntry('$k', v));
            final classCourseTitle =
                (c['course_title'] ?? c['courseTitle'] ?? '').toString().trim();
            if (classCourseTitle.isNotEmpty) courseTitle = classCourseTitle;
          }
        }

        if ((courseTitle.isEmpty || courseTitle == courseKey) &&
            courseKey.isNotEmpty) {
          final courseSnap = await _db.child('courses/$courseKey').get();
          if (courseSnap.exists && courseSnap.value is Map) {
            final c = (courseSnap.value as Map).map(
              (k, v) => MapEntry('$k', v),
            );
            final t = (c['title'] ?? c['course_title'] ?? '').toString().trim();
            if (t.isNotEmpty) courseTitle = t;
          }
        }
      }
    } catch (_) {}

    return _HomeworkThreadView(
      row: row,
      source: _HomeworkSource.inbox,
      courseTitle: courseTitle.isEmpty ? 'Course not set' : courseTitle,
      courseKey: courseKey,
      sessionId: sessionId,
      classId: classId,
      homeworkRefPath: homeworkRefPath,
      homeworkText: homeworkText,
      homeworkDueDate: homeworkDueDate,
      submittedAtMs: submittedAtMs,
      reviewed: reviewed,
      needsRedo: needsRedo,
      reviewedAtMs: reviewedAt,
      reviewScore: score,
      reviewGrade: grade,
      reviewStatus: reviewStatus,
      taughtTitle: taughtTitle,
    );
  }

  Future<void> _copyHomeworkText(_HomeworkThreadView v) async {
    final text = v.homeworkText.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Homework text copied'),
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  Future<void> _editHomework(_HomeworkThreadView v) async {
    if (v.homeworkRefPath.trim().isEmpty) return;

    final latest = await _db.child(v.homeworkRefPath).get();
    final latestMap = _safeMap(latest.value);
    final textC = TextEditingController(
      text: (latestMap['text'] ?? v.homeworkText).toString(),
    );
    String due = (latestMap['dueDate'] ?? v.homeworkDueDate).toString().trim();

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            Future<void> pickDueDate() async {
              DateTime initial = DateTime.now();
              final parts = due.split('-');
              if (parts.length == 3) {
                final y = int.tryParse(parts[0]);
                final m = int.tryParse(parts[1]);
                final d = int.tryParse(parts[2]);
                if (y != null && m != null && d != null) {
                  initial = DateTime(y, m, d);
                }
              }

              final picked = await showDatePicker(
                context: ctx,
                initialDate: initial,
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked == null) return;
              final mm = picked.month.toString().padLeft(2, '0');
              final dd = picked.day.toString().padLeft(2, '0');
              setLocal(() => due = '${picked.year}-$mm-$dd');
            }

            return AlertDialog(
              title: const Text('Edit homework'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.row.peerName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: textC,
                      minLines: 6,
                      maxLines: 10,
                      decoration: const InputDecoration(
                        labelText: 'Homework text',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            due.isEmpty ? 'No due date' : 'Due: $due',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setLocal(() => due = ''),
                          child: const Text('Clear'),
                        ),
                        FilledButton.tonal(
                          onPressed: pickDueDate,
                          child: const Text('Pick'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.child(v.homeworkRefPath).update({
      'text': textC.text.trim(),
      'dueDate': due,
      'updatedAt': now,
    });

    _rowsSignature = '';
    _viewsFuture = null;
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Homework updated'),
          duration: Duration(milliseconds: 1200),
        ),
      );
    }
  }

  Future<void> _deleteForMe(_HomeworkThreadView v) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete from your homework inbox?'),
            content: const Text(
              'This hides it for you only. You can restore it later.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.child('mail_index/$_meUid/${v.row.threadId}').update({
      'deletedAt': now,
    });
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  Future<void> _restoreForMe(String threadId) async {
    await _db.child('mail_index/$_meUid/$threadId').update({'deletedAt': null});
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  Future<void> _markReviewed(_HomeworkThreadView v) async {
    if (v.homeworkRefPath.trim().isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.child(v.homeworkRefPath).update({
      'reviewedAt': now,
      'reviewStatus': 'pass',
      'needsRedo': false,
      'reviewNote': 'Marked reviewed from homework inbox.',
    });
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  Future<void> _markUnreviewed(_HomeworkThreadView v) async {
    if (v.homeworkRefPath.trim().isEmpty) return;
    await _db.child(v.homeworkRefPath).update({
      'reviewedAt': null,
      'reviewStatus': '',
      'reviewScore': null,
      'reviewGrade': '',
      'reviewNote': '',
      'needsRedo': false,
    });
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  List<_HomeworkThreadView> _applyFilter(List<_HomeworkThreadView> views) {
    switch (_filter) {
      case _HomeworkFilter.notReviewed:
        return views.where((v) => !v.reviewed).toList();
      case _HomeworkFilter.reviewed:
        return views.where((v) => v.reviewed).toList();
      case _HomeworkFilter.sent:
        return views.where((v) => v.source == _HomeworkSource.sent).toList();
      case _HomeworkFilter.all:
        return views;
    }
  }

  void _showDetails(_HomeworkThreadView v) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Homework details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Learner: ${v.row.peerName}'),
            const SizedBox(height: 6),
            Text('Course: ${v.courseTitle}'),
            if (v.courseKey.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Course key: ${v.courseKey}'),
            ],
            if (v.sessionId.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Session ID: ${v.sessionId}'),
            ],
            if (v.taughtTitle.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Lesson: ${v.taughtTitle}'),
            ],
            if (v.homeworkDueDate.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Due date: ${v.homeworkDueDate}'),
            ],
            if (v.submittedAtMs > 0) ...[
              const SizedBox(height: 6),
              Text('Submitted at: ${_fmtTime(v.submittedAtMs)}'),
            ],
            const SizedBox(height: 8),
            Text('Status: ${v.reviewed ? 'Reviewed' : 'Not reviewed'}'),
            if (v.needsRedo) ...[
              const SizedBox(height: 6),
              const Text('Needs redo: Yes'),
            ],
            if (v.reviewed &&
                (v.reviewScore > 0 || v.reviewGrade.isNotEmpty)) ...[
              const SizedBox(height: 6),
              Text(
                'Score/Grade: ${v.reviewScore > 0 ? '${v.reviewScore}/100' : '-'} ${v.reviewGrade.isNotEmpty ? '• ${v.reviewGrade}' : ''}',
              ),
            ],
            if (v.reviewedAtMs > 0) ...[
              const SizedBox(height: 6),
              Text('Reviewed at: ${_fmtTime(v.reviewedAtMs)}'),
            ],
            const SizedBox(height: 8),
            Text(
              'Homework text:',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.black.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.black.withValues(alpha: 0.12)),
                color: Colors.black.withValues(alpha: 0.03),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  v.homeworkText.trim().isEmpty ? '-' : v.homeworkText,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.78),
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (v.homeworkRefPath.trim().isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _editHomework(v);
              },
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('Edit'),
            ),
          if (v.homeworkText.trim().isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _copyHomeworkText(v);
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy text'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(List<_HomeworkThreadView> all) {
    final allCount = all.length;
    final reviewedCount = all.where((v) => v.reviewed).length;
    final notReviewedCount = allCount - reviewedCount;
    final sentCount = all.where((v) => v.source == _HomeworkSource.sent).length;

    Widget chip(String text, _HomeworkFilter value, int count) {
      return ChoiceChip(
        selected: _filter == value,
        label: Text('$text ($count)'),
        onSelected: (_) => setState(() => _filter = value),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('All', _HomeworkFilter.all, allCount),
        chip('Not reviewed', _HomeworkFilter.notReviewed, notReviewedCount),
        chip('Reviewed', _HomeworkFilter.reviewed, reviewedCount),
        chip('Sent', _HomeworkFilter.sent, sentCount),
      ],
    );
  }

  void _showDeletedSheet(List<_HomeworkThreadView> deleted) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        if (deleted.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: Text('No deleted homework threads.')),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
          itemCount: deleted.length,
          separatorBuilder: (_, index) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final v = deleted[i];
            return ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
              ),
              title: Text(
                v.row.peerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                v.courseTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton.icon(
                onPressed: () async {
                  await _restoreForMe(v.row.threadId);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Restore'),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _refreshInbox() async {
    _rowsSignature = '';
    _viewsFuture = null;
    if (mounted) setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Homework Inbox'),
        actions: [
          if (_viewsFuture != null)
            FutureBuilder<List<_HomeworkThreadView>>(
              future: _viewsFuture,
              builder: (context, s) {
                final all = s.data ?? const <_HomeworkThreadView>[];
                final deleted = all
                    .where((v) => v.row.deletedAtMs != null)
                    .toList();
                return IconButton(
                  tooltip: 'Deleted',
                  onPressed: () => _showDeletedSheet(deleted),
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.delete_outline_rounded),
                      if (deleted.isNotEmpty)
                        Positioned(
                          right: -6,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              deleted.length > 99 ? '99+' : '${deleted.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1420,
        child: _indexStream == null
            ? const Center(child: Text('Please sign in again.'))
            : StreamBuilder<DatabaseEvent>(
                stream: _indexStream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          toHumanError(
                            snap.error ?? Exception('Unknown error'),
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    );
                  }

                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final rows = _rowsFromSnapshot(snap.data?.snapshot.value);
                  return FutureBuilder<List<_HomeworkThreadView>>(
                    future: _ensureViews(rows),
                    builder: (context, viewsSnap) {
                      if (!viewsSnap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final allViews =
                          viewsSnap.data ?? const <_HomeworkThreadView>[];
                      final activeViews = allViews
                          .where((v) => v.row.deletedAtMs == null)
                          .toList();
                      final views = _applyFilter(activeViews);

                      if (views.isEmpty) {
                        return RefreshIndicator(
                          onRefresh: _refreshInbox,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 180),
                              Center(child: Text('No homework items found.')),
                            ],
                          ),
                        );
                      }

                      return RefreshIndicator(
                        onRefresh: _refreshInbox,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                          itemCount: views.length + 1,
                          itemBuilder: (context, i) {
                            if (i == 0) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _buildFilterBar(activeViews),
                              );
                            }

                            final v = views[i - 1];
                            return Dismissible(
                              key: ValueKey(
                                'hw_${v.row.threadId.isEmpty ? v.homeworkRefPath : v.row.threadId}',
                              ),
                              direction: DismissDirection.horizontal,
                              confirmDismiss: (direction) async {
                                if (direction == DismissDirection.startToEnd) {
                                  if (v.reviewed) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Already reviewed'),
                                          duration: Duration(
                                            milliseconds: 1200,
                                          ),
                                        ),
                                      );
                                    }
                                    return false;
                                  }
                                  final ok =
                                      await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text(
                                            'Mark as reviewed?',
                                          ),
                                          content: const Text(
                                            'This will mark this homework thread as reviewed and remove it from "Not reviewed".',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('Cancel'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
                                              child: const Text(
                                                'Mark reviewed',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ) ??
                                      false;
                                  if (!ok) return false;
                                  await _markReviewed(v);
                                  if (!context.mounted) return false;
                                  {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Marked reviewed'),
                                        duration: Duration(milliseconds: 1200),
                                      ),
                                    );
                                  }
                                  return false;
                                }

                                if (direction == DismissDirection.endToStart) {
                                  if (!v.reviewed) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Already not reviewed'),
                                          duration: Duration(
                                            milliseconds: 1200,
                                          ),
                                        ),
                                      );
                                    }
                                    return false;
                                  }
                                  final ok =
                                      await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text(
                                            'Mark as not reviewed?',
                                          ),
                                          content: const Text(
                                            'This will move this homework thread back to "Not reviewed" and clear review details.',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('Cancel'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
                                              child: const Text(
                                                'Mark not reviewed',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ) ??
                                      false;
                                  if (!ok) return false;
                                  await _markUnreviewed(v);
                                  if (!context.mounted) return false;
                                  {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Marked not reviewed'),
                                        duration: Duration(milliseconds: 1200),
                                      ),
                                    );
                                  }
                                  return false;
                                }

                                return false;
                              },
                              background: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                alignment: Alignment.centerLeft,
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline_rounded,
                                      color: Colors.green,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Mark reviewed',
                                      style: TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              secondaryBackground: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                alignment: Alignment.centerRight,
                                decoration: BoxDecoration(
                                  color: Colors.orange.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Icon(
                                      Icons.undo_rounded,
                                      color: Colors.orange.shade800,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Mark not reviewed',
                                      style: TextStyle(
                                        color: Colors.orange.shade800,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              child: Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onLongPress: v.row.threadId.isEmpty
                                      ? null
                                      : () => _deleteForMe(v),
                                  onTap: () {
                                    if (v.row.threadId.isNotEmpty) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              TeacherMailThreadScreen(
                                                threadId: v.row.threadId,
                                                peerUid: v.row.peerUid,
                                                peerName: v.row.peerName,
                                                subject: v.row.subject,
                                              ),
                                        ),
                                      );
                                      return;
                                    }
                                    _showDetails(v);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        CircleAvatar(
                                          radius: 18,
                                          backgroundColor: v.reviewed
                                              ? Colors.green.withValues(
                                                  alpha: 0.14,
                                                )
                                              : Colors.orange.withValues(
                                                  alpha: 0.14,
                                                ),
                                          child: Icon(
                                            Icons.assignment_rounded,
                                            color: v.reviewed
                                                ? Colors.green.shade700
                                                : Colors.orange.shade700,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                v.row.peerName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 14.5,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      v.source ==
                                                          _HomeworkSource.sent
                                                      ? Colors.blue.withValues(
                                                          alpha: 0.12,
                                                        )
                                                      : Colors.purple
                                                            .withValues(
                                                              alpha: 0.12,
                                                            ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                  border: Border.all(
                                                    color:
                                                        v.source ==
                                                            _HomeworkSource.sent
                                                        ? Colors.blue
                                                              .withValues(
                                                                alpha: 0.35,
                                                              )
                                                        : Colors.purple
                                                              .withValues(
                                                                alpha: 0.35,
                                                              ),
                                                  ),
                                                ),
                                                child: Text(
                                                  v.source ==
                                                          _HomeworkSource.sent
                                                      ? 'Sent'
                                                      : 'Inbox',
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w900,
                                                    color:
                                                        v.source ==
                                                            _HomeworkSource.sent
                                                        ? Colors.blue.shade800
                                                        : Colors
                                                              .purple
                                                              .shade800,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                v.courseTitle,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  color: Colors.black
                                                      .withValues(alpha: 0.67),
                                                  fontSize: 12.2,
                                                ),
                                              ),
                                              if (v.classId.isNotEmpty) ...[
                                                const SizedBox(height: 3),
                                                Text(
                                                  'Class: ${v.classId}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.55,
                                                        ),
                                                    fontSize: 11.2,
                                                  ),
                                                ),
                                              ],
                                              const SizedBox(height: 6),
                                              Text(
                                                v.row.lastMessage.isEmpty
                                                    ? '-'
                                                    : v.row.lastMessage,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.62),
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (v.unreadCount > 0)
                                                  Container(
                                                    margin:
                                                        const EdgeInsets.only(
                                                          right: 6,
                                                        ),
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 4,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.red
                                                          .withValues(
                                                            alpha: 0.12,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      v.unreadCount.toString(),
                                                      style: const TextStyle(
                                                        color: Colors.red,
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                  ),
                                                IconButton(
                                                  tooltip: 'Homework details',
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  onPressed: () =>
                                                      _showDetails(v),
                                                  icon: Icon(
                                                    Icons.info_outline_rounded,
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.65,
                                                        ),
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Edit homework',
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  onPressed: () =>
                                                      _editHomework(v),
                                                  icon: Icon(
                                                    Icons.edit_rounded,
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.65,
                                                        ),
                                                  ),
                                                ),
                                                if (v.homeworkText
                                                    .trim()
                                                    .isNotEmpty)
                                                  IconButton(
                                                    tooltip: 'Copy text',
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    onPressed: () =>
                                                        _copyHomeworkText(v),
                                                    icon: Icon(
                                                      Icons.copy_rounded,
                                                      color: Colors.black
                                                          .withValues(
                                                            alpha: 0.65,
                                                          ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            Text(
                                              _fmtTime(v.row.updatedAtMs),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.black.withValues(
                                                  alpha: 0.58,
                                                ),
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: v.reviewed
                                                    ? Colors.green.withValues(
                                                        alpha: 0.12,
                                                      )
                                                    : Colors.orange.withValues(
                                                        alpha: 0.12,
                                                      ),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Text(
                                                v.needsRedo
                                                    ? 'Redo'
                                                    : (v.reviewed
                                                          ? 'Reviewed'
                                                          : 'Not reviewed'),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w900,
                                                  color: v.needsRedo
                                                      ? Colors.orange.shade800
                                                      : (v.reviewed
                                                            ? Colors
                                                                  .green
                                                                  .shade800
                                                            : Colors
                                                                  .orange
                                                                  .shade800),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _HomeworkThreadRow {
  const _HomeworkThreadRow({
    required this.threadId,
    required this.peerUid,
    required this.peerName,
    required this.subject,
    required this.lastMessage,
    required this.updatedAtMs,
    required this.unreadCount,
    required this.deletedAtMs,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final int? deletedAtMs;
}

class _HomeworkThreadView {
  const _HomeworkThreadView({
    required this.row,
    required this.source,
    required this.courseTitle,
    required this.courseKey,
    required this.sessionId,
    required this.classId,
    required this.homeworkRefPath,
    required this.homeworkText,
    required this.homeworkDueDate,
    required this.submittedAtMs,
    required this.reviewed,
    required this.needsRedo,
    required this.reviewedAtMs,
    required this.reviewScore,
    required this.reviewGrade,
    required this.reviewStatus,
    required this.taughtTitle,
  });

  final _HomeworkThreadRow row;
  final _HomeworkSource source;
  final String courseTitle;
  final String courseKey;
  final String sessionId;
  final String classId;
  final String homeworkRefPath;
  final String homeworkText;
  final String homeworkDueDate;
  final int submittedAtMs;
  final bool reviewed;
  final bool needsRedo;
  final int reviewedAtMs;
  final int reviewScore;
  final String reviewGrade;
  final String reviewStatus;
  final String taughtTitle;

  int get unreadCount => row.unreadCount;
}
