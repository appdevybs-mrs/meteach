import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../services/backend_api.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/media_download.dart';

enum _SortOrder { newest, oldest }

String _teacherAbbr(String name) {
  if (name.isEmpty) return '';
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.length >= 2) {
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
  return name.length >= 2 ? name.substring(0, 2).toUpperCase() : name.toUpperCase();
}

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

Future<void> _deleteUploadedFile(String fileUrl) async {
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

class AdminGalleryScreen extends StatefulWidget {
  const AdminGalleryScreen({super.key});

  @override
  State<AdminGalleryScreen> createState() => _AdminGalleryScreenState();
}

class _AdminGalleryScreenState extends State<AdminGalleryScreen>
    with SingleTickerProviderStateMixin {
  static const primaryBlue = Color(0xFF1A2B48);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  late final TabController _tab;

  dynamic _publicCache;
  dynamic _learnerCache;
  dynamic _teacherCache;

  List<Map<String, dynamic>>? _mergedCache;

  _SortOrder _sort = _SortOrder.newest;

  StreamSubscription<DatabaseEvent>? _publicSub;
  StreamSubscription<DatabaseEvent>? _learnerSub;
  StreamSubscription<DatabaseEvent>? _teacherSub;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() {
      if (mounted) setState(() {});
    });

    _publicSub =
        _db.child('public_gallery_teasers').onValue.asBroadcastStream().listen(
          (e) {
            if (!mounted) return;
            _publicCache = e.snapshot.value;
            _mergedCache = null;
            setState(() {});
          },
        );
    _learnerSub =
        _db.child('learner_gallery').onValue.asBroadcastStream().listen(
          (e) {
            if (!mounted) return;
            _learnerCache = e.snapshot.value;
            _mergedCache = null;
            setState(() {});
          },
        );
    _teacherSub =
        _db.child('website/teachers').onValue.asBroadcastStream().listen(
          (e) {
            if (!mounted) return;
            _teacherCache = e.snapshot.value;
            _mergedCache = null;
            setState(() {});
          },
        );
  }

  @override
  void dispose() {
    _tab.dispose();
    _publicSub?.cancel();
    _learnerSub?.cancel();
    _teacherSub?.cancel();
    super.dispose();
  }

  bool get _hasAnyData =>
      _publicCache != null || _learnerCache != null || _teacherCache != null;

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _normUrl(dynamic raw) {
    final v = (raw ?? '').toString().trim();
    if (v.isEmpty) return '';
    if (v.startsWith('//')) return 'https:$v';
    if (v.startsWith('www.')) return 'https://$v';
    return v;
  }

  static bool _isHttpUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static List<String> _urlsFromUnknown(dynamic raw) {
    final out = <String>[];
    void addOne(dynamic v) {
      final s = _normUrl(v);
      if (s.isNotEmpty && _isHttpUrl(s)) out.add(s);
    }
    if (raw is List) {
      for (final item in raw) {
        addOne(item);
      }
      return out;
    }
    if (raw is Map) {
      final entries = raw.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final e in entries) {
        addOne(e.value);
      }
      return out;
    }
    if (raw is String) {
      addOne(raw);
    }
    return out;
  }

  List<Map<String, dynamic>> _itemsFromSnapshot(dynamic value) {
    if (value is! Map) return [];
    final raw = Map<dynamic, dynamic>.from(value);
    final out = <Map<String, dynamic>>[];
    raw.forEach((key, val) {
      if (val is! Map) return;
      final m = val.map((k, vv) => MapEntry(k.toString(), vv));
      out.add({'id': key.toString(), ...m});
    });
    out.sort(
      (a, b) => _toInt(b['createdAt']).compareTo(_toInt(a['createdAt'])),
    );
    return out;
  }

  List<Map<String, dynamic>> _computeMerged() {
    final result = <Map<String, dynamic>>[];

    if (_publicCache is Map) {
      final items = _itemsFromSnapshot(_publicCache);
      for (final item in items) {
        item['_source'] = 'public';
        item['_sourceLabel'] = 'Public Gallery';
        result.add(item);
      }
    }

    if (_learnerCache is Map) {
      final learners = Map<dynamic, dynamic>.from(_learnerCache as Map);
      learners.forEach((learnerUidRaw, galleryRaw) {
        if (galleryRaw is! Map) return;
        final learnerUid = learnerUidRaw.toString().trim();
        if (learnerUid.isEmpty) return;
        final items = _itemsFromSnapshot(galleryRaw);
        String learnerName = '';
        for (final item in items) {
          final ln = (item['learnerName'] ?? '').toString().trim();
          if (ln.isNotEmpty) {
            learnerName = ln;
            break;
          }
        }
        if (learnerName.isEmpty) learnerName = learnerUid;
        for (final item in items) {
          item['_source'] = 'learner';
          item['_sourceLabel'] = 'Learner: $learnerName';
          item['_learnerUid'] = learnerUid;
          result.add(item);
        }
      });
    }

    if (_teacherCache is Map) {
      final teachers = Map<dynamic, dynamic>.from(_teacherCache as Map);
      teachers.forEach((uidRaw, teacherNodeRaw) {
        if (teacherNodeRaw is! Map) return;
        final teacherNode =
            teacherNodeRaw.map((k, v) => MapEntry(k.toString(), v));
        final profile = teacherNode['profile'];
        if (profile is! Map) return;
        final profileMap =
            profile.map((k, v) => MapEntry(k.toString(), v));

        final photoUrls = _urlsFromUnknown(profileMap['profile_photos']);
        if (photoUrls.isEmpty) {
          final one = _normUrl(profileMap['profile_photo']);
          if (one.isNotEmpty && _isHttpUrl(one)) photoUrls.add(one);
        }

        final introVideoUrl = _normUrl(profileMap['intro_video_url']);
        final safeVideoUrl = _isHttpUrl(introVideoUrl) ? introVideoUrl : '';

        final uid = uidRaw.toString().trim();
        if (uid.isEmpty) return;

        for (final photoUrl in photoUrls) {
          result.add({
            'id': '${uid}_photo_${photoUrl.hashCode}',
            'url': photoUrl,
            'type': 'photo',
            'createdAt': 0,
            '_source': 'teacher',
            '_sourceLabel': 'Teacher Profile',
            '_teacherUid': uid,
          });
        }

        if (safeVideoUrl.isNotEmpty) {
          result.add({
            'id': '${uid}_video',
            'url': safeVideoUrl,
            'type': 'video',
            'createdAt': 0,
            '_source': 'teacher',
            '_sourceLabel': 'Teacher Profile',
            '_teacherUid': uid,
          });
        }
      });
    }

    result.sort((a, b) {
      final cmp = _toInt(a['createdAt']).compareTo(_toInt(b['createdAt']));
      return _sort == _SortOrder.newest ? -cmp : cmp;
    });
    return result;
  }

  List<Map<String, dynamic>> _merged() {
    return _mergedCache ??= _computeMerged();
  }

  List<Map<String, dynamic>> _filtered(String type) {
    final all = _merged();
    if (type == 'all') return all;
    return all.where((item) {
      final t = (item['type'] ?? '').toString().trim().toLowerCase();
      return t == type;
    }).toList();
  }

  Future<bool> _confirmDelete() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item'),
        content: const Text(
          'Delete this item? It will be removed from the server and database.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final ok = await _confirmDelete();
    if (!ok) return;

    final source = (item['_source'] ?? '').toString().trim();
    final id = (item['id'] ?? '').toString().trim();
    final url = (item['url'] ?? '').toString().trim();

    try {
      if (url.isNotEmpty) {
        await _deleteUploadedFile(url);
      }

      if (source == 'public' && id.isNotEmpty) {
        await _db.child('public_gallery_teasers/$id').remove();
      } else if (source == 'learner') {
        final learnerUid =
            (item['_learnerUid'] ?? '').toString().trim();
        if (learnerUid.isNotEmpty && id.isNotEmpty) {
          await _db.child('learner_gallery/$learnerUid/$id').remove();
        }
      } else if (source == 'teacher') {
        final teacherUid =
            (item['_teacherUid'] ?? '').toString().trim();
        if (teacherUid.isNotEmpty) {
          final type =
              (item['type'] ?? '').toString().trim().toLowerCase();
          if (type == 'video') {
            await _db
                .child(
                'website/teachers/$teacherUid/profile/intro_video_url')
                .remove();
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              toHumanError(e, fallback: 'Could not delete item.'),
            ),
          ),
        );
      }
    }
  }

  void _openViewer(List<Map<String, dynamic>> items, int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminGalleryViewerScreen(
          items: items,
          initialIndex: index,
          onDelete: (i) async {
            await _deleteItem(items[i]);
          },
        ),
      ),
    );
  }

  (int, int, int) _counts() {
    final all = _merged();
    var photos = 0;
    var videos = 0;
    for (final item in all) {
      final type = (item['type'] ?? '').toString().trim().toLowerCase();
      if (type == 'photo') { photos++; }
      else if (type == 'video') { videos++; }
    }
    return (all.length, photos, videos);
  }

  Widget _buildStats() {
    final (total, photos, videos) = _counts();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        'All: $total  ·  Photos: $photos  ·  Videos: $videos',
        style: TextStyle(
          color: mainText.withValues(alpha: 0.65),
          fontWeight: FontWeight.w800,
          fontSize: 12,
          height: 1.3,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Row(
          children: [
            const Text(
              'Gallery',
              style: TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () {
                setState(() {
                  _sort = _SortOrder.newest;
                  _mergedCache = null;
                });
              },
              child: Icon(
                Icons.arrow_downward_rounded,
                size: 18,
                color: _sort == _SortOrder.newest
                    ? primaryBlue
                    : primaryBlue.withValues(alpha: 0.3),
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  _sort = _SortOrder.oldest;
                  _mergedCache = null;
                });
              },
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 18,
                color: _sort == _SortOrder.oldest
                    ? primaryBlue
                    : primaryBlue.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tab,
          labelColor: primaryBlue,
          unselectedLabelColor: primaryBlue.withValues(alpha: 0.55),
          indicatorColor: primaryBlue,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Videos'),
            Tab(text: 'Pics'),
          ],
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: SafeArea(
          child: !_hasAnyData
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _buildStats(),
                    Expanded(
                      child: TabBarView(
                        controller: _tab,
                        children: [
                          _buildGrid('all'),
                          _buildGrid('video'),
                          _buildGrid('photo'),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildGrid(String filterType) {
    final items = _filtered(filterType);

    if (items.isEmpty) {
      return Center(
        child: Text(
          filterType == 'all'
              ? 'No media items found.'
              : filterType == 'video'
                  ? 'No videos found.'
                  : 'No photos found.',
          style: const TextStyle(
            color: mainText,
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.9,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        final type =
            (item['type'] ?? '').toString().trim().toLowerCase();
        final url = (item['url'] ?? '').toString().trim();
        final thumbnailUrl =
            (item['thumbnailUrl'] ?? '').toString().trim();
        final sourceLabel =
            (item['_sourceLabel'] ?? '').toString().trim();
        final uploaderName =
            (item['uploadedByName'] ?? '').toString().trim();
        final teacherName =
            (item['teacherName'] ?? '').toString().trim();
        final displayName = uploaderName.isNotEmpty
            ? uploaderName
            : teacherName.isNotEmpty
            ? teacherName
            : '';
        final abbr = _teacherAbbr(displayName);
        final dateLabel = _fmtDate(item['createdAt']);

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openViewer(items, index),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: uiBorder.withValues(alpha: 0.85),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (type == 'video')
                    _AdminGalleryVideoTile(
                      url: url,
                      thumbnailUrl: thumbnailUrl,
                    )
                  else
                    CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: 220,
                      placeholder: (_, _) => Container(
                        color: Colors.grey.shade100,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                      errorWidget: (_, _, _) => Container(
                        color: Colors.grey.shade200,
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.broken_image_outlined,
                        ),
                      ),
                    ),
                  if (abbr.isNotEmpty)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          dateLabel != '-' ? '$abbr · $dateLabel' : abbr,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 9,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: primaryBlue.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        sourceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 9,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _fmtDate(dynamic ts) {
    final ms = _toInt(ts);
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';
}

class _AdminGalleryVideoTile extends StatefulWidget {
  const _AdminGalleryVideoTile({required this.url, this.thumbnailUrl});

  final String url;
  final String? thumbnailUrl;

  @override
  State<_AdminGalleryVideoTile> createState() =>
      _AdminGalleryVideoTileState();
}

class _AdminGalleryVideoTileState extends State<_AdminGalleryVideoTile> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.thumbnailUrl == null || widget.thumbnailUrl!.isEmpty) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final controller =
      VideoPlayerController.networkUrl(Uri.parse(widget.url));

      await controller.initialize().timeout(const Duration(seconds: 10));
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
    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: widget.thumbnailUrl!,
            fit: BoxFit.cover,
            memCacheWidth: 220,
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
          Container(color: Colors.black.withValues(alpha: 0.18)),
          const Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 52,
            ),
          ),
        ],
      );
    }

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
        Container(color: Colors.black.withValues(alpha: 0.18)),
        const Center(
          child: Icon(
            Icons.play_circle_fill_rounded,
            color: Colors.white,
            size: 52,
          ),
        ),
      ],
    );
  }
}

