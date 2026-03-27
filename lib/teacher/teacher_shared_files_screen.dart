import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/backend_api.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';

class TeacherSharedFilesScreen extends StatefulWidget {
  const TeacherSharedFilesScreen({super.key});

  @override
  State<TeacherSharedFilesScreen> createState() =>
      _TeacherSharedFilesScreenState();
}

class _TeacherSharedFilesScreenState extends State<TeacherSharedFilesScreen> {
  static const String _serverRoot = 'shared_files';
  static const String _legacyServerRoot = 'shared';
  static const String _coursesRoot = 'courses';
  static const String _uploadUrl =
      'https://www.yourbridgeschool.com/app/secure/upload_file_secure.php';
  static const String _deleteUrl =
      'https://www.yourbridgeschool.com/app/secure/delete_file_secure.php';
  static const String _createFolderUrl =
      'https://www.yourbridgeschool.com/app/secure/create_folder_secure.php';

  static const Set<String> _allowedDocExt = {
    'pdf',
    'html',
    'htm',
    'doc',
    'docx',
    'txt',
    'rtf',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'csv',
    'md',
    'json',
    'xml',
  };

  final DatabaseReference _sharedRef = FirebaseDatabase.instance.ref(
    'shared_files',
  );

  bool _uploading = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _teacherFilterUid = 'all';
  final Set<String> _downloadingIds = <String>{};

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<String> _displayName() async {
    if (_uid.isEmpty) return 'Teacher';
    try {
      final snap = await FirebaseDatabase.instance.ref('users/$_uid').get();
      if (snap.value is! Map) return 'Teacher';
      final m = Map<String, dynamic>.from(snap.value as Map);
      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();
      final full = '$first $last'.trim();
      return full.isEmpty ? 'Teacher' : full;
    } catch (_) {
      return 'Teacher';
    }
  }

  bool _isInvalidRootError(Object e) {
    final lower = e.toString().toLowerCase();
    return lower.contains('invalid root') ||
        lower.contains('unknown root') ||
        lower.contains('root not allowed');
  }

