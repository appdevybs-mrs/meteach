import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/material_webview_screen.dart';

class LearnerGamesScreen extends StatefulWidget {
  const LearnerGamesScreen({super.key});

  @override
  State<LearnerGamesScreen> createState() => _LearnerGamesScreenState();
}

class _LearnerGamesScreenState extends State<LearnerGamesScreen> {
  final DatabaseReference _gamesRef = FirebaseDatabase.instance.ref('games');
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String _selectedTag = 'All';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openGame(Map<String, dynamic> game) async {
    final link = (game['link'] ?? '').toString().trim();
    final name = (game['name'] ?? 'Game').toString().trim();

    if (link.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This game has no link.')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: name.isEmpty ? 'Game' : name,
          url: link,
        ),
      ),
    );
  }

  String _teacherName(Map<String, dynamic> game) {
    final first = (game['teacherFirstName'] ?? '').toString().trim();
    final last = (game['teacherLastName'] ?? '').toString().trim();
    final full = ('$first $last').trim();

    if (full.isNotEmpty) return full;

    final email = (game['teacherEmail'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return 'Teacher';
  }

  List<String> _tagsFromGame(Map<String, dynamic> game) {
    final out = <String>[];
    final tags = game['tags'];

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

  List<String> _allTags(List<MapEntry<String, Map<String, dynamic>>> items) {
    final set = <String>{};

    for (final item in items) {
      final tags = _tagsFromGame(item.value);
      for (final tag in tags) {
        final clean = tag.trim();
        if (clean.isNotEmpty) {
          set.add(clean);
        }
      }
    }

    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return ['All', ...list];
  }

  bool _matchesSearch({
    required Map<String, dynamic> game,
    required String query,
  }) {
    if (query.trim().isEmpty) return true;

    final q = query.trim().toLowerCase();
    final name = (game['name'] ?? '').toString().trim().toLowerCase();
    final description =
    (game['description'] ?? '').toString().trim().toLowerCase();
    final category = (game['category'] ?? '').toString().trim().toLowerCase();
    final level = (game['level'] ?? '').toString().trim().toLowerCase();
    final tags = _tagsFromGame(game).map((e) => e.toLowerCase()).toList();

    if (name.contains(q)) return true;
    if (description.contains(q)) return true;
    if (category.contains(q)) return true;
    if (level.contains(q)) return true;
    if (tags.any((tag) => tag.contains(q))) return true;

    return false;
  }

  bool _matchesTag({
    required Map<String, dynamic> game,
    required String selectedTag,
  }) {
    if (selectedTag == 'All') return true;

    final tags = _tagsFromGame(game);
    return tags.any(
          (tag) => tag.trim().toLowerCase() == selectedTag.trim().toLowerCase(),
    );
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Widget _buildTopHeader(BuildContext context, int totalCount, int shownCount) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            cs.primary,
            cs.primary.withOpacity(0.82),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withOpacity(0.20),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.20)),
            ),
            child: const Icon(
              Icons.sports_esports_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Games Library',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$shownCount of $totalCount game${totalCount == 1 ? '' : 's'}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.88),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAndFilter(BuildContext context, List<String> tags) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outline.withOpacity(0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
            decoration: InputDecoration(
              hintText: 'Search by name, tag, category, or level...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searchQuery.trim().isEmpty
                  ? null
                  : IconButton(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _searchQuery = '';
                  });
                },
                icon: const Icon(Icons.close_rounded),
              ),
              filled: true,
              fillColor: cs.surfaceVariant.withOpacity(0.35),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: cs.outline.withOpacity(0.18)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: cs.outline.withOpacity(0.18)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: cs.primary, width: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: tags.map((tag) {
                  final selected = _selectedTag == tag;

                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(tag),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          _selectedTag = tag;
                        });
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, {required bool filtered}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: cs.outline.withOpacity(0.25)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sports_esports_rounded,
                size: 46,
                color: cs.primary,
              ),
              const SizedBox(height: 14),
              Text(
                filtered ? 'No games match your search.' : 'No games available yet.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                filtered ? 'Try another name or tag.' : 'Please check again later.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.textTheme.bodyMedium?.color?.withOpacity(0.68),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniInfoChip({
    required BuildContext context,
    required IconData icon,
    required String text,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.primary.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: theme.textTheme.bodyMedium?.color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameCard(BuildContext context, Map<String, dynamic> game) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final name = (game['name'] ?? '').toString().trim();
    final description = (game['description'] ?? '').toString().trim();
    final rules = (game['rules'] ?? '').toString().trim();
    final tags = _tagsFromGame(game);
    final ownerName = _teacherName(game);
    final thumbnail = (game['thumbnail'] ?? '').toString().trim();
    final category = (game['category'] ?? '').toString().trim();
    final level = (game['level'] ?? '').toString().trim();
    final durationMinutes = _toInt(game['durationMinutes']);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outline.withOpacity(0.22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 52,
                height: 52,
                color: cs.primary.withOpacity(0.10),
                child: thumbnail.isNotEmpty
                    ? Image.network(
                  thumbnail,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.sports_esports_rounded,
                    color: cs.primary,
                    size: 24,
                  ),
                )
                    : Icon(
                  Icons.sports_esports_rounded,
                  color: cs.primary,
                  size: 24,
                ),
              ),
            ),
            title: Text(
              name.isEmpty ? 'Untitled Game' : name,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: cs.primary,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'By: $ownerName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: theme.textTheme.bodyMedium?.color?.withOpacity(0.70),
                    ),
                  ),
                  if (category.isNotEmpty || level.isNotEmpty || tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (category.isNotEmpty)
                          _buildMiniInfoChip(
                            context: context,
                            icon: Icons.category_rounded,
                            text: category,
                          ),
                        if (level.isNotEmpty)
                          _buildMiniInfoChip(
                            context: context,
                            icon: Icons.bar_chart_rounded,
                            text: level,
                          ),
                        ...tags.take(2).map(
                              (tag) => _buildMiniInfoChip(
                            context: context,
                            icon: Icons.sell_rounded,
                            text: tag,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            children: [
              if (thumbnail.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    thumbnail,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 180,
                      alignment: Alignment.center,
                      color: cs.primary.withOpacity(0.06),
                      child: Icon(
                        Icons.image_not_supported_rounded,
                        color: cs.primary,
                        size: 34,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (category.isNotEmpty || level.isNotEmpty || durationMinutes > 0) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (category.isNotEmpty)
                        Chip(
                          label: Text(category),
                          avatar: Icon(
                            Icons.category_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                          backgroundColor: cs.primary.withOpacity(0.08),
                          side: BorderSide(color: cs.primary.withOpacity(0.12)),
                        ),
                      if (level.isNotEmpty)
                        Chip(
                          label: Text(level),
                          avatar: Icon(
                            Icons.bar_chart_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                          backgroundColor: cs.primary.withOpacity(0.08),
                          side: BorderSide(color: cs.primary.withOpacity(0.12)),
                        ),
                      if (durationMinutes > 0)
                        Chip(
                          label: Text('$durationMinutes min'),
                          avatar: Icon(
                            Icons.schedule_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                          backgroundColor: cs.primary.withOpacity(0.08),
                          side: BorderSide(color: cs.primary.withOpacity(0.12)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (description.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Description',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: cs.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    description,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (rules.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Rules',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: cs.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    rules,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (tags.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Tags',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: cs.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: tags
                        .map(
                          (tag) => Chip(
                        label: Text(tag),
                        backgroundColor: cs.primary.withOpacity(0.08),
                        side: BorderSide(
                          color: cs.primary.withOpacity(0.12),
                        ),
                      ),
                    )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _openGame(game),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play Game'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _gamesRef.onValue,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              snap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final value = snap.data?.snapshot.value;

          if (value == null || value is! Map) {
            return _buildEmptyState(context, filtered: false);
          }

          final raw = Map<dynamic, dynamic>.from(value);

          final items = raw.entries.map((entry) {
            final gameId = entry.key.toString();
            final gameValue = entry.value;

            final game = gameValue is Map
                ? Map<String, dynamic>.from(gameValue as Map)
                : <String, dynamic>{};

            return MapEntry(gameId, game);
          }).toList();

          items.sort((a, b) {
            final aUpdated = _toInt(a.value['updatedAt']);
            final bUpdated = _toInt(b.value['updatedAt']);
            return bUpdated.compareTo(aUpdated);
          });

          final tags = _allTags(items);

          if (!tags.contains(_selectedTag)) {
            _selectedTag = 'All';
          }

          final filteredItems = items.where((item) {
            final game = item.value;
            return _matchesSearch(game: game, query: _searchQuery) &&
                _matchesTag(game: game, selectedTag: _selectedTag);
          }).toList();

          return RefreshIndicator(
            onRefresh: () async {
              await _gamesRef.get();
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                _buildTopHeader(context, items.length, filteredItems.length),
                _buildSearchAndFilter(context, tags),
                if (filteredItems.isEmpty)
                  _buildEmptyState(context, filtered: true)
                else
                  ...filteredItems.map(
                        (item) => _buildGameCard(context, item.value),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}