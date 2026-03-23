import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'shared/app_feedback.dart';
import 'shared/human_error.dart';
import 'services/backend_api.dart';

/// ----------------------------
/// Course Syllabus Screen
/// ----------------------------
/// Data path:
///   syllabi/{courseId}/{variantKey}
///
/// Recorded sessions:
/// - upload 1 video file
/// - upload 1 HTML material file
/// - files stored under:
///   `courses/<course-folder>/<session-folder>/`
/// - saved back into RTDB as:
///   videoUrl, materialsUrl, serverFolderPath
///

class CourseSyllabusScreen extends StatefulWidget {
  const CourseSyllabusScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
    required this.variantKey,
  });

  final String courseId;
  final String courseTitle;

  /// One of: inclass, flexible, private, recorded
  final String variantKey;

  @override
  State<CourseSyllabusScreen> createState() => _CourseSyllabusScreenState();
}

class _CourseSyllabusScreenState extends State<CourseSyllabusScreen> {
  final _db = FirebaseDatabase.instance;

  DatabaseReference get _syllabusRef =>
      _db.ref('syllabi').child(widget.courseId).child(widget.variantKey);

  bool _loading = true;
  bool _saving = false;

  List<SyllabusUnit> _units = [];
  final Map<String, bool> _unitExpanded = {};

  bool get _isRecordedVariant =>
      widget.variantKey.trim().toLowerCase() == 'recorded';

  @override
  void initState() {
    super.initState();
    _loadSyllabus();
  }

