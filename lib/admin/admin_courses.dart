

import 'dart:async';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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
          unselectedLabelColor: AdminCoursesScreen.primaryBlue.withOpacity(0.55),
          indicatorColor: AdminCoursesScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Courses'),
            Tab(text: 'Trash'),
          ],
        ),
        actions: [
          // Add only on Courses tab
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              final isCoursesTab = _tabController.index == 0;
              if (!isCoursesTab) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: IconButton(
                  tooltip: 'Add course',
                  onPressed: () async {
                    final created = await Navigator.of(context).push<Course?>(
                      MaterialPageRoute(
                        builder: (_) => CourseEditorScreen(
                          mode: EditorMode.create,
                          uploadClient: UploadClient.defaultClient(),
                        ),
                      ),
                    );
                    if (created != null && mounted) {
                      _showSnack('Course created ✅');
                    }
                  },
                  icon: const Icon(Icons.add_circle_outline, color: AdminCoursesScreen.actionOrange),
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
    final ok = await _confirm(
      title: 'Move to Trash?',
      message:
      'This will remove the course from Courses and move it to Trash.\n\nYou can restore it later.',
      confirmText: 'Move to Trash',
      danger: true,
    );
    if (!ok) return;

    // Write into trash with metadata, then remove from courses
    final trashData = course.toMap()
      ..addAll({
        'trashedAt': ServerValue.timestamp,
        'originalId': courseId,
      });

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
      ..addAll({
        'updatedAt': ServerValue.timestamp,
      });

    await _coursesRef.child(courseId).set(restoreData);
    await _trashRef.child(courseId).remove();

    if (mounted) _showSnack('Restored ✅');
  }

  Future<void> _deletePermanently(String courseId) async {
    final ok = await _confirm(
      title: 'Delete permanently?',
      message:
      'This will permanently delete the course from Trash.\n\nThis cannot be undone.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    await _trashRef.child(courseId).remove();
    if (mounted) _showSnack('Deleted permanently ✅');
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }
}

class _CoursesTab extends StatelessWidget {
  const _CoursesTab({
    required this.coursesRef,
    required this.search,
    required this.statusFilter,
    required this.onSearchChanged,
    required this.onStatusFilterChanged,
    required this.onEdit,
    required this.onChangeStatus,
    required this.onMoveToTrash,
  });

  final DatabaseReference coursesRef;
  final String search;
  final CourseStatus? statusFilter;

  final ValueChanged<String> onSearchChanged;
  final ValueChanged<CourseStatus?> onStatusFilterChanged;

  final Future<void> Function(String courseId, Course course) onEdit;
  final Future<void> Function(String courseId, CourseStatus newStatus)
  onChangeStatus;
  final Future<void> Function(String courseId, Course course) onMoveToTrash;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          hint: 'Search courses…',
          value: search,
          onChanged: onSearchChanged,
          filters: [
            _FilterChipItem(
              label: 'All',
              selected: statusFilter == null,
              onTap: () => onStatusFilterChanged(null),
            ),
            ...CourseStatus.values.map(
                  (s) => _FilterChipItem(
                label: s.label,
                selected: statusFilter == s,
                onTap: () => onStatusFilterChanged(s),
              ),
            ),
          ],
        ),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: coursesRef.onValue,
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
              final items = _parseCoursesMap(data);

              // client-side sorting (newest first)
              items.sort((a, b) => (b.updatedAtMs ?? 0).compareTo(a.updatedAtMs ?? 0));

              final filtered = items.where((x) {
                final matchesSearch = search.trim().isEmpty
                    ? true
                    : x.course.title.toLowerCase().contains(search.toLowerCase()) ||
                    x.course.shortDescription
                        .toLowerCase()
                        .contains(search.toLowerCase()) ||
                    (x.course.tags.join(',').toLowerCase().contains(search.toLowerCase()));
                final matchesStatus = statusFilter == null
                    ? true
                    : x.course.status == statusFilter!;
                return matchesSearch && matchesStatus;
              }).toList();

              if (filtered.isEmpty) {
                return _StateCard(
                  title: 'No courses',
                  message: statusFilter == null && search.trim().isEmpty
                      ? 'Add your first course using the + button.'
                      : 'No results match your filters.',
                  icon: Icons.school_outlined,
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final row = filtered[i];
                  return _CourseCard(
                    courseId: row.id,
                    course: row.course,
                    onEdit: () => onEdit(row.id, row.course),
                    onChangeStatus: (s) => onChangeStatus(row.id, s),
                    onMoveToTrash: () => onMoveToTrash(row.id, row.course),
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
              final items = _parseCoursesMap(data);

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
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          if (filters.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: filters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
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

class _CourseCard extends StatelessWidget {
  const _CourseCard({
    required this.courseId,
    required this.course,
    required this.onEdit,
    required this.onChangeStatus,
    required this.onMoveToTrash,
  });

  final String courseId;
  final Course course;
  final VoidCallback onEdit;
  final ValueChanged<CourseStatus> onChangeStatus;
  final VoidCallback onMoveToTrash;

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

// ✅ show course code (if exists)
                  if (course.courseCode.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      course.courseCode,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.black.withOpacity(0.55),
                      ),
                    ),
                  ],

                  const SizedBox(height: 4),
                  Text(
                    course.shortDescription.isEmpty
                        ? 'No short description'
                        : course.shortDescription,

                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.black.withOpacity(0.65)),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Pill(
                        label: course.status.label,
                        bg: _statusBg(course.status),
                        fg: _statusFg(course.status),
                      ),
                      if (course.level.trim().isNotEmpty) _Pill(label: course.level),
                      if (course.language.trim().isNotEmpty) _Pill(label: course.language),
                      // show each delivery option as its own colored pill
                      ...course.deliveryOptions.map((opt) => _Pill(
                        label: opt,
                        bg: _deliveryBg(opt),
                        fg: _deliveryFg(opt),
                      )),


                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
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
                  const SizedBox(height: 4),
                  Text(
                    course.shortDescription.isEmpty
                        ? 'No short description'
                        : course.shortDescription,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.black.withOpacity(0.65)),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      const _Pill(label: 'Trashed'),
                      if (course.status.label.isNotEmpty) _Pill(label: 'Was: ${course.status.label}'),
                    ],
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
                PopupMenuItem(value: _TrashAction.restore, child: Text('Restore')),
                PopupMenuDivider(),
                PopupMenuItem(value: _TrashAction.deleteForever, child: Text('Delete permanently')),
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
    final hasUrl = url.trim().isNotEmpty;
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
          errorBuilder: (_, __, ___) =>
          const Icon(Icons.image_not_supported_outlined),
        )
            : const Icon(Icons.image_outlined),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    this.bg,
    this.fg,
    this.border,
  });

  final String label;
  final Color? bg;
  final Color? fg;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final background = bg ?? AdminCoursesScreen.appBg;
    final foreground = fg ?? AdminCoursesScreen.primaryBlue;
    final borderColor = border;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: borderColor == null ? null : Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}
