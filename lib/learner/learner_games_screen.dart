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

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
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
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No games available yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            );
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

          return RefreshIndicator(
            onRefresh: () async {
              await _gamesRef.get();
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final game = items[index].value;
                final name = (game['name'] ?? '').toString().trim();
                final description = (game['description'] ?? '').toString().trim();
                final rules = (game['rules'] ?? '').toString().trim();
                final tags = _tagsFromGame(game);
                final ownerName = _teacherName(game);

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    leading: const Icon(Icons.sports_esports_rounded),
                    title: Text(
                      name.isEmpty ? 'Untitled Game' : name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(
                          'By: $ownerName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (description.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ] else if (tags.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            tags.join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                    children: [
                      if (description.isNotEmpty) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Description',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            description,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (rules.isNotEmpty) ...[
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Rules',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            rules,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (tags.isNotEmpty) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: tags
                                .map((tag) => Chip(label: Text(tag)))
                                .toList(),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _openGame(game),
                          icon: const Icon(Icons.open_in_browser_rounded),
                          label: const Text('Play Game'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}