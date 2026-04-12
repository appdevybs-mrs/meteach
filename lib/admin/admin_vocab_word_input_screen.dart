import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/ybs_busy_logo.dart';

class AdminVocabWordInputScreen extends StatefulWidget {
  const AdminVocabWordInputScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
  });

  final String courseId;
  final String courseTitle;

  @override
  State<AdminVocabWordInputScreen> createState() =>
      _AdminVocabWordInputScreenState();
}

class _AdminVocabWordInputScreenState extends State<AdminVocabWordInputScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  bool _busy = false;
  bool _selectionMode = false;
  String _search = '';

  final Set<String> _selectedWordIds = <String>{};
  final List<_VocabWordItem> _words = <_VocabWordItem>[];

  DatabaseReference get _listMetaRef =>
      _db.child('vocab_lists/${widget.courseId}');

  DatabaseReference get _wordsRef =>
      _db.child('vocab_words/${widget.courseId}');

  String _courseImageAppId(String uid) {
    final safeCourse = widget.courseId.trim().replaceAll(
      RegExp(r'[^a-zA-Z0-9_-]'),
      '_',
    );
    return 'admin_vocab_words_${uid}_$safeCourse';
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadWords());
  }

  Future<void> _loadWords() async {
    setState(() => _loading = true);
    try {
      final snap = await _wordsRef.get();
      final next = <_VocabWordItem>[];
      if (snap.exists && snap.value is Map) {
        final map = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final entry in map.entries) {
          if (entry.value is! Map) continue;
          final valueMap = Map<String, dynamic>.from(
            (entry.value as Map).map((k, v) => MapEntry(k.toString(), v)),
          );
          next.add(_VocabWordItem.fromMap(entry.key.toString(), valueMap));
        }
      }

      next.sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _words
          ..clear()
          ..addAll(next);
      });
      await _syncListMeta();
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not load words: ${toHumanError(e)}',
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncListMeta() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? '';
    await _listMetaRef.update({
      'courseId': widget.courseId,
      'courseTitle': widget.courseTitle,
      'wordCount': _words.length,
      'updatedAt': ServerValue.timestamp,
      if (uid.isNotEmpty) 'updatedBy': uid,
      'active': true,
    });
  }

  List<_VocabWordItem> get _filteredWords {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return List<_VocabWordItem>.from(_words);
    return _words.where((w) {
      final blob = [
        w.word,
        w.definition,
        w.example,
        ...w.trainingExamples,
      ].join(' ').toLowerCase();
      return blob.contains(q);
    }).toList();
  }

  Future<void> _setBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAddDialog() async {
    await _openEditDialog();
  }

  Future<void> _openEditDialog({_VocabWordItem? item}) async {
    final wordCtrl = TextEditingController(text: item?.word ?? '');
    final defCtrl = TextEditingController(text: item?.definition ?? '');
    final exCtrl = TextEditingController(text: item?.example ?? '');
    final trainCtrl = TextEditingController(
      text: item == null ? '' : item.trainingExamples.join(' | '),
    );
    final imageCtrl = TextEditingController(text: item?.imageUrl ?? '');

    final isEdit = item != null;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit word' : 'Add word'),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: wordCtrl,
                    decoration: const InputDecoration(labelText: 'Word *'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: defCtrl,
                    decoration: const InputDecoration(labelText: 'Definition'),
                    minLines: 2,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: exCtrl,
                    decoration: const InputDecoration(labelText: 'Example'),
                    minLines: 2,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: trainCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Training examples (use | separator)',
                    ),
                    minLines: 2,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: imageCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Image URL (optional)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;

    final word = wordCtrl.text.trim();
    if (word.isEmpty) {
      if (!mounted) return;
      AppToast.show(context, 'Word is required.', type: AppToastType.error);
      return;
    }

    await _setBusy(() async {
      final duplicate = _words.any(
        (w) =>
            w.id != item?.id && _normalizeWord(w.word) == _normalizeWord(word),
      );
      if (duplicate) {
        throw Exception('This word already exists for this course.');
      }

      final trainingExamples = _splitExamples(trainCtrl.text);
      final map = <String, dynamic>{
        'word': word,
        'definition': defCtrl.text.trim(),
        'example': exCtrl.text.trim(),
        'trainingExamples': trainingExamples,
        'imageUrl': imageCtrl.text.trim(),
        'updatedAt': ServerValue.timestamp,
      };

      if (item == null) {
        final newRef = _wordsRef.push();
        await newRef.set({...map, 'createdAt': ServerValue.timestamp});
      } else {
        await _wordsRef.child(item.id).update(map);
      }

      await _loadWords();
      if (!mounted) return;
      AppToast.show(
        context,
        item == null ? 'Word added.' : 'Word updated.',
        type: AppToastType.success,
      );
    });
  }

  Future<String> _uploadImage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: kIsWeb,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
    );
    if (result == null || result.files.isEmpty) {
      throw Exception('No image selected.');
    }

    final picked = result.files.single;
    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);
    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['app_id'] = _courseImageAppId(user.uid);

    if (kIsWeb) {
      final bytes = picked.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected image bytes.');
      }
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: picked.name),
      );
    } else {
      final path = picked.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected image path.');
      }
      request.files.add(
        await http.MultipartFile.fromPath('file', path, filename: picked.name),
      );
    }

    final streamed = await request.send().timeout(const Duration(minutes: 5));
    final resp = await http.Response.fromStream(
      streamed,
    ).timeout(const Duration(minutes: 5));

    if (resp.statusCode != 200) {
      throw Exception('Upload failed (${resp.statusCode}).');
    }
    final body = jsonDecode(resp.body);
    if (body is! Map || body['success'] != true) {
      throw Exception(
        (body is Map ? body['message'] : 'Upload failed').toString(),
      );
    }
    final url = (body['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('Upload succeeded but no URL returned.');
    }
    return url;
  }

  Future<void> _replaceImage(_VocabWordItem item) async {
    await _setBusy(() async {
      final url = await _uploadImage();
      await _wordsRef.child(item.id).update({
        'imageUrl': url,
        'updatedAt': ServerValue.timestamp,
      });
      await _loadWords();
      if (!mounted) return;
      AppToast.show(context, 'Image updated.', type: AppToastType.success);
    });
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
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

  Future<void> _deleteWord(_VocabWordItem item) async {
    final ok = await _confirmDelete(
      title: 'Delete word?',
      message: 'Delete "${item.word}" from this course list?',
    );
    if (!ok) return;

    await _setBusy(() async {
      await _wordsRef.child(item.id).remove();
      await _loadWords();
      if (!mounted) return;
      AppToast.show(context, 'Word deleted.', type: AppToastType.success);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedWordIds.isEmpty) {
      AppToast.show(context, 'No selected words.', type: AppToastType.info);
      return;
    }

    final ok = await _confirmDelete(
      title: 'Delete selected words?',
      message: 'Delete ${_selectedWordIds.length} selected word(s)?',
    );
    if (!ok) return;

    await _setBusy(() async {
      for (final id in _selectedWordIds) {
        await _wordsRef.child(id).remove();
      }
      _selectedWordIds.clear();
      await _loadWords();
      if (!mounted) return;
      AppToast.show(
        context,
        'Selected words deleted.',
        type: AppToastType.success,
      );
    });
  }

  Future<void> _deleteFiltered() async {
    final filtered = _filteredWords;
    if (filtered.isEmpty) {
      AppToast.show(
        context,
        'No filtered rows to delete.',
        type: AppToastType.info,
      );
      return;
    }

    final ok = await _confirmDelete(
      title: 'Delete filtered rows?',
      message: 'This will delete ${filtered.length} filtered row(s). Continue?',
    );
    if (!ok) return;

    await _setBusy(() async {
      for (final w in filtered) {
        await _wordsRef.child(w.id).remove();
      }
      _selectedWordIds.removeWhere((id) => filtered.any((w) => w.id == id));
      await _loadWords();
      if (!mounted) return;
      AppToast.show(
        context,
        'Filtered rows deleted.',
        type: AppToastType.success,
      );
    });
  }

  Future<void> _importCsvMerge() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: kIsWeb,
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (result == null || result.files.isEmpty) return;

    await _setBusy(() async {
      final file = result.files.single;
      String raw;
      if (kIsWeb) {
        final bytes = file.bytes;
        if (bytes == null) throw Exception('Could not read CSV bytes.');
        raw = utf8.decode(bytes, allowMalformed: true);
      } else {
        final path = file.path;
        if (path == null || path.isEmpty) {
          throw Exception('Could not read CSV file path.');
        }
        raw = await File(path).readAsString();
      }

      final parsed = _parseCsv(raw);
      if (parsed.isEmpty) {
        throw Exception('CSV is empty.');
      }

      final headers = parsed.first.map(_normalizeHeader).toList();
      final required = [
        'word',
        'definition',
        'example',
        'training_examples',
        'image_url',
      ];
      for (final key in required) {
        if (!headers.contains(key)) {
          throw Exception('CSV missing required header: $key');
        }
      }

      final index = <String, int>{
        for (int i = 0; i < headers.length; i++) headers[i]: i,
      };

      final byNorm = <String, _VocabWordItem>{
        for (final w in _words) _normalizeWord(w.word): w,
      };

      int inserted = 0;
      int updated = 0;
      int skipped = 0;
      int errors = 0;

      for (int r = 1; r < parsed.length; r++) {
        final row = parsed[r];
        if (row.isEmpty) continue;

        String cell(String key) {
          final idx = index[key] ?? -1;
          if (idx < 0 || idx >= row.length) return '';
          return row[idx].trim();
        }

        final word = cell('word');
        if (word.isEmpty) {
          skipped++;
          continue;
        }
        final norm = _normalizeWord(word);

        final csvDefinition = cell('definition');
        final csvExample = cell('example');
        final csvImage = cell('image_url');
        final csvTrain = _splitExamples(cell('training_examples'));

        final existing = byNorm[norm];
        if (existing == null) {
          final newRef = _wordsRef.push();
          await newRef.set({
            'word': word,
            'definition': csvDefinition,
            'example': csvExample,
            'trainingExamples': csvTrain,
            'imageUrl': csvImage,
            'createdAt': ServerValue.timestamp,
            'updatedAt': ServerValue.timestamp,
          });
          inserted++;
          continue;
        }

        final mergedDefinition = existing.definition.trim().isEmpty
            ? csvDefinition
            : existing.definition;
        final mergedExample = existing.example.trim().isEmpty
            ? csvExample
            : existing.example;
        final mergedImage = existing.imageUrl.trim().isEmpty
            ? csvImage
            : existing.imageUrl;
        final mergedTraining = _mergeExamples(
          existing.trainingExamples,
          csvTrain,
        );

        final changed =
            mergedDefinition != existing.definition ||
            mergedExample != existing.example ||
            mergedImage != existing.imageUrl ||
            !_sameExamples(mergedTraining, existing.trainingExamples);

        if (!changed) {
          skipped++;
          continue;
        }

        try {
          await _wordsRef.child(existing.id).update({
            'definition': mergedDefinition,
            'example': mergedExample,
            'imageUrl': mergedImage,
            'trainingExamples': mergedTraining,
            'updatedAt': ServerValue.timestamp,
          });
          updated++;
        } catch (_) {
          errors++;
        }
      }

      await _loadWords();
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('CSV merge completed'),
          content: Text(
            'Inserted: $inserted\nUpdated: $updated\nSkipped: $skipped\nErrors: $errors',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    });
  }

  String _normalizeHeader(String value) {
    return value.trim().toLowerCase().replaceAll(' ', '_').replaceAll('-', '_');
  }

  String _normalizeWord(String value) => value.trim().toLowerCase();

  List<String> _splitExamples(String raw) {
    final parts = raw
        .split('|')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return _mergeExamples(const <String>[], parts);
  }

  List<String> _mergeExamples(List<String> a, List<String> b) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in [...a, ...b]) {
      final t = item.trim();
      if (t.isEmpty) continue;
      final key = t.toLowerCase();
      if (!seen.add(key)) continue;
      out.add(t);
    }
    return out;
  }

  bool _sameExamples(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<List<String>> _parseCsv(String source) {
    final rows = <List<String>>[];
    final row = <String>[];
    final cell = StringBuffer();
    bool inQuotes = false;

    void pushCell() {
      row.add(cell.toString());
      cell.clear();
    }

    void pushRow() {
      rows.add(List<String>.from(row));
      row.clear();
    }

    int i = 0;
    while (i < source.length) {
      final ch = source[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < source.length && source[i + 1] == '"') {
          cell.write('"');
          i += 2;
          continue;
        }
        inQuotes = !inQuotes;
        i++;
        continue;
      }

      if (!inQuotes && ch == ',') {
        pushCell();
        i++;
        continue;
      }

      if (!inQuotes && (ch == '\n' || ch == '\r')) {
        pushCell();
        pushRow();
        if (ch == '\r' && i + 1 < source.length && source[i + 1] == '\n') {
          i += 2;
        } else {
          i++;
        }
        continue;
      }

      cell.write(ch);
      i++;
    }

    if (cell.isNotEmpty || row.isNotEmpty) {
      pushCell();
      pushRow();
    }

    return rows
        .where((r) => r.any((c) => c.trim().isNotEmpty))
        .toList(growable: false);
  }

  Future<void> _handleTopMenu(String value) async {
    switch (value) {
      case 'add':
        await _openAddDialog();
        return;
      case 'import_csv':
        await _importCsvMerge();
        return;
      case 'enter_select':
        setState(() {
          _selectionMode = true;
          _selectedWordIds.clear();
        });
        return;
      case 'exit_select':
        setState(() {
          _selectionMode = false;
          _selectedWordIds.clear();
        });
        return;
      case 'delete_selected':
        await _deleteSelected();
        return;
      case 'delete_filtered':
        await _deleteFiltered();
        return;
      default:
        return;
    }
  }

  Future<void> _handleWordMenu(_VocabWordItem item, String value) async {
    switch (value) {
      case 'edit':
        await _openEditDialog(item: item);
        return;
      case 'replace_image':
        await _replaceImage(item);
        return;
      case 'delete':
        await _deleteWord(item);
        return;
      default:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final filtered = _filteredWords;

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: Text('Words • ${widget.courseTitle}'),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'More options',
                onSelected: _handleTopMenu,
                itemBuilder: (_) => [
                  const PopupMenuItem<String>(
                    value: 'add',
                    child: Text('Add word'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'import_csv',
                    child: Text('Import CSV (merge)'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    value: _selectionMode ? 'exit_select' : 'enter_select',
                    child: Text(
                      _selectionMode
                          ? 'Exit selection mode'
                          : 'Enter selection mode',
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete_selected',
                    child: Text('Delete selected words'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete_filtered',
                    child: Text('Delete filtered rows'),
                  ),
                ],
                icon: const Icon(Icons.more_vert_rounded),
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
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search words, definition, example...',
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Total: ${_words.length} • Filtered: ${filtered.length}${_selectionMode ? ' • Selected: ${_selectedWordIds.length}' : ''}',
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
                              'No words found.',
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
                              final item = filtered[index];
                              final selected = _selectedWordIds.contains(
                                item.id,
                              );
                              return Card(
                                elevation: 0,
                                margin: const EdgeInsets.only(bottom: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  side: BorderSide(
                                    color: cs.outline.withValues(alpha: 0.5),
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    8,
                                    8,
                                  ),
                                  child: Row(
                                    children: [
                                      if (_selectionMode)
                                        Checkbox(
                                          value: selected,
                                          onChanged: (v) {
                                            setState(() {
                                              if (v == true) {
                                                _selectedWordIds.add(item.id);
                                              } else {
                                                _selectedWordIds.remove(
                                                  item.id,
                                                );
                                              }
                                            });
                                          },
                                        ),
                                      if (item.imageUrl.trim().isNotEmpty)
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Image.network(
                                            item.imageUrl,
                                            width: 44,
                                            height: 44,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                Container(
                                                  width: 44,
                                                  height: 44,
                                                  color: cs.primary.withValues(
                                                    alpha: 0.08,
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: Icon(
                                                    Icons.broken_image_rounded,
                                                    size: 18,
                                                    color: cs.primary,
                                                  ),
                                                ),
                                          ),
                                        )
                                      else
                                        Container(
                                          width: 44,
                                          height: 44,
                                          decoration: BoxDecoration(
                                            color: cs.primary.withValues(
                                              alpha: 0.08,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          alignment: Alignment.center,
                                          child: Icon(
                                            Icons.text_fields_rounded,
                                            color: cs.primary,
                                          ),
                                        ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.word,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                color: cs.primary,
                                              ),
                                            ),
                                            if (item.definition
                                                .trim()
                                                .isNotEmpty)
                                              Text(
                                                item.definition,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            if (item.example.trim().isNotEmpty)
                                              Text(
                                                item.example,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w500,
                                                  color: theme
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.color
                                                      ?.withValues(alpha: 0.75),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        tooltip: 'Actions',
                                        onSelected: (v) =>
                                            _handleWordMenu(item, v),
                                        itemBuilder: (_) => const [
                                          PopupMenuItem<String>(
                                            value: 'edit',
                                            child: Text('Edit'),
                                          ),
                                          PopupMenuItem<String>(
                                            value: 'replace_image',
                                            child: Text('Replace image'),
                                          ),
                                          PopupMenuItem<String>(
                                            value: 'delete',
                                            child: Text('Delete'),
                                          ),
                                        ],
                                        icon: const Icon(
                                          Icons.more_vert_rounded,
                                        ),
                                      ),
                                    ],
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
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _busy ? null : _openAddDialog,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: const Text('Add'),
          ),
        ),
        if (_busy) ...[
          const Positioned.fill(
            child: ModalBarrier(dismissible: false, color: Color(0x66000000)),
          ),
          Positioned.fill(
            child: Center(
              child: Container(
                width: 220,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const YbsBusyLogo(size: 56),
                    const SizedBox(height: 10),
                    Text(
                      'Processing...',
                      style: TextStyle(
                        color: cs.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _VocabWordItem {
  const _VocabWordItem({
    required this.id,
    required this.word,
    required this.definition,
    required this.example,
    required this.trainingExamples,
    required this.imageUrl,
  });

  final String id;
  final String word;
  final String definition;
  final String example;
  final List<String> trainingExamples;
  final String imageUrl;

  factory _VocabWordItem.fromMap(String id, Map<String, dynamic> map) {
    List<String> parseTraining(dynamic raw) {
      if (raw is List) {
        return raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      if (raw is Map) {
        return raw.values
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      return const <String>[];
    }

    return _VocabWordItem(
      id: id,
      word: (map['word'] ?? '').toString().trim(),
      definition: (map['definition'] ?? '').toString().trim(),
      example: (map['example'] ?? '').toString().trim(),
      trainingExamples: parseTraining(map['trainingExamples']),
      imageUrl: (map['imageUrl'] ?? '').toString().trim(),
    );
  }
}
