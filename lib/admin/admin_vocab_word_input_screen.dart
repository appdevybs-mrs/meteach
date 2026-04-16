import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _speakingLoading = true;
  bool _speakingBusy = false;
  bool _selectionMode = false;
  String _search = '';

  final Set<String> _selectedWordIds = <String>{};
  final List<_VocabWordItem> _words = <_VocabWordItem>[];
  final List<_SpeakingTopicItem> _speakingTopics = <_SpeakingTopicItem>[];

  DatabaseReference get _listMetaRef =>
      _db.child('vocab_lists/${widget.courseId}');

  DatabaseReference get _wordsRef =>
      _db.child('vocab_words/${widget.courseId}');

  DatabaseReference get _speakingRef =>
      _db.child('study_coach_speaking/${widget.courseId}');

  String _safePathSegment(String value, {String fallback = 'item'}) {
    final cleaned = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? fallback : cleaned;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadWords());
    unawaited(_loadSpeakingTopics());
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

  Future<String> _uploadImage({required String section}) async {
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
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final courseFolder = _safePathSegment(widget.courseId, fallback: 'course');
    final baseName = picked.name.split('.').first;
    final customName = _safePathSegment(baseName, fallback: section);
    final uploadPath = 'study_coach/$courseFolder/$section/${now.year}/$month';

    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_file_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);
    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['root'] = 'courses';
    request.fields['path'] = uploadPath;
    request.fields['custom_name'] = customName;

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
      final url = await _uploadImage(section: 'vocabulary');
      await _wordsRef.child(item.id).update({
        'imageUrl': url,
        'updatedAt': ServerValue.timestamp,
      });
      await _loadWords();
      if (!mounted) return;
      AppToast.show(context, 'Image updated.', type: AppToastType.success);
    });
  }

  Future<void> _loadSpeakingTopics() async {
    setState(() => _speakingLoading = true);
    try {
      final snap = await _speakingRef.get();
      final next = <_SpeakingTopicItem>[];
      if (snap.exists && snap.value is Map) {
        final map = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final entry in map.entries) {
          if (entry.value is! Map) continue;
          final valueMap = Map<String, dynamic>.from(
            (entry.value as Map).map((k, v) => MapEntry(k.toString(), v)),
          );
          final item = _SpeakingTopicItem.fromMap(
            entry.key.toString(),
            valueMap,
          );
          if (item.topic.isEmpty) continue;
          next.add(item);
        }
      }

      next.sort((a, b) {
        if (a.updatedAt != b.updatedAt) {
          return b.updatedAt.compareTo(a.updatedAt);
        }
        return a.topic.toLowerCase().compareTo(b.topic.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _speakingTopics
          ..clear()
          ..addAll(next);
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not load speaking topics: ${toHumanError(e)}',
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _speakingLoading = false);
    }
  }

  Future<void> _setSpeakingBusy(Future<void> Function() action) async {
    if (_speakingBusy) return;
    setState(() => _speakingBusy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _speakingBusy = false);
    }
  }

  Future<void> _openSpeakingDialog({_SpeakingTopicItem? item}) async {
    final topicCtrl = TextEditingController(text: item?.topic ?? '');
    final questionsCtrl = TextEditingController(
      text: item == null ? '' : item.questions.join('\n'),
    );
    final keywordsCtrl = TextEditingController(text: item?.keywordsText ?? '');
    final sampleCtrl = TextEditingController(text: item?.exampleSpeech ?? '');
    final imageCtrl = TextEditingController(text: item?.imageUrl ?? '');
    final isEdit = item != null;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(isEdit ? 'Edit speaking topic' : 'Add speaking topic'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: topicCtrl,
                    decoration: const InputDecoration(labelText: 'Topic *'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: questionsCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Questions (one per line)',
                    ),
                    minLines: 3,
                    maxLines: 8,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: keywordsCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Keywords (plain multiline text)',
                    ),
                    minLines: 2,
                    maxLines: 6,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: sampleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Example speech',
                    ),
                    minLines: 3,
                    maxLines: 8,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: imageCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Image URL (optional)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          try {
                            final url = await _uploadImage(section: 'speaking');
                            imageCtrl.text = url;
                            if (!ctx.mounted) return;
                            AppToast.show(
                              ctx,
                              'Image uploaded.',
                              type: AppToastType.success,
                            );
                          } catch (e) {
                            if (!ctx.mounted) return;
                            AppToast.show(
                              ctx,
                              'Image upload failed: ${toHumanError(e)}',
                              type: AppToastType.error,
                            );
                          }
                        },
                        icon: Icon(Icons.image_rounded, color: cs.primary),
                        label: const Text('Upload'),
                      ),
                    ],
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

    final topic = topicCtrl.text.trim();
    if (topic.isEmpty) {
      if (!mounted) return;
      AppToast.show(context, 'Topic is required.', type: AppToastType.error);
      return;
    }

    final questions = questionsCtrl.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    await _setSpeakingBusy(() async {
      final map = <String, dynamic>{
        'topic': topic,
        'questions': questions,
        'keywordsText': keywordsCtrl.text.trim(),
        'exampleSpeech': sampleCtrl.text.trim(),
        'imageUrl': imageCtrl.text.trim(),
        'updatedAt': ServerValue.timestamp,
      };
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isNotEmpty) map['updatedBy'] = uid;

      if (item == null) {
        final newRef = _speakingRef.push();
        await newRef.set({
          ...map,
          'createdAt': ServerValue.timestamp,
          if (uid.isNotEmpty) 'createdBy': uid,
        });
      } else {
        await _speakingRef.child(item.id).update(map);
      }

      await _loadSpeakingTopics();
      if (!mounted) return;
      AppToast.show(
        context,
        item == null ? 'Topic added.' : 'Topic updated.',
        type: AppToastType.success,
      );
    });
  }

  Future<void> _deleteSpeakingTopic(_SpeakingTopicItem item) async {
    final ok = await _confirmDelete(
      title: 'Delete topic?',
      message: 'Delete speaking topic "${item.topic}"?',
    );
    if (!ok) return;

    await _setSpeakingBusy(() async {
      await _speakingRef.child(item.id).remove();
      await _loadSpeakingTopics();
      if (!mounted) return;
      AppToast.show(context, 'Topic deleted.', type: AppToastType.success);
    });
  }

  String _vocabularyCsvInstructions() {
    return [
      'Vocabulary CSV template (required headers):',
      'word,definition,example,training_examples,image_url',
      '',
      'Rules:',
      '- Keep headers exactly as shown above.',
      '- training_examples uses | separator.',
      '- image_url accepts full public URL.',
      '- Existing words are merged by exact word (case-insensitive).',
      '',
      'Sample row:',
      'apple,A fruit,I eat an apple daily.,I like apples|Apple is healthy,https://example.com/apple.jpg',
      '',
      'Long-press this text to copy.',
    ].join('\n');
  }

  String _speakingCsvInstructions() {
    return [
      'Speaking CSV template (recommended headers):',
      'topic,questions,keywords_text,example_speech,image_url',
      '',
      'Rules:',
      '- topic is required.',
      '- questions use | separator when importing CSV.',
      '- keywords_text stays plain multiline/paragraph style.',
      '- example_speech can be one long paragraph.',
      '- image_url accepts full public URL.',
      '',
      'Sample row:',
      'My Dream Job,What job do you want?|Why do you like it?,career words and useful phrases,I want to become a...,https://example.com/speaking.jpg',
      '',
      'Long-press this text to copy.',
    ].join('\n');
  }

  Future<void> _showTabInstructions(int tabIndex) async {
    final title = switch (tabIndex) {
      0 => 'Vocabulary CSV Guide',
      1 => 'Grammar Guide',
      _ => 'Speaking CSV Guide',
    };
    final content = switch (tabIndex) {
      0 => _vocabularyCsvInstructions(),
      1 => 'Grammar tab is currently empty.\n\nLong-press this text to copy.',
      _ => _speakingCsvInstructions(),
    };

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: GestureDetector(
          onLongPress: () async {
            await Clipboard.setData(ClipboardData(text: content));
            if (!ctx.mounted) return;
            AppToast.show(ctx, 'Copied.', type: AppToastType.success);
          },
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: const TextStyle(height: 1.35),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
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
    const vocabGreen = Color(0xFF1E8E5A);
    const speakingBlue = Color(0xFF12438A);

    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (tabContext) {
          final tabs = DefaultTabController.of(tabContext);
          return AnimatedBuilder(
            animation: tabs,
            builder: (context, _) {
              final index = tabs.index;
              final accent = switch (index) {
                0 => vocabGreen,
                1 => cs.primary,
                _ => speakingBlue,
              };

              return Stack(
                children: [
                  Scaffold(
                    appBar: AppBar(
                      title: Text('Study Coach • ${widget.courseTitle}'),
                      actions: [
                        IconButton(
                          tooltip: 'Instructions',
                          onPressed: () => _showTabInstructions(index),
                          icon: const Icon(Icons.priority_high_rounded),
                        ),
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: index == 2
                              ? (_speakingBusy ? null : _loadSpeakingTopics)
                              : (_busy ? null : _loadWords),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                        if (index == 0)
                          PopupMenuButton<String>(
                            tooltip: 'Vocabulary options',
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
                                value: _selectionMode
                                    ? 'exit_select'
                                    : 'enter_select',
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
                      bottom: TabBar(
                        labelColor: accent,
                        indicatorColor: accent,
                        tabs: const [
                          Tab(text: 'Vocabulary'),
                          Tab(text: 'Grammar'),
                          Tab(text: 'Speaking'),
                        ],
                      ),
                    ),
                    body: adminWebBodyFrame(
                      context: context,
                      child: SafeArea(
                        child: TabBarView(
                          children: [
                            _buildVocabularyTab(theme, cs, vocabGreen),
                            _buildGrammarTab(theme),
                            _buildSpeakingTab(theme, speakingBlue),
                          ],
                        ),
                      ),
                    ),
                    floatingActionButton: switch (index) {
                      0 => FloatingActionButton.extended(
                        backgroundColor: vocabGreen,
                        onPressed: _busy ? null : _openAddDialog,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add word'),
                      ),
                      2 => FloatingActionButton.extended(
                        backgroundColor: speakingBlue,
                        onPressed: _speakingBusy ? null : _openSpeakingDialog,
                        icon: const Icon(Icons.add_comment_rounded),
                        label: const Text('Add topic'),
                      ),
                      _ => null,
                    },
                  ),
                  if (_busy || _speakingBusy) ...[
                    const Positioned.fill(
                      child: ModalBarrier(
                        dismissible: false,
                        color: Color(0x66000000),
                      ),
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
                            border: Border.all(
                              color: cs.outline.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const YbsBusyLogo(size: 56),
                              const SizedBox(height: 10),
                              Text(
                                'Processing...',
                                style: TextStyle(
                                  color: accent,
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
            },
          );
        },
      ),
    );
  }

  Widget _buildVocabularyTab(ThemeData theme, ColorScheme cs, Color accent) {
    final filtered = _filteredWords;
    return Column(
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
              ? Center(child: CircularProgressIndicator(color: accent))
              : filtered.isEmpty
              ? Center(
                  child: Text(
                    'No words found.',
                    style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.7,
                      ),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    final selected = _selectedWordIds.contains(item.id);
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: accent.withValues(alpha: 0.2)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        child: Row(
                          children: [
                            if (_selectionMode)
                              Checkbox(
                                value: selected,
                                activeColor: accent,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedWordIds.add(item.id);
                                    } else {
                                      _selectedWordIds.remove(item.id);
                                    }
                                  });
                                },
                              ),
                            if (item.imageUrl.trim().isNotEmpty)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  item.imageUrl,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    width: 48,
                                    height: 48,
                                    color: accent.withValues(alpha: 0.1),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.broken_image_rounded,
                                      size: 18,
                                      color: accent,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.text_fields_rounded,
                                  color: accent,
                                ),
                              ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.word,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: accent,
                                    ),
                                  ),
                                  if (item.definition.trim().isNotEmpty)
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
                                        color: theme.textTheme.bodyMedium?.color
                                            ?.withValues(alpha: 0.75),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Actions',
                              onSelected: (v) => _handleWordMenu(item, v),
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
                              icon: Icon(
                                Icons.more_vert_rounded,
                                color: accent,
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
    );
  }

  Widget _buildGrammarTab(ThemeData theme) {
    return Center(
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.rule_folder_rounded,
                size: 32,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 10),
              const Text(
                'Grammar tab is ready for future content.',
                style: TextStyle(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpeakingTab(ThemeData theme, Color accent) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.22)),
          ),
          child: Text(
            'Speaking topics: ${_speakingTopics.length}',
            style: TextStyle(fontWeight: FontWeight.w800, color: accent),
          ),
        ),
        Expanded(
          child: _speakingLoading
              ? Center(child: CircularProgressIndicator(color: accent))
              : _speakingTopics.isEmpty
              ? Center(
                  child: Text(
                    'No speaking topics yet. Use Add topic.',
                    style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.75,
                      ),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  itemCount: _speakingTopics.length,
                  itemBuilder: (context, index) {
                    final item = _speakingTopics[index];
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: accent.withValues(alpha: 0.28)),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _openSpeakingDialog(item: item),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (item.imageUrl.trim().isNotEmpty)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.network(
                                    item.imageUrl,
                                    width: 78,
                                    height: 78,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      width: 78,
                                      height: 78,
                                      color: accent.withValues(alpha: 0.1),
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.mic_none_rounded,
                                        color: accent,
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Container(
                                  width: 78,
                                  height: 78,
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    Icons.record_voice_over_rounded,
                                    color: accent,
                                  ),
                                ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.topic,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: accent,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Questions: ${item.questions.length}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (item.keywordsText.trim().isNotEmpty)
                                      Text(
                                        item.keywordsText,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: theme
                                              .textTheme
                                              .bodyMedium
                                              ?.color
                                              ?.withValues(alpha: 0.76),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Actions',
                                onSelected: (value) async {
                                  if (value == 'edit') {
                                    await _openSpeakingDialog(item: item);
                                  } else {
                                    await _deleteSpeakingTopic(item);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem<String>(
                                    value: 'edit',
                                    child: Text('Edit topic'),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text('Delete topic'),
                                  ),
                                ],
                                icon: Icon(
                                  Icons.more_horiz_rounded,
                                  color: accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
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

class _SpeakingTopicItem {
  const _SpeakingTopicItem({
    required this.id,
    required this.topic,
    required this.questions,
    required this.keywordsText,
    required this.exampleSpeech,
    required this.imageUrl,
    required this.updatedAt,
  });

  final String id;
  final String topic;
  final List<String> questions;
  final String keywordsText;
  final String exampleSpeech;
  final String imageUrl;
  final int updatedAt;

  factory _SpeakingTopicItem.fromMap(String id, Map<String, dynamic> map) {
    List<String> parseQuestions(dynamic raw) {
      if (raw is List) {
        return raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      if (raw is String) {
        return raw
            .split('|')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      return const <String>[];
    }

    int asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    return _SpeakingTopicItem(
      id: id,
      topic: (map['topic'] ?? '').toString().trim(),
      questions: parseQuestions(map['questions']),
      keywordsText: (map['keywordsText'] ?? '').toString().trim(),
      exampleSpeech: (map['exampleSpeech'] ?? '').toString().trim(),
      imageUrl: (map['imageUrl'] ?? '').toString().trim(),
      updatedAt: asInt(map['updatedAt']),
    );
  }
}
