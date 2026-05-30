import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../services/backend_api.dart';
import '../services/storage_existence.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/media_download.dart';

String _coursesRelativePathFromUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';

  try {
    final uri = Uri.parse(trimmed);
    final parts = uri.pathSegments;
    final coursesIndex = parts.indexOf('courses');
    if (coursesIndex < 0 || coursesIndex + 1 >= parts.length) return '';
    return parts.sublist(coursesIndex + 1).join('/');
  } catch (_) {
    return '';
  }
}

Future<void> _deleteUploadedCoursesAsset(String fileUrl) async {
  final relPath = _coursesRelativePathFromUrl(fileUrl);
  if (relPath.isEmpty) return;

  final uri = await BackendApi.withAuthQuery(
    BackendApi.uri('delete_file_secure.php'),
  );
  final headers = await BackendApi.authHeaders();
  final authFields = await BackendApi.authFormFields();

  final r = await http.post(
    uri,
    headers: headers,
    body: {'root': 'courses', 'path': relPath, ...authFields},
  );

  final raw = r.body.trim();
  if (!raw.startsWith('{')) {
    throw Exception('Delete endpoint did not return JSON.');
  }

  final data = jsonDecode(raw);
  if (data is! Map<String, dynamic>) {
    throw Exception('Invalid delete response.');
  }

  if (data['success'] == true) return;

  final msg = (data['message'] ?? 'Delete failed').toString();
  if (msg.toLowerCase().contains('not found')) return;
  throw Exception(msg);
}

Future<http.StreamedResponse> _sendMultipartWithProgress({
  required http.MultipartRequest request,
  required void Function(double progress) onProgress,
}) async {
  final totalBytes = request.contentLength;
  var sentBytes = 0;

  final stream = request.finalize().transform(
    StreamTransformer.fromHandlers(
      handleData: (chunk, sink) {
        sentBytes += chunk.length;
        if (totalBytes > 0) {
          final p = (sentBytes / totalBytes).clamp(0.0, 1.0);
          onProgress(p);
        }
        sink.add(chunk);
      },
    ),
  );

  final streamedRequest = http.StreamedRequest(request.method, request.url)
    ..headers.addAll(request.headers)
    ..contentLength = totalBytes;

  final pipeDone = Completer<void>();
  stream.listen(
    (data) => streamedRequest.sink.add(data as List<int>),
    onError: (e, st) {
      if (!pipeDone.isCompleted) pipeDone.completeError(e, st);
      streamedRequest.sink.close();
    },
    onDone: () {
      if (!pipeDone.isCompleted) pipeDone.complete();
      streamedRequest.sink.close();
    },
    cancelOnError: true,
  );

  final client = http.Client();
  try {
    final responseFuture = client.send(streamedRequest);
    await pipeDone.future;
    final response = await responseFuture;
    onProgress(1.0);
    return response;
  } finally {
    client.close();
  }
}

class _GalleryCleanupStats {
  const _GalleryCleanupStats({
    required this.stage,
    required this.found,
    required this.checked,
    required this.missing,
    required this.deleted,
    required this.unknown,
  });

  const _GalleryCleanupStats.initial()
    : stage = 'Preparing cleanup...',
      found = 0,
      checked = 0,
      missing = 0,
      deleted = 0,
      unknown = 0;

  final String stage;
  final int found;
  final int checked;
  final int missing;
  final int deleted;
  final int unknown;

  _GalleryCleanupStats copyWith({
    String? stage,
    int? found,
    int? checked,
    int? missing,
    int? deleted,
    int? unknown,
  }) {
    return _GalleryCleanupStats(
      stage: stage ?? this.stage,
      found: found ?? this.found,
      checked: checked ?? this.checked,
      missing: missing ?? this.missing,
      deleted: deleted ?? this.deleted,
      unknown: unknown ?? this.unknown,
    );
  }
}

typedef _CleanupProgressCallback =
    void Function({
      String? stage,
      int foundDelta,
      int checkedDelta,
      int missingDelta,
      int deletedDelta,
      int unknownDelta,
    });

class AdminPublicGalleryScreen extends StatefulWidget {
  const AdminPublicGalleryScreen({super.key});

  @override
  State<AdminPublicGalleryScreen> createState() =>
      _AdminPublicGalleryScreenState();
}

