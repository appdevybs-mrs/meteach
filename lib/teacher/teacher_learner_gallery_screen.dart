import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../services/backend_api.dart';
import '../services/audit_log_service.dart';
import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/media_download.dart';
import '../shared/teacher_web_layout.dart';

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

class TeacherLearnerGalleryScreen extends StatefulWidget {
  const TeacherLearnerGalleryScreen({
    super.key,
    required this.learnerUid,
    required this.learnerName,
    required this.classId,
    required this.classTitle,
  });

  final String learnerUid;
  final String learnerName;
  final String classId;
  final String classTitle;

  @override
  State<TeacherLearnerGalleryScreen> createState() =>
      _TeacherLearnerGalleryScreenState();
}

class _TeacherLearnerGalleryScreenState
    extends State<TeacherLearnerGalleryScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
  double _photoUploadProgress = 0;
  double _videoUploadProgress = 0;
  String? _error;
  String? _ok;
  String _teacherName = 'Teacher';

  AppPalette get palette => appThemeController.palette;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _loadTeacherName();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadTeacherName() async {
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
          _teacherName = full.isNotEmpty ? full : 'Teacher';
        });
      }
    } catch (_) {}
  }

  String _teacherAppId(String uid) => 'teacher_gallery_$uid';

  DatabaseReference _galleryRef() =>
      _db.child('learner_gallery/${widget.learnerUid}');

  Future<Map<String, String>> _uploadPlatformFile(
    PlatformFile file, {
    void Function(double progress)? onProgress,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);

    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['app_id'] = _teacherAppId(user.uid);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file bytes.');
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
      request.files.add(
        http.MultipartFile('file', stream, total, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected file path.');
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
      request.files.add(
        http.MultipartFile('file', stream, total, filename: file.name),
      );
    }

    onProgress?.call(0.0);
    final streamedResponse = await request.send().timeout(
      const Duration(minutes: 5),
    );
    onProgress?.call(0.95);
    final response = await http.Response.fromStream(
      streamedResponse,
    ).timeout(const Duration(minutes: 5));
    final responseBody = response.body;

    if (response.statusCode != 200) {
      throw Exception('Upload failed (${response.statusCode}): $responseBody');
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

    onProgress?.call(0.98);

    return {'url': url, 'thumbnailUrl': thumbnailUrl};
  }

  Future<void> _saveGalleryItem({
    required String type,
    required String url,
    String thumbnailUrl = '',
  }) async {
    final teacherUid = FirebaseAuth.instance.currentUser?.uid;
    if (teacherUid == null || teacherUid.isEmpty) {
      throw Exception('Not logged in.');
    }

    final newRef = _galleryRef().push();

    await newRef
        .set({
          'type': type,
          'url': url,
          'thumbnailUrl': thumbnailUrl,
          'teacherUid': teacherUid,
          'teacherName': _teacherName,
          'learnerUid': widget.learnerUid,
          'learnerName': widget.learnerName,
          'classId': widget.classId,
          'classTitle': widget.classTitle,
          'createdAt': ServerValue.timestamp,
        })
        .timeout(const Duration(seconds: 45));

    await AuditLogService.logSuccess(
      actionKey: 'teacher.gallery.upload',
      domain: 'content',
      summary: 'Teacher uploaded $type to learner gallery',
      actor: AuditActor(uid: teacherUid, role: 'teacher', name: _teacherName),
      target: AuditTarget(
        type: 'learner',
        uid: widget.learnerUid,
        id: newRef.key,
        name: widget.learnerName,
      ),
      keywords: [widget.classId, widget.learnerUid, type],
      context: {
        'itemId': newRef.key ?? '',
        'classId': widget.classId,
        'classTitle': widget.classTitle,
      },
      meta: {'mediaType': type},
    );
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
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

      if (!mounted) return;
      setState(() {
        _uploadingPhoto = true;
        _photoUploadProgress = 0;
      });

      final file = result.files.first;
      final uploadResult = await _uploadPlatformFile(
        file,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _photoUploadProgress = p);
        },
      );

      await _saveGalleryItem(type: 'photo', url: uploadResult['url']!);

      if (!mounted) return;
      setState(() {
        _photoUploadProgress = 1.0;
        _ok = 'Photo uploaded ✅';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploadingPhoto = false;
          _photoUploadProgress = 0;
        });
      }
    }
  }

  Future<void> _pickAndUploadVideo() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
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

      if (!mounted) return;
      setState(() {
        _uploadingVideo = true;
        _videoUploadProgress = 0;
      });

      final file = result.files.first;
      final uploadResult = await _uploadPlatformFile(
        file,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _videoUploadProgress = p);
        },
      );

      await _saveGalleryItem(type: 'video', url: uploadResult['url']!, thumbnailUrl: uploadResult['thumbnailUrl']!);

      if (!mounted) return;
      setState(() {
        _videoUploadProgress = 1.0;
        _ok = 'Video uploaded ✅';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
      });
    } finally {
      if (mounted) {
        setState(() {
          _uploadingVideo = false;
          _videoUploadProgress = 0;
        });
      }
    }
  }

  Future<bool> _confirmDelete() async {
    final p = palette;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.cardBg,
        title: Text(
          'Delete item',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          'Do you want to remove this gallery item for this learner?',
          style: TextStyle(
            color: p.text,
            fontWeight: FontWeight.w700,
            height: 1.4,
          ),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
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

      await AuditLogService.logSuccess(
        actionKey: 'teacher.gallery.delete',
        domain: 'content',
        summary: 'Teacher deleted learner gallery item',
        actor: AuditActor(
          uid: FirebaseAuth.instance.currentUser?.uid,
          role: 'teacher',
          name: _teacherName,
        ),
        target: AuditTarget(
          type: 'learner',
          uid: widget.learnerUid,
          id: itemId,
          name: widget.learnerName,
        ),
        keywords: [widget.classId, widget.learnerUid, itemId],
      );

      if (!mounted) return;
      setState(() {
        _ok = 'Gallery item deleted from server and database';
        _error = null;
      });
    } catch (e) {
      await AuditLogService.logFailure(
        actionKey: 'teacher.gallery.delete',
        domain: 'content',
        summary: 'Teacher failed to delete learner gallery item',
        actor: AuditActor(
          uid: FirebaseAuth.instance.currentUser?.uid,
          role: 'teacher',
          name: _teacherName,
        ),
        target: AuditTarget(
          type: 'learner',
          uid: widget.learnerUid,
          id: itemId,
          name: widget.learnerName,
        ),
        errorMessage: e.toString(),
      );
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
      });
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

  Future<void> _openViewer(
      List<Map<String, dynamic>> items, int index) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _TeacherGalleryViewerScreen(
          items: items,
          initialIndex: index,
          classTitle: widget.classTitle,
          learnerName: widget.learnerName,
          onDelete: (i) async {
            final itemId =
                (items[i]['id'] ?? '').toString().trim();
            if (itemId.isNotEmpty) {
              await _deleteItem(itemId);
            }
          },
        ),
      ),
    );
  }

  Widget _messageBox({
    required Color color,
    required IconData icon,
    required String text,
  }) {
    final p = palette;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color == p.accent ? p.primary : color,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip({required String text, required IconData icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    final displayLearnerName = widget.learnerName.trim().isEmpty
        ? 'Learner'
        : widget.learnerName.trim();

    final displayClassTitle = widget.classTitle.trim().isEmpty
        ? widget.classId
        : widget.classTitle.trim();

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$displayLearnerName Gallery',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              displayClassTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.text.withValues(alpha: 0.72),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [const SizedBox.shrink()],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1620,
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
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [p.primary, p.primary.withValues(alpha: 0.88)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: p.primary.withValues(alpha: 0.16),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(
                            Icons.collections_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayLearnerName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 20,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Class: $displayClassTitle',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.84),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _statChip(
                                    text: '${items.length} total',
                                    icon: Icons.grid_view_rounded,
                                  ),
                                  _statChip(
                                    text: '$photoCount photos',
                                    icon: Icons.photo_rounded,
                                  ),
                                  _statChip(
                                    text: '$videoCount videos',
                                    icon: Icons.videocam_rounded,
                                  ),
                                ],
                              ),
                            ],
                          ),
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
                                ? 'Uploading ${(_photoUploadProgress * 100).round()}%'
                                : 'Upload Photo',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: p.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
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
                                ? 'Uploading ${(_videoUploadProgress * 100).round()}%'
                                : 'Upload Video',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: p.primary,
                            side: BorderSide(
                              color: p.border.withValues(alpha: 0.9),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: (_uploadingPhoto || _uploadingVideo)
                              ? null
                              : _pickAndUploadVideo,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (_uploadingPhoto) ...[
                    LinearProgressIndicator(
                      value: _photoUploadProgress.clamp(0.0, 1.0).toDouble(),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_uploadingVideo) ...[
                    LinearProgressIndicator(
                      value: _videoUploadProgress.clamp(0.0, 1.0).toDouble(),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_error != null) ...[
                    _messageBox(
                      color: Theme.of(context).colorScheme.error,
                      icon: Icons.error_outline_rounded,
                      text: _error!,
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_ok != null) ...[
                    _messageBox(
                      color: p.accent,
                      icon: Icons.check_circle_rounded,
                      text: _ok!,
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Text(
                        'Gallery Items',
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${items.length} item${items.length == 1 ? '' : 's'}',
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (items.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: p.cardBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.85),
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.perm_media_outlined,
                            size: 56,
                            color: p.primary.withValues(alpha: 0.22),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No gallery items yet.',
                            style: TextStyle(
                              color: p.primary,
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Upload a photo or a video for this learner.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.text.withValues(alpha: 0.7),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
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
                            childAspectRatio: 0.88,
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
                        final itemTeacherName = (item['teacherName'] ?? '')
                            .toString()
                            .trim();

                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => _openViewer(items, index),
                          child: Container(
                            decoration: BoxDecoration(
                              color: p.cardBg,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: p.border.withValues(alpha: 0.85),
                              ),
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
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(18),
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (type == 'video')
                                          _TeacherVideoTile(url: url, thumbnailUrl: thumbnailUrl)
                                        else
                                          CachedNetworkImage(
                                            imageUrl: url,
                                            fit: BoxFit.cover,
                                            memCacheWidth: 440,
                                            placeholder: (_, _) => Container(
                                              color: p.soft,
                                              alignment: Alignment.center,
                                              child: const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              ),
                                            ),
                                            errorWidget: (_, _, _) =>
                                                Container(
                                                  color: p.soft,
                                                  alignment: Alignment.center,
                                                  child: Icon(
                                                    Icons.broken_image_outlined,
                                                    color: p.primary.withValues(
                                                      alpha: 0.55,
                                                    ),
                                                  ),
                                                ),
                                          ),
                                        Positioned(
                                          top: 8,
                                          left: 8,
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
                                          color: p.text.withValues(alpha: 0.72),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.person_rounded,
                                            size: 14,
                                            color: p.primary,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              itemTeacherName.isEmpty
                                                  ? _teacherName
                                                  : itemTeacherName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: p.primary,
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

class _TeacherVideoTile extends StatefulWidget {
  const _TeacherVideoTile({required this.url, this.thumbnailUrl});

  final String url;
  final String? thumbnailUrl;

  @override
  State<_TeacherVideoTile> createState() => _TeacherVideoTileState();
}

class _TeacherVideoTileState extends State<_TeacherVideoTile> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  int _thumbnailAttempt = 0;
  bool _autoRetryScheduled = false;

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

      await controller.initialize();
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

  Widget _buildThumbnailError() {
    if (!_autoRetryScheduled && _thumbnailAttempt < 3) {
      _autoRetryScheduled = true;
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _autoRetryScheduled = false;
          _retryThumbnail();
        }
      });
    }
    return GestureDetector(
      onTap: _retryThumbnail,
      child: Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 34),
      ),
    );
  }

  void _retryThumbnail() {
    setState(() => _thumbnailAttempt++);
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
    final p = appThemeController.palette;

    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: widget.thumbnailUrl!,
            cacheKey: '${widget.thumbnailUrl}_$_thumbnailAttempt',
            fit: BoxFit.cover,
            memCacheWidth: 440,
            errorWidget: (_, _, _) => _buildThumbnailError(),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.black.withValues(alpha: 0.10),
                  Colors.black.withValues(alpha: 0.35),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          Center(
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.90),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 34,
              ),
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
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.black.withValues(alpha: 0.10),
                Colors.black.withValues(alpha: 0.35),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
        Center(
          child: Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.90),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
        ),
      ],
    );
  }
}

