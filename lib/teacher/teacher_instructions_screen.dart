import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/material_webview_screen.dart';
import '../shared/teacher_web_layout.dart';

class TeacherInstructionsScreen extends StatefulWidget {
  const TeacherInstructionsScreen({super.key});

  @override
  State<TeacherInstructionsScreen> createState() =>
      _TeacherInstructionsScreenState();
}

class _TeacherInstructionsScreenState extends State<TeacherInstructionsScreen> {
  final DatabaseReference _instructionsRef =
      FirebaseDatabase.instance.ref('instructions');
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final String _statusFilter = 'all';
  String _sortBy = 'updated_desc';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  bool _matchesSearch(Map<String, dynamic> item) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    final name = (item['name'] ?? '').toString().toLowerCase();
    final desc = (item['description'] ?? '').toString().toLowerCase();
    return name.contains(q) || desc.contains(q);
  }

  bool _matchesStatus(Map<String, dynamic> item) {
    if (_statusFilter == 'all') return true;
    final status = (item['status'] ?? '').toString().trim().toLowerCase();
    return status == _statusFilter;
  }

  Future<void> _openInstruction(Map<String, dynamic> item) async {
    final link = (item['link'] ?? '').toString().trim();
    final name = (item['name'] ?? 'Instruction').toString().trim();
    if (link.isEmpty) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: name.isEmpty ? 'Instruction' : name,
          url: link,
          viewerMode: MaterialViewerMode.document,
        ),
      ),
    );
  }

  void _showDetails(Map<String, dynamic> item) {
    final name = (item['name'] ?? '').toString().trim();
    final description = (item['description'] ?? '').toString().trim();
    final thumbnail = (item['thumbnail'] ?? '').toString().trim();
    final teacherFirst =
        (item['teacherFirstName'] ?? '').toString().trim();
    final teacherLast = (item['teacherLastName'] ?? '').toString().trim();
    final teacher = '$teacherFirst $teacherLast'.trim();
    final createdAt = _toInt(item['createdAt']);
    final updatedAt = _toInt(item['updatedAt']);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (thumbnail.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      thumbnail,
                      height: 160,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        height: 160,
                        color: Colors.blue.shade50,
                        child: Icon(
                          Icons.menu_book_rounded,
                          size: 48,
                          color: Colors.blue.shade200,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  name.isEmpty ? 'Instruction' : name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (teacher.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'By $teacher',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (createdAt > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Created: ${DateTime.fromMillisecondsSinceEpoch(createdAt).toString().substring(0, 10)}'
                    '${updatedAt > 0 ? ' • Updated: ${DateTime.fromMillisecondsSinceEpoch(updatedAt).toString().substring(0, 10)}' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Description',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: const TextStyle(
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _openInstruction(item);
                    },
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Instructions',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1200,
        child: StreamBuilder<DatabaseEvent>(
          stream: _instructionsRef.onValue,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                snap.data == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final value = snap.data?.snapshot.value;
            if (value == null || value is! Map) {
              return _buildEmptyState();
            }

            final raw = Map<dynamic, dynamic>.from(value);
            final items = <MapEntry<String, Map<String, dynamic>>>[];

            for (final entry in raw.entries) {
              final rawValue = entry.value;
              if (rawValue is! Map) continue;
              final item = Map<String, dynamic>.from(rawValue);

              final targetRole =
                  (item['targetRole'] ?? '').toString().trim();
              if (targetRole != 'teacher' && targetRole != 'all') continue;

              final status =
                  (item['status'] ?? '').toString().trim().toLowerCase();
              if (status != 'ready') continue;

              item['instructionId'] = entry.key.toString();
              items.add(MapEntry(entry.key.toString(), item));
            }

            items.sort((a, b) {
              switch (_sortBy) {
                case 'name_asc':
                  return (a.value['name'] ?? '')
                      .toString()
                      .toLowerCase()
                      .compareTo(
                        (b.value['name'] ?? '').toString().toLowerCase(),
                      );
                case 'name_desc':
                  return (b.value['name'] ?? '')
                      .toString()
                      .toLowerCase()
                      .compareTo(
                        (a.value['name'] ?? '').toString().toLowerCase(),
                      );
                case 'created_desc':
                  return _toInt(b.value['createdAt']).compareTo(
                    _toInt(a.value['createdAt']),
                  );
                case 'updated_desc':
                default:
                  return _toInt(b.value['updatedAt']).compareTo(
                    _toInt(a.value['updatedAt']),
                  );
              }
            });

            final filtered = items.where((entry) {
              return _matchesSearch(entry.value) &&
                  _matchesStatus(entry.value);
            }).toList();

            if (filtered.isEmpty) {
              return _buildEmptyState(
                searching:
                    _searchQuery.isNotEmpty || _statusFilter != 'all',
              );
            }

            return Column(
              children: [
                _buildToolbar(),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final item = filtered[index].value;
                      return _buildInstructionCard(item);
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v.trim()),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search instructions...',
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            icon: Icon(
              Icons.sort_rounded,
              color: _sortBy != 'updated_desc' ? Colors.blue : null,
            ),
            onSelected: (v) => setState(() => _sortBy = v),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'updated_desc',
                child: Text('Recently Updated'),
              ),
              const PopupMenuItem(
                value: 'created_desc',
                child: Text('Newest First'),
              ),
              const PopupMenuItem(
                value: 'name_asc',
                child: Text('Name A-Z'),
              ),
              const PopupMenuItem(
                value: 'name_desc',
                child: Text('Name Z-A'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionCard(Map<String, dynamic> item) {
    final name = (item['name'] ?? 'Untitled').toString().trim();
    final description = (item['description'] ?? '').toString().trim();
    final thumbnail = (item['thumbnail'] ?? '').toString().trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openInstruction(item),
        onLongPress: () => _showDetails(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: thumbnail.isNotEmpty
                      ? Image.network(
                          thumbnail,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _fallbackIcon(),
                        )
                      : _fallbackIcon(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallbackIcon() {
    return Container(
      color: Colors.blue.shade50,
      child: Icon(Icons.menu_book_rounded, color: Colors.blue.shade200),
    );
  }

  Widget _buildEmptyState({bool searching = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_rounded, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              searching
                  ? 'No instructions match your search.'
                  : 'No instructions available yet.',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Please check again later.',
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