Color _statusBg(CourseStatus s) {
  switch (s) {
    case CourseStatus.published:
      return const Color(0xFFDFF7E8); // light green
    case CourseStatus.paused:
      return const Color(0xFFFFF3D6); // light amber
    case CourseStatus.archived:
      return const Color(0xFFE8E8E8); // light gray
    case CourseStatus.draft:
    default:
      return const Color(0xFFE6F0FF); // light blue
  }
}

Color _statusFg(CourseStatus s) {
  switch (s) {
    case CourseStatus.published:
      return const Color(0xFF157A3D); // green
    case CourseStatus.paused:
      return const Color(0xFF9A6B00); // amber/brown
    case CourseStatus.archived:
      return const Color(0xFF444444); // dark gray
    case CourseStatus.draft:
    default:
      return const Color(0xFF1A4FA3); // blue
  }
}

Color _deliveryBg(String d) {
  switch (d.toLowerCase().trim()) {
    case 'recorded':
      return const Color(0xFFEAF2FF); // soft blue
    case 'live':
      return const Color(0xFFE8FFFB); // soft cyan
    case 'hybrid':
      return const Color(0xFFF3E8FF); // soft purple
    case 'in-class':
    case 'in class':
      return const Color(0xFFFFE8EA); // soft pink
    default:
      return AdminCoursesScreen.appBg;
  }
}