  Future<void> _ensureSharedRoot(String root) async {
    final uri = await BackendApi.withAuthQuery(Uri.parse(_createFolderUrl));
    final headers = await BackendApi.authHeaders();
    final authFields = await BackendApi.authFormFields();

    final r = await http.post(
      uri,
      headers: headers,
      body: {'root': root, 'parent': '', 'folder': 'teachers', ...authFields},
    );

    final raw = r.body.trim();
    if (!raw.startsWith('{')) return;
    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) return;
    if (data['success'] == true) return;
    final msg = (data['message'] ?? '').toString().trim().toLowerCase();
    if (msg.contains('already exists')) return;
    if (msg.isNotEmpty) throw Exception(msg);
  }

  String _safeFolderName(String input) {
    final clean = input.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\-_.]+'),
      '-',
    );
    return clean.isEmpty ? 'file' : clean;
  }

  String _pathForRoot({required String root, required String folderName}) {
    if (root == _coursesRoot) {
      return 'shared_files/teachers/$_uid/$folderName';
    }
    return 'teachers/$_uid/$folderName';
  }

  Future<String> _uploadSelectedFile({
    required PlatformFile picked,
    required String folderName,
    required String root,
  }) async {
    final uploadUri = await BackendApi.withAuthQuery(Uri.parse(_uploadUrl));
    final req = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(req);
    req.fields['root'] = root;
    req.fields['path'] = _pathForRoot(root: root, folderName: folderName);

    if (picked.path != null && picked.path!.isNotEmpty) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          picked.path!,
          filename: picked.name,
        ),
      );
    } else {
      final Uint8List? bytes = picked.bytes;
      if (bytes == null) throw Exception('Could not read selected file.');
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: picked.name),
      );
    }

    final streamed = await req.send().timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(
      streamed,
    ).timeout(const Duration(seconds: 120));
    final raw = response.body.trim();
    if (!raw.startsWith('{')) {
      final snippet = raw.length > 180 ? '${raw.substring(0, 180)}...' : raw;
      throw Exception('Upload failed (HTTP ${response.statusCode}): $snippet');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid upload response.');
    }
    if (data['success'] != true) {
      final message = (data['message'] ?? 'Upload failed').toString();
      throw Exception('Upload failed: $message');
    }

    final url = (data['url'] ?? '').toString().trim();
    if (url.isEmpty) throw Exception('Upload succeeded without URL.');
    return url;
  }

  String _extOf(String name) {
    final idx = name.lastIndexOf('.');
    if (idx < 0 || idx >= name.length - 1) return '';
    return name.substring(idx + 1).toLowerCase().trim();
  }

  Future<void> _pickAndUpload() async {
    if (_uid.isEmpty || _uploading) return;

    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Upload Shared File'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Title (optional)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Choose File'),
            ),
          ],
        );
      },
    );

    if (proceed != true) return;
    if (descCtrl.text.trim().isEmpty) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Description is required for each shared file.',
        type: AppToastType.error,
      );
      return;
    }

    try {
      setState(() => _uploading = true);
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
        type: FileType.custom,
        allowedExtensions: _allowedDocExt.toList()..sort(),
      );

      if (result == null || result.files.isEmpty) {
        if (!mounted) return;
        AppToast.show(
          context,
          'Upload was cancelled.',
          type: AppToastType.info,
        );
        return;
      }
      final picked = result.files.single;
      final ext = _extOf(picked.name);
      if (!_allowedDocExt.contains(ext)) {
        throw Exception('Only document files are allowed.');
      }

      final folderName = _safeFolderName(
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      String? url;
      Object? lastUploadError;
      String? chosenRoot;
      final rootsToTry = <String>{
        _serverRoot,
        _legacyServerRoot,
        _coursesRoot,
      }.toList();

      for (final root in rootsToTry) {
        try {
          try {
            if (root != _coursesRoot) {
              await _ensureSharedRoot(root);
            }
          } catch (e) {
            if (!_isInvalidRootError(e)) rethrow;
          }

          url = await _uploadSelectedFile(
            picked: picked,
            folderName: folderName,
            root: root,
          );
          chosenRoot = root;
          break;
        } catch (e) {
          lastUploadError = e;
          if (_isInvalidRootError(e)) {
            continue;
          }
          rethrow;
        }
      }

      if (url == null || url.trim().isEmpty) {
        if (lastUploadError != null) {
          throw Exception(lastUploadError.toString());
        }
        throw Exception('Upload failed: invalid root.');
      }
      final selectedRoot = chosenRoot ?? _serverRoot;
      final selectedPath = _pathForRoot(
        root: selectedRoot,
        folderName: folderName,
      );
      final ownerName = await _displayName();
      final id =
          _sharedRef.push().key ??
          DateTime.now().millisecondsSinceEpoch.toString();

      await _sharedRef.child(id).set({
        'id': id,
        'title': titleCtrl.text.trim(),
        'description': descCtrl.text.trim(),
        'name': picked.name,
        'ext': ext,
        'url': url,
        'serverRoot': selectedRoot,
        'serverPath': selectedPath,
        'ownerUid': _uid,
        'ownerName': ownerName,
        'createdAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      AppToast.show(
        context,
        'File uploaded successfully.',
        type: AppToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(
          e,
          fallback:
              'Something unexpected happened while sending the file. Please try again.',
        ),
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String _relativeSharedPathFromUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return '';
    try {
      final uri = Uri.parse(trimmed);
      final parts = uri.pathSegments;
      final idx = parts.indexOf('shared_files');
      if (idx >= 0 && idx + 1 < parts.length) {
        return parts.sublist(idx + 1).join('/');
      }
      final legacyIdx = parts.indexOf('shared');
      if (legacyIdx < 0 || legacyIdx + 1 >= parts.length) return '';
      return parts.sublist(legacyIdx + 1).join('/');
    } catch (_) {
      return '';
    }
  }

  ({String root, String path})? _deleteTargetFromUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;
    try {
      final uri = Uri.parse(trimmed);
      final parts = uri.pathSegments;

      final coursesIdx = parts.indexOf('courses');
      if (coursesIdx >= 0 && coursesIdx + 2 < parts.length) {
        if (parts[coursesIdx + 1] == 'shared_files') {
          final path = parts.sublist(coursesIdx + 1).join('/');
          return (root: _coursesRoot, path: path);
        }
      }

      final sharedFilesIdx = parts.indexOf('shared_files');
      if (sharedFilesIdx >= 0 && sharedFilesIdx + 1 < parts.length) {
        final path = parts.sublist(sharedFilesIdx + 1).join('/');
        return (root: _serverRoot, path: path);
      }

      final sharedIdx = parts.indexOf('shared');
      if (sharedIdx >= 0 && sharedIdx + 1 < parts.length) {
        final path = parts.sublist(sharedIdx + 1).join('/');
        return (root: _legacyServerRoot, path: path);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> _deleteOwn(Map<String, dynamic> item) async {
    final ownerUid = (item['ownerUid'] ?? '').toString().trim();
    if (ownerUid != _uid) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete file?'),
        content: const Text('This action will remove your shared file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final relPath = _relativeSharedPathFromUrl(
        (item['url'] ?? '').toString(),
      );
      final storedRoot = (item['serverRoot'] ?? '').toString().trim();
      final storedPath = (item['serverPath'] ?? '').toString().trim();
      final inferred = _deleteTargetFromUrl((item['url'] ?? '').toString());
      final deleteRoot = storedRoot.isNotEmpty
          ? storedRoot
          : (inferred?.root ?? _serverRoot);
      final deletePath = storedPath.isNotEmpty
          ? storedPath
          : (inferred?.path ?? relPath);

      if (deletePath.isNotEmpty) {
        final deleteUri = await BackendApi.withAuthQuery(Uri.parse(_deleteUrl));
        final headers = await BackendApi.authHeaders();
        final authFields = await BackendApi.authFormFields();
        await http
            .post(
              deleteUri,
              headers: headers,
              body: {'root': deleteRoot, 'path': deletePath, ...authFields},
            )
            .timeout(const Duration(seconds: 60));
      }
      final id = (item['id'] ?? '').toString().trim();
      if (id.isNotEmpty) {
        await _sharedRef.child(id).remove();
      }
      if (!mounted) return;
      AppToast.show(context, 'File deleted.', type: AppToastType.success);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, toHumanError(e), type: AppToastType.error);
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _fileNameFromUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return 'downloaded_file';
    try {
      final uri = Uri.parse(trimmed);
      if (uri.pathSegments.isEmpty) return 'downloaded_file';
      return Uri.decodeComponent(uri.pathSegments.last);
    } catch (_) {
      return 'downloaded_file';
    }
  }

  String _sanitizeFileName(String input) {
    final name = input.trim();
    if (name.isEmpty) return 'downloaded_file';
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return cleaned.isEmpty ? 'downloaded_file' : cleaned;
  }

  int _searchScore({
    required String query,
    required String title,
    required String description,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return 1;

    final t = title.toLowerCase();
    final d = description.toLowerCase();
    final all = '$t $d';

    if (t.startsWith(q)) return 320;
    if (t.contains(q)) return 260;
    if (d.contains(q)) return 190;
    if (all.startsWith(q)) return 170;

    var score = 0;
    final words = q.split(RegExp(r'\s+')).where((e) => e.length > 1);
    for (final w in words) {
      if (t.contains(w)) {
        score += 75;
      } else if (d.contains(w)) {
        score += 40;
      }
    }
    if (score > 0) return score;

    final compactQ = q.replaceAll(' ', '');
    final compactAll = all.replaceAll(' ', '');
    if (compactQ.isNotEmpty && compactAll.contains(compactQ)) return 120;

    return 0;
  }

  Future<void> _downloadFile(Map<String, dynamic> item) async {
    final id = (item['id'] ?? '').toString().trim();
    final url = (item['url'] ?? '').toString().trim();
    if (id.isEmpty || url.isEmpty) return;
    if (_downloadingIds.contains(id)) return;

    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (!mounted) return;
      AppToast.show(context, 'Invalid file URL.', type: AppToastType.error);
      return;
    }

    setState(() => _downloadingIds.add(id));
    try {
      if (kIsWeb) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }

      final r = await http.get(uri).timeout(const Duration(minutes: 2));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw Exception('HTTP ${r.statusCode}');
      }

      final docDir = await getApplicationDocumentsDirectory();
      final targetDir = Directory('${docDir.path}/shared_downloads');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final itemName = (item['name'] ?? '').toString().trim();
      final guessed = itemName.isNotEmpty ? itemName : _fileNameFromUrl(url);
      final safeName = _sanitizeFileName(guessed);
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_$safeName';
      final out = File('${targetDir.path}/$fileName');
      await out.writeAsBytes(r.bodyBytes, flush: true);

      if (!mounted) return;
      AppToast.show(
        context,
        'Downloaded to app storage: $safeName',
        type: AppToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, toHumanError(e), type: AppToastType.error);
    } finally {
      if (mounted) {
        setState(() => _downloadingIds.remove(id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_shared_files',
      hints: const [
        TeacherTourHint(
          title: 'Shared documents',
          line: 'Upload and manage shared document files for all teachers.',
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared'),
        actions: [
          IconButton(
            tooltip: 'Instructions',
            onPressed: () => ScreenHelpGuide.show(
              context,
              role: GuideRole.teacher,
              screenId: 'teacher_shared_files',
              screenTitle: 'Shared Files',
            ),
            icon: const Icon(Icons.help_outline_rounded),
          ),
          IconButton(
            tooltip: 'Upload document',
            onPressed: _uploading ? null : _pickAndUpload,
            icon: _uploading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file_rounded),
          ),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _sharedRef.onValue,
        builder: (context, snap) {
          final raw = snap.data?.snapshot.value;
          final items = <Map<String, dynamic>>[];
          if (raw is Map) {
            final m = Map<dynamic, dynamic>.from(raw);
            for (final e in m.entries) {
              if (e.value is! Map) continue;
              final item = Map<String, dynamic>.from(e.value as Map);
              item['id'] = item['id'] ?? e.key.toString();
              items.add(item);
            }
          }
          items.sort((a, b) {
            final aa = (a['createdAt'] as num?)?.toInt() ?? 0;
            final bb = (b['createdAt'] as num?)?.toInt() ?? 0;
            return bb.compareTo(aa);
          });

          final teacherNamesByUid = <String, String>{};
          for (final item in items) {
            final uid = (item['ownerUid'] ?? '').toString().trim();
            if (uid.isEmpty) continue;
            final name = (item['ownerName'] ?? '').toString().trim();
            teacherNamesByUid[uid] = name.isEmpty ? 'Teacher' : name;
          }

          final teacherFilters =
              <MapEntry<String, String>>[
                const MapEntry('all', 'All Teachers'),
                ...teacherNamesByUid.entries,
              ]..sort((a, b) {
                if (a.key == 'all') return -1;
                if (b.key == 'all') return 1;
                return a.value.toLowerCase().compareTo(b.value.toLowerCase());
              });

          final activeTeacherFilter =
              teacherFilters.any((e) => e.key == _teacherFilterUid)
              ? _teacherFilterUid
              : 'all';

          final filtered = <Map<String, dynamic>>[];
          for (final item in items) {
            final ownerUid = (item['ownerUid'] ?? '').toString().trim();
            if (activeTeacherFilter != 'all' &&
                ownerUid != activeTeacherFilter) {
              continue;
            }

            final name = (item['name'] ?? '').toString().trim();
            final title = (item['title'] ?? '').toString().trim();
            final description = (item['description'] ?? '').toString().trim();
            final shownTitle = title.isEmpty ? name : title;
            final score = _searchScore(
              query: _searchQuery,
              title: shownTitle,
              description: description,
            );
            if (_searchQuery.trim().isNotEmpty && score <= 0) {
              continue;
            }

            final row = Map<String, dynamic>.from(item);
            row['_score'] = score;
            filtered.add(row);
          }

          filtered.sort((a, b) {
            final sa = (a['_score'] as num?)?.toInt() ?? 0;
            final sb = (b['_score'] as num?)?.toInt() ?? 0;
            if (sa != sb) return sb.compareTo(sa);
            final aa = (a['createdAt'] as num?)?.toInt() ?? 0;
            final bb = (b['createdAt'] as num?)?.toInt() ?? 0;
            return bb.compareTo(aa);
          });

          if (items.isEmpty) {
            return const Center(child: Text('No shared files yet.'));
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (v) {
                          setState(() => _searchQuery = v);
                        },
                        decoration: InputDecoration(
                          hintText: 'Search title or description',
                          isDense: true,
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _searchQuery.trim().isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: activeTeacherFilter,
                        borderRadius: BorderRadius.circular(12),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _teacherFilterUid = v);
                        },
                        items: teacherFilters
                            .map(
                              (e) => DropdownMenuItem<String>(
                                value: e.key,
                                child: Text(e.value),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(
                        child: Text('No files match your search/filter.'),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final item = filtered[i];
                          final name = (item['name'] ?? 'Document').toString();
                          final title = (item['title'] ?? '').toString().trim();
                          final description = (item['description'] ?? '')
                              .toString()
                              .trim();
                          final ownerUid = (item['ownerUid'] ?? '')
                              .toString()
                              .trim();
                          final ownerName = (item['ownerName'] ?? '')
                              .toString()
                              .trim();
                          final url = (item['url'] ?? '').toString().trim();
                          final id = (item['id'] ?? '').toString().trim();
                          final downloading =
                              id.isNotEmpty && _downloadingIds.contains(id);

                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title.isEmpty ? name : title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  if (description.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(description),
                                  ],
                                  const SizedBox(height: 6),
                                  Text(
                                    ownerName.isEmpty
                                        ? 'Uploaded by: Teacher'
                                        : 'Uploaded by: $ownerName',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black54,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: url.isEmpty
                                            ? null
                                            : () => _openUrl(url),
                                        icon: const Icon(
                                          Icons.open_in_new_rounded,
                                        ),
                                        label: const Text('Open'),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: (url.isEmpty || downloading)
                                            ? null
                                            : () => _downloadFile(item),
                                        icon: downloading
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.download_rounded,
                                              ),
                                        label: Text(
                                          downloading
                                              ? 'Downloading...'
                                              : 'Download',
                                        ),
                                      ),
                                      const Spacer(),
                                      if (ownerUid == _uid)
                                        IconButton(
                                          tooltip: 'Delete my file',
                                          onPressed: () => _deleteOwn(item),
                                          icon: const Icon(
                                            Icons.delete_rounded,
                                            color: Colors.red,
                                          ),
                                        ),
                                    ],
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
        },
      ),
    );
  }
}
