import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import 'admin_vocab_word_input_screen.dart';

class AdminVocabWordsListsScreen extends StatefulWidget {
  const AdminVocabWordsListsScreen({super.key});

  @override
  State<AdminVocabWordsListsScreen> createState() =>
      _AdminVocabWordsListsScreenState();
}

class _AdminVocabWordsListsScreenState
    extends State<AdminVocabWordsListsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  bool _busy = false;
  String _search = '';

  final List<_CourseListRow> _rows = <_CourseListRow>[];

  DatabaseReference get _coursesRef => _db.child('courses');
  DatabaseReference get _listsRef => _db.child('vocab_lists');
  DatabaseReference _wordsRef(String courseId) =>
      _db.child('vocab_words/$courseId');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final snaps = await Future.wait([_coursesRef.get(), _listsRef.get()]);
      final coursesSnap = snaps[0];
      final listsSnap = snaps[1];

      final byCourse = <String, _CourseListRow>{};

      if (coursesSnap.exists && coursesSnap.value is Map) {
        final map = Map<dynamic, dynamic>.from(coursesSnap.value as Map);
        for (final entry in map.entries) {
          if (entry.value is! Map) continue;
          final data = Map<dynamic, dynamic>.from(entry.value as Map);
          final id = entry.key.toString();
          final title = (data['title'] ?? data['course_title'] ?? '')
              .toString()
              .trim();
          final code = (data['course_code'] ?? '').toString().trim();
          final level = (data['level'] ?? '').toString().trim();
          byCourse[id] = _CourseListRow(
            courseId: id,
            courseTitle: title.isEmpty ? id : title,
            courseCode: code,
            level: level,
            hasList: false,
            wordCount: 0,
            updatedAt: 0,
          );
        }
      }

      if (listsSnap.exists && listsSnap.value is Map) {
        final map = Map<dynamic, dynamic>.from(listsSnap.value as Map);
        for (final entry in map.entries) {
          final courseId = entry.key.toString();
          if (entry.value is! Map) continue;
          final value = Map<dynamic, dynamic>.from(entry.value as Map);
          final wordCount = _asInt(value['wordCount']);
          final updatedAt = _asInt(value['updatedAt']);
          final listedTitle = (value['courseTitle'] ?? '').toString().trim();

          final base = byCourse[courseId];
          if (base == null) {
            byCourse[courseId] = _CourseListRow(
              courseId: courseId,
              courseTitle: listedTitle.isEmpty ? courseId : listedTitle,
              courseCode: '',
              level: '',
              hasList: true,
              wordCount: wordCount,
              updatedAt: updatedAt,
            );
          } else {
            byCourse[courseId] = base.copyWith(
              hasList: true,
              wordCount: wordCount,
              updatedAt: updatedAt,
            );
          }
        }
      }

      final next = byCourse.values.toList()
        ..sort((a, b) {
          final ac = a.courseCode.toLowerCase();
          final bc = b.courseCode.toLowerCase();
          if (ac.isNotEmpty && bc.isNotEmpty) return ac.compareTo(bc);
          return a.courseTitle.toLowerCase().compareTo(
            b.courseTitle.toLowerCase(),
          );
        });

      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(next);
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not load course lists: ${toHumanError(e)}',
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  List<_CourseListRow> get _filtered {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return List<_CourseListRow>.from(_rows);
    return _rows.where((row) {
      final blob = [
        row.courseTitle,
        row.courseCode,
        row.level,
        row.courseId,
      ].join(' ').toLowerCase();
      return blob.contains(q);
    }).toList();
  }

  Future<void> _ensureList(_CourseListRow row) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    await _listsRef.child(row.courseId).update({
      'courseId': row.courseId,
      'courseTitle': row.courseTitle,
      'wordCount': row.wordCount,
      'active': true,
      'updatedAt': ServerValue.timestamp,
      if (uid.isNotEmpty) 'updatedBy': uid,
      if (!row.hasList) 'createdAt': ServerValue.timestamp,
      if (!row.hasList && uid.isNotEmpty) 'createdBy': uid,
    });
  }

  Future<void> _openWords(_CourseListRow row) async {
    await _ensureList(row);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminVocabWordInputScreen(
          courseId: row.courseId,
          courseTitle: row.courseTitle,
        ),
      ),
    );
    await _load();
  }

  Future<bool> _confirmDelete(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
      ),
    );
    return result == true;
  }

  Future<void> _deleteList(_CourseListRow row) async {
    final ok = await _confirmDelete(
      'Delete list?',
      'Delete the vocabulary list for "${row.courseTitle}" and all its words?',
    );
    if (!ok) return;

    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _listsRef.child(row.courseId).remove();
      await _wordsRef(row.courseId).remove();
      await _load();
      if (!mounted) return;
      AppToast.show(context, 'List deleted.', type: AppToastType.success);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not delete list: ${toHumanError(e)}',
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleRowMenu(_CourseListRow row, String action) async {
    switch (action) {
      case 'open':
        await _openWords(row);
        return;
      case 'delete':
        await _deleteList(row);
        return;
      default:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final filtered = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vocabulary Lists'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: const InputDecoration(
                    hintText: 'Search by course title, code, level, or id...',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Courses: ${_rows.length} • Filtered: ${filtered.length}',
                    style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.72,
                      ),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No matching courses found.',
                          style: TextStyle(
                            color: theme.textTheme.bodyMedium?.color
                                ?.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final row = filtered[index];
                          return Card(
                            elevation: 0,
                            margin: const EdgeInsets.only(bottom: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: cs.outline.withValues(alpha: 0.5),
                              ),
                            ),
                            child: ListTile(
                              onTap: _busy ? null : () => _openWords(row),
                              leading: CircleAvatar(
                                backgroundColor: row.hasList
                                    ? cs.primary.withValues(alpha: 0.14)
                                    : cs.secondary.withValues(alpha: 0.14),
                                foregroundColor: row.hasList
                                    ? cs.primary
                                    : cs.secondary,
                                child: Icon(
                                  row.hasList
                                      ? Icons.menu_book_rounded
                                      : Icons.playlist_add_rounded,
                                ),
                              ),
                              title: Text(
                                row.courseTitle,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: cs.primary,
                                ),
                              ),
                              subtitle: Text(
                                [
                                  if (row.courseCode.isNotEmpty) row.courseCode,
                                  if (row.level.isNotEmpty) row.level,
                                  'Words: ${row.wordCount}',
                                  'Updated: ${_fmtDate(row.updatedAt)}',
                                ].join(' • '),
                              ),
                              trailing: PopupMenuButton<String>(
                                tooltip: 'Actions',
                                onSelected: (value) =>
                                    _handleRowMenu(row, value),
                                itemBuilder: (_) => const [
                                  PopupMenuItem<String>(
                                    value: 'open',
                                    child: Text('Open words'),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text('Delete list'),
                                  ),
                                ],
                                icon: const Icon(Icons.more_vert_rounded),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CourseListRow {
  const _CourseListRow({
    required this.courseId,
    required this.courseTitle,
    required this.courseCode,
    required this.level,
    required this.hasList,
    required this.wordCount,
    required this.updatedAt,
  });

  final String courseId;
  final String courseTitle;
  final String courseCode;
  final String level;
  final bool hasList;
  final int wordCount;
  final int updatedAt;

  _CourseListRow copyWith({
    String? courseId,
    String? courseTitle,
    String? courseCode,
    String? level,
    bool? hasList,
    int? wordCount,
    int? updatedAt,
  }) {
    return _CourseListRow(
      courseId: courseId ?? this.courseId,
      courseTitle: courseTitle ?? this.courseTitle,
      courseCode: courseCode ?? this.courseCode,
      level: level ?? this.level,
      hasList: hasList ?? this.hasList,
      wordCount: wordCount ?? this.wordCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
