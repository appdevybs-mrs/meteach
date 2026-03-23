import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:video_player/video_player.dart';
import '../shared/human_error.dart';

class TeacherMediaSheet extends StatefulWidget {
  const TeacherMediaSheet({
    super.key,
    required this.teacherUid,
    required this.teacherName,
  });

  final String teacherUid;
  final String teacherName;

  @override
  State<TeacherMediaSheet> createState() => _TeacherMediaSheetState();
}

class _TeacherMediaSheetState extends State<TeacherMediaSheet> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  bool _loading = true;
  String? _error;

  String _teacherName = '';
  List<String> _photos = [];
  String? _videoUrl;

  VideoPlayerController? _videoController;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    _teacherName = widget.teacherName;
    _loadTeacher();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _loadTeacher() async {
    try {
      final baseRef = FirebaseDatabase.instance.ref(
        'users/${widget.teacherUid}',
      );

      final firstSnap = await baseRef.child('first_name').get();
      final lastSnap = await baseRef.child('last_name').get();
      final photosSnap = await baseRef.child('profile_photos').get();
      final videoSnap = await baseRef.child('intro_video_url').get();

      final first = (firstSnap.value ?? '').toString().trim();
      final last = (lastSnap.value ?? '').toString().trim();
      final dbName = ('$first $last').trim();

      final photos = <String>[];
      final rawPhotos = photosSnap.value;

      if (rawPhotos != null) {
        if (rawPhotos is List) {
          for (final item in rawPhotos) {
            final s = item?.toString().trim() ?? '';
            if (s.isNotEmpty) photos.add(s);
          }
        } else if (rawPhotos is Map) {
          final entries = rawPhotos.entries.toList()
            ..sort((a, b) {
              final ai = int.tryParse(a.key.toString()) ?? 999999;
              final bi = int.tryParse(b.key.toString()) ?? 999999;
              return ai.compareTo(bi);
            });

          for (final e in entries) {
            final s = (e.value ?? '').toString().trim();
            if (s.isNotEmpty) photos.add(s);
          }
        } else {
          final s = rawPhotos.toString().trim();
          if (s.isNotEmpty) photos.add(s);
        }
      }

      String? video;
      final rawVideo = videoSnap.value;
      if (rawVideo != null) {
        final s = rawVideo.toString().trim();
        if (s.isNotEmpty) {
          video = s;
        }
      }

      if (!mounted) return;

      setState(() {
        _teacherName = dbName.isNotEmpty ? dbName : widget.teacherName;
        _photos = photos;
        _videoUrl = video;
      });

      if (_videoUrl != null && _videoUrl!.trim().isNotEmpty) {
        final uri = Uri.tryParse(_videoUrl!);

        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          final controller = VideoPlayerController.networkUrl(uri);
          await controller.initialize();
          await controller.setLooping(false);

          if (!mounted) {
            await controller.dispose();
            return;
          }

          setState(() {
            _videoController = controller;
            _videoReady = true;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not load teacher profile.');
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Widget _buildPhotos() {
    if (_photos.isEmpty) {
      return Container(
        height: 180,
        decoration: BoxDecoration(
          color: appBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: uiBorder),
        ),
        child: const Center(
          child: Icon(Icons.person_rounded, size: 56, color: primaryBlue),
        ),
      );
    }

    return SizedBox(
      height: 220,
      child: PageView.builder(
        itemCount: _photos.length,
        controller: PageController(viewportFraction: 0.92),
        itemBuilder: (context, index) {
          final url = _photos[index];

          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Container(
                color: appBg,
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  errorBuilder: (_, _, _) =>
                      const Center(child: Icon(Icons.image_not_supported)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVideo() {
    if (_videoUrl == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Intro video',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color: primaryBlue,
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            color: Colors.black,
            child: AspectRatio(
              aspectRatio: (_videoReady && _videoController != null)
                  ? _videoController!.value.aspectRatio
                  : 16 / 9,
              child: !_videoReady || _videoController == null
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(_videoController!),
                        IconButton(
                          iconSize: 60,
                          color: Colors.white,
                          onPressed: () {
                            final c = _videoController!;
                            if (c.value.isPlaying) {
                              c.pause();
                            } else {
                              c.play();
                            }
                            setState(() {});
                          },
                          icon: Icon(
                            _videoController!.value.isPlaying
                                ? Icons.pause_circle_filled_rounded
                                : Icons.play_circle_fill_rounded,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _teacherName.isEmpty ? 'Teacher' : _teacherName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: primaryBlue,
                ),
              ),
              const SizedBox(height: 14),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.20)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else ...[
                _buildPhotos(),
                if (_videoUrl != null) ...[
                  const SizedBox(height: 18),
                  _buildVideo(),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
