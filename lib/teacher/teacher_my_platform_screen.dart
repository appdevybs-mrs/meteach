import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/course_feedback_service.dart';
import '../shared/profile_avatar.dart';
import 'teacher_mail_thread_screen.dart';

class TeacherMyPlatformScreen extends StatefulWidget {
  const TeacherMyPlatformScreen({super.key});

  @override
  State<TeacherMyPlatformScreen> createState() =>
      _TeacherMyPlatformScreenState();
}

enum _MyPlatformTab { needsReply, reported, recent, hidden }

class _MyPlatformItem {
  const _MyPlatformItem({
    required this.kind,
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
    required this.rating,
  });

  final String kind;
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
  final int rating;
}

class _TeacherMyPlatformScreenState extends State<TeacherMyPlatformScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _busy = true;
  String? _error;
  _MyPlatformTab _tab = _MyPlatformTab.needsReply;
  String _courseFilter = 'all';
  List<_MyPlatformItem> _all = const [];
  Set<String> _assignedCourseIds = const <String>{};

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
    });
    try {
      final assigned = await _loadAssignedCourses();
      final items = await _loadFeedbackItems(assigned);
      if (!mounted) return;
      setState(() {
        _assignedCourseIds = assigned;
        _all = items;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<Set<String>> _loadAssignedCourses() async {
    final out = <String>{};
    final snap = await _db.child('classes').get();
    if (!snap.exists || snap.value is! Map) return out;

    final classes = Map<dynamic, dynamic>.from(snap.value as Map);
    for (final entry in classes.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final m = value.map((k, v) => MapEntry(k.toString(), v));
      String currentUid = '';
      final cur = m['instructor_current'];
      if (cur is Map) {
        currentUid = (cur['uid'] ?? '').toString().trim();
      }
      if (currentUid != _uid) continue;

      final cid = (m['course_id'] ?? '').toString().trim();
      if (cid.isNotEmpty) out.add(cid);
    }
    return out;
  }

  Future<List<_MyPlatformItem>> _loadFeedbackItems(
    Set<String> courseIds,
  ) async {
    if (courseIds.isEmpty) return const [];

    final out = <_MyPlatformItem>[];

    for (final courseId in courseIds) {
      final reviewSnap = await _db
          .child('course_reviews')
          .child(courseId)
          .get();
      if (reviewSnap.exists && reviewSnap.value is Map) {
        final raw = Map<dynamic, dynamic>.from(reviewSnap.value as Map);
        for (final e in raw.entries) {
          if (e.value is! Map) continue;
          final m = (e.value as Map).map((k, v) => MapEntry('$k', v));
          final item = CourseReviewItem.fromMap(e.key.toString(), m);
          out.add(
            _MyPlatformItem(
              kind: 'review',
              courseId: courseId,
              lessonId: '',
              entryId: item.id,
              uid: item.uid,
              firstName: item.firstName,
              displayName: item.displayName,
              photoUrl: item.photoUrl,
              abbr: item.abbr,
              text: item.comment,
              status: item.status,
              reportCount: item.reportCount,
              createdAt: item.createdAt,
              rating: item.rating,
            ),
          );
        }
      }

      final commentsSnap = await _db
          .child('lesson_comments')
          .child(courseId)
          .get();
      if (commentsSnap.exists && commentsSnap.value is Map) {
        final lessons = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
        for (final lesson in lessons.entries) {
          final lessonId = lesson.key.toString();
          final comments = lesson.value;
          if (comments is! Map) continue;
          final cm = Map<dynamic, dynamic>.from(comments);
          for (final e in cm.entries) {
            if (e.value is! Map) continue;
            final m = (e.value as Map).map((k, v) => MapEntry('$k', v));
            final item = LessonCommentItem.fromMap(e.key.toString(), m);
            out.add(
              _MyPlatformItem(
                kind: 'comment',
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
                rating: 0,
              ),
            );
          }
        }
      }
    }

    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  List<_MyPlatformItem> get _filtered {
    return _all.where((x) {
      if (_courseFilter != 'all' && x.courseId != _courseFilter) return false;

      switch (_tab) {
        case _MyPlatformTab.needsReply:
          return x.kind == 'comment' && x.status == 'visible';
        case _MyPlatformTab.reported:
          return x.reportCount > 0;
        case _MyPlatformTab.recent:
          return x.status == 'visible';
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

  Future<void> _moderate(_MyPlatformItem item, String status) async {
    if (item.kind == 'review') {
      await CourseFeedbackService.moderateCourseReview(
        courseId: item.courseId,
        reviewId: item.entryId,
        status: status,
      );
    } else {
      await CourseFeedbackService.moderateLessonComment(
        courseId: item.courseId,
        lessonId: item.lessonId,
        commentId: item.entryId,
        status: status,
      );
    }
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

  Future<void> _messageLearner(_MyPlatformItem item) async {
    final subject = 'Course support: ${item.courseId}';
    final threadId = _threadIdFor(_uid, item.uid, item.courseId);
    final now = DateTime.now().millisecondsSinceEpoch;

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
        'body':
            'Hi ${item.firstName.isEmpty ? 'Learner' : item.firstName}, I saw your comment and wanted to help.',
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
          peerName: item.firstName.isEmpty ? 'Learner' : item.firstName,
          subject: subject,
        ),
      ),
    );
  }

  String _threadIdFor(String a, String b, String scope) {
    final ids = [a.trim(), b.trim()]..sort();
    return 'support_${scope}_${ids[0]}_${ids[1]}';
  }

  Widget _tabs() {
    Widget chip(_MyPlatformTab tab, String label) {
      final selected = _tab == tab;
      return ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _tab = tab),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(_MyPlatformTab.needsReply, 'Needs reply'),
        chip(_MyPlatformTab.reported, 'Reported'),
        chip(_MyPlatformTab.recent, 'Recent'),
        chip(_MyPlatformTab.hidden, 'Hidden'),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _tabs(),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _courseFilter,
                  decoration: const InputDecoration(
                    labelText: 'Course filter',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('All assigned courses'),
                    ),
                    ...courses.map(
                      (c) => DropdownMenuItem(value: c, child: Text(c)),
                    ),
                  ],
                  onChanged: (v) => setState(() => _courseFilter = v ?? 'all'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _busy
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  )
                : rows.isEmpty
                ? const Center(child: Text('No items in this view yet.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final item = rows[i];
                      return Container(
                        padding: const EdgeInsets.all(12),
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
                                ProfileAvatar(
                                  name: item.displayName,
                                  photoUrl: item.photoUrl,
                                  radius: 14,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${item.firstName.isEmpty ? 'Learner' : item.firstName} (${item.abbr.isEmpty ? 'L' : item.abbr})',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                Text(
                                  item.kind == 'review' ? 'Review' : 'Comment',
                                  style: TextStyle(
                                    color: item.kind == 'review'
                                        ? const Color(0xFF1D4ED8)
                                        : const Color(0xFF047857),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (item.kind == 'review')
                              Row(
                                children: List.generate(5, (idx) {
                                  return Icon(
                                    idx < item.rating
                                        ? Icons.star_rounded
                                        : Icons.star_border_rounded,
                                    size: 16,
                                    color: const Color(0xFFF59E0B),
                                  );
                                }),
                              ),
                            const SizedBox(height: 6),
                            Text(item.text),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Text(
                                  'Course: ${item.courseId}',
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                if (item.lessonId.isNotEmpty)
                                  Text(
                                    'Lesson: ${item.lessonId}',
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                const Spacer(),
                                Text(
                                  _fmtDate(item.createdAt),
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.tonal(
                                  onPressed: () => _moderate(item, 'visible'),
                                  child: const Text('Accept'),
                                ),
                                FilledButton.tonal(
                                  onPressed: () => _moderate(item, 'hidden'),
                                  child: const Text('Hide'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFB91C1C),
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: () => _moderate(item, 'removed'),
                                  child: const Text('Remove'),
                                ),
                                if (item.kind == 'comment')
                                  OutlinedButton(
                                    onPressed: () => _reply(item),
                                    child: const Text('Answer'),
                                  ),
                                OutlinedButton(
                                  onPressed: () => _messageLearner(item),
                                  child: const Text('Message learner'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