class _AdminGalleryVideoPreviewCard extends StatefulWidget {
  const _AdminGalleryVideoPreviewCard({required this.url});

  final String url;

  @override
  State<_AdminGalleryVideoPreviewCard> createState() =>
      _AdminGalleryVideoPreviewCardState();
}

class _AdminGalleryVideoPreviewCardState
    extends State<_AdminGalleryVideoPreviewCard> {
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
      final controller =
      VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await controller.initialize().timeout(const Duration(seconds: 10));
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
    if (_failed) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(14),
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
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final value = _controller!.value;
    final duration = value.duration;
    final position =
    value.position > duration ? duration : value.position;

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio:
              value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(_controller!),
                  IconButton(
                    onPressed: _togglePlayPause,
                    iconSize: 54,
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
                      activeColor: Colors.white,
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

class AdminGalleryViewerScreen extends StatefulWidget {
  const AdminGalleryViewerScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    this.onDelete,
  });

  final List<Map<String, dynamic>> items;
  final int initialIndex;
  final Future<void> Function(int index)? onDelete;

  @override
  State<AdminGalleryViewerScreen> createState() =>
      _AdminGalleryViewerScreenState();
}

class _AdminGalleryViewerScreenState
    extends State<AdminGalleryViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _precacheAdjacent(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _precacheAdjacent(int index) {
    for (final offset in [-2, -1, 0, 1, 2]) {
      final i = index + offset;
      if (i < 0 || i >= widget.items.length) continue;
      final type =
          (widget.items[i]['type'] ?? '').toString().trim().toLowerCase();
      if (type == 'video') continue;
      final url = (widget.items[i]['url'] ?? '').toString().trim();
      if (url.isNotEmpty) {
        precacheImage(NetworkImage(url), context);
      }
    }
  }

  String _fmtDate(dynamic ts) {
    final ms = _toInt(ts);
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_currentIndex + 1} / ${widget.items.length}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: [
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_rounded, color: Colors.white),
            onPressed: () {
              final item = widget.items[_currentIndex];
              final isVideo =
                  (item['type'] ?? '').toString().trim().toLowerCase() ==
                      'video';
              final url = (item['url'] ?? '').toString().trim();
              MediaDownload.downloadUrl(
                context,
                url: url,
                suggestedName: isVideo
                    ? 'gallery_video_${DateTime.now().millisecondsSinceEpoch}.mp4'
                    : 'gallery_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
                isVideo: isVideo,
              );
            },
          ),
          if (widget.onDelete != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: () async {
                await widget.onDelete!(_currentIndex);
                if (context.mounted) {
                  Navigator.of(context).pop(true);
                }
              },
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.white,
              ),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.items.length,
        onPageChanged: (i) {
          setState(() => _currentIndex = i);
          _precacheAdjacent(i);
        },
        itemBuilder: (context, index) {
          final item = widget.items[index];
          final type =
              (item['type'] ?? '').toString().trim().toLowerCase();
          final url = (item['url'] ?? '').toString().trim();
          final thumbnailUrl =
              (item['thumbnailUrl'] ?? '').toString().trim();
          final isVideo = type == 'video';
          final sourceLabel =
              (item['_sourceLabel'] ?? '').toString().trim();
          final uploaderName =
              (item['uploadedByName'] ?? '').toString().trim();
          final teacherName =
              (item['teacherName'] ?? '').toString().trim();
          final displayUploader = uploaderName.isNotEmpty
              ? uploaderName
              : teacherName.isNotEmpty
              ? teacherName
              : 'Admin';
          final createdAt = _fmtDate(item['createdAt']);

          return Column(
            children: [
              Expanded(
                child: Center(
                  child: isVideo
                      ? _AdminGalleryVideoPreviewCard(url: url)
                      : _buildImageViewer(url, thumbnailUrl),
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
                      sourceLabel.isNotEmpty ? sourceLabel : (isVideo ? 'Video' : 'Photo'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      displayUploader != 'Admin'
                          ? '${_teacherAbbr(displayUploader)} · $createdAt'
                          : createdAt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildImageViewer(String url, String thumbnailUrl) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final memCacheWidth =
            (constraints.maxWidth * devicePixelRatio).round().clamp(320, 2400);
        final memCacheHeight =
            (constraints.maxHeight * devicePixelRatio).round().clamp(320, 2400);

        return Stack(
          children: [
            if (thumbnailUrl.isNotEmpty)
              Positioned.fill(
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: thumbnailUrl,
                    fit: BoxFit.contain,
                    memCacheWidth: memCacheWidth,
                    memCacheHeight: memCacheHeight,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.contain,
                  memCacheWidth: memCacheWidth,
                  memCacheHeight: memCacheHeight,
                  placeholder: (_, _) => thumbnailUrl.isNotEmpty
                      ? const SizedBox.shrink()
                      : const SizedBox(
                    height: 260,
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                  progressIndicatorBuilder: (context, _, progress) {
                    return SizedBox(
                      height: 260,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              value: progress.progress,
                              color: Colors.white54,
                              strokeWidth: 2.5,
                            ),
                            if (progress.progress != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '${(progress.progress! * 100).toInt()}%',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                  errorWidget: (_, _, _) => const SizedBox(
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
          ],
        );
      },
    );
  }
}