class _TeacherVideoPreviewCard extends StatefulWidget {
  const _TeacherVideoPreviewCard({required this.url});

  final String url;

  @override
  State<_TeacherVideoPreviewCard> createState() =>
      _TeacherVideoPreviewCardState();
}

class _TeacherVideoPreviewCardState extends State<_TeacherVideoPreviewCard> {
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
      await controller.initialize();
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
    final p = appThemeController.palette;

    if (_failed) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
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
          borderRadius: BorderRadius.circular(16),
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
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: value.aspectRatio == 0 ? 16 / 9 : value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(_controller!),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.20),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _togglePlayPause,
                    iconSize: 62,
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
                      activeColor: p.accent,
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

class _TeacherGalleryViewerScreen extends StatefulWidget {
  const _TeacherGalleryViewerScreen({
    required this.items,
    required this.initialIndex,
    required this.classTitle,
    required this.learnerName,
    this.onDelete,
  });

  final List<Map<String, dynamic>> items;
  final int initialIndex;
  final String classTitle;
  final String learnerName;
  final Future<void> Function(int index)? onDelete;

  @override
  State<_TeacherGalleryViewerScreen> createState() =>
      _TeacherGalleryViewerScreenState();
}

class _TeacherGalleryViewerScreenState
    extends State<_TeacherGalleryViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _precacheAdjacent(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _precacheAdjacent(int index) {
    for (final offset in [-2, -1, 0, 1, 2]) {
      final i = index + offset;
      if (i < 0 || i >= widget.items.length) continue;
      final type =
          (widget.items[i]['type'] ?? '').toString().trim().toLowerCase();
      if (type == 'video') continue;
      final url = (widget.items[i]['url'] ?? '').toString().trim();
      if (url.isNotEmpty) {
        precacheImage(NetworkImage(url), context);
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

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          '${_currentIndex + 1} / ${widget.items.length}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: [
          IconButton(
            tooltip: 'Download',
            icon: Icon(Icons.download_rounded, color: p.accent),
            onPressed: () {
              final item = widget.items[_currentIndex];
              final isVideo =
                  (item['type'] ?? '').toString().trim().toLowerCase() ==
                      'video';
              final url = (item['url'] ?? '').toString().trim();
              MediaDownload.downloadUrl(
                context,
                url: url,
                suggestedName: isVideo
                    ? 'teacher_learner_video_${DateTime.now().millisecondsSinceEpoch}.mp4'
                    : 'teacher_learner_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
                isVideo: isVideo,
              );
            },
          ),
          if (widget.onDelete != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: () async {
                await widget.onDelete!(_currentIndex);
                if (context.mounted) {
                  Navigator.of(context).pop(true);
                }
              },
              icon: Icon(Icons.delete_outline_rounded, color: p.accent),
            ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.items.length,
        onPageChanged: (i) {
          setState(() => _currentIndex = i);
          _precacheAdjacent(i);
        },
        itemBuilder: (context, index) {
          final item = widget.items[index];
          final type =
              (item['type'] ?? '').toString().trim().toLowerCase();
          final url = (item['url'] ?? '').toString().trim();
          final thumbnailUrl =
              (item['thumbnailUrl'] ?? '').toString().trim();
          final isVideo = type == 'video';
          final teacherName =
              (item['teacherName'] ?? '').toString().trim();
          final displayTeacher =
              teacherName.isEmpty ? 'Teacher' : teacherName;
          final createdAt = _fmtDate(item['createdAt']);

          return Column(
            children: [
              Expanded(
                child: Center(
                  child: isVideo
                      ? _TeacherVideoPreviewCard(url: url)
                      : _buildImageViewer(url, thumbnailUrl),
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
                      'Uploaded by: $displayTeacher',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        height: 1.2,
                      ),
                    ),
                    if (widget.learnerName.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Learner: ${widget.learnerName}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          height: 1.2,
                        ),
                      ),
                    ],
                    if (widget.classTitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Class: ${widget.classTitle}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          height: 1.2,
                        ),
                      ),
                    ],
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
          );
        },
      ),
    );
  }

  Widget _buildImageViewer(String url, String thumbnailUrl) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final memCacheWidth =
            (constraints.maxWidth * devicePixelRatio).round().clamp(320, 2400);
        final memCacheHeight =
            (constraints.maxHeight * devicePixelRatio).round().clamp(320, 2400);

        return Stack(
          children: [
            if (thumbnailUrl.isNotEmpty)
              Positioned.fill(
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: thumbnailUrl,
                    fit: BoxFit.contain,
                    memCacheWidth: memCacheWidth,
                    memCacheHeight: memCacheHeight,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.contain,
                  memCacheWidth: memCacheWidth,
                  memCacheHeight: memCacheHeight,
                  placeholder: (_, _) => thumbnailUrl.isNotEmpty
                      ? const SizedBox.shrink()
                      : const SizedBox(
                          height: 260,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                  progressIndicatorBuilder: (context, _, progress) {
                    return SizedBox(
                      height: 260,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(
                              value: progress.progress,
                              color: Colors.white54,
                              strokeWidth: 2.5,
                            ),
                            if (progress.progress != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '${(progress.progress! * 100).toInt()}%',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                  errorWidget: (_, _, _) => const SizedBox(
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
          ],
        );
      },
    );
  }
}
