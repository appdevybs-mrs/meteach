import 'dart:async';
import 'dart:convert';

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
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';

class TeacherStoriesScreen extends StatefulWidget {
  const TeacherStoriesScreen({super.key});

  @override
  State<TeacherStoriesScreen> createState() => _TeacherStoriesScreenState();
}

class _TeacherStoriesScreenState extends State<TeacherStoriesScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final String? _myUid = FirebaseAuth.instance.currentUser?.uid;

  bool _saving = false;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _statusFilter = 'all';
  String _genreFilter = 'all';
  String _sortBy = 'updated_desc';

  static const String _uploadUrl =
      'https://www.yourbridgeschool.com/app/secure/upload_file_secure.php';

  static const String _deleteUrl =
      'https://www.yourbridgeschool.com/app/secure/delete_item_secure.php';

  static const List<String> _genreOptions = [
    'Adventure',
    'Fantasy',
    'Mystery',
    'Sci-Fi',
    'Historical',
    'Comedy',
    'Drama',
    'Fairy Tale',
    'Educational',
    'Real Life',
    'Animal Story',
    'Friendship',
    'Family',
    'Moral Story',
  ];

  static const List<String> _lengthOptions = [
    'Very Short',
    'Short',
    'Medium',
    'Long',
  ];

  static const List<String> _scriptTypeOptions = [
    'Dialogue',
    'Narrative',
    'Mixed',
    'Illustrated',
    'Interactive',
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

  DatabaseReference get _storiesRef => _db.child('stories');

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

    if (cleaned.isEmpty) return 'story';
    return cleaned;
  }

  String _buildServerFolderPath({
    required String teacherUid,
    required String storyUid,
    required String storyName,
  }) {
    return 'teachers/$teacherUid/$storyUid-${_safeFolderName(storyName)}';
  }

  String _friendlyFileName(String name) {
    final raw = name.trim();
    String clean;
    try {
      clean = Uri.decodeComponent(raw);
    } catch (_) {
      clean = raw;
    }
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

  Future<String?> _uploadToServer({
    required String folderPath,
    required bool isThumbnail,
    List<String>? allowedExtensions,
    void Function(double progress)? onProgress,
    void Function(String fileName)? onSelectedName,
    void Function(PlatformFile picked)? onSelectedFile,
  }) async {
    final FileType pickerType;
    if (allowedExtensions != null && allowedExtensions.isNotEmpty) {
      pickerType = FileType.custom;
    } else if (isThumbnail) {
      pickerType = FileType.image;
    } else {
      pickerType = FileType.any;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: kIsWeb,
      type: pickerType,
      allowedExtensions: allowedExtensions,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final picked = result.files.single;

    if (allowedExtensions != null && allowedExtensions.isNotEmpty) {
      final allowed = allowedExtensions
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toSet();

      final ext = (picked.extension ?? '').trim().toLowerCase().replaceFirst(
        '.',
        '',
      );
      if (ext.isEmpty || !allowed.contains(ext)) {
        throw Exception(
          'Selected file format is not supported. Allowed: ${allowed.join(', ')}',
        );
      }
    }

    onSelectedName?.call(_friendlyFileName(picked.name));
    onSelectedFile?.call(picked);
    final uploadUri = await BackendApi.withAuthQuery(Uri.parse(_uploadUrl));
    final req = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(req);

    req.fields['root'] = 'stories';
    req.fields['path'] = folderPath;

    if (picked.path != null && picked.path!.isNotEmpty) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          picked.path!,
          filename: picked.name,
        ),
      );
    } else {
      final bytes = picked.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file');
      }
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: picked.name),
      );
    }

    onProgress?.call(0.1);
    final streamed = await req.send().timeout(const Duration(minutes: 5));
    onProgress?.call(0.95);
    final response = await http.Response.fromStream(
      streamed,
    ).timeout(const Duration(minutes: 5));

    final raw = response.body.trim();

    if (!raw.startsWith('{')) {
      throw Exception(
        'Server did not return JSON. HTTP ${response.statusCode}. Response: $raw',
      );
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

  Future<void> _deleteFromServer({required String folderPath}) async {
    final headers = await BackendApi.authHeaders();
    final authFields = await BackendApi.authFormFields();
    final deleteUri = await BackendApi.withAuthQuery(Uri.parse(_deleteUrl));
    final response = await http.post(
      deleteUri,
      headers: headers,
      body: {'root': 'stories', 'path': folderPath, ...authFields},
    );

    final raw = response.body.trim();

    if (!raw.startsWith('{')) {
      throw Exception(
        'Server did not return JSON. '
        'HTTP ${response.statusCode}. '
        'BODY: $raw',
      );
    }

    final data = json.decode(raw);

    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid delete response');
    }

    if (data['success'] == true) {
      return;
    }

    final message = (data['message'] ?? 'Delete failed').toString();

    if (message.toLowerCase() == 'item not found') {
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

  List<String> _extractAllKnownTags(dynamic storiesValue) {
    final out = <String>{};

    if (storiesValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(storiesValue);

    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final story = Map<String, dynamic>.from(value);
      final tags = story['tags'];

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

  List<String> _extractAllGenres(dynamic storiesValue) {
    final out = <String>{};

    if (storiesValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(storiesValue);

    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final story = Map<String, dynamic>.from(value);
      final genre = (story['genre'] ?? '').toString().trim();
      if (genre.isNotEmpty) out.add(genre);
    }

    final list = out.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  bool _canEditStory(Map<String, dynamic> story) {
    final ownerUid = (story['teacherUid'] ?? '').toString().trim();
    return _myUid != null && _myUid == ownerUid;
  }

  bool get _hasActiveFilters {
    return _searchQuery.isNotEmpty ||
        _statusFilter != 'all' ||
        _genreFilter != 'all' ||
        _sortBy != 'updated_desc';
  }

  Future<void> _openUrl({
    required String url,
    required String title,
    required String emptyMessage,
  }) async {
    final cleanUrl = url.trim();

    if (cleanUrl.isEmpty) {
      if (!mounted) return;
      AppToast.fromSnackBar(context, SnackBar(content: Text(emptyMessage)));
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MaterialWebViewScreen.fromUrl(title: title, url: cleanUrl),
      ),
    );
  }

  Future<void> _openStory(Map<String, dynamic> story) async {
    final link = (story['link'] ?? '').toString().trim();
    final name = (story['name'] ?? 'Story').toString().trim();

    await _openUrl(
      url: link,
      title: name.isEmpty ? 'Story' : name,
      emptyMessage: 'This story has no file.',
    );
  }

  Future<void> _openAudio(Map<String, dynamic> story) async {
    final audioUrl = (story['audioUrl'] ?? '').toString().trim();
    final name = (story['name'] ?? 'Story Audio').toString().trim();

    await _openUrl(
      url: audioUrl,
      title: name.isEmpty ? 'Story Audio' : '$name Audio',
      emptyMessage: 'This story has no audio.',
    );
  }

  Future<void> _openPdf(Map<String, dynamic> story) async {
    final pdfUrl = (story['pdfUrl'] ?? '').toString().trim();
    final name = (story['name'] ?? 'Story PDF').toString().trim();

    await _openUrl(
      url: pdfUrl,
      title: name.isEmpty ? 'Story PDF' : '$name PDF',
      emptyMessage: 'This story has no PDF.',
    );
  }

  Future<void> _deleteStory(String storyId, Map<String, dynamic> story) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Delete story'),
              content: const Text(
                'Are you sure you want to delete this story and all uploaded files?',
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

    final teacherUid = (story['teacherUid'] ?? '').toString().trim();
    final storyUid = (story['storyUid'] ?? storyId).toString().trim();
    final storyName = (story['name'] ?? '').toString().trim();

    final savedFolderPath = (story['serverFolderPath'] ?? '').toString().trim();
    final folderPath = savedFolderPath.isNotEmpty
        ? savedFolderPath
        : (teacherUid.isNotEmpty && storyUid.isNotEmpty && storyName.isNotEmpty)
        ? _buildServerFolderPath(
            teacherUid: teacherUid,
            storyUid: storyUid,
            storyName: storyName,
          )
        : '';

    try {
      if (folderPath.isNotEmpty) {
        await _deleteFromServer(folderPath: folderPath);
      }

      await _storiesRef.child(storyId).remove();

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Story deleted successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not delete story. Try again.'),
          ),
        ),
      );
    }
  }

  Future<void> _duplicateStory({
    required String storyId,
    required Map<String, dynamic> existingStory,
  }) async {
    if (!_canEditStory(existingStory)) return;

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

      final ref = _storiesRef.push();
      final now = ServerValue.timestamp;

      final cloned = <String, dynamic>{
        ...existingStory,
        'storyUid': ref.key ?? '',
        'name': '${(existingStory['name'] ?? 'Story').toString().trim()} Copy',
        'createdAt': now,
        'updatedAt': now,
        'status': 'draft',
        'serverFolderPath': '',
      };

      await ref.set(cloned);

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Story duplicated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not duplicate story. Try again.'),
          ),
        ),
      );
    }
  }

  Future<void> _toggleArchive({
    required String storyId,
    required Map<String, dynamic> story,
  }) async {
    if (!_canEditStory(story)) return;

    final currentStatus = (story['status'] ?? 'ready').toString().trim();
    final nextStatus = currentStatus == 'archived' ? 'ready' : 'archived';

    try {
      await _storiesRef.child(storyId).update({
        'status': nextStatus,
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            nextStatus == 'archived'
                ? 'Story archived successfully.'
                : 'Story restored successfully.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not update story. Try again.'),
          ),
        ),
      );
    }
  }

  Future<void> _showStoryForm({
    String? storyId,
    Map<String, dynamic>? existingStory,
    List<String> knownTags = const <String>[],
  }) async {
    final isEdit = storyId != null && existingStory != null;
    final draftStoryUid = storyId ?? _storiesRef.push().key ?? '';

    final nameController = TextEditingController(
      text: (existingStory?['name'] ?? '').toString(),
    );
    final descriptionController = TextEditingController(
      text: (existingStory?['description'] ?? '').toString(),
    );
    final authorSourceController = TextEditingController(
      text: (existingStory?['authorSource'] ?? '').toString(),
    );
    final genreController = TextEditingController(
      text: (existingStory?['genre'] ?? '').toString(),
    );
    final lengthController = TextEditingController(
      text: (existingStory?['lengthApprox'] ?? '').toString(),
    );
    final scriptTypeController = TextEditingController(
      text: (existingStory?['scriptType'] ?? '').toString(),
    );
    final levelController = TextEditingController(
      text: (existingStory?['level'] ?? '').toString(),
    );
    final teacherNotesController = TextEditingController(
      text: (existingStory?['teacherNotes'] ?? '').toString(),
    );
    final tagInputController = TextEditingController();

    final selectedTags = <String>{
      ...knownTags.where((e) => e.trim().isNotEmpty).map((e) => e.trim()),
    };

    final existingTagsValue = existingStory?['tags'];
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

    bool localSaving = false;
    bool localUploadingStory = false;
    bool localUploadingAudio = false;
    bool localUploadingPdf = false;
    bool localUploadingThumb = false;
    double localStoryUploadProgress = 0;
    double localAudioUploadProgress = 0;
    double localPdfUploadProgress = 0;
    double localThumbUploadProgress = 0;

    String uploadedUrl = (existingStory?['link'] ?? '').toString().trim();
    String uploadedAudioUrl = (existingStory?['audioUrl'] ?? '')
        .toString()
        .trim();
    String uploadedPdfUrl = (existingStory?['pdfUrl'] ?? '').toString().trim();
    String uploadedThumbnail = (existingStory?['thumbnail'] ?? '')
        .toString()
        .trim();
    String uploadedStoryFileName = _fileNameFromUrl(uploadedUrl);
    String uploadedAudioFileName = _fileNameFromUrl(uploadedAudioUrl);
    String uploadedPdfFileName = _fileNameFromUrl(uploadedPdfUrl);
    String uploadedThumbFileName = _fileNameFromUrl(uploadedThumbnail);
    String selectedStatus = (existingStory?['status'] ?? 'ready')
        .toString()
        .trim();

    String serverFolderPath = (existingStory?['serverFolderPath'] ?? '')
        .toString()
        .trim();

    String ensureFolderPath(String teacherUid) {
      if (serverFolderPath.isNotEmpty) {
        return serverFolderPath;
      }

      final storyName = nameController.text.trim();
      serverFolderPath = _buildServerFolderPath(
        teacherUid: teacherUid,
        storyUid: draftStoryUid,
        storyName: storyName,
      );
      return serverFolderPath;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            void safeLocalSetState(VoidCallback fn) {
              if (!context.mounted) return;
              setLocalState(fn);
            }

            void addTag(String raw) {
              final tag = raw.trim();
              if (tag.isEmpty) return;

              setLocalState(() {
                selectedTags.add(tag);
                chosenTags.add(tag);
                tagInputController.clear();
              });
            }

            Future<void> uploadStoryFile() async {
              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in teacher found.')),
                );
                return;
              }

              final storyName = nameController.text.trim();
              if (storyName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Enter the story title before uploading.'),
                  ),
                );
                return;
              }

              try {
                final folderPath = ensureFolderPath(uid);

                final url = await _uploadToServer(
                  folderPath: folderPath,
                  isThumbnail: false,
                  allowedExtensions: const ['html', 'htm'],
                  onSelectedName: (name) {
                    safeLocalSetState(() {
                      uploadedStoryFileName = name;
                    });
                  },
                  onSelectedFile: (_) {
                    safeLocalSetState(() {
                      localUploadingStory = true;
                      localStoryUploadProgress = 0;
                    });
                  },
                  onProgress: (p) {
                    safeLocalSetState(() {
                      localStoryUploadProgress = p;
                    });
                  },
                );

                if (url != null && url.trim().isNotEmpty) {
                  safeLocalSetState(() {
                    uploadedUrl = url.trim();
                    uploadedStoryFileName = _fileNameFromUrl(uploadedUrl);
                  });

                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Story file uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload story file.'),
                    ),
                  ),
                );
              } finally {
                safeLocalSetState(() {
                  localUploadingStory = false;
                  localStoryUploadProgress = 0;
                });
              }
            }

            Future<void> uploadAudioFile() async {
              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in teacher found.')),
                );
                return;
              }

              final storyName = nameController.text.trim();
              if (storyName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text(
                      'Enter the story title before uploading audio.',
                    ),
                  ),
                );
                return;
              }

              try {
                final folderPath = ensureFolderPath(uid);

                final url = await _uploadToServer(
                  folderPath: folderPath,
                  isThumbnail: false,
                  allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg'],
                  onSelectedName: (name) {
                    safeLocalSetState(() {
                      uploadedAudioFileName = name;
                    });
                  },
                  onSelectedFile: (_) {
                    safeLocalSetState(() {
                      localUploadingAudio = true;
                      localAudioUploadProgress = 0;
                    });
                  },
                  onProgress: (p) {
                    safeLocalSetState(() {
                      localAudioUploadProgress = p;
                    });
                  },
                );

                if (url != null && url.trim().isNotEmpty) {
                  safeLocalSetState(() {
                    uploadedAudioUrl = url.trim();
                    uploadedAudioFileName = _fileNameFromUrl(uploadedAudioUrl);
                  });

                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Audio uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload audio file.'),
                    ),
                  ),
                );
              } finally {
                safeLocalSetState(() {
                  localUploadingAudio = false;
                  localAudioUploadProgress = 0;
                });
              }
            }

            Future<void> uploadPdfFile() async {
              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in teacher found.')),
                );
                return;
              }

              final storyName = nameController.text.trim();
              if (storyName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text(
                      'Enter the story title before uploading PDF.',
                    ),
                  ),
                );
                return;
              }

              try {
                final folderPath = ensureFolderPath(uid);

                final url = await _uploadToServer(
                  folderPath: folderPath,
                  isThumbnail: false,
                  allowedExtensions: const ['pdf'],
                  onSelectedName: (name) {
                    safeLocalSetState(() {
                      uploadedPdfFileName = name;
                    });
                  },
                  onSelectedFile: (_) {
                    safeLocalSetState(() {
                      localUploadingPdf = true;
                      localPdfUploadProgress = 0;
                    });
                  },
                  onProgress: (p) {
                    safeLocalSetState(() {
                      localPdfUploadProgress = p;
                    });
                  },
                );

                if (url != null && url.trim().isNotEmpty) {
                  safeLocalSetState(() {
                    uploadedPdfUrl = url.trim();
                    uploadedPdfFileName = _fileNameFromUrl(uploadedPdfUrl);
                  });

                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(content: Text('PDF uploaded successfully.')),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload PDF file.'),
                    ),
                  ),
                );
              } finally {
                safeLocalSetState(() {
                  localUploadingPdf = false;
                  localPdfUploadProgress = 0;
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

              final storyName = nameController.text.trim();
              if (storyName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text(
                      'Enter the story title before uploading thumbnail.',
                    ),
                  ),
                );
                return;
              }

              try {
                final folderPath = ensureFolderPath(uid);

                final url = await _uploadToServer(
                  folderPath: folderPath,
                  isThumbnail: true,
                  allowedExtensions: const [
                    'jpg',
                    'jpeg',
                    'png',
                    'webp',
                    'gif',
                    'bmp',
                    'heic',
                    'heif',
                  ],
                  onSelectedName: (name) {
                    safeLocalSetState(() {
                      uploadedThumbFileName = name;
                    });
                  },
                  onSelectedFile: (_) {
                    safeLocalSetState(() {
                      localUploadingThumb = true;
                      localThumbUploadProgress = 0;
                    });
                  },
                  onProgress: (p) {
                    safeLocalSetState(() {
                      localThumbUploadProgress = p;
                    });
                  },
                );

                if (url != null && url.trim().isNotEmpty) {
                  safeLocalSetState(() {
                    uploadedThumbnail = url.trim();
                    uploadedThumbFileName = _fileNameFromUrl(uploadedThumbnail);
                  });

                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Thumbnail uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload thumbnail.'),
                    ),
                  ),
                );
              } finally {
                safeLocalSetState(() {
                  localUploadingThumb = false;
                  localThumbUploadProgress = 0;
                });
              }
            }

            Future<void> saveStory() async {
              final name = nameController.text.trim();
              final description = descriptionController.text.trim();
              final authorSource = authorSourceController.text.trim();
              final genre = genreController.text.trim();
              final lengthApprox = lengthController.text.trim();
              final scriptType = scriptTypeController.text.trim();
              final level = levelController.text.trim();
              final teacherNotes = teacherNotesController.text.trim();
              final link = uploadedUrl.trim();
              final audioUrl = uploadedAudioUrl.trim();
              final pdfUrl = uploadedPdfUrl.trim();
              final thumbnail = uploadedThumbnail.trim();

              if (name.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please enter the story title.'),
                  ),
                );
                return;
              }

              if (description.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please enter the story description.'),
                  ),
                );
                return;
              }

              if (genre.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please select the genre.')),
                );
                return;
              }

              if (lengthApprox.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please select the approximate length.'),
                  ),
                );
                return;
              }

              if (scriptType.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please select the script type.'),
                  ),
                );
                return;
              }

              if (level.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please select the level.')),
                );
                return;
              }

              if (link.isEmpty && audioUrl.isEmpty && pdfUrl.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text(
                      'Upload at least one story asset: HTML/Story file, Audio, or PDF.',
                    ),
                  ),
                );
                return;
              }

              if (thumbnail.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please upload a thumbnail image.'),
                  ),
                );
                return;
              }

              final teacher = await _loadMyTeacherData();
              if (teacher == null) {
                if (!context.mounted) return;
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
                if (!context.mounted) return;
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

              final finalFolderPath = serverFolderPath.isNotEmpty
                  ? serverFolderPath
                  : _buildServerFolderPath(
                      teacherUid: uid,
                      storyUid: draftStoryUid,
                      storyName: name,
                    );

              setLocalState(() => localSaving = true);
              if (mounted) {
                setState(() => _saving = true);
              }

              try {
                final ref = isEdit
                    ? _storiesRef.child(storyId)
                    : _storiesRef.child(draftStoryUid);

                final data = <String, dynamic>{
                  'storyUid': ref.key ?? draftStoryUid,
                  'teacherUid': uid,
                  'teacherFirstName': firstName,
                  'teacherLastName': lastName,
                  'teacherEmail': email,
                  'teacherSerial': serial,
                  'name': name,
                  'description': description,
                  'authorSource': authorSource,
                  'genre': genre,
                  'lengthApprox': lengthApprox,
                  'scriptType': scriptType,
                  'level': level,
                  'link': link,
                  'audioUrl': audioUrl,
                  'pdfUrl': pdfUrl,
                  'thumbnail': thumbnail,
                  'tags': tagsToSave,
                  'teacherNotes': teacherNotes,
                  'status': selectedStatus,
                  'serverFolderPath': finalFolderPath,
                  'updatedAt': now,
                };

                if (!isEdit) {
                  data['createdAt'] = now;
                } else {
                  data['createdAt'] =
                      existingStory['createdAt'] ?? ServerValue.timestamp;
                }

                await ref.update(data);

                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();

                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      isEdit
                          ? 'Story updated successfully.'
                          : 'Story added successfully.',
                    ),
                  ),
                );
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(
                        e,
                        fallback: 'Could not save story. Try again.',
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
                        isEdit ? 'Edit Story' : 'Add Story',
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
                          labelText: 'Story Title',
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
                      DropdownButtonFormField<String>(
                        initialValue:
                            _genreOptions.contains(genreController.text.trim())
                            ? genreController.text.trim()
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Genre',
                          border: OutlineInputBorder(),
                        ),
                        items: _genreOptions
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
                            genreController.text = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue:
                            _lengthOptions.contains(
                              lengthController.text.trim(),
                            )
                            ? lengthController.text.trim()
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Approximate Length',
                          border: OutlineInputBorder(),
                        ),
                        items: _lengthOptions
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
                            lengthController.text = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue:
                            _scriptTypeOptions.contains(
                              scriptTypeController.text.trim(),
                            )
                            ? scriptTypeController.text.trim()
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'Script Type',
                          border: OutlineInputBorder(),
                        ),
                        items: _scriptTypeOptions
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
                            scriptTypeController.text = value;
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
                          labelText: 'Language Level',
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
                        controller: authorSourceController,
                        decoration: const InputDecoration(
                          labelText: 'Author / Source',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Focus Skills / Tags',
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
                        'Story File (HTML / Reveal)',
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
                                uploadedStoryFileName,
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
                                      if (!context.mounted) return;
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
                                    onPressed: localUploadingStory
                                        ? null
                                        : uploadStoryFile,
                                    icon: const Icon(Icons.sync_rounded),
                                    label: Text(
                                      localUploadingStory
                                          ? 'Uploading ${(localStoryUploadProgress * 100).round()}%'
                                          : 'Replace File',
                                    ),
                                  ),
                                ],
                              ),
                              if (localUploadingStory) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localStoryUploadProgress
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                                ),
                              ],
                            ] else ...[
                              const Text(
                                'No story file uploaded yet.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: localUploadingStory
                                    ? null
                                    : uploadStoryFile,
                                icon: localUploadingStory
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.upload_file_rounded),
                                label: Text(
                                  localUploadingStory
                                      ? 'Uploading ${(localStoryUploadProgress * 100).round()}%'
                                      : 'Upload Story File',
                                ),
                              ),
                              if (localUploadingStory) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localStoryUploadProgress
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
                        'Audio File',
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
                            if (uploadedAudioUrl.isNotEmpty) ...[
                              Text(
                                uploadedAudioFileName,
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
                                        ClipboardData(text: uploadedAudioUrl),
                                      );
                                      if (!context.mounted) return;
                                      AppToast.fromSnackBar(
                                        context,
                                        const SnackBar(
                                          content: Text('Audio link copied'),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: localUploadingAudio
                                        ? null
                                        : uploadAudioFile,
                                    icon: const Icon(Icons.headphones_rounded),
                                    label: Text(
                                      localUploadingAudio
                                          ? 'Uploading ${(localAudioUploadProgress * 100).round()}%'
                                          : 'Replace Audio',
                                    ),
                                  ),
                                ],
                              ),
                              if (localUploadingAudio) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localAudioUploadProgress
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                                ),
                              ],
                            ] else ...[
                              const Text(
                                'No audio file uploaded yet.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: localUploadingAudio
                                    ? null
                                    : uploadAudioFile,
                                icon: localUploadingAudio
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.audio_file_rounded),
                                label: Text(
                                  localUploadingAudio
                                      ? 'Uploading ${(localAudioUploadProgress * 100).round()}%'
                                      : 'Upload Audio File',
                                ),
                              ),
                              if (localUploadingAudio) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localAudioUploadProgress
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
                        'PDF Script',
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
                            if (uploadedPdfUrl.isNotEmpty) ...[
                              Text(
                                uploadedPdfFileName,
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
                                        ClipboardData(text: uploadedPdfUrl),
                                      );
                                      if (!context.mounted) return;
                                      AppToast.fromSnackBar(
                                        context,
                                        const SnackBar(
                                          content: Text('PDF link copied'),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: localUploadingPdf
                                        ? null
                                        : uploadPdfFile,
                                    icon: const Icon(
                                      Icons.picture_as_pdf_rounded,
                                    ),
                                    label: Text(
                                      localUploadingPdf
                                          ? 'Uploading ${(localPdfUploadProgress * 100).round()}%'
                                          : 'Replace PDF',
                                    ),
                                  ),
                                ],
                              ),
                              if (localUploadingPdf) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localPdfUploadProgress
                                      .clamp(0.0, 1.0)
                                      .toDouble(),
                                ),
                              ],
                            ] else ...[
                              const Text(
                                'No PDF uploaded yet.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: localUploadingPdf
                                    ? null
                                    : uploadPdfFile,
                                icon: localUploadingPdf
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.picture_as_pdf_rounded),
                                label: Text(
                                  localUploadingPdf
                                      ? 'Uploading ${(localPdfUploadProgress * 100).round()}%'
                                      : 'Upload PDF File',
                                ),
                              ),
                              if (localUploadingPdf) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: localPdfUploadProgress
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
                                child: Image.network(
                                  uploadedThumbnail,
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
                                      if (!context.mounted) return;
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
                              onPressed: localSaving ? null : saveStory,
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

  String _teacherName(Map<String, dynamic> story) {
    final first = (story['teacherFirstName'] ?? '').toString().trim();
    final last = (story['teacherLastName'] ?? '').toString().trim();
    final full = ('$first $last').trim();

    if (full.isNotEmpty) return full;

    final email = (story['teacherEmail'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return 'Teacher';
  }

  List<String> _tagsFromStory(Map<String, dynamic> story) {
    final out = <String>[];
    final tags = story['tags'];

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

  String _sortLabel(String value) {
    switch (value) {
      case 'updated_desc':
        return 'Recently updated';
      case 'updated_asc':
        return 'Oldest updated';
      case 'created_desc':
        return 'Newest created';
      case 'created_asc':
        return 'Oldest created';
      case 'name_asc':
        return 'Name A-Z';
      case 'name_desc':
        return 'Name Z-A';
      default:
        return 'Sort';
    }
  }

  void _resetFilters() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _statusFilter = 'all';
      _genreFilter = 'all';
      _sortBy = 'updated_desc';
    });
  }

  Future<void> _showFilterSheet(List<String> genres) async {
    String tempStatus = _statusFilter;
    String tempGenre = _genreFilter;
    final genreItems = ['all', ...genres];

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Filters',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: tempStatus,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('All')),
                        DropdownMenuItem(value: 'draft', child: Text('Draft')),
                        DropdownMenuItem(value: 'ready', child: Text('Ready')),
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
                          tempStatus = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: genreItems.contains(tempGenre)
                          ? tempGenre
                          : 'all',
                      decoration: const InputDecoration(
                        labelText: 'Genre',
                        border: OutlineInputBorder(),
                      ),
                      items: genreItems
                          .map(
                            (e) => DropdownMenuItem<String>(
                              value: e,
                              child: Text(e == 'all' ? 'All' : e),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setLocalState(() {
                          tempGenre = value;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              setState(() {
                                _statusFilter = 'all';
                                _genreFilter = 'all';
                              });
                            },
                            child: const Text('Reset'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              setState(() {
                                _statusFilter = tempStatus;
                                _genreFilter = tempGenre;
                              });
                            },
                            child: const Text('Apply'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showSortSheet() async {
    String tempSort = _sortBy;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget option(String value, String title) {
          final selected = tempSort == value;

          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
            ),
            title: Text(
              title,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
            onTap: () {
              Navigator.of(ctx).pop();
              setState(() {
                _sortBy = value;
              });
            },
          );
        }

        return StatefulBuilder(
          builder: (context, setLocalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Sort by',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    option('updated_desc', 'Recently updated'),
                    option('updated_asc', 'Oldest updated'),
                    option('created_desc', 'Newest created'),
                    option('created_asc', 'Oldest created'),
                    option('name_asc', 'Name A-Z'),
                    option('name_desc', 'Name Z-A'),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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

  Widget _buildCompactToolbar(List<String> genres) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final activeFilterCount = [
      if (_statusFilter != 'all') 1,
      if (_genreFilter != 'all') 1,
    ].length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
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
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value.trim().toLowerCase();
                      });
                    },
                    decoration: InputDecoration(
                      hintText: 'Search stories...',
                      isDense: true,
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
                      fillColor: cs.surfaceContainerHighest.withValues(
                        alpha: 0.35,
                      ),
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
                ),
                const SizedBox(width: 8),
                _buildToolbarIcon(
                  icon: Icons.filter_list_rounded,
                  tooltip: 'Filters',
                  active: activeFilterCount > 0,
                  badgeText: activeFilterCount > 0
                      ? '$activeFilterCount'
                      : null,
                  onTap: () => _showFilterSheet(genres),
                ),
                const SizedBox(width: 8),
                _buildToolbarIcon(
                  icon: Icons.swap_vert_rounded,
                  tooltip: 'Sort',
                  active: _sortBy != 'updated_desc',
                  onTap: _showSortSheet,
                ),
                if (_hasActiveFilters) ...[
                  const SizedBox(width: 8),
                  _buildToolbarIcon(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Clear all',
                    onTap: _resetFilters,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTopTagChip(
                    icon: Icons.filter_list_rounded,
                    label: _statusFilter == 'all'
                        ? 'All statuses'
                        : 'Status: $_statusFilter',
                  ),
                  const SizedBox(width: 8),
                  _buildTopTagChip(
                    icon: Icons.category_rounded,
                    label: _genreFilter == 'all' ? 'All genres' : _genreFilter,
                  ),
                  const SizedBox(width: 8),
                  _buildTopTagChip(
                    icon: Icons.swap_vert_rounded,
                    label: _sortLabel(_sortBy),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
    String? badgeText,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: active
              ? cs.primary.withValues(alpha: 0.12)
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Tooltip(
              message: tooltip,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  icon,
                  color: active ? cs.primary : theme.iconTheme.color,
                ),
              ),
            ),
          ),
        ),
        if (badgeText != null)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  color: cs.onPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTopTagChip({required IconData icon, required String label}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outline.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Future<void> _handleStoryMenuAction({
    required String action,
    required String storyId,
    required Map<String, dynamic> story,
    required List<String> knownTags,
  }) async {
    switch (action) {
      case 'edit':
        await _showStoryForm(
          storyId: storyId,
          existingStory: story,
          knownTags: knownTags,
        );
        break;
      case 'duplicate':
        await _duplicateStory(storyId: storyId, existingStory: story);
        break;
      case 'archive':
        await _toggleArchive(storyId: storyId, story: story);
        break;
      case 'delete':
        await _deleteStory(storyId, story);
        break;
    }
  }

  Widget _buildStoryCard({
    required String storyId,
    required Map<String, dynamic> story,
    required List<String> knownTags,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final canEdit = _canEditStory(story);
    final tags = _tagsFromStory(story);
    final name = (story['name'] ?? '').toString().trim();
    final description = (story['description'] ?? '').toString().trim();
    final link = (story['link'] ?? '').toString().trim();
    final audioUrl = (story['audioUrl'] ?? '').toString().trim();
    final pdfUrl = (story['pdfUrl'] ?? '').toString().trim();
    final thumbnail = (story['thumbnail'] ?? '').toString().trim();
    final ownerName = _teacherName(story);
    final genre = (story['genre'] ?? '').toString().trim();
    final lengthApprox = (story['lengthApprox'] ?? '').toString().trim();
    final scriptType = (story['scriptType'] ?? '').toString().trim();
    final level = (story['level'] ?? '').toString().trim();
    final status = (story['status'] ?? 'ready').toString().trim();
    final teacherNotes = (story['teacherNotes'] ?? '').toString().trim();
    final authorSource = (story['authorSource'] ?? '').toString().trim();

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
                          Icons.menu_book_rounded,
                          color: cs.primary,
                          size: 24,
                        ),
                      )
                    : Icon(
                        Icons.menu_book_rounded,
                        color: cs.primary,
                        size: 24,
                      ),
              ),
            ),
            title: Text(
              name.isEmpty ? 'Untitled Story' : name,
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
                      if (genre.isNotEmpty)
                        _buildMiniInfoChip(
                          context: context,
                          icon: Icons.category_rounded,
                          text: genre,
                        ),
                      if (lengthApprox.isNotEmpty)
                        _buildMiniInfoChip(
                          context: context,
                          icon: Icons.schedule_rounded,
                          text: lengthApprox,
                        ),
                      if (scriptType.isNotEmpty)
                        _buildMiniInfoChip(
                          context: context,
                          icon: Icons.article_rounded,
                          text: scriptType,
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
              if (genre.isNotEmpty ||
                  lengthApprox.isNotEmpty ||
                  scriptType.isNotEmpty ||
                  level.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (genre.isNotEmpty)
                        Chip(
                          label: Text(genre),
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
                      if (lengthApprox.isNotEmpty)
                        Chip(
                          label: Text(lengthApprox),
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
                      if (scriptType.isNotEmpty)
                        Chip(
                          label: Text(scriptType),
                          avatar: Icon(
                            Icons.article_rounded,
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
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (authorSource.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Author / Source',
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
                    authorSource,
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
                    'Focus Skills / Tags',
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
                    'Story File',
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
              if (audioUrl.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Audio File',
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
                    audioUrl,
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
              if (pdfUrl.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'PDF File',
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
                    pdfUrl,
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
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _openStory(story),
                          icon: const Icon(Icons.ondemand_video_rounded),
                          label: const Text('Open'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _openAudio(story),
                          icon: const Icon(Icons.headphones_rounded),
                          label: const Text('Audio'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _openPdf(story),
                          icon: const Icon(Icons.picture_as_pdf_rounded),
                          label: const Text('PDF'),
                        ),
                      ],
                    ),
                  ),
                  if (canEdit)
                    PopupMenuButton<String>(
                      tooltip: 'More options',
                      onSelected: (value) => _handleStoryMenuAction(
                        action: value,
                        storyId: storyId,
                        story: story,
                        knownTags: knownTags,
                      ),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.edit_rounded),
                            title: Text('Edit'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'duplicate',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.copy_rounded),
                            title: Text('Duplicate'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'archive',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              status == 'archived'
                                  ? Icons.unarchive_rounded
                                  : Icons.archive_rounded,
                            ),
                            title: Text(
                              status == 'archived' ? 'Restore' : 'Archive',
                            ),
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.delete_rounded),
                            title: Text('Delete'),
                          ),
                        ),
                      ],
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest.withValues(
                            alpha: 0.55,
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(Icons.more_horiz_rounded),
                      ),
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
      final story = entry.value;

      final name = (story['name'] ?? '').toString().toLowerCase().trim();
      final description = (story['description'] ?? '')
          .toString()
          .toLowerCase()
          .trim();
      final genre = (story['genre'] ?? '').toString().toLowerCase().trim();
      final level = (story['level'] ?? '').toString().toLowerCase().trim();
      final scriptType = (story['scriptType'] ?? '')
          .toString()
          .toLowerCase()
          .trim();
      final authorSource = (story['authorSource'] ?? '')
          .toString()
          .toLowerCase()
          .trim();
      final status = (story['status'] ?? 'ready')
          .toString()
          .toLowerCase()
          .trim();
      final tags = _tagsFromStory(story).map((e) => e.toLowerCase()).join(' ');

      final matchesSearch =
          _searchQuery.isEmpty ||
          name.contains(_searchQuery) ||
          description.contains(_searchQuery) ||
          genre.contains(_searchQuery) ||
          level.contains(_searchQuery) ||
          scriptType.contains(_searchQuery) ||
          authorSource.contains(_searchQuery) ||
          tags.contains(_searchQuery);

      final matchesStatus =
          _statusFilter == 'all' || status == _statusFilter.toLowerCase();

      final matchesGenre =
          _genreFilter == 'all' || genre == _genreFilter.toLowerCase();

      return matchesSearch && matchesStatus && matchesGenre;
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

  int _myStoriesCount(List<MapEntry<String, Map<String, dynamic>>> items) {
    return items.where((e) => _canEditStory(e.value)).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_stories',
      hints: const [
        TeacherTourHint(
          title: 'Stories manager',
          line: 'Create, search, and organize story content for your learners.',
        ),
        TeacherTourHint(
          title: 'Add story',
          line: 'Use the Add Story button to publish a new story item.',
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stories'),
        actions: [
          const SizedBox.shrink(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving
            ? null
            : () => _showStoryForm(knownTags: const <String>[]),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Story'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _storiesRef.onValue,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              snap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final value = snap.data?.snapshot.value;
          final knownTags = _extractAllKnownTags(value);
          final genres = _extractAllGenres(value);

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
                        Icons.menu_book_rounded,
                        size: 48,
                        color: cs.primary,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'No stories added yet.',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap "Add Story" to create the first story.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _saving
                            ? null
                            : () => _showStoryForm(knownTags: knownTags),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add Story'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          final raw = Map<dynamic, dynamic>.from(value);
          final items = raw.entries.map((entry) {
            final storyId = entry.key.toString();
            final storyValue = entry.value;

            final story = storyValue is Map
                ? Map<String, dynamic>.from(storyValue)
                : <String, dynamic>{};

            return MapEntry(storyId, story);
          }).toList();

          final visibleItems = _applyFiltersAndSort(items: items);

          return Column(
            children: [
              _buildCompactToolbar(genres),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total stories: ${visibleItems.length} • My stories: ${_myStoriesCount(items)}',
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
                    await _storiesRef.get();
                  },
                  child: visibleItems.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 40, 16, 100),
                          children: [
                            Center(
                              child: Text(
                                'No stories match your filters.',
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
                            return _buildStoryCard(
                              storyId: item.key,
                              story: item.value,
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