class _AdminPublicGalleryScreenState extends State<AdminPublicGalleryScreen>
    with SingleTickerProviderStateMixin {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  late final TabController _tab;
  late final Stream<DatabaseEvent> _publicGalleryStream;
  late final Stream<DatabaseEvent> _usersStream;
  late final Stream<DatabaseEvent> _learnerGalleryStream;
  late final Stream<DatabaseEvent> _teacherProfilesStream;
  dynamic _publicGalleryCache;
  dynamic _usersCache;
  dynamic _learnerGalleryCache;
  dynamic _teacherProfilesCache;
  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
  double? _uploadPhotoProgress;
  double? _uploadVideoProgress;
  int _uploadPhotoBatchTotal = 0;
  int _uploadPhotoBatchCurrent = 0;
  int _uploadVideoBatchTotal = 0;
  int _uploadVideoBatchCurrent = 0;
  String? _error;
  String? _ok;

  String _adminName = 'Admin';
  String _learnerSearch = '';
  String _teacherSearch = '';
  bool _onlyEmptyLearnerGalleries = false;
  bool _publicVideoCleanupRunning = false;
  final Map<String, String> _publicVideoCheckedUrls = <String, String>{};
  bool _teacherMediaCleanupRunning = false;
  final Map<String, String> _teacherMediaCheckedSignatures = <String, String>{};
  bool _globalCleanupRunning = false;
  bool _bulkDeleting = false;
  bool _publicBulkMode = false;
  final Set<String> _selectedPublicIds = <String>{};
  bool _learnerBulkMode = false;
  final Set<String> _selectedLearnerUids = <String>{};
  bool _teacherBulkMode = false;
  final Set<String> _selectedTeacherUids = <String>{};
  int _activeTabIndex = 0;
  List<Map<String, dynamic>> _visiblePublicItems =
      const <Map<String, dynamic>>[];
  List<_AdminLearnerLite> _visibleLearners = const <_AdminLearnerLite>[];
  List<_AdminTeacherProfileLite> _visibleTeachers =
      const <_AdminTeacherProfileLite>[];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() {
      if (!mounted) return;
      if (_activeTabIndex == _tab.index) return;
      setState(() => _activeTabIndex = _tab.index);
    });

    _publicGalleryStream = _galleryRef().onValue.asBroadcastStream();
    _usersStream = _db.child('users').onValue.asBroadcastStream();
    _learnerGalleryStream = _db
        .child('learner_gallery')
        .onValue
        .asBroadcastStream();
    _teacherProfilesStream = _db
        .child('website/teachers')
        .onValue
        .asBroadcastStream();

    _loadAdminName();
  }

  bool get _isBulkModeActive {
    if (_activeTabIndex == 0) return _publicBulkMode;
    if (_activeTabIndex == 1) return _learnerBulkMode;
    return _teacherBulkMode;
  }

  int get _selectedCount {
    if (_activeTabIndex == 0) return _selectedPublicIds.length;
    if (_activeTabIndex == 1) return _selectedLearnerUids.length;
    return _selectedTeacherUids.length;
  }

  void _toggleBulkModeForActiveTab() {
    if (_bulkDeleting) return;
    setState(() {
      if (_activeTabIndex == 0) {
        _publicBulkMode = !_publicBulkMode;
        if (!_publicBulkMode) _selectedPublicIds.clear();
      } else if (_activeTabIndex == 1) {
        _learnerBulkMode = !_learnerBulkMode;
        if (!_learnerBulkMode) _selectedLearnerUids.clear();
      } else {
        _teacherBulkMode = !_teacherBulkMode;
        if (!_teacherBulkMode) _selectedTeacherUids.clear();
      }
    });
  }

  void _selectAllForActiveTab() {
    if (_bulkDeleting) return;
    setState(() {
      if (_activeTabIndex == 0) {
        _selectedPublicIds
          ..clear()
          ..addAll(
            _visiblePublicItems
                .map((e) => (e['id'] ?? '').toString().trim())
                .where((id) => id.isNotEmpty),
          );
      } else if (_activeTabIndex == 1) {
        _selectedLearnerUids
          ..clear()
          ..addAll(_visibleLearners.map((e) => e.uid.trim()));
      } else {
        _selectedTeacherUids
          ..clear()
          ..addAll(_visibleTeachers.map((e) => e.uid.trim()));
      }
    });
  }

  void _clearSelectionForActiveTab() {
    if (_bulkDeleting) return;
    setState(() {
      if (_activeTabIndex == 0) {
        _selectedPublicIds.clear();
      } else if (_activeTabIndex == 1) {
        _selectedLearnerUids.clear();
      } else {
        _selectedTeacherUids.clear();
      }
    });
  }

  Future<void> _deleteSelectedForActiveTab() async {
    if (_bulkDeleting) return;
    if (_activeTabIndex == 0) {
      await _bulkDeletePublicItems(_visiblePublicItems);
      return;
    }
    if (_activeTabIndex == 1) {
      await _bulkDeleteLearnerGalleries(_visibleLearners);
      return;
    }
    await _bulkDeleteTeacherMedia(_visibleTeachers);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadAdminName() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final snap = await _db.child('users/$uid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();

        if (!mounted) return;
        setState(() {
          _adminName = full.isNotEmpty ? full : 'Admin';
        });
      }
    } catch (_) {}
  }

  String _adminAppId(String uid) => 'admin_public_gallery_$uid';

  DatabaseReference _galleryRef() => _db.child('public_gallery_teasers');

  Future<Map<String, String>> _uploadPlatformFile(
    PlatformFile file, {
    required void Function(double progress) onProgress,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);

    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['app_id'] = _adminAppId(user.uid);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file bytes.');
      }

      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected file path.');
      }

      request.files.add(
        await http.MultipartFile.fromPath('file', path, filename: file.name),
      );
    }

    final streamedResponse = await _sendMultipartWithProgress(
      request: request,
      onProgress: onProgress,
    );
    final responseBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      throw Exception(
        'Upload failed (${streamedResponse.statusCode}): $responseBody',
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['success'] != true) {
      throw Exception(
        decoded is Map
            ? (decoded['message'] ?? 'Upload failed')
            : 'Upload failed',
      );
    }

    final url = (decoded['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('Upload succeeded but no URL returned.');
    }

    final thumbnailUrl = (decoded['thumbnail_url'] ?? '').toString().trim();

    return {'url': url, 'thumbnailUrl': thumbnailUrl};
  }

  Future<void> _saveGalleryItem({
    required String type,
    required String url,
    String thumbnailUrl = '',
  }) async {
    final adminUid = FirebaseAuth.instance.currentUser?.uid;
    if (adminUid == null || adminUid.isEmpty) {
      throw Exception('Not logged in.');
    }

    final newRef = _galleryRef().push();
    final itemId = newRef.key;

    await newRef.set({
      'type': type,
      'url': url,
      'thumbnailUrl': thumbnailUrl,
      'uploadedByUid': adminUid,
      'uploadedByName': _adminName,
      'createdAt': ServerValue.timestamp,
    });

    await _mirrorWebsitePublicGalleryItem(
      adminUid: adminUid,
      itemId: itemId,
      type: type,
      url: url,
      thumbnailUrl: thumbnailUrl,
    );
  }

  Future<void> _mirrorWebsitePublicGalleryItem({
    required String adminUid,
    required String? itemId,
    required String type,
    required String url,
    String thumbnailUrl = '',
  }) async {
    final cleanItemId = (itemId ?? '').trim();
    final cleanUrl = url.trim();
    if (cleanItemId.isEmpty || cleanUrl.isEmpty) return;

    try {
      await _db
          .child('website/admin/$adminUid/public_gallery/$cleanItemId')
          .set({
            'type': type,
            'url': cleanUrl,
            'thumbnailUrl': thumbnailUrl,
            'uploadedByUid': adminUid,
            'uploadedByName': _adminName,
            'createdAt': ServerValue.timestamp,
          });
    } catch (e) {
      debugPrint('Admin website public gallery mirror failed: $e');
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
        _uploadingPhoto = true;
        _uploadingVideo = false;
        _uploadPhotoProgress = 0;
        _uploadPhotoBatchCurrent = 0;
        _uploadPhotoBatchTotal = 0;
        _error = null;
        _ok = null;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: kIsWeb,
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );

      if (result == null || result.files.isEmpty) return;

      final files = result.files;
      var uploadedCount = 0;
      final failedFiles = <String>[];

      if (mounted) {
        setState(() {
          _uploadPhotoBatchCurrent = 0;
          _uploadPhotoBatchTotal = files.length;
        });
      }

      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        if (mounted) {
          setState(() {
            _uploadPhotoBatchCurrent = i + 1;
            _uploadPhotoProgress = 0;
          });
        }

        try {
          final result = await _uploadPlatformFile(
            file,
            onProgress: (p) {
              if (!mounted) return;
              setState(() => _uploadPhotoProgress = p);
            },
          );

          await _saveGalleryItem(type: 'photo', url: result['url']!);
          uploadedCount += 1;
        } catch (e) {
          failedFiles.add(file.name);
          debugPrint('Public gallery photo upload failed for ${file.name}: $e');
        }
      }

      if (!mounted) return;
      setState(() {
        if (uploadedCount > 0) {
          final uploadedLabel =
              '$uploadedCount photo${uploadedCount == 1 ? '' : 's'} uploaded';
          _ok = failedFiles.isEmpty
              ? uploadedLabel
              : '$uploadedLabel. Failed: ${failedFiles.join(', ')}';
          _error = null;
        } else {
          _ok = null;
          _error = failedFiles.isEmpty
              ? 'Could not upload photos.'
              : 'Could not upload photos. Failed: ${failedFiles.join(', ')}';
        }
      });
      if (failedFiles.isNotEmpty) {
        await _showUploadSummaryDialog(
          mediaLabel: 'Photos',
          uploadedCount: uploadedCount,
          failedFiles: failedFiles,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not upload photo.');
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploadingPhoto = false;
          _uploadPhotoProgress = null;
          _uploadPhotoBatchCurrent = 0;
          _uploadPhotoBatchTotal = 0;
        });
      }
    }
  }

  Future<void> _pickAndUploadVideo() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
        _uploadingVideo = true;
        _uploadingPhoto = false;
        _uploadVideoProgress = 0;
        _uploadVideoBatchCurrent = 0;
        _uploadVideoBatchTotal = 0;
        _error = null;
        _ok = null;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: kIsWeb,
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'mov', 'webm', '3gp', 'ogg'],
      );

      if (result == null || result.files.isEmpty) return;

      final files = result.files;
      var uploadedCount = 0;
      final failedFiles = <String>[];

      if (mounted) {
        setState(() {
          _uploadVideoBatchCurrent = 0;
          _uploadVideoBatchTotal = files.length;
        });
      }

      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        if (mounted) {
          setState(() {
            _uploadVideoBatchCurrent = i + 1;
            _uploadVideoProgress = 0;
          });
        }

        try {
          final result = await _uploadPlatformFile(
            file,
            onProgress: (p) {
              if (!mounted) return;
              setState(() => _uploadVideoProgress = p);
            },
          );

          await _saveGalleryItem(type: 'video', url: result['url']!, thumbnailUrl: result['thumbnailUrl']!);
          uploadedCount += 1;
        } catch (e) {
          failedFiles.add(file.name);
          debugPrint('Public gallery video upload failed for ${file.name}: $e');
        }
      }

      if (!mounted) return;
      setState(() {
        if (uploadedCount > 0) {
          final uploadedLabel =
              '$uploadedCount video${uploadedCount == 1 ? '' : 's'} uploaded';
          _ok = failedFiles.isEmpty
              ? uploadedLabel
              : '$uploadedLabel. Failed: ${failedFiles.join(', ')}';
          _error = null;
        } else {
          _ok = null;
          _error = failedFiles.isEmpty
              ? 'Could not upload videos.'
              : 'Could not upload videos. Failed: ${failedFiles.join(', ')}';
        }
      });
      if (failedFiles.isNotEmpty) {
        await _showUploadSummaryDialog(
          mediaLabel: 'Videos',
          uploadedCount: uploadedCount,
          failedFiles: failedFiles,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not upload video.');
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploadingVideo = false;
          _uploadVideoProgress = null;
          _uploadVideoBatchCurrent = 0;
          _uploadVideoBatchTotal = 0;
        });
      }
    }
  }

  String _photoUploadLabel() {
    if (!_uploadingPhoto) return 'Upload Photos';
    final progress = ((_uploadPhotoProgress ?? 0) * 100).toStringAsFixed(0);
    final batchLabel = _uploadPhotoBatchTotal > 0
        ? ' $_uploadPhotoBatchCurrent/$_uploadPhotoBatchTotal'
        : '';
    return 'Uploading$batchLabel ($progress%)';
  }

  String _videoUploadLabel() {
    if (!_uploadingVideo) return 'Upload Videos';
    final progress = ((_uploadVideoProgress ?? 0) * 100).toStringAsFixed(0);
    final batchLabel = _uploadVideoBatchTotal > 0
        ? ' $_uploadVideoBatchCurrent/$_uploadVideoBatchTotal'
        : '';
    return 'Uploading$batchLabel ($progress%)';
  }

  Future<void> _showUploadSummaryDialog({
    required String mediaLabel,
    required int uploadedCount,
    required List<String> failedFiles,
  }) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$mediaLabel Upload Summary'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  uploadedCount > 0
                      ? '$uploadedCount uploaded successfully.'
                      : 'No files were uploaded successfully.',
                ),
                const SizedBox(height: 12),
                Text(
                  'Failed files (${failedFiles.length}):',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                for (final fileName in failedFiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(fileName),
                  ),
              ],
            ),
          ),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item'),
        content: const Text(
          'Do you want to remove this public teaser gallery item?',
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: actionOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  Future<void> _deleteItem(String itemId) async {
    final ok = await _confirmDelete();
    if (!ok) return;

    try {
      final snap = await _galleryRef().child(itemId).get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final url = (m['url'] ?? '').toString().trim();
        if (url.isNotEmpty) {
          await _deleteUploadedCoursesAsset(url);
        }
      }

      await _galleryRef().child(itemId).remove();
      if (!mounted) return;
      setState(() {
        _ok = 'Gallery item deleted from server and database';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not delete item.');
      });
    }
  }

  Future<bool> _confirmBulkDelete({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> _bulkDeletePublicItems(
    List<Map<String, dynamic>> allItems,
  ) async {
    final selectedItems = allItems.where((item) {
      final id = (item['id'] ?? '').toString().trim();
      return id.isNotEmpty && _selectedPublicIds.contains(id);
    }).toList();
    if (selectedItems.isEmpty) return;

    final ok = await _confirmBulkDelete(
      title: 'Delete selected public media',
      message:
          'Delete ${selectedItems.length} selected public item${selectedItems.length == 1 ? '' : 's'}? This removes from RTDB and server storage.',
    );
    if (!ok) return;

    setState(() {
      _bulkDeleting = true;
      _error = null;
    });

    var removed = 0;
    try {
      for (final item in selectedItems) {
        final itemId = (item['id'] ?? '').toString().trim();
        if (itemId.isEmpty) continue;

        final url = (item['url'] ?? '').toString().trim();
        if (url.isNotEmpty) {
          try {
            await _deleteUploadedCoursesAsset(url);
          } catch (_) {}
        }

        await _galleryRef().child(itemId).remove();
        removed++;
      }

      if (!mounted) return;
      setState(() {
        _selectedPublicIds.clear();
        _publicBulkMode = false;
        _ok = 'Deleted $removed public item${removed == 1 ? '' : 's'}.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(
          e,
          fallback: 'Could not bulk delete public items.',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _bulkDeleting = false;
        });
      }
    }
  }

  Future<void> _bulkDeleteLearnerGalleries(
    List<_AdminLearnerLite> allLearners,
  ) async {
    final selectedLearners = allLearners.where((l) {
      return l.uid.trim().isNotEmpty && _selectedLearnerUids.contains(l.uid);
    }).toList();
    if (selectedLearners.isEmpty) return;

    final ok = await _confirmBulkDelete(
      title: 'Delete selected learner galleries',
      message:
          'Delete gallery contents for ${selectedLearners.length} selected learner${selectedLearners.length == 1 ? '' : 's'}? This removes all their gallery items from RTDB and server storage.',
    );
    if (!ok) return;

    setState(() {
      _bulkDeleting = true;
      _error = null;
    });

    var removedItems = 0;
    try {
      for (final learner in selectedLearners) {
        final uid = learner.uid.trim();
        if (uid.isEmpty) continue;

        final snap = await _db.child('learner_gallery/$uid').get();
        final value = snap.value;
        if (value is Map) {
          final gallery = Map<dynamic, dynamic>.from(value);
          for (final entry in gallery.entries) {
            final raw = entry.value;
            if (raw is! Map) continue;
            final item = raw.map((k, v) => MapEntry(k.toString(), v));
            final url = (item['url'] ?? '').toString().trim();
            if (url.isNotEmpty) {
              try {
                await _deleteUploadedCoursesAsset(url);
              } catch (_) {}
            }
            removedItems++;
          }
        }

        await _db.child('learner_gallery/$uid').remove();
      }

      if (!mounted) return;
      setState(() {
        _selectedLearnerUids.clear();
        _learnerBulkMode = false;
        _ok =
            'Deleted $removedItems learner gallery item${removedItems == 1 ? '' : 's'} from selected learners.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(
          e,
          fallback: 'Could not bulk delete learner galleries.',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _bulkDeleting = false;
        });
      }
    }
  }

  Future<void> _bulkDeleteTeacherMedia(
    List<_AdminTeacherProfileLite> allTeachers,
  ) async {
    final selectedTeachers = allTeachers.where((t) {
      return t.uid.trim().isNotEmpty && _selectedTeacherUids.contains(t.uid);
    }).toList();
    if (selectedTeachers.isEmpty) return;

    final ok = await _confirmBulkDelete(
      title: 'Delete selected teacher media',
      message:
          'Delete photos and intro video for ${selectedTeachers.length} selected teacher${selectedTeachers.length == 1 ? '' : 's'}? This clears teacher media URLs from RTDB and removes files from server when possible.',
    );
    if (!ok) return;

    setState(() {
      _bulkDeleting = true;
      _error = null;
    });

    var removedFiles = 0;
    try {
      for (final teacher in selectedTeachers) {
        for (final photo in teacher.photoUrls) {
          final url = photo.trim();
          if (url.isEmpty) continue;
          try {
            await _deleteUploadedCoursesAsset(url);
          } catch (_) {}
          removedFiles++;
        }

        final videoUrl = teacher.introVideoUrl.trim();
        if (videoUrl.isNotEmpty) {
          try {
            await _deleteUploadedCoursesAsset(videoUrl);
          } catch (_) {}
          removedFiles++;
        }

        await _db.child('website/teachers/${teacher.uid}/profile').update({
          'profile_photos': <String>[],
          'profile_photo': '',
          'intro_video_url': '',
        });
      }

      if (!mounted) return;
      setState(() {
        _selectedTeacherUids.clear();
        _teacherBulkMode = false;
        _ok =
            'Cleared media for ${selectedTeachers.length} teacher${selectedTeachers.length == 1 ? '' : 's'} ($removedFiles file${removedFiles == 1 ? '' : 's'}).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(
          e,
          fallback: 'Could not bulk delete teacher media.',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _bulkDeleting = false;
        });
      }
    }
  }

  Future<StorageCheckResult> _probeMediaUrl(
    String url, {
    required String expectedType,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return StorageCheckResult.missing;
    }

    Future<http.Response> headReq() {
      return http.head(uri).timeout(const Duration(seconds: 8));
    }

    Future<http.Response> rangeReq() {
      return http
          .get(uri, headers: const {'Range': 'bytes=0-0'})
          .timeout(const Duration(seconds: 8));
    }

    http.Response response;
    try {
      response = await headReq();
      if (response.statusCode == 405 || response.statusCode == 501) {
        response = await rangeReq();
      }
    } catch (_) {
      return StorageCheckResult.unknown;
    }

    final code = response.statusCode;
    if (code == 404 || code == 410) return StorageCheckResult.missing;
    if (code == 401 || code == 403 || code >= 500) {
      return StorageCheckResult.unknown;
    }
    if (code >= 400) return StorageCheckResult.missing;

    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    final contentLength = int.tryParse(
      response.headers['content-length'] ?? '',
    );

    if (contentLength != null && contentLength == 0) {
      return StorageCheckResult.missing;
    }

    if (contentType.startsWith('text/html')) {
      return StorageCheckResult.missing;
    }

    if (expectedType == 'photo' &&
        contentType.isNotEmpty &&
        !contentType.startsWith('image/')) {
      return StorageCheckResult.missing;
    }

    if (expectedType == 'video' &&
        contentType.isNotEmpty &&
        !contentType.startsWith('video/')) {
      return StorageCheckResult.missing;
    }

    return StorageCheckResult.exists;
  }

  Future<StorageCheckResult> _checkMediaHealth(
    String url, {
    required String expectedType,
  }) async {
    final existence = await StorageExistence.checkUrlExistsOnManagedStorage(
      url,
      expect: 'file',
      allowedRoots: const {'courses'},
    );

    if (existence != StorageCheckResult.exists) return existence;

    final probe = await _probeMediaUrl(url, expectedType: expectedType);
    if (probe == StorageCheckResult.missing) return StorageCheckResult.missing;
    if (probe == StorageCheckResult.unknown) return StorageCheckResult.unknown;
    return StorageCheckResult.exists;
  }

  Future<int> _cleanupMissingPublicMedia(
    List<Map<String, dynamic>> items, {
    _CleanupProgressCallback? onProgress,
  }) async {
    if (_publicVideoCleanupRunning) return 0;

    _publicVideoCleanupRunning = true;
    var removed = 0;

    try {
      final existingIds = items
          .map((e) => (e['id'] ?? '').toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      _publicVideoCheckedUrls.removeWhere((k, _) => !existingIds.contains(k));

      for (final item in items) {
        final itemId = (item['id'] ?? '').toString().trim();
        if (itemId.isEmpty) continue;

        final type = (item['type'] ?? '').toString().trim().toLowerCase();
        if (type != 'video' && type != 'photo') continue;

        final url = (item['url'] ?? '').toString().trim();
        if (url.isEmpty) continue;

        onProgress?.call(stage: 'Public Gallery', foundDelta: 1);

        if (_publicVideoCheckedUrls[itemId] == url) continue;

        final check = await _checkMediaHealth(url, expectedType: type);
        onProgress?.call(stage: 'Public Gallery', checkedDelta: 1);

        if (check == StorageCheckResult.unknown) {
          onProgress?.call(stage: 'Public Gallery', unknownDelta: 1);
          continue;
        }

        _publicVideoCheckedUrls[itemId] = url;

        if (check == StorageCheckResult.missing) {
          onProgress?.call(stage: 'Public Gallery', missingDelta: 1);
          await _galleryRef().child(itemId).remove();
          _publicVideoCheckedUrls.remove(itemId);
          removed++;
          onProgress?.call(stage: 'Public Gallery', deletedDelta: 1);
        }
      }

      return removed;
    } finally {
      _publicVideoCleanupRunning = false;
    }
  }

  Future<int> _cleanupMissingLearnerGalleryMediaGlobal({
    _CleanupProgressCallback? onProgress,
  }) async {
    final snap = await _db.child('learner_gallery').get();
    final value = snap.value;
    if (value is! Map) return 0;

    var removed = 0;
    final learners = Map<dynamic, dynamic>.from(value);

    for (final learnerEntry in learners.entries) {
      final learnerUid = learnerEntry.key.toString().trim();
      final learnerNode = learnerEntry.value;
      if (learnerUid.isEmpty || learnerNode is! Map) continue;

      final galleryMap = Map<dynamic, dynamic>.from(learnerNode);
      for (final itemEntry in galleryMap.entries) {
        final itemId = itemEntry.key.toString().trim();
        final itemRaw = itemEntry.value;
        if (itemId.isEmpty || itemRaw is! Map) continue;

        final item = itemRaw.map((k, v) => MapEntry(k.toString(), v));
        final type = (item['type'] ?? '').toString().trim().toLowerCase();
        if (type != 'photo' && type != 'video') continue;

        final url = (item['url'] ?? '').toString().trim();
        if (url.isEmpty) continue;

        onProgress?.call(stage: 'Learner Galleries', foundDelta: 1);

        final check = await _checkMediaHealth(url, expectedType: type);
        onProgress?.call(stage: 'Learner Galleries', checkedDelta: 1);

        if (check == StorageCheckResult.unknown) {
          onProgress?.call(stage: 'Learner Galleries', unknownDelta: 1);
          continue;
        }
        if (check != StorageCheckResult.missing) continue;

        onProgress?.call(stage: 'Learner Galleries', missingDelta: 1);
        await _db.child('learner_gallery/$learnerUid/$itemId').remove();
        removed++;
        onProgress?.call(stage: 'Learner Galleries', deletedDelta: 1);
      }
    }

    return removed;
  }

  Future<void> _runGlobalGalleryCleanup() async {
    if (_globalCleanupRunning) return;

    final progress = ValueNotifier<_GalleryCleanupStats>(
      const _GalleryCleanupStats.initial(),
    );

    void bumpProgress({
      String? stage,
      int foundDelta = 0,
      int checkedDelta = 0,
      int missingDelta = 0,
      int deletedDelta = 0,
      int unknownDelta = 0,
    }) {
      final current = progress.value;
      progress.value = current.copyWith(
        stage: stage ?? current.stage,
        found: current.found + foundDelta,
        checked: current.checked + checkedDelta,
        missing: current.missing + missingDelta,
        deleted: current.deleted + deletedDelta,
        unknown: current.unknown + unknownDelta,
      );
    }

    var dialogOpen = false;

    if (mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            dialogOpen = true;
            return PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Text('Cleaning Gallery'),
                content: ValueListenableBuilder<_GalleryCleanupStats>(
                  valueListenable: progress,
                  builder: (context, s, _) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                s.stage,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('Found: ${s.found}'),
                        Text('Checked: ${s.checked}'),
                        Text('Missing: ${s.missing}'),
                        Text('Deleted: ${s.deleted}'),
                        Text('Unknown/Skipped: ${s.unknown}'),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      );
    }

    setState(() {
      _globalCleanupRunning = true;
      _ok = null;
      _error = null;
    });

    try {
      _publicVideoCheckedUrls.clear();
      _teacherMediaCheckedSignatures.clear();

      bumpProgress(stage: 'Checking Public Gallery...');
      final publicSnap = await _galleryRef().get();
      final publicItems = _itemsFromSnapshot(publicSnap.value);
      final removedPublic = await _cleanupMissingPublicMedia(
        publicItems,
        onProgress: bumpProgress,
      );

      bumpProgress(stage: 'Checking Learner Galleries...');
      final removedLearner = await _cleanupMissingLearnerGalleryMediaGlobal(
        onProgress: bumpProgress,
      );

      bumpProgress(stage: 'Checking Teacher Gallery...');
      final usersSnap = await _db.child('users').get();
      final teacherProfilesSnap = await _db.child('website/teachers').get();
      final teachers = _parseTeacherProfiles(
        usersValue: usersSnap.value,
        websiteTeachersValue: teacherProfilesSnap.value,
      );
      final cleanedTeachers = await _cleanupMissingTeacherProfileMedia(
        teachers,
        onProgress: bumpProgress,
      );

      final refreshedPublic = await _galleryRef().get();
      final refreshedLearner = await _db.child('learner_gallery').get();
      final refreshedTeachers = await _db.child('website/teachers').get();

      if (!mounted) return;
      final totalRemoved = removedPublic + removedLearner;
      setState(() {
        _publicGalleryCache = refreshedPublic.value;
        _learnerGalleryCache = refreshedLearner.value;
        _teacherProfilesCache = refreshedTeachers.value;
        _ok =
            'Cleanup done: found ${progress.value.found}, checked ${progress.value.checked}, deleted ${progress.value.deleted}. Removed $totalRemoved gallery item${totalRemoved == 1 ? '' : 's'} and updated $cleanedTeachers teacher profile${cleanedTeachers == 1 ? '' : 's'}.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Global cleanup failed.');
      });
    } finally {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      progress.dispose();

      if (mounted) {
        setState(() {
          _globalCleanupRunning = false;
        });
      }
    }
  }

  String _fmtDate(dynamic ts) {
    final ms = _toInt(ts);
    if (ms <= 0) return '-';

    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  List<Map<String, dynamic>> _itemsFromSnapshot(dynamic value) {
    if (value is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(value);
    final out = <Map<String, dynamic>>[];

    raw.forEach((key, val) {
      if (val is! Map) return;

      final m = val.map((k, vv) => MapEntry(k.toString(), vv));
      out.add({'id': key.toString(), ...m});
    });

    out.sort((a, b) {
      final aTs = _toInt(a['createdAt']);
      final bTs = _toInt(b['createdAt']);
      return bTs.compareTo(aTs);
    });

    return out;
  }

  Future<void> _openViewer(Map<String, dynamic> item) async {
    final itemId = (item['id'] ?? '').toString();
    final type = (item['type'] ?? '').toString().trim().toLowerCase();
    final url = (item['url'] ?? '').toString().trim();
    final uploaderName = (item['uploadedByName'] ?? '').toString().trim();
    final createdAt = _fmtDate(item['createdAt']);

    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _AdminPublicGalleryViewerScreen(
          itemId: itemId,
          type: type,
          url: url,
          uploaderName: uploaderName,
          createdAt: createdAt,
          onDelete: itemId.isEmpty
              ? null
              : () async {
                  await _deleteItem(itemId);
                },
        ),
      ),
    );
  }

  Widget _buildPublicTeasersTab() {
    return StreamBuilder<DatabaseEvent>(
      stream: _publicGalleryStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting &&
            _publicGalleryCache == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final rawValue = snap.data?.snapshot.value;
        if (rawValue != null) {
          _publicGalleryCache = rawValue;
        }

        final items = _itemsFromSnapshot(rawValue ?? _publicGalleryCache);
        _visiblePublicItems = items;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: _uploadingPhoto
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.add_photo_alternate_rounded),
                    label: Text(_photoUploadLabel()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: actionOrange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: (_uploadingPhoto || _uploadingVideo)
                        ? null
                        : _pickAndUploadPhoto,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: _uploadingVideo
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.video_call_rounded),
                    label: Text(_videoUploadLabel()),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryBlue,
                      side: BorderSide(color: uiBorder.withValues(alpha: 0.9)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: (_uploadingPhoto || _uploadingVideo)
                        ? null
                        : _pickAndUploadVideo,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (_ok != null) ...[
              Text(
                _ok!,
                style: const TextStyle(
                  color: primaryBlue,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
            ],
            const Text(
              'Teaser Items',
              style: TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
                ),
                child: const Text(
                  'No public teaser items yet.',
                  style: TextStyle(
                    color: mainText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              )
            else
              GridView.builder(
                itemCount: items.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1,
                ),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final type = (item['type'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();
                  final url = (item['url'] ?? '').toString().trim();
                  final thumbnailUrl = (item['thumbnailUrl'] ?? '').toString().trim();
                  final itemId = (item['id'] ?? '').toString().trim();
                  final isSelected = _selectedPublicIds.contains(itemId);

                  return InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      if (_publicBulkMode) {
                        if (itemId.isEmpty || _bulkDeleting) return;
                        setState(() {
                          if (isSelected) {
                            _selectedPublicIds.remove(itemId);
                          } else {
                            _selectedPublicIds.add(itemId);
                          }
                        });
                        return;
                      }
                      _openViewer(item);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: _publicBulkMode && isSelected
                              ? actionOrange
                              : uiBorder.withValues(alpha: 0.85),
                          width: _publicBulkMode && isSelected ? 2 : 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (type == 'video')
                              _AdminVideoTile(url: url, thumbnailUrl: thumbnailUrl)
                            else
                              Image.network(
                                url,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  color: Colors.grey.shade200,
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                  ),
                                ),
                              ),
                            Positioned(
                              left: 8,
                              right: 8,
                              bottom: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.58),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      type == 'video'
                                          ? Icons.play_circle_fill_rounded
                                          : Icons.photo_rounded,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        type == 'video' ? 'Video' : 'Photo',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_publicBulkMode)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Checkbox(
                                    value: isSelected,
                                    onChanged: _bulkDeleting
                                        ? null
                                        : (_) {
                                            if (itemId.isEmpty) return;
                                            setState(() {
                                              if (isSelected) {
                                                _selectedPublicIds.remove(
                                                  itemId,
                                                );
                                              } else {
                                                _selectedPublicIds.add(itemId);
                                              }
                                            });
                                          },
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Map<String, String> _parseTeacherNames(dynamic value) {
    final out = <String, String>{};
    if (value is! Map) return out;

    value.forEach((key, rawVal) {
      if (rawVal is! Map) return;
      final m = rawVal.map((k, vv) => MapEntry(k.toString(), vv));
      final role = (m['role'] ?? '').toString().trim().toLowerCase();
      if (role != 'teacher') return;

      final uid = key.toString().trim();
      if (uid.isEmpty) return;

      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();

      out[uid] = full.isNotEmpty ? full : (email.isNotEmpty ? email : uid);
    });

    return out;
  }

  String _resolveResponsibleTeacher(
    Map<String, dynamic> learnerMap,
    Map<String, String> teacherNamesByUid,
  ) {
    final unique = <String>{};
    final ordered = <String>[];

    void addName(String name) {
      final n = name.trim();
      if (n.isEmpty) return;
      if (unique.add(n)) ordered.add(n);
    }

    final coursesRaw = learnerMap['courses'];
    if (coursesRaw is Map) {
      final courses = coursesRaw.map((k, v) => MapEntry(k.toString(), v));
      for (final courseEntry in courses.entries) {
        final rawCourse = courseEntry.value;
        if (rawCourse is! Map) continue;

        final course = rawCourse.map((k, v) => MapEntry(k.toString(), v));

        addName(
          (course['teacherName'] ?? course['instructorName'] ?? '').toString(),
        );

        final directTeacherUid =
            (course['teacherUid'] ?? course['teacher_uid'] ?? '').toString();
        if (directTeacherUid.trim().isNotEmpty) {
          addName(teacherNamesByUid[directTeacherUid] ?? directTeacherUid);
        }

        final clsRaw = course['class'];
        if (clsRaw is Map) {
          final cls = clsRaw.map((k, v) => MapEntry(k.toString(), v));

          addName(
            (cls['teacher_name'] ??
                    cls['instructor_name'] ??
                    cls['teacherName'] ??
                    cls['instructorName'] ??
                    cls['teacher'] ??
                    cls['instructor'] ??
                    '')
                .toString(),
          );

          final teacherUid = (cls['teacher_uid'] ?? cls['teacherUid'] ?? '')
              .toString();
          final instructorUid =
              (cls['instructor_uid'] ?? cls['instructorUid'] ?? '').toString();

          if (teacherUid.trim().isNotEmpty) {
            addName(teacherNamesByUid[teacherUid] ?? teacherUid);
          }
          if (instructorUid.trim().isNotEmpty) {
            addName(teacherNamesByUid[instructorUid] ?? instructorUid);
          }
        }
      }
    }

    addName(
      (learnerMap['teacher_name'] ?? learnerMap['instructor_name'] ?? '')
          .toString(),
    );

    if (ordered.isEmpty) return 'Not assigned';
    return ordered.join(', ');
  }

  List<_AdminLearnerLite> _parseLearners(dynamic value) {
    if (value is! Map) return [];

    final out = <_AdminLearnerLite>[];
    final teacherNamesByUid = _parseTeacherNames(value);

    value.forEach((key, rawVal) {
      if (rawVal is! Map) return;

      final m = rawVal.map((k, vv) => MapEntry(k.toString(), vv));

      final role = (m['role'] ?? '').toString().trim().toLowerCase();
      if (role != 'learner') return;

      final uid = key.toString();
      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final fullName = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      final phone1 = (m['phone1'] ?? '').toString().trim();
      final serial = (m['serial'] ?? '').toString().trim();
      final responsibleTeacher = _resolveResponsibleTeacher(
        m,
        teacherNamesByUid,
      );

      out.add(
        _AdminLearnerLite(
          uid: uid,
          fullName: fullName.isEmpty ? 'Learner' : fullName,
          email: email,
          phone1: phone1,
          serial: serial,
          responsibleTeacher: responsibleTeacher,
        ),
      );
    });

    out.sort(
      (a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()),
    );
    return out;
  }

  Map<String, Map<String, dynamic>> _parseLearnerGalleryStats(dynamic value) {
    final out = <String, Map<String, dynamic>>{};
    if (value is! Map) return out;

    final raw = Map<dynamic, dynamic>.from(value);
    raw.forEach((learnerUid, learnerGalleryValue) {
      if (learnerGalleryValue is! Map) {
        out[learnerUid.toString()] = const {'count': 0, 'thumbnailUrl': ''};
        return;
      }

      int count = 0;
      String thumbnailUrl = '';
      int newestPhotoTs = -1;
      final gallery = Map<dynamic, dynamic>.from(learnerGalleryValue);
      gallery.forEach((_, itemRaw) {
        if (itemRaw is! Map) return;
        final m = itemRaw.map((k, v) => MapEntry(k.toString(), v));
        final type = (m['type'] ?? '').toString().trim().toLowerCase();
        final url = (m['url'] ?? '').toString().trim();
        if (url.isEmpty || (type != 'photo' && type != 'video')) return;
        count++;

        if (type == 'photo') {
          final ts = _toInt(m['createdAt']);
          if (ts >= newestPhotoTs) {
            newestPhotoTs = ts;
            thumbnailUrl = url;
          }
        }
      });

      out[learnerUid.toString()] = {
        'count': count,
        'thumbnailUrl': thumbnailUrl,
      };
    });

    return out;
  }

  static String _normUrl(dynamic raw) {
    final v = (raw ?? '').toString().trim();
    if (v.isEmpty) return '';
    if (v.startsWith('//')) return 'https:$v';
    if (v.startsWith('www.')) return 'https://$v';
    return v;
  }

  static bool _isHttpUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static List<String> _urlsFromUnknown(dynamic raw) {
    final out = <String>[];

    void addOne(dynamic v) {
      final s = _normUrl(v);
      if (s.isNotEmpty && _isHttpUrl(s)) out.add(s);
    }

    if (raw is List) {
      for (final item in raw) {
        addOne(item);
      }
      return out;
    }

    if (raw is Map) {
      final entries = raw.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final e in entries) {
        addOne(e.value);
      }
      return out;
    }

    addOne(raw);
    return out;
  }

  Widget _buildLearnerGalleriesTab() {
    return StreamBuilder<DatabaseEvent>(
      stream: _usersStream,
      builder: (context, usersSnap) {
        if (usersSnap.connectionState == ConnectionState.waiting &&
            _usersCache == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final usersValue = usersSnap.data?.snapshot.value;
        if (usersValue != null) {
          _usersCache = usersValue;
        }

        final learners = _parseLearners(usersValue ?? _usersCache);

        return StreamBuilder<DatabaseEvent>(
          stream: _learnerGalleryStream,
          builder: (context, gallerySnap) {
            if (gallerySnap.connectionState == ConnectionState.waiting &&
                _learnerGalleryCache == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final galleryValue = gallerySnap.data?.snapshot.value;
            if (galleryValue != null) {
              _learnerGalleryCache = galleryValue;
            }

            final stats = _parseLearnerGalleryStats(
              galleryValue ?? _learnerGalleryCache,
            );

            final q = _learnerSearch.trim().toLowerCase();

            final filtered = learners.where((l) {
              final count = (stats[l.uid]?['count'] as int?) ?? 0;
              if (_onlyEmptyLearnerGalleries && count > 0) {
                return false;
              }
              if (q.isEmpty) return true;
              return l.fullName.toLowerCase().contains(q) ||
                  l.email.toLowerCase().contains(q) ||
                  l.phone1.toLowerCase().contains(q) ||
                  l.serial.toLowerCase().contains(q);
            }).toList();
            _visibleLearners = filtered;

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  onChanged: (v) => setState(() => _learnerSearch = v),
                  decoration: InputDecoration(
                    hintText: 'Search learner…',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: uiBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: uiBorder.withValues(alpha: 0.9),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      borderSide: BorderSide(color: primaryBlue),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      selected: !_onlyEmptyLearnerGalleries,
                      label: const Text('All learners'),
                      onSelected: (_) =>
                          setState(() => _onlyEmptyLearnerGalleries = false),
                    ),
                    ChoiceChip(
                      selected: _onlyEmptyLearnerGalleries,
                      label: const Text('No gallery only'),
                      onSelected: (_) =>
                          setState(() => _onlyEmptyLearnerGalleries = true),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${filtered.length} learner${filtered.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 10),
                if (filtered.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: uiBorder.withValues(alpha: 0.85),
                      ),
                    ),
                    child: const Text(
                      'No learners found.',
                      style: TextStyle(
                        color: mainText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, _) {
                      return GridView.builder(
                        itemCount: filtered.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: 1.12,
                            ),
                        itemBuilder: (context, index) {
                          final learner = filtered[index];
                          final stat =
                              stats[learner.uid] ??
                              const {'count': 0, 'thumbnailUrl': ''};
                          return _AdminLearnerGalleryCard(
                            key: ValueKey(learner.uid),
                            learner: learner,
                            itemCount: (stat['count'] as int?) ?? 0,
                            thumbnailUrl: (stat['thumbnailUrl'] ?? '')
                                .toString()
                                .trim(),
                            selectionMode: _learnerBulkMode,
                            selected: _selectedLearnerUids.contains(
                              learner.uid.trim(),
                            ),
                            onSelectToggle: () {
                              if (_bulkDeleting) return;
                              final uid = learner.uid.trim();
                              if (uid.isEmpty) return;
                              setState(() {
                                if (_selectedLearnerUids.contains(uid)) {
                                  _selectedLearnerUids.remove(uid);
                                } else {
                                  _selectedLearnerUids.add(uid);
                                }
                              });
                            },
                            onTap: () async {
                              if (_learnerBulkMode) {
                                final uid = learner.uid.trim();
                                if (uid.isEmpty || _bulkDeleting) return;
                                setState(() {
                                  if (_selectedLearnerUids.contains(uid)) {
                                    _selectedLearnerUids.remove(uid);
                                  } else {
                                    _selectedLearnerUids.add(uid);
                                  }
                                });
                                return;
                              }
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => AdminLearnerGalleryScreen(
                                    learnerUid: learner.uid,
                                    learnerName: learner.fullName,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }

  List<_AdminTeacherProfileLite> _parseTeacherProfiles({
    required dynamic usersValue,
    required dynamic websiteTeachersValue,
  }) {
    if (usersValue is! Map) return [];

    final websiteByUid = <String, Map<String, dynamic>>{};
    if (websiteTeachersValue is Map) {
      final websiteRaw = Map<dynamic, dynamic>.from(websiteTeachersValue);
      websiteRaw.forEach((uidRaw, teacherNodeRaw) {
        if (teacherNodeRaw is! Map) return;
        final teacherNode = teacherNodeRaw.map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final profileRaw = teacherNode['profile'];
        if (profileRaw is! Map) return;
        websiteByUid[uidRaw.toString()] = profileRaw.map(
          (k, v) => MapEntry(k.toString(), v),
        );
      });
    }

    final out = <_AdminTeacherProfileLite>[];
    final users = Map<dynamic, dynamic>.from(usersValue);
    users.forEach((uidRaw, userRaw) {
      if (userRaw is! Map) return;
      final m = userRaw.map((k, v) => MapEntry(k.toString(), v));
      final role = (m['role'] ?? '').toString().trim().toLowerCase();
      if (role != 'teacher') return;

      final uid = uidRaw.toString().trim();
      if (uid.isEmpty) return;

      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      final phone = (m['phone1'] ?? m['phone2'] ?? '').toString().trim();

      final profile = websiteByUid[uid] ?? const <String, dynamic>{};
      final photos = <String>[];
      photos.addAll(_urlsFromUnknown(profile['profile_photos']));
      if (photos.isEmpty) {
        final one = _normUrl(profile['profile_photo']);
        if (one.isNotEmpty && _isHttpUrl(one)) photos.add(one);
      }

      final introVideoUrl = _normUrl(profile['intro_video_url']);
      final safeVideoUrl = _isHttpUrl(introVideoUrl) ? introVideoUrl : '';

      out.add(
        _AdminTeacherProfileLite(
          uid: uid,
          name: full.isNotEmpty ? full : (email.isNotEmpty ? email : 'Teacher'),
          email: email,
          phone1: phone,
          photoUrls: photos,
          introVideoUrl: safeVideoUrl,
        ),
      );
    });

    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<int> _cleanupMissingTeacherProfileMedia(
    List<_AdminTeacherProfileLite> teachers, {
    _CleanupProgressCallback? onProgress,
  }) async {
    if (_teacherMediaCleanupRunning) return 0;

    _teacherMediaCleanupRunning = true;
    var cleanedTeachers = 0;

    try {
      final liveUids = teachers.map((t) => t.uid).toSet();
      _teacherMediaCheckedSignatures.removeWhere(
        (k, _) => !liveUids.contains(k),
      );

      for (final teacher in teachers) {
        final uid = teacher.uid.trim();
        if (uid.isEmpty) continue;

        final signature =
            '${teacher.photoUrls.join('|')}|${teacher.introVideoUrl.trim()}';
        if (_teacherMediaCheckedSignatures[uid] == signature) continue;

        var hadUnknown = false;
        var changed = false;
        final keptPhotos = <String>[];

        for (final photoUrl in teacher.photoUrls) {
          onProgress?.call(stage: 'Teacher Gallery', foundDelta: 1);
          final check = await _checkMediaHealth(
            photoUrl,
            expectedType: 'photo',
          );
          onProgress?.call(stage: 'Teacher Gallery', checkedDelta: 1);

          if (check == StorageCheckResult.missing) {
            onProgress?.call(stage: 'Teacher Gallery', missingDelta: 1);
            changed = true;
            continue;
          }
          if (check == StorageCheckResult.unknown) {
            hadUnknown = true;
            onProgress?.call(stage: 'Teacher Gallery', unknownDelta: 1);
          }
          keptPhotos.add(photoUrl);
        }

        var nextIntroVideo = teacher.introVideoUrl.trim();
        if (nextIntroVideo.isNotEmpty) {
          onProgress?.call(stage: 'Teacher Gallery', foundDelta: 1);
          final check = await _checkMediaHealth(
            nextIntroVideo,
            expectedType: 'video',
          );
          onProgress?.call(stage: 'Teacher Gallery', checkedDelta: 1);

          if (check == StorageCheckResult.missing) {
            nextIntroVideo = '';
            changed = true;
            onProgress?.call(stage: 'Teacher Gallery', missingDelta: 1);
          } else if (check == StorageCheckResult.unknown) {
            hadUnknown = true;
            onProgress?.call(stage: 'Teacher Gallery', unknownDelta: 1);
          }
        }

        if (changed) {
          await _db.child('website/teachers/$uid/profile').update({
            'profile_photos': keptPhotos,
            'profile_photo': keptPhotos.isEmpty ? '' : keptPhotos.first,
            'intro_video_url': nextIntroVideo,
          });
          cleanedTeachers++;

          final removedForTeacher =
              teacher.photoUrls.length -
              keptPhotos.length +
              (teacher.introVideoUrl.trim().isNotEmpty && nextIntroVideo.isEmpty
                  ? 1
                  : 0);
          if (removedForTeacher > 0) {
            onProgress?.call(
              stage: 'Teacher Gallery',
              deletedDelta: removedForTeacher,
            );
          }
        }

        if (!hadUnknown) {
          _teacherMediaCheckedSignatures[uid] = signature;
        }
      }

      return cleanedTeachers;
    } finally {
      _teacherMediaCleanupRunning = false;
    }
  }

  Widget _buildTeacherGalleryTab() {
    return StreamBuilder<DatabaseEvent>(
      stream: _usersStream,
      builder: (context, usersSnap) {
        if (usersSnap.connectionState == ConnectionState.waiting &&
            _usersCache == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final usersValue = usersSnap.data?.snapshot.value;
        if (usersValue != null) {
          _usersCache = usersValue;
        }

        return StreamBuilder<DatabaseEvent>(
          stream: _teacherProfilesStream,
          builder: (context, profilesSnap) {
            if (profilesSnap.connectionState == ConnectionState.waiting &&
                _teacherProfilesCache == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final profilesValue = profilesSnap.data?.snapshot.value;
            if (profilesValue != null) {
              _teacherProfilesCache = profilesValue;
            }

            final teachers = _parseTeacherProfiles(
              usersValue: usersValue ?? _usersCache,
              websiteTeachersValue: profilesValue ?? _teacherProfilesCache,
            );

            final q = _teacherSearch.trim().toLowerCase();
            final filtered = teachers.where((t) {
              if (q.isEmpty) return true;
              return t.name.toLowerCase().contains(q) ||
                  t.email.toLowerCase().contains(q) ||
                  t.phone1.toLowerCase().contains(q);
            }).toList();
            _visibleTeachers = filtered;

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  onChanged: (v) => setState(() => _teacherSearch = v),
                  decoration: InputDecoration(
                    hintText: 'Search teacher profile…',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: uiBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: uiBorder.withValues(alpha: 0.9),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      borderSide: BorderSide(color: primaryBlue),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${filtered.length} teacher${filtered.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 10),
                if (filtered.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: uiBorder.withValues(alpha: 0.85),
                      ),
                    ),
                    child: const Text(
                      'No teacher profiles found.',
                      style: TextStyle(
                        color: mainText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, _) {
                      return GridView.builder(
                        itemCount: filtered.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: 1.12,
                            ),
                        itemBuilder: (context, index) {
                          final teacher = filtered[index];
                          return _AdminTeacherProfileCard(
                            teacher: teacher,
                            thumbnailUrl: teacher.photoUrls.isEmpty
                                ? ''
                                : teacher.photoUrls.first,
                            selectionMode: _teacherBulkMode,
                            selected: _selectedTeacherUids.contains(
                              teacher.uid.trim(),
                            ),
                            onSelectToggle: () {
                              if (_bulkDeleting) return;
                              final uid = teacher.uid.trim();
                              if (uid.isEmpty) return;
                              setState(() {
                                if (_selectedTeacherUids.contains(uid)) {
                                  _selectedTeacherUids.remove(uid);
                                } else {
                                  _selectedTeacherUids.add(uid);
                                }
                              });
                            },
                            onTap: () async {
                              if (_teacherBulkMode) {
                                final uid = teacher.uid.trim();
                                if (uid.isEmpty || _bulkDeleting) return;
                                setState(() {
                                  if (_selectedTeacherUids.contains(uid)) {
                                    _selectedTeacherUids.remove(uid);
                                  } else {
                                    _selectedTeacherUids.add(uid);
                                  }
                                });
                                return;
                              }
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      _AdminTeacherProfileGalleryScreen(
                                        teacher: teacher,
                                      ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Gallery',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh and clean all galleries',
            onPressed: _globalCleanupRunning ? null : _runGlobalGalleryCleanup,
            icon: _globalCleanupRunning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: _isBulkModeActive ? 'Exit bulk select' : 'Bulk select',
            onPressed: _globalCleanupRunning
                ? null
                : _toggleBulkModeForActiveTab,
            icon: Icon(
              _isBulkModeActive
                  ? Icons.checklist_rtl_rounded
                  : Icons.select_all_rounded,
            ),
          ),
          if (_isBulkModeActive) ...[
            IconButton(
              tooltip: 'Select all',
              onPressed: _bulkDeleting ? null : _selectAllForActiveTab,
              icon: const Icon(Icons.done_all_rounded),
            ),
            IconButton(
              tooltip: 'Clear selection',
              onPressed: _bulkDeleting ? null : _clearSelectionForActiveTab,
              icon: const Icon(Icons.deselect_rounded),
            ),
            IconButton(
              tooltip: 'Delete selected',
              onPressed: _bulkDeleting || _selectedCount == 0
                  ? null
                  : _deleteSelectedForActiveTab,
              icon: _bulkDeleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_rounded),
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: primaryBlue,
          unselectedLabelColor: primaryBlue.withValues(alpha: 0.55),
          indicatorColor: primaryBlue,
          tabs: const [
            Tab(text: 'Public Gallery'),
            Tab(text: 'Learner Galleries'),
            Tab(text: 'Teacher Gallery'),
          ],
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: SafeArea(
          child: TabBarView(
            controller: _tab,
            children: [
              _buildPublicTeasersTab(),
              _buildLearnerGalleriesTab(),
              _buildTeacherGalleryTab(),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminLearnerLite {
  const _AdminLearnerLite({
    required this.uid,
    required this.fullName,
    required this.email,
    required this.phone1,
    required this.serial,
    required this.responsibleTeacher,
  });

  final String uid;
  final String fullName;
  final String email;
  final String phone1;
  final String serial;
  final String responsibleTeacher;
}

class _AdminTeacherProfileLite {
  const _AdminTeacherProfileLite({
    required this.uid,
    required this.name,
    required this.email,
    required this.phone1,
    required this.photoUrls,
    required this.introVideoUrl,
  });

  final String uid;
  final String name;
  final String email;
  final String phone1;
  final List<String> photoUrls;
  final String introVideoUrl;
}

class _AdminTeacherProfileCard extends StatelessWidget {
  const _AdminTeacherProfileCard({
    required this.teacher,
    required this.thumbnailUrl,
    required this.onTap,
    required this.selectionMode,
    required this.selected,
    required this.onSelectToggle,
  });

  final _AdminTeacherProfileLite teacher;
  final String thumbnailUrl;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onSelectToggle;

  @override
  Widget build(BuildContext context) {
    const uiBorder = _AdminPublicGalleryScreenState.uiBorder;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selectionMode && selected
                ? _AdminPublicGalleryScreenState.actionOrange
                : uiBorder.withValues(alpha: 0.85),
            width: selectionMode && selected ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            _SingleCardImage(
              url: thumbnailUrl,
              emptyIcon: Icons.person_rounded,
              topTag: teacher.name,
            ),
            if (selectionMode)
              Positioned(
                top: 8,
                right: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    shape: BoxShape.circle,
                  ),
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => onSelectToggle(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AdminLearnerGalleryCard extends StatelessWidget {
  const _AdminLearnerGalleryCard({
    super.key,
    required this.learner,
    required this.itemCount,
    required this.thumbnailUrl,
    required this.onTap,
    required this.selectionMode,
    required this.selected,
    required this.onSelectToggle,
  });

  final _AdminLearnerLite learner;
  final int itemCount;
  final String thumbnailUrl;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onSelectToggle;

  @override
  Widget build(BuildContext context) {
    const uiBorder = _AdminPublicGalleryScreenState.uiBorder;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selectionMode && selected
                ? _AdminPublicGalleryScreenState.actionOrange
                : uiBorder.withValues(alpha: 0.85),
            width: selectionMode && selected ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            _SingleCardImage(
              url: thumbnailUrl,
              emptyIcon: Icons.photo_library_rounded,
              topTag: learner.fullName,
              trailingCount: itemCount,
            ),
            if (selectionMode)
              Positioned(
                top: 8,
                right: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    shape: BoxShape.circle,
                  ),
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => onSelectToggle(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SingleCardImage extends StatelessWidget {
  const _SingleCardImage({
    required this.url,
    required this.emptyIcon,
    required this.topTag,
    this.trailingCount,
  });

  final String url;
  final IconData emptyIcon;
  final String topTag;
  final int? trailingCount;

  @override
  Widget build(BuildContext context) {
    final cardWidth = (MediaQuery.of(context).size.width - (16 * 2) - 12) / 2;
    final pxRatio = MediaQuery.of(context).devicePixelRatio;
    final targetCacheWidth = (cardWidth * pxRatio).round();

    if (url.trim().isEmpty) {
      return Container(
        constraints: const BoxConstraints(minHeight: 120),
        decoration: BoxDecoration(
          color: _AdminPublicGalleryScreenState.appBg,
          borderRadius: BorderRadius.circular(18),
          border: Border(
            bottom: BorderSide(
              color: _AdminPublicGalleryScreenState.uiBorder.withValues(
                alpha: 0.6,
              ),
            ),
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Icon(
                emptyIcon,
                color: _AdminPublicGalleryScreenState.primaryBlue.withValues(
                  alpha: 0.35,
                ),
                size: 24,
              ),
            ),
            _TopNameTag(label: topTag),
            if (trailingCount != null) _BottomCountTag(count: trailingCount!),
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              url,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              cacheWidth: targetCacheWidth,
              errorBuilder: (_, _, _) => Container(
                color: Colors.grey.shade200,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
            _TopNameTag(label: topTag),
            if (trailingCount != null) _BottomCountTag(count: trailingCount!),
          ],
        ),
      ),
    );
  }
}

class _TopNameTag extends StatelessWidget {
  const _TopNameTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      left: 8,
      right: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _BottomCountTag extends StatelessWidget {
  const _BottomCountTag({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 8,
      bottom: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '$count',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

class _AdminTeacherProfileGalleryScreen extends StatelessWidget {
  const _AdminTeacherProfileGalleryScreen({required this.teacher});

  final _AdminTeacherProfileLite teacher;

  List<Map<String, dynamic>> _items() {
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < teacher.photoUrls.length; i++) {
      final url = teacher.photoUrls[i].trim();
      if (url.isEmpty) continue;
      out.add({'id': 'photo_$i', 'type': 'photo', 'url': url});
    }
    final video = teacher.introVideoUrl.trim();
    if (video.isNotEmpty) {
      out.insert(0, {'id': 'video_intro', 'type': 'video', 'url': video});
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    const primaryBlue = _AdminPublicGalleryScreenState.primaryBlue;
    const mainText = _AdminPublicGalleryScreenState.mainText;
    const appBg = _AdminPublicGalleryScreenState.appBg;
    const uiBorder = _AdminPublicGalleryScreenState.uiBorder;

    final items = _items();
    final photos = items.where((e) => e['type'] == 'photo').length;
    final videos = items.where((e) => e['type'] == 'video').length;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Text(
          '${teacher.name} Profile',
          style: const TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      teacher.name,
                      style: const TextStyle(
                        color: primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Teacher profile media (photos and intro video).',
                      style: TextStyle(
                        color: mainText.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _AdminCountPill(label: '${items.length} total'),
                        _AdminCountPill(label: '$photos photos'),
                        _AdminCountPill(label: '$videos videos'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (items.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
                  ),
                  child: const Text(
                    'No teacher profile media yet.',
                    style: TextStyle(
                      color: mainText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                )
              else
                GridView.builder(
                  itemCount: items.length,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.92,
                  ),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final type = (item['type'] ?? '').toString();
                    final url = (item['url'] ?? '').toString();
                    final thumbnailUrl = (item['thumbnailUrl'] ?? '').toString();

                    return InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => _AdminLearnerGalleryViewerScreen(
                              itemId: (item['id'] ?? '').toString(),
                              type: type,
                              url: url,
                              uploaderName: teacher.name,
                              learnerName: teacher.name,
                              createdAt: 'Teacher profile media',
                              onDelete: null,
                              subjectLabel: 'Teacher',
                            ),
                          ),
                        );
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: uiBorder.withValues(alpha: 0.85),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (type == 'video')
                                _AdminVideoTile(url: url, thumbnailUrl: thumbnailUrl)
                              else
                                Image.network(
                                  url,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    color: Colors.grey.shade200,
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                    ),
                                  ),
                                ),
                              Positioned(
                                left: 8,
                                top: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    type == 'video' ? 'Video' : 'Photo',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AdminLearnerGalleryScreen extends StatefulWidget {
  const AdminLearnerGalleryScreen({
    super.key,
    required this.learnerUid,
    required this.learnerName,
  });

  final String learnerUid;
  final String learnerName;

  @override
  State<AdminLearnerGalleryScreen> createState() =>
      _AdminLearnerGalleryScreenState();
}

class _AdminLearnerGalleryScreenState extends State<AdminLearnerGalleryScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
  double? _uploadPhotoProgress;
  double? _uploadVideoProgress;
  String? _error;
  String? _ok;
  String _adminName = 'Admin';

  @override
  void initState() {
    super.initState();
    _loadAdminName();
  }

  Future<void> _loadAdminName() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final snap = await _db.child('users/$uid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();

        if (!mounted) return;
        setState(() {
          _adminName = full.isNotEmpty ? full : 'Admin';
        });
      }
    } catch (_) {}
  }

  String _adminAppId(String uid) =>
      'admin_learner_gallery_${widget.learnerUid}_$uid';

  DatabaseReference _galleryRef() =>
      _db.child('learner_gallery/${widget.learnerUid}');

  Future<Map<String, String>> _uploadPlatformFile(
    PlatformFile file, {
    required void Function(double progress) onProgress,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);

    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['app_id'] = _adminAppId(user.uid);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file bytes.');
      }

      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected file path.');
      }

      request.files.add(
        await http.MultipartFile.fromPath('file', path, filename: file.name),
      );
    }

    final streamedResponse = await _sendMultipartWithProgress(
      request: request,
      onProgress: onProgress,
    );
    final responseBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      throw Exception(
        'Upload failed (${streamedResponse.statusCode}): $responseBody',
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['success'] != true) {
      throw Exception(
        decoded is Map
            ? (decoded['message'] ?? 'Upload failed')
            : 'Upload failed',
      );
    }

    final url = (decoded['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('Upload succeeded but no URL returned.');
    }

    final thumbnailUrl = (decoded['thumbnail_url'] ?? '').toString().trim();

    return {'url': url, 'thumbnailUrl': thumbnailUrl};
  }

  Future<void> _saveGalleryItem({
    required String type,
    required String url,
    String thumbnailUrl = '',
  }) async {
    final adminUid = FirebaseAuth.instance.currentUser?.uid;
    if (adminUid == null || adminUid.isEmpty) {
      throw Exception('Not logged in.');
    }

    final newRef = _galleryRef().push();

    await newRef.set({
      'type': type,
      'url': url,
      'thumbnailUrl': thumbnailUrl,
      'uploadedByUid': adminUid,
      'uploadedByName': _adminName,
      'uploadedByRole': 'admin',
      'teacherUid': adminUid,
      'teacherName': _adminName,
      'learnerUid': widget.learnerUid,
      'learnerName': widget.learnerName,
      'classId': '',
      'classTitle': '',
      'createdAt': ServerValue.timestamp,
    });
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
        _uploadingPhoto = true;
        _uploadingVideo = false;
        _uploadPhotoProgress = 0;
        _error = null;
        _ok = null;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: kIsWeb,
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final uploadResult = await _uploadPlatformFile(
        file,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _uploadPhotoProgress = p);
        },
      );

      await _saveGalleryItem(type: 'photo', url: uploadResult['url']!);

      if (!mounted) return;
      setState(() {
        _ok = 'Photo uploaded ✅';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not upload photo.');
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploadingPhoto = false;
          _uploadPhotoProgress = null;
        });
      }
    }
  }

  Future<void> _pickAndUploadVideo() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
        _uploadingVideo = true;
        _uploadingPhoto = false;
        _uploadVideoProgress = 0;
        _error = null;
        _ok = null;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: kIsWeb,
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'mov', 'webm', '3gp', 'ogg'],
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final uploadResult = await _uploadPlatformFile(
        file,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _uploadVideoProgress = p);
        },
      );

      await _saveGalleryItem(type: 'video', url: uploadResult['url']!, thumbnailUrl: uploadResult['thumbnailUrl']!);

      if (!mounted) return;
      setState(() {
        _ok = 'Video uploaded ✅';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not upload video.');
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploadingVideo = false;
          _uploadVideoProgress = null;
        });
      }
    }
  }

  Future<bool> _confirmDelete() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item'),
        content: Text(
          'Do you want to remove this gallery item for ${widget.learnerName}?',
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: actionOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  Future<void> _deleteItem(String itemId) async {
    final ok = await _confirmDelete();
    if (!ok) return;

    try {
      final snap = await _galleryRef().child(itemId).get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final url = (m['url'] ?? '').toString().trim();
        if (url.isNotEmpty) {
          await _deleteUploadedCoursesAsset(url);
        }
      }

      await _galleryRef().child(itemId).remove();
      if (!mounted) return;
      setState(() {
        _ok = 'Gallery item deleted from server and database';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e, fallback: 'Could not delete gallery item.');
      });
    }
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  String _fmtDate(dynamic ts) {
    final ms = _toInt(ts);
    if (ms <= 0) return '-';

    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  List<Map<String, dynamic>> _itemsFromSnapshot(dynamic value) {
    if (value is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(value);
    final out = <Map<String, dynamic>>[];

    raw.forEach((key, val) {
      if (val is! Map) return;

      final m = val.map((k, vv) => MapEntry(k.toString(), vv));
      out.add({'id': key.toString(), ...m});
    });

    out.sort((a, b) {
      final aTs = _toInt(a['createdAt']);
      final bTs = _toInt(b['createdAt']);
      return bTs.compareTo(aTs);
    });

    return out;
  }

  String _displayUploader(Map<String, dynamic> item) {
    final uploadedByName = (item['uploadedByName'] ?? '').toString().trim();
    if (uploadedByName.isNotEmpty) return uploadedByName;

    final teacherName = (item['teacherName'] ?? '').toString().trim();
    if (teacherName.isNotEmpty) return teacherName;

    return 'Admin';
  }

  Future<void> _openViewer(Map<String, dynamic> item) async {
    final itemId = (item['id'] ?? '').toString();
    final type = (item['type'] ?? '').toString().trim().toLowerCase();
    final url = (item['url'] ?? '').toString().trim();
    final uploaderName = _displayUploader(item);
    final createdAt = _fmtDate(item['createdAt']);

    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _AdminLearnerGalleryViewerScreen(
          itemId: itemId,
          type: type,
          url: url,
          uploaderName: uploaderName,
          learnerName: widget.learnerName,
          createdAt: createdAt,
          onDelete: itemId.isEmpty
              ? null
              : () async {
                  await _deleteItem(itemId);
                },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Text(
          '${widget.learnerName} Gallery',
          style: const TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [const SizedBox.shrink()],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: SafeArea(
          child: StreamBuilder<DatabaseEvent>(
            stream: _galleryRef().onValue,
            builder: (context, snap) {
              final items = _itemsFromSnapshot(snap.data?.snapshot.value);
              final photoCount = items
                  .where(
                    (e) =>
                        (e['type'] ?? '').toString().toLowerCase() == 'photo',
                  )
                  .length;
              final videoCount = items
                  .where(
                    (e) =>
                        (e['type'] ?? '').toString().toLowerCase() == 'video',
                  )
                  .length;

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: uiBorder.withValues(alpha: 0.85),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.learnerName,
                          style: const TextStyle(
                            color: primaryBlue,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Manage this learner gallery individually from admin.',
                          style: TextStyle(
                            color: mainText.withValues(alpha: 0.78),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _AdminCountPill(label: '${items.length} total'),
                            _AdminCountPill(label: '$photoCount photos'),
                            _AdminCountPill(label: '$videoCount videos'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: _uploadingPhoto
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.add_photo_alternate_rounded),
                          label: Text(
                            _uploadingPhoto
                                ? 'Uploading ${((_uploadPhotoProgress ?? 0) * 100).toStringAsFixed(0)}%'
                                : 'Upload Photo',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: actionOrange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: (_uploadingPhoto || _uploadingVideo)
                              ? null
                              : _pickAndUploadPhoto,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: _uploadingVideo
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.video_call_rounded),
                          label: Text(
                            _uploadingVideo
                                ? 'Uploading ${((_uploadVideoProgress ?? 0) * 100).toStringAsFixed(0)}%'
                                : 'Upload Video',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primaryBlue,
                            side: BorderSide(
                              color: uiBorder.withValues(alpha: 0.9),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: (_uploadingPhoto || _uploadingVideo)
                              ? null
                              : _pickAndUploadVideo,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_ok != null) ...[
                    Text(
                      _ok!,
                      style: const TextStyle(
                        color: primaryBlue,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const Text(
                    'Gallery Items',
                    style: TextStyle(
                      color: primaryBlue,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (items.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: uiBorder.withValues(alpha: 0.85),
                        ),
                      ),
                      child: const Text(
                        'No learner gallery items yet.',
                        style: TextStyle(
                          color: mainText,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    )
                  else
                    GridView.builder(
                      itemCount: items.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.92,
                          ),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final type = (item['type'] ?? '')
                            .toString()
                            .trim()
                            .toLowerCase();
                        final url = (item['url'] ?? '').toString().trim();
                        final thumbnailUrl = (item['thumbnailUrl'] ?? '').toString().trim();
                        final createdAt = _fmtDate(item['createdAt']);
                        final uploader = _displayUploader(item);

                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => _openViewer(item),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: uiBorder.withValues(alpha: 0.85),
                              ),
                            ),
                            child: Column(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(18),
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (type == 'video')
                                          _AdminVideoTile(url: url, thumbnailUrl: thumbnailUrl)
                                        else
                                          Image.network(
                                            url,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                Container(
                                                  color: Colors.grey.shade200,
                                                  alignment: Alignment.center,
                                                  child: const Icon(
                                                    Icons.broken_image_outlined,
                                                  ),
                                                ),
                                          ),
                                        Positioned(
                                          left: 8,
                                          top: 8,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.58,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  type == 'video'
                                                      ? Icons
                                                            .play_circle_fill_rounded
                                                      : Icons.photo_rounded,
                                                  color: Colors.white,
                                                  size: 14,
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  type == 'video'
                                                      ? 'Video'
                                                      : 'Photo',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    10,
                                    10,
                                    12,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        createdAt,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: mainText.withValues(
                                            alpha: 0.72,
                                          ),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.person_rounded,
                                            size: 14,
                                            color: primaryBlue,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              uploader,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: primaryBlue,
                                                fontWeight: FontWeight.w800,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AdminCountPill extends StatelessWidget {
  const _AdminCountPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: _AdminLearnerGalleryScreenState.primaryBlue.withValues(
          alpha: 0.08,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: _AdminLearnerGalleryScreenState.primaryBlue,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _AdminVideoTile extends StatefulWidget {
  const _AdminVideoTile({required this.url, this.thumbnailUrl});

  final String url;
  final String? thumbnailUrl;

  @override
  State<_AdminVideoTile> createState() => _AdminVideoTileState();
}

class _AdminVideoTileState extends State<_AdminVideoTile> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.thumbnailUrl == null || widget.thumbnailUrl!.isEmpty) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );

      await controller.initialize().timeout(const Duration(seconds: 10));
      await controller.setLooping(false);
      await controller.pause();
      await controller.seekTo(Duration.zero);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _ready = true;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _ready = false;
      });
    }
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            widget.thumbnailUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          Container(color: Colors.black.withValues(alpha: 0.18)),
          const Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              color: Colors.white,
              size: 52,
            ),
          ),
        ],
      );
    }

    if (_failed) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const Icon(
          Icons.broken_image_outlined,
          color: Colors.white,
          size: 34,
        ),
      );
    }

    if (!_ready || _controller == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),
        Container(color: Colors.black.withValues(alpha: 0.18)),
        const Center(
          child: Icon(
            Icons.play_circle_fill_rounded,
            color: Colors.white,
            size: 52,
          ),
        ),
      ],
    );
  }
}

class _AdminVideoPreviewCard extends StatefulWidget {
  const _AdminVideoPreviewCard({required this.url});

  final String url;

  @override
  State<_AdminVideoPreviewCard> createState() => _AdminVideoPreviewCardState();
}

class _AdminVideoPreviewCardState extends State<_AdminVideoPreviewCard> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.url),
      );
      await controller.initialize().timeout(const Duration(seconds: 10));
      await controller.setLooping(false);
      await controller.setPlaybackSpeed(_speed);
      controller.addListener(_videoListener);

      if (!mounted) {
        controller.removeListener(_videoListener);
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _ready = true;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _ready = false;
      });
    }
  }

  void _videoListener() {
    if (!mounted) return;
    setState(() {});
  }

  String _fmtDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _togglePlayPause() async {
    if (_controller == null) return;

    if (_controller!.value.isPlaying) {
      await _controller!.pause();
    } else {
      await _controller!.play();
    }

    if (mounted) setState(() {});
  }

  Future<void> _toggleSpeed() async {
    if (_controller == null) return;

    _speed = _speed == 1.0 ? 2.0 : 1.0;
    await _controller!.setPlaybackSpeed(_speed);

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final c = _controller;
    if (c != null) {
      c.removeListener(_videoListener);
    }
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.broken_image_outlined,
          color: Colors.white,
          size: 34,
        ),
      );
    }

    if (!_ready || _controller == null) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final value = _controller!.value;
    final duration = value.duration;
    final position = value.position > duration ? duration : value.position;

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(_controller!),
                  IconButton(
                    onPressed: _togglePlayPause,
                    iconSize: 54,
                    color: Colors.white,
                    icon: Icon(
                      value.isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
              color: Colors.black.withValues(alpha: 0.88),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      min: 0,
                      max: duration.inMilliseconds <= 0
                          ? 1
                          : duration.inMilliseconds.toDouble(),
                      value: position.inMilliseconds
                          .clamp(
                            0,
                            duration.inMilliseconds <= 0
                                ? 1
                                : duration.inMilliseconds,
                          )
                          .toDouble(),
                      activeColor: Colors.white,
                      inactiveColor: Colors.white24,
                      onChanged: (value) async {
                        await _controller!.seekTo(
                          Duration(milliseconds: value.toInt()),
                        );
                      },
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        _fmtDuration(position),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _toggleSpeed,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _speed == 1.0 ? '1x' : '2x',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _fmtDuration(duration),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminPublicGalleryViewerScreen extends StatelessWidget {
  const _AdminPublicGalleryViewerScreen({
    required this.itemId,
    required this.type,
    required this.url,
    required this.uploaderName,
    required this.createdAt,
    required this.onDelete,
  });

  final String itemId;
  final String type;
  final String url;
  final String uploaderName;
  final String createdAt;
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    final isVideo = type.trim().toLowerCase() == 'video';
    final displayUploader = uploaderName.trim().isEmpty
        ? 'Admin'
        : uploaderName.trim();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          isVideo ? 'Video' : 'Photo',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_rounded, color: Colors.white),
            onPressed: () => MediaDownload.downloadUrl(
              context,
              url: url,
              suggestedName: isVideo
                  ? 'admin_gallery_video_${DateTime.now().millisecondsSinceEpoch}.mp4'
                  : 'admin_gallery_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
            ),
          ),
          if (onDelete != null && itemId.isNotEmpty)
            IconButton(
              tooltip: 'Delete',
              onPressed: () async {
                await onDelete!.call();
                if (context.mounted) {
                  Navigator.of(context).pop(true);
                }
              },
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.white,
              ),
            ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: isVideo
                            ? _AdminVideoPreviewCard(url: url)
                            : InteractiveViewer(
                                minScale: 0.8,
                                maxScale: 4,
                                child: Image.network(
                                  url,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) => const SizedBox(
                                    height: 260,
                                    child: Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.white,
                                        size: 44,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          border: Border(
                            top: BorderSide(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isVideo ? 'Video' : 'Photo',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Uploaded by: $displayUploader',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Added: $createdAt',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                                height: 1.15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AdminLearnerGalleryViewerScreen extends StatelessWidget {
  const _AdminLearnerGalleryViewerScreen({
    required this.itemId,
    required this.type,
    required this.url,
    required this.uploaderName,
    required this.learnerName,
    required this.createdAt,
    required this.onDelete,
    this.subjectLabel = 'Learner',
  });

  final String itemId;
  final String type;
  final String url;
  final String uploaderName;
  final String learnerName;
  final String createdAt;
  final Future<void> Function()? onDelete;
  final String subjectLabel;

  @override
  Widget build(BuildContext context) {
    final isVideo = type.trim().toLowerCase() == 'video';
    final displayUploader = uploaderName.trim().isEmpty
        ? 'Admin'
        : uploaderName.trim();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          isVideo ? 'Video' : 'Photo',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_rounded, color: Colors.white),
            onPressed: () => MediaDownload.downloadUrl(
              context,
              url: url,
              suggestedName: isVideo
                  ? 'admin_gallery_video_${DateTime.now().millisecondsSinceEpoch}.mp4'
                  : 'admin_gallery_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
            ),
          ),
          if (onDelete != null && itemId.isNotEmpty)
            IconButton(
              tooltip: 'Delete',
              onPressed: () async {
                await onDelete!.call();
                if (context.mounted) {
                  Navigator.of(context).pop(true);
                }
              },
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.white,
              ),
            ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: isVideo
                            ? _AdminVideoPreviewCard(url: url)
                            : InteractiveViewer(
                                minScale: 0.8,
                                maxScale: 4,
                                child: Image.network(
                                  url,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) => const SizedBox(
                                    height: 260,
                                    child: Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.white,
                                        size: 44,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          border: Border(
                            top: BorderSide(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isVideo ? 'Video' : 'Photo',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$subjectLabel: $learnerName',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Uploaded by: $displayUploader',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Added: $createdAt',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                                height: 1.15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
