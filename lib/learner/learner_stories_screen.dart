import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_theme.dart';
import '../shared/material_webview_screen.dart';
import '../shared/shared_story_audio_player_screen.dart';
import '../shared/shared_pdf_reader_screen.dart';

class LearnerStoriesScreen extends StatefulWidget {
  const LearnerStoriesScreen({super.key});

  @override
  State<LearnerStoriesScreen> createState() => _LearnerStoriesScreenState();
}

class _LearnerStoriesScreenState extends State<LearnerStoriesScreen> {
  final DatabaseReference _storiesRef = FirebaseDatabase.instance.ref('stories');
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String _genreFilter = 'all';
  String _levelFilter = 'all';
  String _lengthFilter = 'all';
  String _sortBy = 'updated_desc';

  bool _showSearch = false;
  bool _showFilters = false;

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

  List<String> _extractAllGenres(List<MapEntry<String, Map<String, dynamic>>> items) {
    final out = <String>{};
    for (final entry in items) {
      final genre = (entry.value['genre'] ?? '').toString().trim();
      if (genre.isNotEmpty) out.add(genre);
    }
    final list = out.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _extractAllLevels(List<MapEntry<String, Map<String, dynamic>>> items) {
    final out = <String>{};
    for (final entry in items) {
      final level = (entry.value['level'] ?? '').toString().trim();
      if (level.isNotEmpty) out.add(level);
    }
    final list = out.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _extractAllLengths(List<MapEntry<String, Map<String, dynamic>>> items) {
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

  String _teacherName(Map<String, dynamic> story) {
    final first = (story['teacherFirstName'] ?? '').toString().trim();
    final last = (story['teacherLastName'] ?? '').toString().trim();
    final full = ('$first $last').trim();

    if (full.isNotEmpty) return full;

    final email = (story['teacherEmail'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return 'Teacher';
  }

  bool _hasWatch(Map<String, dynamic> story) =>
      (story['link'] ?? '').toString().trim().isNotEmpty;

  bool _hasListen(Map<String, dynamic> story) =>
      (story['audioUrl'] ?? '').toString().trim().isNotEmpty;

  bool _hasRead(Map<String, dynamic> story) =>
      (story['pdfUrl'] ?? '').toString().trim().isNotEmpty;

  List<MapEntry<String, Map<String, dynamic>>> _applyFiltersAndSort({
    required List<MapEntry<String, Map<String, dynamic>>> items,
  }) {
    var filtered = items.where((entry) {
      final story = entry.value;
      final status = (story['status'] ?? '').toString().trim().toLowerCase();

      if (status != 'ready') return false;

      final name = (story['name'] ?? '').toString().trim().toLowerCase();
      final description = (story['description'] ?? '').toString().trim().toLowerCase();
      final genre = (story['genre'] ?? '').toString().trim().toLowerCase();
      final level = (story['level'] ?? '').toString().trim().toLowerCase();
      final lengthApprox = (story['lengthApprox'] ?? '').toString().trim().toLowerCase();
      final scriptType = (story['scriptType'] ?? '').toString().trim().toLowerCase();
      final authorSource = (story['authorSource'] ?? '').toString().trim().toLowerCase();
      final teacher = _teacherName(story).toLowerCase();
      final tags = _tagsFromStory(story).map((e) => e.toLowerCase()).join(' ');

      final matchesSearch = _searchQuery.isEmpty ||
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
          return (a.value['name'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((b.value['name'] ?? '').toString().toLowerCase());
        case 'name_desc':
          return (b.value['name'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((a.value['name'] ?? '').toString().toLowerCase());
        case 'created_desc':
          return _toInt(b.value['createdAt']).compareTo(_toInt(a.value['createdAt']));
        case 'created_asc':
          return _toInt(a.value['createdAt']).compareTo(_toInt(b.value['createdAt']));
        case 'updated_asc':
          return _toInt(a.value['updatedAt']).compareTo(_toInt(b.value['updatedAt']));
        case 'updated_desc':
        default:
          return _toInt(b.value['updatedAt']).compareTo(_toInt(a.value['updatedAt']));
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

  void _openWatch(Map<String, dynamic> story) {
    final url = (story['link'] ?? '').toString().trim();
    final title = (story['name'] ?? 'Story').toString().trim();

    if (url.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: title.isEmpty ? 'Story' : title,
          url: url,
        ),
      ),
    );
  }

  void _openListen(Map<String, dynamic> story) {
    final audioUrl = (story['audioUrl'] ?? '').toString().trim();
    final title = (story['name'] ?? 'Story Audio').toString().trim();
    final imageUrl = (story['thumbnail'] ?? '').toString().trim();

    if (audioUrl.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SharedAudioPlayerScreen(
          title: title.isEmpty ? 'Story Audio' : title,
          audioUrl: audioUrl,
          imageUrl: imageUrl,
        ),
      ),
    );
  }

  void _openRead(Map<String, dynamic> story) {
    final pdfUrl = (story['pdfUrl'] ?? '').toString().trim();
    final title = (story['name'] ?? 'Story PDF').toString().trim();

    if (pdfUrl.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SharedPdfReaderScreen(
          title: title.isEmpty ? 'Story PDF' : title,
          pdfUrl: pdfUrl,
        ),
      ),
    );
  }

  void _showStoryDetails(Map<String, dynamic> story) {
    final p = palette;
    final title = (story['name'] ?? 'Story').toString().trim();
    final description = (story['description'] ?? '').toString().trim();
    final genre = (story['genre'] ?? '').toString().trim();
    final level = (story['level'] ?? '').toString().trim();
    final lengthApprox = (story['lengthApprox'] ?? '').toString().trim();
    final scriptType = (story['scriptType'] ?? '').toString().trim();
    final authorSource = (story['authorSource'] ?? '').toString().trim();
    final thumbnail = (story['thumbnail'] ?? '').toString().trim();
    final teacher = _teacherName(story);
    final tags = _tagsFromStory(story);

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (thumbnail.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.network(
                      thumbnail,
                      width: double.infinity,
                      height: narrow ? 180 : 200,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
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
                        colors: [
                          p.primary,
                          p.accent,
                        ],
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
                Text(
                  'By $teacher',
                  style: TextStyle(
                    color: p.text.withOpacity(0.65),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (genre.isNotEmpty) _detailChip(p, Icons.category_rounded, genre),
                    if (level.isNotEmpty) _detailChip(p, Icons.bar_chart_rounded, level),
                    if (lengthApprox.isNotEmpty)
                      _detailChip(p, Icons.schedule_rounded, lengthApprox),
                    if (scriptType.isNotEmpty)
                      _detailChip(p, Icons.article_rounded, scriptType),
                    if (_hasRead(story)) _detailChip(p, Icons.picture_as_pdf_rounded, 'Read'),
                    if (_hasListen(story)) _detailChip(p, Icons.headphones_rounded, 'Listen'),
                    if (_hasWatch(story)) _detailChip(p, Icons.ondemand_video_rounded, 'Watch'),
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
                  Text(
                    description,
                    style: TextStyle(
                      color: p.text,
                      fontWeight: FontWeight.w700,
                      height: 1.5,
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
                          color: p.accent.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: p.accent.withOpacity(0.20),
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
                if (narrow) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _hasRead(story)
                          ? () {
                        Navigator.of(ctx).pop();
                        _openRead(story);
                      }
                          : null,
                      icon: const Icon(Icons.picture_as_pdf_rounded),
                      label: const Text('Read'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _hasListen(story)
                          ? () {
                        Navigator.of(ctx).pop();
                        _openListen(story);
                      }
                          : null,
                      icon: const Icon(Icons.headphones_rounded),
                      label: const Text('Listen'),
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _hasRead(story)
                              ? () {
                            Navigator.of(ctx).pop();
                            _openRead(story);
                          }
                              : null,
                          icon: const Icon(Icons.picture_as_pdf_rounded),
                          label: const Text('Read'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _hasListen(story)
                              ? () {
                            Navigator.of(ctx).pop();
                            _openListen(story);
                          }
                              : null,
                          icon: const Icon(Icons.headphones_rounded),
                          label: const Text('Listen'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _hasWatch(story)
                        ? () {
                      Navigator.of(ctx).pop();
                      _openWatch(story);
                    }
                        : null,
                    icon: const Icon(Icons.ondemand_video_rounded),
                    label: const Text('Watch'),
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
        border: Border.all(color: p.border.withOpacity(0.90)),
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
              color: selected ? p.primary : p.border.withOpacity(0.85),
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
    final title = (story['name'] ?? 'Story').toString().trim();
    final genre = (story['genre'] ?? '').toString().trim();
    final level = (story['level'] ?? '').toString().trim();
    final thumbnail = (story['thumbnail'] ?? '').toString().trim();
    final teacher = _teacherName(story);

    return SizedBox(
      width: 210,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => _showStoryDetails(story),
          child: Container(
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: p.border.withOpacity(0.90)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
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
                          errorBuilder: (_, __, ___) => _fallbackCover(p),
                        )
                            : _fallbackCover(p),
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_hasRead(story))
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.picture_as_pdf_rounded,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                            if (_hasListen(story))
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.headphones_rounded,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                            if (_hasWatch(story))
                              const Icon(
                                Icons.ondemand_video_rounded,
                                color: Colors.white,
                                size: 14,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Column(
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
                            color: p.text.withOpacity(0.62),
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (genre.isNotEmpty) _smallTag(p, genre),
                            if (level.isNotEmpty) _smallTag(p, level),
                            if (_hasRead(story))
                              _smallTag(p, 'Read', isAccent: true),
                            if (_hasListen(story))
                              _smallTag(p, 'Listen', isAccent: true),
                            if (_hasWatch(story))
                              _smallTag(p, 'Watch', isAccent: true),
                          ],
                        ),
                      ],
                    ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, right: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ),
              Text(
                '${stories.length}',
                style: TextStyle(
                  color: p.text.withOpacity(0.60),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 270,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: stories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              return _buildStoryCard(stories[index]);
            },
          ),
        ),
      ],
    );
  }

  static Widget _fallbackCover(_StoriesPalette p) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            p.primary,
            p.accent,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.menu_book_rounded,
          color: Colors.white,
          size: 54,
        ),
      ),
    );
  }

  static Widget _smallTag(_StoriesPalette p, String text, {bool isAccent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: isAccent ? p.accent.withOpacity(0.10) : p.soft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isAccent ? p.accent.withOpacity(0.20) : p.border.withOpacity(0.90),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isAccent ? p.accent : p.text,
          fontWeight: FontWeight.w800,
          fontSize: 11,
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

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        surfaceTintColor: p.cardBg,
        elevation: 0,
        title: _showSearch
            ? TextField(
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
              color: p.text.withOpacity(0.55),
              fontWeight: FontWeight.w600,
            ),
          ),
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w800,
          ),
        )
            : Text(
          'Stories',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: _showSearch ? 'Close search' : 'Search',
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
            icon: Icon(
              _showSearch ? Icons.close_rounded : Icons.search_rounded,
              color: p.primary,
            ),
          ),
          IconButton(
            tooltip: 'Filters',
            onPressed: () {
              setState(() {
                _showFilters = !_showFilters;
              });
            },
            icon: Icon(
              _showFilters ? Icons.tune_rounded : Icons.filter_alt_outlined,
              color: p.primary,
            ),
          ),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _storiesRef.onValue,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && snap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final rawValue = snap.data?.snapshot.value;

          if (rawValue == null || rawValue is! Map) {
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
                    border: Border.all(color: p.border.withOpacity(0.85)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.menu_book_rounded, size: 50, color: p.primary),
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

          final raw = Map<dynamic, dynamic>.from(rawValue);
          final items = raw.entries.map((entry) {
            final storyId = entry.key.toString();
            final storyValue = entry.value;
            final story = storyValue is Map
                ? Map<String, dynamic>.from(storyValue as Map)
                : <String, dynamic>{};
            return MapEntry(storyId, story);
          }).toList();

          final allGenres = _extractAllGenres(items);
          final allLevels = _extractAllLevels(items);
          final allLengths = _extractAllLengths(items);
          final visibleItems = _applyFiltersAndSort(items: items);
          final groupedStories = _groupStoriesByGenre(visibleItems);

          return LayoutBuilder(
            builder: (context, constraints) {
              final availableWidth = constraints.maxWidth;
              final pagePadding = _pagePaddingForWidth(availableWidth);
              final narrowHeader = availableWidth < 500;

              return RefreshIndicator(
                onRefresh: () async {
                  await _storiesRef.get();
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: pagePadding,
                  children: [
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: narrowHeader ? 14 : 16,
                        vertical: narrowHeader ? 14 : 16,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            p.primary.withOpacity(0.96),
                            p.accent.withOpacity(0.92),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: p.primary.withOpacity(0.16),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.14),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.24),
                              ),
                            ),
                            child: const Icon(
                              Icons.auto_stories_rounded,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Story Library',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 20,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${visibleItems.length} stories ready to explore',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.84),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_showFilters) ...[
                      const SizedBox(height: 14),
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
                          border: Border.all(color: p.border.withOpacity(0.85)),
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