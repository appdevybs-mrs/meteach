import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/services.dart';
class LearnerGalleryScreen extends StatefulWidget {
  const LearnerGalleryScreen({super.key});

  @override
  State<LearnerGalleryScreen> createState() => _LearnerGalleryScreenState();
}

class _LearnerGalleryScreenState extends State<LearnerGalleryScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
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
      out.add({
        'id': key.toString(),
        ...m,
      });
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
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'My Gallery',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: SafeArea(
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
                      border: Border.all(color: uiBorder.withOpacity(0.85)),
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
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final type =
                (item['type'] ?? '').toString().trim().toLowerCase();
                final url = (item['url'] ?? '').toString().trim();
                final teacherName =
                (item['teacherName'] ?? '').toString().trim();
                final classTitle =
                (item['classTitle'] ?? '').toString().trim();
                final createdAt = _fmtDate(item['createdAt']);

                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _LearnerGalleryViewerScreen(
                          type: type,
                          url: url,
                          teacherName: teacherName,
                          classTitle: classTitle,
                          createdAt: createdAt,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: uiBorder.withOpacity(0.85)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (type == 'video')
                            _LearnerVideoTile(url: url)
                          else
                            Image.network(
                              url,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey.shade200,
                                alignment: Alignment.center,
                                child: const Icon(Icons.broken_image_outlined),
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
                                color: Colors.black.withOpacity(0.58),
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
                                      type == 'video' ? 'Video' : 'Photo',
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

            return ListView(
              padding: const EdgeInsets.all(16),
              children: items.map((item) {
                final type =
                (item['type'] ?? '').toString().trim().toLowerCase();
                final url = (item['url'] ?? '').toString().trim();
                final teacherName =
                (item['teacherName'] ?? '').toString().trim();
                final classTitle =
                (item['classTitle'] ?? '').toString().trim();
                final createdAt = _fmtDate(item['createdAt']);

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: uiBorder.withOpacity(0.85)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (type == 'video')
                        _LearnerVideoPreviewCard(url: url)
                      else
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.network(
                            url,
                            width: double.infinity,
                            height: 220,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              height: 220,
                              color: Colors.grey.shade200,
                              alignment: Alignment.center,
                              child:
                              const Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        ),
                      const SizedBox(height: 10),
                      Text(
                        type == 'video' ? 'Video' : 'Photo',
                        style: const TextStyle(
                          color: primaryBlue,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (teacherName.isNotEmpty)
                        Text(
                          'Teacher: $teacherName',
                          style: TextStyle(
                            color: mainText.withOpacity(0.75),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (classTitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Class: $classTitle',
                          style: TextStyle(
                            color: mainText.withOpacity(0.75),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        'Added: $createdAt',
                        style: TextStyle(
                          color: mainText.withOpacity(0.65),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            );
          },
        ),
      ),
    );
  }
}

class _LearnerVideoTile extends StatelessWidget {
  const _LearnerVideoTile({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          color: Colors.black,
          child: const Center(
            child: Icon(
              Icons.videocam_rounded,
              color: Colors.white70,
              size: 42,
            ),
          ),
        ),
        Container(
          color: Colors.black.withOpacity(0.18),
        ),
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
      controller.setLooping(false);

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

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_controller!),
              IconButton(
                onPressed: () {
                  if (_controller!.value.isPlaying) {
                    _controller!.pause();
                  } else {
                    _controller!.play();
                  }
                  setState(() {});
                },
                iconSize: 54,
                color: Colors.white,
                icon: Icon(
                  _controller!.value.isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _LearnerGalleryViewerScreen extends StatelessWidget {
  const _LearnerGalleryViewerScreen({
    required this.type,
    required this.url,
    required this.teacherName,
    required this.classTitle,
    required this.createdAt,
  });

  final String type;
  final String url;
  final String teacherName;
  final String classTitle;
  final String createdAt;

  static const primaryBlue = Color(0xFF1A2B48);
  static const mainText = Color(0xFF2D2D2D);

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
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: isVideo
                  ? _LearnerVideoPreviewCard(url: url)
                  : InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              border: Border(
                top: BorderSide(color: Colors.white.withOpacity(0.12)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isVideo ? 'Video' : 'Photo',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                if (teacherName.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Teacher: $teacherName',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                if (classTitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Class: $classTitle',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  'Added: $createdAt',
                  style: const TextStyle(
                    color: Colors.white60,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}