  Future<void> _loadSyllabus() async {
    setState(() => _loading = true);
    try {
      final snap = await _syllabusRef.get();
      final v = snap.value;

      if (v == null) {
        await _db
            .ref('courses')
            .child(widget.courseId)
            .child('syllabi_flags')
            .child(widget.variantKey)
            .set(false);
      }

      if (v is Map) {
        final map = Map<String, dynamic>.from(
          v.map((k, value) => MapEntry(k.toString(), value)),
        );

        final rawUnits = _asListOfMaps(map['units']);
        final units = rawUnits.map((x) => SyllabusUnit.fromMap(x)).toList();

        units.sort((a, b) => a.order.compareTo(b.order));
        for (final u in units) {
          u.sessions.sort((a, b) => a.order.compareTo(b.order));
        }

        _units = units;
        _ensureSessionNumbers();
      } else {
        _units = [];
      }
    } catch (_) {
      _units = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalSessions =>
      _units.fold<int>(0, (sum, u) => sum + u.sessions.length);

  void _ensureSessionNumbers() {
    _units.sort((a, b) => a.order.compareTo(b.order));
    for (final u in _units) {
      u.sessions.sort((a, b) => a.order.compareTo(b.order));
    }

    int n = 1;
    for (int ui = 0; ui < _units.length; ui++) {
      final u = _units[ui];
      final sessions = <SyllabusSession>[];

      for (int si = 0; si < u.sessions.length; si++) {
        final s = u.sessions[si];
        sessions.add(s.copyWith(sessionNumber: n));
        n++;
      }

      _units[ui] = u.copyWith(sessions: sessions);
    }
  }

  Future<Map<String, dynamic>> _loadCourseMeta() async {
    final snap = await _db.ref('courses').child(widget.courseId).get();
    if (snap.value is Map) {
      return Map<String, dynamic>.from(snap.value as Map);
    }
    return <String, dynamic>{};
  }

  Future<String> _loadCourseFolderName() async {
    final courseMap = await _loadCourseMeta();
    final courseCode = (courseMap['course_code'] ?? '').toString().trim();
    final courseTitle = (courseMap['title'] ?? widget.courseTitle)
        .toString()
        .trim();

    return _SyllabusServerStorage.buildCourseFolderName(
      courseCode: courseCode,
      courseTitle: courseTitle,
    );
  }

  Future<void> _saveSyllabus() async {
    setState(() => _saving = true);
    try {
      for (int i = 0; i < _units.length; i++) {
        _units[i] = _units[i].copyWith(order: i + 1);
        for (int j = 0; j < _units[i].sessions.length; j++) {
          _units[i].sessions[j] = _units[i].sessions[j].copyWith(order: j + 1);
        }
      }

      _ensureSessionNumbers();

      final courseMap = await _loadCourseMeta();
      final courseCode = (courseMap['course_code'] ?? '').toString();
      final courseTitle = (courseMap['title'] ?? widget.courseTitle).toString();
      final courseDuration = (courseMap['duration'] ?? '').toString();

      final payload = {
        'courseId': widget.courseId,
        'courseCode': courseCode,
        'title': courseTitle,
        'duration': courseDuration,
        'updatedAt': ServerValue.timestamp,
        'units': _units
            .map(
              (u) => u.toMap(
                includeRecordedExtras: _isRecordedVariant,
                includeOnlineExtras: !_isRecordedVariant,
              ),
            )
            .toList(),
      };

      await _syllabusRef.set(payload);

      await _db
          .ref('courses')
          .child(widget.courseId)
          .child('syllabi_flags')
          .child(widget.variantKey)
          .set(true);

      if (!mounted) return;
      AppToast.show(context, 'Syllabus saved', type: AppToastType.success);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not save changes.'),
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteRecordedAssetsIfNeeded(SyllabusSession session) async {
    if (!_isRecordedVariant) return;

    final folderPath = _resolveServerFolderPath(session);
    if (folderPath.isEmpty) return;

    try {
      await _SyllabusServerStorage.deletePath(
        root: 'courses',
        path: folderPath,
      );
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('item not found')) return;
      rethrow;
    }
  }

  String _resolveServerFolderPath(SyllabusSession session) {
    final stored = session.serverFolderPath.trim();
    if (stored.isNotEmpty) return stored;

    final fromVideo = _SyllabusServerStorage.extractFolderPathFromUrl(
      session.videoUrl,
    );
    if (fromVideo.isNotEmpty) return fromVideo;

    final fromMaterials = _SyllabusServerStorage.extractFolderPathFromUrl(
      session.materialsUrl,
    );
    if (fromMaterials.isNotEmpty) return fromMaterials;

    return '';
  }

  // ----------------------------
  // Unit actions
  // ----------------------------

  Future<void> _addUnit() async {
    final res = await showModalBottomSheet<_UnitDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UnitEditorSheet(
        title: 'Add Unit',
        initial: _UnitDraft(title: '', otherTitle: '', description: ''),
      ),
    );

    if (res == null) return;

    final newUnit = SyllabusUnit(
      id: _newId(),
      title: res.title.trim(),
      otherTitle: res.otherTitle.trim(),
      description: res.description.trim(),
      order: _units.length + 1,
      sessions: [],
    );

    setState(() => _units = [..._units, newUnit]);
  }

  Future<void> _editUnit(int unitIndex) async {
    final u = _units[unitIndex];
    final res = await showModalBottomSheet<_UnitDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UnitEditorSheet(
        title: 'Edit Unit',
        initial: _UnitDraft(
          title: u.title,
          otherTitle: u.otherTitle,
          description: u.description,
        ),
      ),
    );

    if (res == null) return;

    setState(() {
      final updated = u.copyWith(
        title: res.title.trim(),
        otherTitle: res.otherTitle.trim(),
        description: res.description.trim(),
      );
      final next = [..._units];
      next[unitIndex] = updated;
      _units = next;
    });
  }

  Future<void> _deleteUnit(int unitIndex) async {
    final ok = await _confirm(
      title: 'Delete Unit?',
      message: 'This will delete the unit and all its sessions.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    try {
      final unit = _units[unitIndex];
      if (_isRecordedVariant) {
        for (final session in unit.sessions) {
          await _deleteRecordedAssetsIfNeeded(session);
        }
      }

      setState(() {
        final next = [..._units]..removeAt(unitIndex);
        _units = next;
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not delete item.'),
        type: AppToastType.error,
      );
    }
  }

  void _moveUnit(int from, int to) {
    setState(() {
      final next = [..._units];
      final item = next.removeAt(from);
      next.insert(to, item);
      _units = next;
    });
  }

  // ----------------------------
  // Session actions
  // ----------------------------

  Future<void> _addSession(int unitIndex) async {
    final courseFolderName = _isRecordedVariant
        ? await _loadCourseFolderName()
        : '';

    final res = await showModalBottomSheet<_SessionDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionEditorSheet(
        title: 'Add Session',
        isRecorded: _isRecordedVariant,
        courseFolderName: courseFolderName,
        suggestedSessionNumber: _totalSessions + 1,
        initial: _SessionDraft(
          title: '',
          skillType: SkillType.listening,
          objective: '',
          content: '',
          homework: '',
          durationMinutes: 45,
          videoUrl: '',
          videoThumbnailUrl: '',
          materialsUrl: '',
          serverFolderPath: '',
        ),
      ),
    );

    if (res == null) return;

    final unit = _units[unitIndex];
    final newSession = SyllabusSession(
      id: _newId(),
      title: res.title.trim(),
      skillType: res.skillType,
      objective: res.objective.trim(),
      content: res.content.trim(),
      homework: res.homework.trim(),
      durationMinutes: res.durationMinutes,
      order: unit.sessions.length + 1,
      sessionNumber: _totalSessions + 1,
      videoUrl: res.videoUrl.trim(),
      videoThumbnailUrl: res.videoThumbnailUrl.trim(),
      materialsUrl: res.materialsUrl.trim(),
      serverFolderPath: res.serverFolderPath.trim(),
    );

    setState(() {
      final next = [..._units];
      next[unitIndex] = unit.copyWith(sessions: [...unit.sessions, newSession]);
      _units = next;
    });

    if (mounted) {
      AppToast.show(
        context,
        'Session added. Tap Save to apply in RTDB.',
        type: AppToastType.success,
      );
    }
  }

  Future<void> _editSession(int unitIndex, int sessionIndex) async {
    final unit = _units[unitIndex];
    final s = unit.sessions[sessionIndex];
    final courseFolderName = _isRecordedVariant
        ? await _loadCourseFolderName()
        : '';

    final res = await showModalBottomSheet<_SessionDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionEditorSheet(
        title: 'Edit Session',
        isRecorded: _isRecordedVariant,
        courseFolderName: courseFolderName,
        suggestedSessionNumber: s.sessionNumber > 0
            ? s.sessionNumber
            : (sessionIndex + 1),
        initial: _SessionDraft(
          title: s.title,
          skillType: s.skillType,
          objective: s.objective,
          content: s.content,
          homework: s.homework,
          durationMinutes: s.durationMinutes,
          videoUrl: s.videoUrl,
          videoThumbnailUrl: s.videoThumbnailUrl,
          materialsUrl: s.materialsUrl,
          serverFolderPath: _resolveServerFolderPath(s),
        ),
      ),
    );

    if (res == null) return;

    final updated = s.copyWith(
      title: res.title.trim(),
      skillType: res.skillType,
      objective: res.objective.trim(),
      content: res.content.trim(),
      homework: res.homework.trim(),
      durationMinutes: res.durationMinutes,
      videoUrl: res.videoUrl.trim(),
      videoThumbnailUrl: res.videoThumbnailUrl.trim(),
      materialsUrl: res.materialsUrl.trim(),
      serverFolderPath: res.serverFolderPath.trim(),
    );

    setState(() {
      final sessions = [...unit.sessions];
      sessions[sessionIndex] = updated;
      final nextUnits = [..._units];
      nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      _units = nextUnits;
    });

    if (mounted) {
      AppToast.show(
        context,
        'Session updated. Tap Save to apply in RTDB.',
        type: AppToastType.success,
      );
    }
  }

