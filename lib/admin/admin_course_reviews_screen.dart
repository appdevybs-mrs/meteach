import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../services/course_feedback_service.dart';
import '../shared/profile_avatar.dart';

class AdminCourseReviewsScreen extends StatefulWidget {
  const AdminCourseReviewsScreen({super.key});

  @override
  State<AdminCourseReviewsScreen> createState() =>
      _AdminCourseReviewsScreenState();
}

class _AdminCourseReviewsScreenState extends State<AdminCourseReviewsScreen> {
  bool _busy = true;
  String? _error;
  String _courseFilter = 'all';
  String _statusFilter = 'all';
  List<CourseReviewItem> _all = const [];

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
      final root = await FirebaseDatabase.instance.ref('course_reviews').get();
      final out = <CourseReviewItem>[];
      if (root.exists && root.value is Map) {
        final courses = Map<dynamic, dynamic>.from(root.value as Map);
        for (final entry in courses.entries) {
          final courseId = entry.key.toString();
          final reviews = entry.value;
          if (reviews is! Map) continue;
          final revMap = Map<dynamic, dynamic>.from(reviews);
          for (final rEntry in revMap.entries) {
            if (rEntry.value is! Map) continue;
            final m = (rEntry.value as Map).map(
              (k, v) => MapEntry(k.toString(), v),
            );
            final item = CourseReviewItem.fromMap(rEntry.key.toString(), m);
            if (item.courseId.trim().isEmpty) {
              out.add(
                CourseReviewItem.fromMap(rEntry.key.toString(), {
                  ...m,
                  'courseId': courseId,
                }),
              );
            } else {
              out.add(item);
            }
          }
        }
      }
      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (!mounted) return;
      setState(() {
        _all = out;
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

  List<CourseReviewItem> get _filtered {
    return _all.where((r) {
      if (_courseFilter != 'all' && r.courseId != _courseFilter) return false;
      if (_statusFilter != 'all' && r.status != _statusFilter) return false;
      return true;
    }).toList();
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _moderate(CourseReviewItem item, String next) async {
    await CourseFeedbackService.moderateCourseReview(
      courseId: item.courseId,
      reviewId: item.id,
      status: next,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Review set to "$next"')));
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

  @override
  Widget build(BuildContext context) {
    final courseIds = _all.map((e) => e.courseId).toSet().toList()..sort();
    final rows = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Course Reviews Moderation'),
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
                    items: [
                      const DropdownMenuItem(
                        value: 'all',
                        child: Text('All courses'),
                      ),
                      ...courseIds.map(
                        (id) => DropdownMenuItem(value: id, child: Text(id)),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _courseFilter = v ?? 'all'),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 170,
                  child: DropdownButtonFormField<String>(
                    value: _statusFilter,
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All')),
                      DropdownMenuItem(
                        value: 'visible',
                        child: Text('Visible'),
                      ),
                      DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
                      DropdownMenuItem(
                        value: 'removed',
                        child: Text('Removed'),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _statusFilter = v ?? 'all'),
                  ),
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
                ? const Center(child: Text('No reviews match current filters.'))
                : ListView.separated(
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
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                Text(
                                  'Course: ${r.courseId}',
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.58),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
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
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
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
                                  onPressed: () => _moderate(r, 'visible'),
                                  child: const Text('Accept'),
                                ),
                                FilledButton.tonal(
                                  onPressed: () => _moderate(r, 'hidden'),
                                  child: const Text('Hide'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFB91C1C),
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: () => _moderate(r, 'removed'),
                                  child: const Text('Remove'),
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
