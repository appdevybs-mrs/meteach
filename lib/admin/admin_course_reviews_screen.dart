import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/course_feedback_service.dart';
import '../shared/profile_avatar.dart';

class AdminCourseReviewsScreen extends StatefulWidget {
  const AdminCourseReviewsScreen({super.key});

  @override
  State<AdminCourseReviewsScreen> createState() =>
      _AdminCourseReviewsScreenState();
}

enum _AdminFeedbackTab { reviews, comments }

class _AdminLessonCommentRow {
  const _AdminLessonCommentRow({
    required this.item,
    required this.courseId,
    required this.lessonId,
  });

  final LessonCommentItem item;
  final String courseId;
  final String lessonId;
}

class _AdminCourseReviewsScreenState extends State<AdminCourseReviewsScreen> {
  bool _busy = true;
  String? _error;

  _AdminFeedbackTab _tab = _AdminFeedbackTab.reviews;
  bool _binMode = false;
  String _courseFilter = 'all';
  String _statusFilter = 'all';

  List<CourseReviewItem> _reviews = const [];
  List<_AdminLessonCommentRow> _comments = const [];
  final Map<String, String> _courseTitleById = <String, String>{};

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
      final db = FirebaseDatabase.instance.ref();
      final results = await Future.wait([
        db.child('course_reviews').get(),
        db.child('lesson_comments').get(),
        db.child('courses').get(),
      ]);

      final reviews = <CourseReviewItem>[];
      final reviewsSnap = results[0];
      if (reviewsSnap.exists && reviewsSnap.value is Map) {
        final byCourse = Map<dynamic, dynamic>.from(reviewsSnap.value as Map);
        for (final c in byCourse.entries) {
          final courseId = c.key.toString();
          if (c.value is! Map) continue;
          final map = Map<dynamic, dynamic>.from(c.value as Map);
          for (final r in map.entries) {
            if (r.value is! Map) continue;
            final m = (r.value as Map).map((k, v) => MapEntry('$k', v));
            reviews.add(
              CourseReviewItem.fromMap(r.key.toString(), {
                ...m,
                'courseId': (m['courseId'] ?? courseId).toString(),
              }),
            );
          }
        }
      }

      final comments = <_AdminLessonCommentRow>[];
      final commentsSnap = results[1];
      if (commentsSnap.exists && commentsSnap.value is Map) {
        final byCourse = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
        for (final c in byCourse.entries) {
          final courseId = c.key.toString();
          if (c.value is! Map) continue;
          final byLesson = Map<dynamic, dynamic>.from(c.value as Map);
          for (final l in byLesson.entries) {
            final lessonId = l.key.toString();
            if (l.value is! Map) continue;
            final cm = Map<dynamic, dynamic>.from(l.value as Map);
            for (final item in cm.entries) {
              if (item.value is! Map) continue;
              final m = (item.value as Map).map((k, v) => MapEntry('$k', v));
              comments.add(
                _AdminLessonCommentRow(
                  item: LessonCommentItem.fromMap(item.key.toString(), {
                    ...m,
                    'courseId': (m['courseId'] ?? courseId).toString(),
                    'lessonId': (m['lessonId'] ?? lessonId).toString(),
                  }),
                  courseId: courseId,
                  lessonId: lessonId,
                ),
              );
            }
          }
        }
      }

      final titleMap = <String, String>{};
      final coursesSnap = results[2];
      if (coursesSnap.exists && coursesSnap.value is Map) {
        final byId = Map<dynamic, dynamic>.from(coursesSnap.value as Map);
        for (final c in byId.entries) {
          if (c.value is! Map) continue;
          final m = (c.value as Map).map((k, v) => MapEntry('$k', v));
          final id = c.key.toString();
          final title = (m['title'] ?? m['course_title'] ?? '')
              .toString()
              .trim();
          final code = (m['course_code'] ?? '').toString().trim();
          titleMap[id] = title.isEmpty
              ? (code.isEmpty ? id : code)
              : (code.isEmpty ? title : '$title ($code)');
        }
      }

      reviews.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      comments.sort((a, b) => b.item.createdAt.compareTo(a.item.createdAt));