  Future<void> _deleteSession(int unitIndex, int sessionIndex) async {
    final ok = await _confirm(
      title: 'Delete Session?',
      message: 'This will delete this session.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    try {
      final unit = _units[unitIndex];
      final session = unit.sessions[sessionIndex];

      if (_isRecordedVariant) {
        await _deleteRecordedAssetsIfNeeded(session);
      }

      setState(() {
        final sessions = [...unit.sessions]..removeAt(sessionIndex);
        final nextUnits = [..._units];
        nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
        _units = nextUnits;
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not delete item.'),
        type: AppToastType.error,
      );
    }
  }

  void _moveSession(int unitIndex, int from, int to) {
    setState(() {
      final unit = _units[unitIndex];
      final sessions = [...unit.sessions];
      final item = sessions.removeAt(from);
      sessions.insert(to, item);

      final nextUnits = [..._units];
      nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      _units = nextUnits;
    });
  }

  // ----------------------------
  // UI
  // ----------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Syllabus',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: Color(0xFF1A2B48),
              ),
            ),
            Text(
              '${widget.courseTitle} • ${_variantLabel(widget.variantKey)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.black.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        iconTheme: const IconThemeData(color: Color(0xFF1A2B48)),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _loadSyllabus,
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: FilledButton.icon(
              onPressed: (_saving || _loading) ? null : _saveSyllabus,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _addUnit,
        icon: const Icon(Icons.add),
        label: const Text('Add Unit'),
      ),
      body: _loading
          ? const Center(
              child: BrandedInlineLoader(message: 'Loading syllabus...'),
            )
          : _units.isEmpty
          ? _EmptyState(onAddUnit: _addUnit, courseTitle: widget.courseTitle)
          : Column(
              children: [
                _HeaderStats(units: _units.length, sessions: _totalSessions),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                    itemCount: _units.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      _moveUnit(oldIndex, newIndex);
                    },
                    itemBuilder: (context, unitIndex) {
                      final unit = _units[unitIndex];
                      return _UnitCard(
                        key: ValueKey(unit.id),
                        unitNumber: unitIndex + 1,
                        unit: unit,
                        isExpanded: _isExpanded(unit.id),
                        onToggleExpanded: () => _toggleExpanded(unit.id),
                        onEdit: () => _editUnit(unitIndex),
                        onDelete: () => _deleteUnit(unitIndex),
                        onAddSession: () => _addSession(unitIndex),
                        onReorderSession: (oldI, newI) {
                          if (newI > oldI) newI -= 1;
                          _moveSession(unitIndex, oldI, newI);
                        },
                        onEditSession: (sessionIndex) =>
                            _editSession(unitIndex, sessionIndex),
                        onDeleteSession: (sessionIndex) =>
                            _deleteSession(unitIndex, sessionIndex),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    bool danger = false,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger ? Colors.red : null,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmText),
              ),
            ],
          ),
        )) ??
        false;
  }

  List<Map<String, dynamic>> _asListOfMaps(dynamic node) {
    final out = <Map<String, dynamic>>[];

    if (node is List) {
      for (final x in node) {
        if (x is Map) {
          out.add(Map<String, dynamic>.from(x));
        }
      }
      return out;
    }

    if (node is Map) {
      final mm = Map<dynamic, dynamic>.from(node);
      for (final entry in mm.entries) {
        final v = entry.value;
        if (v is Map) {
          out.add(Map<String, dynamic>.from(v));
        }
      }
      return out;
    }

    return out;
  }

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  bool _isExpanded(String unitId) => _unitExpanded[unitId] ?? true;

  String _variantLabel(String key) {
    switch (key.trim().toLowerCase()) {
      case 'recorded':
        return 'Recorded';
      case 'private':
        return 'Private';
      case 'inclass':
        return 'In-Class';
      case 'flexible':
        return 'Flexible';
      default:
        return key;
    }
  }

  void _toggleExpanded(String unitId) {
    setState(() => _unitExpanded[unitId] = !(_unitExpanded[unitId] ?? true));
  }
}

class _SyllabusServerStorage {
  static const String uploadUrl =
      'https://www.yourbridgeschool.com/app/secure/upload_file_secure.php';
  static const String deleteUrl =
      'https://www.yourbridgeschool.com/app/secure/delete_item_secure.php';

  static void _debug(String message) {
    // no-op in production build
  }

  static String sanitizeSegment(String value, {String fallback = 'item'}) {
    final cleaned = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');

    if (cleaned.isEmpty) return fallback;
    return cleaned;
  }

  static String buildCourseFolderName({
    required String courseCode,
    required String courseTitle,
  }) {
    final code = sanitizeSegment(courseCode, fallback: '');
    final title = sanitizeSegment(courseTitle, fallback: 'course');

    if (code.isNotEmpty) {
      return '${code}_$title';
    }
    return title;
  }

  static String buildSessionFolderName({
    required int sessionNumber,
    required String sessionTitle,
  }) {
    final padded = sessionNumber.toString().padLeft(2, '0');
    final title = sanitizeSegment(sessionTitle, fallback: 'session_$padded');
    return 'session_${padded}_$title';
  }

  static String buildCustomBaseName({
    required int sessionNumber,
    required String suffix,
  }) {
    final padded = sessionNumber.toString().padLeft(2, '0');
    return 'session_${padded}_$suffix';
  }

  static Future<String> uploadPlatformFile({
    required PlatformFile file,
    required String root,
    required String path,
    required String customName,
    void Function(double progress)? onProgress,
  }) async {
    final token = await BackendApi.authToken();
    final authFields = await BackendApi.authFormFields();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    _debug(
      'upload start root=$root path=$path customName=$customName '
      'file=${file.name} uidPresent=${uid.isNotEmpty} tokenLen=${token.length}',
    );

    final uploadUri = await BackendApi.withAuthQuery(Uri.parse(uploadUrl));

    final req = http.MultipartRequest('POST', uploadUri);
    req.headers.addAll(await BackendApi.authHeaders());
    req.fields.addAll(authFields);
    req.fields['root'] = root;
    req.fields['path'] = path;
    req.fields['custom_name'] = customName;

    if (file.path != null && file.path!.isNotEmpty) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path!,
          filename: file.name,
        ),
      );
    } else {
      final Uint8List? bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file');
      }

      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    }

    final byteStream = req.finalize();
    final totalBytes = req.contentLength;
    int sent = 0;
    final trackedStream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          if (onProgress != null && totalBytes > 0) {
            final p = (sent / totalBytes).clamp(0.0, 1.0);
            onProgress(p);
          }
          sink.add(chunk);
        },
      ),
    );

    final streamedReq = http.StreamedRequest(req.method, req.url)
      ..headers.addAll(req.headers)
      ..contentLength = totalBytes;

    await trackedStream.pipe(streamedReq.sink);
    final streamed = await streamedReq.send();
    final response = await http.Response.fromStream(streamed);
    final raw = response.body.trim();

    _debug(
      'upload response status=${response.statusCode} '
      'bodyPreview=${raw.length > 200 ? '${raw.substring(0, 200)}...' : raw}',
    );

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
        _debug('upload failed: success=true but url is empty');
        throw Exception('Upload succeeded but no URL returned');
      }
      _debug('upload success url=$url');
      onProgress?.call(1.0);
      return url;
    }

    _debug('upload failed message=${data['message']}');
    throw Exception((data['message'] ?? 'Upload failed').toString());
  }

  static Future<void> deletePath({
    required String root,
    required String path,
  }) async {
    final token = await BackendApi.authToken();
    final authFields = await BackendApi.authFormFields();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final headers = await BackendApi.authHeaders();

    _debug(
      'delete start root=$root path=$path '
      'uidPresent=${uid.isNotEmpty} tokenLen=${token.length}',
    );

    final deleteUri = await BackendApi.withAuthQuery(Uri.parse(deleteUrl));

    final r = await http.post(
      deleteUri,
      headers: headers,
      body: {'root': root, 'path': path, ...authFields},
    );

    final raw = r.body.trim();
    _debug(
      'delete response status=${r.statusCode} '
      'bodyPreview=${raw.length > 200 ? '${raw.substring(0, 200)}...' : raw}',
    );
    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.\n$raw');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid delete response');
    }

    if (data['success'] == true) return;

    _debug('delete failed message=${data['message']}');
    throw Exception((data['message'] ?? 'Delete failed').toString());
  }

  static String extractFolderPathFromUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';

    try {
      final uri = Uri.parse(trimmed);
      final segments = uri.pathSegments;
      final coursesIndex = segments.indexOf('courses');
      if (coursesIndex == -1 || segments.length <= coursesIndex + 2) {
        return '';
      }

      final folderSegments = segments.sublist(coursesIndex + 1);
      if (folderSegments.length < 2) return '';
      final withoutFile = folderSegments.sublist(0, folderSegments.length - 1);
      return withoutFile.join('/');
    } catch (_) {
      return '';
    }
  }

  static String extractRelativePathFromUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';

    try {
      final uri = Uri.parse(trimmed);
      final segments = uri.pathSegments;
      final coursesIndex = segments.indexOf('courses');
      if (coursesIndex == -1 || segments.length <= coursesIndex + 1) {
        return '';
      }

      final relSegments = segments.sublist(coursesIndex + 1);
      return relSegments.join('/');
    } catch (_) {
      return '';
    }
  }
}

