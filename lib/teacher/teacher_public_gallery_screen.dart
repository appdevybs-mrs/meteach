import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../services/backend_api.dart';
import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/media_download.dart';
import '../shared/teacher_web_layout.dart';

String _coursesRelativePathFromUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';

  try {
    final uri = Uri.parse(trimmed);
    final parts = uri.pathSegments;
    final coursesIndex = parts.indexOf('courses');
    if (coursesIndex < 0 || coursesIndex + 1 >= parts.length) return '';
    return parts.sublist(coursesIndex + 1).join('/');
  } catch (_) {
    return '';
  }
}

Future<void> _deleteUploadedCoursesAsset(String fileUrl) async {
  final relPath = _coursesRelativePathFromUrl(fileUrl);
  if (relPath.isEmpty) return;

  final uri = await BackendApi.withAuthQuery(
    BackendApi.uri('delete_file_secure.php'),
  );
  final headers = await BackendApi.authHeaders();
  final authFields = await BackendApi.authFormFields();

  final r = await http.post(
    uri,
    headers: headers,
    body: {'root': 'courses', 'path': relPath, ...authFields},
  );

  final raw = r.body.trim();
  if (!raw.startsWith('{')) {
    throw Exception('Delete endpoint did not return JSON.');
  }

  final data = jsonDecode(raw);
  if (data is! Map<String, dynamic>) {
    throw Exception('Invalid delete response.');
  }

  if (data['success'] == true) return;

  final msg = (data['message'] ?? 'Delete failed').toString();
  if (msg.toLowerCase().contains('not found')) return;
  throw Exception(msg);
}

class TeacherPublicGalleryScreen extends StatefulWidget {
  const TeacherPublicGalleryScreen({super.key});

  @override
  State<TeacherPublicGalleryScreen> createState() =>
      _TeacherPublicGalleryScreenState();
}

