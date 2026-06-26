import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/services.dart';
import '../shared/learner_web_layout.dart';
import '../shared/media_download.dart';

class LearnerGalleryScreen extends StatefulWidget {
  const LearnerGalleryScreen({super.key});

  @override
  State<LearnerGalleryScreen> createState() => _LearnerGalleryScreenState();
}

class _LearnerGalleryScreenState extends State<LearnerGalleryScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  DatabaseReference _galleryRef() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return _db.child('learner_gallery/$uid');
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

    out.sort((a, b) {
      final aTs = _toInt(a['createdAt']);
      final bTs = _toInt(b['createdAt']);
      return bTs.compareTo(aTs);
    });

    return out;
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  String _fmtDate(dynamic ts) {
    final ms = _toInt(ts);
    if (ms <= 0) return '-';

    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        toolbarHeight: 58,
        backgroundColor: const Color(0xFFF8FBFF),
        elevation: 0,
        surfaceTintColor: const Color(0xFFF8FBFF),
        iconTheme: const IconThemeData(color: primaryBlue),
        titleSpacing: 12,
        title: const Row(
          children: [
            Icon(
              Icons.photo_library_rounded,
              color: Color(0xFF5A6AE6),
              size: 20,
            ),
            SizedBox(width: 8),
            Text(
              'My Gallery',
              style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1540,
        child: SafeArea(
          child: myUid.isEmpty
              ? const Center(
                  child: Text(
                    'Not logged in.',
                    style: TextStyle(
                      color: mainText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                )
              : StreamBuilder<DatabaseEvent>(
                  stream: _galleryRef().onValue,
                  builder: (context, snap) {
                    final items = _itemsFromSnapshot(snap.data?.snapshot.value);

                    if (items.isEmpty) {
                      return ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: uiBorder.withValues(alpha: 0.85),
                              ),
                            ),
                            child: const Text(
                              'No gallery items yet.',
                              style: TextStyle(
                                color: mainText,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      );
                    }

                    return GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1,
                          ),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final type = (item['type'] ?? '')
                            .toString()
                            .trim()
                            .toLowerCase();
                        final url = (item['url'] ?? '').toString().trim();
                        final thumbnailUrl = (item['thumbnailUrl'] ?? '').toString().trim();

                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => _LearnerGalleryViewerScreen(
                                  items: items,
                                  initialIndex: index,
                                ),
                              ),
                            );
                          },
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
                                    _LearnerVideoTile(url: url, thumbnailUrl: thumbnailUrl)
                                  else
                                    CachedNetworkImage(
                                      imageUrl: url,
                                      fit: BoxFit.cover,
                                      memCacheWidth: 440,
                                      memCacheHeight: 440,
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
                                  Positioned(
                                    left: 8,
                                    right: 8,
                                    bottom: 8,
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
                                        children: [
                                          Icon(
                                            type == 'video'
                                                ? Icons.play_circle_fill_rounded
                                                : Icons.photo_rounded,
                                            color: Colors.white,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              type == 'video'
                                                  ? 'Video'
                                                  : 'Photo',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 12,
                                              ),
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
                        );
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _LearnerVideoTile extends StatefulWidget {
  const _LearnerVideoTile({required this.url, this.thumbnailUrl});

  final String url;
  final String? thumbnailUrl;

  @override
  State<_LearnerVideoTile> createState() => _LearnerVideoTileState();
}

class _LearnerVideoTileState extends State<_LearnerVideoTile> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  int _thumbnailAttempt = 0;
  bool _autoRetryScheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.thumbnailUrl == null || widget.thumbnailUrl!.isEmpty) {
      _init();
    }
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

  Widget _buildThumbnailError() {
    if (!_autoRetryScheduled && _thumbnailAttempt < 3) {
      _autoRetryScheduled = true;
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _autoRetryScheduled = false;
          _retryThumbnail();
        }
      });
    }
    return GestureDetector(
      onTap: _retryThumbnail,
      child: Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 34),
      ),
    );
  }

  void _retryThumbnail() {
    setState(() => _thumbnailAttempt++);
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
          Image.network(
            widget.thumbnailUrl!,
            key: ValueKey('thumb_${widget.url}_$_thumbnailAttempt'),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _buildThumbnailError(),
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

class _LearnerVideoPreviewCard extends StatefulWidget {
  const _LearnerVideoPreviewCard({required this.url});

  final String url;

  @override
  State<_LearnerVideoPreviewCard> createState() =>
      _LearnerVideoPreviewCardState();
}

class _LearnerVideoPreviewCardState extends State<_LearnerVideoPreviewCard> {
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
    final position = value.position > duration ? duration : value.position;

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
              aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
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

class _LearnerGalleryViewerScreen extends StatefulWidget {
  const _LearnerGalleryViewerScreen({
    required this.items,
    required this.initialIndex,
  });

  final List<Map<String, dynamic>> items;
  final int initialIndex;

  @override
  State<_LearnerGalleryViewerScreen> createState() =>
      _LearnerGalleryViewerScreenState();
}

class _LearnerGalleryViewerScreenState
    extends State<_LearnerGalleryViewerScreen> {
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
                    ? 'learner_video_${DateTime.now().millisecondsSinceEpoch}.mp4'
                    : 'learner_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
                isVideo: isVideo,
              );
            },
          ),
        ],
        systemOverlayStyle: SystemUiOverlayStyle.light,
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
          final teacherName =
              (item['teacherName'] ?? '').toString().trim();
          final classTitle =
              (item['classTitle'] ?? '').toString().trim();
          final createdAt = _fmtDate(item['createdAt']);

          return Column(
            children: [
              Expanded(
                child: Center(
                  child: isVideo
                      ? _LearnerVideoPreviewCard(url: url)
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
                      isVideo ? 'Video' : 'Photo',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                    if (teacherName.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Teacher: $teacherName',
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
                    if (classTitle.isNotEmpty) ...[
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
