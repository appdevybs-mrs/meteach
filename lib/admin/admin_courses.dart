import 'dart:async';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert';
import 'package:dream_english_academy/admin/course_syllabus_screen.dart';
import 'package:dream_english_academy/shared/human_error.dart';
import 'package:dream_english_academy/services/backend_api.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';

class AdminCoursesScreen extends StatefulWidget {
  const AdminCoursesScreen({super.key});

  // ✅ Brand palette
  static const primaryBlue = Color(0xFF1A2B48); // #1A2B48
  static const actionOrange = Color(0xFFF98D28); // #F98D28
  static const accentCyan = Color(0xFF00D4FF); // #00D4FF
  static const mainText = Color(0xFF2D2D2D); // #2D2D2D
  static const appBg = Color(0xFFF4F7F9); // #F4F7F9
  static const uiBorders = Color(0xFFD1D9E0); // #D1D9E0

  @override
  State<AdminCoursesScreen> createState() => _AdminCoursesScreenState();
}

class _AdminCoursesScreenState extends State<AdminCoursesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _db = FirebaseDatabase.instance;

  // Firebase paths
  static const _coursesPath = 'courses';
  static const _trashPath = 'courses_trash';

  // NEW: ordering field name (stored inside each course)
  static const String _orderField = 'order_index';

  // UI state
  String _search = '';
  CourseStatus? _statusFilter; // null = all

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  DatabaseReference get _coursesRef => _db.ref(_coursesPath);
  DatabaseReference get _trashRef => _db.ref(_trashPath);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminCoursesScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminCoursesScreen.primaryBlue),
        title: const Text(
          'Courses',
          style: TextStyle(
            color: AdminCoursesScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AdminCoursesScreen.primaryBlue,
          unselectedLabelColor: AdminCoursesScreen.primaryBlue.withValues(
            alpha: 0.55,
          ),
          indicatorColor: AdminCoursesScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Courses'),
            Tab(text: 'Trash'),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
          // Add only on Courses tab
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              final isCoursesTab = _tabController.index == 0;
              if (!isCoursesTab) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Bulk pricing tool',
                      onPressed: _openBulkPricingTool,
                      icon: const Icon(
                        Icons.price_change_outlined,
                        color: AdminCoursesScreen.primaryBlue,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Add course',
                      onPressed: () async {
                        final created = await Navigator.of(context)
                            .push<Course?>(
                              MaterialPageRoute(
                                builder: (_) => CourseEditorScreen(
                                  mode: EditorMode.create,
                                  uploadClient: UploadClient.defaultClient(),
                                ),
                              ),
                            );
                        if (created != null && mounted) {
                          _showSnack('Course created successfully.');
                        }
                      },
                      icon: const Icon(
                        Icons.add_circle_outline,
                        color: AdminCoursesScreen.actionOrange,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _CoursesTab(
            coursesRef: _coursesRef,
            orderField: _orderField,
            search: _search,
            statusFilter: _statusFilter,
            onSearchChanged: (v) => setState(() => _search = v),
            onStatusFilterChanged: (v) => setState(() => _statusFilter = v),
            onEdit: (courseId, course) async {
              final updated = await Navigator.of(context).push<Course?>(
                MaterialPageRoute(
                  builder: (_) => CourseEditorScreen(
                    mode: EditorMode.edit,
                    courseId: courseId,
                    initial: course,
                    uploadClient: UploadClient.defaultClient(),
                  ),
                ),
              );
              if (updated != null && mounted) {
                _showSnack('Course updated ✅');
              }
            },
            onChangeStatus: _changeStatus,
            onMoveToTrash: _moveToTrash,
          ),
          _TrashTab(
            trashRef: _trashRef,
            search: _search,
            onSearchChanged: (v) => setState(() => _search = v),
            onRestore: _restoreFromTrash,
            onDeletePermanently: _deletePermanently,
          ),
        ],
      ),
    );
  }

  Future<void> _changeStatus(String courseId, CourseStatus newStatus) async {
    await _coursesRef.child(courseId).update({
      'status': newStatus.value,
      'updatedAt': ServerValue.timestamp,
    });
    if (mounted) _showSnack('Status set to "${newStatus.label}" ✅');
  }

  Future<void> _moveToTrash(String courseId, Course course) async {
    final lookupIds = <String>{courseId};
    final counts = await _loadEngagementCounts(lookupIds.toList());
    final reviewCount = counts['reviews'] ?? 0;
    final commentCount = counts['comments'] ?? 0;

    final ok = await _confirm(
      title: 'Move to Trash?',
      message:
          'This will remove the course from Courses and move it to Trash.\n\nYou can restore it later.\n\nEngagement data:\n• Reviews: $reviewCount\n• Lesson comments: $commentCount\n\nRecommended: Archive/Hide the course if you want to preserve discovery history.',
      confirmText: 'Move to Trash',
      danger: true,
    );
    if (!ok) return;

    // Write into trash with metadata, then remove from courses
    final trashData = course.toMap()
      ..addAll({'trashedAt': ServerValue.timestamp, 'originalId': courseId});

    await _trashRef.child(courseId).set(trashData);
    await _coursesRef.child(courseId).remove();

    if (mounted) _showSnack('Moved to Trash 🗑️');
  }

  Future<void> _restoreFromTrash(String courseId, Course course) async {
    final ok = await _confirm(
      title: 'Restore course?',
      message: 'This will restore the course back to Courses.',
      confirmText: 'Restore',
    );
    if (!ok) return;

    final restoreData = course.toMap()
      ..remove('trashedAt')
      ..remove('originalId')
      ..addAll({'updatedAt': ServerValue.timestamp});

    await _coursesRef.child(courseId).set(restoreData);
    await _trashRef.child(courseId).remove();

    if (mounted) _showSnack('Restored ✅');
  }

  Future<void> _deletePermanently(String courseId) async {
    final trashSnap = await _trashRef.child(courseId).get();
    final lookupIds = <String>{courseId};
    if (trashSnap.exists && trashSnap.value is Map) {
      final m = (trashSnap.value as Map).map((k, v) => MapEntry('$k', v));
      final id = (m['id'] ?? '').toString().trim();
      final original = (m['originalId'] ?? '').toString().trim();
      if (id.isNotEmpty) lookupIds.add(id);
      if (original.isNotEmpty) lookupIds.add(original);
    }

    final counts = await _loadEngagementCounts(lookupIds.toList());
    final reviewCount = counts['reviews'] ?? 0;
    final commentCount = counts['comments'] ?? 0;

    final ok = await _confirm(
      title: 'Delete permanently?',
      message:
          'This will permanently delete the course from Trash.\n\nThis cannot be undone.\n\nEngagement data:\n• Reviews: $reviewCount\n• Lesson comments: $commentCount\n\nRecommended: Archive/Hide the course instead of deleting to preserve comments and trust signals.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    if (reviewCount > 0 || commentCount > 0) {
      final second = await _confirm(
        title: 'Confirm permanent deletion',
        message:
            'This course has learner engagement content.\n\nDeleting permanently may make discovery moderation harder later.\n\nAre you absolutely sure you want to continue?',
        confirmText: 'Yes, delete permanently',
        danger: true,
      );
      if (!second) return;
    }

    await _trashRef.child(courseId).remove();
    if (mounted) _showSnack('Deleted permanently ✅');
  }

  Future<Map<String, int>> _loadEngagementCounts(List<String> lookupIds) async {
    final seen = <String>{};
    var reviewCount = 0;
    var commentCount = 0;

    for (final rawId in lookupIds) {
      final id = rawId.trim();
      if (id.isEmpty || !seen.add(id)) continue;

      final reviewSnap = await _db.ref('course_reviews/$id').get();
      if (reviewSnap.exists && reviewSnap.value is Map) {
        final reviews = Map<dynamic, dynamic>.from(reviewSnap.value as Map);
        reviewCount += reviews.length;
      }

      final commentsSnap = await _db.ref('lesson_comments/$id').get();
      if (commentsSnap.exists && commentsSnap.value is Map) {
        final lessons = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
        for (final v in lessons.values) {
          if (v is Map) {
            commentCount += Map<dynamic, dynamic>.from(v).length;
          }
        }
      }
    }

    return {'reviews': reviewCount, 'comments': commentCount};
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    bool danger = false,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger ? Colors.red : null,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmText),
              ),
            ],
          ),
        )) ??
        false;
  }

  void _showSnack(String msg) {
    AppToast.fromSnackBar(context, SnackBar(content: Text(msg)));
  }

  Future<void> _openBulkPricingTool() async {
    try {
      final snap = await _coursesRef.get();
      final rows = _parseCoursesMap(snap.value, orderField: _orderField)
        ..sort(
          (a, b) => a.course.title.toLowerCase().compareTo(
            b.course.title.toLowerCase(),
          ),
        );

      if (!mounted) return;
      if (rows.isEmpty) {
        _showSnack('No courses found to update.');
        return;
      }

      final result = await showDialog<_BulkPricingApplyResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BulkPricingDialog(coursesRef: _coursesRef, rows: rows),
      );

      if (!mounted || result == null) return;
      _showSnack(
        'Bulk update applied to ${result.courseCount} course${result.courseCount == 1 ? '' : 's'} across ${result.variantCount} variant${result.variantCount == 1 ? '' : 's'}.',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not open bulk pricing tool.'),
        type: AppToastType.error,
      );
    }
  }
}

