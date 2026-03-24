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
import '../shared/human_error.dart';
import '../shared/material_webview_screen.dart';
import '../shared/app_feedback.dart';
import '../shared/teacher_tour_guide.dart';

class TeacherGamesScreen extends StatefulWidget {
  const TeacherGamesScreen({super.key});

  @override
  State<TeacherGamesScreen> createState() => _TeacherGamesScreenState();
}

class _TeacherGamesScreenState extends State<TeacherGamesScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final String? _myUid = FirebaseAuth.instance.currentUser?.uid;

  bool _saving = false;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _statusFilter = 'all';
  String _categoryFilter = 'all';
  String _sortBy = 'updated_desc';

  static const String _uploadUrl =
      'https://www.yourbridgeschool.com/app/secure/upload_file_secure.php';

  static const String _deleteUrl =
      'https://www.yourbridgeschool.com/app/secure/delete_file_secure.php';

  static const List<String> _categoryOptions = [
    'Vocabulary',
    'Grammar',
    'Reading',
    'Writing',
    'Listening',
    'Speaking',
    'Pronunciation',
    'Spelling',
    'Conversation',
    'Mixed Skills',
  ];

  static const List<String> _levelOptions = [
    'Beginner',
    'Elementary',
    'Pre-Intermediate',
    'Intermediate',
    'Upper-Intermediate',
    'Advanced',
    'All Levels',
  ];

  DatabaseReference get _gamesRef => _db.child('games');

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _safeFolderName(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');

    if (cleaned.isEmpty) return 'game';
    return cleaned;
  }

  String _serverFolderPath({
    required String teacherUid,
    required String gameUid,
    required String gameName,
  }) {
    return 'teachers/$teacherUid/$gameUid-${_safeFolderName(gameName)}';
  }

  String _friendlyFileName(String name) {
    final clean = Uri.decodeComponent(name.trim());
    if (clean.isEmpty) return 'Uploaded file';
    if (clean.length <= 48) return clean;
    return '${clean.substring(0, 32)}...${clean.substring(clean.length - 12)}';
  }

  String _fileNameFromUrl(String url) {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return 'Uploaded file';
    try {
      final path = Uri.parse(cleanUrl).path;
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return _friendlyFileName(cleanUrl);
      return _friendlyFileName(segments.last);
    } catch (_) {
      return _friendlyFileName(cleanUrl);
    }
  }

  String _cacheBustedUrl(String url, int version) {
    final clean = url.trim();
    if (clean.isEmpty) return clean;
    try {
      final uri = Uri.parse(clean);
      final qp = Map<String, String>.from(uri.queryParameters);
      qp['_v'] = version.toString();
      return uri.replace(queryParameters: qp).toString();
    } catch (_) {
      return clean;
    }
  }

  Future<String?> _uploadToServer({
    required String teacherUid,
    required String gameUid,
    required String gameName,
    required bool isThumbnail,
    void Function(double progress)? onProgress,
    void Function(String fileName)? onSelectedName,
    void Function(PlatformFile picked)? onSelectedFile,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: kIsWeb,
      type: isThumbnail ? FileType.image : FileType.any,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final picked = result.files.single;
    onSelectedName?.call(_friendlyFileName(picked.name));
    onSelectedFile?.call(picked);
    final uploadUri = await BackendApi.withAuthQuery(Uri.parse(_uploadUrl));
    final req = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(req);

    req.fields['root'] = 'games';
    req.fields['path'] =
        'teachers/$teacherUid/$gameUid-${_safeFolderName(gameName)}';

    if (kIsWeb) {
      final Uint8List? bytes = picked.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file');
      }

      final total = bytes.length;
      int sent = 0;
      final stream = Stream<List<int>>.value(bytes).transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            if (onProgress != null && total > 0) {
              final p = (sent / total).clamp(0.0, 1.0);
              onProgress((p * 0.9).toDouble());
            }
            sink.add(chunk);
          },
        ),
      );

      req.files.add(
        http.MultipartFile('file', stream, total, filename: picked.name),
      );
    } else {
      final path = picked.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected file path');
      }

      final local = File(path);
      final total = await local.length();
      int sent = 0;
      final stream = local.openRead().transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            if (onProgress != null && total > 0) {
              final p = (sent / total).clamp(0.0, 1.0);
              onProgress((p * 0.9).toDouble());
            }
            sink.add(chunk);
          },
        ),
      );

      req.files.add(
        http.MultipartFile('file', stream, total, filename: picked.name),
      );
    }

    onProgress?.call(0.0);
    final streamed = await req.send().timeout(const Duration(minutes: 5));
    onProgress?.call(0.95);
    final response = await http.Response.fromStream(
      streamed,
    ).timeout(const Duration(minutes: 5));

    final raw = response.body.trim();
    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.\n$raw');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid upload response');
    }

    if (data['success'] == true) {
      final url = (data['url'] ?? '').toString().trim();
      if (url.isEmpty) {
        throw Exception('Upload succeeded but no URL was returned');
      }
      onProgress?.call(1.0);
      return url;
    }

    throw Exception((data['message'] ?? 'Upload failed').toString());
  }

  Future<void> _deleteFromServer({
    required String teacherUid,
    required String gameUid,
    required String gameName,
  }) async {
    final headers = await BackendApi.authHeaders();
    final authFields = await BackendApi.authFormFields();
    final deleteUri = await BackendApi.withAuthQuery(Uri.parse(_deleteUrl));
    final response = await http.post(
      deleteUri,
      headers: headers,
      body: {
        'root': 'games',
        'path': _serverFolderPath(
          teacherUid: teacherUid,
          gameUid: gameUid,
          gameName: gameName,
        ),
        ...authFields,
      },
    );

    final raw = response.body.trim();

    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.\n$raw');
    }

    final data = json.decode(raw);

    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid delete response');
    }

    if (data['success'] == true) {
      return;
    }

    final message = (data['message'] ?? 'Delete failed').toString();
    final lower = message.toLowerCase();

    if (lower == 'item not found' ||
        lower == 'file not found.' ||
        lower == 'file not found' ||
        lower.contains('not found')) {
      return;
    }

    throw Exception(message);
  }

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

      final game = Map<String, dynamic>.from(value);
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

  List<String> _extractAllCategories(dynamic gamesValue) {
    final out = <String>{};

    if (gamesValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(gamesValue);

    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final game = Map<String, dynamic>.from(value);
      final category = (game['category'] ?? '').toString().trim();
      if (category.isNotEmpty) out.add(category);
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

  Future<void> _deleteGame(String gameId, Map<String, dynamic> game) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Delete game'),
              content: const Text(
                'Are you sure you want to delete this game and its uploaded files?',
              ),
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
        ) ??
        false;

    if (!ok) return;

    final teacherUid = (game['teacherUid'] ?? '').toString().trim();
    final gameUid = (game['gameUid'] ?? gameId).toString().trim();
    final gameName = (game['name'] ?? '').toString().trim();

    try {
      if (teacherUid.isNotEmpty && gameUid.isNotEmpty && gameName.isNotEmpty) {
        await _deleteFromServer(
          teacherUid: teacherUid,
          gameUid: gameUid,
          gameName: gameName,
        );
      }

      await _gamesRef.child(gameId).remove();

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Game deleted successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not delete game. Try again.'),
          ),
        ),
      );
    }
  }

  Future<void> _duplicateGame({
    required String gameId,
    required Map<String, dynamic> existingGame,
  }) async {
    if (!_canEditGame(existingGame)) return;

    try {
      final teacher = await _loadMyTeacherData();
      if (teacher == null) {
        if (!mounted) return;
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Could not load teacher details.')),
        );
        return;
      }

      final ref = _gamesRef.push();
      final now = ServerValue.timestamp;

      final cloned = <String, dynamic>{
        ...existingGame,
        'gameUid': ref.key ?? '',
        'name': '${(existingGame['name'] ?? 'Game').toString().trim()} Copy',
        'createdAt': now,
        'updatedAt': now,
        'status': 'draft',
      };

      await ref.set(cloned);

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Game duplicated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not duplicate game. Try again.'),
          ),
        ),
      );
    }
  }

  Future<void> _toggleArchive({
    required String gameId,
    required Map<String, dynamic> game,
  }) async {
    if (!_canEditGame(game)) return;

    final currentStatus = (game['status'] ?? 'ready').toString().trim();
    final nextStatus = currentStatus == 'archived' ? 'ready' : 'archived';

    try {
      await _gamesRef.child(gameId).update({
        'status': nextStatus,
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            nextStatus == 'archived'
                ? 'Game archived successfully.'
                : 'Game restored successfully.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not update game. Try again.'),
          ),
        ),
      );
    }
  }

  Future<void> _showGameForm({
    String? gameId,
    Map<String, dynamic>? existingGame,
    List<String> knownTags = const <String>[],
  }) async {
    final isEdit = gameId != null && existingGame != null;
    final draftGameUid = gameId ?? _gamesRef.push().key ?? '';

    final nameController = TextEditingController(
      text: (existingGame?['name'] ?? '').toString(),
    );
    final descriptionController = TextEditingController(
      text: (existingGame?['description'] ?? '').toString(),
    );
    final rulesController = TextEditingController(
      text: (existingGame?['rules'] ?? '').toString(),
    );
    final categoryController = TextEditingController(
      text: (existingGame?['category'] ?? '').toString(),
    );
    final levelController = TextEditingController(
      text: (existingGame?['level'] ?? '').toString(),
    );
    final durationController = TextEditingController(
      text: (existingGame?['durationMinutes'] ?? '').toString(),
    );
    final teacherNotesController = TextEditingController(
      text: (existingGame?['teacherNotes'] ?? '').toString(),
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
        bool localUploadingGame = false;
        bool localUploadingThumb = false;
        double localGameUploadProgress = 0;
        double localThumbUploadProgress = 0;

        String uploadedUrl = (existingGame?['link'] ?? '').toString().trim();
        String uploadedThumbnail = (existingGame?['thumbnail'] ?? '')
            .toString()
            .trim();
        String uploadedGameFileName = _fileNameFromUrl(uploadedUrl);
        String uploadedThumbFileName = _fileNameFromUrl(uploadedThumbnail);
        Uint8List? localThumbBytes;
        String? localThumbPath;
        int thumbPreviewVersion = DateTime.now().millisecondsSinceEpoch;
        String selectedStatus = (existingGame?['status'] ?? 'ready')
            .toString()
            .trim();

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

            Future<void> uploadGameFile() async {
              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in teacher found.')),
                );
                return;
              }

              final gameName = nameController.text.trim();
              if (gameName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Enter the game name before uploading.'),
                  ),
                );
                return;
              }

              try {
                final url = await _uploadToServer(
                  teacherUid: uid,
                  gameUid: draftGameUid,
                  gameName: gameName,
                  isThumbnail: false,
                  onSelectedName: (name) {
                    setLocalState(() {
                      uploadedGameFileName = name;
                      localUploadingGame = true;
                      localGameUploadProgress = 0;
                    });
                  },
                  onProgress: (p) {
                    setLocalState(() {
                      localGameUploadProgress = p;
                    });
                  },
                );

                if (url != null && url.trim().isNotEmpty) {
                  setLocalState(() {
                    uploadedUrl = url.trim();
                    uploadedGameFileName = _fileNameFromUrl(uploadedUrl);
                  });

                  if (!mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Game file uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload game file.'),
                    ),
                  ),
                );
              } finally {
                setLocalState(() {
                  localUploadingGame = false;
                  localGameUploadProgress = 0;
                });
              }
            }

            Future<void> uploadThumbnail() async {
              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in teacher found.')),
                );
                return;
              }

              final gameName = nameController.text.trim();
              if (gameName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text(
                      'Enter the game name before uploading thumbnail.',
                    ),
                  ),
                );
                return;
              }

              try {
                final url = await _uploadToServer(
                  teacherUid: uid,
                  gameUid: draftGameUid,
                  gameName: gameName,
                  isThumbnail: true,
                  onSelectedName: (name) {
                    setLocalState(() {
                      uploadedThumbFileName = name;
                      localUploadingThumb = true;
                      localThumbUploadProgress = 0;
                    });
                  },
                  onSelectedFile: (picked) {
                    setLocalState(() {
                      if (kIsWeb && picked.bytes != null) {
                        localThumbBytes = picked.bytes;
                        localThumbPath = null;
                      } else if (picked.path != null &&
                          picked.path!.isNotEmpty) {
                        localThumbPath = picked.path;
                        localThumbBytes = null;
                      }
                    });
                  },
                  onProgress: (p) {
                    setLocalState(() {
                      localThumbUploadProgress = p;
                    });
                  },
                );

                if (url != null && url.trim().isNotEmpty) {
                  setLocalState(() {
                    uploadedThumbnail = url.trim();
                    uploadedThumbFileName = _fileNameFromUrl(uploadedThumbnail);
                    thumbPreviewVersion = DateTime.now().millisecondsSinceEpoch;
                  });

                  if (!mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Thumbnail uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload thumbnail.'),
                    ),
                  ),
                );
              } finally {
                setLocalState(() {
                  localUploadingThumb = false;
                  localThumbUploadProgress = 0;
                });
              }
            }

            Future<void> saveGame() async {
              final name = nameController.text.trim();
              final description = descriptionController.text.trim();
              final rules = rulesController.text.trim();
              final category = categoryController.text.trim();
              final level = levelController.text.trim();
              final teacherNotes = teacherNotesController.text.trim();
              final link = uploadedUrl.trim();
              final thumbnail = uploadedThumbnail.trim();
              final durationMinutes =
                  int.tryParse(durationController.text.trim()) ?? 0;

              if (name.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please enter the game name.')),
                );
                return;
              }

              if (description.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please enter the game description.'),
                  ),
                );
                return;
              }

              if (link.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please upload the game file first.'),
                  ),
                );
                return;
              }

              final teacher = await _loadMyTeacherData();
              if (teacher == null) {
                if (!mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Could not load teacher details.'),
                  ),
                );
                return;
              }

              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                if (!mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in teacher found.')),
                );
                return;
              }

              final firstName = (teacher['first_name'] ?? '').toString().trim();
              final lastName = (teacher['last_name'] ?? '').toString().trim();
              final email = (teacher['email'] ?? '').toString().trim();
              final serial = (teacher['serial'] ?? '').toString().trim();
              final now = ServerValue.timestamp;

              final tagsToSave =
                  chosenTags
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList()
                    ..sort(
                      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                    );

              setLocalState(() => localSaving = true);
              if (mounted) {
                setState(() => _saving = true);
              }

              try {
                final ref = isEdit
                    ? _gamesRef.child(gameId)
                    : _gamesRef.child(draftGameUid);

                final data = <String, dynamic>{
                  'gameUid': ref.key ?? draftGameUid,
                  'teacherUid': uid,
                  'teacherFirstName': firstName,
                  'teacherLastName': lastName,
                  'teacherEmail': email,
                  'teacherSerial': serial,
                  'name': name,
                  'description': description,
                  'rules': rules,
                  'link': link,
                  'thumbnail': thumbnail,
                  'tags': tagsToSave,
                  'category': category,
                  'level': level,
                  'durationMinutes': durationMinutes,
                  'teacherNotes': teacherNotes,
                  'status': selectedStatus,
                  'updatedAt': now,
                };

                if (!isEdit) {
                  data['createdAt'] = now;
                } else {
                  data['createdAt'] =
                      existingGame['createdAt'] ?? ServerValue.timestamp;
                }

                await ref.update(data);

                if (!mounted) return;
                Navigator.of(ctx).pop();

                AppToast.fromSnackBar(
                  context,
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
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(
                        e,
                        fallback: 'Could not save game. Try again.',
                      ),
                    ),
                  ),
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
                      DropdownButtonFormField<String>(
                        initialValue:
                            _categoryOptions.contains(
                              categoryController.text.trim(),
                            )
                            ? categoryController.text.trim()
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          border: OutlineInputBorder(),
                        ),
                        items: _categoryOptions
                            .map(
                              (item) => DropdownMenuItem<String>(
                                value: item,
                                child: Text(item),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setLocalState(() {
                            categoryController.text = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue:
                            _levelOptions.contains(levelController.text.trim())
                            ? levelController.text.trim()
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Level',
                          border: OutlineInputBorder(),
                        ),
                        items: _levelOptions
                            .map(
                              (item) => DropdownMenuItem<String>(
                                value: item,
                                child: Text(item),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setLocalState(() {
                            levelController.text = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: durationController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Duration in minutes',
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
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue:
                            const [
                              'draft',
                              'ready',
                              'hidden',
                              'archived',
                            ].contains(selectedStatus)
                            ? selectedStatus
                            : 'ready',
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'draft',
                            child: Text('Draft'),
                          ),
                          DropdownMenuItem(
                            value: 'ready',
                            child: Text('Ready'),
                          ),
                          DropdownMenuItem(
                            value: 'hidden',
                            child: Text('Hidden'),
                          ),
                          DropdownMenuItem(
                            value: 'archived',
                            child: Text('Archived'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setLocalState(() {
                            selectedStatus = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: teacherNotesController,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Teacher Notes',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Game File',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (uploadedUrl.isNotEmpty) ...[
                              Text(
                                uploadedGameFileName,
                                style: TextStyle(
                                  color: Colors.blue.shade700,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: uploadedUrl),
                                      );
                                      if (!mounted) return;
                                      AppToast.fromSnackBar(
                                        context,
                                        const SnackBar(
                                          content: Text('Link copied'),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: localUploadingGame
                                        ? null
                                        : uploadGameFile,
                                    icon: const Icon(Icons.sync_rounded),
                                    label: Text(
                                      localUploadingGame
                                          ? 'Uploading ${(localGameUploadProgress * 100).round()}%'
                                          : 'Replace File',
                                    ),
                                  ),
                                ],
                              ),
                              if (localUploadingGame) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localGameUploadProgress
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                                ),
                              ],
                            ] else ...[
                              const Text(
                                'No game file uploaded yet.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: localUploadingGame
                                    ? null
                                    : uploadGameFile,
                                icon: localUploadingGame
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.upload_file_rounded),
                                label: Text(
                                  localUploadingGame
                                      ? 'Uploading ${(localGameUploadProgress * 100).round()}%'
                                      : 'Upload Game File',
                                ),
                              ),
                              if (localUploadingGame) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localGameUploadProgress
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Thumbnail',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (uploadedThumbnail.isNotEmpty) ...[
                              Text(
                                uploadedThumbFileName,
                                style: TextStyle(
                                  color: Colors.blue.shade700,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: localThumbBytes != null
                                    ? Image.memory(
                                        localThumbBytes!,
                                        key: ValueKey(
                                          'thumb_memory_$thumbPreviewVersion',
                                        ),
                                        height: 140,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                      )
                                    : (localThumbPath != null &&
                                          localThumbPath!.isNotEmpty)
                                    ? Image.file(
                                        File(localThumbPath!),
                                        key: ValueKey(
                                          'thumb_file_$thumbPreviewVersion',
                                        ),
                                        height: 140,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                      )
                                    : Image.network(
                                        _cacheBustedUrl(
                                          uploadedThumbnail,
                                          thumbPreviewVersion,
                                        ),
                                        key: ValueKey(
                                          'thumb_net_$thumbPreviewVersion',
                                        ),
                                        height: 140,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => Container(
                                          height: 140,
                                          alignment: Alignment.center,
                                          color: Colors.grey.shade100,
                                          child: const Text(
                                            'Could not load thumbnail',
                                          ),
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: uploadedThumbnail),
                                      );
                                      if (!mounted) return;
                                      AppToast.fromSnackBar(
                                        context,
                                        const SnackBar(
                                          content: Text(
                                            'Thumbnail link copied',
                                          ),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: localUploadingThumb
                                        ? null
                                        : uploadThumbnail,
                                    icon: const Icon(Icons.image_rounded),
                                    label: Text(
                                      localUploadingThumb
                                          ? 'Uploading ${(localThumbUploadProgress * 100).round()}%'
                                          : 'Replace Thumbnail',
                                    ),
                                  ),
                                ],
                              ),
                              if (localUploadingThumb) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localThumbUploadProgress
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                                ),
                              ],
                            ] else ...[
                              const Text(
                                'No thumbnail uploaded yet.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: localUploadingThumb
                                    ? null
                                    : uploadThumbnail,
                                icon: localUploadingThumb
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.upload_rounded),
                                label: Text(
                                  localUploadingThumb
                                      ? 'Uploading ${(localThumbUploadProgress * 100).round()}%'
                                      : 'Upload Thumbnail',
                                ),
                              ),
                              if (localUploadingThumb) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localThumbUploadProgress
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                                ),
                              ],
                            ],
                          ],
                        ),
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

  Color _statusColor(String status) {
    switch (status) {
      case 'draft':
        return Colors.orange;
      case 'hidden':
        return Colors.grey;
      case 'archived':
        return Colors.blueGrey;
      case 'ready':
      default:
        return Colors.green;
    }
  }

  Widget _buildMiniInfoChip({
    required BuildContext context,
    required IconData icon,
    required String text,
    Color? backgroundColor,
    Color? borderColor,
    Color? iconColor,
    Color? textColor,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: backgroundColor ?? cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: borderColor ?? cs.primary.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: iconColor ?? cs.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: textColor ?? theme.textTheme.bodyMedium?.color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameCard({
    required String gameId,
    required Map<String, dynamic> game,
    required List<String> knownTags,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final canEdit = _canEditGame(game);
    final tags = _tagsFromGame(game);
    final name = (game['name'] ?? '').toString().trim();
    final description = (game['description'] ?? '').toString().trim();
    final rules = (game['rules'] ?? '').toString().trim();
    final link = (game['link'] ?? '').toString().trim();
    final thumbnail = (game['thumbnail'] ?? '').toString().trim();
    final ownerName = _teacherName(game);
    final category = (game['category'] ?? '').toString().trim();
    final level = (game['level'] ?? '').toString().trim();
    final status = (game['status'] ?? 'ready').toString().trim();
    final teacherNotes = (game['teacherNotes'] ?? '').toString().trim();
    final durationMinutes = _toInt(game['durationMinutes']);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: cs.outline.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
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
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 52,
                height: 52,
                color: cs.primary.withValues(alpha: 0.10),
                child: thumbnail.isNotEmpty
                    ? Image.network(
                        thumbnail,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
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
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.70,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildMiniInfoChip(
                        context: context,
                        icon: Icons.verified_rounded,
                        text: status,
                        backgroundColor: _statusColor(
                          status,
                        ).withValues(alpha: 0.12),
                        borderColor: _statusColor(
                          status,
                        ).withValues(alpha: 0.35),
                        iconColor: _statusColor(status),
                        textColor: _statusColor(status),
                      ),
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
                      ...tags
                          .take(2)
                          .map(
                            (tag) => _buildMiniInfoChip(
                              context: context,
                              icon: Icons.sell_rounded,
                              text: tag,
                              backgroundColor: cs.secondary.withValues(
                                alpha: 0.08,
                              ),
                              borderColor: cs.secondary.withValues(alpha: 0.14),
                              iconColor: cs.secondary,
                            ),
                          ),
                    ],
                  ),
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
                    errorBuilder: (_, _, _) => Container(
                      height: 180,
                      alignment: Alignment.center,
                      color: cs.primary.withValues(alpha: 0.06),
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
              if (category.isNotEmpty ||
                  level.isNotEmpty ||
                  durationMinutes > 0) ...[
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
                          backgroundColor: cs.primary.withValues(alpha: 0.08),
                          side: BorderSide(
                            color: cs.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      if (level.isNotEmpty)
                        Chip(
                          label: Text(level),
                          avatar: Icon(
                            Icons.bar_chart_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                          backgroundColor: cs.primary.withValues(alpha: 0.08),
                          side: BorderSide(
                            color: cs.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      if (durationMinutes > 0)
                        Chip(
                          label: Text('$durationMinutes min'),
                          avatar: Icon(
                            Icons.schedule_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                          backgroundColor: cs.primary.withValues(alpha: 0.08),
                          side: BorderSide(
                            color: cs.primary.withValues(alpha: 0.12),
                          ),
                        ),
                    ],
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
                            backgroundColor: cs.secondary.withValues(
                              alpha: 0.08,
                            ),
                            side: BorderSide(
                              color: cs.secondary.withValues(alpha: 0.14),
                            ),
                          ),
                        )
                        .toList(),
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
              if (teacherNotes.isNotEmpty && canEdit) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Teacher Notes',
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
                    teacherNotes,
                    style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.78,
                      ),
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (link.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Game Link',
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
                    link,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.blue.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
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
                      onPressed: () =>
                          _duplicateGame(gameId: gameId, existingGame: game),
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Duplicate'),
                    ),
                  if (canEdit)
                    OutlinedButton.icon(
                      onPressed: () =>
                          _toggleArchive(gameId: gameId, game: game),
                      icon: Icon(
                        status == 'archived'
                            ? Icons.unarchive_rounded
                            : Icons.archive_rounded,
                      ),
                      label: Text(status == 'archived' ? 'Restore' : 'Archive'),
                    ),
                  if (canEdit)
                    OutlinedButton.icon(
                      onPressed: () => _deleteGame(gameId, game),
                      icon: const Icon(Icons.delete_rounded),
                      label: const Text('Delete'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<MapEntry<String, Map<String, dynamic>>> _applyFiltersAndSort({
    required List<MapEntry<String, Map<String, dynamic>>> items,
  }) {
    var filtered = items.where((entry) {
      final game = entry.value;

      final name = (game['name'] ?? '').toString().toLowerCase().trim();
      final description = (game['description'] ?? '')
          .toString()
          .toLowerCase()
          .trim();
      final category = (game['category'] ?? '').toString().toLowerCase().trim();
      final level = (game['level'] ?? '').toString().toLowerCase().trim();
      final status = (game['status'] ?? 'ready')
          .toString()
          .toLowerCase()
          .trim();
      final tags = _tagsFromGame(game).map((e) => e.toLowerCase()).join(' ');

      final matchesSearch =
          _searchQuery.isEmpty ||
          name.contains(_searchQuery) ||
          description.contains(_searchQuery) ||
          category.contains(_searchQuery) ||
          level.contains(_searchQuery) ||
          tags.contains(_searchQuery);

      final matchesStatus =
          _statusFilter == 'all' || status == _statusFilter.toLowerCase();

      final matchesCategory =
          _categoryFilter == 'all' || category == _categoryFilter.toLowerCase();

      return matchesSearch && matchesStatus && matchesCategory;
    }).toList();

    filtered.sort((a, b) {
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
          return _toInt(
            b.value['createdAt'],
          ).compareTo(_toInt(a.value['createdAt']));
        case 'created_asc':
          return _toInt(
            a.value['createdAt'],
          ).compareTo(_toInt(b.value['createdAt']));
        case 'updated_asc':
          return _toInt(
            a.value['updatedAt'],
          ).compareTo(_toInt(b.value['updatedAt']));
        case 'updated_desc':
        default:
          return _toInt(
            b.value['updatedAt'],
          ).compareTo(_toInt(a.value['updatedAt']));
      }
    });

    return filtered;
  }

  Widget _buildFilterBar(List<String> categories) {
    final categoryItems = ['all', ...categories];
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: cs.outline.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.trim().toLowerCase();
                });
              },
              decoration: InputDecoration(
                hintText: 'Search games...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                        icon: const Icon(Icons.clear_rounded),
                      ),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: cs.outline.withValues(alpha: 0.18),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: cs.outline.withValues(alpha: 0.18),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: cs.primary, width: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _statusFilter,
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All')),
                      DropdownMenuItem(value: 'draft', child: Text('Draft')),
                      DropdownMenuItem(value: 'ready', child: Text('Ready')),
                      DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
                      DropdownMenuItem(
                        value: 'archived',
                        child: Text('Archived'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _statusFilter = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _categoryFilter,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      border: OutlineInputBorder(),
                    ),
                    items: categoryItems
                        .map(
                          (e) => DropdownMenuItem(
                            value: e,
                            child: Text(e == 'all' ? 'All' : e),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _categoryFilter = value;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _sortBy,
              decoration: const InputDecoration(
                labelText: 'Sort by',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'updated_desc',
                  child: Text('Recently updated'),
                ),
                DropdownMenuItem(
                  value: 'updated_asc',
                  child: Text('Oldest updated'),
                ),
                DropdownMenuItem(
                  value: 'created_desc',
                  child: Text('Newest created'),
                ),
                DropdownMenuItem(
                  value: 'created_asc',
                  child: Text('Oldest created'),
                ),
                DropdownMenuItem(value: 'name_asc', child: Text('Name A-Z')),
                DropdownMenuItem(value: 'name_desc', child: Text('Name Z-A')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _sortBy = value;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  int _myGamesCount(List<MapEntry<String, Map<String, dynamic>>> items) {
    return items.where((e) => _canEditGame(e.value)).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_games',
      hints: const [
        TeacherTourHint(
          title: 'Games manager',
          line:
              'Manage learning games, categories, and publishing status here.',
        ),
        TeacherTourHint(
          title: 'Add game',
          line: 'Use the Add Game button to create a new playable activity.',
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Games')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving
            ? null
            : () => _showGameForm(knownTags: const <String>[]),
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
          final categories = _extractAllCategories(value);

          if (value == null || value is! Map) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 480),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: cs.outline.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.sports_esports_rounded,
                        size: 48,
                        color: cs.primary,
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
              ),
            );
          }

          final raw = Map<dynamic, dynamic>.from(value);
          final items = raw.entries.map((entry) {
            final gameId = entry.key.toString();
            final gameValue = entry.value;

            final game = gameValue is Map
                ? Map<String, dynamic>.from(gameValue)
                : <String, dynamic>{};

            return MapEntry(gameId, game);
          }).toList();

          final visibleItems = _applyFiltersAndSort(items: items);

          return Column(
            children: [
              _buildFilterBar(categories),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total games: ${visibleItems.length} • My games: ${_myGamesCount(items)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    await _gamesRef.get();
                  },
                  child: visibleItems.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 40, 16, 100),
                          children: [
                            Center(
                              child: Text(
                                'No games match your filters.',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: theme.textTheme.bodyMedium?.color
                                      ?.withValues(alpha: 0.65),
                                ),
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                          itemCount: visibleItems.length,
                          itemBuilder: (context, index) {
                            final item = visibleItems[index];
                            return _buildGameCard(
                              gameId: item.key,
                              game: item.value,
                              knownTags: knownTags,
                            );
                          },
                        ),
                ),
              ),
            ],
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
