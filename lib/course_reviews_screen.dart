import 'package:flutter/material.dart';

import 'services/course_feedback_service.dart';
import 'shared/profile_avatar.dart';
import 'shared/responsive_layout.dart';

enum CourseReviewSort { topRated, newest, lowestRated }

class CourseReviewsScreen extends StatefulWidget {
  const CourseReviewsScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
  });

  final String courseId;
  final String courseTitle;

  @override
  State<CourseReviewsScreen> createState() => _CourseReviewsScreenState();
}

class _CourseReviewsScreenState extends State<CourseReviewsScreen> {
  bool _busy = true;
  String? _error;
  CourseReviewSort _sort = CourseReviewSort.topRated;
  List<CourseReviewItem> _reviews = const [];

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
      final reviews = await CourseFeedbackService.listCourseReviews(
        widget.courseId,
        visibleOnly: true,
      );
      if (!mounted) return;
      setState(() {
        _reviews = reviews;
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

  List<CourseReviewItem> get _sorted {
    final copy = [..._reviews];
    switch (_sort) {
      case CourseReviewSort.topRated:
        copy.sort((a, b) {
          final byRating = b.rating.compareTo(a.rating);
          if (byRating != 0) return byRating;
          return b.createdAt.compareTo(a.createdAt);
        });
      case CourseReviewSort.newest:
        copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case CourseReviewSort.lowestRated:
        copy.sort((a, b) {
          final byRating = a.rating.compareTo(b.rating);
          if (byRating != 0) return byRating;
          return b.createdAt.compareTo(a.createdAt);
        });
    }
    return copy;
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Widget _stars(int rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < rating ? Icons.star_rounded : Icons.star_border_rounded,
          size: 18,
          color: const Color(0xFFF59E0B),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktopWide = AppResponsive.isWebDesktop(context, minWidth: 1180);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.courseTitle.isEmpty ? 'Course Reviews' : widget.courseTitle,
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: desktopWide ? 980 : 760),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  children: [
                    const Text(
                      'Sort:',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<CourseReviewSort>(
                      value: _sort,
                      items: const [
                        DropdownMenuItem(
                          value: CourseReviewSort.topRated,
                          child: Text('Top rated'),
                        ),
                        DropdownMenuItem(
                          value: CourseReviewSort.newest,
                          child: Text('Newest'),
                        ),
                        DropdownMenuItem(
                          value: CourseReviewSort.lowestRated,
                          child: Text('Lowest rated'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _sort = v);
                      },
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
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
                    : _sorted.isEmpty
                    ? const Center(child: Text('No reviews yet.'))
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                        itemCount: _sorted.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final r = _sorted[i];
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                color: const Color(0xFFE5E7EB),
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    ProfileAvatar(
                                      name: r.displayName,
                                      photoUrl: r.photoUrl,
                                      radius: 16,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${r.firstName.isEmpty ? 'Learner' : r.firstName} (${r.abbr.isEmpty ? 'L' : r.abbr})',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _fmtDate(r.createdAt),
                                      style: TextStyle(
                                        color: Colors.black.withValues(
                                          alpha: 0.55,
                                        ),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                _stars(r.rating),
                                const SizedBox(height: 8),
                                Text(
                                  r.comment,
                                  style: const TextStyle(
                                    height: 1.35,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
