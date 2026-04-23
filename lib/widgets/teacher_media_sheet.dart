import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
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
  bool _socialLinksVisibleToLearners = true;
  final Map<String, String> _socialLinks = <String, String>{
    'facebook': '',
    'linkedin': '',
    'tiktok': '',
    'extra_url': '',
    'extra_icon': 'globe',
  };

  VideoPlayerController? _videoController;
  bool _videoReady = false;

  static bool _isLikelyUid(String uid) {
    final v = uid.trim();
    if (v.length < 8) return false;
    if (v.contains('/') ||
        v.contains('.') ||
        v.contains('#') ||
        v.contains(r'$') ||
        v.contains('[') ||
        v.contains(']')) {
      return false;
    }
    return true;
  }

  static String _normalizeUrl(String input) {
    final v = input.trim();
    if (v.isEmpty) return '';
    if (v.startsWith('//')) return 'https:$v';
    if (v.startsWith('www.')) return 'https://$v';
    return v;
  }

  static bool _isHttpUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null) return false;
    return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map((key, data) => MapEntry(key.toString().trim(), data));
  }

  IconData _iconForExtraKey(String key) {
    return switch (key.trim()) {
      'instagram' => FontAwesomeIcons.instagram,
      'youtube' => FontAwesomeIcons.youtube,
      'whatsapp' => FontAwesomeIcons.whatsapp,
      'telegram' => FontAwesomeIcons.telegram,
      _ => Icons.public_rounded,
    };
  }

  Future<void> _openExternalUrl(String rawUrl) async {
    final url = _normalizeUrl(rawUrl);
    if (!_isHttpUrl(url)) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this link.')),
      );
    }
  }

  static String _urlFromUnknown(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return _normalizeUrl(raw);
    if (raw is Map) {
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      for (final key in const [
        'url',
        'photo_url',
        'video_url',
        'downloadUrl',
        'download_url',
        'value',
        'src',
        'link',
      ]) {
        final found = m[key];
        if (found == null) continue;
        final candidate = _normalizeUrl(found.toString());
        if (candidate.isNotEmpty) return candidate;
      }
      return '';
    }
    return _normalizeUrl(raw.toString());
  }

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
      final cleanUid = widget.teacherUid.trim();
      if (!_isLikelyUid(cleanUid)) {
        setState(() {
          _error =
              'This instructor profile is not available yet. Please refresh and try again.';
        });
        return;
      }

      final profileRef = FirebaseDatabase.instance.ref(
        'website/teachers/$cleanUid/profile',
      );
      final profileSnap = await profileRef.get();
      final profileVal = profileSnap.value;
      if (profileVal == null || profileVal is! Map) {
        if (!mounted) return;
        setState(() {
          _error =
              'This instructor profile is not available yet. Please refresh and try again.';
        });
        return;
      }

      final profile = profileVal.map((k, v) => MapEntry(k.toString(), v));

      String pickName() {
        for (final key in const ['name', 'display_name', 'full_name']) {
          final raw = (profile[key] ?? '').toString().trim();
          if (raw.isNotEmpty) return raw;
        }
        return widget.teacherName.trim();
      }

      final dbName = pickName();

      final photos = <String>[];
      final rawPhotos = profile['profile_photos'];

      if (rawPhotos != null) {
        if (rawPhotos is List) {
          for (final item in rawPhotos) {
            final s = _urlFromUnknown(item);
            if (s.isNotEmpty && _isHttpUrl(s)) photos.add(s);
          }
        } else if (rawPhotos is Map) {
          final entries = rawPhotos.entries.toList()
            ..sort((a, b) {
              final ai = int.tryParse(a.key.toString()) ?? 999999;
              final bi = int.tryParse(b.key.toString()) ?? 999999;
              return ai.compareTo(bi);
            });

          for (final e in entries) {
            final s = _urlFromUnknown(e.value);
            if (s.isNotEmpty && _isHttpUrl(s)) photos.add(s);
          }
        } else {
          final s = _urlFromUnknown(rawPhotos);
          if (s.isNotEmpty && _isHttpUrl(s)) photos.add(s);
        }
      }

      if (photos.isEmpty) {
        final one = _urlFromUnknown(profile['profile_photo']);
        if (one.isNotEmpty && _isHttpUrl(one)) {
          photos.add(one);
        }
      }

      String? video;
      final rawVideo = profile['intro_video_url'];
      if (rawVideo != null) {
        final s = _urlFromUnknown(rawVideo);
        if (s.isNotEmpty && _isHttpUrl(s)) {
          video = s;
        }
      }

      final socialRaw = _asMap(profile['social_links']);
      final socialLinks = <String, String>{
        'facebook': _normalizeUrl((socialRaw['facebook'] ?? '').toString()),
        'linkedin': _normalizeUrl((socialRaw['linkedin'] ?? '').toString()),
        'tiktok': _normalizeUrl((socialRaw['tiktok'] ?? '').toString()),
        'extra_url': _normalizeUrl((socialRaw['extra_url'] ?? '').toString()),
        'extra_icon': (socialRaw['extra_icon'] ?? 'globe').toString().trim(),
      };
      final visibleToLearners =
          profile['social_links_visible_to_learners'] != false;

      if (!mounted) return;

      setState(() {
        _teacherName = dbName.isNotEmpty ? dbName : widget.teacherName;
        _photos = photos;
        _videoUrl = video;
        _socialLinksVisibleToLearners = visibleToLearners;
        _socialLinks
          ..clear()
          ..addAll(socialLinks);
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
      final human = toHumanError(
        e,
        fallback: 'Could not load this instructor profile right now.',
      );
      final lower = human.toLowerCase();
      setState(() {
        _error = (lower.contains('log in') || lower.contains('session'))
            ? 'Teacher media is currently restricted by database rules. Please make sure `website/teachers` is publicly readable.'
            : human;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
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

  Widget _socialAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: appBg,
            shape: BoxShape.circle,
            border: Border.all(color: uiBorder),
          ),
          child: Icon(icon, color: primaryBlue, size: 18),
        ),
      ),
    );
  }

  Widget _buildSocialLinks() {
    if (!_socialLinksVisibleToLearners) return const SizedBox.shrink();

    final actions = <Widget>[];
    final facebook = _socialLinks['facebook'] ?? '';
    final linkedin = _socialLinks['linkedin'] ?? '';
    final tiktok = _socialLinks['tiktok'] ?? '';
    final extraUrl = _socialLinks['extra_url'] ?? '';
    final extraIconKey = _socialLinks['extra_icon'] ?? 'globe';

    if (_isHttpUrl(facebook)) {
      actions.add(
        _socialAction(
          icon: FontAwesomeIcons.facebook,
          tooltip: 'Facebook',
          onTap: () => _openExternalUrl(facebook),
        ),
      );
    }
    if (_isHttpUrl(linkedin)) {
      actions.add(
        _socialAction(
          icon: FontAwesomeIcons.linkedin,
          tooltip: 'LinkedIn',
          onTap: () => _openExternalUrl(linkedin),
        ),
      );
    }
    if (_isHttpUrl(tiktok)) {
      actions.add(
        _socialAction(
          icon: FontAwesomeIcons.tiktok,
          tooltip: 'TikTok',
          onTap: () => _openExternalUrl(tiktok),
        ),
      );
    }
    if (_isHttpUrl(extraUrl)) {
      actions.add(
        _socialAction(
          icon: _iconForExtraKey(extraIconKey),
          tooltip: 'Extra link',
          onTap: () => _openExternalUrl(extraUrl),
        ),
      );
    }

    if (actions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color: primaryBlue,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: actions),
      ],
    );
  }

  bool _hasVisibleSocialLinks() {
    if (!_socialLinksVisibleToLearners) return false;
    return _isHttpUrl(_socialLinks['facebook'] ?? '') ||
        _isHttpUrl(_socialLinks['linkedin'] ?? '') ||
        _isHttpUrl(_socialLinks['tiktok'] ?? '') ||
        _isHttpUrl(_socialLinks['extra_url'] ?? '');
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
                    border: Border.all(
                      color: Colors.red.withValues(alpha: 0.20),
                    ),
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
                if (_hasVisibleSocialLinks()) ...[
                  const SizedBox(height: 18),
                  _buildSocialLinks(),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