/// ----------------------------
/// Widgets
/// ----------------------------

class _HeaderStats extends StatelessWidget {
  const _HeaderStats({required this.units, required this.sessions});

  final int units;
  final int sessions;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          _Pill(label: '$units Units'),
          const SizedBox(width: 8),
          _Pill(label: '$sessions Sessions'),
          const Spacer(),
          Text(
            'Drag units to reorder',
            style: TextStyle(color: Colors.black.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAddUnit, required this.courseTitle});

  final VoidCallback onAddUnit;
  final String courseTitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.menu_book_outlined,
                size: 42,
                color: Color(0xFF1A2B48),
              ),
              const SizedBox(height: 10),
              const Text(
                'No syllabus yet',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: Color(0xFF1A2B48),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Create the syllabus for "$courseTitle" by adding your first unit.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black.withValues(alpha: 0.7)),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onAddUnit,
                icon: const Icon(Icons.add),
                label: const Text('Add Unit'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnitCard extends StatelessWidget {
  const _UnitCard({
    super.key,
    required this.unitNumber,
    required this.unit,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onEdit,
    required this.onDelete,
    required this.onAddSession,
    required this.onReorderSession,
    required this.onEditSession,
    required this.onDeleteSession,
  });

  final int unitNumber;
  final SyllabusUnit unit;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onAddSession;
  final void Function(int oldIndex, int newIndex) onReorderSession;
  final void Function(int sessionIndex) onEditSession;
  final void Function(int sessionIndex) onDeleteSession;

  @override
  Widget build(BuildContext context) {
    final baseTitle = unit.title.trim().isNotEmpty
        ? unit.title.trim()
        : unit.description.trim();

    final title = unit.otherTitle.trim().isEmpty
        ? baseTitle
        : '${baseTitle.isEmpty ? 'Unit' : baseTitle} (${unit.otherTitle})';

    return Card(
      key: key,
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2B48).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _Pill(label: 'Unit $unitNumber'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title.isEmpty ? '(Untitled unit)' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A2B48),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: isExpanded ? 'Collapse' : 'Expand',
                    onPressed: onToggleExpanded,
                    icon: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') onEdit();
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit unit')),
                      PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete unit'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (unit.description.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  unit.description,
                  style: TextStyle(color: Colors.black.withValues(alpha: 0.65)),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  '${unit.sessions.length} sessions',
                  style: TextStyle(color: Colors.black.withValues(alpha: 0.55)),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onAddSession,
                  icon: const Icon(Icons.add),
                  label: const Text('Add session'),
                ),
              ],
            ),
            if (!isExpanded)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Collapsed • ${unit.sessions.length} sessions',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              )
            else if (unit.sessions.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'No sessions yet. Add your first session.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: unit.sessions.length,
                onReorder: onReorderSession,
                itemBuilder: (context, i) {
                  final s = unit.sessions[i];
                  return ListTile(
                    key: ValueKey(s.id),
                    leading: ReorderableDragStartListener(
                      index: i,
                      child: const Icon(Icons.drag_handle),
                    ),
                    title: Text(
                      'Session ${s.sessionNumber <= 0 ? (i + 1) : s.sessionNumber} • ${s.title.isEmpty ? '(Untitled session)' : s.title}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${s.skillType.label} • ${s.durationMinutes} min\nObjective: ${s.objective.isEmpty ? '(missing)' : s.objective}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') onEditSession(i);
                        if (v == 'delete') onDeleteSession(i);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuDivider(),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF1A2B48),
        ),
      ),
    );
  }
}

/// ----------------------------
/// Bottom sheets (editors)
/// ----------------------------

class _UnitDraft {
  _UnitDraft({
    required this.title,
    required this.otherTitle,
    required this.description,
  });

  final String title;
  final String otherTitle;
  final String description;
}

class _UnitEditorSheet extends StatefulWidget {
  const _UnitEditorSheet({required this.title, required this.initial});

  final String title;
  final _UnitDraft initial;

  @override
  State<_UnitEditorSheet> createState() => _UnitEditorSheetState();
}