Color _deliveryFg(String d) {
  switch (d.toLowerCase().trim()) {
    case 'recorded':
      return const Color(0xFF1A4FA3);
    case 'live':
      return const Color(0xFF007A7A);
    case 'hybrid':
      return const Color(0xFF6A1B9A);
    case 'in-class':
    case 'in class':
      return const Color(0xFFB00020);
    default:
      return AdminCoursesScreen.primaryBlue;
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
                style: TextStyle(color: Colors.black.withOpacity(0.7)),
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
              SizedBox(width: 64, height: 64, child: ColoredBox(color: AdminCoursesScreen.appBg)),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 14, width: 160, child: ColoredBox(color: AdminCoursesScreen.appBg)),
                    SizedBox(height: 10),
                    SizedBox(height: 12, width: 260, child: ColoredBox(color: AdminCoursesScreen.appBg)),
                    SizedBox(height: 10),
                    SizedBox(height: 12, width: 200, child: ColoredBox(color: AdminCoursesScreen.appBg)),
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
  static const List<String> _deliveryOptions = ['Recorded', 'Live', 'Hybrid', 'In-Class'];
  Set<String> _deliverySelected = {};


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
  late final TextEditingController priceMonthC;
  late final TextEditingController priceLevelC;
  late final TextEditingController accessTypeC;
  late final TextEditingController requirementsC;
  late final TextEditingController tagsC;

  List<String> _categorySuggestions = [];
  bool _loadingCategories = false;

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

      final list = set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

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

  DatabaseReference get _coursesRef => FirebaseDatabase.instance.ref('courses');

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
    instructorsC = TextEditingController(text: initial?.instructors.join(', ') ?? '');
    levelC = TextEditingController(text: initial?.level ?? '');
    languageC = TextEditingController(text: initial?.language ?? '');
    deliveryC = TextEditingController(text: initial?.deliveryOption ?? '');
    priceMonthC = TextEditingController(
      text: (initial?.pricePerMonth?.toString() ?? ''),
    );
    priceLevelC = TextEditingController(
      text: (initial?.pricePerLevel?.toString() ?? ''),
    );
    accessTypeC = TextEditingController(text: initial?.accessType ?? '');
    requirementsC = TextEditingController(text: initial?.requirementsText ?? '');
    tagsC = TextEditingController(text: initial?.tags.join(', ') ?? '');

    _status = initial?.status ?? CourseStatus.draft;
    // Delivery spinner default
    // Load delivery checkboxes from DB if exists
    _deliverySelected = initial?.deliveryOptions.toSet() ?? {};

// Keep old string field updated (for display)
    deliveryC.text = _deliverySelected.join(', ');
    if (deliveryC.text.trim().isEmpty) {
      deliveryC.text = (initial?.deliveryOption ?? '').trim();
    }

    _loadCategorySuggestions();

// Price type default (if missing, per month)

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
    priceMonthC.dispose();
    priceLevelC.dispose();
    accessTypeC.dispose();
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
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(_saving ? 'Saving…' : (isEdit ? 'Save Changes' : 'Create Course')),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
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
              const SizedBox(height: 12),

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
                    _TextField(
                      controller: instructorsC,
                      label: 'Instructors',
                      hint: 'Comma separated (example: John, Sarah)',
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
                    _DeliveryCheckboxes(
                      options: _deliveryOptions,
                      selected: _deliverySelected,
                      onChanged: (newSet) {
                        setState(() => _deliverySelected = newSet);
                        deliveryC.text = _deliverySelected.join(', ');
                      },
                    ),


                  ],
                ),
              ),
              const SizedBox(height: 12),

              _SectionCard(
                title: 'Access & pricing',
                child: Column(
                  children: [
                    Column(
                      children: [
                        _TextField(
                          controller: priceMonthC,
                          label: 'Price (per month)',
                          hint: 'Example: 19.99',
                          keyboardType: TextInputType.number,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return null;
                            final n = double.tryParse(v.trim());
                            if (n == null) return 'Must be a number';
                            if (n < 0) return 'Must be >= 0';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        _TextField(
                          controller: priceLevelC,
                          label: 'Price (per level)',
                          hint: 'Example: 49.99',
                          keyboardType: TextInputType.number,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return null;
                            final n = double.tryParse(v.trim());
                            if (n == null) return 'Must be a number';
                            if (n < 0) return 'Must be >= 0';
                            return null;
                          },
                        ),
                      ],
                    ),


                    const SizedBox(height: 12),
                    _TextField(
                      controller: accessTypeC,
                      label: 'Access type',
                      hint: 'Lifetime / Limited / Fixed dates…',
                    ),
                    const SizedBox(height: 12),
                    _StatusPicker(
                      value: _status,
                      onChanged: (v) => setState(() => _status = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

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
            ],
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



      final url = await widget.uploadClient.uploadFile(
        file: File(xfile.path),
      );

      if (!mounted) return;

      thumbnailUrlC.text = url;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thumbnail uploaded ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
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
        pricePerMonth: _parseDoubleOrNull(priceMonthC.text),
        pricePerLevel: _parseDoubleOrNull(priceLevelC.text),
        accessType: accessTypeC.text.trim(),
        status: _status,
        requirementsText: requirementsC.text.trim(),
        tags: _splitCsv(tagsC.text),
        updatedAtMs: null,
        trashedAtMs: null,
      );

      if (widget.mode == EditorMode.create) {
        final newRef = _coursesRef.push();
        await newRef.set({
          ...course.toMap(),
          'createdAt': nowTs,
          'updatedAt': nowTs,
        });
      } else {
        final id = widget.courseId!;
        final updateMap = course.toMap()
          ..remove('course_code'); // default: don’t overwrite

        if (existing.isEmpty) {
          updateMap['course_code'] = computedCode; // fill once
        }

        await _coursesRef.child(id).update({
          ...updateMap,
          'updatedAt': nowTs,
        });

      }

      if (!mounted) return;
      Navigator.of(context).pop(course);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
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
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
  });

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
    this.keyboardType,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
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
        final contains = suggestions.where((s) =>
        !s.toLowerCase().startsWith(q) && s.toLowerCase().contains(q));

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
            hintText: loading ? 'Loading categories…' : 'Type and pick a suggestion',
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
  const _StatusPicker({
    required this.value,
    required this.onChanged,
  });

  final CourseStatus value;
  final ValueChanged<CourseStatus> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<CourseStatus>(
        value: value,
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
              (s) => DropdownMenuItem<CourseStatus>(
            value: s,
            child: Text(s.label),
          ),
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
          errorBuilder: (_, __, ___) =>
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
  UploadClient({
    required this.endpoint,
    required this.appId,
    required this.key,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String endpoint;
  final String appId;
  final String key;
  final http.Client _http;

  /// Hardcoded default client per your requirements
  factory UploadClient.defaultClient() {
    return UploadClient(
      endpoint: 'https://www.yourbridgeschool.com/app/upload.php',
      appId: 'dreamenglishacademy',
      key: 'a7a995d9c499128351d827eaad7285bcc891919b',
    );
  }

  /// Uploads file field name "file", and form fields:
  /// - key
  /// - app_id
  /// Header: X-Requested-With: XMLHttpRequest
  /// Returns url from JSON: { success: true, url: "..." }
  Future<String> uploadFile({required File file}) async {
    final uri = Uri.parse(endpoint);

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({
        'X-Requested-With': 'XMLHttpRequest',
      })
      ..fields['key'] = key
      ..fields['app_id'] = appId
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('Upload failed: HTTP ${streamed.statusCode}\n$body');
    }

    // Expecting JSON {success: true, url: "..."}
    final decoded = _tryDecodeJson(body);
    if (decoded == null) {
      throw Exception('Upload failed: invalid JSON response\n$body');
    }

    final success = decoded['success'] == true;
    final url = (decoded['url'] ?? '').toString();

    if (!success || url.trim().isEmpty) {
      throw Exception('Upload failed: $decoded');
    }

    return url;
  }

  static Map<String, dynamic>? _tryDecodeJson(String s) {
    try {
      // ignore: avoid_dynamic_calls
      return (jsonDecode(s) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}

// Needed for jsonDecode

/// ----------------------------
/// Data model
/// ----------------------------

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
    required this.pricePerMonth,
    required this.pricePerLevel,
    required this.accessType,
    required this.status,
    required this.requirementsText,
    required this.tags,
    required this.updatedAtMs,
    required this.trashedAtMs,
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

  final double? pricePerMonth;
  final double? pricePerLevel;

  final String accessType;
  final CourseStatus status;
  final String requirementsText;
  final List<String> tags;

  final int? updatedAtMs;
  final int? trashedAtMs;

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
      'price_per_month': pricePerMonth,
      'price_per_level': pricePerLevel,
      'access_type': accessType,
      'status': status.value,
      'requirement': requirementsText,
      'tags': tags,
      'updatedAt': updatedAtMs,
      'trashedAt': trashedAtMs,
    };
  }

  factory Course.fromMap(Map<dynamic, dynamic> m) {
    double? parsePrice(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

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
      pricePerMonth: parsePrice(m['price_per_month']),
      pricePerLevel: parsePrice(m['price_per_level']),
      accessType: (m['access_type'] ?? '').toString(),
      status: CourseStatus.fromValue(m['status']?.toString()),
      requirementsText: (m['requirement'] ?? '').toString(),
      tags: parseList(m['tags']),
      updatedAtMs: parseInt(m['updatedAt']),
      trashedAtMs: parseInt(m['trashedAt']),
    );
  }
}



/// row helper
class _CourseRow {
  _CourseRow({required this.id, required this.course});
  final String id;
  final Course course;

  int? get updatedAtMs => course.updatedAtMs;
}

/// Firebase snapshot parsing
List<_CourseRow> _parseCoursesMap(dynamic data) {
  if (data == null) return [];

  // Firebase can return Map<Object?, Object?>
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
/// Delivery + Price Type helpers
/// ----------------------------



class _DeliveryCheckboxes extends StatelessWidget {
  const _DeliveryCheckboxes({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

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
            'Delivery option',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          ...options.map((opt) {
            final isOn = selected.contains(opt);
            return CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: isOn,
              title: Text(opt),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) {
                final next = {...selected};
                if (v == true) {
                  next.add(opt);
                } else {
                  next.remove(opt);
                }
                onChanged(next);
              },
            );
          }).toList(),
        ],
      ),
    );
  }
}
String _fixUrl(String url) {
  final u = url.trim();
  if (u.isEmpty) return u;

  // if it starts with //example.com/image.jpg => add https:
  if (u.startsWith('//')) return 'https:$u';

  // if it starts with www.example.com => add https://
  if (u.startsWith('www.')) return 'https://$u';

  // if it already has http/https => keep it
  return u;
}
String generateCourseCode(String title) {
  final words = title
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  final initials = words
      .map((w) => w[0].toUpperCase())
      .join();

  final number = DateTime.now().millisecondsSinceEpoch % 1000;
  final padded = number.toString().padLeft(3, '0');

  return '$initials-$padded';
}
