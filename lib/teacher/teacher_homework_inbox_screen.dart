import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/offline_action_guard.dart';
import '../shared/human_error.dart';
import '../shared/responsive_layout.dart';
import '../shared/teacher_web_layout.dart';
import '../services/audit_action_keys.dart';
import '../services/audit_log_service.dart';
import '../services/homework_cache_service.dart';
import '../services/homework_review_sync_service.dart';
import '../services/push_dispatch_service.dart';
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
  final Set<String> _locallyDeletedThreadIds = <String>{};
  final Map<String, bool> _localReviewedOverrideByHwRef = <String, bool>{};
  String? _desktopSelectedKey;
  bool _bulkMode = false;
  final Set<String> _selectedThreadIds = <String>{};
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _backgroundRefreshing = false;
  Timer? _searchDebounce;
  String? _expandedPendingClassKey;

  final Map<String, String> _courseTitleCache = <String, String>{};
  final Map<String, String> _classTitleCache = <String, String>{};
  final Map<String, String> _learnerNameCache = <String, String>{};

  @override
  void initState() {
    super.initState();
    _meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (_meUid.isNotEmpty) {
      final indexRef = _db.child('mail_index/$_meUid');
      indexRef.keepSynced(true);
      _indexStream = indexRef.onValue;
      _tryRestoreFromCache();
    }
  }

  void _tryRestoreFromCache() {
    final cache = HomeworkCacheService.instance;
    final key = '${_meUid}_views';
    final sigKey = '${_meUid}_signature';
    final cached = cache.retrieve<List<_HomeworkThreadView>>(key);
    final sig = cache.retrieve<String>(sigKey);
    if (cached != null && sig != null) {
      _viewsFuture = Future<List<_HomeworkThreadView>>.value(cached);
      _rowsSignature = sig;
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  bool _isHomework(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'homework') return true;

    final homeworkRef = (m['homeworkRef'] ?? '').toString().trim();
    if (homeworkRef.isNotEmpty) return true;

    final subject = (m['subject'] ?? '').toString().trim().toLowerCase();
    if (subject.startsWith('[hw]')) return true;
    return false;
  }

  String _displaySubject(String raw) {
    var s = raw.trim();
    while (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close <= 0) break;
      s = s.substring(close + 1).trimLeft();
    }
    return s;
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
    return HomeworkReviewSyncService.normalizeStatus(raw);
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
      if (_locallyDeletedThreadIds.contains(threadId)) return;

      out.add(
        _HomeworkThreadRow(
          threadId: threadId,
          peerUid: (m['peerUid'] ?? '').toString().trim(),
          peerName: ((m['peerName'] ?? '').toString().trim().isEmpty)
              ? 'Learner'
              : (m['peerName'] ?? '').toString().trim(),
          subject: (_displaySubject((m['subject'] ?? '').toString()).isEmpty)
              ? 'Homework'
              : _displaySubject((m['subject'] ?? '').toString()),
          lastMessage: (m['lastMessage'] ?? '').toString().trim(),
          updatedAtMs: _toInt(m['updatedAt']),
          unreadCount: _toInt(m['unreadCount'] ?? m['unread']),
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

    if (_viewsFuture != null && !_backgroundRefreshing) {
      _backgroundRefreshing = true;
      if (mounted) setState(() {});
      _viewsFuture = _composeViews(rows);
      return _viewsFuture!;
    }

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

    _storeViewsInCache(merged);
    if (mounted) {
      setState(() => _backgroundRefreshing = false);
    }

    return merged;
  }

  void _storeViewsInCache(List<_HomeworkThreadView> views) {
    if (_meUid.isEmpty) return;
    final cache = HomeworkCacheService.instance;
    cache.store('${_meUid}_views', views);
    cache.store('${_meUid}_signature', _rowsSignature);
    cache.store('${_meUid}_refreshedAt', DateTime.now().millisecondsSinceEpoch);
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

        final learnerName = _learnerNameCache.putIfAbsent(
          learnerUid,
          () => learnerUid,
        );
        if (learnerName == learnerUid) {
          _learnerNameCache[learnerUid] = await _learnerName(learnerUid);
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
                peerName: _learnerNameCache[learnerUid] ?? learnerUid,
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
        if (homeworkRefPath.isEmpty &&
            row.peerUid.isNotEmpty &&
            courseKey.isNotEmpty &&
            sessionId.isNotEmpty) {
          homeworkRefPath =
              'users/${row.peerUid}/courses/$courseKey/attendance/$sessionId/homework';
        }

        final hwSnap = homeworkRefPath.isNotEmpty
            ? await _db.child(homeworkRefPath).get()
            : null;
        if (hwSnap != null && hwSnap.exists && hwSnap.value is Map) {
          final hw = (hwSnap.value as Map).map((k, v) => MapEntry('$k', v));
          reviewedAt = _toInt(hw['reviewedAt']);
          submittedAtMs = _toInt(hw['submittedAt']);
          reviewStatus = _normalizeHomeworkStatus(hw['reviewStatus']);
          score = _toInt(hw['reviewScore']);
          grade = (hw['reviewGrade'] ?? '').toString().trim();
          needsRedo = hw['needsRedo'] == true || reviewStatus == 'redo';
          reviewed = reviewedAt > 0 || reviewStatus.isNotEmpty;
          homeworkText = (hw['text'] ?? hw['homeworkText'] ?? hw['note'] ?? '')
              .toString()
              .trim();
          homeworkDueDate = (hw['dueDate'] ?? '').toString().trim();
        }

        if (homeworkRefPath.isNotEmpty && !reviewed) {
          final repaired =
              await HomeworkReviewSyncService.repairHomeworkNodeFromThread(
                db: FirebaseDatabase.instance,
                threadId: row.threadId,
                homeworkRefPath: homeworkRefPath,
                lastMessage: row.lastMessage,
                updatedAt: row.updatedAtMs,
              );
          if (repaired != null) {
            reviewedAt = repaired.reviewedAt;
            reviewStatus = repaired.reviewStatus;
            score = repaired.reviewScore;
            grade = repaired.reviewGrade;
            needsRedo = repaired.needsRedo;
            reviewed = true;
          }
        }

        final needsCourseTitle =
            courseTitle.isEmpty ||
            courseTitle == courseKey ||
            courseTitle == 'Course not set';

        if (needsCourseTitle &&
            row.peerUid.isNotEmpty &&
            courseKey.isNotEmpty) {
          final cacheKey = '${row.peerUid}|$courseKey';
          final cachedTitle = _courseTitleCache[cacheKey];
          if (cachedTitle != null && cachedTitle.isNotEmpty) {
            courseTitle = cachedTitle;
          } else {
            final cSnap = await _db
                .child('users/${row.peerUid}/courses/$courseKey')
                .get();
            if (cSnap.exists && cSnap.value is Map) {
              final c = (cSnap.value as Map).map((k, v) => MapEntry('$k', v));
              final title = (c['title'] ?? c['course_title'] ?? '')
                  .toString()
                  .trim();
              if (title.isNotEmpty) {
                courseTitle = title;
                _courseTitleCache[cacheKey] = title;
              }

              if (classId.isEmpty && c['class'] is Map) {
                final cls = (c['class'] as Map).map(
                  (k, v) => MapEntry('$k', v),
                );
                classId = (cls['class_id'] ?? '').toString().trim();
                final classTitle = (cls['course_title'] ?? '')
                    .toString()
                    .trim();
                if (courseTitle.isEmpty && classTitle.isNotEmpty) {
                  courseTitle = classTitle;
                }
              }
            }
          }
        }

        if (classId.isNotEmpty &&
            (courseTitle.isEmpty || courseTitle == 'Course not set')) {
          final cachedClassTitle = _classTitleCache[classId];
          if (cachedClassTitle != null && cachedClassTitle.isNotEmpty) {
            courseTitle = cachedClassTitle;
          } else {
            final clsSnap = await _db.child('classes/$classId').get();
            if (clsSnap.exists && clsSnap.value is Map) {
              final c = (clsSnap.value as Map).map((k, v) => MapEntry('$k', v));
              final classCourseTitle =
                  (c['course_title'] ?? c['courseTitle'] ?? '')
                      .toString()
                      .trim();
              if (classCourseTitle.isNotEmpty) {
                courseTitle = classCourseTitle;
                _classTitleCache[classId] = classCourseTitle;
              }
            }
          }
        }

        if ((courseTitle.isEmpty || courseTitle == courseKey) &&
            courseKey.isNotEmpty) {
          final cachedCourseTitle = _courseTitleCache[courseKey];
          if (cachedCourseTitle != null && cachedCourseTitle.isNotEmpty) {
            courseTitle = cachedCourseTitle;
          } else {
            final courseSnap = await _db.child('courses/$courseKey').get();
            if (courseSnap.exists && courseSnap.value is Map) {
              final c = (courseSnap.value as Map).map(
                (k, v) => MapEntry('$k', v),
              );
              final t = (c['title'] ?? c['course_title'] ?? '')
                  .toString()
                  .trim();
              if (t.isNotEmpty) {
                courseTitle = t;
                _courseTitleCache[courseKey] = t;
              }
            }
          }
        }
      }
    } catch (_) {}

    final localOverride = _localReviewedOverrideByHwRef[homeworkRefPath.trim()];
    if (localOverride != null) {
      reviewed = localOverride;
      if (localOverride) {
        if (reviewedAt <= 0) {
          reviewedAt = DateTime.now().millisecondsSinceEpoch;
        }
        if (reviewStatus.isEmpty) reviewStatus = 'pass';
        needsRedo = false;
      } else {
        reviewedAt = 0;
        reviewStatus = '';
        needsRedo = false;
      }
    }

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

    await AuditLogService.logSuccess(
      actionKey: AuditActionKeys.teacherHomeworkEdit,
      domain: AuditDomain.homework,
      summary: 'Teacher edited homework for ${v.row.peerName}',
      actor: AuditActor(uid: _meUid, role: 'teacher'),
      target: AuditTarget(
        type: 'learner',
        uid: v.row.peerUid,
        id: v.sessionId,
        name: v.row.peerName,
      ),
      keywords: [v.courseKey, v.sessionId, v.row.threadId],
      context: {
        'courseKey': v.courseKey,
        'sessionId': v.sessionId,
        'threadId': v.row.threadId,
        'homeworkRefPath': v.homeworkRefPath,
      },
    );

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
    final tid = v.row.threadId.trim();
    if (tid.isNotEmpty) {
      _locallyDeletedThreadIds.add(tid);
      _rowsSignature = '';
      _viewsFuture = null;
      if (mounted) setState(() {});
    }
    try {
      await _db.child('mail_index/$_meUid/${v.row.threadId}').update({
        'deletedAt': now,
      });
    } catch (_) {
      if (tid.isNotEmpty) {
        _locallyDeletedThreadIds.remove(tid);
      }
      _rowsSignature = '';
      _viewsFuture = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> _deleteThreadIdsForMe(List<String> threadIds) async {
    final unique = threadIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (unique.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    _locallyDeletedThreadIds.addAll(unique);
    _rowsSignature = '';
    _viewsFuture = null;
    if (mounted) setState(() {});

    try {
      await Future.wait(
        unique.map(
          (tid) =>
              _db.child('mail_index/$_meUid/$tid').update({'deletedAt': now}),
        ),
      );
    } catch (_) {
      _locallyDeletedThreadIds.removeAll(unique);
      _rowsSignature = '';
      _viewsFuture = null;
      if (mounted) setState(() {});
    }
  }

  void _setBulkMode(bool enabled) {
    if (_bulkMode == enabled) return;
    setState(() {
      _bulkMode = enabled;
      if (!enabled) _selectedThreadIds.clear();
    });
  }

  void _toggleBulkSelection(String threadId) {
    final tid = threadId.trim();
    if (tid.isEmpty) return;
    setState(() {
      if (_selectedThreadIds.contains(tid)) {
        _selectedThreadIds.remove(tid);
      } else {
        _selectedThreadIds.add(tid);
      }
    });
  }

  void _selectAllVisible(List<_HomeworkThreadView> views) {
    final ids = views
        .map((v) => v.row.threadId.trim())
        .where((tid) => tid.isNotEmpty)
        .toSet();
    setState(() {
      _selectedThreadIds
        ..clear()
        ..addAll(ids);
    });
  }

  Future<void> _bulkDeleteSelected() async {
    if (_selectedThreadIds.isEmpty) return;
    final count = _selectedThreadIds.length;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete $count selected item${count == 1 ? '' : 's'}?'),
            content: const Text(
              'This hides the selected homework threads for you only. You can restore them later from Deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete selected'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    final ids = _selectedThreadIds.toList();
    await _deleteThreadIdsForMe(ids);
    if (!mounted) return;
    setState(() {
      _selectedThreadIds.clear();
      _bulkMode = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted $count item${count == 1 ? '' : 's'}'),
        duration: const Duration(milliseconds: 1300),
      ),
    );
  }

  Future<void> _restoreForMe(String threadId) async {
    final tid = threadId.trim();
    if (tid.isNotEmpty) _locallyDeletedThreadIds.remove(tid);
    await _db.child('mail_index/$_meUid/$threadId').update({'deletedAt': null});
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  Future<void> _markReviewed(_HomeworkThreadView v) async {
    if (v.homeworkRefPath.trim().isEmpty) return;
    final hwRef = v.homeworkRefPath.trim();
    _localReviewedOverrideByHwRef[hwRef] = true;
    if (mounted) setState(() {});
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await _db.child(v.homeworkRefPath).update({
        'reviewedAt': now,
        'reviewStatus': 'pass',
        'needsRedo': false,
        'reviewNote': 'Marked reviewed from homework inbox.',
      });
      await AuditLogService.logSuccess(
        actionKey: AuditActionKeys.teacherHomeworkReviewPass,
        domain: AuditDomain.homework,
        summary: 'Teacher marked homework reviewed for ${v.row.peerName}',
        actor: AuditActor(uid: _meUid, role: 'teacher'),
        target: AuditTarget(
          type: 'learner',
          uid: v.row.peerUid,
          id: v.sessionId,
          name: v.row.peerName,
        ),
        keywords: [v.courseKey, v.sessionId, v.row.threadId],
      );
      try {
        await PushDispatchService.dispatchMailToUser(
          targetUid: v.row.peerUid,
          threadId: v.row.threadId,
          peerUid: _meUid,
          title: 'Homework reviewed',
          preview: 'Your homework has been reviewed.',
          nowMs: now,
          context: const PushDispatchContext(
            screen: 'teacher/teacher_homework_inbox',
            action: 'homework_review_push',
          ),
        );
      } catch (_) {}
    } catch (_) {
      await AuditLogService.logFailure(
        actionKey: AuditActionKeys.teacherHomeworkReviewPass,
        domain: AuditDomain.homework,
        summary: 'Failed to mark homework reviewed',
        actor: AuditActor(uid: _meUid, role: 'teacher'),
        target: AuditTarget(
          type: 'learner',
          uid: v.row.peerUid,
          id: v.sessionId,
        ),
        keywords: [v.courseKey, v.sessionId],
      );
      _localReviewedOverrideByHwRef.remove(hwRef);
      if (mounted) setState(() {});
    }
  }

  Future<void> _markUnreviewed(_HomeworkThreadView v) async {
    if (v.homeworkRefPath.trim().isEmpty) return;
    final hwRef = v.homeworkRefPath.trim();
    _localReviewedOverrideByHwRef[hwRef] = false;
    if (mounted) setState(() {});
    try {
      await _db.child(v.homeworkRefPath).update({
        'reviewedAt': null,
        'reviewStatus': '',
        'reviewScore': null,
        'reviewGrade': '',
        'reviewNote': '',
        'needsRedo': false,
      });
      await AuditLogService.logSuccess(
        actionKey: AuditActionKeys.teacherHomeworkUnreview,
        domain: AuditDomain.homework,
        summary: 'Teacher removed homework review for ${v.row.peerName}',
        actor: AuditActor(uid: _meUid, role: 'teacher'),
        target: AuditTarget(
          type: 'learner',
          uid: v.row.peerUid,
          id: v.sessionId,
          name: v.row.peerName,
        ),
        keywords: [v.courseKey, v.sessionId, v.row.threadId],
      );
    } catch (_) {
      await AuditLogService.logFailure(
        actionKey: AuditActionKeys.teacherHomeworkUnreview,
        domain: AuditDomain.homework,
        summary: 'Failed to remove homework review',
        actor: AuditActor(uid: _meUid, role: 'teacher'),
        target: AuditTarget(
          type: 'learner',
          uid: v.row.peerUid,
          id: v.sessionId,
        ),
        keywords: [v.courseKey, v.sessionId],
      );
      _localReviewedOverrideByHwRef.remove(hwRef);
      if (mounted) setState(() {});
    }
  }

  List<_HomeworkThreadView> _applyFilter(List<_HomeworkThreadView> views) {
    List<_HomeworkThreadView> byTab;
    switch (_filter) {
      case _HomeworkFilter.notReviewed:
        byTab = views.where(_isPendingReviewView).toList();
        break;
      case _HomeworkFilter.reviewed:
        byTab = views
            .where((v) => v.source == _HomeworkSource.inbox && v.reviewed)
            .toList();
        break;
      case _HomeworkFilter.sent:
        byTab = views.where((v) => v.source == _HomeworkSource.sent).toList();
        break;
      case _HomeworkFilter.all:
        byTab = views;
        break;
    }

    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return byTab;
    return byTab.where((v) {
      final bag = <String>[
        v.row.peerName,
        v.courseTitle,
        v.classId,
        v.row.subject,
        v.row.lastMessage,
        v.homeworkText,
      ].join(' ').toLowerCase();
      return bag.contains(q);
    }).toList();
  }

  bool _isPendingReviewView(_HomeworkThreadView v) {
    return v.source == _HomeworkSource.inbox &&
        v.homeworkRefPath.trim().isNotEmpty &&
        v.submittedAtMs > 0 &&
        !v.reviewed;
  }

  String _pendingClassKey(_HomeworkThreadView v) {
    final classId = v.classId.trim();
    if (classId.isNotEmpty) return classId;
    final courseKey = v.courseKey.trim();
    if (courseKey.isNotEmpty) return 'course:$courseKey';
    final courseTitle = v.courseTitle.trim();
    if (courseTitle.isNotEmpty) return 'title:$courseTitle';
    return 'unknown';
  }

  String _pendingClassTitle(_HomeworkThreadView v) {
    final title = v.courseTitle.trim();
    if (title.isNotEmpty && title != 'Course not set') return title;
    final classId = v.classId.trim();
    if (classId.isNotEmpty) return 'Class $classId';
    return 'Class not set';
  }

  Map<String, List<_HomeworkThreadView>> _groupPendingByClass(
    List<_HomeworkThreadView> views,
  ) {
    final grouped = <String, List<_HomeworkThreadView>>{};
    for (final v in views) {
      final key = _pendingClassKey(v);
      grouped.putIfAbsent(key, () => <_HomeworkThreadView>[]).add(v);
    }
    return grouped;
  }

  void _openHomeworkView(_HomeworkThreadView v, bool desktopWorkspace) {
    if (desktopWorkspace) {
      setState(() => _desktopSelectedKey = _desktopViewKey(v));
      return;
    }
    if (_bulkMode) {
      final tid = v.row.threadId.trim();
      if (tid.isNotEmpty) _toggleBulkSelection(tid);
      return;
    }
    if (v.row.threadId.isNotEmpty) {
      unawaited(
        OfflineActionGuard.runExclusive(
          context,
          'teacher.homework_inbox.open.${v.row.threadId}',
          () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TeacherMailThreadScreen(
                  threadId: v.row.threadId,
                  peerUid: v.row.peerUid,
                  peerName: v.row.peerName,
                  subject: v.row.subject,
                ),
              ),
            );
          },
        ),
      );
      return;
    }
    _showDetails(v);
  }

  Widget _buildSearchBox() {
    return TextField(
      controller: _searchCtrl,
      onChanged: (value) {
        _searchDebounce?.cancel();
        _searchDebounce = Timer(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _searchQuery = value);
        });
      },
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search students, subjects or keywords...',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _searchQuery.trim().isEmpty
            ? const Icon(Icons.tune_rounded)
            : IconButton(
                tooltip: 'Clear search',
                onPressed: () {
                  _searchDebounce?.cancel();
                  _searchCtrl.clear();
                  setState(() => _searchQuery = '');
                },
                icon: const Icon(Icons.close_rounded),
              ),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.12)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.indigo.withValues(alpha: 0.35)),
        ),
      ),
    );
  }

  String _filterLabel(_HomeworkFilter f) {
    switch (f) {
      case _HomeworkFilter.all:
        return 'All';
      case _HomeworkFilter.notReviewed:
        return 'Pending';
      case _HomeworkFilter.reviewed:
        return 'Reviewed';
      case _HomeworkFilter.sent:
        return 'Sent';
    }
  }

  String _filterEmoji(_HomeworkFilter f) {
    switch (f) {
      case _HomeworkFilter.all:
        return '📚';
      case _HomeworkFilter.notReviewed:
        return '⏳';
      case _HomeworkFilter.reviewed:
        return '✅';
      case _HomeworkFilter.sent:
        return '📤';
    }
  }

  Color _filterColor(_HomeworkFilter f) {
    switch (f) {
      case _HomeworkFilter.all:
        return const Color(0xFF243B5A);
      case _HomeworkFilter.notReviewed:
        return const Color(0xFFEC740A);
      case _HomeworkFilter.reviewed:
        return const Color(0xFF15803D);
      case _HomeworkFilter.sent:
        return const Color(0xFF2563EB);
    }
  }

  String _initialsOf(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'HW';
    if (parts.length == 1) {
      final s = parts.first;
      final end = s.length < 2 ? s.length : 2;
      return s.substring(0, end).toUpperCase();
    }
    return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
  }

  Color _avatarTint(String seed) {
    final palette = <Color>[
      const Color(0xFFFDE9C9),
      const Color(0xFFD9F2F2),
      const Color(0xFFE4EEFF),
      const Color(0xFFF7DDEF),
    ];
    final idx = seed.hashCode.abs() % palette.length;
    return palette[idx];
  }

  Future<void> _openReviewPopup(_HomeworkThreadView v) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFFF8FAFD),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Homework Review',
                  style: TextStyle(
                    color: const Color(0xFF163B5D),
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  v.row.peerName,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Open this learner thread to review and submit feedback.',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF163B5D),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      if (v.row.threadId.isNotEmpty) {
                        unawaited(
                          OfflineActionGuard.runExclusive(
                            context,
                            'teacher.homework_inbox.review.${v.row.threadId}',
                            () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TeacherMailThreadScreen(
                                    threadId: v.row.threadId,
                                    peerUid: v.row.peerUid,
                                    peerName: v.row.peerName,
                                    subject: v.row.subject,
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.rate_review_rounded),
                    label: const Text('Open review popup'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _emptyStateText() {
    switch (_filter) {
      case _HomeworkFilter.notReviewed:
        return 'No pending homework. Everything looks reviewed.';
      case _HomeworkFilter.reviewed:
        return 'No reviewed homework yet.';
      case _HomeworkFilter.sent:
        return 'No sent homework yet.';
      case _HomeworkFilter.all:
        return 'No homework items found.';
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
            Text('Status: ${v.reviewed ? 'Reviewed' : 'Pending'}'),
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
    final reviewedCount = all
        .where((v) => v.source == _HomeworkSource.inbox && v.reviewed)
        .length;
    final notReviewedCount = all.where(_isPendingReviewView).length;
    final sentCount = all.where((v) => v.source == _HomeworkSource.sent).length;

    const tabs = <_HomeworkFilter>[
      _HomeworkFilter.all,
      _HomeworkFilter.notReviewed,
      _HomeworkFilter.reviewed,
      _HomeworkFilter.sent,
    ];
    final countByFilter = <_HomeworkFilter, int>{
      _HomeworkFilter.all: allCount,
      _HomeworkFilter.notReviewed: notReviewedCount,
      _HomeworkFilter.reviewed: reviewedCount,
      _HomeworkFilter.sent: sentCount,
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: tabs.map((f) {
          final selected = _filter == f;
          final color = _filterColor(f);
          final count = countByFilter[f] ?? 0;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => setState(() => _filter = f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: selected ? color : color.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: selected ? color : color.withValues(alpha: 0.28),
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.22),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_filterEmoji(f), style: const TextStyle(fontSize: 15)),
                    const SizedBox(width: 7),
                    Text(
                      _filterLabel(f),
                      style: TextStyle(
                        color: selected ? Colors.white : color,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.white.withValues(alpha: 0.18)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: selected
                              ? Colors.white.withValues(alpha: 0.22)
                              : color.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          color: selected ? Colors.white : color,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
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
    _backgroundRefreshing = true;
    if (mounted) setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  String _desktopViewKey(_HomeworkThreadView v) {
    final tid = v.row.threadId.trim();
    if (tid.isNotEmpty) return tid;
    return v.homeworkRefPath;
  }

  _HomeworkThreadView? _desktopSelectedView(List<_HomeworkThreadView> views) {
    if (views.isEmpty) return null;
    final selectedKey = _desktopSelectedKey?.trim() ?? '';
    if (selectedKey.isNotEmpty) {
      for (final view in views) {
        if (_desktopViewKey(view) == selectedKey) return view;
      }
    }
    return views.first;
  }

  Widget _buildDesktopSelectionPlaceholder() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Select a homework thread to review it in the larger desktop workspace.',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  Widget _buildDesktopHomeworkSummary(_HomeworkThreadView v) {
    final statusColor = v.reviewed
        ? Colors.green.shade700
        : Colors.orange.shade700;
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            v.row.peerName,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(v.reviewed ? 'Reviewed' : 'Pending')),
              Chip(
                label: Text(
                  v.source == _HomeworkSource.sent ? 'Sent' : 'Inbox',
                ),
              ),
              if (v.courseTitle.trim().isNotEmpty)
                Chip(label: Text(v.courseTitle)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                onPressed: v.reviewed ? null : () => _markReviewed(v),
                icon: const Icon(Icons.check_circle_rounded),
                label: const Text('Mark reviewed'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: v.reviewed ? () => _markUnreviewed(v) : null,
                icon: const Icon(Icons.undo_rounded),
                label: const Text('Mark not reviewed'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => _showDetails(v),
                icon: const Icon(Icons.info_outline_rounded),
                label: const Text('Details'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.reviewed ? 'Review status' : 'Homework text',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: statusColor,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  v.homeworkText.trim().isEmpty
                      ? 'No homework text available.'
                      : v.homeworkText.trim(),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingClassList(
    List<_HomeworkThreadView> pendingViews,
    List<_HomeworkThreadView> activeViews,
    bool desktopWorkspace,
  ) {
    final grouped = _groupPendingByClass(pendingViews);
    final groups = grouped.entries.toList()
      ..sort((a, b) {
        final aTitle = _pendingClassTitle(a.value.first).toLowerCase();
        final bTitle = _pendingClassTitle(b.value.first).toLowerCase();
        return aTitle.compareTo(bTitle);
      });

    return RefreshIndicator(
      onRefresh: _refreshInbox,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        itemCount: groups.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSearchBox(),
                  const SizedBox(height: 10),
                  _buildFilterBar(activeViews),
                  if (_backgroundRefreshing) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Updating...',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    'Pending review grouped by class',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.62),
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            );
          }

          final entry = groups[i - 1];
          final items = entry.value;
          final first = items.first;
          final expanded = _expandedPendingClassKey == entry.key;
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.orange.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    setState(() {
                      _expandedPendingClassKey = expanded ? null : entry.key;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3D6),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.groups_2_rounded,
                            color: Color(0xFFD97706),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _pendingClassTitle(first),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15.5,
                                ),
                              ),
                              if (first.classId.trim().isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  'Class ${first.classId.trim()}',
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD97706),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${items.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: const Color(0xFFD97706),
                        ),
                      ],
                    ),
                  ),
                ),
                if (expanded) ...[
                  Divider(
                    height: 1,
                    color: Colors.black.withValues(alpha: 0.08),
                  ),
                  ...items.map(
                    (v) => ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: _avatarTint(v.row.peerName),
                        child: Text(
                          _initialsOf(v.row.peerName),
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.65),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      title: Text(
                        v.row.peerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      subtitle: Text(
                        v.taughtTitle.trim().isNotEmpty
                            ? v.taughtTitle.trim()
                            : 'Submitted ${_fmtTime(v.submittedAtMs)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openHomeworkView(v, desktopWorkspace),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: AppBar(
        title: const Text('Homework Inbox'),
        actions: [
          IconButton(
            tooltip: _bulkMode ? 'Exit select mode' : 'Select multiple',
            onPressed: () => _setBulkMode(!_bulkMode),
            icon: Icon(
              _bulkMode
                  ? Icons.checklist_rtl_rounded
                  : Icons.check_box_outlined,
            ),
          ),
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
                      final selectedView = desktopWorkspace
                          ? _desktopSelectedView(views)
                          : null;

                      if (views.isEmpty) {
                        return RefreshIndicator(
                          onRefresh: _refreshInbox,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                            children: [
                              _buildSearchBox(),
                              const SizedBox(height: 10),
                              _buildFilterBar(activeViews),
                              if (_backgroundRefreshing) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Updating…',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 120),
                              Center(child: Text(_emptyStateText())),
                            ],
                          ),
                        );
                      }

                      final inboxList = RefreshIndicator(
                        onRefresh: _refreshInbox,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                          itemCount: views.length + 1,
                          itemBuilder: (context, i) {
                            if (i == 0) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _buildSearchBox(),
                                    const SizedBox(height: 10),
                                    _buildFilterBar(activeViews),
                                    if (_backgroundRefreshing) ...[
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          SizedBox(
                                            width: 12,
                                            height: 12,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                              color: Colors.grey.shade500,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Updating…',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade500,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    if (_bulkMode) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.withValues(
                                            alpha: 0.08,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: Colors.blue.withValues(
                                              alpha: 0.22,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                _selectedThreadIds.isEmpty
                                                    ? 'Select homework threads to delete'
                                                    : '${_selectedThreadIds.length} selected',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: () =>
                                                  _selectAllVisible(views),
                                              child: const Text('Select all'),
                                            ),
                                            TextButton(
                                              onPressed:
                                                  _selectedThreadIds.isEmpty
                                                  ? null
                                                  : () => setState(
                                                      _selectedThreadIds.clear,
                                                    ),
                                              child: const Text('Clear'),
                                            ),
                                            const SizedBox(width: 6),
                                            FilledButton.icon(
                                              onPressed:
                                                  _selectedThreadIds.isEmpty
                                                  ? null
                                                  : _bulkDeleteSelected,
                                              icon: const Icon(
                                                Icons.delete_outline_rounded,
                                              ),
                                              label: const Text('Delete'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            }

                            final v = views[i - 1];
                            final hasSubmission =
                                v.source == _HomeworkSource.inbox &&
                                (v.homeworkText.trim().isNotEmpty ||
                                    v.row.lastMessage.trim().isNotEmpty ||
                                    v.submittedAtMs > 0);
                            final waitingSubmission = !hasSubmission;
                            final isPending = hasSubmission && !v.reviewed;
                            final isReviewed = hasSubmission && v.reviewed;
                            final showReviewButton =
                                (_filter == _HomeworkFilter.notReviewed ||
                                    _filter == _HomeworkFilter.all) &&
                                isPending;
                            final statusLabel = waitingSubmission
                                ? 'Waiting for submission'
                                : (isReviewed ? 'Reviewed' : 'Pending');
                            final statusColor = waitingSubmission
                                ? const Color(0xFFB45309)
                                : (isReviewed
                                      ? Colors.green.shade800
                                      : const Color(0xFFEC740A));
                            final preview = v.row.lastMessage.trim();
                            final showPreview =
                                preview.isNotEmpty &&
                                preview.toLowerCase() != 'homework';
                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              color: waitingSubmission
                                  ? const Color(0xFFFFF5EB)
                                  : (isPending
                                        ? const Color(0xFFFFFBF4)
                                        : Colors.white),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onLongPress: v.row.threadId.isEmpty
                                    ? null
                                    : () => _deleteForMe(v),
                                onTap: () {
                                  _openHomeworkView(v, desktopWorkspace);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          CircleAvatar(
                                            radius: 24,
                                            backgroundColor: _avatarTint(
                                              v.row.peerName,
                                            ),
                                            child: Text(
                                              _initialsOf(v.row.peerName),
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: Colors.black.withValues(
                                                  alpha: 0.65,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Positioned(
                                            left: -2,
                                            top: -2,
                                            child: Container(
                                              width: 10,
                                              height: 10,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Colors.deepPurple,
                                                border: Border.all(
                                                  color: Colors.white,
                                                  width: 1.5,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 10),
                                      if (_bulkMode)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 2,
                                          ),
                                          child: Checkbox(
                                            value: _selectedThreadIds.contains(
                                              v.row.threadId.trim(),
                                            ),
                                            onChanged:
                                                v.row.threadId.trim().isEmpty
                                                ? null
                                                : (_) => _toggleBulkSelection(
                                                    v.row.threadId,
                                                  ),
                                          ),
                                        ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    v.row.peerName,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize: 14.5,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  _fmtTime(v.row.updatedAtMs),
                                                  textAlign: TextAlign.right,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.58,
                                                        ),
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: [
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 4,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFFEEE8FF,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          999,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    v.courseTitle,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: Color(0xFF5B33D6),
                                                      fontSize: 11.5,
                                                    ),
                                                  ),
                                                ),
                                                if (v.classId.isNotEmpty)
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 10,
                                                          vertical: 4,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xFFF2F4F8,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          Icons
                                                              .groups_2_outlined,
                                                          size: 13,
                                                          color: Colors.black
                                                              .withValues(
                                                                alpha: 0.55,
                                                              ),
                                                        ),
                                                        const SizedBox(
                                                          width: 4,
                                                        ),
                                                        Text(
                                                          v.classId,
                                                          style: TextStyle(
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            fontSize: 11.5,
                                                            color: Colors.black
                                                                .withValues(
                                                                  alpha: 0.62,
                                                                ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              'Homework ($statusLabel)',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: statusColor,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            if (showPreview)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 4,
                                                ),
                                                child: Text(
                                                  preview,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.58,
                                                        ),
                                                    fontSize: 11.5,
                                                  ),
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
                                                  margin: const EdgeInsets.only(
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
                                              PopupMenuButton<String>(
                                                tooltip: 'More actions',
                                                color: const Color(0xFFF5F8FC),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                  side: BorderSide(
                                                    color: const Color(
                                                      0xFF163B5D,
                                                    ).withValues(alpha: 0.12),
                                                  ),
                                                ),
                                                onSelected: (value) async {
                                                  if (value == 'details') {
                                                    _showDetails(v);
                                                    return;
                                                  }
                                                  if (value == 'edit') {
                                                    await _editHomework(v);
                                                    return;
                                                  }
                                                  if (value == 'copy') {
                                                    await _copyHomeworkText(v);
                                                    return;
                                                  }
                                                  if (value == 'delete') {
                                                    await _deleteForMe(v);
                                                  }
                                                },
                                                itemBuilder: (context) => [
                                                  const PopupMenuItem(
                                                    value: 'details',
                                                    child: ListTile(
                                                      dense: true,
                                                      leading: Icon(
                                                        Icons
                                                            .info_outline_rounded,
                                                        color: Color(
                                                          0xFF163B5D,
                                                        ),
                                                      ),
                                                      title: Text('Details'),
                                                    ),
                                                  ),
                                                  const PopupMenuItem(
                                                    value: 'edit',
                                                    child: ListTile(
                                                      dense: true,
                                                      leading: Icon(
                                                        Icons.edit_rounded,
                                                        color: Color(
                                                          0xFF1F4E79,
                                                        ),
                                                      ),
                                                      title: Text('Edit'),
                                                    ),
                                                  ),
                                                  if (v.homeworkText
                                                      .trim()
                                                      .isNotEmpty)
                                                    const PopupMenuItem(
                                                      value: 'copy',
                                                      child: ListTile(
                                                        dense: true,
                                                        leading: Icon(
                                                          Icons.copy_rounded,
                                                          color: Color(
                                                            0xFFEC740A,
                                                          ),
                                                        ),
                                                        title: Text(
                                                          'Copy Homework',
                                                        ),
                                                      ),
                                                    ),
                                                  const PopupMenuItem(
                                                    value: 'delete',
                                                    child: ListTile(
                                                      dense: true,
                                                      leading: Icon(
                                                        Icons
                                                            .delete_outline_rounded,
                                                        color: Color(
                                                          0xFFB42318,
                                                        ),
                                                      ),
                                                      title: Text(
                                                        'Delete for me',
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                                child: Container(
                                                  padding: const EdgeInsets.all(
                                                    4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFFEAF0F8,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  child: Icon(
                                                    Icons.more_vert_rounded,
                                                    color: const Color(
                                                      0xFF163B5D,
                                                    ).withValues(alpha: 0.9),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (showReviewButton) ...[
                                            const SizedBox(height: 8),
                                            SizedBox(
                                              width: 154,
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  gradient:
                                                      const LinearGradient(
                                                        colors: [
                                                          Color(0xFF1F4E79),
                                                          Color(0xFF163B5D),
                                                        ],
                                                      ),
                                                ),
                                                child: FilledButton(
                                                  onPressed: () =>
                                                      _openReviewPopup(v),
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor:
                                                        Colors.transparent,
                                                    shadowColor:
                                                        Colors.transparent,
                                                    foregroundColor:
                                                        Colors.white,
                                                    minimumSize:
                                                        const Size.fromHeight(
                                                          36,
                                                        ),
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 10,
                                                        ),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                    ),
                                                  ),
                                                  child: const Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Text(
                                                        'Review',
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w900,
                                                        ),
                                                      ),
                                                      SizedBox(width: 6),
                                                      Icon(
                                                        Icons
                                                            .chevron_right_rounded,
                                                        size: 18,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      );

                      final bodyList =
                          _filter == _HomeworkFilter.notReviewed && !_bulkMode
                          ? _buildPendingClassList(
                              views,
                              activeViews,
                              desktopWorkspace,
                            )
                          : inboxList;

                      if (!desktopWorkspace) return bodyList;

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 5, child: bodyList),
                          Container(
                            width: 1,
                            color: Colors.black.withValues(alpha: 0.08),
                          ),
                          Expanded(
                            flex: 6,
                            child: selectedView == null
                                ? _buildDesktopSelectionPlaceholder()
                                : (selectedView.row.threadId.isNotEmpty
                                      ? TeacherMailThreadScreen(
                                          key: ValueKey(
                                            'desktop_hw_${selectedView.row.threadId}',
                                          ),
                                          threadId: selectedView.row.threadId,
                                          peerUid: selectedView.row.peerUid,
                                          peerName: selectedView.row.peerName,
                                          subject: selectedView.row.subject,
                                        )
                                      : _buildDesktopHomeworkSummary(
                                          selectedView,
                                        )),
                          ),
                        ],
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
