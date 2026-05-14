import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_theme.dart';
import '../shared/app_feedback.dart';
import '../shared/learner_web_layout.dart';
import '../shared/material_webview_screen.dart';
import '../shared/responsive_layout.dart';
import '../shared/profile_avatar.dart';
import '../shared/shared_story_study_screen.dart';
import '../services/story_preload_service.dart';

class LearnerStoriesScreen extends StatefulWidget {
  const LearnerStoriesScreen({super.key});

  @override
  State<LearnerStoriesScreen> createState() => _LearnerStoriesScreenState();
}

class _LearnerStoriesScreenState extends State<LearnerStoriesScreen> {
  final DatabaseReference _storiesRef = FirebaseDatabase.instance.ref(
    'stories',
  );
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _searchController = TextEditingController();
  final Map<String, String> _teacherPhotoCache = {};
  final Map<String, Future<String>> _teacherPhotoPending = {};
  final Set<String> _thumbPrecachedUrls = <String>{};

  int _thumbPrecacheRunId = 0;
  String _lastThumbPrecacheKey = '';

  String _searchQuery = '';
  String _genreFilter = 'all';
  String _levelFilter = 'all';
  String _lengthFilter = 'all';
  String _sortBy = 'updated_desc';

  bool _showSearch = false;
  bool _showFilters = false;

  static const int _thumbPrecacheBatchSize = 4;

