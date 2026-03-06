import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

class AdminPublicGalleryScreen extends StatefulWidget {
  const AdminPublicGalleryScreen({super.key});

  @override
  State<AdminPublicGalleryScreen> createState() =>
      _AdminPublicGalleryScreenState();
}

class _AdminPublicGalleryScreenState extends State<AdminPublicGalleryScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  static const String _uploadEndpoint =
      'https://www.yourbridgeschool.com/app/upload.php';

  static const String _uploadKeySha1 =
      'a7a995d9c499128351d827eaad7285bcc891919b';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
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

  String _adminAppId(String uid) => 'admin_public_gallery_$uid';

  DatabaseReference _galleryRef() => _db.child('public_gallery_teasers');

  Future<String> _uploadPlatformFile(PlatformFile file) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(_uploadEndpoint),
    );

    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    request.fields['key'] = _uploadKeySha1;
    request.fields['app_id'] = _adminAppId(user.uid);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file bytes.');
      }

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: file.name,
        ),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected file path.');
      }

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          path,
          filename: file.name,
        ),
      );
    }

    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      throw Exception(
        'Upload failed (${streamedResponse.statusCode}): $responseBody',
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['success'] != true) {
      throw Exception(
        decoded is Map ? (decoded['message'] ?? 'Upload failed') : 'Upload failed',
      );
    }

    final url = (decoded['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('Upload succeeded but no URL returned.');
    }

    return url;
  }

  Future<void> _saveGalleryItem({
    required String type,
    required String url,
  }) async {
    final adminUid = FirebaseAuth.instance.currentUser?.uid;
    if (adminUid == null || adminUid.isEmpty) {
      throw Exception('Not logged in.');
    }

    final newRef = _galleryRef().push();

    await newRef.set({
      'type': type,
      'url': url,
      'uploadedByUid': adminUid,
      'uploadedByName': _adminName,
      'createdAt': ServerValue.timestamp,
    });
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
        _uploadingPhoto = true;
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
      final url = await _uploadPlatformFile(file);

      await _saveGalleryItem(
        type: 'photo',
        url: url,
      );

      if (!mounted) return;
      setState(() {
        _ok = 'Photo uploaded ✅';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _uploadingPhoto = false;
      });
    }
  }

  Future<void> _pickAndUploadVideo() async {
    if (_uploadingPhoto || _uploadingVideo) return;

    try {
      setState(() {
        _uploadingVideo = true;
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
      final url = await _uploadPlatformFile(file);

      await _saveGalleryItem(
        type: 'video',
        url: url,
      );

      if (!mounted) return;
      setState(() {
        _ok = 'Video uploaded ✅';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _uploadingVideo = false;
      });
    }
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
      await _galleryRef().child(itemId).remove();
      if (!mounted) return;
      setState(() {
        _ok = 'Gallery item deleted';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
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
      out.add({
        'id': key.toString(),
        ...m,
      });
    });

    out.sort((a, b) {
      final aTs = _toInt(a['createdAt']);
      final bTs = _toInt(b['createdAt']);
      return bTs.compareTo(aTs);
    });

    return out;
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
          'Public Gallery',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: uiBorder.withOpacity(0.85)),
              ),
              child: Text(
                'These items will be used later as public gallery teasers.',
                style: TextStyle(
                  color: mainText.withOpacity(0.78),
                  fontWeight: FontWeight.w700,
                ),
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
                      _uploadingPhoto ? 'Uploading...' : 'Upload Photo',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: actionOrange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed:
                    (_uploadingPhoto || _uploadingVideo) ? null : _pickAndUploadPhoto,
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
                    label: Text(
                      _uploadingVideo ? 'Uploading...' : 'Upload Video',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryBlue,
                      side: BorderSide(color: uiBorder.withOpacity(0.9)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed:
                    (_uploadingPhoto || _uploadingVideo) ? null : _pickAndUploadVideo,
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
            StreamBuilder<DatabaseEvent>(
              stream: _galleryRef().onValue,
              builder: (context, snap) {
                final items = _itemsFromSnapshot(snap.data?.snapshot.value);

                if (items.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: uiBorder.withOpacity(0.85)),
                    ),
                    child: const Text(
                      'No public teaser items yet.',
                      style: TextStyle(
                        color: mainText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  );
                }

                return Column(
                  children: items.map((item) {
                    final itemId = (item['id'] ?? '').toString();
                    final type = (item['type'] ?? '').toString().trim().toLowerCase();
                    final url = (item['url'] ?? '').toString().trim();
                    final uploaderName =
                    (item['uploadedByName'] ?? '').toString().trim();
                    final createdAt = _fmtDate(item['createdAt']);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: uiBorder.withOpacity(0.85)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (type == 'video')
                            _AdminVideoPreviewCard(url: url)
                          else
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Image.network(
                                url,
                                width: double.infinity,
                                height: 220,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  height: 220,
                                  color: Colors.grey.shade200,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.broken_image_outlined),
                                ),
                              ),
                            ),
                          const SizedBox(height: 10),
                          Text(
                            type == 'video' ? 'Video' : 'Photo',
                            style: const TextStyle(
                              color: primaryBlue,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Uploaded by: ${uploaderName.isEmpty ? "Admin" : uploaderName}',
                            style: TextStyle(
                              color: mainText.withOpacity(0.75),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Created: $createdAt',
                            style: TextStyle(
                              color: mainText.withOpacity(0.65),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: const Text('Delete'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red.shade700,
                                side: BorderSide(color: Colors.red.shade200),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: itemId.isEmpty
                                  ? null
                                  : () => _deleteItem(itemId),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await controller.initialize();
      controller.setLooping(false);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _ready = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
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

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_controller!),
              IconButton(
                onPressed: () {
                  if (_controller!.value.isPlaying) {
                    _controller!.pause();
                  } else {
                    _controller!.play();
                  }
                  setState(() {});
                },
                iconSize: 54,
                color: Colors.white,
                icon: Icon(
                  _controller!.value.isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}