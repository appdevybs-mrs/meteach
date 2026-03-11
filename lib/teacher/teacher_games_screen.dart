import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/material_webview_screen.dart';

class TeacherGamesScreen extends StatefulWidget {
  const TeacherGamesScreen({super.key});

  @override
  State<TeacherGamesScreen> createState() => _TeacherGamesScreenState();
}

class _TeacherGamesScreenState extends State<TeacherGamesScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final String? _myUid = FirebaseAuth.instance.currentUser?.uid;

  bool _saving = false;

  DatabaseReference get _gamesRef => _db.child('games');

  Future<Map<String, dynamic>?> _loadMyTeacherData() async {
    final uid = _myUid;
    if (uid == null || uid.isEmpty) return null;

    try {
      final snap = await _db.child('users/$uid').get();
      if (!snap.exists || snap.value is! Map) return null;

      return Map<String, dynamic>.from(snap.value as Map);
    } catch (_) {
      return null;
    }
  }

  List<String> _extractAllKnownTags(dynamic gamesValue) {
    final out = <String>{};

    if (gamesValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(gamesValue);

    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final game = Map<String, dynamic>.from(value as Map);
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
    }

    final list = out.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  bool _canEditGame(Map<String, dynamic> game) {
    final ownerUid = (game['teacherUid'] ?? '').toString().trim();
    return _myUid != null && _myUid == ownerUid;
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

  Future<void> _deleteGame(String gameId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete game'),
          content: const Text('Are you sure you want to delete this game?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;

    try {
      await _gamesRef.child(gameId).remove();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Game deleted successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete game: $e')),
      );
    }
  }

  Future<void> _showGameForm({
    String? gameId,
    Map<String, dynamic>? existingGame,
    List<String> knownTags = const <String>[],
  }) async {
    final isEdit = gameId != null && existingGame != null;

    final nameController = TextEditingController(
      text: (existingGame?['name'] ?? '').toString(),
    );
    final descriptionController = TextEditingController(
      text: (existingGame?['description'] ?? '').toString(),
    );
    final rulesController = TextEditingController(
      text: (existingGame?['rules'] ?? '').toString(),
    );
    final linkController = TextEditingController(
      text: (existingGame?['link'] ?? '').toString(),
    );
    final tagInputController = TextEditingController();

    final selectedTags = <String>{
      ...knownTags.where((e) => e.trim().isNotEmpty).map((e) => e.trim()),
    };

    final existingTagsValue = existingGame?['tags'];
    if (existingTagsValue is List) {
      for (final item in existingTagsValue) {
        final v = item.toString().trim();
        if (v.isNotEmpty) selectedTags.add(v);
      }
    } else if (existingTagsValue is Map) {
      final tagMap = Map<dynamic, dynamic>.from(existingTagsValue);
      for (final item in tagMap.values) {
        final v = item.toString().trim();
        if (v.isNotEmpty) selectedTags.add(v);
      }
    } else if (existingTagsValue is String) {
      final v = existingTagsValue.trim();
      if (v.isNotEmpty) selectedTags.add(v);
    }

    final chosenTags = <String>{
      if (isEdit)
        ...selectedTags.where((e) => e.trim().isNotEmpty).map((e) => e.trim()),
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        bool localSaving = false;

        return StatefulBuilder(
          builder: (context, setLocalState) {
            void addTag(String raw) {
              final tag = raw.trim();
              if (tag.isEmpty) return;

              setLocalState(() {
                selectedTags.add(tag);
                chosenTags.add(tag);
                tagInputController.clear();
              });
            }

            Future<void> saveGame() async {
              final name = nameController.text.trim();
              final description = descriptionController.text.trim();
              final rules = rulesController.text.trim();
              final link = linkController.text.trim();

              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter the game name.')),
                );
                return;
              }

              if (description.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter the game description.'),
                  ),
                );
                return;
              }

              if (link.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter the game link.')),
                );
                return;
              }

              final uri = Uri.tryParse(link);
              if (uri == null ||
                  (!uri.hasScheme ||
                      (uri.scheme.toLowerCase() != 'http' &&
                          uri.scheme.toLowerCase() != 'https'))) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a valid http/https link.'),
                  ),
                );
                return;
              }

              final teacher = await _loadMyTeacherData();
              if (teacher == null) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not load teacher details.'),
                  ),
                );
                return;
              }

              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No logged-in teacher found.')),
                );
                return;
              }

              final firstName = (teacher['first_name'] ?? '').toString().trim();
              final lastName = (teacher['last_name'] ?? '').toString().trim();
              final email = (teacher['email'] ?? '').toString().trim();
              final serial = (teacher['serial'] ?? '').toString().trim();
              final now = ServerValue.timestamp;

              final tagsToSave = chosenTags
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList()
                ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

              setLocalState(() => localSaving = true);
              if (mounted) {
                setState(() => _saving = true);
              }

              try {
                final ref = isEdit
                    ? _gamesRef.child(gameId!)
                    : _gamesRef.push();

                final data = <String, dynamic>{
                  'gameUid': ref.key ?? gameId ?? '',
                  'teacherUid': uid,
                  'teacherFirstName': firstName,
                  'teacherLastName': lastName,
                  'teacherEmail': email,
                  'teacherSerial': serial,
                  'name': name,
                  'description': description,
                  'rules': rules,
                  'link': link,
                  'tags': tagsToSave,
                  'updatedAt': now,
                };

                if (!isEdit) {
                  data['createdAt'] = now;
                } else {
                  data['createdAt'] =
                      existingGame?['createdAt'] ?? ServerValue.timestamp;
                }

                await ref.update(data);

                if (!mounted) return;
                Navigator.of(ctx).pop();

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      isEdit
                          ? 'Game updated successfully.'
                          : 'Game added successfully.',
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to save game: $e')),
                );
              } finally {
                if (mounted) {
                  setState(() => _saving = false);
                }
              }
            }

            final sortedTags = selectedTags.toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isEdit ? 'Edit Game' : 'Add Game',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: nameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: descriptionController,
                        minLines: 3,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: rulesController,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Rules (if any)',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: linkController,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Link to the game',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Tags',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: tagInputController,
                              onSubmitted: addTag,
                              decoration: const InputDecoration(
                                labelText: 'Add tag',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: localSaving
                                ? null
                                : () => addTag(tagInputController.text),
                            child: const Text('Add'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (sortedTags.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: sortedTags.map((tag) {
                            final selected = chosenTags.contains(tag);

                            return FilterChip(
                              label: Text(tag),
                              selected: selected,
                              onSelected: localSaving
                                  ? null
                                  : (value) {
                                setLocalState(() {
                                  if (value) {
                                    chosenTags.add(tag);
                                  } else {
                                    chosenTags.remove(tag);
                                  }
                                });
                              },
                              onDeleted: localSaving
                                  ? null
                                  : () {
                                setLocalState(() {
                                  selectedTags.remove(tag);
                                  chosenTags.remove(tag);
                                });
                              },
                            );
                          }).toList(),
                        )
                      else
                        const Text(
                          'No tags yet. Add the first one.',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: localSaving
                                  ? null
                                  : () => Navigator.of(ctx).pop(),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: localSaving ? null : saveGame,
                              child: Text(localSaving ? 'Saving...' : 'Save'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
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

  Widget _buildGameCard({
    required String gameId,
    required Map<String, dynamic> game,
    required List<String> knownTags,
  }) {
    final canEdit = _canEditGame(game);
    final tags = _tagsFromGame(game);
    final name = (game['name'] ?? '').toString().trim();
    final description = (game['description'] ?? '').toString().trim();
    final rules = (game['rules'] ?? '').toString().trim();
    final link = (game['link'] ?? '').toString().trim();
    final ownerName = _teacherName(game);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name.isEmpty ? 'Untitled Game' : name,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'By: $ownerName',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                description,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ],
            if (rules.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Rules',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                rules,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ],
            if (link.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                link,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.blue.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: tags
                    .map(
                      (tag) => Chip(
                    label: Text(tag),
                  ),
                )
                    .toList(),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _openGame(game),
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Open'),
                ),
                if (canEdit)
                  OutlinedButton.icon(
                    onPressed: () => _showGameForm(
                      gameId: gameId,
                      existingGame: game,
                      knownTags: knownTags,
                    ),
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text('Edit'),
                  ),
                if (canEdit)
                  OutlinedButton.icon(
                    onPressed: () => _deleteGame(gameId),
                    icon: const Icon(Icons.delete_rounded),
                    label: const Text('Delete'),
                  ),
              ],
            ),
          ],
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving
            ? null
            : () => _showGameForm(
          knownTags: const <String>[],
        ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Game'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _gamesRef.onValue,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              snap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final value = snap.data?.snapshot.value;
          final knownTags = _extractAllKnownTags(value);

          if (value == null || value is! Map) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.sports_esports_rounded,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No games added yet.',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Tap "Add Game" to create the first game.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _showGameForm(knownTags: knownTags),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Game'),
                    ),
                  ],
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
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return _buildGameCard(
                  gameId: item.key,
                  game: item.value,
                  knownTags: knownTags,
                );
              },
            ),
          );
        },
      ),
    );
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}