class _UnitEditorSheetState extends State<_UnitEditorSheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController titleC;
  late final TextEditingController otherTitleC;
  late final TextEditingController descC;

  @override
  void initState() {
    super.initState();
    titleC = TextEditingController(text: widget.initial.title);
    otherTitleC = TextEditingController(text: widget.initial.otherTitle);
    descC = TextEditingController(text: widget.initial.description);
  }

  @override
  void dispose() {
    titleC.dispose();
    otherTitleC.dispose();
    descC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: titleC,
                  decoration: const InputDecoration(
                    labelText: 'Unit name *',
                    hintText: 'Example: Unit 1: Introductions',
                    filled: true,
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: otherTitleC,
                  decoration: const InputDecoration(
                    labelText: 'Other name (in brackets)',
                    hintText: 'Example: Theme / Module / Part',
                    filled: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: descC,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Unit description',
                    hintText: 'Optional description',
                    filled: true,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (!_form.currentState!.validate()) return;
                      Navigator.pop(
                        context,
                        _UnitDraft(
                          title: titleC.text,
                          otherTitle: otherTitleC.text,
                          description: descC.text,
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Done'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDraft {
  _SessionDraft({
    required this.title,
    required this.skillType,
    required this.objective,
    required this.content,
    required this.homework,
    required this.durationMinutes,
    this.videoUrl = '',
    this.videoThumbnailUrl = '',
    this.materialsUrl = '',
    this.serverFolderPath = '',
  });

  final String title;
  final SkillType skillType;
  final String objective;
  final String content;
  final String homework;
  final int durationMinutes;
  final String videoUrl;
  final String videoThumbnailUrl;
  final String materialsUrl;
  final String serverFolderPath;
}

class _SessionEditorSheet extends StatefulWidget {
  const _SessionEditorSheet({
    required this.title,
    required this.initial,
    required this.isRecorded,
    required this.courseFolderName,
    required this.suggestedSessionNumber,
  });

  final String title;
  final _SessionDraft initial;
  final bool isRecorded;
  final String courseFolderName;
  final int suggestedSessionNumber;

  @override
  State<_SessionEditorSheet> createState() => _SessionEditorSheetState();
}

class _SessionEditorSheetState extends State<_SessionEditorSheet> {
  void _debug(String message) {
    // no-op in production build
  }

  String _fileNameFromUrl(String url) {
    final t = url.trim();
    if (t.isEmpty) return '';
    try {
      final uri = Uri.parse(t);
      if (uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.last;
      }
    } catch (_) {}
    return t.split('/').last;
  }

  String? _inlineError;
  final _form = GlobalKey<FormState>();

  late final TextEditingController titleC;
  late final TextEditingController objectiveC;
  late final TextEditingController contentC;
  late final TextEditingController homeworkC;
  late final TextEditingController durationC;
  late final TextEditingController videoUrlC;
  late final TextEditingController videoThumbC;
  late final TextEditingController materialsUrlC;

  SkillType _skill = SkillType.listening;

  bool _uploadingVideo = false;
  bool _uploadingMaterials = false;
  double _videoUploadProgress = 0;
  double _materialsUploadProgress = 0;
  bool _recordedAssetFlowBusy = false;
  late String _serverFolderPath;

  bool get _recordedAssetsBusy =>
      _recordedAssetFlowBusy || _uploadingVideo || _uploadingMaterials;

  bool get _hasInitialRecordedAssets =>
      widget.initial.serverFolderPath.trim().isNotEmpty ||
      widget.initial.videoUrl.trim().isNotEmpty ||
      widget.initial.materialsUrl.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    titleC = TextEditingController(text: widget.initial.title);
    objectiveC = TextEditingController(text: widget.initial.objective);
    contentC = TextEditingController(text: widget.initial.content);
    homeworkC = TextEditingController(text: widget.initial.homework);
    durationC = TextEditingController(
      text: widget.initial.durationMinutes.toString(),
    );
    videoUrlC = TextEditingController(text: widget.initial.videoUrl);
    videoThumbC = TextEditingController(text: widget.initial.videoThumbnailUrl);
    materialsUrlC = TextEditingController(text: widget.initial.materialsUrl);
    _serverFolderPath = widget.initial.serverFolderPath.trim();
    _skill = widget.initial.skillType;
  }

  @override
  void dispose() {
    titleC.dispose();
    objectiveC.dispose();
    contentC.dispose();
    homeworkC.dispose();
    durationC.dispose();
    videoUrlC.dispose();
    videoThumbC.dispose();
    materialsUrlC.dispose();
    super.dispose();
  }

  void _showInlineError(String message) {
    _debug('inlineError=$message');
    if (!mounted) return;
    setState(() => _inlineError = message);
  }

  void _clearInlineError() {
    if (!mounted) return;
    if (_inlineError != null) {
      setState(() => _inlineError = null);
    }
  }

  Future<bool> _confirmClearAsset({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmText),
              ),
            ],
          ),
        )) ??
        false;
  }

  String _resolvedSessionFolderPath() {
    if (_serverFolderPath.trim().isNotEmpty) return _serverFolderPath.trim();

    final sessionFolder = _SyllabusServerStorage.buildSessionFolderName(
      sessionNumber: widget.suggestedSessionNumber,
      sessionTitle: titleC.text.trim(),
    );

    _serverFolderPath = '${widget.courseFolderName}/$sessionFolder';
    return _serverFolderPath;
  }

  Future<void> _clearVideoOnly() async {
    if (_recordedAssetsBusy) {
      _debug('clearVideo ignored busy=true');
      return;
    }

    _debug(
      'clearVideo requested hasVideo=${videoUrlC.text.trim().isNotEmpty} '
      'hasThumb=${videoThumbC.text.trim().isNotEmpty}',
    );
    if (videoUrlC.text.trim().isEmpty && videoThumbC.text.trim().isEmpty) {
      _debug('clearVideo skipped (nothing to clear)');
      return;
    }

    final ok = await _confirmClearAsset(
      title: 'Remove video?',
      message:
          'This will remove the video from this session. Learners will no longer see the video button.',
      confirmText: 'Remove',
    );

    if (!ok) {
      _debug('clearVideo cancelled by user');
      return;
    }

    final oldVideoUrl = videoUrlC.text.trim();
    final oldThumbUrl = videoThumbC.text.trim();

    if (mounted) {
      setState(() => _recordedAssetFlowBusy = true);
    }

    try {
      if (oldVideoUrl.isNotEmpty) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
          oldVideoUrl,
        );
        if (rel.isNotEmpty) {
          try {
            await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
            _debug('clearVideo removed old video relPath=$rel');
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('item not found')) {
              rethrow;
            }
            _debug('clearVideo old video already missing relPath=$rel');
          }
        }
      }

      if (oldThumbUrl.isNotEmpty) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
          oldThumbUrl,
        );
        if (rel.isNotEmpty) {
          try {
            await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
            _debug('clearVideo removed old thumbnail relPath=$rel');
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('item not found')) {
              rethrow;
            }
            _debug('clearVideo old thumbnail already missing relPath=$rel');
          }
        }
      }

      if (!mounted) return;
      setState(() {
        videoUrlC.clear();
        videoThumbC.clear();
        _inlineError = null;
      });
      _debug('clearVideo completed (server + local)');
    } catch (e) {
      _debug('clearVideo error=$e');
      _showInlineError('Could not remove old video: $e');
    } finally {
      if (mounted) {
        setState(() => _recordedAssetFlowBusy = false);
      }
    }
  }

  Future<void> _clearHtmlOnly() async {
    if (_recordedAssetsBusy) {
      _debug('clearHtml ignored busy=true');
      return;
    }

    _debug(
      'clearHtml requested hasHtml=${materialsUrlC.text.trim().isNotEmpty}',
    );
    if (materialsUrlC.text.trim().isEmpty) {
      _debug('clearHtml skipped (nothing to clear)');
      return;
    }

    final ok = await _confirmClearAsset(
      title: 'Remove HTML?',
      message:
          'This will remove the HTML materials from this session. Learners will no longer see the read button.',
      confirmText: 'Remove',
    );

    if (!ok) {
      _debug('clearHtml cancelled by user');
      return;
    }

    final oldHtmlUrl = materialsUrlC.text.trim();

    if (mounted) {
      setState(() => _recordedAssetFlowBusy = true);
    }

    try {
      if (oldHtmlUrl.isNotEmpty) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
          oldHtmlUrl,
        );
        if (rel.isNotEmpty) {
          try {
            await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
            _debug('clearHtml removed old html relPath=$rel');
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('item not found')) {
              rethrow;
            }
            _debug('clearHtml old html already missing relPath=$rel');
          }
        }
      }

      if (!mounted) return;
      setState(() {
        materialsUrlC.clear();
        _inlineError = null;
      });
      _debug('clearHtml completed (server + local)');
    } catch (e) {
      _debug('clearHtml error=$e');
      _showInlineError('Could not remove old HTML: $e');
    } finally {
      if (mounted) {
        setState(() => _recordedAssetFlowBusy = false);
      }
    }
  }

  Future<bool> _prepareRecordedReplacementIfNeeded() async {
    _debug(
      'prepareReplacement start isRecorded=${widget.isRecorded} '
      'hasInitialAssets=$_hasInitialRecordedAssets '
      'busy=$_recordedAssetsBusy',
    );
    if (!widget.isRecorded) {
      _debug('prepareReplacement skipped (not recorded)');
      return true;
    }
    final folderPath = _resolvedSessionFolderPath();
    _debug(
      'prepareReplacement ready folderPath=$folderPath '
      'hasInitialAssets=$_hasInitialRecordedAssets',
    );

    return true;
  }

  Future<void> _pickAndUploadVideo() async {
    if (_recordedAssetsBusy) {
      _debug('video upload ignored busy=true');
      return;
    }

    final title = titleC.text.trim();
    _debug('video upload tapped titleEmpty=${title.isEmpty}');
    if (title.isEmpty) {
      _showInlineError('Enter session title first.');
      return;
    }

    if (mounted) {
      setState(() => _recordedAssetFlowBusy = true);
    }

    try {
      _clearInlineError();

      final oldVideoUrl = videoUrlC.text.trim();
      final oldThumbUrl = videoThumbC.text.trim();

      final prepared = await _prepareRecordedReplacementIfNeeded();
      if (!prepared) {
        _debug('video upload aborted by prepareReplacement=false');
        return;
      }

      setState(() => _uploadingVideo = true);
      setState(() => _videoUploadProgress = 0);

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        type: FileType.video,
      );

      if (result == null || result.files.isEmpty) {
        _debug('video upload cancelled at file picker');
        return;
      }

      final file = result.files.single;
      final path = _resolvedSessionFolderPath();
      _debug(
        'video upload picked file=${file.name} bytes=${file.size} path=$path',
      );

      final url = await _SyllabusServerStorage.uploadPlatformFile(
        file: file,
        root: 'courses',
        path: path,
        customName: _SyllabusServerStorage.buildCustomBaseName(
          sessionNumber: widget.suggestedSessionNumber,
          suffix: 'video',
        ),
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _videoUploadProgress = p);
        },
      );

      if (!mounted) return;
      setState(() {
        videoUrlC.text = url;
        videoThumbC.clear();
        _inlineError = null;
      });
      _debug('video upload success url=$url');

      if (oldVideoUrl.isNotEmpty && oldVideoUrl != url) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
          oldVideoUrl,
        );
        if (rel.isNotEmpty) {
          try {
            await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
            _debug('video replace removed old video relPath=$rel');
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('item not found')) {
              _debug('video replace could not remove old video error=$e');
            }
          }
        }
      }

      if (oldThumbUrl.isNotEmpty) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
          oldThumbUrl,
        );
        if (rel.isNotEmpty) {
          try {
            await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
            _debug('video replace removed old thumbnail relPath=$rel');
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('item not found')) {
              _debug('video replace could not remove old thumbnail error=$e');
            }
          }
        }
      }
    } catch (e) {
      _debug('video upload error=$e');
      _showInlineError('Video upload failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _uploadingVideo = false;
          _videoUploadProgress = 0;
          _recordedAssetFlowBusy = false;
        });
      }
      _debug(
        'video upload finished uploading=$_uploadingVideo busy=$_recordedAssetFlowBusy',
      );
    }
  }

  Future<void> _pickAndUploadHtml() async {
    if (_recordedAssetsBusy) {
      _debug('html upload ignored busy=true');
      return;
    }

    final title = titleC.text.trim();
    _debug('html upload tapped titleEmpty=${title.isEmpty}');
    if (title.isEmpty) {
      _showInlineError('Enter session title first.');
      return;
    }

    if (mounted) {
      setState(() => _recordedAssetFlowBusy = true);
    }

    try {
      _clearInlineError();

      final oldHtmlUrl = materialsUrlC.text.trim();

      final prepared = await _prepareRecordedReplacementIfNeeded();
      if (!prepared) {
        _debug('html upload aborted by prepareReplacement=false');
        return;
      }

      setState(() => _uploadingMaterials = true);
      setState(() => _materialsUploadProgress = 0);

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const ['html', 'htm'],
      );

      if (result == null || result.files.isEmpty) {
        _debug('html upload cancelled at file picker');
        return;
      }

      final file = result.files.single;
      final path = _resolvedSessionFolderPath();
      _debug(
        'html upload picked file=${file.name} bytes=${file.size} path=$path',
      );

      final url = await _SyllabusServerStorage.uploadPlatformFile(
        file: file,
        root: 'courses',
        path: path,
        customName: _SyllabusServerStorage.buildCustomBaseName(
          sessionNumber: widget.suggestedSessionNumber,
          suffix: 'materials',
        ),
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _materialsUploadProgress = p);
        },
      );

      if (!mounted) return;
      setState(() {
        materialsUrlC.text = url;
        _inlineError = null;
      });
      _debug('html upload success url=$url');

      if (oldHtmlUrl.isNotEmpty && oldHtmlUrl != url) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
          oldHtmlUrl,
        );
        if (rel.isNotEmpty) {
          try {
            await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
            _debug('html replace removed old html relPath=$rel');
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('item not found')) {
              _debug('html replace could not remove old html error=$e');
            }
          }
        }
      }
    } catch (e) {
      _debug('html upload error=$e');
      _showInlineError('HTML upload failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _uploadingMaterials = false;
          _materialsUploadProgress = 0;
          _recordedAssetFlowBusy = false;
        });
      }
      _debug(
        'html upload finished uploading=$_uploadingMaterials busy=$_recordedAssetFlowBusy',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                if (_inlineError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      border: Border.all(color: Colors.red.shade200),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _inlineError!,
                      style: TextStyle(
                        color: Colors.red.shade800,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: titleC,
                  decoration: const InputDecoration(
                    labelText: 'Session title *',
                    hintText: 'Example: Listening – Greetings',
                    filled: true,
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                  onChanged: (_) => _clearInlineError(),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<SkillType>(
                  initialValue: _skill,
                  items: SkillType.values
                      .map(
                        (s) => DropdownMenuItem(value: s, child: Text(s.label)),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _skill = v ?? _skill),
                  decoration: const InputDecoration(
                    labelText: 'Skill type',
                    filled: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: objectiveC,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Lesson objective *',
                    hintText:
                        'By the end of this session, students will be able to…',
                    filled: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Objective is required'
                      : null,
                  onChanged: (_) => _clearInlineError(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: durationC,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Estimated duration (minutes)',
                    hintText: 'Example: 45',
                    filled: true,
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Required';
                    final n = int.tryParse(t);
                    if (n == null) return 'Must be a number';
                    if (n <= 0) return 'Must be > 0';
                    return null;
                  },
                  onChanged: (_) => _clearInlineError(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: contentC,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Lesson content',
                    hintText:
                        'Optional: instructions, links, text, activities…',
                    filled: true,
                  ),
                  onChanged: (_) => _clearInlineError(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: homeworkC,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Homework / Quiz (optional)',
                    hintText: 'Optional: questions, tasks, exercises…',
                    filled: true,
                  ),
                  onChanged: (_) => _clearInlineError(),
                ),
                if (widget.isRecorded) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Recorded assets',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Video file',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        if (videoUrlC.text.trim().isNotEmpty)
                          Text(
                            _fileNameFromUrl(videoUrlC.text.trim()),
                            style: TextStyle(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        else
                          const Text(
                            'No video uploaded yet.',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _recordedAssetsBusy
                              ? null
                              : _pickAndUploadVideo,
                          icon: _uploadingVideo
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.video_file_rounded),
                          label: Text(
                            _uploadingVideo
                                ? 'Uploading ${(_videoUploadProgress * 100).round()}%'
                                : (videoUrlC.text.trim().isEmpty
                                      ? 'Upload Video'
                                      : 'Replace Video'),
                          ),
                        ),
                        if (_uploadingVideo) ...[
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 7,
                              value: _videoUploadProgress
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                            ),
                          ),
                        ],
                        if (videoUrlC.text.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _recordedAssetsBusy
                                ? null
                                : _clearVideoOnly,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Remove Video'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red.shade700,
                              side: BorderSide(color: Colors.red.shade200),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        const Text(
                          'HTML materials',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        if (materialsUrlC.text.trim().isNotEmpty)
                          Text(
                            _fileNameFromUrl(materialsUrlC.text.trim()),
                            style: TextStyle(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        else
                          const Text(
                            'No HTML materials uploaded yet.',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _recordedAssetsBusy
                              ? null
                              : _pickAndUploadHtml,
                          icon: _uploadingMaterials
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.html_rounded),
                          label: Text(
                            _uploadingMaterials
                                ? 'Uploading ${(_materialsUploadProgress * 100).round()}%'
                                : (materialsUrlC.text.trim().isEmpty
                                      ? 'Upload HTML'
                                      : 'Replace HTML'),
                          ),
                        ),
                        if (_uploadingMaterials) ...[
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 7,
                              value: _materialsUploadProgress
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                            ),
                          ),
                        ],
                        if (materialsUrlC.text.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _recordedAssetsBusy
                                ? null
                                : _clearHtmlOnly,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Remove HTML'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red.shade700,
                              side: BorderSide(color: Colors.red.shade200),
                            ),
                          ),
                        ],
                        if (_serverFolderPath.trim().isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Server folder: ${_serverFolderPath.trim()}',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.55),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (!widget.isRecorded) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: materialsUrlC,
                    decoration: const InputDecoration(
                      labelText: 'Materials link (PowerPoint/Drive)',
                      hintText: 'https://...',
                      filled: true,
                    ),
                    onChanged: (_) => _clearInlineError(),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _recordedAssetsBusy
                        ? null
                        : () {
                            _clearInlineError();

                            if (!_form.currentState!.validate()) return;

                            Navigator.pop(
                              context,
                              _SessionDraft(
                                title: titleC.text,
                                skillType: _skill,
                                objective: objectiveC.text,
                                content: contentC.text,
                                homework: homeworkC.text,
                                durationMinutes: int.parse(
                                  durationC.text.trim(),
                                ),
                                videoUrl: widget.isRecorded
                                    ? videoUrlC.text.trim()
                                    : '',
                                videoThumbnailUrl: widget.isRecorded
                                    ? videoThumbC.text.trim()
                                    : '',
                                materialsUrl: materialsUrlC.text.trim(),
                                serverFolderPath: widget.isRecorded
                                    ? _serverFolderPath.trim()
                                    : '',
                              ),
                            );
                          },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Done'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ----------------------------
/// Models
/// ----------------------------
enum SkillType {
  listening,
  speaking,
  reading,
  writing,
  grammar,
  project,
  workshop,
}

extension SkillTypeX on SkillType {
  String get label {
    switch (this) {
      case SkillType.listening:
        return 'Listening';
      case SkillType.speaking:
        return 'Speaking';
      case SkillType.reading:
        return 'Reading';
      case SkillType.writing:
        return 'Writing';
      case SkillType.grammar:
        return 'Grammar';
      case SkillType.project:
        return 'Project';
      case SkillType.workshop:
        return 'Workshop';
    }
  }

  static SkillType fromString(String? s) {
    final v = (s ?? '').toLowerCase().trim();
    switch (v) {
      case 'speaking':
        return SkillType.speaking;
      case 'reading':
        return SkillType.reading;
      case 'writing':
        return SkillType.writing;
      case 'grammar':
        return SkillType.grammar;
      case 'project':
        return SkillType.project;
      case 'workshop':
        return SkillType.workshop;
      case 'listening':
      default:
        return SkillType.listening;
    }
  }
}

class SyllabusUnit {
  SyllabusUnit({
    required this.id,
    required this.title,
    required this.otherTitle,
    required this.description,
    required this.order,
    required this.sessions,
  });

  final String id;
  final String title;
  final String otherTitle;
  final String description;
  final int order;
  final List<SyllabusSession> sessions;

  SyllabusUnit copyWith({
    String? title,
    String? otherTitle,
    String? description,
    int? order,
    List<SyllabusSession>? sessions,
  }) {
    return SyllabusUnit(
      id: id,
      title: title ?? this.title,
      otherTitle: otherTitle ?? this.otherTitle,
      description: description ?? this.description,
      order: order ?? this.order,
      sessions: sessions ?? this.sessions,
    );
  }

  Map<String, dynamic> toMap({
    required bool includeRecordedExtras,
    required bool includeOnlineExtras,
  }) {
    return {
      'id': id,
      'title': title,
      'otherTitle': otherTitle,
      'description': description,
      'order': order,
      'sessions': sessions
          .map(
            (s) => s.toMap(
              includeRecordedExtras: includeRecordedExtras,
              includeOnlineExtras: includeOnlineExtras,
            ),
          )
          .toList(),
    };
  }

  factory SyllabusUnit.fromMap(Map m) {
    List<Map<String, dynamic>> asListOfMaps(dynamic node) {
      final out = <Map<String, dynamic>>[];

      if (node is List) {
        for (final x in node) {
          if (x is Map) {
            out.add(Map<String, dynamic>.from(x));
          }
        }
        return out;
      }

      if (node is Map) {
        final mm = Map<dynamic, dynamic>.from(node);
        for (final entry in mm.entries) {
          final v = entry.value;
          if (v is Map) {
            out.add(Map<String, dynamic>.from(v));
          }
        }
        return out;
      }

      return out;
    }

    final rawSessions = asListOfMaps(m['sessions']);
    final sessions = rawSessions
        .map((x) => SyllabusSession.fromMap(x))
        .toList();

    return SyllabusUnit(
      id: (m['id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      otherTitle: (m['otherTitle'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      order: (m['order'] is num)
          ? (m['order'] as num).toInt()
          : (int.tryParse('${m['order']}') ?? 0),
      sessions: sessions,
    );
  }
}

class SyllabusSession {
  SyllabusSession({
    required this.id,
    required this.title,
    required this.skillType,
    required this.objective,
    required this.content,
    required this.homework,
    required this.durationMinutes,
    required this.order,
    required this.sessionNumber,
    this.videoUrl = '',
    this.videoThumbnailUrl = '',
    this.materialsUrl = '',
    this.serverFolderPath = '',
  });

  final String id;
  final String title;
  final SkillType skillType;
  final String objective;
  final String content;
  final String homework;
  final int durationMinutes;
  final int order;
  final int sessionNumber;
  final String videoUrl;
  final String videoThumbnailUrl;
  final String materialsUrl;
  final String serverFolderPath;

  SyllabusSession copyWith({
    String? title,
    SkillType? skillType,
    String? objective,
    String? content,
    String? homework,
    int? durationMinutes,
    int? order,
    int? sessionNumber,
    String? videoUrl,
    String? videoThumbnailUrl,
    String? materialsUrl,
    String? serverFolderPath,
  }) {
    return SyllabusSession(
      id: id,
      title: title ?? this.title,
      skillType: skillType ?? this.skillType,
      objective: objective ?? this.objective,
      content: content ?? this.content,
      homework: homework ?? this.homework,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      order: order ?? this.order,
      sessionNumber: sessionNumber ?? this.sessionNumber,
      videoUrl: videoUrl ?? this.videoUrl,
      videoThumbnailUrl: videoThumbnailUrl ?? this.videoThumbnailUrl,
      materialsUrl: materialsUrl ?? this.materialsUrl,
      serverFolderPath: serverFolderPath ?? this.serverFolderPath,
    );
  }

  Map<String, dynamic> toMap({
    required bool includeRecordedExtras,
    required bool includeOnlineExtras,
  }) {
    final map = <String, dynamic>{
      'id': id,
      'title': title,
      'skillType': skillType.label,
      'objective': objective,
      'content': content,
      'homework': homework,
      'durationMinutes': durationMinutes,
      'order': order,
      'sessionNumber': sessionNumber,
    };

    if (includeRecordedExtras) {
      map['videoUrl'] = videoUrl;
      map['videoThumbnailUrl'] = videoThumbnailUrl;
      map['materialsUrl'] = materialsUrl;
      map['serverFolderPath'] = serverFolderPath;
    }

    if (includeOnlineExtras) {
      map['materialsUrl'] = materialsUrl;
    }

    return map;
  }

  factory SyllabusSession.fromMap(Map m) {
    return SyllabusSession(
      id: (m['id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      skillType: SkillTypeX.fromString((m['skillType'] ?? '').toString()),
      objective: (m['objective'] ?? '').toString(),
      content: (m['content'] ?? '').toString(),
      homework: (m['homework'] ?? '').toString(),
      durationMinutes: (m['durationMinutes'] is num)
          ? (m['durationMinutes'] as num).toInt()
          : (int.tryParse('${m['durationMinutes']}') ?? 45),
      order: (m['order'] is num)
          ? (m['order'] as num).toInt()
          : (int.tryParse('${m['order']}') ?? 0),
      sessionNumber: (m['sessionNumber'] is num)
          ? (m['sessionNumber'] as num).toInt()
          : (int.tryParse('${m['sessionNumber']}') ?? 0),
      videoUrl: (m['videoUrl'] ?? '').toString(),
      videoThumbnailUrl: (m['videoThumbnailUrl'] ?? '').toString(),
      materialsUrl: (m['materialsUrl'] ?? '').toString(),
      serverFolderPath: (m['serverFolderPath'] ?? '').toString(),
    );
  }
}