      if (!mounted) return;
      setState(() {
        _reviews = reviews;
        _comments = comments;
        _courseTitleById
          ..clear()
          ..addAll(titleMap);
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

  String _courseLabel(String id) => _courseTitleById[id] ?? id;

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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

  Future<void> _moderateReview(CourseReviewItem item, String status) async {
    await CourseFeedbackService.moderateCourseReview(
      courseId: item.courseId,
      reviewId: item.id,
      status: status,
    );
    await _load();
  }

  Future<void> _moderateComment(
    _AdminLessonCommentRow row,
    String status,
  ) async {
    await CourseFeedbackService.moderateLessonComment(
      courseId: row.courseId,
      lessonId: row.lessonId,
      commentId: row.item.id,
      status: status,
    );
    await _load();
  }

  List<CourseReviewItem> get _filteredReviews {
    return _reviews.where((r) {
      if (_courseFilter != 'all' && r.courseId != _courseFilter) return false;
      if (_binMode) return r.status == 'removed';
      if (r.status == 'removed') return false;
      if (_statusFilter != 'all' && r.status != _statusFilter) return false;
      return true;
    }).toList();
  }

  List<_AdminLessonCommentRow> get _filteredComments {
    return _comments.where((r) {
      if (_courseFilter != 'all' && r.courseId != _courseFilter) return false;
      if (_binMode) return r.item.status == 'removed';
      if (r.item.status == 'removed') return false;
      if (_statusFilter != 'all' && r.item.status != _statusFilter)
        return false;
      return true;
    }).toList();
  }

  Widget _buildFilters(List<String> courseIds) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _courseFilter,
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
                ...courseIds.map(
                  (id) => DropdownMenuItem(
                    value: id,
                    child: Text(
                      _courseLabel(id),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _courseFilter = v ?? 'all'),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 142,
            child: DropdownButtonFormField<String>(
              value: _statusFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(value: 'pending', child: Text('Pending')),
                DropdownMenuItem(value: 'visible', child: Text('Visible')),
                DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
              ],
              onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stars(int rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < rating ? Icons.star_rounded : Icons.star_border_rounded,
          size: 14,
          color: const Color(0xFFF59E0B),
        );
      }),
    );
  }

  PopupMenuButton<String> _actionsMenu(void Function(String) onSelect) {
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      icon: const Text(
        '!',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w900,
          color: Color(0xFF0F172A),
        ),
      ),
      onSelected: onSelect,
      itemBuilder: (_) => _binMode
          ? const [
              PopupMenuItem(value: 'visible', child: Text('Restore')),
              PopupMenuItem(value: 'hidden', child: Text('Restore as hidden')),
            ]
          : const [
              PopupMenuItem(value: 'visible', child: Text('Accept')),
              PopupMenuItem(value: 'hidden', child: Text('Hide')),
              PopupMenuItem(value: 'removed', child: Text('Remove')),
            ],
    );
  }

  Widget _reviewCard(CourseReviewItem r) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 7, 7, 7),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfileAvatar(
                name: r.displayName,
                photoUrl: r.photoUrl,
                radius: 11,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  r.firstName.isEmpty ? 'Learner' : r.firstName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                _fmtDate(r.createdAt),
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.52),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              _actionsMenu((v) => _moderateReview(r, v)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _stars(r.rating),
              const SizedBox(width: 6),
              _statusChip(r.status),
              const SizedBox(width: 8),
              if (r.reportCount > 0)
                Text(
                  'Reports ${r.reportCount}',
                  style: const TextStyle(
                    color: Color(0xFFB45309),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            r.comment,
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: Colors.black.withValues(alpha: 0.78),
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentCard(_AdminLessonCommentRow row) {
    final c = row.item;
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 7, 7, 7),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfileAvatar(
                name: c.displayName,
                photoUrl: c.photoUrl,
                radius: 11,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  c.firstName.isEmpty ? 'Learner' : c.firstName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                _fmtDate(c.createdAt),
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.52),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              _actionsMenu((v) => _moderateComment(row, v)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _statusChip(c.status),
              const SizedBox(width: 8),
              if (c.reportCount > 0)
                Text(
                  'Reports ${c.reportCount}',
                  style: const TextStyle(
                    color: Color(0xFFB45309),
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              const Spacer(),
              Flexible(
                child: Text(
                  _courseLabel(row.courseId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.55),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            c.text,
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: Colors.black.withValues(alpha: 0.78),
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final courseIds = {
      ..._reviews.map((e) => e.courseId),
      ..._comments.map((e) => e.courseId),
    }.where((x) => x.trim().isNotEmpty).toList()..sort();

    final reviewRows = _filteredReviews;
    final commentRows = _filteredComments;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Course Feedback Moderation'),
        actions: [
          IconButton(
            tooltip: _binMode ? 'Show active items' : 'Open bin',
            onPressed: () => setState(() => _binMode = !_binMode),
            icon: Icon(
              _binMode
                  ? Icons.restore_from_trash_rounded
                  : Icons.delete_outline_rounded,
            ),
          ),
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
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SegmentedButton<_AdminFeedbackTab>(
              segments: const [
                ButtonSegment(
                  value: _AdminFeedbackTab.reviews,
                  icon: Icon(Icons.reviews_rounded),
                  label: Text('Course Reviews'),
                ),
                ButtonSegment(
                  value: _AdminFeedbackTab.comments,
                  icon: Icon(Icons.forum_rounded),
                  label: Text('Lesson Comments'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (set) {
                if (set.isEmpty) return;
                setState(() => _tab = set.first);
              },
            ),
          ),
          _buildFilters(courseIds),
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
                : _tab == _AdminFeedbackTab.reviews
                ? (reviewRows.isEmpty
                      ? Center(
                          child: Text(
                            _binMode
                                ? 'No removed reviews in bin.'
                                : 'No reviews match current filters.',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                          itemCount: reviewRows.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (_, i) => _reviewCard(reviewRows[i]),
                        ))
                : (commentRows.isEmpty
                      ? Center(
                          child: Text(
                            _binMode
                                ? 'No removed comments in bin.'
                                : 'No lesson comments match current filters.',
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                          itemCount: commentRows.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (_, i) => _commentCard(commentRows[i]),
                        )),
          ),
        ],
      ),
    );
  }
}
