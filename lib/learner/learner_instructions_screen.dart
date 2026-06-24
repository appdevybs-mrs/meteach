import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/material_webview_screen.dart';
import '../shared/learner_web_layout.dart';

class LearnerInstructionsScreen extends StatefulWidget {
  final bool showAppBar;
  const LearnerInstructionsScreen({super.key, this.showAppBar = true});

  @override
  State<LearnerInstructionsScreen> createState() =>
      _LearnerInstructionsScreenState();
}

class _LearnerInstructionsScreenState extends State<LearnerInstructionsScreen> {
  final DatabaseReference _instructionsRef =
      FirebaseDatabase.instance.ref('instructions');
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'updated_desc';

  static const Color _accentBlue = Color(0xFF3B82F6);

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

  bool _matchesSearch(Map<String, dynamic> item) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    final name = (item['name'] ?? '').toString().toLowerCase();
    final desc = (item['description'] ?? '').toString().toLowerCase();
    return name.contains(q) || desc.contains(q);
  }

  Future<void> _openInstruction(Map<String, dynamic> item) async {
    final link = _normalizeMediaUrl((item['link'] ?? '').toString());
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
    final thumbnail = _normalizeMediaUrl(
      (item['thumbnail'] ?? '').toString(),
    );
    final teacherFirst = (item['teacherFirstName'] ?? '').toString().trim();
    final teacherLast = (item['teacherLastName'] ?? '').toString().trim();
    final teacher = '$teacherFirst $teacherLast'.trim();

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
                    borderRadius: BorderRadius.circular(18),
                    child: Image.network(
                      thumbnail,
                      height: 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          height: 180,
                          color: Colors.grey.shade100,
                          alignment: Alignment.center,
                          child: const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                      errorBuilder: (_, _, _) => Container(
                        height: 180,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [_accentBlue, _accentBlue.withValues(alpha: 0.7)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.menu_book_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  name.isEmpty ? 'Instruction' : name,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _accentBlue,
                  ),
                ),
                if (teacher.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'By $teacher',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.72),
                    ),
                  ),
                ],
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Description',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: _accentBlue,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    maxLines: 8,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      height: 1.5,
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
                    style: FilledButton.styleFrom(
                      backgroundColor: _accentBlue,
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = learnerWebBodyFrame(
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

            final targetRole = (item['targetRole'] ?? '').toString().trim();
            if (targetRole != 'learner' && targetRole != 'all') continue;

            final status = (item['status'] ?? '').toString().trim().toLowerCase();
            if (status != 'ready') continue;

            item['instructionId'] = entry.key.toString();
            items.add(MapEntry(entry.key.toString(), item));
          }

          items.sort((a, b) {
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
            return _matchesSearch(entry.value);
          }).toList();

          if (filtered.isEmpty) {
            return _buildEmptyState(searching: _searchQuery.isNotEmpty);
          }

          return RefreshIndicator(
            onRefresh: () async => await _instructionsRef.get(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              children: [
                _buildSearchBar(),
                const SizedBox(height: 8),
                ...filtered.map((entry) => _buildInstructionCard(entry.value)),
              ],
            ),
          );
        },
      ),
    );

    if (!widget.showAppBar) return body;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Instructions',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: body,
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.16)),
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
          SizedBox(
            height: 42,
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search instructions...',
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                suffixIcon: _searchQuery.trim().isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                filled: true,
                fillColor: const Color(0xFFF0F7FF),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _sortChip('Recently Updated', 'updated_desc'),
                  _sortChip('Newest', 'created_desc'),
                  _sortChip('A-Z', 'name_asc'),
                  _sortChip('Z-A', 'name_desc'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sortChip(String label, String value) {
    final selected = _sortBy == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        selectedColor: _accentBlue.withValues(alpha: 0.18),
        side: BorderSide(
          color: selected
              ? _accentBlue.withValues(alpha: 0.40)
              : Colors.grey.withValues(alpha: 0.18),
        ),
        labelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          color: selected ? _accentBlue : null,
        ),
        onSelected: (_) => setState(() => _sortBy = value),
      ),
    );
  }

  Widget _buildInstructionCard(Map<String, dynamic> item) {
    final name = (item['name'] ?? 'Untitled').toString().trim();
    final description = (item['description'] ?? '').toString().trim();
    final thumbnail = _normalizeMediaUrl(
      (item['thumbnail'] ?? '').toString(),
    );
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cardCacheWidth = (220 * dpr).round().clamp(320, 900);
    final cardCacheHeight = (160 * dpr).round().clamp(240, 700);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _accentBlue.withValues(alpha: 0.18)),
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
          InkWell(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(22),
            ),
            onTap: () => _openInstruction(item),
            onLongPress: () => _showDetails(item),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              child: Container(
                height: 160,
                color: _accentBlue.withValues(alpha: 0.08),
                child: thumbnail.isNotEmpty
                    ? Image.network(
                        thumbnail,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                        cacheWidth: cardCacheWidth,
                        cacheHeight: cardCacheHeight,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _accentBlue.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          );
                        },
                        errorBuilder: (_, _, _) => Center(
                          child: Icon(
                            Icons.menu_book_rounded,
                            color: _accentBlue,
                            size: 34,
                          ),
                        ),
                      )
                    : Center(
                        child: Icon(
                          Icons.menu_book_rounded,
                          color: _accentBlue,
                          size: 34,
                        ),
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Untitled' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: _accentBlue,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.color
                          ?.withValues(alpha: 0.72),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _openInstruction(item),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Open'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accentBlue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({bool searching = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_rounded, size: 46, color: _accentBlue),
              const SizedBox(height: 14),
              Text(
                searching
                    ? 'No instructions match your search.'
                    : 'No instructions available yet.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                searching
                    ? 'Try another search term.'
                    : 'Please check again later.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withValues(alpha: 0.68),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