  String _normalizeMediaUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('//')) value = 'https:$value';
    if (value.startsWith('www.')) value = 'https://$value';
    if (value.startsWith('http://')) {
      value = 'https://${value.substring('http://'.length)}';
    }
    final uri = Uri.tryParse(value);
    if (uri == null) return '';
    if (uri.scheme != 'https' && uri.scheme != 'http') return '';
    if (uri.host.trim().isEmpty) return '';
    return uri.toString();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  _StoriesPalette get palette => _toStoriesPalette(appThemeController.palette);

  _StoriesPalette _toStoriesPalette(AppPalette p) {
    return _StoriesPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  List<String> _extractAllGenres(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    final out = <String>{};
    for (final entry in items) {
      final genre = (entry.value['genre'] ?? '').toString().trim();
      if (genre.isNotEmpty) out.add(genre);
    }
    final list = out.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _extractAllLevels(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    final out = <String>{};
    for (final entry in items) {
      final level = (entry.value['level'] ?? '').toString().trim();
      if (level.isNotEmpty) out.add(level);
    }
    final list = out.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _extractAllLengths(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    final out = <String>{};
    for (final entry in items) {
      final value = (entry.value['lengthApprox'] ?? '').toString().trim();
      if (value.isNotEmpty) out.add(value);
    }
    final list = out.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _tagsFromStory(Map<String, dynamic> story) {
    final out = <String>[];
    final tags = story['tags'];

    if (tags is List) {
      for (final item in tags) {
        final v = item.toString().trim();
        if (v.isNotEmpty) out.add(v);
      }
    } else if (tags is Map) {
      final tagMap = Map<dynamic, dynamic>.from(tags);
      for (final item in tagMap.values) {
        final v = item.toString().trim();
        if (v.isNotEmpty) out.add(v);
      }
    } else if (tags is String) {
      final v = tags.trim();
      if (v.isNotEmpty) out.add(v);
    }

    return out;
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _storyId(Map<String, dynamic> story) {
    return (story['storyId'] ?? story['storyUid'] ?? story['id'] ?? '')
        .toString()
        .trim();
  }

  int _storyStat(Map<String, dynamic> story, String key) {
    final stats = story['stats'];
    if (stats is Map) {
      final m = Map<dynamic, dynamic>.from(stats);
      return _toInt(m[key]);
    }
    return _toInt(story[key]);
  }

  Future<void> _incrementStoryStat(
    Map<String, dynamic> story,
    String key,
  ) async {
    final id = _storyId(story);
    if (id.isEmpty) return;
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      await _storiesRef.child(id).child('stats').child(key).runTransaction((v) {
        final cur = _toInt(v);
        return Transaction.success(cur + 1);
      });
    } catch (e, st) {
      debugPrint('story stat increment failed ($key): $e');
      debugPrint('$st');
    }
  }

  Widget _storyStatChip(_StoriesPalette p, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: p.soft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: p.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.82),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  String _teacherName(Map<String, dynamic> story) {
    final first = (story['teacherFirstName'] ?? '').toString().trim();
    final last = (story['teacherLastName'] ?? '').toString().trim();
    final full = ('$first $last').trim();

    if (full.isNotEmpty) return full;

    final email = (story['teacherEmail'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return 'Teacher';
  }

  String _teacherUid(Map<String, dynamic> story) {
    return (story['teacherUid'] ?? '').toString().trim();
  }

  Future<String> _teacherPhotoUrl(String teacherUid) {
    final uid = teacherUid.trim();
    if (uid.isEmpty) return Future.value('');

    final cached = _teacherPhotoCache[uid];
    if (cached != null) return Future.value(cached);

    final pending = _teacherPhotoPending[uid];
    if (pending != null) return pending;

    final future = () async {
      try {
        final snap = await _db.child('users/$uid').get();
        String photo = '';
        if (snap.value is Map) {
          photo = ProfileAvatar.resolvePhotoFromMap(snap.value as Map);
        }
        _teacherPhotoCache[uid] = photo;
        return photo;
      } catch (_) {
        _teacherPhotoCache[uid] = '';
        return '';
      } finally {
        _teacherPhotoPending.remove(uid);
      }
    }();

    _teacherPhotoPending[uid] = future;
    return future;
  }

  bool _hasListen(Map<String, dynamic> story) =>
      _normalizeMediaUrl((story['audioUrl'] ?? '').toString()).isNotEmpty;

  bool _hasRead(Map<String, dynamic> story) =>
      _normalizeMediaUrl((story['pdfUrl'] ?? '').toString()).isNotEmpty;

  bool _hasHtml(Map<String, dynamic> story) =>
      _normalizeMediaUrl((story['link'] ?? '').toString()).isNotEmpty;

  List<MapEntry<String, Map<String, dynamic>>> _applyFiltersAndSort({
    required List<MapEntry<String, Map<String, dynamic>>> items,
  }) {
    var filtered = items.where((entry) {
      final story = entry.value;
      final status = (story['status'] ?? '').toString().trim().toLowerCase();

      if (status != 'ready') return false;

      final name = (story['name'] ?? '').toString().trim().toLowerCase();
      final description = (story['description'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final genre = (story['genre'] ?? '').toString().trim().toLowerCase();
      final level = (story['level'] ?? '').toString().trim().toLowerCase();
      final lengthApprox = (story['lengthApprox'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final scriptType = (story['scriptType'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final authorSource = (story['authorSource'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final teacher = _teacherName(story).toLowerCase();
      final tags = _tagsFromStory(story).map((e) => e.toLowerCase()).join(' ');

      final matchesSearch =
          _searchQuery.isEmpty ||
          name.contains(_searchQuery) ||
          description.contains(_searchQuery) ||
          genre.contains(_searchQuery) ||
          level.contains(_searchQuery) ||
          lengthApprox.contains(_searchQuery) ||
          scriptType.contains(_searchQuery) ||
          authorSource.contains(_searchQuery) ||
          teacher.contains(_searchQuery) ||
          tags.contains(_searchQuery);

      final matchesGenre =
          _genreFilter == 'all' || genre == _genreFilter.toLowerCase();

      final matchesLevel =
          _levelFilter == 'all' || level == _levelFilter.toLowerCase();

      final matchesLength =
          _lengthFilter == 'all' || lengthApprox == _lengthFilter.toLowerCase();

      return matchesSearch && matchesGenre && matchesLevel && matchesLength;
    }).toList();

    filtered.sort((a, b) {
      switch (_sortBy) {
        case 'name_asc':
          return (a.value['name'] ?? '').toString().toLowerCase().compareTo(
            (b.value['name'] ?? '').toString().toLowerCase(),
          );
        case 'name_desc':
          return (b.value['name'] ?? '').toString().toLowerCase().compareTo(
            (a.value['name'] ?? '').toString().toLowerCase(),
          );
        case 'created_desc':
          return _toInt(
            b.value['createdAt'],
          ).compareTo(_toInt(a.value['createdAt']));
        case 'created_asc':
          return _toInt(
            a.value['createdAt'],
          ).compareTo(_toInt(b.value['createdAt']));
        case 'updated_asc':
          return _toInt(
            a.value['updatedAt'],
          ).compareTo(_toInt(b.value['updatedAt']));
        case 'updated_desc':
        default:
          return _toInt(
            b.value['updatedAt'],
          ).compareTo(_toInt(a.value['updatedAt']));
      }
    });

    return filtered;
  }

  Map<String, List<Map<String, dynamic>>> _groupStoriesByGenre(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};

    for (final entry in items) {
      final story = entry.value;
      final genre = (story['genre'] ?? '').toString().trim();
      final key = genre.isEmpty ? 'Other' : genre;

      grouped.putIfAbsent(key, () => []);
      grouped[key]!.add(story);
    }

    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final result = <String, List<Map<String, dynamic>>>{};
    for (final key in sortedKeys) {
      result[key] = grouped[key]!;
    }
    return result;
  }

  Future<void> _openHtmlRead(Map<String, dynamic> story) async {
    final htmlUrl = _normalizeMediaUrl((story['link'] ?? '').toString());
    final title = (story['name'] ?? 'Story Material').toString().trim();
    if (htmlUrl.isEmpty) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: title.isEmpty ? 'Story Material' : title,
          url: htmlUrl,
        ),
      ),
    );
  }

  Future<void> _openStudy(Map<String, dynamic> story) async {
    final audioUrl = _normalizeMediaUrl((story['audioUrl'] ?? '').toString());
    final pdfUrl = _normalizeMediaUrl((story['pdfUrl'] ?? '').toString());
    final htmlUrl = _normalizeMediaUrl((story['link'] ?? '').toString());
    final title = (story['name'] ?? 'Story Study').toString().trim();
    final imageUrl = _normalizeMediaUrl((story['thumbnail'] ?? '').toString());

    if (pdfUrl.isEmpty && audioUrl.isEmpty && htmlUrl.isNotEmpty) {
      await _openHtmlRead(story);
      return;
    }

    if (pdfUrl.isEmpty && audioUrl.isEmpty) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('No media available for this story.')),
      );
      return;
    }

    if (pdfUrl.isNotEmpty) {
      unawaited(_incrementStoryStat(story, 'views'));
    }
    if (audioUrl.isNotEmpty) {
      unawaited(_incrementStoryStat(story, 'listens'));
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SharedStoryStudyScreen(
          title: title.isEmpty ? 'Story Study' : title,
          thumbnailUrl: imageUrl,
          audioUrl: audioUrl,
          pdfUrl: pdfUrl,
          htmlUrl: htmlUrl,
        ),
      ),
    );
  }

  Color _storyActionColor(Map<String, dynamic> story, _StoriesPalette p) {
    final thumbnail = (story['thumbnail'] ?? '').toString().trim();
    if (thumbnail.isEmpty) return p.accent;
    final hash = thumbnail.hashCode.abs();
    final hue = (hash % 360).toDouble();
    return HSVColor.fromAHSV(1, hue, 0.68, 0.84).toColor();
  }

  void _scheduleThumbPrecache(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    final urls = <String>[];
    for (final entry in items) {
      final url = _normalizeMediaUrl(
        (entry.value['thumbnail'] ?? '').toString(),
      );
      if (url.isNotEmpty) urls.add(url);
    }
    if (urls.isEmpty) return;

    final deduped = <String>[];
    final seen = <String>{};
    for (final url in urls) {
      if (seen.add(url)) deduped.add(url);
    }

    final key = deduped.take(40).join('|');
    if (key == _lastThumbPrecacheKey) return;
    _lastThumbPrecacheKey = key;

    final runId = ++_thumbPrecacheRunId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || runId != _thumbPrecacheRunId) return;
      unawaited(_precacheThumbsInBatches(deduped, runId));
    });
  }

  Future<void> _precacheThumbsInBatches(List<String> urls, int runId) async {
    for (var i = 0; i < urls.length; i += _thumbPrecacheBatchSize) {
      if (!mounted || runId != _thumbPrecacheRunId) return;
      final end = (i + _thumbPrecacheBatchSize < urls.length)
          ? i + _thumbPrecacheBatchSize
          : urls.length;
      final batch = urls.sublist(i, end);

      await Future.wait(
        batch.map((url) async {
          if (_thumbPrecachedUrls.contains(url)) return;
          _thumbPrecachedUrls.add(url);
          try {
            await precacheImage(NetworkImage(url), context);
          } catch (_) {}
        }),
      );
    }
  }

  void _showStoryDetails(Map<String, dynamic> story) {
    _incrementStoryStat(story, 'opens');
    final p = palette;
    final hasRead = _hasRead(story);
    final hasListen = _hasListen(story);
    final actionColor = _storyActionColor(story, p);
    final title = (story['name'] ?? 'Story').toString().trim();
    final description = (story['description'] ?? '').toString().trim();
    final genre = (story['genre'] ?? '').toString().trim();
    final level = (story['level'] ?? '').toString().trim();
    final lengthApprox = (story['lengthApprox'] ?? '').toString().trim();
    final scriptType = (story['scriptType'] ?? '').toString().trim();
    final authorSource = (story['authorSource'] ?? '').toString().trim();
    final thumbnail = _normalizeMediaUrl((story['thumbnail'] ?? '').toString());
    final teacher = _teacherName(story);
    final teacherUid = _teacherUid(story);
    final teacherPhotoFuture = _teacherPhotoUrl(teacherUid);
    final tags = _tagsFromStory(story);
    final opens = _storyStat(story, 'opens');
    final listens = _storyStat(story, 'listens');
    final views = _storyStat(story, 'views');
    final plays = _storyStat(story, 'plays');

    showModalBottomSheet(
      context: context,
      backgroundColor: p.appBg,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final screenWidth = MediaQuery.of(ctx).size.width;
        final bool narrow = screenWidth < 420;

        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              narrow ? 12 : 16,
              8,
              narrow ? 12 : 16,
              20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (thumbnail.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.network(
                      thumbnail,
                      filterQuality: FilterQuality.low,
                      cacheWidth:
                          (screenWidth * MediaQuery.of(ctx).devicePixelRatio)
                              .round()
                              .clamp(320, 1600),
                      cacheHeight:
                          ((narrow ? 180 : 200) *
                                  MediaQuery.of(ctx).devicePixelRatio)
                              .round()
                              .clamp(320, 1200),
                      width: double.infinity,
                      height: narrow ? 180 : 200,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          height: narrow ? 180 : 200,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.soft,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                p.primary.withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        );
                      },
                      errorBuilder: (_, _, _) => Container(
                        height: narrow ? 180 : 200,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: p.soft,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Icon(
                          Icons.menu_book_rounded,
                          size: 44,
                          color: p.primary,
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    height: narrow ? 180 : 200,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [p.primary, p.accent],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.menu_book_rounded,
                        color: Colors.white,
                        size: 52,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  title.isEmpty ? 'Story' : title,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: narrow ? 20 : 22,
                  ),
                ),
                const SizedBox(height: 6),
                FutureBuilder<String>(
                  future: teacherPhotoFuture,
                  initialData: _teacherPhotoCache[teacherUid] ?? '',
                  builder: (context, photoSnap) {
                    final photoUrl = (photoSnap.data ?? '').trim();
                    return Row(
                      children: [
                        ProfileAvatar(
                          name: teacher,
                          photoUrl: photoUrl,
                          radius: 16,
                          fallbackBg: p.soft,
                          fallbackFg: p.primary,
                          borderColor: p.border.withValues(alpha: 0.9),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'By $teacher',
                            style: TextStyle(
                              color: p.text.withValues(alpha: 0.65),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (genre.isNotEmpty)
                      _detailChip(p, Icons.category_rounded, genre),
                    if (level.isNotEmpty)
                      _detailChip(p, Icons.bar_chart_rounded, level),
                    if (lengthApprox.isNotEmpty)
                      _detailChip(p, Icons.schedule_rounded, lengthApprox),
                    if (scriptType.isNotEmpty)
                      _detailChip(p, Icons.article_rounded, scriptType),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _storyStatChip(
                      p,
                      Icons.open_in_new_rounded,
                      'Opens $opens',
                    ),
                    _storyStatChip(
                      p,
                      Icons.headphones_rounded,
                      'Listens $listens',
                    ),
                    _storyStatChip(p, Icons.visibility_rounded, 'Views $views'),
                    _storyStatChip(p, Icons.play_arrow_rounded, 'Plays $plays'),
                  ],
                ),
                if (authorSource.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Author / Source',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    authorSource,
                    style: TextStyle(
                      color: p.text,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                    ),
                  ),
                ],
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Description',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.18,
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        description,
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Tags',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: tags
                        .map(
                          (tag) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: p.accent.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: p.accent.withValues(alpha: 0.20),
                              ),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                color: p.accent,
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: actionColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _openStudy(story);
                    },
                    icon: Icon(
                      hasRead
                          ? Icons.auto_stories_rounded
                          : hasListen
                          ? Icons.headphones_rounded
                          : Icons.language_rounded,
                    ),
                    label: Text(hasRead || hasListen ? 'Enjoy' : 'Read'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _detailChip(_StoriesPalette p, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: p.soft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: p.border.withValues(alpha: 0.90)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: p.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.text,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactFilters({
    required List<String> genres,
    required List<String> levels,
    required List<String> lengths,
  }) {
    final p = palette;

    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
      IconData? icon,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? p.primary : p.cardBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? p.primary : p.border.withValues(alpha: 0.85),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 15,
                  color: selected ? Colors.white : p.primary,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : p.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Future<void> pickValue({
      required String title,
      required List<String> values,
      required String currentValue,
      required ValueChanged<String> onSelected,
      String Function(String value)? labelBuilder,
    }) async {
      await showModalBottomSheet(
        context: context,
        backgroundColor: p.appBg,
        showDragHandle: true,
        builder: (ctx) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 12),
                ...values.map(
                  (value) => ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    title: Text(labelBuilder?.call(value) ?? value),
                    trailing: currentValue == value
                        ? Icon(Icons.check_rounded, color: p.primary)
                        : null,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onSelected(value);
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    String sortLabel(String value) {
      switch (value) {
        case 'updated_desc':
          return 'Recently updated';
        case 'created_desc':
          return 'Newest added';
        case 'name_asc':
          return 'Name A-Z';
        case 'name_desc':
          return 'Name Z-A';
        case 'created_asc':
          return 'Oldest added';
        case 'updated_asc':
          return 'Least recently updated';
        default:
          return value;
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(
          label: _genreFilter == 'all' ? 'Genre' : _genreFilter,
          selected: _genreFilter != 'all',
          icon: Icons.category_rounded,
          onTap: () => pickValue(
            title: 'Genre',
            values: ['all', ...genres],
            currentValue: _genreFilter,
            labelBuilder: (value) => value == 'all' ? 'All' : value,
            onSelected: (value) {
              setState(() {
                _genreFilter = value;
              });
            },
          ),
        ),
        chip(
          label: _levelFilter == 'all' ? 'Level' : _levelFilter,
          selected: _levelFilter != 'all',
          icon: Icons.bar_chart_rounded,
          onTap: () => pickValue(
            title: 'Level',
            values: ['all', ...levels],
            currentValue: _levelFilter,
            labelBuilder: (value) => value == 'all' ? 'All' : value,
            onSelected: (value) {
              setState(() {
                _levelFilter = value;
              });
            },
          ),
        ),
        chip(
          label: _lengthFilter == 'all' ? 'Length' : _lengthFilter,
          selected: _lengthFilter != 'all',
          icon: Icons.schedule_rounded,
          onTap: () => pickValue(
            title: 'Length',
            values: ['all', ...lengths],
            currentValue: _lengthFilter,
            labelBuilder: (value) => value == 'all' ? 'All' : value,
            onSelected: (value) {
              setState(() {
                _lengthFilter = value;
              });
            },
          ),
        ),
        chip(
          label: sortLabel(_sortBy),
          selected: _sortBy != 'updated_desc',
          icon: Icons.swap_vert_rounded,
          onTap: () => pickValue(
            title: 'Sort by',
            values: const [
              'updated_desc',
              'created_desc',
              'name_asc',
              'name_desc',
            ],
            currentValue: _sortBy,
            labelBuilder: sortLabel,
            onSelected: (value) {
              setState(() {
                _sortBy = value;
              });
            },
          ),
        ),
        if (_genreFilter != 'all' ||
            _levelFilter != 'all' ||
            _lengthFilter != 'all' ||
            _searchQuery.isNotEmpty ||
            _sortBy != 'updated_desc')
          chip(
            label: 'Reset',
            selected: false,
            icon: Icons.close_rounded,
            onTap: () {
              _searchController.clear();
              setState(() {
                _searchQuery = '';
                _genreFilter = 'all';
                _levelFilter = 'all';
                _lengthFilter = 'all';
                _sortBy = 'updated_desc';
              });
            },
          ),
      ],
    );
  }

  Widget _buildStoryCard(Map<String, dynamic> story) {
    final p = palette;
    final hasRead = _hasRead(story);
    final hasListen = _hasListen(story);
    final hasHtml = _hasHtml(story);
    final hasAnyAction = hasRead || hasListen || hasHtml;
    final actionColor = _storyActionColor(story, p);
    final title = (story['name'] ?? 'Story').toString().trim();
    final genre = (story['genre'] ?? '').toString().trim();
    final level = (story['level'] ?? '').toString().trim();
    final topTags = _tagsFromStory(story).take(2).toList();
    final denseMeta =
        topTags.length >= 2 && level.isNotEmpty && genre.isNotEmpty;
    final chips = <String>[
      ...topTags,
      if (level.isNotEmpty) level,
      if (genre.isNotEmpty) genre,
    ];
    final visibleChips = chips.take(3).toList();
    final hiddenCount = chips.length - visibleChips.length;
    final thumbnail = _normalizeMediaUrl((story['thumbnail'] ?? '').toString());
    final teacher = _teacherName(story);
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cardCacheWidth = (210 * dpr).round().clamp(320, 900);
    final cardCacheHeight = (120 * dpr).round().clamp(180, 700);

    return SizedBox(
      width: 210,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => _showStoryDetails(story),
          child: Container(
            decoration: BoxDecoration(
              color: actionColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: actionColor.withValues(alpha: 0.50)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(22),
                      ),
                      child: SizedBox(
                        height: 120,
                        width: double.infinity,
                        child: thumbnail.isNotEmpty
                            ? Image.network(
                                thumbnail,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                                cacheWidth: cardCacheWidth,
                                cacheHeight: cardCacheHeight,
                                loadingBuilder: (context, child, progress) {
                                  if (progress == null) return child;
                                  return Container(
                                    color: p.soft,
                                    alignment: Alignment.center,
                                    child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              p.primary.withValues(alpha: 0.7),
                                            ),
                                      ),
                                    ),
                                  );
                                },
                                errorBuilder: (_, _, _) => _fallbackCover(p),
                              )
                            : _fallbackCover(p),
                      ),
                    ),
                    if (hasAnyAction)
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hasRead)
                                const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(
                                    Icons.picture_as_pdf_rounded,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              if (hasListen)
                                const Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(
                                    Icons.headphones_rounded,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              if (!hasRead && !hasListen && hasHtml)
                                const Icon(
                                  Icons.language_rounded,
                                  color: Colors.white,
                                  size: 14,
                                ),
                            ],
                          ),
                        ),
                      ),
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _showStoryDetails(story),
                          child: const SizedBox(
                            width: 30,
                            height: 30,
                            child: Center(
                              child: Text(
                                '!',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  height: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.isEmpty ? 'Story' : title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        teacher,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.62),
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: denseMeta ? 24 : 26,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount:
                              visibleChips.length + (hiddenCount > 0 ? 1 : 0),
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (context, index) {
                            if (hiddenCount > 0 &&
                                index == visibleChips.length) {
                              return _smallTag(
                                p,
                                '+$hiddenCount',
                                compact: denseMeta,
                              );
                            }
                            final chip = visibleChips[index];
                            final isAccent = topTags.contains(chip);
                            return _smallTag(
                              p,
                              chip,
                              isAccent: isAccent,
                              compact: denseMeta,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGenreShelf({
    required String title,
    required List<Map<String, dynamic>> stories,
  }) {
    final p = palette;

    return _AutoScrollingStoryShelf(
      title: title,
      count: stories.length,
      palette: p,
      itemCount: stories.length,
      itemBuilder: (context, index) => _buildStoryCard(stories[index]),
    );
  }

  static Widget _fallbackCover(_StoriesPalette p) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.primary, p.accent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.menu_book_rounded, color: Colors.white, size: 54),
      ),
    );
  }

  static Widget _smallTag(
    _StoriesPalette p,
    String text, {
    bool isAccent = false,
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 9,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: isAccent ? p.accent.withValues(alpha: 0.10) : p.soft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isAccent
              ? p.accent.withValues(alpha: 0.20)
              : p.border.withValues(alpha: 0.90),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isAccent ? p.accent : p.text,
          fontWeight: FontWeight.w800,
          fontSize: compact ? 10 : 11,
        ),
      ),
    );
  }

  EdgeInsets _pagePaddingForWidth(double width) {
    if (width >= 1200) {
      return const EdgeInsets.fromLTRB(24, 20, 24, 28);
    }
    if (width >= 700) {
      return const EdgeInsets.fromLTRB(20, 18, 20, 26);
    }
    return const EdgeInsets.fromLTRB(16, 16, 16, 24);
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        toolbarHeight: 52,
        backgroundColor: p.cardBg.withValues(alpha: 0.96),
        surfaceTintColor: p.cardBg,
        elevation: 0,
        titleSpacing: 12,
        title: _showSearch
            ? Container(
                height: 40,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: p.appBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.border.withValues(alpha: 0.92)),
                ),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value.trim().toLowerCase();
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Search stories...',
                    isDense: true,
                    border: InputBorder.none,
                    hintStyle: TextStyle(
                      color: p.text.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              )
            : Text(
                'Stories',
                style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
              ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                _StoriesTopIconButton(
                  tooltip: _showSearch ? 'Close search' : 'Search',
                  active: _showSearch,
                  activeColor: p.accent,
                  onPressed: () {
                    setState(() {
                      if (_showSearch) {
                        _showSearch = false;
                        _searchController.clear();
                        _searchQuery = '';
                      } else {
                        _showSearch = true;
                      }
                    });
                  },
                  icon: _showSearch
                      ? Icons.close_rounded
                      : Icons.search_rounded,
                  iconColor: p.primary,
                ),
                const SizedBox(width: 6),
                _StoriesTopIconButton(
                  tooltip: 'Filters',
                  active: _showFilters,
                  activeColor: const Color(0xFFF59E0B),
                  onPressed: () {
                    setState(() {
                      _showFilters = !_showFilters;
                    });
                  },
                  icon: _showFilters
                      ? Icons.tune_rounded
                      : Icons.filter_alt_outlined,
                  iconColor: p.primary,
                ),
              ],
            ),
          ),
        ],
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1600,
        child: StreamBuilder<DatabaseEvent>(
          stream: _storiesRef.onValue,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                snap.data == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final rawValue = snap.data?.snapshot.value;
            final warmItems = StoryPreloadService.warmStories();

            if ((rawValue == null || rawValue is! Map) && warmItems.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 520),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: p.cardBg,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: p.border.withValues(alpha: 0.85),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.menu_book_rounded,
                          size: 50,
                          color: p.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No stories available yet.',
                          style: TextStyle(
                            color: p.primary,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            final items = (rawValue is Map)
                ? Map<dynamic, dynamic>.from(rawValue).entries.map((entry) {
                    final storyId = entry.key.toString();
                    final storyValue = entry.value;
                    final story = storyValue is Map
                        ? Map<String, dynamic>.from(storyValue)
                        : <String, dynamic>{};
                    story['storyId'] = storyId;
                    return MapEntry(storyId, story);
                  }).toList()
                : warmItems;

            final allGenres = _extractAllGenres(items);
            final allLevels = _extractAllLevels(items);
            final allLengths = _extractAllLengths(items);
            final visibleItems = _applyFiltersAndSort(items: items);
            _scheduleThumbPrecache(visibleItems);
            final groupedStories = _groupStoriesByGenre(visibleItems);

            return LayoutBuilder(
              builder: (context, constraints) {
                final availableWidth = constraints.maxWidth;
                final pagePadding = _pagePaddingForWidth(availableWidth);

                final storiesList = ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: pagePadding,
                  children: [
                    if (visibleItems.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: p.cardBg,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: p.border.withValues(alpha: 0.85),
                          ),
                        ),
                        child: Text(
                          'No stories match your filters.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      )
                    else
                      ...groupedStories.entries.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: _buildGenreShelf(
                            title: entry.key,
                            stories: entry.value,
                          ),
                        ),
                      ),
                  ],
                );

                return RefreshIndicator(
                  onRefresh: () async {
                    await _storiesRef.get();
                  },
                  child: desktopWorkspace
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 310,
                              child: ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: pagePadding,
                                children: [
                                  _buildCompactFilters(
                                    genres: allGenres,
                                    levels: allLevels,
                                    lengths: allLengths,
                                  ),
                                ],
                              ),
                            ),
                            Expanded(child: storiesList),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: pagePadding,
                          children: [
                            if (_showFilters) ...[
                              const SizedBox(height: 6),
                              _buildCompactFilters(
                                genres: allGenres,
                                levels: allLevels,
                                lengths: allLengths,
                              ),
                            ],
                            const SizedBox(height: 18),
                            if (visibleItems.isEmpty)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(22),
                                decoration: BoxDecoration(
                                  color: p.cardBg,
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: p.border.withValues(alpha: 0.85),
                                  ),
                                ),
                                child: Text(
                                  'No stories match your filters.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: p.text,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              )
                            else
                              ...groupedStories.entries.map(
                                (entry) => Padding(
                                  padding: const EdgeInsets.only(bottom: 20),
                                  child: _buildGenreShelf(
                                    title: entry.key,
                                    stories: entry.value,
                                  ),
                                ),
                              ),
                          ],
                        ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _StoriesTopIconButton extends StatelessWidget {
  const _StoriesTopIconButton({
    required this.tooltip,
    required this.active,
    required this.activeColor,
    required this.onPressed,
    required this.icon,
    required this.iconColor,
  });

  final String tooltip;
  final bool active;
  final Color activeColor;
  final VoidCallback onPressed;
  final IconData icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active
            ? activeColor.withValues(alpha: 0.18)
            : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onPressed,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, color: iconColor, size: 20),
          ),
        ),
      ),
    );
  }
}

