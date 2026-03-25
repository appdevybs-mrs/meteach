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
import '../shared/human_error.dart';
import '../shared/admin_tour_guide.dart';

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
  dynamic _publicGalleryCache;
  dynamic _usersCache;
  dynamic _learnerGalleryCache;
  bool _uploadingPhoto = false;
  bool _uploadingVideo = false;
  String? _error;
  String? _ok;

  String _adminName = 'Admin';
  String _learnerSearch = '';
  bool _onlyEmptyLearnerGalleries = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);

    _publicGalleryStream = _galleryRef().onValue.asBroadcastStream();
    _usersStream = _db.child('users').onValue.asBroadcastStream();
    _learnerGalleryStream = _db
        .child('learner_gallery')
        .onValue
        .asBroadcastStream();

    _loadAdminName();
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

  Future<String> _uploadPlatformFile(PlatformFile file) async {
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
        decoded is Map
            ? (decoded['message'] ?? 'Upload failed')
            : 'Upload failed',
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
    final itemId = newRef.key;

    await newRef.set({
      'type': type,
      'url': url,
      'uploadedByUid': adminUid,
      'uploadedByName': _adminName,
      'createdAt': ServerValue.timestamp,
    });

    await _mirrorWebsitePublicGalleryItem(
      adminUid: adminUid,
      itemId: itemId,
      type: type,
      url: url,
    );
  }

  Future<void> _mirrorWebsitePublicGalleryItem({
    required String adminUid,
    required String? itemId,
    required String type,
    required String url,
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

      await _saveGalleryItem(type: 'photo', url: url);

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
        _uploadingPhoto = false;
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

      await _saveGalleryItem(type: 'video', url: url);

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
                    label: Text(
                      _uploadingVideo ? 'Uploading...' : 'Upload Video',
                    ),
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
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (type == 'video')
                              _AdminVideoTile(url: url)
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

  Map<String, int> _parseLearnerGalleryCounts(dynamic value) {
    final counts = <String, int>{};

    if (value is! Map) return counts;

    final raw = Map<dynamic, dynamic>.from(value);

    raw.forEach((learnerUid, learnerGalleryValue) {
      if (learnerGalleryValue is Map) {
        counts[learnerUid.toString()] = learnerGalleryValue.length;
      } else {
        counts[learnerUid.toString()] = 0;
      }
    });

    return counts;
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

            final counts = _parseLearnerGalleryCounts(
              galleryValue ?? _learnerGalleryCache,
            );

            final q = _learnerSearch.trim().toLowerCase();

            final filtered = learners.where((l) {
              if (_onlyEmptyLearnerGalleries && (counts[l.uid] ?? 0) > 0) {
                return false;
              }
              if (q.isEmpty) return true;
              return l.fullName.toLowerCase().contains(q) ||
                  l.email.toLowerCase().contains(q) ||
                  l.phone1.toLowerCase().contains(q) ||
                  l.serial.toLowerCase().contains(q);
            }).toList();

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
                  ...filtered.map(
                    (learner) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _AdminLearnerGalleryCard(
                        key: ValueKey(learner.uid),
                        learner: learner,
                        itemCount: counts[learner.uid] ?? 0,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AdminLearnerGalleryScreen(
                                learnerUid: learner.uid,
                                learnerName: learner.fullName,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
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
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_public_gallery',
      title: 'المعرض العام',
      line: 'من هنا تستعرض وسائط المعرض العام ومعرض المتعلمين.',
    );

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
        bottom: TabBar(
          controller: _tab,
          labelColor: primaryBlue,
          unselectedLabelColor: primaryBlue.withValues(alpha: 0.55),
          indicatorColor: primaryBlue,
          tabs: const [
            Tab(text: 'Public Gallery'),
            Tab(text: 'Learner Galleries'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tab,
          children: [_buildPublicTeasersTab(), _buildLearnerGalleriesTab()],
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

class _AdminLearnerGalleryCard extends StatelessWidget {
  const _AdminLearnerGalleryCard({
    super.key,
    required this.learner,
    required this.itemCount,
    required this.onTap,
  });

  final _AdminLearnerLite learner;
  final int itemCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const primaryBlue = _AdminPublicGalleryScreenState.primaryBlue;
    const mainText = _AdminPublicGalleryScreenState.mainText;
    const uiBorder = _AdminPublicGalleryScreenState.uiBorder;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: primaryBlue.withValues(alpha: 0.08),
              child: Text(
                learner.fullName.trim().isNotEmpty
                    ? learner.fullName.trim()[0].toUpperCase()
                    : 'L',
                style: const TextStyle(
                  color: primaryBlue,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    learner.fullName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: primaryBlue,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (learner.serial.trim().isNotEmpty)
                    Text(
                      learner.serial,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: mainText.withValues(alpha: 0.78),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  if (learner.email.trim().isNotEmpty)
                    Text(
                      learner.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: mainText.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    )
                  else if (learner.phone1.trim().isNotEmpty)
                    Text(
                      learner.phone1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: mainText.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    'Teacher: ${learner.responsibleTeacher}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: mainText.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: primaryBlue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$itemCount item${itemCount == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: primaryBlue,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Icon(Icons.chevron_right_rounded, color: primaryBlue),
              ],
            ),
          ],
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

  Future<String> _uploadPlatformFile(PlatformFile file) async {
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
        decoded is Map
            ? (decoded['message'] ?? 'Upload failed')
            : 'Upload failed',
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

      await _saveGalleryItem(type: 'photo', url: url);

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
        _uploadingPhoto = false;
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

      await _saveGalleryItem(type: 'video', url: url);

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
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_learner_gallery',
      title: 'معرض المتعلم',
      line: 'تعرض هذه الشاشة ملفات المتعلم ويمكنك حذف او فتح اي عنصر.',
    );

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
      ),
      body: SafeArea(
        child: StreamBuilder<DatabaseEvent>(
          stream: _galleryRef().onValue,
          builder: (context, snap) {
            final items = _itemsFromSnapshot(snap.data?.snapshot.value);
            final photoCount = items
                .where(
                  (e) => (e['type'] ?? '').toString().toLowerCase() == 'photo',
                )
                .length;
            final videoCount = items
                .where(
                  (e) => (e['type'] ?? '').toString().toLowerCase() == 'video',
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
                    border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
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
                          _uploadingVideo ? 'Uploading...' : 'Upload Video',
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
                                        _AdminVideoTile(url: url)
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
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(
                                              alpha: 0.58,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      createdAt,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: mainText.withValues(alpha: 0.72),
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
  const _AdminVideoTile({required this.url});

  final String url;

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
    _init();
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

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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

    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_public_gallery_viewer',
      title: 'عارض الوسائط',
      line: 'هنا تفتح الصورة او الفيديو بالحجم الكامل مع معلومات الرفع.',
    );

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
      body: SafeArea(
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
  });

  final String itemId;
  final String type;
  final String url;
  final String uploaderName;
  final String learnerName;
  final String createdAt;
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    final isVideo = type.trim().toLowerCase() == 'video';
    final displayUploader = uploaderName.trim().isEmpty
        ? 'Admin'
        : uploaderName.trim();

    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_learner_gallery_viewer',
      title: 'عارض معرض المتعلم',
      line: 'تستطيع من هذه الشاشة معاينة الوسائط الخاصة بالمتعلم بالتفصيل.',
    );

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
      body: SafeArea(
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
                            'Learner: $learnerName',
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
    );
  }
}
