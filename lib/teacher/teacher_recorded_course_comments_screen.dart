import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/learner_web_layout.dart';
import '../shared/profile_avatar.dart';
import '../services/course_feedback_service.dart';
import '../services/internal_mail_service.dart';
import 'teacher_learner_profile_screen.dart';
import 'teacher_mail_thread_screen.dart';
import 'teacher_reminder.dart';

class TeacherRecordedCourseCommentsScreen extends StatefulWidget {
  const TeacherRecordedCourseCommentsScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
    required this.courseCode,
    this.initialFilterPending = false,
  });

  final String courseId;
  final String courseTitle;
  final String courseCode;
  final bool initialFilterPending;

  @override
  State<TeacherRecordedCourseCommentsScreen> createState() =>
      _TeacherRecordedCourseCommentsScreenState();
}

enum _CourseCommentFilter {
  approved,
  all,
  pending,
  reported,
  removed,
  notApproved,
}

class _RecordedLessonMeta {
  const _RecordedLessonMeta({
    required this.id,
    required this.title,
    required this.sessionNumber,
    required this.hasVideo,
  });

  final String id;
  final String title;
  final int sessionNumber;
  final bool hasVideo;
}

class _CommentGroup {
  _CommentGroup({
    required this.dateKey,
    required this.lessonId,
    required this.items,
  });

  final String dateKey;
  final String lessonId;
  final List<LessonCommentItem> items;

  int get latestCreatedAt => items.fold<int>(
    0,
    (latest, item) => item.createdAt > latest ? item.createdAt : latest,
  );
}