class _AutoScrollingStoryShelf extends StatefulWidget {
  const _AutoScrollingStoryShelf({
    required this.title,
    required this.count,
    required this.palette,
    required this.itemCount,
    required this.itemBuilder,
  });

  final String title;
  final int count;
  final _StoriesPalette palette;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_AutoScrollingStoryShelf> createState() =>
      _AutoScrollingStoryShelfState();
}

class _AutoScrollingStoryShelfState extends State<_AutoScrollingStoryShelf> {
  final ScrollController _controller = ScrollController();
  Timer? _autoScrollTimer;
  Timer? _resumeTimer;
  bool _scrollForward = true;
  bool _isPaused = false;

  @override
  void initState() {
    super.initState();
    _startAutoScroll();
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _resumeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 35), (_) {
      if (!mounted ||
          _isPaused ||
          !_controller.hasClients ||
          widget.itemCount < 2) {
        return;
      }

      final position = _controller.position;
      if (position.maxScrollExtent <= 0) return;

      final min = position.minScrollExtent;
      final max = position.maxScrollExtent;
      final nextOffset = position.pixels + (_scrollForward ? 0.9 : -0.9);

      if (nextOffset >= max) {
        _scrollForward = false;
        _controller.jumpTo(max);
        return;
      }

      if (nextOffset <= min) {
        _scrollForward = true;
        _controller.jumpTo(min);
        return;
      }

      _controller.jumpTo(nextOffset);
    });
  }

  void _pauseAutoScroll() {
    _resumeTimer?.cancel();
    _isPaused = true;
  }

  void _resumeAutoScrollSoon() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _isPaused = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, right: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ),
              Text(
                '${widget.count}',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.60),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 236,
          child: Listener(
            onPointerDown: (_) => _pauseAutoScroll(),
            onPointerUp: (_) => _resumeAutoScrollSoon(),
            onPointerCancel: (_) => _resumeAutoScrollSoon(),
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: widget.itemBuilder,
            ),
          ),
        ),
      ],
    );
  }
}

class _StoriesPalette {
  const _StoriesPalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}
