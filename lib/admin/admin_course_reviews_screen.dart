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

      final reviewsSnap = results[0];
      final commentsSnap = results[1];
      final coursesSnap = results[2];

      final reviews = <CourseReviewItem>[];
      if (reviewsSnap.exists && reviewsSnap.value is Map) {
        final courses = Map<dynamic, dynamic>.from(reviewsSnap.value as Map);
        for (final cEntry in courses.entries) {
          final courseId = cEntry.key.toString();
          final reviewsMap = cEntry.value;
          if (reviewsMap is! Map) continue;
          final rawReviews = Map<dynamic, dynamic>.from(reviewsMap);
          for (final rEntry in rawReviews.entries) {
            if (rEntry.value is! Map) continue;
            final m = (rEntry.value as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            );
            final item = CourseReviewItem.fromMap(rEntry.key.toString(), {
              ...m,
              'courseId': (m['courseId'] ?? courseId).toString(),
            });
            reviews.add(item);
          }
        }
      }

      final comments = <_AdminLessonCommentRow>[];
      if (commentsSnap.exists && commentsSnap.value is Map) {
        final byCourse = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
        for (final cEntry in byCourse.entries) {
          final courseId = cEntry.key.toString();
          final byLesson = cEntry.value;
          if (byLesson is! Map) continue;
          final lessons = Map<dynamic, dynamic>.from(byLesson);
          for (final lEntry in lessons.entries) {
            final lessonId = lEntry.key.toString();
            final commentsMap = lEntry.value;
            if (commentsMap is! Map) continue;
            final rawComments = Map<dynamic, dynamic>.from(commentsMap);
            for (final x in rawComments.entries) {
              if (x.value is! Map) continue;
              final m = (x.value as Map).map((k, v) => MapEntry('$k', v));
              final item = LessonCommentItem.fromMap(x.key.toString(), {
                ...m,
                'courseId': (m['courseId'] ?? courseId).toString(),
                'lessonId': (m['lessonId'] ?? lessonId).toString(),
              });
              comments.add(
                _AdminLessonCommentRow(
                  item: item,
                  courseId: courseId,
                  lessonId: lessonId,
                ),
              );
            }
          }
        }
      }

      final titleMap = <String, String>{};
      if (coursesSnap.exists && coursesSnap.value is Map) {
        final raw = Map<dynamic, dynamic>.from(coursesSnap.value as Map);
        for (final entry in raw.entries) {
          final id = entry.key.toString();
          final value = entry.value;
          if (value is! Map) continue;
          final m = value.map((k, v) => MapEntry('$k', v));
          final title = (m['title'] ?? m['course_title'] ?? '')
              .toString()
              .trim();
          final code = (m['course_code'] ?? '').toString().trim();
          final label = title.isEmpty
              ? (code.isEmpty ? id : code)
              : (code.isEmpty ? title : '$title ($code)');
          titleMap[id] = label;
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
        _busy = false;
        _error = e.toString();
      });
    }
  }

  List<CourseReviewItem> get _filteredReviews {
    return _reviews.where((r) {
      if (_courseFilter != 'all' && r.courseId != _courseFilter) return false;
      if (_statusFilter != 'all' && r.status != _statusFilter) return false;
      return true;
    }).toList();
  }

  List<_AdminLessonCommentRow> get _filteredComments {
    return _comments.where((r) {
      if (_courseFilter != 'all' && r.courseId != _courseFilter) return false;
      if (_statusFilter != 'all' && r.item.status != _statusFilter)
        return false;
      return true;
    }).toList();
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _courseLabel(String courseId) {
    return _courseTitleById[courseId] ?? courseId;
  }

  Future<void> _moderateReview(CourseReviewItem item, String status) async {
    await CourseFeedbackService.moderateCourseReview(
      courseId: item.courseId,
      reviewId: item.id,
      status: status,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Review set to "$status"')));
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
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Comment set to "$status"')));
    await _load();
  }

  Widget _stars(int rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < rating ? Icons.star_rounded : Icons.star_border_rounded,
          size: 16,
          color: const Color(0xFFF59E0B),
        );
      }),
    );
  }

  Widget _buildFilters(List<String> courseIds) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _courseFilter,
              decoration: const InputDecoration(
                labelText: 'Course',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              selectedItemBuilder: (_) {
                final labels = ['All courses', ...courseIds.map(_courseLabel)];
                return labels
                    .map(
                      (x) =>
                          Text(x, overflow: TextOverflow.ellipsis, maxLines: 1),
                    )
                    .toList();
              },
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
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _courseFilter = v ?? 'all'),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 155,
            child: DropdownButtonFormField<String>(
              value: _statusFilter,
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(value: 'visible', child: Text('Visible')),
                DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
                DropdownMenuItem(value: 'removed', child: Text('Removed')),
              ],
              onChanged: (v) => setState(() => _statusFilter = v ?? 'all'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewsList() {
    final rows = _filteredReviews;
    if (rows.isEmpty)
      return const Center(child: Text('No reviews match current filters.'));
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final r = rows[i];
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
                    name: r.displayName,
                    photoUrl: r.photoUrl,
                    radius: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${r.firstName.isEmpty ? 'Learner' : r.firstName} (${r.abbr.isEmpty ? 'L' : r.abbr})',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      _courseLabel(r.courseId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.58),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _stars(r.rating),
                  const SizedBox(width: 8),
                  Text(
                    'Status: ${r.status}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 8),
                  if (r.reportCount > 0)
                    Text(
                      'Reports: ${r.reportCount}',
                      style: const TextStyle(
                        color: Color(0xFFB45309),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  const Spacer(),
                  Text(
                    _fmtDate(r.createdAt),
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(r.comment),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: () => _moderateReview(r, 'visible'),
                    child: const Text('Accept'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _moderateReview(r, 'hidden'),
                    child: const Text('Hide'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB91C1C),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _moderateReview(r, 'removed'),
                    child: const Text('Remove'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _commentsList() {
    final rows = _filteredComments;
    if (rows.isEmpty)
      return const Center(
        child: Text('No lesson comments match current filters.'),
      );
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final row = rows[i];
        final c = row.item;
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
                    name: c.displayName,
                    photoUrl: c.photoUrl,
                    radius: 13,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${c.firstName.isEmpty ? 'Learner' : c.firstName} (${c.abbr.isEmpty ? 'L' : c.abbr})',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      _courseLabel(row.courseId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.58),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(c.text),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'Lesson: ${row.lessonId}',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.62),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Status: ${c.status}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (c.reportCount > 0)
                    Text(
                      'Reports: ${c.reportCount}',
                      style: const TextStyle(
                        color: Color(0xFFB45309),
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  const Spacer(),
                  Text(
                    _fmtDate(c.createdAt),
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.52),
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
                    onPressed: () => _moderateComment(row, 'visible'),
                    child: const Text('Accept'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _moderateComment(row, 'hidden'),
                    child: const Text('Hide'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB91C1C),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _moderateComment(row, 'removed'),
                    child: const Text('Remove'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final courseIds = {
      ..._reviews.map((e) => e.courseId),
      ..._comments.map((e) => e.courseId),
    }.where((id) => id.trim().isNotEmpty).toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Course Feedback Moderation'),
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
                : (_tab == _AdminFeedbackTab.reviews
                      ? _reviewsList()
                      : _commentsList()),
          ),
        ],
      ),
    );
  }
}