class _TeacherRecordedCourseCommentsScreenState
    extends State<TeacherRecordedCourseCommentsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final Set<String> _expandedReplies = <String>{};
  final Map<String, List<Map<String, dynamic>>> _repliesByComment = {};
  final Set<String> _loadingReplies = <String>{};
  final Map<String, int> _replyCountByComment = {};
  int _replyAvailabilityRequestId = 0;
  StreamSubscription<DatabaseEvent>? _commentsSub;

  bool _busy = true;
  bool _posting = false;
  bool _deletingPermanently = false;
  String? _error;
  late _CourseCommentFilter _filter;
  final Set<String> _selectedRemovedCommentIds = <String>{};

  List<LessonCommentItem> _comments = const [];
  Map<String, _RecordedLessonMeta> _lessonMetaById = const {};

  String get _courseId => widget.courseId.trim();

  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilterPending
        ? _CourseCommentFilter.pending
        : _CourseCommentFilter.all;
    _loadComments();
    _commentsSub = _db
        .child('lesson_comments')
        .child(_courseId)
        .onValue
        .listen((_) => _loadComments());
  }

  @override
  void dispose() {
    _commentsSub?.cancel();
    super.dispose();
  }

  String _normalizedStatus(String raw) {
    return CourseFeedbackService.normalizeLessonCommentStatus(raw);
  }

  String _fmtDateTime(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _fmtDateKey(int ms) {
    if (ms <= 0) return 'Unknown date';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  bool _isApproved(LessonCommentItem item) =>
      _normalizedStatus(item.status) == CourseFeedbackService.statusVisible;
  bool _isPending(LessonCommentItem item) =>
      _normalizedStatus(item.status) == CourseFeedbackService.statusPending;
  bool _isNotApproved(LessonCommentItem item) =>
      _normalizedStatus(item.status) == CourseFeedbackService.statusNotApproved;
  bool _isRemoved(LessonCommentItem item) =>
      _normalizedStatus(item.status) == CourseFeedbackService.statusRemoved;
  bool _isReported(LessonCommentItem item) =>
      item.reportCount > 0 && !_isRemoved(item);

  List<LessonCommentItem> get _filteredComments {
    return _comments.where((item) {
      switch (_filter) {
        case _CourseCommentFilter.approved:
          return _isApproved(item);
        case _CourseCommentFilter.all:
          return true;
        case _CourseCommentFilter.pending:
          return _isPending(item);
        case _CourseCommentFilter.reported:
          return _isReported(item);
        case _CourseCommentFilter.removed:
          return _isRemoved(item);
        case _CourseCommentFilter.notApproved:
          return _isNotApproved(item);
      }
    }).toList();
  }

  Future<void> _loadComments() async {
    setState(() {
      _busy = true;
      _error = null;
      _repliesByComment.clear();
      _expandedReplies.clear();
      _loadingReplies.clear();
      _replyCountByComment.clear();
      _replyAvailabilityRequestId += 1;
    });

    try {
      final results = await Future.wait<DataSnapshot>([
        _db.child('lesson_comments').child(_courseId).get(),
        _db.child('syllabi').child(_courseId).child('recorded').get(),
      ]);
      final snap = results[0];
      final lessonMetaById = _parseLessonMeta(results[1].value);
      final out = <LessonCommentItem>[];
      if (snap.exists && snap.value is Map) {
        final lessons = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final lessonEntry in lessons.entries) {
          final lessonId = lessonEntry.key.toString();
          if (lessonEntry.value is! Map) continue;
          final comments = Map<dynamic, dynamic>.from(lessonEntry.value as Map);
          for (final entry in comments.entries) {
            if (entry.value is! Map) continue;
            final map = (entry.value as Map).map((k, v) => MapEntry('$k', v));
            out.add(
              LessonCommentItem.fromMap(entry.key.toString(), {
                ...map,
                'lessonId': lessonId,
                'courseId': _courseId,
              }),
            );
          }
        }
      }

      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (!mounted) return;
      setState(() {
        _comments = out;
        _lessonMetaById = lessonMetaById;
        _busy = false;
      });
      _refreshReplyCountsForVisibleComments();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  List<Map<String, dynamic>> _mapsFrom(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((item) => item.map((k, v) => MapEntry('$k', v)))
          .toList();
    }
    if (raw is Map) {
      return raw.values
          .whereType<Map>()
          .map((item) => item.map((k, v) => MapEntry('$k', v)))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  Map<String, _RecordedLessonMeta> _parseLessonMeta(dynamic raw) {
    final out = <String, _RecordedLessonMeta>{};
    if (raw is! Map) return out;
    final root = raw.map((k, v) => MapEntry('$k', v));

    void addLesson(dynamic lessonRaw, int fallbackNumber) {
      if (lessonRaw is! Map) return;
      final lesson = lessonRaw.map((k, v) => MapEntry('$k', v));
      final id = (lesson['id'] ?? '').toString().trim();
      if (id.isEmpty) return;
      final number = CourseFeedbackService.asInt(
        lesson['sessionNumber'] ?? lesson['lessonNumber'] ?? lesson['order'],
      );
      out[id] = _RecordedLessonMeta(
        id: id,
        title: (lesson['title'] ?? '').toString().trim(),
        sessionNumber: number > 0 ? number : fallbackNumber,
        hasVideo: (lesson['videoUrl'] ?? '').toString().trim().isNotEmpty,
      );
    }

    final modules = _mapsFrom(root['modules']);
    if (modules.isNotEmpty) {
      var fallbackNumber = 0;
      for (final module in modules) {
        for (final unit in _mapsFrom(module['units'])) {
          for (final lesson in _mapsFrom(unit['lessons'])) {
            fallbackNumber += 1;
            addLesson(lesson, fallbackNumber);
          }
        }
      }
      return out;
    }

    var fallbackNumber = 0;
    for (final unit in _mapsFrom(root['units'])) {
      for (final session in _mapsFrom(unit['sessions'])) {
        fallbackNumber += 1;
        addLesson(session, fallbackNumber);
      }
    }
    return out;
  }

  String _lessonLabel(String lessonId) {
    final safeLessonId = lessonId.trim();
    final meta = _lessonMetaById[safeLessonId];
    if (meta == null) {
      return 'Lesson ${safeLessonId.isEmpty ? '-' : safeLessonId}';
    }

    final title = meta.title.trim();
    final number = meta.sessionNumber;
    final prefix = meta.hasVideo ? 'Video' : 'Lesson';
    if (number > 0 && title.isNotEmpty) return '$prefix $number: $title';
    if (title.isNotEmpty) return title;
    if (number > 0) return '$prefix $number';
    return 'Lesson ${safeLessonId.isEmpty ? '-' : safeLessonId}';
  }

  List<_CommentGroup> _groupComments(List<LessonCommentItem> comments) {
    final groupsByKey = <String, _CommentGroup>{};
    for (final item in comments) {
      final dateKey = _fmtDateKey(item.createdAt);
      final lessonId = item.lessonId.trim();
      final key = '$dateKey\u0000$lessonId';
      final group = groupsByKey.putIfAbsent(
        key,
        () => _CommentGroup(
          dateKey: dateKey,
          lessonId: lessonId,
          items: <LessonCommentItem>[],
        ),
      );
      group.items.add(item);
    }

    final groups = groupsByKey.values.toList();
    for (final group in groups) {
      group.items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    groups.sort((a, b) {
      final cmp = b.latestCreatedAt.compareTo(a.latestCreatedAt);
      if (cmp != 0) return cmp;
      return _lessonLabel(
        a.lessonId,
      ).toLowerCase().compareTo(_lessonLabel(b.lessonId).toLowerCase());
    });
    return groups;
  }

  Future<void> _ensureRepliesLoaded(LessonCommentItem item) async {
    if (_repliesByComment.containsKey(item.id) ||
        _loadingReplies.contains(item.id)) {
      return;
    }
    setState(() => _loadingReplies.add(item.id));
    try {
      final replies = await CourseFeedbackService.listLessonReplies(
        _courseId,
        item.lessonId,
        item.id,
      );
      if (!mounted) return;
      setState(() {
        _repliesByComment[item.id] = replies;
        _replyCountByComment[item.id] = replies.length;
        _loadingReplies.remove(item.id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingReplies.remove(item.id));
    }
  }

  Future<void> _refreshReplyCountsForVisibleComments() async {
    final requestId = ++_replyAvailabilityRequestId;
    final candidates = _filteredComments
        .where((item) => !_replyCountByComment.containsKey(item.id))
        .toList();
    if (candidates.isEmpty) return;

    final counts = <String, int>{};
    await Future.wait(
      candidates.map((item) async {
        try {
          final snap = await _db
              .child(CourseFeedbackService.lessonRepliesNode)
              .child(_courseId)
              .child(item.lessonId)
              .child(item.id)
              .get();
          if (snap.exists && snap.value is Map) {
            final raw = Map<dynamic, dynamic>.from(snap.value as Map);
            counts[item.id] = raw.length;
          } else {
            counts[item.id] = 0;
          }
        } catch (_) {
          counts[item.id] = 0;
        }
      }),
    );

    if (!mounted || requestId != _replyAvailabilityRequestId) return;
    setState(() => _replyCountByComment.addAll(counts));
  }

  Future<void> _moderate(LessonCommentItem item, String status) async {
    if (status == 'delete_permanently') {
      final ok = await _confirmPermanentDelete(count: 1);
      if (!ok) return;
      setState(() => _deletingPermanently = true);
      try {
        await CourseFeedbackService.deleteLessonCommentPermanently(
          courseId: _courseId,
          lessonId: item.lessonId,
          commentId: item.id,
        );
        if (!mounted) return;
        _selectedRemovedCommentIds.remove(item.id);
        AppToast.show(context, 'Comment permanently deleted.');
        await _loadComments();
      } finally {
        if (mounted) setState(() => _deletingPermanently = false);
      }
      return;
    }
    if (status == CourseFeedbackService.statusNotApproved) {
      final teacher = FirebaseAuth.instance.currentUser;
      final teacherUid = teacher?.uid ?? '';
      final teacherName = teacher?.displayName ?? 'Teacher';
      final lessonTitle =
          _lessonMetaById[item.lessonId]?.title.trim().isEmpty == false
          ? _lessonMetaById[item.lessonId]!.title.trim()
          : item.lessonId;
      await CourseFeedbackService.archiveAndDeleteLessonComment(
        courseId: _courseId,
        lessonId: item.lessonId,
        commentId: item.id,
        actorUid: teacherUid,
        actorName: teacherName,
        reason: 'not_approved',
        context: <String, dynamic>{
          'courseTitle': widget.courseTitle,
          'lessonTitle': lessonTitle,
          'learnerUid': item.uid,
          'learnerName': item.displayName,
        },
      );
      try {
        await InternalMailService.sendAutoMail(
          senderUid: teacherUid,
          senderName: teacherName,
          senderRole: 'teacher',
          receiverUid: item.uid,
          receiverName: item.displayName.trim().isEmpty
              ? 'Learner'
              : item.displayName.trim(),
          receiverRole: 'learner',
          subject: 'Learning Reflection Needs Improvement',
          body:
              '$lessonTitle\n\n'
              'Dear ${item.firstName.trim().isEmpty ? 'Learner' : item.firstName.trim()},\n\n'
              'Thank you for writing your learning reflection.\n\n'
              'Please watch the lesson carefully and submit a revised reflection that clearly connects to the lesson topic.\n\n'
              'Best regards,\n$teacherName',
        );
      } catch (_) {}
      if (mounted) {
        AppToast.show(
          context,
          'Reflection rejected, removed, and learner notified.',
        );
      }
      await _loadComments();
      return;
    }
    await CourseFeedbackService.moderateLessonComment(
      courseId: _courseId,
      lessonId: item.lessonId,
      commentId: item.id,
      status: status,
    );
    await _loadComments();
  }

  Future<bool> _confirmPermanentDelete({required int count}) async {
    final label = count == 1 ? 'this comment' : '$count comments';
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text(
          'This will permanently delete $label with all replies and reports. This cannot be undone.',
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return res == true;
  }

  Future<void> _deleteSelectedRemovedComments(
    List<LessonCommentItem> removedItems,
  ) async {
    if (_selectedRemovedCommentIds.isEmpty) return;
    final selected = removedItems
        .where((item) => _selectedRemovedCommentIds.contains(item.id))
        .toList();
    if (selected.isEmpty) return;

    final ok = await _confirmPermanentDelete(count: selected.length);
    if (!ok) return;

    setState(() => _deletingPermanently = true);
    var deleted = 0;
    try {
      for (final item in selected) {
        try {
          await CourseFeedbackService.deleteLessonCommentPermanently(
            courseId: _courseId,
            lessonId: item.lessonId,
            commentId: item.id,
          );
          deleted += 1;
        } catch (_) {}
      }
      if (!mounted) return;
      _selectedRemovedCommentIds.clear();
      AppToast.show(
        context,
        'Permanently deleted $deleted/${selected.length}.',
      );
      await _loadComments();
    } finally {
      if (mounted) setState(() => _deletingPermanently = false);
    }
  }

  Future<void> _reply(LessonCommentItem item) async {
    final c = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Reply to learner',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: c,
                    maxLength: 400,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Write your reply...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('Send'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (ok != true) return;
    final text = c.text.trim();
    if (text.isEmpty) return;

    setState(() => _posting = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) {
        throw Exception('Missing teacher account.');
      }

      await CourseFeedbackService.addLessonReply(
        courseId: _courseId,
        lessonId: item.lessonId,
        commentId: item.id,
        uid: uid,
        text: text,
      );
      await _loadComments();
      if (!mounted) return;
      AppToast.show(context, 'Reply posted.');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        humanizeUiMessage(e.toString()),
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  int get _totalComments => _comments.length;
  int get _pendingCount => _comments.where(_isPending).length;
  int get _reportedCount => _comments.where(_isReported).length;
  int get _approvedCount => _comments.where(_isApproved).length;
  int get _notApprovedCount => _comments.where(_isNotApproved).length;
  int get _removedCount => _comments.where(_isRemoved).length;

  String _threadIdFor(String a, String b, String scope) {
    final ids = [a.trim(), b.trim()]..sort();
    return 'support_${scope}_${ids[0]}_${ids[1]}';
  }

  Future<void> _openLearnerProfile(LessonCommentItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeacherLearnerProfileScreen(
          learnerUid: item.uid,
          learnerName: item.displayName,
          initialCourseTitle: widget.courseTitle,
        ),
      ),
    );
  }

  Future<void> _openLearnerMail(LessonCommentItem item) async {
    final meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (meUid.isEmpty || item.uid.trim().isEmpty) return;

    final subject = 'Course support: ${widget.courseTitle}';
    final threadId = _threadIdFor(meUid, item.uid, widget.courseId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final threadRef = _db.child('mail_threads').child(threadId);
    final snap = await threadRef.get();
    if (!snap.exists) {
      await threadRef.set({
        'participants': {meUid: true, item.uid: true},
        'subject': subject,
        'type': 'mail',
        'createdAt': now,
        'updatedAt': now,
        'lastMessage':
            'Hi ${item.displayName}, I wanted to help with your comment.',
        'lastMessageAt': now,
      });
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeacherMailThreadScreen(
          threadId: threadId,
          peerUid: item.uid,
          peerName: item.displayName,
          subject: subject,
        ),
      ),
    );
  }

  Future<void> _openLearnerReminder(LessonCommentItem item) async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const TeacherReminderScreen()));
  }

  void _showLearnerActions(LessonCommentItem item) {
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
                    name: item.displayName,
                    photoUrl: item.photoUrl,
                    radius: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.displayName,
                      style: const TextStyle(
                        fontSize: 16,
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

  void _showStats() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Course statistics'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Comments: $_totalComments'),
            Text('Approved: $_approvedCount'),
            Text('Not approved: $_notApprovedCount'),
            Text('Pending: $_pendingCount'),
            Text('Reported: $_reportedCount'),
            Text('Removed: $_removedCount'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(_CourseCommentFilter filter, String label, Color color) {
    final selected = _filter == filter;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        setState(() {
          _filter = filter;
          if (_filter != _CourseCommentFilter.removed) {
            _selectedRemovedCommentIds.clear();
          }
        });
        _refreshReplyCountsForVisibleComments();
      },
      labelStyle: TextStyle(
        fontWeight: FontWeight.w800,
        color: selected ? color : const Color(0xFF475569),
      ),
      selectedColor: color.withValues(alpha: 0.14),
      backgroundColor: Colors.white,
      side: BorderSide(color: color.withValues(alpha: selected ? 0.36 : 0.16)),
    );
  }

  Color _statusColor(String status) {
    switch (_normalizedStatus(status)) {
      case 'pending':
        return const Color(0xFFF59E0B);
      case 'visible':
        return const Color(0xFF10B981);
      case 'not_approved':
        return const Color(0xFF9333EA);
      case 'hidden':
        return const Color(0xFF64748B);
      case 'removed':
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF475569);
    }
  }

  Widget _statusChip(String status) {
    final normalized = _normalizedStatus(status);
    final color = _statusColor(normalized);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        normalized.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _commentGroupHeader(_CommentGroup group) {
    final count = group.items.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFEFF6FF), Color(0xFFF8FAFC)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF2563EB).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.video_library_rounded,
              color: Color(0xFF1D4ED8),
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.dateKey,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _lessonLabel(group.lessonId),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w900,
                    fontSize: 13.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFDBEAFE)),
            ),
            child: Text(
              '$count comment${count == 1 ? '' : 's'}',
              style: const TextStyle(
                color: Color(0xFF1D4ED8),
                fontWeight: FontWeight.w900,
                fontSize: 10.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentCard(LessonCommentItem item, {required bool removedView}) {
    final replies = _repliesByComment[item.id] ?? const [];
    final loadingReplies = _loadingReplies.contains(item.id);
    final expanded = _expandedReplies.contains(item.id);
    final replyCount = _replyCountByComment[item.id] ?? replies.length;
    final hasReplies = replyCount > 0 || replies.isNotEmpty;
    final visibleReplies = expanded ? replies : const <Map<String, dynamic>>[];

    final accent = _statusColor(item.status);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => _showLearnerActions(item),
                borderRadius: BorderRadius.circular(999),
                child: ProfileAvatar(
                  name: item.displayName,
                  photoUrl: item.photoUrl,
                  radius: 16,
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
                            item.firstName.isEmpty ? 'Learner' : item.firstName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        Text(
                          _fmtDateTime(item.createdAt),
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (removedView)
                          Checkbox(
                            value: _selectedRemovedCommentIds.contains(item.id),
                            onChanged: _deletingPermanently
                                ? null
                                : (v) {
                                    setState(() {
                                      if (v == true) {
                                        _selectedRemovedCommentIds.add(item.id);
                                      } else {
                                        _selectedRemovedCommentIds.remove(
                                          item.id,
                                        );
                                      }
                                    });
                                  },
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _statusChip(item.status),
                        const SizedBox(width: 8),
                        if (_isReported(item))
                          const Text(
                            'Reported',
                            style: TextStyle(
                              color: Color(0xFFF97316),
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF6FF),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                _lessonLabel(item.lessonId),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF1D4ED8),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        item.text.trim(),
                        style: const TextStyle(
                          color: Color(0xFF334155),
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_isPending(item)) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _posting
                      ? null
                      : () => _moderate(
                          item,
                          CourseFeedbackService.statusVisible,
                        ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: const Text('Approve'),
                ),
                OutlinedButton.icon(
                  onPressed: _posting
                      ? null
                      : () => _moderate(
                          item,
                          CourseFeedbackService.statusNotApproved,
                        ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                    side: const BorderSide(color: Color(0xFFFECACA)),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  icon: const Icon(Icons.error_outline_rounded, size: 16),
                  label: const Text('Not approve'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _posting ? null : () => _reply(item),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE0F2FE),
                  foregroundColor: const Color(0xFF0369A1),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                icon: const Icon(Icons.reply_rounded, size: 16),
                label: const Text('Reply'),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: PopupMenuButton<String>(
                  tooltip: 'More actions',
                  icon: const Icon(Icons.more_horiz_rounded, size: 18),
                  onSelected: (choice) => _moderate(item, choice),
                  itemBuilder: (_) => [
                    if (!_isApproved(item))
                      const PopupMenuItem(
                        value: 'visible',
                        child: Text('Approve'),
                      ),
                    if (!_isNotApproved(item))
                      const PopupMenuItem(
                        value: CourseFeedbackService.statusNotApproved,
                        child: Text('Not approve'),
                      ),
                    const PopupMenuItem(value: 'hidden', child: Text('Hide')),
                    if (_isRemoved(item))
                      const PopupMenuItem(
                        value: 'delete_permanently',
                        child: Text('Delete permanently'),
                      )
                    else
                      const PopupMenuItem(
                        value: 'removed',
                        child: Text('Remove'),
                      ),
                  ],
                ),
              ),
              if (removedView) ...[
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _deletingPermanently
                      ? null
                      : () => _moderate(item, 'delete_permanently'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFEE2E2),
                    foregroundColor: const Color(0xFFB91C1C),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  icon: const Icon(Icons.delete_forever_rounded, size: 16),
                  label: const Text('Delete permanently'),
                ),
              ],
              const Spacer(),
              if (hasReplies)
                OutlinedButton.icon(
                  onPressed: () async {
                    if (expanded) {
                      setState(() => _expandedReplies.remove(item.id));
                      return;
                    }
                    await _ensureRepliesLoaded(item);
                    if (!mounted) return;
                    if ((_repliesByComment[item.id] ?? const []).isEmpty) {
                      return;
                    }
                    setState(() => _expandedReplies.add(item.id));
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF1D4ED8),
                    side: const BorderSide(color: Color(0xFFBFDBFE)),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  icon: Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                  ),
                  label: Text(
                    expanded
                        ? 'Hide replies ($replyCount)'
                        : 'Show replies ($replyCount)',
                  ),
                ),
            ],
          ),
          if (loadingReplies)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (expanded && replies.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final reply in visibleReplies)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ProfileAvatar(
                      name: (reply['displayName'] ?? 'User').toString(),
                      photoUrl: (reply['photoUrl'] ?? '').toString(),
                      radius: 11,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  (reply['firstName'] ?? 'User').toString(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11.5,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              Text(
                                _fmtDateTime(
                                  CourseFeedbackService.asInt(
                                    reply['createdAt'],
                                  ),
                                ),
                                style: const TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            (reply['text'] ?? '').toString(),
                            style: const TextStyle(
                              color: Color(0xFF334155),
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _statsButton() {
    return IconButton(
      tooltip: 'Statistics',
      onPressed: _showStats,
      icon: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: const Color(0xFFFDE68A),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: const Text(
          '!',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 18,
            color: Color(0xFF92400E),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final comments = _filteredComments;
    final groups = _groupComments(comments);
    final removedView = _filter == _CourseCommentFilter.removed;
    final removedVisibleComments = comments.where(_isRemoved).toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Course Reflection'),
            Text(
              widget.courseTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Removed reflections',
            onPressed: () => setState(() {
              _filter = _CourseCommentFilter.removed;
            }),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1100,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: RefreshIndicator(
              onRefresh: _loadComments,
              child: Column(
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _filterChip(
                        _CourseCommentFilter.all,
                        'All',
                        const Color(0xFF1D4ED8),
                      ),
                      _filterChip(
                        _CourseCommentFilter.pending,
                        'Pending',
                        const Color(0xFFF59E0B),
                      ),
                      _filterChip(
                        _CourseCommentFilter.notApproved,
                        'Rejected',
                        const Color(0xFF9333EA),
                      ),
                      _filterChip(
                        _CourseCommentFilter.approved,
                        'Approved',
                        const Color(0xFF16A34A),
                      ),
                    ],
                  ),
                  if (removedView) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF7ED),
                        border: Border.all(color: const Color(0xFFFED7AA)),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.tonal(
                            onPressed: _deletingPermanently
                                ? null
                                : () {
                                    setState(() {
                                      _selectedRemovedCommentIds
                                        ..clear()
                                        ..addAll(
                                          removedVisibleComments.map(
                                            (e) => e.id,
                                          ),
                                        );
                                    });
                                  },
                            child: const Text('Select all loaded'),
                          ),
                          OutlinedButton(
                            onPressed: _deletingPermanently
                                ? null
                                : () => setState(
                                    () => _selectedRemovedCommentIds.clear(),
                                  ),
                            child: const Text('Clear'),
                          ),
                          FilledButton.icon(
                            onPressed:
                                _deletingPermanently ||
                                    _selectedRemovedCommentIds.isEmpty
                                ? null
                                : () => _deleteSelectedRemovedComments(
                                    removedVisibleComments,
                                  ),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFB91C1C),
                            ),
                            icon: const Icon(Icons.delete_forever_rounded),
                            label: Text(
                              _deletingPermanently
                                  ? 'Deleting...'
                                  : 'Delete selected (${_selectedRemovedCommentIds.length})',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Expanded(
                    child: _busy
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                        ? Center(
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : comments.isEmpty
                        ? const Center(
                            child: Text('No comments for this course yet.'),
                          )
                        : ListView.builder(
                            itemCount: groups.length,
                            itemBuilder: (_, index) {
                              final group = groups[index];
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _commentGroupHeader(group),
                                  for (final item in group.items)
                                    _commentCard(
                                      item,
                                      removedView: removedView,
                                    ),
                                ],
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _miniStatChip(String label, int value, Color bg, Color fg) {
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
}
