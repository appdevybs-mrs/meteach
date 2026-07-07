import 'package:firebase_auth/firebase_auth.dart';
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

  bool _isTeacherLikeRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher' ||
        r == 'teachers' ||
        r == 'teacher(s)' ||
        r == 'instructor' ||
        r == 'oteacher' ||
        r == 'internationalteacher' ||
        r == 'international_teacher';
  }

  String _firstNonEmpty(Iterable<dynamic> values) {
    for (final value in values) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _classInstructorUid(Map<String, dynamic> cls) {
    final current = _safeMap(cls['instructor_current']);
    return (current['uid'] ?? '').toString().trim();
  }

  String _classInstructorName(Map<String, dynamic> cls) {
    final current = _safeMap(cls['instructor_current']);
    return _firstNonEmpty([
      current['name'],
      cls['teacherName'],
      cls['teacher_name'],
      cls['instructor'],
    ]);
  }

  Map<String, String> _instructorNamesByUid(Map<String, dynamic> courses) {
    final names = <String, String>{};
    for (final courseRaw in courses.values) {
      final course = _safeMap(courseRaw);

      final instructorsMap = _safeMap(course['instructors_map']);
      for (final entry in instructorsMap.entries) {
        final uid = entry.key.toString().trim();
        if (uid.isEmpty) continue;
        final instructor = _safeMap(entry.value);
        final name = (instructor['name'] ?? '').toString().trim();
        if (name.isNotEmpty) names.putIfAbsent(uid, () => name);
      }

      final instructors = course['instructors'];
      if (instructors is List) {
        for (final item in instructors) {
          final instructor = _safeMap(item);
          final uid = (instructor['uid'] ?? '').toString().trim();
          final name = instructor.isEmpty
              ? item.toString().trim()
              : (instructor['name'] ?? '').toString().trim();
          if (uid.isNotEmpty && name.isNotEmpty) {
            names.putIfAbsent(uid, () => name);
          }
        }
      } else if (instructors is Map) {
        final map = _safeMap(instructors);
        for (final entry in map.entries) {
          final instructor = _safeMap(entry.value);
          final uid = instructor.isEmpty
              ? entry.key.toString().trim()
              : (instructor['uid'] ?? entry.key).toString().trim();
          final name = instructor.isEmpty
              ? entry.value.toString().trim()
              : (instructor['name'] ?? '').toString().trim();
          if (uid.isNotEmpty && name.isNotEmpty) {
            names.putIfAbsent(uid, () => name);
          }
        }
      }
    }
    return names;
  }

  _TeacherHomeworkStats _teacherStatsFromIdentity({
    required String teacherUid,
    required Map<String, dynamic> users,
    String nameHint = '',
  }) {
    final uid = teacherUid.trim();
    final user = _safeMap(users[uid]);
    final fallback = nameHint.trim().isNotEmpty ? nameHint.trim() : 'Teacher';
    if (user.isEmpty) {
      return _TeacherHomeworkStats(
        teacherUid: uid,
        teacherName: fallback,
        photoUrl: '',
      );
    }

    return _TeacherHomeworkStats(
      teacherUid: uid,
      teacherName: _fullName(user, fallback),
      photoUrl: ProfileAvatar.resolvePhotoFromMap(user),
    );
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

  String _learnerNameFromUsers(Map<String, dynamic> users, String learnerUid) {
    final user = _safeMap(users[learnerUid]);
    if (user.isEmpty) return learnerUid;
    return _fullName(user, learnerUid);
  }

  _CurrentTeacherTarget _currentTeacherForClass(
    Map<String, dynamic> cls,
    Map<String, dynamic> users,
  ) {
    final current = _safeMap(cls['instructor_current']);
    var uid = (current['uid'] ?? '').toString().trim();
    var name = _classInstructorName(cls);
    if (uid.isEmpty) {
      final attendance = _safeMap(cls['attendance']);
      var bestTs = 0;
      for (final entry in attendance.entries) {
        final session = _safeMap(entry.value);
        final sessionUid =
            (session['teacherUid'] ?? session['teacher_uid'] ?? '')
                .toString()
                .trim();
        if (sessionUid.isEmpty) continue;
        final ts = _toInt(session['updatedAt']);
        if (ts >= bestTs) {
          bestTs = ts;
          uid = sessionUid;
          name = _firstNonEmpty([
            session['teacherName'],
            session['teacher_name'],
            name,
          ]);
        }
      }
    }
    if (uid.isEmpty) return const _CurrentTeacherTarget();
    final user = _safeMap(users[uid]);
    if (user.isNotEmpty) {
      name = _fullName(user, name.isEmpty ? 'Teacher' : name);
    }
    if (name.isEmpty) name = 'Teacher';
    return _CurrentTeacherTarget(uid: uid, name: name);
  }

  void _mergeHomeworkItem(
    Map<String, _HomeworkStatItem> itemsByRef, {
    required String homeworkRef,
    required String teacherUid,
    String teacherNameHint = '',
    String learnerUid = '',
    String learnerName = '',
    String classId = '',
    String courseKey = '',
    String sessionId = '',
    String threadId = '',
    _CurrentTeacherTarget targetTeacher = const _CurrentTeacherTarget(),
    bool overrideOwner = false,
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
        teacherNameHint: teacherNameHint.trim(),
        learnerUid: learnerUid.trim(),
        learnerName: learnerName.trim(),
        classId: classId.trim(),
        courseKey: courseKey.trim(),
        sessionId: sessionId.trim(),
        homeworkRef: cleanRef,
        threadId: threadId.trim(),
        targetTeacherUid: targetTeacher.uid,
        targetTeacherName: targetTeacher.name,
        sent: sent,
        submitted: _toInt(homework['submittedAt']) > 0,
        reviewed: _isReviewed(homework),
        score: _scoreFromHomework(homework),
      );
      return;
    }

    if (existing.teacherUid != cleanTeacher) {
      if (!overrideOwner) return;
      existing.teacherUid = cleanTeacher;
      existing.teacherNameHint = teacherNameHint.trim();
    }
    if (existing.teacherNameHint.isEmpty && teacherNameHint.trim().isNotEmpty) {
      existing.teacherNameHint = teacherNameHint.trim();
    }
    if (existing.learnerUid.isEmpty) existing.learnerUid = learnerUid.trim();
    if (existing.learnerName.isEmpty) existing.learnerName = learnerName.trim();
    if (existing.classId.isEmpty) existing.classId = classId.trim();
    if (existing.courseKey.isEmpty) existing.courseKey = courseKey.trim();
    if (existing.sessionId.isEmpty) existing.sessionId = sessionId.trim();
    if (existing.threadId.isEmpty) existing.threadId = threadId.trim();
    if (existing.targetTeacherUid.isEmpty && targetTeacher.uid.isNotEmpty) {
      existing.targetTeacherUid = targetTeacher.uid;
      existing.targetTeacherName = targetTeacher.name;
    }
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

  Map<String, List<_PendingHomeworkItem>> _groupPendingByLearner(
    List<_PendingHomeworkItem> items,
  ) {
    final grouped = <String, List<_PendingHomeworkItem>>{};
    for (final item in items) {
      final key = '${item.learnerUid}|${item.targetTeacherUid}';
      grouped.putIfAbsent(key, () => <_PendingHomeworkItem>[]).add(item);
    }
    return grouped;
  }

  Future<void> _showManagePendingDialog(_TeacherHomeworkStats stats) async {
    final items = stats.pendingItems;
    if (items.isEmpty) return;
    final transferable = items
        .where(
          (item) =>
              item.targetTeacherUid.isNotEmpty &&
              item.targetTeacherUid != item.ownerUid,
        )
        .toList();
    final groups = _groupPendingByLearner(items).values.toList()
      ..sort((a, b) {
        final an = a.first.learnerName.toLowerCase();
        final bn = b.first.learnerName.toLowerCase();
        return an.compareTo(bn);
      });

    if (!mounted) return;
    final action = await showDialog<_PendingAction>(
      context: context,
      builder: (ctx) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
          ),
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(22, 20, 16, 18),
                    decoration: const BoxDecoration(
                      color: _deepBlue,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.route_rounded,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Review pending homework routing',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Current owner: ${stats.teacherName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.82),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                    child: Row(
                      children: [
                        _DialogPill(
                          label: 'Pending',
                          value: '${items.length}',
                          color: _actionOrange,
                        ),
                        const SizedBox(width: 8),
                        _DialogPill(
                          label: 'Transferable',
                          value: '${transferable.length}',
                          color: Colors.green,
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
                      itemCount: groups.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, index) {
                        final group = groups[index];
                        final first = group.first;
                        final hasTarget = first.targetTeacherUid.isNotEmpty;
                        final sameOwner =
                            first.targetTeacherUid == first.ownerUid;
                        final targetLabel = hasTarget
                            ? first.targetTeacherName
                            : 'No current teacher found';
                        final targetColor = !hasTarget
                            ? Colors.red.shade700
                            : (sameOwner ? _deepBlue : Colors.green.shade700);
                        return Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: hasTarget
                                ? const Color(0xFFFAFCFF)
                                : const Color(0xFFFFF4F4),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: hasTarget
                                  ? _border
                                  : Colors.red.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: _primaryBlue.withValues(
                                  alpha: 0.10,
                                ),
                                foregroundColor: _primaryBlue,
                                child: Text(
                                  first.learnerName.trim().isEmpty
                                      ? '?'
                                      : first.learnerName.characters.first
                                            .toUpperCase(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      first.learnerName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _deepBlue,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      '${group.length} pending homework',
                                      style: TextStyle(
                                        color: Colors.black.withValues(
                                          alpha: 0.58,
                                        ),
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      sameOwner
                                          ? 'Already with'
                                          : 'Transfer to',
                                      style: TextStyle(
                                        color: Colors.black.withValues(
                                          alpha: 0.55,
                                        ),
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      targetLabel,
                                      textAlign: TextAlign.right,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: targetColor,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(28),
                      ),
                      border: Border(
                        top: BorderSide(
                          color: Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () =>
                              Navigator.pop(ctx, _PendingAction.clear),
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('Clear'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red.shade700,
                            side: BorderSide(
                              color: Colors.red.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: transferable.isEmpty
                              ? null
                              : () =>
                                    Navigator.pop(ctx, _PendingAction.transfer),
                          icon: const Icon(Icons.swap_horiz_rounded),
                          label: const Text('Transfer'),
                          style: FilledButton.styleFrom(
                            backgroundColor: _primaryBlue,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (action == _PendingAction.transfer) {
      await _transferPendingHomework(transferable);
    } else if (action == _PendingAction.clear) {
      await _confirmAndClearPendingHomework(items);
    }
  }

  Future<void> _transferPendingHomework(
    List<_PendingHomeworkItem> items,
  ) async {
    if (items.isEmpty) return;
    final adminUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, dynamic>{};

    for (final item in items) {
      if (item.homeworkRef.isEmpty || item.targetTeacherUid.isEmpty) continue;
      if (item.targetTeacherUid == item.ownerUid) continue;
      updates['${item.homeworkRef}/originalTeacherUid'] = item.ownerUid;
      updates['${item.homeworkRef}/originalTeacherName'] = item.ownerName;
      updates['${item.homeworkRef}/assignedTeacherUid'] = item.targetTeacherUid;
      updates['${item.homeworkRef}/assignedTeacherName'] =
          item.targetTeacherName;
      updates['${item.homeworkRef}/transferredFromUid'] = item.ownerUid;
      updates['${item.homeworkRef}/transferredFromName'] = item.ownerName;
      updates['${item.homeworkRef}/transferredToUid'] = item.targetTeacherUid;
      updates['${item.homeworkRef}/transferredToName'] = item.targetTeacherName;
      updates['${item.homeworkRef}/transferredAt'] = now;
      updates['${item.homeworkRef}/transferredBy'] = adminUid;
      updates['${item.homeworkRef}/routingStatus'] = 'transferred';

      final threadId = item.threadId.trim();
      if (threadId.isEmpty) continue;

      final threadSnap = await _db.child('mail_threads/$threadId').get();
      final thread = _safeMap(threadSnap.value);
      final subject = (thread['subject'] ?? 'Homework').toString();
      final lastMessage = (thread['lastMessage'] ?? '').toString();
      final updatedAt = _toInt(thread['updatedAt']) > 0
          ? _toInt(thread['updatedAt'])
          : now;

      updates['mail_threads/$threadId/teacherUid'] = item.targetTeacherUid;
      updates['mail_threads/$threadId/participants/${item.targetTeacherUid}'] =
          true;
      if (item.ownerUid.isNotEmpty) {
        updates['mail_threads/$threadId/participants/${item.ownerUid}'] = null;
        updates['mail_index/${item.ownerUid}/$threadId'] = null;
        updates['mail_state/${item.ownerUid}/$threadId'] = null;
      }

      updates['mail_index/${item.targetTeacherUid}/$threadId'] = {
        'peerUid': item.learnerUid,
        'peerName': item.learnerName.isEmpty ? 'Learner' : item.learnerName,
        'peerRole': 'learner',
        'subject': subject,
        'lastMessage': lastMessage,
        'updatedAt': updatedAt,
        'type': 'homework',
        'homeworkRef': item.homeworkRef,
        'deletedAt': null,
        'unreadCount': 1,
      };
      if (item.learnerUid.isNotEmpty) {
        updates['mail_index/${item.learnerUid}/$threadId/peerUid'] =
            item.targetTeacherUid;
        updates['mail_index/${item.learnerUid}/$threadId/peerName'] =
            item.targetTeacherName;
        updates['mail_index/${item.learnerUid}/$threadId/peerRole'] = 'teacher';
        updates['mail_index/${item.learnerUid}/$threadId/homeworkRef'] =
            item.homeworkRef;
      }
      updates['mail_state/${item.targetTeacherUid}/$threadId/lastDeliveredAt'] =
          now;
    }

    if (updates.isEmpty) return;
    await _db.update(updates);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Transferred ${items.length} homework item(s).')),
    );
    _refresh();
  }

  Future<void> _confirmAndClearPendingHomework(
    List<_PendingHomeworkItem> items,
  ) async {
    if (items.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear learner homework?'),
        content: Text(
          'This deletes ${items.length} learner homework submission(s) and removes related homework mail list entries. The class homework assignment remains.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final updates = <String, dynamic>{};
    for (final item in items) {
      if (item.homeworkRef.isNotEmpty) updates[item.homeworkRef] = null;
      final threadId = item.threadId.trim();
      if (threadId.isEmpty) continue;
      if (item.learnerUid.isNotEmpty) {
        updates['mail_index/${item.learnerUid}/$threadId'] = null;
        updates['mail_state/${item.learnerUid}/$threadId'] = null;
      }
      if (item.ownerUid.isNotEmpty) {
        updates['mail_index/${item.ownerUid}/$threadId'] = null;
        updates['mail_state/${item.ownerUid}/$threadId'] = null;
      }
      if (item.targetTeacherUid.isNotEmpty) {
        updates['mail_index/${item.targetTeacherUid}/$threadId'] = null;
        updates['mail_state/${item.targetTeacherUid}/$threadId'] = null;
      }
    }

    if (updates.isEmpty) return;
    await _db.update(updates);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cleared ${items.length} homework item(s).')),
    );
    _refresh();
  }

  Future<List<_TeacherHomeworkStats>> _loadStats() async {
    final usersSnap = await _db.child('users').get();
    final classesSnap = await _db.child('classes').get();
    final coursesSnap = await _db.child('courses').get();
    final threadsSnap = await _db.child('mail_threads').get();

    final users = _safeMap(usersSnap.value);
    final instructorNamesByUid = _instructorNamesByUid(
      _safeMap(coursesSnap.value),
    );
    final teachers = <String, _TeacherHomeworkStats>{};

    for (final entry in users.entries) {
      final uid = entry.key.toString().trim();
      final user = _safeMap(entry.value);
      final role = (user['role'] ?? '').toString().trim().toLowerCase();
      if (uid.isEmpty || !_isTeacherLikeRole(role)) continue;
      teachers[uid] = _teacherStatsFromIdentity(
        teacherUid: uid,
        users: users,
        nameHint: instructorNamesByUid[uid] ?? '',
      );
    }

    final itemsByRef = <String, _HomeworkStatItem>{};
    final classes = _safeMap(classesSnap.value);

    for (final classEntry in classes.entries) {
      final classId = classEntry.key.toString().trim();
      if (classId.isEmpty) continue;
      final cls = _safeMap(classEntry.value);
      final fallbackTeacherUid = _classInstructorUid(cls);
      final fallbackTeacherName = _classInstructorName(cls);
      final targetTeacher = _currentTeacherForClass(cls, users);
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
        final teacherNameHint = _firstNonEmpty([
          session['teacherName'],
          session['teacher_name'],
          fallbackTeacherName,
          instructorNamesByUid[teacherUid],
        ]);

        for (final learnerEntry in learners.entries) {
          final learnerUid = learnerEntry.key.toString().trim();
          if (learnerUid.isEmpty) continue;
          final learnerName = _learnerNameFromUsers(users, learnerUid);
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
            teacherNameHint: teacherNameHint,
            learnerUid: learnerUid,
            learnerName: learnerName,
            classId: classId,
            courseKey: courseKey,
            sessionId: sessionId,
            targetTeacher: targetTeacher,
            sent: true,
            homework: homework,
          );
        }
      }
    }

    final threadRefsToLoad = <String, _ThreadTeacherRef>{};
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
      final teacherNameHint = _firstNonEmpty([
        thread['teacherName'],
        thread['teacher_name'],
        instructorNamesByUid[teacherUid],
      ]);
      threadRefsToLoad[homeworkRef] = _ThreadTeacherRef(
        teacherUid: teacherUid,
        teacherNameHint: teacherNameHint,
        threadId: entry.key.toString().trim(),
        learnerUid: (thread['learnerUid'] ?? '').toString().trim(),
        courseKey: (thread['courseKey'] ?? '').toString().trim(),
        sessionId: (thread['sessionId'] ?? '').toString().trim(),
        classId: (thread['classId'] ?? '').toString().trim(),
      );
    }

    for (final entry in threadRefsToLoad.entries) {
      final homeworkRef = entry.key;
      final teacherRef = entry.value;
      final snap = await _db.child(homeworkRef).get();
      final homework = _safeMap(snap.value);
      if (homework.isEmpty) continue;
      var classId = teacherRef.classId;
      var learnerName = '';
      _CurrentTeacherTarget targetTeacher = const _CurrentTeacherTarget();
      if (teacherRef.learnerUid.isNotEmpty) {
        learnerName = _learnerNameFromUsers(users, teacherRef.learnerUid);
      }
      if (classId.isEmpty &&
          teacherRef.learnerUid.isNotEmpty &&
          teacherRef.courseKey.isNotEmpty) {
        final user = _safeMap(users[teacherRef.learnerUid]);
        final courses = _safeMap(user['courses']);
        final course = _safeMap(courses[teacherRef.courseKey]);
        final cls = _safeMap(course['class']);
        classId = (cls['class_id'] ?? '').toString().trim();
      }
      if (classId.isNotEmpty) {
        final cls = _safeMap(classes[classId]);
        targetTeacher = _currentTeacherForClass(cls, users);
      }
      _mergeHomeworkItem(
        itemsByRef,
        homeworkRef: homeworkRef,
        teacherUid: teacherRef.teacherUid,
        teacherNameHint: teacherRef.teacherNameHint,
        learnerUid: teacherRef.learnerUid,
        learnerName: learnerName,
        classId: classId,
        courseKey: teacherRef.courseKey,
        sessionId: teacherRef.sessionId,
        threadId: teacherRef.threadId,
        targetTeacher: targetTeacher,
        overrideOwner: true,
        sent: true,
        homework: homework,
      );
    }

    for (final item in itemsByRef.values) {
      final teacher = teachers.putIfAbsent(
        item.teacherUid,
        () => _teacherStatsFromIdentity(
          teacherUid: item.teacherUid,
          users: users,
          nameHint: _firstNonEmpty([
            item.teacherNameHint,
            instructorNamesByUid[item.teacherUid],
          ]),
        ),
      );
      if (item.sent) teacher.sent += 1;
      if (item.reviewed) teacher.reviewed += 1;
      if (item.submitted && !item.reviewed) teacher.pending += 1;
      if (item.submitted && !item.reviewed) {
        teacher.pendingItems.add(
          _PendingHomeworkItem(
            ownerUid: item.teacherUid,
            ownerName: teacher.teacherName,
            learnerUid: item.learnerUid,
            learnerName: item.learnerName.isEmpty
                ? item.learnerUid
                : item.learnerName,
            classId: item.classId,
            courseKey: item.courseKey,
            sessionId: item.sessionId,
            homeworkRef: item.homeworkRef,
            threadId: item.threadId,
            targetTeacherUid: item.targetTeacherUid,
            targetTeacherName: item.targetTeacherName,
          ),
        );
      }
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
                          return _TeacherStatsCard(
                            stats: rows[index],
                            onManage: () =>
                                _showManagePendingDialog(rows[index]),
                          );
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

class _DialogPill extends StatelessWidget {
  const _DialogPill({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.62),
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherStatsCard extends StatelessWidget {
  const _TeacherStatsCard({required this.stats, required this.onManage});

  final _TeacherHomeworkStats stats;
  final VoidCallback onManage;

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
                if (stats.pendingItems.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: onManage,
                    icon: const Icon(Icons.route_rounded, size: 17),
                    label: const Text('Manage'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                          _AdminLearnersFeedbackScreenState._deepBlue,
                      side: BorderSide(
                        color: _AdminLearnersFeedbackScreenState._deepBlue
                            .withValues(alpha: 0.24),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
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
    required this.teacherNameHint,
    required this.learnerUid,
    required this.learnerName,
    required this.classId,
    required this.courseKey,
    required this.sessionId,
    required this.homeworkRef,
    required this.threadId,
    required this.targetTeacherUid,
    required this.targetTeacherName,
    required this.sent,
    required this.submitted,
    required this.reviewed,
    required this.score,
  });

  String teacherUid;
  String teacherNameHint;
  String learnerUid;
  String learnerName;
  String classId;
  String courseKey;
  String sessionId;
  final String homeworkRef;
  String threadId;
  String targetTeacherUid;
  String targetTeacherName;
  bool sent;
  bool submitted;
  bool reviewed;
  int? score;
}

class _CurrentTeacherTarget {
  const _CurrentTeacherTarget({this.uid = '', this.name = ''});

  final String uid;
  final String name;
}

class _PendingHomeworkItem {
  const _PendingHomeworkItem({
    required this.ownerUid,
    required this.ownerName,
    required this.learnerUid,
    required this.learnerName,
    required this.classId,
    required this.courseKey,
    required this.sessionId,
    required this.homeworkRef,
    required this.threadId,
    required this.targetTeacherUid,
    required this.targetTeacherName,
  });

  final String ownerUid;
  final String ownerName;
  final String learnerUid;
  final String learnerName;
  final String classId;
  final String courseKey;
  final String sessionId;
  final String homeworkRef;
  final String threadId;
  final String targetTeacherUid;
  final String targetTeacherName;
}

enum _PendingAction { transfer, clear }

class _ThreadTeacherRef {
  const _ThreadTeacherRef({
    required this.teacherUid,
    required this.teacherNameHint,
    required this.threadId,
    required this.learnerUid,
    required this.courseKey,
    required this.sessionId,
    required this.classId,
  });

  final String teacherUid;
  final String teacherNameHint;
  final String threadId;
  final String learnerUid;
  final String courseKey;
  final String sessionId;
  final String classId;
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
  final List<_PendingHomeworkItem> pendingItems = <_PendingHomeworkItem>[];

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