class _CoursesTab extends StatefulWidget {
  const _CoursesTab({
    required this.coursesRef,
    required this.orderField,
    required this.search,
    required this.statusFilter,
    required this.onSearchChanged,
    required this.onStatusFilterChanged,
    required this.onEdit,
    required this.onChangeStatus,
    required this.onMoveToTrash,
  });

  final DatabaseReference coursesRef;
  final String orderField;

  final String search;
  final CourseStatus? statusFilter;

  final ValueChanged<String> onSearchChanged;
  final ValueChanged<CourseStatus?> onStatusFilterChanged;

  final Future<void> Function(String courseId, Course course) onEdit;
  final Future<void> Function(String courseId, CourseStatus newStatus)
  onChangeStatus;
  final Future<void> Function(String courseId, Course course) onMoveToTrash;

  @override
  State<_CoursesTab> createState() => _CoursesTabState();
}

class _CoursesTabState extends State<_CoursesTab> {
  bool _savingOrder = false;

  // local cache ONLY for reorder UI (we still listen to stream)
  List<_CourseRow>? _localFiltered;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          hint: 'Search courses…',
          value: widget.search,
          onChanged: widget.onSearchChanged,
          filters: [
            _FilterChipItem(
              label: 'All',
              selected: widget.statusFilter == null,
              onTap: () => widget.onStatusFilterChanged(null),
            ),
            ...CourseStatus.values.map(
              (s) => _FilterChipItem(
                label: s.label,
                selected: widget.statusFilter == s,
                onTap: () => widget.onStatusFilterChanged(s),
              ),
            ),
          ],
        ),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: widget.coursesRef.onValue,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _StateCard(
                  title: 'Error',
                  message: 'Could not load courses.',
                  icon: Icons.error_outline,
                );
              }
              if (!snapshot.hasData) {
                return const _LoadingList();
              }

              final data = snapshot.data!.snapshot.value;
              final items = _parseCoursesMap(
                data,
                orderField: widget.orderField,
              );

              // Ensure every item has an order_index once (lazy init).
              // This does NOT change other logic; only adds ordering metadata if missing.
              _ensureOrderIndexes(items);

              // Sort by order_index first, then fallback to updatedAt (your logic still applies)
              items.sort((a, b) {
                final ao = a.orderIndex ?? 1 << 30;
                final bo = b.orderIndex ?? 1 << 30;
                final c = ao.compareTo(bo);
                if (c != 0) return c;
                return (b.updatedAtMs ?? 0).compareTo(a.updatedAtMs ?? 0);
              });

              final filtered = items.where((x) {
                final s = widget.search.trim();
                final matchesSearch = s.isEmpty
                    ? true
                    : x.course.title.toLowerCase().contains(s.toLowerCase()) ||
                          x.course.shortDescription.toLowerCase().contains(
                            s.toLowerCase(),
                          ) ||
                          (x.course.tags
                              .join(',')
                              .toLowerCase()
                              .contains(s.toLowerCase()));
                final matchesStatus = widget.statusFilter == null
                    ? true
                    : x.course.status == widget.statusFilter!;
                return matchesSearch && matchesStatus;
              }).toList();

              if (filtered.isEmpty) {
                return _StateCard(
                  title: 'No courses',
                  message:
                      widget.statusFilter == null &&
                          widget.search.trim().isEmpty
                      ? 'Add your first course using the + button.'
                      : 'No results match your filters.',
                  icon: Icons.school_outlined,
                );
              }

              // If search/filter changes, rebuild local ordering list from filtered
              // Keep local list in sync with latest Firebase data.
              // If IDs/order are the same, refresh the course payloads only.
              if (_localFiltered == null) {
                _localFiltered = List<_CourseRow>.from(filtered);
              } else if (_localFiltered!.length != filtered.length ||
                  !_sameIds(_localFiltered!, filtered)) {
                _localFiltered = List<_CourseRow>.from(filtered);
              } else {
                _localFiltered = filtered.map((fresh) {
                  final existingIndex = _localFiltered!.indexWhere(
                    (e) => e.id == fresh.id,
                  );
                  if (existingIndex == -1) return fresh;
                  return _CourseRow(
                    id: _localFiltered![existingIndex].id,
                    course: fresh.course,
                  );
                }).toList();
              }

              return Stack(
                children: [
                  // ✅ Drag reorder list
                  ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: _localFiltered!.length,
                    onReorder: (oldIndex, newIndex) async {
                      if (_savingOrder) return;

                      setState(() {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final item = _localFiltered!.removeAt(oldIndex);
                        _localFiltered!.insert(newIndex, item);
                      });

                      // Persist only when NOT searching/filtering? No:
                      // We persist current visible order (filtered view).
                      // BUT to avoid messing global order while filtered, we require no search & no filter.
                      // This is the safest behaviour.
                      final isSafeToPersist =
                          widget.search.trim().isEmpty &&
                          widget.statusFilter == null;

                      if (!isSafeToPersist) {
                        AppToast.fromSnackBar(
                          context,
                          const SnackBar(
                            content: Text(
                              'Reordering is disabled while search/filters are active. Clear filters to save order.',
                            ),
                          ),
                        );
                        return;
                      }

                      await _persistOrder(_localFiltered!);
                    },
                    itemBuilder: (context, i) {
                      final row = _localFiltered![i];
                      return _CourseCard(
                        key: ValueKey('course_${row.id}'),
                        courseId: row.id,
                        course: row.course,
                        // nice drag handle (also long-press drag still works)
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                        onEdit: () => widget.onEdit(row.id, row.course),
                        onChangeStatus: (s) => widget.onChangeStatus(row.id, s),
                        onMoveToTrash: () =>
                            widget.onMoveToTrash(row.id, row.course),
                      );
                    },
                  ),

                  if (_savingOrder)
                    Positioned.fill(
                      child: Container(
                        color: Colors.white.withValues(alpha: 0.6),
                        child: const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  bool _sameIds(List<_CourseRow> a, List<_CourseRow> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Future<void> _ensureOrderIndexes(List<_CourseRow> items) async {
    // Only assign if missing ANY order_index (lazy init, best effort)
    final missing = items.where((e) => e.orderIndex == null).toList();
    if (missing.isEmpty) return;

    // Assign based on current sorted fallback (updatedAt descending in original code)
    // We'll assign order after sorting by updatedAt desc so "newest first" stays.
    final copy = List<_CourseRow>.from(items);
    copy.sort((a, b) => (b.updatedAtMs ?? 0).compareTo(a.updatedAtMs ?? 0));

    final updates = <String, dynamic>{};
    for (int i = 0; i < copy.length; i++) {
      updates['${copy[i].id}/${widget.orderField}'] = i;
    }

    try {
      await widget.coursesRef.update(updates);
    } catch (_) {
      // ignore: non-blocking init
    }
  }

  Future<void> _persistOrder(List<_CourseRow> ordered) async {
    setState(() => _savingOrder = true);
    try {
      final updates = <String, dynamic>{};
      for (int i = 0; i < ordered.length; i++) {
        updates['${ordered[i].id}/${widget.orderField}'] = i;
      }
      await widget.coursesRef.update(updates);

      if (mounted) {
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Order saved ✅')),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              toHumanError(e, fallback: 'Could not save course order.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingOrder = false);
    }
  }
}

class _TrashTab extends StatelessWidget {
  const _TrashTab({
    required this.trashRef,
    required this.search,
    required this.onSearchChanged,
    required this.onRestore,
    required this.onDeletePermanently,
  });

  final DatabaseReference trashRef;
  final String search;
  final ValueChanged<String> onSearchChanged;
  final Future<void> Function(String courseId, Course course) onRestore;
  final Future<void> Function(String courseId) onDeletePermanently;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          hint: 'Search trash…',
          value: search,
          onChanged: onSearchChanged,
          filters: const [],
        ),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: trashRef.onValue,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _StateCard(
                  title: 'Error',
                  message: 'Could not load trash.',
                  icon: Icons.error_outline,
                );
              }
              if (!snapshot.hasData) {
                return const _LoadingList();
              }

              final data = snapshot.data!.snapshot.value;
              final items = _parseCoursesMap(data, orderField: null);

              // sort by trashedAt if available
              items.sort((a, b) {
                final aT = a.course.trashedAtMs ?? 0;
                final bT = b.course.trashedAtMs ?? 0;
                return bT.compareTo(aT);
              });

              final filtered = items.where((x) {
                if (search.trim().isEmpty) return true;
                final s = search.toLowerCase();
                return x.course.title.toLowerCase().contains(s) ||
                    x.course.shortDescription.toLowerCase().contains(s) ||
                    x.course.tags.join(',').toLowerCase().contains(s);
              }).toList();

              if (filtered.isEmpty) {
                return const _StateCard(
                  title: 'Trash is empty',
                  message: 'Courses you move to Trash will appear here.',
                  icon: Icons.delete_outline,
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final row = filtered[i];
                  return _TrashCourseCard(
                    courseId: row.id,
                    course: row.course,
                    onRestore: () => onRestore(row.id, row.course),
                    onDeletePermanently: () => onDeletePermanently(row.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.hint,
    required this.value,
    required this.onChanged,
    required this.filters,
  });

  final String hint;
  final String value;
  final ValueChanged<String> onChanged;
  final List<_FilterChipItem> filters;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          TextField(
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: AdminCoursesScreen.appBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
          if (filters.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: filters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final f = filters[i];
                  return ChoiceChip(
                    label: Text(f.label),
                    selected: f.selected,
                    onSelected: (_) => f.onTap(),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChipItem {
  const _FilterChipItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

class _BulkPricingApplyResult {
  const _BulkPricingApplyResult({
    required this.courseCount,
    required this.variantCount,
  });

  final int courseCount;
  final int variantCount;
}

class _BulkPricingDialog extends StatefulWidget {
  const _BulkPricingDialog({required this.coursesRef, required this.rows});

  final DatabaseReference coursesRef;
  final List<_CourseRow> rows;

  @override
  State<_BulkPricingDialog> createState() => _BulkPricingDialogState();
}

class _BulkPricingDialogState extends State<_BulkPricingDialog> {
  static const List<String> _variants = [
    'online',
    'live',
    'recorded',
    'inclass',
  ];
  static const Map<String, String> _labels = {
    'online': 'Flexible',
    'live': 'Private',
    'recorded': 'Recorded',
    'inclass': 'In-Class',
  };

  final Set<String> _selectedCourseIds = <String>{};
  late final Map<String, bool> _applyVariant;
  late final Map<String, String> _accessModes;
  late final Map<String, TextEditingController> _feeControllers;
  late final Map<String, TextEditingController> _durationControllers;

  bool _applying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedCourseIds.addAll(widget.rows.map((e) => e.id));
    _applyVariant = {for (final v in _variants) v: false};
    _accessModes = {for (final v in _variants) v: 'lifetime'};
    _feeControllers = {for (final v in _variants) v: TextEditingController()};
    _durationControllers = {
      for (final v in _variants) v: TextEditingController(),
    };
  }

  @override
  void dispose() {
    for (final c in _feeControllers.values) {
      c.dispose();
    }
    for (final c in _durationControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _allSelected => _selectedCourseIds.length == widget.rows.length;

  void _toggleAll(bool? checked) {
    setState(() {
      if (checked == true) {
        _selectedCourseIds
          ..clear()
          ..addAll(widget.rows.map((e) => e.id));
      } else {
        _selectedCourseIds.clear();
      }
    });
  }

  Future<void> _apply() async {
    setState(() => _error = null);

    if (_selectedCourseIds.isEmpty) {
      setState(() => _error = 'Select at least one course.');
      return;
    }

    final activeVariants = _variants
        .where((v) => _applyVariant[v] == true)
        .toList();
    if (activeVariants.isEmpty) {
      setState(() => _error = 'Enable at least one variant.');
      return;
    }

    final updates = <String, dynamic>{};

    for (final courseId in _selectedCourseIds) {
      updates['$courseId/updatedAt'] = ServerValue.timestamp;

      for (final variant in activeVariants) {
        final feeText = _feeControllers[variant]!.text.trim();
        final fee = double.tryParse(feeText);
        if (fee == null || fee < 0) {
          setState(() {
            _error = '${_labels[variant]} fee must be a valid number.';
          });
          return;
        }

        final mode = _accessModes[variant] ?? 'lifetime';
        final base = '$courseId/delivery_configs/$variant';
        updates['$base/enabled'] = true;
        updates['$base/fee'] = fee;
        updates['$base/access_mode'] = mode;

        if (mode == 'duration') {
          final monthsText = _durationControllers[variant]!.text.trim();
          final months = int.tryParse(monthsText);
          if (months == null || months <= 0) {
            setState(() {
              _error =
                  '${_labels[variant]} duration must be a positive number.';
            });
            return;
          }
          updates['$base/access_duration_months'] = months;
        } else {
          updates['$base/access_duration_months'] = null;
        }
      }
    }

    setState(() => _applying = true);
    try {
      await widget.coursesRef.update(updates);
      if (!mounted) return;
      Navigator.of(context).pop(
        _BulkPricingApplyResult(
          courseCount: _selectedCourseIds.length,
          variantCount: activeVariants.length,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not apply bulk update.');
      });
    } finally {
      if (mounted) {
        setState(() => _applying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bulk Course Pricing'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _allSelected,
                tristate: true,
                title: Text(
                  'Select all courses (${widget.rows.length})',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                onChanged: _applying ? null : _toggleAll,
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.rows.length,
                  itemBuilder: (context, i) {
                    final row = widget.rows[i];
                    final checked = _selectedCourseIds.contains(row.id);
                    return CheckboxListTile(
                      dense: true,
                      value: checked,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        row.course.title.isEmpty
                            ? '(Untitled)'
                            : row.course.title,
                      ),
                      subtitle: row.course.courseCode.trim().isEmpty
                          ? null
                          : Text(row.course.courseCode),
                      onChanged: _applying
                          ? null
                          : (v) {
                              setState(() {
                                if (v == true) {
                                  _selectedCourseIds.add(row.id);
                                } else {
                                  _selectedCourseIds.remove(row.id);
                                }
                              });
                            },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              const Text(
                'Variant pricing to apply',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              for (final variant in _variants) ...[
                SwitchListTile(
                  value: _applyVariant[variant] == true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_labels[variant]!),
                  subtitle: const Text('Enable and set fee/access rule'),
                  onChanged: _applying
                      ? null
                      : (v) => setState(() => _applyVariant[variant] = v),
                ),
                if (_applyVariant[variant] == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      children: [
                        TextField(
                          controller: _feeControllers[variant],
                          enabled: !_applying,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: '${_labels[variant]} fee',
                            prefixText: '4 ',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _accessModes[variant],
                          decoration: InputDecoration(
                            labelText: '${_labels[variant]} access mode',
                            border: const OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'lifetime',
                              child: Text('Lifetime access'),
                            ),
                            DropdownMenuItem(
                              value: 'duration',
                              child: Text('Duration access'),
                            ),
                          ],
                          onChanged: _applying
                              ? null
                              : (v) {
                                  if (v == null) return;
                                  setState(() => _accessModes[variant] = v);
                                },
                        ),
                        if ((_accessModes[variant] ?? 'lifetime') ==
                            'duration') ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: _durationControllers[variant],
                            enabled: !_applying,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText:
                                  '${_labels[variant]} duration (months)',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                const Divider(height: 1),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _applying ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _applying ? null : _apply,
          icon: _applying
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle_outline),
          label: Text(_applying ? 'Applying...' : 'Apply'),
        ),
      ],
    );
  }
}

class _CourseCard extends StatelessWidget {
  const _CourseCard({
    super.key,
    required this.courseId,
    required this.course,
    required this.onEdit,
    required this.onChangeStatus,
    required this.onMoveToTrash,
    this.trailing,
  });

  final String courseId;
  final Course course;
  final VoidCallback onEdit;
  final ValueChanged<CourseStatus> onChangeStatus;
  final VoidCallback onMoveToTrash;

  // NEW: drag handle support
  final Widget? trailing;
  Future<void> _openSyllabusPicker(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        Widget tile(String key, String label, IconData icon) {
          return ListTile(
            leading: Icon(icon),
            title: Text(label),
            onTap: () => Navigator.pop(context, key),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Choose syllabus type',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
              ),
              tile('inclass', 'In-Class', Icons.class_),
              tile('flexible', 'Flexible', Icons.event_available),
              tile('recorded', 'Recorded', Icons.ondemand_video),
              tile('private', 'Private', Icons.person),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );

    if (picked == null || picked.trim().isEmpty) return;
    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CourseSyllabusScreen(
          courseId: courseId,
          courseTitle: course.title,
          variantKey: picked,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _Thumb(url: course.thumbnailUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    course.title.isEmpty ? '(Untitled)' : course.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: AdminCoursesScreen.primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    course.duration.trim().isEmpty
                        ? 'Duration: -'
                        : 'Duration: ${course.duration.trim()}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.black.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // 📘 Syllabus button
            IconButton(
              tooltip: 'Syllabus',
              onPressed: () => _openSyllabusPicker(context),
              icon: const Text('📘', style: TextStyle(fontSize: 18)),
            ),

            // ⋮ Existing menu
            PopupMenuButton<_CourseAction>(
              tooltip: 'Actions',
              onSelected: (a) async {
                switch (a) {
                  case _CourseAction.edit:
                    onEdit();
                    break;
                  case _CourseAction.toDraft:
                    onChangeStatus(CourseStatus.draft);
                    break;
                  case _CourseAction.publish:
                    onChangeStatus(CourseStatus.published);
                    break;
                  case _CourseAction.pause:
                    onChangeStatus(CourseStatus.paused);
                    break;
                  case _CourseAction.archive:
                    onChangeStatus(CourseStatus.archived);
                    break;
                  case _CourseAction.trash:
                    onMoveToTrash();
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _CourseAction.edit,
                  child: Text('Edit'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: _CourseAction.toDraft,
                  child: Text('Set Draft'),
                ),
                const PopupMenuItem(
                  value: _CourseAction.publish,
                  child: Text('Publish'),
                ),
                const PopupMenuItem(
                  value: _CourseAction.pause,
                  child: Text('Pause'),
                ),
                const PopupMenuItem(
                  value: _CourseAction.archive,
                  child: Text('Archive'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: _CourseAction.trash,
                  child: Text('Move to Trash'),
                ),
              ],
            ),

            ?trailing,
          ],
        ),
      ),
    );
  }
}

enum _CourseAction { edit, toDraft, publish, pause, archive, trash }

class _TrashCourseCard extends StatelessWidget {
  const _TrashCourseCard({
    required this.courseId,
    required this.course,
    required this.onRestore,
    required this.onDeletePermanently,
  });

  final String courseId;
  final Course course;
  final VoidCallback onRestore;
  final VoidCallback onDeletePermanently;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _Thumb(url: course.thumbnailUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    course.title.isEmpty ? '(Untitled)' : course.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: AdminCoursesScreen.primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    course.duration.trim().isEmpty
                        ? 'Duration: -'
                        : 'Duration: ${course.duration.trim()}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.black.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<_TrashAction>(
              tooltip: 'Actions',
              onSelected: (a) {
                switch (a) {
                  case _TrashAction.restore:
                    onRestore();
                    break;
                  case _TrashAction.deleteForever:
                    onDeletePermanently();
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _TrashAction.restore,
                  child: Text('Restore'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: _TrashAction.deleteForever,
                  child: Text('Delete permanently'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _TrashAction { restore, deleteForever }

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final u = url.trim();
    final hasUrl =
        u.isNotEmpty && (u.startsWith('http://') || u.startsWith('https://'));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 64,
        height: 64,
        color: AdminCoursesScreen.appBg,
        child: hasUrl
            ? Image.network(
                url,
                fit: BoxFit.cover,
                // ✅ prevents noisy logs for 404 / bad images
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.image_not_supported_outlined),
                // ✅ also helps avoid repeated reload attempts
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  if (frame != null) return child;
                  return const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                },
              )
            : const Icon(Icons.image_outlined),
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.all(16),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: AdminCoursesScreen.primaryBlue),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: AdminCoursesScreen.primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: 6,
      itemBuilder: (context, i) => Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 10),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: ColoredBox(color: AdminCoursesScreen.appBg),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 14,
                      width: 160,
                      child: ColoredBox(color: AdminCoursesScreen.appBg),
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      height: 12,
                      width: 260,
                      child: ColoredBox(color: AdminCoursesScreen.appBg),
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      height: 12,
                      width: 200,
                      child: ColoredBox(color: AdminCoursesScreen.appBg),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ----------------------------
/// Course Editor
/// ----------------------------

enum EditorMode { create, edit }

class CourseEditorScreen extends StatefulWidget {
  const CourseEditorScreen({
    super.key,
    required this.mode,
    required this.uploadClient,
    this.courseId,
    this.initial,
  });

  final EditorMode mode;
  final String? courseId;
  final Course? initial;
  final UploadClient uploadClient;

  @override
  State<CourseEditorScreen> createState() => _CourseEditorScreenState();
}

class _CourseEditorScreenState extends State<CourseEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  Set<String> _deliverySelected = {};
  late final Map<String, bool> _deliveryEnabled;
  late final Map<String, TextEditingController> _deliveryFeeControllers;
  late final Map<String, String> _deliveryAccessModes;
  late final Map<String, TextEditingController> _deliveryDurationControllers;

  File? _localThumbFile;

  // Controllers for your 15 fields
  late final TextEditingController titleC;
  late final TextEditingController categoryC;

  late final TextEditingController thumbnailUrlC;
  late final TextEditingController shortDescC;
  late final TextEditingController longDescC;
  late final TextEditingController durationC;
  late final TextEditingController contentC;
  late final TextEditingController instructorsC;
  late final TextEditingController levelC;
  late final TextEditingController languageC;
  late final TextEditingController deliveryC;

  late final TextEditingController requirementsC;
  late final TextEditingController tagsC;

  List<String> _categorySuggestions = [];
  bool _loadingCategories = false;

  Future<void> _loadExistingInstructorsMapIfEdit() async {
    // Only in edit mode and only if we have an id
    if (widget.mode != EditorMode.edit) return;
    final id = widget.courseId;
    if (id == null || id.trim().isEmpty) return;

    try {
      final snap = await _coursesRef.child(id).get();
      final v = snap.value;

      if (v is Map) {
        final m = v.map((k, val) => MapEntry(k.toString(), val));

        final existing = m['instructors_map'];
        if (existing is Map) {
          // normalize keys to String
          final normalized = existing.map(
            (k, val) => MapEntry(k.toString(), val),
          );
          _pickedInstructorMap = Map<String, dynamic>.from(normalized);
        }
      }
    } catch (_) {
      // ignore: best effort; we keep empty map if read fails
    }
  }

  Future<void> _loadCategorySuggestions() async {
    setState(() => _loadingCategories = true);
    try {
      final snap = await _coursesRef.get();
      final data = snap.value;

      final set = <String>{};

      if (data is Map) {
        data.forEach((_, value) {
          if (value is Map) {
            final raw = value['category'];
            if (raw != null) {
              final c = raw.toString().trim();
              if (c.isNotEmpty) set.add(c);
            }
          }
        });
      }

      final list = set.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (!mounted) return;
      setState(() => _categorySuggestions = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _categorySuggestions = []);
    } finally {
      if (mounted) setState(() => _loadingCategories = false);
    }
  }

  CourseStatus _status = CourseStatus.draft;

  bool _saving = false;
  bool _uploadingThumb = false;
  // NEW: reliable instructors storage (uid -> {name, serial})
  Map<String, dynamic> _pickedInstructorMap = {};

  DatabaseReference get _coursesRef => FirebaseDatabase.instance.ref('courses');
  // ===== Teachers from RTDB (users) =====
  static const String _usersPath = 'users';
  DatabaseReference get _usersRef => FirebaseDatabase.instance.ref(_usersPath);

  bool _loadingTeachers = false;

  // uid -> {uid,name,serial}
  Map<String, Map<String, String>> _teachersByUid = {};

  List<Map<String, String>> get _teachersList {
    final list = _teachersByUid.values.toList();
    list.sort((a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""));
    return list;
  }

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher' || r == 'teachers' || r == 'teacher(s)';
  }

  Future<void> _loadTeachers() async {
    if (_loadingTeachers) return;
    if (!mounted) return;

    setState(() => _loadingTeachers = true);

    try {
      final snap = await _usersRef.get();
      final Map<String, Map<String, String>> byUid = {};

      if (snap.exists && snap.value is Map) {
        final all = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in all.entries) {
          final uid = entry.key.toString();
          final raw = entry.value;
          if (raw is! Map) continue;

          final data = Map<String, dynamic>.from(raw);
          if (!_isTeacherRole(data["role"])) continue;

          final first = (data["first_name"] ?? "").toString().trim();
          final last = (data["last_name"] ?? "").toString().trim();
          final full = "$first $last".trim();
          final serial = (data["serial"] ?? "").toString().trim();

          byUid[uid] = {
            "uid": uid,
            "name": full.isEmpty ? uid : full,
            "serial": serial,
          };
        }
      }

      if (!mounted) return;
      setState(() => _teachersByUid = byUid);
    } catch (_) {
      // Non-blocking: if teachers fail to load, manual input still works.
    } finally {
      if (mounted) setState(() => _loadingTeachers = false);
    }
  }

  @override
  void initState() {
    super.initState();

    final initial = widget.initial;

    titleC = TextEditingController(text: initial?.title ?? '');
    categoryC = TextEditingController(text: (initial?.category ?? ''));

    thumbnailUrlC = TextEditingController(text: initial?.thumbnailUrl ?? '');
    shortDescC = TextEditingController(text: initial?.shortDescription ?? '');
    longDescC = TextEditingController(text: initial?.longDescription ?? '');
    durationC = TextEditingController(text: initial?.duration ?? '');
    contentC = TextEditingController(text: initial?.contentText ?? '');
    instructorsC = TextEditingController(
      text: initial?.instructors.join(', ') ?? '',
    );
    levelC = TextEditingController(text: initial?.level ?? '');
    languageC = TextEditingController(text: initial?.language ?? '');
    deliveryC = TextEditingController(text: initial?.deliveryOption ?? '');

    requirementsC = TextEditingController(
      text: initial?.requirementsText ?? '',
    );
    tagsC = TextEditingController(text: initial?.tags.join(', ') ?? '');

    _status = initial?.status ?? CourseStatus.draft;

    // Load delivery checkboxes from DB if exists
    _deliverySelected = initial?.deliveryOptions.toSet() ?? {};

    final existingConfigs = initial?.deliveryConfigs ?? {};

    _deliveryEnabled = {
      'online':
          (_deliverySelected.contains('Online') ||
              _deliverySelected.contains('Flexible')) ||
          (existingConfigs['online']?.enabled == true),
      'live':
          (_deliverySelected.contains('Live') ||
              _deliverySelected.contains('Private')) ||
          (existingConfigs['live']?.enabled == true),
      'recorded':
          _deliverySelected.contains('Recorded') ||
          (existingConfigs['recorded']?.enabled == true),
      'inclass':
          _deliverySelected.contains('In-Class') ||
          (existingConfigs['inclass']?.enabled == true),
    };

    _deliveryFeeControllers = {
      'online': TextEditingController(
        text: existingConfigs['online']?.fee?.toString() ?? '',
      ),
      'live': TextEditingController(
        text: existingConfigs['live']?.fee?.toString() ?? '',
      ),
      'recorded': TextEditingController(
        text: existingConfigs['recorded']?.fee?.toString() ?? '',
      ),
      'inclass': TextEditingController(
        text: existingConfigs['inclass']?.fee?.toString() ?? '',
      ),
    };

    _deliveryAccessModes = {
      'online': existingConfigs['online']?.accessMode ?? 'lifetime',
      'live': existingConfigs['live']?.accessMode ?? 'lifetime',
      'recorded': existingConfigs['recorded']?.accessMode ?? 'lifetime',
      'inclass': existingConfigs['inclass']?.accessMode ?? 'lifetime',
    };

    _deliveryDurationControllers = {
      'online': TextEditingController(
        text: existingConfigs['online']?.accessDurationMonths?.toString() ?? '',
      ),
      'live': TextEditingController(
        text: existingConfigs['live']?.accessDurationMonths?.toString() ?? '',
      ),
      'recorded': TextEditingController(
        text:
            existingConfigs['recorded']?.accessDurationMonths?.toString() ?? '',
      ),
      'inclass': TextEditingController(
        text:
            existingConfigs['inclass']?.accessDurationMonths?.toString() ?? '',
      ),
    };

    _syncOldDeliveryFields();

    _loadCategorySuggestions();

    // ✅ Load existing instructors_map (so we don't wipe it on save)
    Future.microtask(_loadExistingInstructorsMapIfEdit);

    _loadTeachers();
  }

  void _syncOldDeliveryFields() {
    final selected = <String>[];

    if (_deliveryEnabled['online'] == true) selected.add('Flexible');
    if (_deliveryEnabled['live'] == true) selected.add('Private');
    if (_deliveryEnabled['recorded'] == true) selected.add('Recorded');
    if (_deliveryEnabled['inclass'] == true) selected.add('In-Class');

    _deliverySelected = selected.toSet();
    deliveryC.text = selected.join(', ');
  }

  @override
  void dispose() {
    titleC.dispose();
    categoryC.dispose();

    thumbnailUrlC.dispose();
    shortDescC.dispose();
    longDescC.dispose();
    durationC.dispose();
    contentC.dispose();
    instructorsC.dispose();
    levelC.dispose();
    languageC.dispose();
    deliveryC.dispose();

    for (final c in _deliveryFeeControllers.values) {
      c.dispose();
    }
    for (final c in _deliveryDurationControllers.values) {
      c.dispose();
    }
    requirementsC.dispose();
    tagsC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.mode == EditorMode.edit;

    return Scaffold(
      backgroundColor: AdminCoursesScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminCoursesScreen.primaryBlue),
        title: Text(
          isEdit ? 'Edit Course' : 'Add Course',
          style: const TextStyle(
            color: AdminCoursesScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [const SizedBox.shrink()],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                _saving
                    ? 'Saving…'
                    : (isEdit ? 'Save Changes' : 'Create Course'),
              ),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        child: Form(
          key: _formKey,
          child: adminWebBodyFrame(
            context: context,
            maxWidth: 1420,
            child: _buildResponsiveSections([
              _SectionCard(
                title: 'Basic info',
                child: Column(
                  children: [
                    _TextField(
                      controller: titleC,
                      label: 'Title *',
                      hint: 'Course title',
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Title is required'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    _CategoryAutocomplete(
                      controller: categoryC,
                      suggestions: _categorySuggestions,
                      loading: _loadingCategories,
                    ),
                    const SizedBox(height: 12),
                    const SizedBox(height: 12),
                    _ThumbPicker(
                      thumbnailUrlC: thumbnailUrlC,
                      uploading: _uploadingThumb,
                      localFile: _localThumbFile,
                      onPickAndUpload: _pickAndUploadThumbnail,
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: shortDescC,
                      label: 'Short description',
                      hint: '1–2 lines for list/card',
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: longDescC,
                      label: 'Long description',
                      hint: 'Full description',
                      maxLines: 6,
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Structure',
                child: Column(
                  children: [
                    _TextField(
                      controller: durationC,
                      label: 'Duration',
                      hint: 'Example: 6 hours / 12 lessons',
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: contentC,
                      label: 'Content',
                      hint:
                          'Write course content. Example:\n- Module 1: ...\n- Lesson 1: ...',
                      maxLines: 8,
                    ),
                    const SizedBox(height: 12),
                    _InstructorsPicker(
                      loading: _loadingTeachers,
                      currentText: instructorsC.text,
                      teachers: _teachersList,
                      onRefresh: _loadTeachers,
                      initiallySelectedUids: _pickedInstructorMap.keys.toList(),

                      onApply: (pickedUids) {
                        // Convert picked UIDs -> names for old field
                        final names = <String>[];
                        final map = <String, dynamic>{};

                        for (final uid in pickedUids) {
                          final t = _teachersByUid[uid];
                          if (t == null) continue;
                          final name = (t["name"] ?? "").trim();
                          final serial = (t["serial"] ?? "").trim();

                          if (name.isNotEmpty) names.add(name);
                          map[uid] = {"name": name, "serial": serial};
                        }

                        // Store names in the existing controller (old behavior stays)
                        setState(() {
                          instructorsC.text = names.join(', ');
                        });

                        // Save the reliable map into a variable we’ll add next
                        _pickedInstructorMap = map;
                      },
                    ),

                    const SizedBox(height: 12),
                    _TextField(
                      controller: levelC,
                      label: 'Level',
                      hint: 'Beginner / Intermediate / Advanced (or your own)',
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: languageC,
                      label: 'Language',
                      hint: 'English / Arabic / French…',
                    ),
                    const SizedBox(height: 12),
                    _DeliveryConfigsEditor(
                      enabledMap: _deliveryEnabled,
                      feeControllers: _deliveryFeeControllers,
                      accessModes: _deliveryAccessModes,
                      durationControllers: _deliveryDurationControllers,
                      onChanged: () {
                        setState(() {
                          _syncOldDeliveryFields();
                        });
                      },
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Status',
                child: Column(
                  children: [
                    _StatusPicker(
                      value: _status,
                      onChanged: (v) => setState(() => _status = v),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Requirements & tags',
                child: Column(
                  children: [
                    _TextField(
                      controller: requirementsC,
                      label: 'Requirements',
                      hint: 'Example:\n- Basic English\n- Phone or laptop',
                      maxLines: 5,
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: tagsC,
                      label: 'Tags',
                      hint: 'Comma separated (example: english, grammar, kids)',
                    ),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndUploadThumbnail() async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (xfile == null) return;
      setState(() {
        _uploadingThumb = true;
        _localThumbFile = File(xfile.path);
      });

      final url = await widget.uploadClient.uploadFile(file: File(xfile.path));

      if (!mounted) return;

      thumbnailUrlC.text = url;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Thumbnail uploaded ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Could not upload file.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploadingThumb = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final nowTs = ServerValue.timestamp;

      final existing = (widget.initial?.courseCode ?? '').trim();

      final computedCode = widget.mode == EditorMode.create
          ? generateCourseCode(titleC.text)
          : (existing.isNotEmpty ? existing : generateCourseCode(titleC.text));

      final onlineAccessMode = _deliveryAccessModes['online'] ?? 'lifetime';
      final liveAccessMode = _deliveryAccessModes['live'] ?? 'lifetime';
      final recordedAccessMode = _deliveryAccessModes['recorded'] ?? 'lifetime';
      final inclassAccessMode = _deliveryAccessModes['inclass'] ?? 'lifetime';

      final deliveryConfigs = <String, CourseDeliveryConfig>{
        'online': CourseDeliveryConfig(
          enabled: _deliveryEnabled['online'] == true,
          fee: _deliveryEnabled['online'] == true
              ? _parseDoubleOrNull(_deliveryFeeControllers['online']!.text)
              : null,
          accessMode: onlineAccessMode,
          accessDurationMonths:
              (_deliveryEnabled['online'] == true &&
                  onlineAccessMode == 'duration')
              ? _parseIntOrNull(_deliveryDurationControllers['online']!.text)
              : null,
        ),
        'live': CourseDeliveryConfig(
          enabled: _deliveryEnabled['live'] == true,
          fee: _deliveryEnabled['live'] == true
              ? _parseDoubleOrNull(_deliveryFeeControllers['live']!.text)
              : null,
          accessMode: liveAccessMode,
          accessDurationMonths:
              (_deliveryEnabled['live'] == true && liveAccessMode == 'duration')
              ? _parseIntOrNull(_deliveryDurationControllers['live']!.text)
              : null,
        ),
        'recorded': CourseDeliveryConfig(
          enabled: _deliveryEnabled['recorded'] == true,
          fee: _deliveryEnabled['recorded'] == true
              ? _parseDoubleOrNull(_deliveryFeeControllers['recorded']!.text)
              : null,
          accessMode: recordedAccessMode,
          accessDurationMonths:
              (_deliveryEnabled['recorded'] == true &&
                  recordedAccessMode == 'duration')
              ? _parseIntOrNull(_deliveryDurationControllers['recorded']!.text)
              : null,
        ),
        'inclass': CourseDeliveryConfig(
          enabled: _deliveryEnabled['inclass'] == true,
          fee: _deliveryEnabled['inclass'] == true
              ? _parseDoubleOrNull(_deliveryFeeControllers['inclass']!.text)
              : null,
          accessMode: inclassAccessMode,
          accessDurationMonths:
              (_deliveryEnabled['inclass'] == true &&
                  inclassAccessMode == 'duration')
              ? _parseIntOrNull(_deliveryDurationControllers['inclass']!.text)
              : null,
        ),
      };

      final course = Course(
        title: titleC.text.trim(),
        category: categoryC.text.trim(),
        thumbnailUrl: thumbnailUrlC.text.trim(),
        courseCode: computedCode,
        shortDescription: shortDescC.text.trim(),
        longDescription: longDescC.text.trim(),
        duration: durationC.text.trim(),
        contentText: contentC.text.trim(),
        instructors: _splitCsv(instructorsC.text),
        level: levelC.text.trim(),
        language: languageC.text.trim(),
        deliveryOption: deliveryC.text.trim(),
        deliveryOptions: _deliverySelected.toList(),
        deliveryConfigs: deliveryConfigs,
        status: _status,
        requirementsText: requirementsC.text.trim(),
        tags: _splitCsv(tagsC.text),
        updatedAtMs: null,
        trashedAtMs: null,
      );

      if (widget.mode == EditorMode.create) {
        final newRef = _coursesRef.push();

        // NEW: add order_index for new courses (put at end)
        final currentSnap = await _coursesRef.get();
        final current = _parseCoursesMap(
          currentSnap.value,
          orderField: 'order_index',
        );
        int nextIndex = 0;
        if (current.isNotEmpty) {
          final maxIdx = current
              .map((e) => e.orderIndex ?? -1)
              .fold<int>(-1, (p, c) => c > p ? c : p);
          nextIndex = maxIdx + 1;
        }

        await newRef.set({
          ...course.toMap(),
          'instructors_map': _pickedInstructorMap, // ✅ NEW
          'createdAt': nowTs,
          'updatedAt': nowTs,
          'order_index': nextIndex,
        });
      } else {
        final id = widget.courseId!;
        final updateMap = course.toMap()
          ..remove('course_code'); // don’t overwrite

        if (existing.isEmpty) {
          updateMap['course_code'] = computedCode; // fill once
        }

        await _coursesRef.child(id).update({
          ...updateMap,
          'instructors_map': _pickedInstructorMap,
          'price_per_month': null,
          'price_per_level': null,
          'access_type': null,
          'updatedAt': nowTs,
        });
      }

      if (!mounted) return;
      Navigator.of(context).pop(course);
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Could not save course.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static List<String> _splitCsv(String input) {
    return input
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static double? _parseDoubleOrNull(String input) {
    final t = input.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  static int? _parseIntOrNull(String input) {
    final t = input.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  Widget _buildResponsiveSections(List<Widget> sections) {
    final webWide = isWebDesktop(context, minWidth: 1200);
    if (!webWide) {
      return Column(
        children: [
          for (int i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            sections[i],
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final itemWidth = ((c.maxWidth - 12) / 2).clamp(320.0, 640.0);
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final section in sections)
              SizedBox(width: itemWidth, child: section),
          ],
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: AdminCoursesScreen.primaryBlue,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: AdminCoursesScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _CategoryAutocomplete extends StatelessWidget {
  const _CategoryAutocomplete({
    required this.controller,
    required this.suggestions,
    required this.loading,
  });

  final TextEditingController controller;
  final List<String> suggestions;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (TextEditingValue value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<String>.empty();

        // startsWith first, then contains
        final starts = suggestions.where((s) => s.toLowerCase().startsWith(q));
        final contains = suggestions.where(
          (s) => !s.toLowerCase().startsWith(q) && s.toLowerCase().contains(q),
        );

        return [...starts, ...contains].take(10);
      },
      onSelected: (String selected) {
        controller.text = selected;
      },
      fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
        // keep in sync
        textController.value = controller.value;
        textController.addListener(() {
          controller.value = textController.value;
        });

        return TextFormField(
          controller: textController,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Category',
            hintText: loading
                ? 'Loading categories…'
                : 'Type and pick a suggestion',
            filled: true,
            fillColor: AdminCoursesScreen.appBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            suffixIcon: loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _StatusPicker extends StatelessWidget {
  const _StatusPicker({required this.value, required this.onChanged});

  final CourseStatus value;
  final ValueChanged<CourseStatus> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<CourseStatus>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Status',
        filled: true,
        fillColor: AdminCoursesScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      items: CourseStatus.values
          .map(
            (s) =>
                DropdownMenuItem<CourseStatus>(value: s, child: Text(s.label)),
          )
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        onChanged(v);
      },
    );
  }
}

/// Thumbnail picker + upload button
class _ThumbPicker extends StatelessWidget {
  const _ThumbPicker({
    required this.thumbnailUrlC,
    required this.uploading,
    required this.onPickAndUpload,
    required this.localFile,
  });

  final TextEditingController thumbnailUrlC;
  final bool uploading;
  final VoidCallback onPickAndUpload;
  final File? localFile;

  @override
  Widget build(BuildContext context) {
    final url = thumbnailUrlC.text.trim();
    final hasUrl = url.isNotEmpty;

    Widget preview() {
      if (localFile != null) {
        return Image.file(localFile!, fit: BoxFit.cover);
      }
      if (hasUrl) {
        return Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.image_not_supported_outlined),
        );
      }
      return const Icon(Icons.image_outlined);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Thumbnail',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 92,
                height: 92,
                color: AdminCoursesScreen.appBg,
                child: preview(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                children: [
                  FilledButton.icon(
                    onPressed: uploading ? null : onPickAndUpload,
                    icon: uploading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload),
                    label: Text(uploading ? 'Uploading…' : 'Pick & upload'),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: thumbnailUrlC,
                    decoration: InputDecoration(
                      labelText: 'Thumbnail URL',
                      hintText: 'Auto-filled after upload (or paste URL)',
                      filled: true,
                      fillColor: AdminCoursesScreen.appBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// ----------------------------
/// Upload client (PHP endpoint)
/// ----------------------------

class UploadClient {
  UploadClient({required this.endpoint, required this.appId});

  final String endpoint;
  final String appId;

  static void _debug(String message) {
    // no-op in production build
  }

  /// Hardcoded default client per your requirements
  factory UploadClient.defaultClient() {
    return UploadClient(
      endpoint: BackendApi.uri('upload_secure.php').toString(),
      appId: 'dreamenglishacademy',
    );
  }

  /// Uploads file field name "file", and form fields:
  /// - key
  /// - app_id
  /// Header: X-Requested-With: XMLHttpRequest
  /// Returns url from JSON: { success: true, url: "..." }
  Future<String> uploadFile({required File file}) async {
    final uri = await BackendApi.withAuthQuery(Uri.parse(endpoint));
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');
    final token = await BackendApi.authToken();
    final authFields = await BackendApi.authFormFields();

    _debug(
      'upload start endpoint=$endpoint uri=$uri file=${file.path} '
      'uid=${user.uid} tokenLen=${token.length}',
    );

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({
        'X-Requested-With': 'XMLHttpRequest',
        'Authorization': 'Bearer $token',
        'Bearer-Token': token,
        'X-Auth-Token': token,
        'X-Auth-Uid': user.uid,
      })
      ..fields.addAll(authFields)
      ..fields['app_id'] = appId
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();

    _debug(
      'upload response status=${streamed.statusCode} '
      'bodyPreview=${body.length > 200 ? '${body.substring(0, 200)}...' : body}',
    );

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      _debug('upload failed httpStatus=${streamed.statusCode}');
      throw Exception('Upload failed: HTTP ${streamed.statusCode}\n$body');
    }

    // Expecting JSON {success: true, url: "..." }
    final decoded = _tryDecodeJson(body);
    if (decoded == null) {
      _debug('upload failed invalidJson=true');
      throw Exception('Upload failed: invalid JSON response\n$body');
    }

    final success = decoded['success'] == true;
    final url = (decoded['url'] ?? '').toString();

    if (!success || url.trim().isEmpty) {
      _debug('upload failed success=$success urlEmpty=${url.trim().isEmpty}');
      throw Exception('Upload failed: $decoded');
    }

    _debug('upload success url=$url');
    return url;
  }

  static Map<String, dynamic>? _tryDecodeJson(String s) {
    try {
      return (jsonDecode(s) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}

/// ----------------------------
/// Data model
/// ----------------------------

class CourseDeliveryConfig {
  CourseDeliveryConfig({
    required this.enabled,
    required this.fee,
    required this.accessMode,
    required this.accessDurationMonths,
  });

  final bool enabled;
  final double? fee;

  /// "lifetime" or "duration"
  final String accessMode;

  /// used only when accessMode == "duration"
  final int? accessDurationMonths;

  Map<String, dynamic> toMap() {
    return {
      'enabled': enabled,
      'fee': fee,
      'access_mode': accessMode,
      'access_duration_months': accessDurationMonths,
    };
  }

  factory CourseDeliveryConfig.fromMap(dynamic raw) {
    if (raw is! Map) {
      return CourseDeliveryConfig(
        enabled: false,
        fee: null,
        accessMode: 'lifetime',
        accessDurationMonths: null,
      );
    }

    final m = Map<String, dynamic>.from(raw);

    double? parseFee(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString().trim());
    }

    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString().trim());
    }

    final accessMode = (m['access_mode'] ?? 'lifetime')
        .toString()
        .trim()
        .toLowerCase();

    return CourseDeliveryConfig(
      enabled: m['enabled'] == true,
      fee: parseFee(m['fee']),
      accessMode: accessMode.isEmpty ? 'lifetime' : accessMode,
      accessDurationMonths: parseInt(m['access_duration_months']),
    );
  }
}

enum CourseStatus {
  draft,
  published,
  paused,
  archived;

  String get value {
    switch (this) {
      case CourseStatus.draft:
        return 'draft';
      case CourseStatus.published:
        return 'published';
      case CourseStatus.paused:
        return 'paused';
      case CourseStatus.archived:
        return 'archived';
    }
  }

  String get label {
    switch (this) {
      case CourseStatus.draft:
        return 'Draft';
      case CourseStatus.published:
        return 'Published';
      case CourseStatus.paused:
        return 'Paused';
      case CourseStatus.archived:
        return 'Archived';
    }
  }

  static CourseStatus fromValue(String? v) {
    switch ((v ?? '').toLowerCase().trim()) {
      case 'published':
        return CourseStatus.published;
      case 'paused':
        return CourseStatus.paused;
      case 'archived':
        return CourseStatus.archived;
      case 'draft':
      default:
        return CourseStatus.draft;
    }
  }
}

class Course {
  Course({
    required this.title,
    required this.category,
    required this.thumbnailUrl,
    required this.courseCode,
    required this.shortDescription,
    required this.longDescription,
    required this.duration,
    required this.contentText,
    required this.instructors,
    required this.level,
    required this.language,
    required this.deliveryOption,
    required this.deliveryOptions,
    required this.deliveryConfigs,
    required this.status,
    required this.requirementsText,
    required this.tags,
    required this.updatedAtMs,
    required this.trashedAtMs,
    this.orderIndex,
  });

  final String title;
  final String category;
  final String thumbnailUrl;
  final String courseCode;

  final String shortDescription;
  final String longDescription;
  final String duration;
  final String contentText;
  final List<String> instructors;
  final String level;
  final String language;

  final String deliveryOption;
  final List<String> deliveryOptions;

  final Map<String, CourseDeliveryConfig> deliveryConfigs;

  final CourseStatus status;
  final String requirementsText;
  final List<String> tags;

  final int? updatedAtMs;
  final int? trashedAtMs;

  // NEW: ordering
  final int? orderIndex;

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'category': category,
      'thumbnail': thumbnailUrl,
      'course_code': courseCode,
      'short_description': shortDescription,
      'long_description': longDescription,
      'duration': duration,
      'content': contentText,
      'instructors': instructors,
      'level': level,
      'language': language,
      'delivery_option': deliveryOption,
      'delivery_options': deliveryOptions,
      'delivery_configs': deliveryConfigs.map(
        (key, value) => MapEntry(key, value.toMap()),
      ),
      'status': status.value,
      'requirement': requirementsText,
      'tags': tags,
      'updatedAt': updatedAtMs,
      'trashedAt': trashedAtMs,
      if (orderIndex != null) 'order_index': orderIndex,
    };
  }

  factory Course.fromMap(Map<dynamic, dynamic> m) {
    List<String> parseList(dynamic v) {
      if (v == null) return [];
      if (v is List) return v.map((e) => e.toString()).toList();
      if (v is String) {
        return v
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      return [];
    }

    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    Map<String, CourseDeliveryConfig> parseDeliveryConfigs(dynamic v) {
      if (v is! Map) return {};

      final out = <String, CourseDeliveryConfig>{};

      v.forEach((key, value) {
        final k = key.toString().trim().toLowerCase();
        if (k.isEmpty) return;
        out[k] = CourseDeliveryConfig.fromMap(value);
      });

      return out;
    }

    return Course(
      title: (m['title'] ?? '').toString(),
      category: (m['category'] ?? '').toString(),
      thumbnailUrl: _fixUrl((m['thumbnail'] ?? '').toString()),
      courseCode: (m['course_code'] ?? '').toString(),
      shortDescription: (m['short_description'] ?? '').toString(),
      longDescription: (m['long_description'] ?? '').toString(),
      duration: (m['duration'] ?? '').toString(),
      contentText: (m['content'] ?? '').toString(),
      instructors: parseList(m['instructors']),
      level: (m['level'] ?? '').toString(),
      language: (m['language'] ?? '').toString(),

      deliveryOption: (m['delivery_option'] ?? '').toString(),
      deliveryOptions: parseList(m['delivery_options']),
      deliveryConfigs: parseDeliveryConfigs(m['delivery_configs']),
      status: CourseStatus.fromValue(m['status']?.toString()),
      requirementsText: (m['requirement'] ?? '').toString(),
      tags: parseList(m['tags']),
      updatedAtMs: parseInt(m['updatedAt']),
      trashedAtMs: parseInt(m['trashedAt']),
      orderIndex: parseInt(m['order_index']),
    );
  }
}

/// row helper
class _CourseRow {
  _CourseRow({required this.id, required this.course});
  final String id;
  final Course course;

  int? get updatedAtMs => course.updatedAtMs;
  int? get orderIndex => course.orderIndex;
}

/// Firebase snapshot parsing
List<_CourseRow> _parseCoursesMap(dynamic data, {required String? orderField}) {
  if (data == null) return [];

  if (data is Map) {
    final out = <_CourseRow>[];
    data.forEach((key, value) {
      if (key == null || value == null) return;
      if (value is Map) {
        final course = Course.fromMap(value);
        out.add(_CourseRow(id: key.toString(), course: course));
      }
    });
    return out;
  }

  return [];
}

/// ----------------------------
/// Delivery helpers
/// ----------------------------
class _DeliveryConfigsEditor extends StatelessWidget {
  const _DeliveryConfigsEditor({
    required this.enabledMap,
    required this.feeControllers,
    required this.accessModes,
    required this.durationControllers,
    required this.onChanged,
  });

  final Map<String, bool> enabledMap;
  final Map<String, TextEditingController> feeControllers;
  final Map<String, String> accessModes;
  final Map<String, TextEditingController> durationControllers;
  final VoidCallback onChanged;

  static const List<Map<String, String>> _items = [
    {'key': 'online', 'label': 'Flexible'},
    {'key': 'live', 'label': 'Private'},
    {'key': 'recorded', 'label': 'Recorded'},
    {'key': 'inclass', 'label': 'In-Class'},
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AdminCoursesScreen.appBg,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Delivery options',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ..._items.map((item) {
            final key = item['key']!;
            final label = item['label']!;
            final enabled = enabledMap[key] == true;
            final accessMode = accessModes[key] ?? 'lifetime';

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AdminCoursesScreen.uiBorders),
              ),
              child: Column(
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: enabled,
                    title: Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (v) {
                      enabledMap[key] = v == true;
                      onChanged();
                    },
                  ),
                  if (enabled) ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: feeControllers[key],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '$label fee',
                        hintText: 'Example: 49.99',
                        filled: true,
                        fillColor: AdminCoursesScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (_) => onChanged(),
                      validator: (v) {
                        if (!enabled) return null;
                        if (v == null || v.trim().isEmpty) {
                          return 'Fee required';
                        }
                        final n = double.tryParse(v.trim());
                        if (n == null) return 'Must be a number';
                        if (n < 0) return 'Must be >= 0';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: accessMode,
                      decoration: InputDecoration(
                        labelText: '$label access',
                        filled: true,
                        fillColor: AdminCoursesScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'lifetime',
                          child: Text('Lifetime'),
                        ),
                        DropdownMenuItem(
                          value: 'duration',
                          child: Text('Expires after X months'),
                        ),
                      ],
                      onChanged: (v) {
                        accessModes[key] = (v ?? 'lifetime');
                        onChanged();
                      },
                    ),
                    if (accessMode == 'duration') ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: durationControllers[key],
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '$label duration (months)',
                          hintText: 'Example: 4',
                          filled: true,
                          fillColor: AdminCoursesScreen.appBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (_) => onChanged(),
                        validator: (v) {
                          if (!enabled) return null;
                          if ((accessModes[key] ?? 'lifetime') != 'duration') {
                            return null;
                          }
                          if (v == null || v.trim().isEmpty) {
                            return 'Months required';
                          }
                          final n = int.tryParse(v.trim());
                          if (n == null) return 'Must be a whole number';
                          if (n <= 0) return 'Must be greater than 0';
                          return null;
                        },
                      ),
                    ],
                  ],
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

String _fixUrl(String url) {
  final u = url.trim();
  if (u.isEmpty) return u;

  if (u.startsWith('//')) return 'https:$u';
  if (u.startsWith('www.')) return 'https://$u';
  return u;
}

String generateCourseCode(String title) {
  final words = title
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  final initials = words.map((w) => w[0].toUpperCase()).join();

  final number = DateTime.now().millisecondsSinceEpoch % 1000;
  final padded = number.toString().padLeft(3, '0');

  return '$initials-$padded';
}

class _InstructorsPicker extends StatelessWidget {
  const _InstructorsPicker({
    required this.loading,
    required this.currentText,
    required this.teachers,
    required this.onRefresh,
    required this.onApply,
    required this.initiallySelectedUids,
  });

  final bool loading;
  final String currentText;
  final List<Map<String, String>> teachers; // {uid,name,serial}
  final Future<void> Function() onRefresh;
  final ValueChanged<List<String>> onApply;
  final List<String> initiallySelectedUids;

  static List<String> _splitCsv(String input) {
    return input
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final current = _splitCsv(currentText);
    // We will preselect using saved instructors_map UIDs (if provided by parent via currentText display only)
    // The dialog will return UIDs.

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Instructors',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              tooltip: 'Refresh teachers',
              onPressed: loading ? null : () async => onRefresh(),
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 6),

        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AdminCoursesScreen.appBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            current.isEmpty ? 'No instructors selected' : current.join(', '),
            style: TextStyle(color: Colors.black.withValues(alpha: 0.75)),
          ),
        ),

        const SizedBox(height: 10),

        FilledButton.icon(
          onPressed: () async {
            final pickedUids = await showDialog<List<String>>(
              context: context,
              builder: (_) => _TeacherMultiPickDialog(
                teachers: teachers,
                initiallySelectedUids: initiallySelectedUids,
              ),
            );

            if (pickedUids != null) {
              onApply(pickedUids);
            }
          },
          icon: const Icon(Icons.people_alt_rounded),
          label: Text(
            teachers.isEmpty
                ? 'Pick instructors (no teachers found)'
                : (current.isEmpty
                      ? 'Pick instructors'
                      : 'Edit instructors (${current.length})'),
          ),
        ),
      ],
    );
  }
}

class _TeacherMultiPickDialog extends StatefulWidget {
  const _TeacherMultiPickDialog({
    required this.teachers,
    required this.initiallySelectedUids,
  });

  final List<Map<String, String>> teachers; // {uid,name,serial}
  final List<String> initiallySelectedUids; // ✅ UIDs

  @override
  State<_TeacherMultiPickDialog> createState() =>
      _TeacherMultiPickDialogState();
}

class _TeacherMultiPickDialogState extends State<_TeacherMultiPickDialog> {
  final TextEditingController _search = TextEditingController();
  late Set<String> _selected; // ✅ selected by UID

  @override
  void initState() {
    super.initState();
    _selected = widget.initiallySelectedUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();

    final filtered = widget.teachers.where((t) {
      if (q.isEmpty) return true;
      final name = (t["name"] ?? "").toLowerCase();
      final serial = (t["serial"] ?? "").toLowerCase();
      return name.contains(q) || serial.contains(q);
    }).toList();

    return AlertDialog(
      title: const Text('Pick instructors'),
      content: SizedBox(
        width: double.maxFinite,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by name or serial',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No teachers found'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final t = filtered[i];
                        final uid = (t["uid"] ?? "").trim();
                        final name = (t["name"] ?? "").trim();
                        final serial = (t["serial"] ?? "").trim();
                        final checked =
                            uid.isNotEmpty && _selected.contains(uid);

                        return CheckboxListTile(
                          value: checked,
                          onChanged: (v) {
                            setState(() {
                              if (uid.isEmpty) return;
                              if (v == true) {
                                _selected.add(uid);
                              } else {
                                _selected.remove(uid);
                              }
                            });
                          },
                          title: Text(name.isEmpty ? '(Unnamed)' : name),
                          subtitle: serial.isEmpty
                              ? null
                              : Text('Serial: $serial'),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final out = _selected.toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            Navigator.pop(context, out);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