class _TeacherPublicGalleryScreenState extends State<TeacherPublicGalleryScreen>
    with SingleTickerProviderStateMixin {
  static const int _pageSize = 4;

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  late final TabController _tab;
  late final Stream<DatabaseEvent> _classesStream;
  late final Stream<DatabaseEvent> _learnerGalleryStream;

  final TextEditingController _myGallerySearchController =
      TextEditingController();
  final TextEditingController _teachersSearchController =
      TextEditingController();

  String _teacherUid = '';

  dynamic _classesCache;
  dynamic _learnerGalleryCache;

  int _visibleMyGalleryCount = _pageSize;
  int _visibleTeachersCount = _pageSize;

  String _myGallerySearch = '';
  String _teachersSearch = '';

  String _myGalleryTypeFilter = 'all';
  String _teachersTypeFilter = 'all';

  AppPalette get palette => appThemeController.palette;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _teacherUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    _classesStream = _db.child('classes').onValue.asBroadcastStream();
    _learnerGalleryStream = _db
        .child('learner_gallery')
        .onValue
        .asBroadcastStream();

    appThemeController.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _myGallerySearchController.dispose();
    _teachersSearchController.dispose();
    _tab.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _fmtDate(dynamic ts) {
    final ms = _toInt(ts);
    if (ms <= 0) return '-';

    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  List<String> _myLearnerUidsFromClasses(dynamic classesValue) {
    if (classesValue is! Map || _teacherUid.isEmpty) return [];

    final raw = Map<dynamic, dynamic>.from(classesValue);
    final out = <String>{};

    raw.forEach((classId, classVal) {
      if (classVal is! Map) return;

      final c = classVal.map((k, vv) => MapEntry(k.toString(), vv));

      bool isMine = false;

      final cur = c['instructor_current'];
      if (cur is Map) {
        final cm = cur.map((kk, vv) => MapEntry(kk.toString(), vv));
        final uid = (cm['uid'] ?? '').toString().trim();
        if (uid.isNotEmpty && uid == _teacherUid) {
          isMine = true;
        }
      }

      if (!isMine) return;

      final learners = c['learners'];
      if (learners is! Map) return;

      final lm = Map<dynamic, dynamic>.from(learners);
      for (final entry in lm.entries) {
        final learnerUid = entry.key.toString().trim();
        if (learnerUid.isNotEmpty) {
          out.add(learnerUid);
        }
      }
    });

    return out.toList();
  }

  List<Map<String, dynamic>> _allMyUploadedGalleryItems({
    required dynamic classesValue,
    required dynamic learnerGalleryValue,
  }) {
    final myLearnerUids = _myLearnerUidsFromClasses(classesValue).toSet();
    if (myLearnerUids.isEmpty) return [];
    if (learnerGalleryValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(learnerGalleryValue);
    final out = <Map<String, dynamic>>[];

    raw.forEach((learnerUid, galleryVal) {
      final uid = learnerUid.toString().trim();
      if (!myLearnerUids.contains(uid)) return;
      if (galleryVal is! Map) return;

      final itemsMap = Map<dynamic, dynamic>.from(galleryVal);

      itemsMap.forEach((itemId, itemVal) {
        if (itemVal is! Map) return;

        final m = itemVal.map((k, vv) => MapEntry(k.toString(), vv));

        final teacherUid = (m['teacherUid'] ?? '').toString().trim();
        final uploadedByRole = (m['uploadedByRole'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        if (teacherUid.isEmpty) return;
        if (teacherUid != _teacherUid) return;
        if (uploadedByRole == 'admin') return;

        out.add({'id': itemId.toString(), 'learnerUid': uid, ...m});
      });
    });

    out.sort((a, b) {
      final aTs = _toInt(a['createdAt']);
      final bTs = _toInt(b['createdAt']);
      return bTs.compareTo(aTs);
    });

    return out;
  }

  List<Map<String, dynamic>> _allOtherTeachersGalleryItems(
    dynamic learnerGalleryValue,
  ) {
    if (learnerGalleryValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(learnerGalleryValue);
    final out = <Map<String, dynamic>>[];

    raw.forEach((learnerUid, galleryVal) {
      if (galleryVal is! Map) return;

      final itemsMap = Map<dynamic, dynamic>.from(galleryVal);

      itemsMap.forEach((itemId, itemVal) {
        if (itemVal is! Map) return;

        final m = itemVal.map((k, vv) => MapEntry(k.toString(), vv));

        final teacherUid = (m['teacherUid'] ?? '').toString().trim();
        final uploadedByRole = (m['uploadedByRole'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        if (teacherUid.isEmpty) return;
        if (teacherUid == _teacherUid) return;
        if (uploadedByRole == 'admin') return;

        out.add({
          'id': itemId.toString(),
          'learnerUid': learnerUid.toString(),
          ...m,
        });
      });
    });

    out.sort((a, b) {
      final aTs = _toInt(a['createdAt']);
      final bTs = _toInt(b['createdAt']);
      return bTs.compareTo(aTs);
    });

    return out;
  }

  List<Map<String, dynamic>> _applySearchAndFilter({
    required List<Map<String, dynamic>> items,
    required String search,
    required String typeFilter,
  }) {
    final q = search.trim().toLowerCase();

    return items.where((item) {
      final type = (item['type'] ?? '').toString().trim().toLowerCase();
      final learnerName = (item['learnerName'] ?? '').toString().toLowerCase();
      final teacherName = (item['teacherName'] ?? '').toString().toLowerCase();
      final classTitle = (item['classTitle'] ?? '').toString().toLowerCase();

      final matchesType = typeFilter == 'all' || type == typeFilter;
      final matchesSearch =
          q.isEmpty ||
          learnerName.contains(q) ||
          teacherName.contains(q) ||
          classTitle.contains(q);

      return matchesType && matchesSearch;
    }).toList();
  }

  List<Map<String, dynamic>> _visibleItems(
    List<Map<String, dynamic>> items,
    int visibleCount,
  ) {
    if (items.isEmpty) return const [];
    final count = visibleCount.clamp(0, items.length);
    return items.take(count).toList();
  }

  Future<bool> _confirmDeleteMyItem() async {
    final p = palette;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.cardBg,
        title: Text(
          'Delete item',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          'Do you want to remove this gallery item from server and database?',
          style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  Future<void> _deleteMyGalleryItem(Map<String, dynamic> item) async {
    final ok = await _confirmDeleteMyItem();
    if (!ok) return;

    final itemId = (item['id'] ?? '').toString().trim();
    final learnerUid = (item['learnerUid'] ?? '').toString().trim();
    final url = (item['url'] ?? '').toString().trim();

    if (itemId.isEmpty || learnerUid.isEmpty) return;

    try {
      if (url.isNotEmpty) {
        await _deleteUploadedCoursesAsset(url);
      }

      await _db.child('learner_gallery/$learnerUid/$itemId').remove();
      if (!mounted) return;
      AppToast.show(
        context,
        'Item deleted from server and database.',
        type: AppToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not delete item.'),
        type: AppToastType.error,
      );
    }
  }

  Future<void> _openLearnerViewer(Map<String, dynamic> item) async {
    final type = (item['type'] ?? '').toString().trim().toLowerCase();
    final url = (item['url'] ?? '').toString().trim();
    final teacherName = (item['teacherName'] ?? '').toString().trim();
    final classTitle = (item['classTitle'] ?? '').toString().trim();
    final learnerName = (item['learnerName'] ?? '').toString().trim();
    final createdAt = _fmtDate(item['createdAt']);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TeacherPublicGalleryViewerScreen(
          type: type,
          url: url,
          uploaderName: teacherName.isEmpty ? 'Teacher' : teacherName,
          learnerName: learnerName,
          classTitle: classTitle,
          createdAt: createdAt,
          onDelete: () => _deleteMyGalleryItem(item),
        ),
      ),
    );
  }

  Future<void> _openTeacherViewer(Map<String, dynamic> item) async {
    final type = (item['type'] ?? '').toString().trim().toLowerCase();
    final url = (item['url'] ?? '').toString().trim();
    final uploaderName = (item['teacherName'] ?? '').toString().trim();
    final learnerName = (item['learnerName'] ?? '').toString().trim();
    final classTitle = (item['classTitle'] ?? '').toString().trim();
    final createdAt = _fmtDate(item['createdAt']);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TeacherPublicGalleryViewerScreen(
          type: type,
          url: url,
          uploaderName: uploaderName.isEmpty ? 'Teacher' : uploaderName,
          learnerName: learnerName,
          classTitle: classTitle,
          createdAt: createdAt,
          onDelete: null,
        ),
      ),
    );
  }

  Widget _buildLoadMoreButton({
    required bool canLoadMore,
    required VoidCallback onTap,
  }) {
    final p = palette;

    if (!canLoadMore) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.expand_more_rounded),
          label: const Text('Load More'),
          style: OutlinedButton.styleFrom(
            foregroundColor: p.primary,
            side: BorderSide(color: p.border.withValues(alpha: 0.9)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchFilterBar({
    required TextEditingController controller,
    required String hintText,
    required String selectedType,
    required ValueChanged<String> onSearchChanged,
    required ValueChanged<String?> onTypeChanged,
  }) {
    final p = palette;

    return Column(
      children: [
        TextField(
          controller: controller,
          onChanged: onSearchChanged,
          decoration: InputDecoration(
            hintText: hintText,
            prefixIcon: Icon(Icons.search_rounded, color: p.primary),
            filled: true,
            fillColor: p.cardBg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: p.border.withValues(alpha: 0.9)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: p.border.withValues(alpha: 0.9)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: p.primary, width: 1.3),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              'Filter:',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: p.cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: p.border.withValues(alpha: 0.9)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: selectedType,
                    isExpanded: true,
                    dropdownColor: p.cardBg,
                    style: TextStyle(
                      color: p.text,
                      fontWeight: FontWeight.w700,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All')),
                      DropdownMenuItem(value: 'photo', child: Text('Photos')),
                      DropdownMenuItem(value: 'video', child: Text('Videos')),
                    ],
                    onChanged: onTypeChanged,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMyGalleryTab() {
    final p = palette;

    return StreamBuilder<DatabaseEvent>(
      stream: _classesStream,
      builder: (context, classesSnap) {
        if (classesSnap.hasError && _classesCache == null) {
          return const Center(
            child: Text('Could not load classes. Please try again.'),
          );
        }
        if (classesSnap.connectionState == ConnectionState.waiting &&
            _classesCache == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final classesValue = classesSnap.data?.snapshot.value;
        if (classesValue != null) {
          _classesCache = classesValue;
        }

        return StreamBuilder<DatabaseEvent>(
          stream: _learnerGalleryStream,
          builder: (context, gallerySnap) {
            if (gallerySnap.hasError && _learnerGalleryCache == null) {
              return const Center(
                child: Text(
                  'Could not load gallery items. Please check your connection.',
                ),
              );
            }
            if (gallerySnap.connectionState == ConnectionState.waiting &&
                _learnerGalleryCache == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final learnerGalleryValue = gallerySnap.data?.snapshot.value;
            if (learnerGalleryValue != null) {
              _learnerGalleryCache = learnerGalleryValue;
            }

            final allItems = _allMyUploadedGalleryItems(
              classesValue: classesValue ?? _classesCache,
              learnerGalleryValue: learnerGalleryValue ?? _learnerGalleryCache,
            );

            final filteredItems = _applySearchAndFilter(
              items: allItems,
              search: _myGallerySearch,
              typeFilter: _myGalleryTypeFilter,
            );

            final visibleItems = _visibleItems(
              filteredItems,
              _visibleMyGalleryCount,
            );

            final photoCount = filteredItems
                .where(
                  (e) => (e['type'] ?? '').toString().toLowerCase() == 'photo',
                )
                .length;

            final videoCount = filteredItems
                .where(
                  (e) => (e['type'] ?? '').toString().toLowerCase() == 'video',
                )
                .length;

            final canLoadMore = visibleItems.length < filteredItems.length;

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [p.primary, p.primary.withValues(alpha: 0.88)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: p.primary.withValues(alpha: 0.16),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'My Gallery',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _TeacherGalleryStatChip(
                            text: '${filteredItems.length} total',
                            icon: Icons.grid_view_rounded,
                          ),
                          _TeacherGalleryStatChip(
                            text: '$photoCount photos',
                            icon: Icons.photo_rounded,
                          ),
                          _TeacherGalleryStatChip(
                            text: '$videoCount videos',
                            icon: Icons.videocam_rounded,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _buildSearchFilterBar(
                  controller: _myGallerySearchController,
                  hintText: 'Search learner or class',
                  selectedType: _myGalleryTypeFilter,
                  onSearchChanged: (value) {
                    setState(() {
                      _myGallerySearch = value;
                      _visibleMyGalleryCount = _pageSize;
                    });
                  },
                  onTypeChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _myGalleryTypeFilter = value;
                      _visibleMyGalleryCount = _pageSize;
                    });
                  },
                ),
                const SizedBox(height: 14),
                if (filteredItems.isEmpty)
                  const _TeacherGalleryEmptyBox(
                    title: 'No gallery items found.',
                    subtitle:
                        'Your uploaded learner gallery items will appear here.',
                  )
                else ...[
                  GridView.builder(
                    itemCount: visibleItems.length,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.88,
                        ),
                    itemBuilder: (context, index) {
                      final item = visibleItems[index];
                      final type = (item['type'] ?? '')
                          .toString()
                          .trim()
                          .toLowerCase();
                      final url = (item['url'] ?? '').toString().trim();
                      final createdAt = _fmtDate(item['createdAt']);
                      final learnerName = (item['learnerName'] ?? '')
                          .toString()
                          .trim();

                      return InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => _openLearnerViewer(item),
                        child: Container(
                          decoration: BoxDecoration(
                            color: p.cardBg,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.85),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 10,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(18),
                                  ),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (type == 'video')
                                        _TeacherGridVideoTile(url: url)
                                      else
                                        Image.network(
                                          url,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => Container(
                                            color: p.soft,
                                            alignment: Alignment.center,
                                            child: Icon(
                                              Icons.broken_image_outlined,
                                              color: p.primary.withValues(
                                                alpha: 0.55,
                                              ),
                                            ),
                                          ),
                                        ),
                                      Positioned(
                                        top: 8,
                                        left: 8,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(
                                              alpha: 0.58,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                type == 'video'
                                                    ? Icons
                                                          .play_circle_fill_rounded
                                                    : Icons.photo_rounded,
                                                color: Colors.white,
                                                size: 14,
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                type == 'video'
                                                    ? 'Video'
                                                    : 'Photo',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  10,
                                  10,
                                  12,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      learnerName.isEmpty
                                          ? 'Learner'
                                          : learnerName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.primary,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      createdAt,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.text.withValues(alpha: 0.72),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  _buildLoadMoreButton(
                    canLoadMore: canLoadMore,
                    onTap: () {
                      setState(() {
                        _visibleMyGalleryCount += _pageSize;
                      });
                    },
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTeachersTab() {
    final p = palette;

    return StreamBuilder<DatabaseEvent>(
      stream: _learnerGalleryStream,
      builder: (context, snap) {
        if (snap.hasError && _learnerGalleryCache == null) {
          return const Center(
            child: Text('Could not load teachers gallery. Please try again.'),
          );
        }
        if (snap.connectionState == ConnectionState.waiting &&
            _learnerGalleryCache == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final learnerGalleryValue = snap.data?.snapshot.value;
        if (learnerGalleryValue != null) {
          _learnerGalleryCache = learnerGalleryValue;
        }

        final allItems = _allOtherTeachersGalleryItems(
          learnerGalleryValue ?? _learnerGalleryCache,
        );

        final filteredItems = _applySearchAndFilter(
          items: allItems,
          search: _teachersSearch,
          typeFilter: _teachersTypeFilter,
        );

        final visibleItems = _visibleItems(
          filteredItems,
          _visibleTeachersCount,
        );

        final photoCount = filteredItems
            .where((e) => (e['type'] ?? '').toString().toLowerCase() == 'photo')
            .length;

        final videoCount = filteredItems
            .where((e) => (e['type'] ?? '').toString().toLowerCase() == 'video')
            .length;

        final canLoadMore = visibleItems.length < filteredItems.length;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [p.primary, p.primary.withValues(alpha: 0.88)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: p.primary.withValues(alpha: 0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Teachers Gallery',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _TeacherGalleryStatChip(
                        text: '${filteredItems.length} total',
                        icon: Icons.grid_view_rounded,
                      ),
                      _TeacherGalleryStatChip(
                        text: '$photoCount photos',
                        icon: Icons.photo_rounded,
                      ),
                      _TeacherGalleryStatChip(
                        text: '$videoCount videos',
                        icon: Icons.videocam_rounded,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buildSearchFilterBar(
              controller: _teachersSearchController,
              hintText: 'Search teacher, learner or class',
              selectedType: _teachersTypeFilter,
              onSearchChanged: (value) {
                setState(() {
                  _teachersSearch = value;
                  _visibleTeachersCount = _pageSize;
                });
              },
              onTypeChanged: (value) {
                if (value == null) return;
                setState(() {
                  _teachersTypeFilter = value;
                  _visibleTeachersCount = _pageSize;
                });
              },
            ),
            const SizedBox(height: 14),
            if (filteredItems.isEmpty)
              const _TeacherGalleryEmptyBox(
                title: 'No other teachers gallery items found.',
                subtitle:
                    'When other teachers upload learner gallery items, they will appear here.',
              )
            else ...[
              GridView.builder(
                itemCount: visibleItems.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.88,
                ),
                itemBuilder: (context, index) {
                  final item = visibleItems[index];
                  final type = (item['type'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();
                  final url = (item['url'] ?? '').toString().trim();
                  final createdAt = _fmtDate(item['createdAt']);
                  final uploader = (item['teacherName'] ?? '')
                      .toString()
                      .trim();
                  final learnerName = (item['learnerName'] ?? '')
                      .toString()
                      .trim();

                  return InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _openTeacherViewer(item),
                    child: Container(
                      decoration: BoxDecoration(
                        color: p.cardBg,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.85),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 10,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(18),
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (type == 'video')
                                    _TeacherGridVideoTile(url: url)
                                  else
                                    Image.network(
                                      url,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        color: p.soft,
                                        alignment: Alignment.center,
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          color: p.primary.withValues(
                                            alpha: 0.55,
                                          ),
                                        ),
                                      ),
                                    ),
                                  Positioned(
                                    top: 8,
                                    left: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.58,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            type == 'video'
                                                ? Icons.play_circle_fill_rounded
                                                : Icons.photo_rounded,
                                            color: Colors.white,
                                            size: 14,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            type == 'video' ? 'Video' : 'Photo',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  uploader.isEmpty ? 'Teacher' : uploader,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.primary,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  learnerName.isEmpty ? 'Learner' : learnerName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.text.withValues(alpha: 0.72),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  createdAt,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.text.withValues(alpha: 0.72),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              _buildLoadMoreButton(
                canLoadMore: canLoadMore,
                onTap: () {
                  setState(() {
                    _visibleTeachersCount += _pageSize;
                  });
                },
              ),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;


    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Text(
          'Gallery',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        actions: [const SizedBox.shrink()],
        bottom: TabBar(
          controller: _tab,
          labelColor: p.primary,
          unselectedLabelColor: p.primary.withValues(alpha: 0.55),
          indicatorColor: p.primary,
          tabs: const [
            Tab(text: 'My Gallery'),
            Tab(text: 'Teachers'),
          ],
        ),
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1640,
        child: SafeArea(
          child: TabBarView(
            controller: _tab,
            children: [_buildMyGalleryTab(), _buildTeachersTab()],
          ),
        ),
      ),
    );
  }
}

class _TeacherGalleryStatChip extends StatelessWidget {
  const _TeacherGalleryStatChip({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherGalleryEmptyBox extends StatelessWidget {
  const _TeacherGalleryEmptyBox({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Column(
        children: [
          Icon(
            Icons.perm_media_outlined,
            size: 56,
            color: p.primary.withValues(alpha: 0.22),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherGridVideoTile extends StatefulWidget {
  const _TeacherGridVideoTile({required this.url});

  final String url;

  @override
  State<_TeacherGridVideoTile> createState() => _TeacherGridVideoTileState();
}

class _TeacherGridVideoTileState extends State<_TeacherGridVideoTile> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );

      await controller.initialize();
      await controller.setLooping(false);
      await controller.pause();
      await controller.seekTo(Duration.zero);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _ready = true;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _ready = false;
      });
    }
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;

    if (_failed) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const Icon(
          Icons.broken_image_outlined,
          color: Colors.white,
          size: 34,
        ),
      );
    }

    if (!_ready || _controller == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.black.withValues(alpha: 0.10),
                Colors.black.withValues(alpha: 0.35),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
        Center(
          child: Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.90),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
        ),
      ],
    );
  }
}

class _TeacherPublicVideoPreviewCard extends StatefulWidget {
  const _TeacherPublicVideoPreviewCard({required this.url});

  final String url;

  @override
  State<_TeacherPublicVideoPreviewCard> createState() =>
      _TeacherPublicVideoPreviewCardState();
}

class _TeacherPublicVideoPreviewCardState
    extends State<_TeacherPublicVideoPreviewCard> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      await controller.initialize();
      await controller.setLooping(false);
      await controller.setPlaybackSpeed(_speed);
      controller.addListener(_videoListener);

      if (!mounted) {
        controller.removeListener(_videoListener);
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _ready = true;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _ready = false;
      });
    }
  }

  void _videoListener() {
    if (!mounted) return;
    setState(() {});
  }

  String _fmtDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _togglePlayPause() async {
    if (_controller == null) return;

    if (_controller!.value.isPlaying) {
      await _controller!.pause();
    } else {
      await _controller!.play();
    }

    if (mounted) setState(() {});
  }

  Future<void> _toggleSpeed() async {
    if (_controller == null) return;

    _speed = _speed == 1.0 ? 2.0 : 1.0;
    await _controller!.setPlaybackSpeed(_speed);

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final c = _controller;
    if (c != null) {
      c.removeListener(_videoListener);
    }
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;

    if (_failed) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.broken_image_outlined,
          color: Colors.white,
          size: 34,
        ),
      );
    }

    if (!_ready || _controller == null) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final value = _controller!.value;
    final duration = value.duration;
    final position = value.position > duration ? duration : value.position;

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(_controller!),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.20),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _togglePlayPause,
                    iconSize: 62,
                    color: Colors.white,
                    icon: Icon(
                      value.isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
              color: Colors.black.withValues(alpha: 0.88),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      min: 0,
                      max: duration.inMilliseconds <= 0
                          ? 1
                          : duration.inMilliseconds.toDouble(),
                      value: position.inMilliseconds
                          .clamp(
                            0,
                            duration.inMilliseconds <= 0
                                ? 1
                                : duration.inMilliseconds,
                          )
                          .toDouble(),
                      activeColor: p.accent,
                      inactiveColor: Colors.white24,
                      onChanged: (value) async {
                        await _controller!.seekTo(
                          Duration(milliseconds: value.toInt()),
                        );
                      },
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        _fmtDuration(position),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _toggleSpeed,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _speed == 1.0 ? '1x' : '2x',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _fmtDuration(duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherPublicGalleryViewerScreen extends StatelessWidget {
  const _TeacherPublicGalleryViewerScreen({
    required this.type,
    required this.url,
    required this.uploaderName,
    required this.learnerName,
    required this.classTitle,
    required this.createdAt,
    required this.onDelete,
  });

  final String type;
  final String url;
  final String uploaderName;
  final String learnerName;
  final String classTitle;
  final String createdAt;
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    final isVideo = type.trim().toLowerCase() == 'video';


    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          isVideo ? 'Video' : 'Photo',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_rounded, color: Colors.white),
            onPressed: () => MediaDownload.downloadUrl(
              context,
              url: url,
              suggestedName: isVideo
                  ? 'teacher_gallery_video_${DateTime.now().millisecondsSinceEpoch}.mp4'
                  : 'teacher_gallery_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: () async {
                await onDelete!.call();
                if (context.mounted) {
                  Navigator.of(context).pop(true);
                }
              },
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.redAccent,
              ),
            ),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: isVideo
                            ? _TeacherPublicVideoPreviewCard(url: url)
                            : InteractiveViewer(
                                minScale: 0.8,
                                maxScale: 4,
                                child: Image.network(
                                  url,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) => const SizedBox(
                                    height: 260,
                                    child: Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.white,
                                        size: 44,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          border: Border(
                            top: BorderSide(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isVideo ? 'Video' : 'Photo',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Uploaded by: $uploaderName',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                                height: 1.2,
                              ),
                            ),
                            if (learnerName.trim().isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                'Learner: $learnerName',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                  height: 1.2,
                                ),
                              ),
                            ],
                            if (classTitle.trim().isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                'Class: $classTitle',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                  height: 1.2,
                                ),
                              ),
                            ],
                            const SizedBox(height: 3),
                            Text(
                              'Added: $createdAt',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                                height: 1.15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
