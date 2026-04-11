import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/material_webview_screen.dart';
import '../shared/app_feedback.dart';
import '../shared/learner_web_layout.dart';

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

  static const Color _funOrange = Color(0xFFF98D28);
  static const Color _funOrangeDark = Color(0xFFE67612);

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
      AppToast.fromSnackBar(
        context,
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

  void _showGameDetails(BuildContext context, Map<String, dynamic> game) {
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (thumbnail.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.network(
                        thumbnail,
                        height: 200,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          height: 200,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Icon(
                            Icons.sports_esports_rounded,
                            size: 42,
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    name.isEmpty ? 'Untitled Game' : name,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'By: $ownerName',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.72,
                      ),
                    ),
                  ),
                  if (category.isNotEmpty ||
                      level.isNotEmpty ||
                      durationMinutes > 0) ...[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (category.isNotEmpty)
                          _buildDetailChip(
                            context: context,
                            icon: Icons.category_rounded,
                            label: category,
                          ),
                        if (level.isNotEmpty)
                          _buildDetailChip(
                            context: context,
                            icon: Icons.bar_chart_rounded,
                            label: level,
                          ),
                        if (durationMinutes > 0)
                          _buildDetailChip(
                            context: context,
                            icon: Icons.schedule_rounded,
                            label: '$durationMinutes min',
                          ),
                      ],
                    ),
                  ],
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Description',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: cs.primary,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      description,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                    ),
                  ],
                  if (rules.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Rules',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: cs.primary,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      rules,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                    ),
                  ],
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Tags',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: cs.primary,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: tags
                          .map(
                            (tag) => Chip(
                              label: Text(tag),
                              backgroundColor: cs.primary.withValues(
                                alpha: 0.08,
                              ),
                              side: BorderSide(
                                color: cs.primary.withValues(alpha: 0.14),
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
                      onPressed: () {
                        Navigator.of(context).pop();
                        _openGame(game);
                      },
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play Game'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _funOrange,
                        foregroundColor: Colors.white,
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
      },
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

  String _categoryFromGame(Map<String, dynamic> game) {
    final category = (game['category'] ?? '').toString().trim();
    if (category.isEmpty) return 'Other';
    return category;
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
    final description = (game['description'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
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

  Map<String, List<Map<String, dynamic>>> _groupByCategory(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};

    for (final item in items) {
      final game = item.value;
      final category = _categoryFromGame(game);
      grouped.putIfAbsent(category, () => <Map<String, dynamic>>[]);
      grouped[category]!.add(game);
    }

    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) {
        if (a.toLowerCase() == 'other') return 1;
        if (b.toLowerCase() == 'other') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final sorted = <String, List<Map<String, dynamic>>>{};
    for (final key in sortedKeys) {
      sorted[key] = grouped[key]!;
    }
    return sorted;
  }

  Widget _buildSearchAndFilter(BuildContext context, List<String> tags) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outline.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 4),
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
              isDense: true,
              hintText: 'Search games...',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _searchQuery.trim().isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.28),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outline.withValues(alpha: 0.15),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: cs.outline.withValues(alpha: 0.15),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: _funOrange, width: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: tags.map((tag) {
                  final selected = _selectedTag == tag;

                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(tag),
                      selected: selected,
                      selectedColor: _funOrange.withValues(alpha: 0.18),
                      side: BorderSide(
                        color: selected
                            ? _funOrange.withValues(alpha: 0.40)
                            : cs.outline.withValues(alpha: 0.18),
                      ),
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected ? _funOrangeDark : null,
                      ),
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
            border: Border.all(color: cs.outline.withValues(alpha: 0.25)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sports_esports_rounded, size: 46, color: _funOrange),
              const SizedBox(height: 14),
              Text(
                filtered
                    ? 'No games match your search.'
                    : 'No games available yet.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                filtered
                    ? 'Try another name or tag.'
                    : 'Please check again later.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.textTheme.bodyMedium?.color?.withValues(
                    alpha: 0.68,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailChip({
    required BuildContext context,
    required IconData icon,
    required String label,
  }) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.primary.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: cs.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConsoleGameCard(
    BuildContext context,
    Map<String, dynamic> game,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final name = (game['name'] ?? '').toString().trim();
    final thumbnail = (game['thumbnail'] ?? '').toString().trim();

    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outline.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: InkWell(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              onTap: () => _openGame(game),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
                child: Container(
                  color: cs.primary.withValues(alpha: 0.08),
                  child: thumbnail.isNotEmpty
                      ? Image.network(
                          thumbnail,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Center(
                            child: Icon(
                              Icons.sports_esports_rounded,
                              color: cs.primary,
                              size: 34,
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            Icons.sports_esports_rounded,
                            color: cs.primary,
                            size: 34,
                          ),
                        ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Untitled Game' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _openGame(game),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: const Text('Play'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _funOrange,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 42,
                      width: 42,
                      child: FilledButton(
                        onPressed: () => _showGameDetails(context, game),
                        style: FilledButton.styleFrom(
                          backgroundColor: _funOrange.withValues(alpha: 0.15),
                          foregroundColor: _funOrangeDark,
                          elevation: 0,
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          '!',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryRow({
    required BuildContext context,
    required String title,
    required List<Map<String, dynamic>> games,
  }) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: cs.primary,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _funOrange.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${games.length}',
                    style: const TextStyle(
                      color: _funOrangeDark,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 280,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: games.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                return _buildConsoleGameCard(context, games[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1540,
        child: StreamBuilder<DatabaseEvent>(
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
              final gameValue = entry.value;

              final game = gameValue is Map
                  ? Map<String, dynamic>.from(gameValue)
                  : <String, dynamic>{};

              return MapEntry(entry.key.toString(), game);
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

            final grouped = _groupByCategory(filteredItems);

            return RefreshIndicator(
              onRefresh: () async {
                await _gamesRef.get();
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                children: [
                  _buildSearchAndFilter(context, tags),
                  if (filteredItems.isEmpty)
                    _buildEmptyState(context, filtered: true)
                  else
                    ...grouped.entries.map(
                      (entry) => _buildCategoryRow(
                        context: context,
                        title: entry.key,
                        games: entry.value,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
