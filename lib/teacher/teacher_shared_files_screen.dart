import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/backend_api.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
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

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

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

          if (items.isEmpty) {
            return const Center(child: Text('No shared files yet.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final item = items[i];
              final name = (item['name'] ?? 'Document').toString();
              final title = (item['title'] ?? '').toString().trim();
              final description = (item['description'] ?? '').toString().trim();
              final ownerUid = (item['ownerUid'] ?? '').toString().trim();
              final ownerName = (item['ownerName'] ?? '').toString().trim();
              final url = (item['url'] ?? '').toString().trim();

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.isEmpty ? name : title,
                        style: const TextStyle(fontWeight: FontWeight.w900),
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
                            onPressed: url.isEmpty ? null : () => _openUrl(url),
                            icon: const Icon(Icons.open_in_new_rounded),
                            label: const Text('Open'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: url.isEmpty ? null : () => _openUrl(url),
                            icon: const Icon(Icons.download_rounded),
                            label: const Text('Download'),
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
          );
        },
      ),
    );
  }
}
