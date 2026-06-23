import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../services/backend_api.dart';

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
  final Set<String> _bulkTouchedSessionIds = <String>{};

  DatabaseReference get _syllabusRef =>
      _db.ref('syllabi').child(widget.courseId).child(widget.variantKey);

  bool _loading = true;
  bool _saving = false;
  bool _recordedAssetBusy = false;
  int _recordedAssetDone = 0;
  int _recordedAssetTotal = 0;
  String _recordedAssetLabel = '';
  final Map<String, _LessonAssetPresence> _lessonPresenceBySessionId =
      <String, _LessonAssetPresence>{};

  List<SyllabusUnit> _units = [];
  final Map<String, bool> _unitExpanded = {};
  final Map<String, bool> _moduleExpanded = {};
  _CourseBookAsset? _courseBook;

  bool _courseBookBusy = false;
  bool _uploadingCourseBook = false;
  double _courseBookUploadProgress = 0;

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

        final units = _isRecordedVariant
            ? _parseRecordedUnits(map)
            : _asListOfMaps(
                map['units'],
              ).map((x) => SyllabusUnit.fromMap(x)).toList();

        units.sort((a, b) => a.order.compareTo(b.order));
        for (final u in units) {
          u.sessions.sort((a, b) => a.order.compareTo(b.order));
        }

        _units = units;
        _courseBook = _CourseBookAsset.fromAny(map['courseBook']);
        _ensureSessionNumbers();
        _bulkTouchedSessionIds.clear();
        _rebuildLessonPresenceFromRtdb();
      } else {
        _units = [];
        _courseBook = null;
        _bulkTouchedSessionIds.clear();
        _lessonPresenceBySessionId.clear();
      }
    } catch (_) {
      _units = [];
      _courseBook = null;
      _lessonPresenceBySessionId.clear();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _rebuildLessonPresenceFromRtdb() {
    _lessonPresenceBySessionId.clear();
    for (final unit in _units) {
      for (final s in unit.sessions) {
        final id = s.id.trim();
        if (id.isEmpty) continue;
        _lessonPresenceBySessionId[id] = _LessonAssetPresence(
          videoOk: s.videoUrl.trim().isNotEmpty,
          htmlOk: s.materialsUrl.trim().isNotEmpty,
        );
      }
    }
  }

  Future<String> _promptIntegrityFixActions({
    required int staleRefs,
    required int orphanFiles,
  }) async {
    return (await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Integrity check found mismatches'),
            content: Text(
              'RTDB stale refs: $staleRefs\n'
              'Orphan server files: $orphanFiles\n\n'
              'Choose how to clean:',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'stale'),
                child: const Text('Clear RTDB stale'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'orphan'),
                child: const Text('Delete orphan files'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, 'both'),
                child: const Text('Clean all'),
              ),
            ],
          ),
        )) ??
        'cancel';
  }

  Future<void> _refreshLessonPresenceFromServer() async {
    if (_recordedAssetBusy) return;
    if (mounted) {
      setState(() {
        _recordedAssetBusy = true;
        _recordedAssetDone = 0;
        _recordedAssetTotal = _totalSessions;
        _recordedAssetLabel = 'Checking lesson files integrity...';
      });
    }

    final next = <String, _LessonAssetPresence>{};
    final listCache = <String, List<Map<String, dynamic>>>{};
    final nextUnits = <SyllabusUnit>[];
    int staleRefCount = 0;
    int orphanCount = 0;
    final orphanPaths = <String>[];

    Future<bool> existsOnServer(String url) async {
      final rel = _SyllabusServerStorage.extractRelativePathFromUrl(url);
      if (rel.isEmpty) return false;
      final folder = rel.contains('/')
          ? rel.substring(0, rel.lastIndexOf('/'))
          : '';
      final fileName = Uri.tryParse(url)?.pathSegments.last ?? '';
      if (folder.isEmpty || fileName.isEmpty) return false;

      final items = listCache.containsKey(folder)
          ? listCache[folder]!
          : await _SyllabusServerStorage.listItems(
              root: 'courses',
              path: folder,
            );
      listCache[folder] = items;
      for (final item in items) {
        final name = (item['name'] ?? '').toString().trim();
        final type = (item['type'] ?? '').toString().trim().toLowerCase();
        if (type == 'file' && name == fileName) return true;
      }
      return false;
    }

    try {
      final courseFolderName = await _loadCourseFolderName();
      for (int ui = 0; ui < _units.length; ui++) {
        final unit = _units[ui];
        final sessions = <SyllabusSession>[];
        for (int si = 0; si < unit.sessions.length; si++) {
          final s = unit.sessions[si];
          final id = s.id.trim();
          if (id.isEmpty) {
            sessions.add(s);
            if (mounted) setState(() => _recordedAssetDone += 1);
            continue;
          }
          final videoUrl = s.videoUrl.trim();
          final htmlUrl = s.materialsUrl.trim();
          final variantFolder = _SyllabusServerStorage.sanitizeSegment(
            widget.variantKey,
            fallback: 'variant',
          );
          final sessionFolder = _SyllabusServerStorage.buildSessionFolderName(
            sessionNumber: s.sessionNumber > 0 ? s.sessionNumber : (si + 1),
            sessionTitle: s.title,
          );
          final fallbackFolder =
              '$courseFolderName/$variantFolder/$sessionFolder';
          final folderPath = _resolveServerFolderPath(s).isNotEmpty
              ? _resolveServerFolderPath(s)
              : fallbackFolder;

          List<Map<String, dynamic>> serverItems =
              const <Map<String, dynamic>>[];
          try {
            serverItems = await _SyllabusServerStorage.listItems(
              root: 'courses',
              path: folderPath,
            );
          } catch (_) {
            serverItems = const <Map<String, dynamic>>[];
          }
          final serverFileNames = <String>{};
          for (final item in serverItems) {
            final type = (item['type'] ?? '').toString().trim().toLowerCase();
            final name = (item['name'] ?? '').toString().trim();
            if (type != 'folder' && name.isNotEmpty) {
              serverFileNames.add(name);
            }
          }

          bool videoOk = videoUrl.isNotEmpty;
          bool htmlOk = htmlUrl.isNotEmpty;

          if (videoUrl.isNotEmpty) {
            try {
              videoOk = await existsOnServer(videoUrl);
            } catch (_) {
              videoOk = false;
            }
          }
          if (htmlUrl.isNotEmpty) {
            try {
              htmlOk = await existsOnServer(htmlUrl);
            } catch (_) {
              htmlOk = false;
            }
          }

          var updated = s;
          if (videoUrl.isNotEmpty && !videoOk) {
            updated = updated.copyWith(videoUrl: '', videoThumbnailUrl: '');
            staleRefCount += 1;
          }
          if (htmlUrl.isNotEmpty && !htmlOk) {
            updated = updated.copyWith(materialsUrl: '');
            staleRefCount += 1;
          }

          final currentFiles = List<LessonFileAsset>.from(updated.lessonFiles);
          final nextFiles = <LessonFileAsset>[];
          for (final lf in currentFiles) {
            final u = lf.url.trim();
            if (u.isEmpty) {
              nextFiles.add(lf);
              continue;
            }
            bool ok = false;
            try {
              ok = await existsOnServer(u);
            } catch (_) {
              ok = false;
            }
            if (ok) {
              nextFiles.add(lf);
            } else {
              staleRefCount += 1;
            }
          }
          if (nextFiles.length != currentFiles.length) {
            updated = updated.copyWith(lessonFiles: nextFiles);
          }

          final trackedNames = <String>{};
          String nameFromUrl(String url) {
            final parsed = Uri.tryParse(url.trim());
            if (parsed != null && parsed.pathSegments.isNotEmpty) {
              return parsed.pathSegments.last;
            }
            final chunks = url.split('/');
            return chunks.isNotEmpty ? chunks.last : '';
          }

          final vName = nameFromUrl(updated.videoUrl);
          final hName = nameFromUrl(updated.materialsUrl);
          if (vName.isNotEmpty) trackedNames.add(vName);
          if (hName.isNotEmpty) trackedNames.add(hName);
          for (final lf in updated.lessonFiles) {
            final name = nameFromUrl(lf.url);
            if (name.isNotEmpty) trackedNames.add(name);
          }
          for (final name in serverFileNames) {
            if (!trackedNames.contains(name)) {
              orphanCount += 1;
              orphanPaths.add('$folderPath/$name');
            }
          }

          if (updated.videoUrl.trim().isEmpty &&
              updated.materialsUrl.trim().isEmpty &&
              updated.serverFolderPath.trim().isNotEmpty &&
              updated.lessonFiles.isEmpty) {
            updated = updated.copyWith(serverFolderPath: '');
          }

          if (updated.videoUrl != s.videoUrl ||
              updated.materialsUrl != s.materialsUrl ||
              updated.videoThumbnailUrl != s.videoThumbnailUrl ||
              updated.serverFolderPath != s.serverFolderPath) {
            _bulkTouchedSessionIds.add(id);
          }

          next[id] = _LessonAssetPresence(videoOk: videoOk, htmlOk: htmlOk);
          sessions.add(updated);
          if (mounted) setState(() => _recordedAssetDone += 1);
        }
        nextUnits.add(unit.copyWith(sessions: sessions));
      }

      if (staleRefCount == 0 && orphanCount == 0) {
        if (mounted) {
          setState(() {
            _units = nextUnits;
            _lessonPresenceBySessionId
              ..clear()
              ..addAll(next);
          });
          AppToast.show(
            context,
            'Integrity check complete. No mismatches found.',
            type: AppToastType.success,
          );
        }
        return;
      }

      final action = await _promptIntegrityFixActions(
        staleRefs: staleRefCount,
        orphanFiles: orphanCount,
      );
      if (action == 'cancel') {
        if (mounted) {
          AppToast.show(
            context,
            'Integrity check cancelled. No changes applied.',
            type: AppToastType.info,
          );
        }
        return;
      }

      final applyStale = action == 'stale' || action == 'both';
      final applyOrphan = action == 'orphan' || action == 'both';

      if (mounted && applyStale) {
        setState(() {
          _units = nextUnits;
          _lessonPresenceBySessionId
            ..clear()
            ..addAll(next);
        });
      }

      if (applyStale) {
        await _saveSyllabus(showToast: false, skipRecordedMerge: true);
      }

      int orphanDeleted = 0;
      int orphanDeleteFailed = 0;
      if (applyOrphan) {
        for (final path in orphanPaths) {
          try {
            await _SyllabusServerStorage.deletePath(
              root: 'courses',
              path: path,
            );
            orphanDeleted += 1;
          } catch (_) {
            orphanDeleteFailed += 1;
          }
        }
      }

      if (mounted) {
        final staleText = applyStale
            ? ' Cleared $staleRefCount stale RTDB ref${staleRefCount == 1 ? '' : 's'}.'
            : '';
        final orphanText = applyOrphan
            ? ' Deleted $orphanDeleted orphan file${orphanDeleted == 1 ? '' : 's'}${orphanDeleteFailed > 0 ? ' ($orphanDeleteFailed failed)' : ''}.'
            : '';
        AppToast.show(
          context,
          'Integrity check done.$staleText$orphanText',
          type: AppToastType.success,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _recordedAssetBusy = false;
          _recordedAssetLabel = '';
        });
      }
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

  Future<void> _mergeRecordedAssetsForUntouchedBulkSessions() async {
    if (!_isRecordedVariant || _bulkTouchedSessionIds.isEmpty) return;

    final snap = await _syllabusRef.get();
    if (snap.value is! Map) return;

    final root = Map<String, dynamic>.from(snap.value as Map);
    final remoteUnits = _parseRecordedUnits(root)
      ..sort((a, b) => a.order.compareTo(b.order));
    for (final u in remoteUnits) {
      u.sessions.sort((a, b) => a.order.compareTo(b.order));
    }

    final remoteById = <String, SyllabusSession>{};
    for (int ui = 0; ui < remoteUnits.length; ui++) {
      final unit = remoteUnits[ui];
      for (int si = 0; si < unit.sessions.length; si++) {
        final session = unit.sessions[si];
        final sid = session.id.trim();
        if (sid.isNotEmpty) {
          remoteById[sid] = session;
        }
      }
    }

    for (int ui = 0; ui < _units.length; ui++) {
      final unit = _units[ui];
      final sessions = [...unit.sessions];

      for (int si = 0; si < sessions.length; si++) {
        final local = sessions[si];
        final sid = local.id.trim();
        if (sid.isNotEmpty && _bulkTouchedSessionIds.contains(sid)) continue;

        SyllabusSession? remote = sid.isEmpty ? null : remoteById[sid];
        if (remote == null && ui < remoteUnits.length) {
          final remoteSessions = remoteUnits[ui].sessions;
          if (si < remoteSessions.length) remote = remoteSessions[si];
        }
        if (remote == null) continue;

        final keepVideo = local.videoUrl.trim().isNotEmpty;
        final keepMaterials = local.materialsUrl.trim().isNotEmpty;
        final keepThumb = local.videoThumbnailUrl.trim().isNotEmpty;
        final keepFolder = local.serverFolderPath.trim().isNotEmpty;

        sessions[si] = local.copyWith(
          videoUrl: keepVideo ? local.videoUrl : remote.videoUrl,
          materialsUrl: keepMaterials
              ? local.materialsUrl
              : remote.materialsUrl,
          videoThumbnailUrl: keepThumb
              ? local.videoThumbnailUrl
              : remote.videoThumbnailUrl,
          serverFolderPath: keepFolder
              ? local.serverFolderPath
              : remote.serverFolderPath,
        );
      }

      _units[ui] = unit.copyWith(sessions: sessions);
    }
  }

  Future<void> _saveSyllabus({
    bool showToast = true,
    bool skipRecordedMerge = false,
  }) async {
    setState(() => _saving = true);
    try {
      for (int i = 0; i < _units.length; i++) {
        _units[i] = _units[i].copyWith(order: i + 1);
        for (int j = 0; j < _units[i].sessions.length; j++) {
          _units[i].sessions[j] = _units[i].sessions[j].copyWith(order: j + 1);
        }
      }

      _ensureSessionNumbers();

      if (!skipRecordedMerge) {
        await _mergeRecordedAssetsForUntouchedBulkSessions();
      }

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
        if (_courseBook != null) 'courseBook': _courseBook!.toMap(),
        if (_isRecordedVariant)
          'modules': _buildRecordedModulesPayload()
        else
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

      _bulkTouchedSessionIds.clear();

      if (!mounted) return;
      if (showToast) {
        AppToast.show(context, 'Syllabus saved', type: AppToastType.success);
      }
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

  Future<void> _autoSaveIfRecorded({String successMessage = 'Saved'}) async {
    if (!_isRecordedVariant) return;
    await _saveSyllabus(showToast: false);
    if (!mounted) return;
    AppToast.show(context, successMessage, type: AppToastType.success);
  }

  List<int> _unitIndexesForModule(String moduleLabel) {
    final out = <int>[];
    for (int i = 0; i < _units.length; i++) {
      final u = _units[i];
      final label = u.otherTitle.trim().isNotEmpty
          ? u.otherTitle.trim()
          : 'Module ${i + 1}';
      if (label == moduleLabel) out.add(i);
    }
    return out;
  }

  Future<void> _clearRecordedAssetsByUnitIndexes({
    required List<int> unitIndexes,
    required String confirmTitle,
    required String confirmMessage,
  }) async {
    if (!_isRecordedVariant || unitIndexes.isEmpty || _recordedAssetBusy) {
      return;
    }

    final ok = await _confirm(
      title: confirmTitle,
      message: confirmMessage,
      confirmText: 'Clear',
      danger: true,
    );
    if (!ok) return;

    final nextUnits = [..._units];
    final totalTargets = unitIndexes.fold<int>(0, (sum, idx) {
      if (idx < 0 || idx >= _units.length) return sum;
      return sum + _units[idx].sessions.length;
    });
    if (mounted) {
      setState(() {
        _recordedAssetBusy = true;
        _recordedAssetDone = 0;
        _recordedAssetTotal = totalTargets;
        _recordedAssetLabel = 'Clearing assets...';
      });
    }
    int cleared = 0;
    int failed = 0;

    try {
      for (final unitIndex in unitIndexes) {
        if (unitIndex < 0 || unitIndex >= nextUnits.length) continue;
        final unit = nextUnits[unitIndex];
        final sessions = [...unit.sessions];

        for (int i = 0; i < sessions.length; i++) {
          final s = sessions[i];
          if (mounted) {
            setState(() {
              _recordedAssetLabel =
                  'Clearing ${unit.title.isEmpty ? 'unit' : unit.title} • ${i + 1}/${sessions.length}';
            });
          }
          try {
            await _deleteRecordedAssetsIfNeeded(s);
            sessions[i] = s.copyWith(
              videoUrl: '',
              materialsUrl: '',
              videoThumbnailUrl: '',
              serverFolderPath: '',
            );
            cleared += 1;
          } catch (_) {
            failed += 1;
          } finally {
            if (mounted) {
              setState(() {
                _recordedAssetDone += 1;
              });
            }
          }
        }

        nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      }
    } finally {
      if (mounted) {
        setState(() {
          _recordedAssetBusy = false;
          _recordedAssetLabel = '';
        });
      }
    }

    setState(() {
      _units = nextUnits;
      _rebuildLessonPresenceFromRtdb();
    });
    await _saveSyllabus(showToast: false);
    if (!mounted) return;
    AppToast.show(
      context,
      'Clear completed. Cleared: $cleared • Failed: $failed',
      type: failed == 0 ? AppToastType.success : AppToastType.info,
    );
  }

  Future<void> _clearRecordedCourseAssets() async {
    await _clearRecordedAssetsByUnitIndexes(
      unitIndexes: [for (int i = 0; i < _units.length; i++) i],
      confirmTitle: 'Clear Course Assets?',
      confirmMessage:
          'This removes recorded files/folders from server and clears URLs in RTDB for the whole course.',
    );
  }

  Future<void> _clearRecordedModuleAssets(String moduleLabel) async {
    await _clearRecordedAssetsByUnitIndexes(
      unitIndexes: _unitIndexesForModule(moduleLabel),
      confirmTitle: 'Clear Module Assets?',
      confirmMessage:
          'This removes recorded files/folders and clears URLs for module "$moduleLabel".',
    );
  }

  Future<void> _clearRecordedUnitAssets(int unitIndex) async {
    final label = (unitIndex >= 0 && unitIndex < _units.length)
        ? _units[unitIndex].title
        : 'Unit';
    await _clearRecordedAssetsByUnitIndexes(
      unitIndexes: [unitIndex],
      confirmTitle: 'Clear Unit Assets?',
      confirmMessage:
          'This removes recorded files/folders and clears URLs for "$label".',
    );
  }

  bool get _anySessionHasHtml {
    for (final unit in _units) {
      for (final s in unit.sessions) {
        if (s.materialsUrl.trim().isNotEmpty) return true;
        if (s.homeworkUrl.trim().isNotEmpty) return true;
      }
    }
    return false;
  }

  bool get _allSessionsHtmlHidden {
    if (_units.isEmpty) return false;
    for (final unit in _units) {
      for (final s in unit.sessions) {
        if (s.materialsUrl.trim().isNotEmpty && !s.materialsHidden) {
          return false;
        }
      }
    }
    return true;
  }

  Future<void> _deleteRecordedCourseHtmlOnly() async {
    if (!_isRecordedVariant || _recordedAssetBusy) return;
    if (!_anySessionHasHtml) {
      if (!mounted) return;
      AppToast.show(
        context,
        'No lesson HTML to delete.',
        type: AppToastType.info,
      );
      return;
    }

    final ok = await _confirmDeleteHtml();
    if (!ok) return;

    final unitIndexes = [for (int i = 0; i < _units.length; i++) i];
    final nextUnits = [..._units];
    final totalTargets = unitIndexes.fold<int>(0, (sum, idx) {
      if (idx < 0 || idx >= _units.length) return sum;
      return sum + _units[idx].sessions.length;
    });

    if (mounted) {
      setState(() {
        _recordedAssetBusy = true;
        _recordedAssetDone = 0;
        _recordedAssetTotal = totalTargets;
        _recordedAssetLabel = 'Deleting lesson HTML...';
      });
    }
    int cleared = 0;
    int failed = 0;

    try {
      for (final unitIndex in unitIndexes) {
        if (unitIndex < 0 || unitIndex >= nextUnits.length) continue;
        final unit = nextUnits[unitIndex];
        final sessions = [...unit.sessions];

        for (int i = 0; i < sessions.length; i++) {
          final s = sessions[i];
          if (mounted) {
            setState(() {
              _recordedAssetLabel =
                  'Deleting ${unit.title.isEmpty ? 'unit' : unit.title} • ${i + 1}/${sessions.length}';
            });
          }
          try {
            final htmlUrl = s.materialsUrl.trim();
            final hwUrl = s.homeworkUrl.trim();

            String? htmlRel;
            String? hwRel;
            if (htmlUrl.isNotEmpty) {
              htmlRel = _SyllabusServerStorage.extractRelativePathFromUrl(
                htmlUrl,
              );
            }
            if (hwUrl.isNotEmpty) {
              hwRel = _SyllabusServerStorage.extractRelativePathFromUrl(hwUrl);
            }

            if (htmlRel != null && htmlRel.isNotEmpty) {
              try {
                await _SyllabusServerStorage.deletePath(
                  root: 'courses',
                  path: htmlRel,
                );
              } catch (e) {
                if (!e.toString().toLowerCase().contains('item not found'))
                  rethrow;
              }
            }
            if (hwRel != null && hwRel.isNotEmpty) {
              try {
                await _SyllabusServerStorage.deletePath(
                  root: 'courses',
                  path: hwRel,
                );
              } catch (e) {
                if (!e.toString().toLowerCase().contains('item not found'))
                  rethrow;
              }
            }

            sessions[i] = s.copyWith(materialsUrl: '', homeworkUrl: '');
            cleared += 1;
          } catch (_) {
            failed += 1;
          } finally {
            if (mounted) {
              setState(() => _recordedAssetDone += 1);
            }
          }
        }
        nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      }
    } finally {
      if (mounted) {
        setState(() {
          _recordedAssetBusy = false;
          _recordedAssetLabel = '';
        });
      }
    }

    setState(() {
      _units = nextUnits;
      _rebuildLessonPresenceFromRtdb();
    });
    await _saveSyllabus(showToast: false);
    if (!mounted) return;
    AppToast.show(
      context,
      'HTML delete completed. Cleared: $cleared • Failed: $failed',
      type: failed == 0 ? AppToastType.success : AppToastType.info,
    );
  }

  Future<void> _hideUnhideRecordedCourseHtml({required bool hidden}) async {
    if (!_isRecordedVariant || _recordedAssetBusy) return;

    final label = hidden ? 'Hide' : 'Unhide';
    final ok = await _confirm(
      title: '$label All Lesson HTML?',
      message: hidden
          ? 'This will hide all lesson HTML from learners. '
                'Files remain on the server and can be unhidden later. '
                'Videos and course book are not affected.'
          : 'This will make all hidden lesson HTML visible to learners again.',
      confirmText: label,
    );
    if (!ok) return;

    final nextUnits = _units.map((unit) {
      final sessions = unit.sessions.map((s) {
        if (s.materialsUrl.trim().isEmpty && s.homeworkUrl.trim().isEmpty) {
          return s;
        }
        return s.copyWith(materialsHidden: hidden);
      }).toList();
      return unit.copyWith(sessions: sessions);
    }).toList();

    setState(() {
      _units = nextUnits;
    });
    await _saveSyllabus(showToast: false);
    if (!mounted) return;
    AppToast.show(
      context,
      hidden
          ? 'Lesson HTML hidden from learners.'
          : 'Lesson HTML visible to learners.',
      type: AppToastType.success,
    );
  }

  Future<bool> _confirmDeleteHtml() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final typed = controller.text.trim();
          final canDelete = typed == 'delete';
          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.delete_forever,
                  color: Colors.red.shade700,
                  size: 24,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Delete All Lesson HTML?',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This will permanently delete all lesson HTML files from the '
                  'server and remove their references from the syllabus.\n\n'
                  'Videos and course book are NOT affected.\n\n'
                  'This action cannot be undone. You will need to re-upload HTML '
                  'files to restore lessons.',
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Type "delete" to confirm:',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'type "delete"',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: canDelete ? () => Navigator.pop(ctx, true) : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Delete'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return confirmed ?? false;
  }

  List<_RecordedBulkTarget> _buildRecordedBulkTargets(List<int> unitIndexes) {
    final targets = <_RecordedBulkTarget>[];
    for (final unitIndex in unitIndexes) {
      if (unitIndex < 0 || unitIndex >= _units.length) continue;
      final unit = _units[unitIndex];
      for (int si = 0; si < unit.sessions.length; si++) {
        targets.add(
          _RecordedBulkTarget(
            unitIndex: unitIndex,
            sessionIndex: si,
            session: unit.sessions[si],
          ),
        );
      }
    }
    targets.sort((a, b) {
      final an = a.session.sessionNumber > 0
          ? a.session.sessionNumber
          : (a.sessionIndex + 1);
      final bn = b.session.sessionNumber > 0
          ? b.session.sessionNumber
          : (b.sessionIndex + 1);
      return an.compareTo(bn);
    });
    return targets;
  }

  bool _isTrailingOnlySelection(
    Map<int, PlatformFile> filesByNo,
    int expected,
  ) {
    if (filesByNo.isEmpty) return true;
    if (filesByNo.length > expected) return false;
    final maxKey = filesByNo.keys.reduce((a, b) => a > b ? a : b);
    if (maxKey != filesByNo.length) return false;
    for (int i = 1; i <= filesByNo.length; i++) {
      if (!filesByNo.containsKey(i)) return false;
    }
    return true;
  }

  Future<void> _bulkUploadRecordedForUnitIndexes({
    required List<int> unitIndexes,
    required String scopeLabel,
  }) async {
    if (_recordedAssetBusy || !_isRecordedVariant) return;
    final targets = _buildRecordedBulkTargets(unitIndexes);
    final expected = targets.length;
    if (expected == 0) {
      AppToast.show(
        context,
        'No lessons found in $scopeLabel.',
        type: AppToastType.info,
      );
      return;
    }

    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.custom,
      allowedExtensions: const [
        'html',
        'htm',
        'mp4',
        'mov',
        'm4v',
        'webm',
        'mkv',
      ],
    );
    if (picked == null || picked.files.isEmpty) return;
    if (!mounted) return;

    bool isHtmlExt(String ext) => ext == 'html' || ext == 'htm';
    bool isVideoExt(String ext) =>
        ext == 'mp4' ||
        ext == 'mov' ||
        ext == 'm4v' ||
        ext == 'webm' ||
        ext == 'mkv';

    final reg = RegExp(r'^(\d+)\.([a-z0-9]+)$', caseSensitive: false);
    final htmlByNo = <int, PlatformFile>{};
    final videoByNo = <int, PlatformFile>{};

    for (final f in picked.files) {
      final m = reg.firstMatch(f.name.trim());
      if (m == null) {
        AppToast.show(
          context,
          'Invalid file: ${f.name}. Use numeric names like 1.html',
          type: AppToastType.error,
        );
        return;
      }
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      final ext = (m.group(2) ?? '').toLowerCase();
      if (n <= 0 || n > expected) {
        AppToast.show(
          context,
          'File ${f.name} out of range. Expected 1..$expected',
          type: AppToastType.error,
        );
        return;
      }
      if (isHtmlExt(ext)) {
        htmlByNo[n] = f;
      } else if (isVideoExt(ext)) {
        videoByNo[n] = f;
      } else {
        AppToast.show(
          context,
          'Unsupported file type: ${f.name}',
          type: AppToastType.error,
        );
        return;
      }
    }

    if (htmlByNo.isEmpty && videoByNo.isEmpty) {
      AppToast.show(
        context,
        'No valid HTML or video files selected.',
        type: AppToastType.error,
      );
      return;
    }

    if (!_isTrailingOnlySelection(htmlByNo, expected)) {
      AppToast.show(
        context,
        'HTML numbering must be 1..N with only trailing missing.',
        type: AppToastType.error,
      );
      return;
    }
    if (!_isTrailingOnlySelection(videoByNo, expected)) {
      AppToast.show(
        context,
        'Video numbering must be 1..N with only trailing missing.',
        type: AppToastType.error,
      );
      return;
    }

    if ((htmlByNo.isNotEmpty && htmlByNo.length < expected) ||
        (videoByNo.isNotEmpty && videoByNo.length < expected)) {
      final htmlInfo = htmlByNo.isNotEmpty
          ? 'HTML ${htmlByNo.length}/$expected'
          : null;
      final videoInfo = videoByNo.isNotEmpty
          ? 'Video ${videoByNo.length}/$expected'
          : null;
      AppToast.show(
        context,
        'Missing trailing lessons allowed. Uploading ${[htmlInfo, videoInfo].whereType<String>().join(' • ')}',
        type: AppToastType.info,
      );
    }

    final courseFolderName = await _loadCourseFolderName();
    final totalOps = htmlByNo.length + videoByNo.length;
    final nextUnits = [..._units];
    int success = 0;
    int failed = 0;
    final failureDetails = <String>[];

    if (mounted) {
      setState(() {
        _recordedAssetBusy = true;
        _recordedAssetDone = 0;
        _recordedAssetTotal = totalOps;
        _recordedAssetLabel = 'Uploading assets for $scopeLabel';
      });
    }

    Future<void> runSingle({
      required _RecordedBulkTarget target,
      required PlatformFile file,
      required bool isHtml,
      required int localNo,
    }) async {
      final current = nextUnits[target.unitIndex].sessions[target.sessionIndex];
      final oldUrl = isHtml
          ? current.materialsUrl.trim()
          : current.videoUrl.trim();
      if (oldUrl.isNotEmpty) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(oldUrl);
        if (rel.isNotEmpty) {
          await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
        }
      }

      final serverPath = _resolveServerFolderPath(current).isNotEmpty
          ? _resolveServerFolderPath(current)
          : '$courseFolderName/${_SyllabusServerStorage.sanitizeSegment(widget.variantKey, fallback: 'variant')}/${_SyllabusServerStorage.buildSessionFolderName(sessionNumber: current.sessionNumber > 0 ? current.sessionNumber : localNo, sessionTitle: current.title)}';

      final url = await _SyllabusServerStorage.uploadPlatformFile(
        file: file,
        root: 'courses',
        path: serverPath,
        customName: _SyllabusServerStorage.buildCustomBaseName(
          sessionNumber: current.sessionNumber > 0
              ? current.sessionNumber
              : localNo,
          suffix: isHtml ? 'materials' : 'video',
        ),
      );

      final updated = isHtml
          ? current.copyWith(materialsUrl: url, serverFolderPath: serverPath)
          : current.copyWith(
              videoUrl: url,
              videoThumbnailUrl: '',
              serverFolderPath: serverPath,
            );

      final sessions = [...nextUnits[target.unitIndex].sessions];
      sessions[target.sessionIndex] = updated;
      nextUnits[target.unitIndex] = nextUnits[target.unitIndex].copyWith(
        sessions: sessions,
      );
    }

    try {
      for (int i = 1; i <= expected; i++) {
        final target = targets[i - 1];
        final htmlFile = htmlByNo[i];
        final videoFile = videoByNo[i];

        if (htmlFile != null) {
          try {
            if (mounted) {
              setState(
                () => _recordedAssetLabel = 'Uploading HTML • $i/$expected',
              );
            }
            await runSingle(
              target: target,
              file: htmlFile,
              isHtml: true,
              localNo: i,
            );
            success += 1;
          } catch (e, st) {
            failed += 1;
            final message = 'HTML $i failed: $e';
            failureDetails.add(message);
            debugPrint('[RecordedBulkUpload] $message');
            debugPrint('$st');
          } finally {
            if (mounted) setState(() => _recordedAssetDone += 1);
          }
        }

        if (videoFile != null) {
          try {
            if (mounted) {
              setState(
                () => _recordedAssetLabel = 'Uploading Video • $i/$expected',
              );
            }
            await runSingle(
              target: target,
              file: videoFile,
              isHtml: false,
              localNo: i,
            );
            success += 1;
          } catch (e, st) {
            failed += 1;
            final message = 'Video $i failed: $e';
            failureDetails.add(message);
            debugPrint('[RecordedBulkUpload] $message');
            debugPrint('$st');
          } finally {
            if (mounted) setState(() => _recordedAssetDone += 1);
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _recordedAssetBusy = false;
          _recordedAssetLabel = '';
        });
      }
    }

    setState(() {
      _units = nextUnits;
      _rebuildLessonPresenceFromRtdb();
    });
    await _saveSyllabus(showToast: false);
    if (!mounted) return;
    final firstFailure = failureDetails.isNotEmpty
        ? '\nFirst error: ${failureDetails.first}'
        : '';
    AppToast.show(
      context,
      'Bulk upload completed for $scopeLabel. Success: $success • Failed: $failed$firstFailure',
      type: failed == 0
          ? AppToastType.success
          : (success == 0 ? AppToastType.error : AppToastType.info),
    );
  }

  Future<void> _bulkUploadRecordedUnitAssets(int unitIndex) async {
    if (!_isRecordedVariant || unitIndex < 0 || unitIndex >= _units.length) {
      return;
    }
    final unitTitle = _units[unitIndex].title.trim().isEmpty
        ? 'Unit ${unitIndex + 1}'
        : _units[unitIndex].title.trim();
    await _bulkUploadRecordedForUnitIndexes(
      unitIndexes: [unitIndex],
      scopeLabel: unitTitle,
    );
  }

  Future<void> _bulkUploadRecordedModuleAssets(String moduleLabel) async {
    await _bulkUploadRecordedForUnitIndexes(
      unitIndexes: _unitIndexesForModule(moduleLabel),
      scopeLabel: moduleLabel,
    );
  }

  Future<void> _bulkUploadRecordedCourseAssets() async {
    await _bulkUploadRecordedForUnitIndexes(
      unitIndexes: [for (int i = 0; i < _units.length; i++) i],
      scopeLabel: 'entire course',
    );
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
    await _autoSaveIfRecorded(successMessage: 'Unit added and saved.');
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
    await _autoSaveIfRecorded(successMessage: 'Unit updated and saved.');
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
      await _autoSaveIfRecorded(successMessage: 'Unit deleted and saved.');
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
    if (_isRecordedVariant) {
      unawaited(_saveSyllabus(showToast: false));
    }
  }

  // ----------------------------
  // Session actions
  // ----------------------------

  Future<void> _addSession(int unitIndex) async {
    final courseFolderName = await _loadCourseFolderName();
    if (!mounted) return;

    final res = await showModalBottomSheet<_SessionDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionEditorSheet(
        title: 'Add Session',
        isRecorded: _isRecordedVariant,
        variantKey: widget.variantKey,
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
          homeworkUrl: '',
          serverFolderPath: '',
          lessonFiles: const <LessonFileAsset>[],
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
      homeworkUrl: res.homeworkUrl.trim(),
      serverFolderPath: res.serverFolderPath.trim(),
      lessonFiles: res.lessonFiles,
    );

    setState(() {
      final next = [..._units];
      next[unitIndex] = unit.copyWith(sessions: [...unit.sessions, newSession]);
      _units = next;
    });
    await _saveSyllabus(showToast: false);
    if (!mounted) return;
    AppToast.show(
      context,
      _isRecordedVariant
          ? 'Lesson added and saved.'
          : 'Session added and saved.',
      type: AppToastType.success,
    );
  }

  Future<void> _editSession(int unitIndex, int sessionIndex) async {
    final unit = _units[unitIndex];
    final s = unit.sessions[sessionIndex];
    final courseFolderName = await _loadCourseFolderName();
    if (!mounted) return;

    final res = await showModalBottomSheet<_SessionDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SessionEditorSheet(
        title: 'Edit Session',
        isRecorded: _isRecordedVariant,
        variantKey: widget.variantKey,
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
          homeworkUrl: s.homeworkUrl,
          serverFolderPath: _resolveServerFolderPath(s),
          lessonFiles: s.lessonFiles,
        ),
      ),
    );

    if (res == null) return;

    final newMaterialsUrl = res.materialsUrl.trim();
    final newHomeworkUrl = res.homeworkUrl.trim();
    final autoUnhide =
        s.materialsHidden &&
        (newMaterialsUrl != s.materialsUrl ||
            newHomeworkUrl != s.homeworkUrl) &&
        (newMaterialsUrl.isNotEmpty || newHomeworkUrl.isNotEmpty);

    final updated = s.copyWith(
      title: res.title.trim(),
      skillType: res.skillType,
      objective: res.objective.trim(),
      content: res.content.trim(),
      homework: res.homework.trim(),
      durationMinutes: res.durationMinutes,
      videoUrl: res.videoUrl.trim(),
      videoThumbnailUrl: res.videoThumbnailUrl.trim(),
      materialsUrl: newMaterialsUrl,
      homeworkUrl: newHomeworkUrl,
      serverFolderPath: res.serverFolderPath.trim(),
      lessonFiles: res.lessonFiles,
      materialsHidden: autoUnhide ? false : s.materialsHidden,
    );

    setState(() {
      final sessions = [...unit.sessions];
      sessions[sessionIndex] = updated;
      final nextUnits = [..._units];
      nextUnits[unitIndex] = unit.copyWith(sessions: sessions);
      _units = nextUnits;
    });
    await _saveSyllabus(showToast: false);
    if (!mounted) return;
    AppToast.show(
      context,
      _isRecordedVariant
          ? 'Lesson updated and saved.'
          : 'Session updated and saved.',
      type: AppToastType.success,
    );
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
      await _autoSaveIfRecorded(successMessage: 'Lesson deleted and saved.');
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
    if (_isRecordedVariant) {
      unawaited(_saveSyllabus(showToast: false));
    }
  }

  // ----------------------------
  // UI
  // ----------------------------

  @override
  Widget build(BuildContext context) {
    final moduleGroups = _isRecordedVariant
        ? _groupUnitsByModule()
        : const <_ModuleUnitGroup>[];
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
          if (_isRecordedVariant)
            PopupMenuButton<String>(
              tooltip: 'More actions',
              icon: const Icon(Icons.more_vert),
              enabled: !_loading && !_saving && !_recordedAssetBusy,
              onSelected: (value) async {
                switch (value) {
                  case 'refresh':
                    await _refreshLessonPresenceFromServer();
                  case 'delete_assets':
                    await _clearRecordedCourseAssets();
                  case 'bulk_upload':
                    await _bulkUploadRecordedCourseAssets();
                  case 'delete_html':
                    await _deleteRecordedCourseHtmlOnly();
                  case 'hide':
                    await _hideUnhideRecordedCourseHtml(hidden: true);
                  case 'unhide':
                    await _hideUnhideRecordedCourseHtml(hidden: false);
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'refresh',
                  child: Row(
                    children: [
                      Icon(Icons.refresh, size: 18),
                      SizedBox(width: 10),
                      Text('Refresh'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete_assets',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_sweep_outlined,
                        size: 18,
                        color: Colors.red,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Delete course assets',
                        style: TextStyle(color: Colors.red),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'bulk_upload',
                  child: Row(
                    children: [
                      Icon(
                        Icons.upload_file_rounded,
                        size: 18,
                        color: Colors.blue,
                      ),
                      SizedBox(width: 10),
                      Text('Bulk upload'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete_html',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_forever,
                        size: 18,
                        color: Colors.red.shade700,
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Delete All Lesson HTML',
                        style: TextStyle(color: Colors.red),
                      ),
                    ],
                  ),
                ),
                if (_allSessionsHtmlHidden)
                  PopupMenuItem(
                    value: 'unhide',
                    child: Row(
                      children: [
                        Icon(
                          Icons.visibility,
                          size: 18,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 10),
                        const Text('Unhide All Lesson HTML'),
                      ],
                    ),
                  )
                else
                  PopupMenuItem(
                    value: 'hide',
                    child: Row(
                      children: [
                        Icon(
                          Icons.visibility_off,
                          size: 18,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 10),
                        const Text('Hide All Lesson HTML'),
                      ],
                    ),
                  ),
              ],
            )
          else
            IconButton(
              tooltip: 'Check RTDB vs server',
              onPressed: (_loading || _saving || _recordedAssetBusy)
                  ? null
                  : _refreshLessonPresenceFromServer,
              icon: const Icon(Icons.refresh),
            ),
          if (!_isRecordedVariant)
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
          if (_isRecordedVariant && _recordedAssetBusy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_loading || (_isRecordedVariant && _recordedAssetBusy))
            ? null
            : _addUnit,
        icon: const Icon(Icons.add),
        label: Text(
          _isRecordedVariant ? 'Add Unit (inside module)' : 'Add Unit',
        ),
      ),
      body: _loading
          ? const Center(
              child: BrandedInlineLoader(message: 'Loading syllabus...'),
            )
          : _units.isEmpty
          ? Column(
              children: [
                _courseBookPanel(),
                Expanded(
                  child: _EmptyState(
                    onAddUnit: _addUnit,
                    courseTitle: widget.courseTitle,
                  ),
                ),
              ],
            )
          : Column(
              children: [
                _HeaderStats(
                  units: _units.length,
                  sessions: _totalSessions,
                  modules: _isRecordedVariant ? moduleGroups.length : null,
                  unitsLabel: _isRecordedVariant ? 'Units' : 'Units',
                  sessionsLabel: _isRecordedVariant ? 'Lessons' : 'Sessions',
                  hint: _isRecordedVariant ? '' : 'Drag units to reorder',
                ),
                _courseBookPanel(),
                if (_isRecordedVariant && _recordedAssetBusy)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Builder(
                            builder: (context) {
                              final progress = _recordedAssetTotal <= 0
                                  ? 0.0
                                  : (_recordedAssetDone / _recordedAssetTotal)
                                        .clamp(0.0, 1.0);
                              final pct = (progress * 100).round();
                              return Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _recordedAssetLabel.isEmpty
                                          ? 'Processing...'
                                          : _recordedAssetLabel,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$pct%',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            minHeight: 8,
                            value: _recordedAssetTotal <= 0
                                ? null
                                : (_recordedAssetDone / _recordedAssetTotal)
                                      .clamp(0.0, 1.0),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$_recordedAssetDone/$_recordedAssetTotal',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.6),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: _isRecordedVariant
                      ? ListView(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                          children: [
                            for (final group in moduleGroups) ...[
                              _ModuleHeader(
                                label: group.moduleLabel,
                                unitCount: group.units.length,
                                lessonCount: group.lessonCount,
                                expanded: _isModuleExpanded(group.moduleLabel),
                                onToggle: () =>
                                    _toggleModuleExpanded(group.moduleLabel),
                                onClear: _recordedAssetBusy
                                    ? null
                                    : () => _clearRecordedModuleAssets(
                                        group.moduleLabel,
                                      ),
                                onBulkUpload: _recordedAssetBusy
                                    ? null
                                    : () => _bulkUploadRecordedModuleAssets(
                                        group.moduleLabel,
                                      ),
                                onEditLabel: () => _editModuleLabel(group),
                              ),
                              if (_isModuleExpanded(group.moduleLabel))
                                for (final pair in group.units)
                                  _UnitCard(
                                    key: ValueKey(pair.value.id),
                                    unitNumber: pair.key + 1,
                                    unit: pair.value,
                                    isExpanded: _isExpanded(pair.value.id),
                                    onToggleExpanded: () =>
                                        _toggleExpanded(pair.value.id),
                                    onEdit: () => _editUnit(pair.key),
                                    onDelete: () => _deleteUnit(pair.key),
                                    onAddSession: () => _addSession(pair.key),
                                    onReorderSession: (oldI, newI) {
                                      if (newI > oldI) newI -= 1;
                                      _moveSession(pair.key, oldI, newI);
                                    },
                                    onEditSession: (sessionIndex) =>
                                        _editSession(pair.key, sessionIndex),
                                    onDeleteSession: (sessionIndex) =>
                                        _deleteSession(pair.key, sessionIndex),
                                    isRecorded: true,
                                    onClearAssets: () =>
                                        _clearRecordedUnitAssets(pair.key),
                                    onBulkUpload: () =>
                                        _bulkUploadRecordedUnitAssets(pair.key),
                                    actionsEnabled: !_recordedAssetBusy,
                                    assetPresenceBySessionId:
                                        _lessonPresenceBySessionId,
                                  ),
                              const SizedBox(height: 8),
                            ],
                          ],
                        )
                      : ReorderableListView.builder(
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
                              isRecorded: false,
                              actionsEnabled: true,
                              assetPresenceBySessionId: const {},
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

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  List<SyllabusUnit> _parseRecordedUnits(Map<String, dynamic> root) {
    final rawModules = _asListOfMaps(root['modules']);
    if (rawModules.isEmpty) {
      return _asListOfMaps(
        root['units'],
      ).map((x) => SyllabusUnit.fromMap(x)).toList();
    }

    final units = <SyllabusUnit>[];

    for (int mi = 0; mi < rawModules.length; mi++) {
      final module = rawModules[mi];
      final moduleOrder = _toInt(module['order'], fallback: mi + 1);
      final moduleLabel =
          (module['otherTitle'] ?? '').toString().trim().isNotEmpty
          ? (module['otherTitle'] ?? '').toString().trim()
          : ((module['title'] ?? '').toString().trim().isNotEmpty
                ? (module['title'] ?? '').toString().trim()
                : 'Module ${mi + 1}');
      final rawUnits = _asListOfMaps(module['units']);

      for (int ui = 0; ui < rawUnits.length; ui++) {
        final unit = rawUnits[ui];
        final unitOrder = _toInt(unit['order'], fallback: ui + 1);
        final rawLessons = _asListOfMaps(unit['lessons']);
        final sessions = rawLessons.map(SyllabusSession.fromMap).toList()
          ..sort((a, b) => a.order.compareTo(b.order));

        units.add(
          SyllabusUnit(
            id: (unit['id'] ?? '').toString().trim().isNotEmpty
                ? (unit['id'] ?? '').toString().trim()
                : _newId(),
            title: (unit['title'] ?? '').toString(),
            otherTitle: moduleLabel,
            description: (unit['description'] ?? '').toString(),
            order: (moduleOrder * 1000) + unitOrder,
            sessions: sessions,
          ),
        );
      }
    }

    return units;
  }

  List<Map<String, dynamic>> _buildRecordedModulesPayload() {
    final grouped = <String, List<SyllabusUnit>>{};
    final moduleLabels = <String>[];

    for (int i = 0; i < _units.length; i++) {
      final unit = _units[i];
      final label = unit.otherTitle.trim().isNotEmpty
          ? unit.otherTitle.trim()
          : 'Module ${i + 1}';
      if (!grouped.containsKey(label)) {
        grouped[label] = <SyllabusUnit>[];
        moduleLabels.add(label);
      }
      grouped[label]!.add(unit);
    }

    final modules = <Map<String, dynamic>>[];
    for (int mi = 0; mi < moduleLabels.length; mi++) {
      final label = moduleLabels[mi];
      final units = grouped[label] ?? <SyllabusUnit>[];
      modules.add({
        'id': 'module_${mi + 1}',
        'title': label,
        'otherTitle': label,
        'description': '',
        'order': mi + 1,
        'units': [
          for (int ui = 0; ui < units.length; ui++)
            {
              'id': units[ui].id,
              'title': units[ui].title,
              'otherTitle': '',
              'description': units[ui].description,
              'order': ui + 1,
              'lessons': units[ui].sessions
                  .map(
                    (s) => s.toMap(
                      includeRecordedExtras: true,
                      includeOnlineExtras: false,
                    ),
                  )
                  .toList(),
            },
        ],
      });
    }

    return modules;
  }

  List<_ModuleUnitGroup> _groupUnitsByModule() {
    final grouped = <String, List<MapEntry<int, SyllabusUnit>>>{};
    final order = <String>[];
    for (int i = 0; i < _units.length; i++) {
      final unit = _units[i];
      final label = unit.otherTitle.trim().isNotEmpty
          ? unit.otherTitle.trim()
          : 'Module ${i + 1}';
      if (!grouped.containsKey(label)) {
        grouped[label] = <MapEntry<int, SyllabusUnit>>[];
        order.add(label);
      }
      grouped[label]!.add(MapEntry(i, unit));
    }

    return [
      for (final label in order)
        _ModuleUnitGroup(moduleLabel: label, units: grouped[label] ?? const []),
    ];
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

  bool _isModuleExpanded(String moduleLabel) =>
      _moduleExpanded[moduleLabel] ?? true;

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

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '-';
    const units = ['B', 'KB', 'MB', 'GB'];
    double value = bytes.toDouble();
    int unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex += 1;
    }
    final decimals = value >= 10 || unitIndex == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  String _fmtDateFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _openCourseBook() async {
    final url = _courseBook?.url.trim() ?? '';
    if (url.isEmpty) {
      AppToast.show(
        context,
        'No course book uploaded yet.',
        type: AppToastType.info,
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      AppToast.show(
        context,
        'Course book URL is invalid.',
        type: AppToastType.error,
      );
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.show(
        context,
        'Could not open the course book.',
        type: AppToastType.error,
      );
    }
  }

  Future<void> _uploadCourseBook() async {
    if (_courseBookBusy || _loading || _saving) return;
    setState(() => _courseBookBusy = true);
    try {
      if (mounted) {
        setState(() {
          _uploadingCourseBook = true;
          _courseBookUploadProgress = 0;
        });
      }
      final pickedRes = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        withData: false,
      );
      if (pickedRes == null || pickedRes.files.isEmpty) return;

      final picked = pickedRes.files.single;
      debugPrint(
        '[CourseBookUpload] picked name=${picked.name} size=${picked.size} '
        'hasPath=${(picked.path ?? '').trim().isNotEmpty} '
        'hasBytes=${picked.bytes != null}',
      );
      final ext = picked.extension?.trim().toLowerCase() ?? '';
      if (ext != 'pdf') {
        throw Exception('Only PDF files are allowed for course book.');
      }
      final hasPath = (picked.path ?? '').trim().isNotEmpty;
      final hasBytes = picked.bytes != null;
      if (!hasPath && !hasBytes) {
        throw Exception(
          'Could not read selected PDF from your file provider. '
          'Try selecting from local storage or another file app.',
        );
      }

      final courseMap = await _loadCourseMeta();
      final courseCode = (courseMap['course_code'] ?? '').toString();
      final courseTitle = (courseMap['title'] ?? widget.courseTitle).toString();
      final folder = _SyllabusServerStorage.buildCourseFolderName(
        courseCode: courseCode,
        courseTitle: courseTitle,
      );
      final variantFolder = _SyllabusServerStorage.sanitizeSegment(
        widget.variantKey,
        fallback: 'variant',
      );
      final uploadPath = '$folder/$variantFolder/books';

      final url = await _SyllabusServerStorage.uploadPlatformFile(
        file: picked,
        root: 'courses',
        path: uploadPath,
        customName: 'course_book',
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _courseBookUploadProgress = p);
        },
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      setState(() {
        _courseBook = _CourseBookAsset(
          url: url,
          name: picked.name.trim(),
          ext: 'pdf',
          sizeBytes: picked.size,
          uploadedAt: now,
          uploadedByUid: uid,
        );
      });
      await _saveSyllabus(showToast: false);
      if (!mounted) return;
      AppToast.show(
        context,
        'Course book uploaded.',
        type: AppToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not upload course book.'),
        type: AppToastType.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _courseBookBusy = false;
          _uploadingCourseBook = false;
          _courseBookUploadProgress = 0;
        });
      }
    }
  }

  Future<void> _removeCourseBook() async {
    if (_courseBookBusy || _courseBook == null) return;
    final ok = await _confirm(
      title: 'Remove course book?',
      message:
          'This removes the course-level PDF book from this flexible syllabus. Lesson materials are not affected.',
      confirmText: 'Remove',
      danger: true,
    );
    if (!ok) return;

    setState(() => _courseBookBusy = true);
    try {
      setState(() => _courseBook = null);
      await _saveSyllabus(showToast: false);
      if (!mounted) return;
      AppToast.show(
        context,
        'Course book removed.',
        type: AppToastType.success,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not remove course book.'),
        type: AppToastType.error,
      );
    } finally {
      if (mounted) setState(() => _courseBookBusy = false);
    }
  }

  Widget _courseBookPanel() {
    final book = _courseBook;
    final hasBook = book != null && book.url.trim().isNotEmpty;
    final uploadedAt = hasBook ? _fmtDateFromMs(book.uploadedAt) : '';
    final fileSize = hasBook ? _fmtBytes(book.sizeBytes) : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.menu_book_rounded, color: Color(0xFF1A2B48)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Course Digital Book (PDF)',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hasBook
                  ? '${book.name.isEmpty ? 'PDF uploaded' : book.name} ${fileSize.isEmpty ? '' : '• $fileSize'} ${uploadedAt.isEmpty ? '' : '• $uploadedAt'}'
                  : 'Upload one PDF for this variant. This is separate from lesson materials.',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.66),
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: (_courseBookBusy || _saving || _loading)
                      ? null
                      : _uploadCourseBook,
                  icon: _uploadingCourseBook
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          hasBook
                              ? Icons.upload_file_rounded
                              : Icons.attach_file_rounded,
                        ),
                  label: Text(
                    _uploadingCourseBook
                        ? 'Uploading ${(_courseBookUploadProgress * 100).round()}%'
                        : (hasBook ? 'Replace PDF' : 'Upload PDF'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: hasBook ? _openCourseBook : null,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open'),
                ),
                if (hasBook)
                  OutlinedButton.icon(
                    onPressed: _courseBookBusy ? null : _removeCourseBook,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Remove'),
                  ),
              ],
            ),
            if (_uploadingCourseBook) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 7,
                  value: _courseBookUploadProgress.clamp(0.0, 1.0).toDouble(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _toggleExpanded(String unitId) {
    setState(() => _unitExpanded[unitId] = !(_unitExpanded[unitId] ?? true));
  }

  void _editModuleLabel(_ModuleUnitGroup group) {
    final controller = TextEditingController(text: group.moduleLabel);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit module title'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Module title',
            hintText: 'e.g. Module 1, Theme A, ...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newLabel = controller.text.trim();
              if (newLabel.isNotEmpty && newLabel != group.moduleLabel) {
                for (final entry in group.units) {
                  _units[entry.key] = entry.value.copyWith(
                    otherTitle: newLabel,
                  );
                }
                await _autoSaveIfRecorded(
                  successMessage: 'Module title updated',
                );
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _toggleModuleExpanded(String moduleLabel) {
    setState(
      () => _moduleExpanded[moduleLabel] =
          !(_moduleExpanded[moduleLabel] ?? true),
    );
  }
}

class _CourseBookAsset {
  const _CourseBookAsset({
    required this.url,
    required this.name,
    required this.ext,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.uploadedByUid,
  });

  final String url;
  final String name;
  final String ext;
  final int sizeBytes;
  final int uploadedAt;
  final String uploadedByUid;

  static _CourseBookAsset? fromAny(dynamic node) {
    if (node is! Map) return null;
    final map = Map<String, dynamic>.from(
      node.map((k, v) => MapEntry(k.toString(), v)),
    );
    final url = (map['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    int asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    return _CourseBookAsset(
      url: url,
      name: (map['name'] ?? '').toString().trim(),
      ext: (map['ext'] ?? 'pdf').toString().trim().toLowerCase(),
      sizeBytes: asInt(map['sizeBytes']),
      uploadedAt: asInt(map['uploadedAt']),
      uploadedByUid: (map['uploadedByUid'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'name': name,
      'ext': ext,
      'sizeBytes': sizeBytes,
      'uploadedAt': uploadedAt,
      'uploadedByUid': uploadedByUid,
    };
  }
}

class LessonFileAsset {
  const LessonFileAsset({
    required this.url,
    required this.name,
    required this.ext,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.uploadedByUid,
    required this.kind,
  });

  final String url;
  final String name;
  final String ext;
  final int sizeBytes;
  final int uploadedAt;
  final String uploadedByUid;
  final String kind;

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static LessonFileAsset? fromAny(dynamic node) {
    if (node is! Map) return null;
    final map = Map<String, dynamic>.from(
      node.map((k, v) => MapEntry(k.toString(), v)),
    );
    final url = (map['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    final kind = (map['kind'] ?? '').toString().trim().toLowerCase();
    return LessonFileAsset(
      url: url,
      name: (map['name'] ?? '').toString().trim(),
      ext: (map['ext'] ?? '').toString().trim().toLowerCase(),
      sizeBytes: _asInt(map['sizeBytes']),
      uploadedAt: _asInt(map['uploadedAt']),
      uploadedByUid: (map['uploadedByUid'] ?? '').toString().trim(),
      kind: kind.isEmpty ? 'file' : kind,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'name': name,
      'ext': ext,
      'sizeBytes': sizeBytes,
      'uploadedAt': uploadedAt,
      'uploadedByUid': uploadedByUid,
      'kind': kind,
    };
  }
}

class _ModuleUnitGroup {
  const _ModuleUnitGroup({required this.moduleLabel, required this.units});

  final String moduleLabel;
  final List<MapEntry<int, SyllabusUnit>> units;

  int get lessonCount =>
      units.fold<int>(0, (sum, e) => sum + e.value.sessions.length);
}

class _RecordedBulkTarget {
  const _RecordedBulkTarget({
    required this.unitIndex,
    required this.sessionIndex,
    required this.session,
  });

  final int unitIndex;
  final int sessionIndex;
  final SyllabusSession session;
}

class _LessonAssetPresence {
  const _LessonAssetPresence({required this.videoOk, required this.htmlOk});

  final bool videoOk;
  final bool htmlOk;
}

class _SyllabusServerStorage {
  static final Uri uploadUrl = BackendApi.uri('upload_file_secure.php');
  static final Uri listUrl = BackendApi.uri('list_items_secure.php');
  static final Uri deleteUrl = BackendApi.uri('delete_item_secure.php');

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
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    _debug(
      'upload start root=$root path=$path customName=$customName '
      'file=${file.name} uidPresent=${uid.isNotEmpty} tokenLen=${token.length}',
    );

    final uploadUri = await BackendApi.withAuthQuery(uploadUrl);

    final req = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(req);
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

    final contentLen = req.contentLength;
    onProgress?.call(0);
    final client = http.Client();
    http.Response response;
    try {
      http.StreamedResponse streamed;
      if (onProgress != null && contentLen > 0) {
        final source = req.finalize();
        final tracked = http.StreamedRequest('POST', uploadUri)
          ..headers.addAll(req.headers)
          ..contentLength = contentLen;

        var uploaded = 0;
        final done = Completer<void>();
        source.listen(
          (chunk) {
            uploaded += chunk.length;
            final ratio = (uploaded / contentLen).clamp(0.0, 0.95).toDouble();
            onProgress(ratio);
            tracked.sink.add(chunk);
          },
          onDone: () {
            tracked.sink.close();
            done.complete();
          },
          onError: (Object err, StackTrace st) {
            tracked.sink.addError(err, st);
            tracked.sink.close();
            if (!done.isCompleted) done.completeError(err, st);
          },
          cancelOnError: true,
        );
        await done.future;
        streamed = await client
            .send(tracked)
            .timeout(const Duration(minutes: 15));
      } else {
        streamed = await client.send(req).timeout(const Duration(minutes: 15));
      }
      onProgress?.call(0.98);
      response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(minutes: 5));
    } finally {
      client.close();
    }
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

    final deleteUri = await BackendApi.withAuthQuery(deleteUrl);

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

  static Future<List<Map<String, dynamic>>> listItems({
    required String root,
    required String path,
  }) async {
    final authFields = await BackendApi.authFormFields();
    final headers = await BackendApi.authHeaders();
    final listUri = await BackendApi.withAuthQuery(listUrl);

    final r = await http
        .post(
          listUri,
          headers: headers,
          body: {'root': root, 'path': path, ...authFields},
        )
        .timeout(const Duration(seconds: 60));

    final raw = r.body.trim();
    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.\n$raw');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid list response');
    }

    if (data['success'] != true) {
      throw Exception((data['message'] ?? 'List failed').toString());
    }

    final out = <Map<String, dynamic>>[];
    final rawItems = data['items'];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map) {
          out.add(Map<String, dynamic>.from(item));
        }
      }
    }
    return out;
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
  const _HeaderStats({
    required this.units,
    required this.sessions,
    this.modules,
    this.unitsLabel = 'Units',
    this.sessionsLabel = 'Sessions',
    this.hint = 'Drag units to reorder',
  });

  final int units;
  final int sessions;
  final int? modules;
  final String unitsLabel;
  final String sessionsLabel;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (modules != null) _Pill(label: '$modules Modules'),
              _Pill(label: '$units $unitsLabel'),
              _Pill(label: '$sessions $sessionsLabel'),
            ],
          ),
          if (hint.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              style: TextStyle(color: Colors.black.withValues(alpha: 0.55)),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModuleHeader extends StatelessWidget {
  const _ModuleHeader({
    required this.label,
    required this.unitCount,
    required this.lessonCount,
    required this.expanded,
    required this.onToggle,
    this.onClear,
    this.onBulkUpload,
    this.onEditLabel,
  });

  final String label;
  final int unitCount;
  final int lessonCount;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onClear;
  final VoidCallback? onBulkUpload;
  final VoidCallback? onEditLabel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFBFDBFE)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$label • $unitCount units • $lessonCount lessons',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1E3A8A),
                ),
              ),
            ),
            Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: const Color(0xFF1E3A8A),
            ),
            if (onEditLabel != null)
              IconButton(
                tooltip: 'Edit module title',
                onPressed: onEditLabel,
                icon: const Icon(Icons.edit_outlined, size: 18),
                color: const Color(0xFF2563EB),
              ),
            IconButton(
              tooltip: 'Bulk upload module assets',
              onPressed: onBulkUpload,
              icon: const Icon(Icons.upload_file_rounded),
              color: const Color(0xFF2563EB),
            ),
            IconButton(
              tooltip: 'Clear module assets',
              onPressed: onClear,
              icon: const Icon(Icons.delete_outline_rounded),
              color: const Color(0xFFDC2626),
            ),
          ],
        ),
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
    this.isRecorded = false,
    this.onClearAssets,
    this.onBulkUpload,
    this.actionsEnabled = true,
    this.assetPresenceBySessionId = const {},
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
  final bool isRecorded;
  final VoidCallback? onClearAssets;
  final VoidCallback? onBulkUpload;
  final bool actionsEnabled;
  final Map<String, _LessonAssetPresence> assetPresenceBySessionId;

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                  '${unit.sessions.length} ${isRecorded ? 'lessons' : 'sessions'}',
                  style: TextStyle(color: Colors.black.withValues(alpha: 0.55)),
                ),
                if (isRecorded)
                  IconButton(
                    onPressed: actionsEnabled ? onBulkUpload : null,
                    tooltip: 'Bulk upload unit',
                    icon: const Icon(Icons.upload_file_rounded),
                    color: const Color(0xFF2563EB),
                  ),
                if (isRecorded)
                  IconButton(
                    onPressed: actionsEnabled ? onClearAssets : null,
                    tooltip: 'Clear unit assets',
                    icon: const Icon(Icons.delete_outline_rounded),
                    color: const Color(0xFFDC2626),
                  ),
                IconButton(
                  onPressed: actionsEnabled ? onAddSession : null,
                  tooltip: isRecorded ? 'Add lesson' : 'Add session',
                  icon: const Icon(Icons.add),
                  color: const Color(0xFF0F172A),
                ),
              ],
            ),
            if (!isExpanded)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Collapsed • ${unit.sessions.length} ${isRecorded ? 'lessons' : 'sessions'}',
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
                    isRecorded
                        ? 'No lessons yet. Add your first lesson.'
                        : 'No sessions yet. Add your first session.',
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
                      '${isRecorded ? 'Lesson' : 'Session'} ${s.sessionNumber <= 0 ? (i + 1) : s.sessionNumber} • ${s.title.isEmpty ? '(Untitled ${isRecorded ? 'lesson' : 'session'})' : s.title}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${s.skillType.label} • ${s.durationMinutes} min',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -1),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isRecorded)
                          Icon(
                            Icons.ondemand_video_rounded,
                            size: 18,
                            color:
                                (assetPresenceBySessionId[s.id]?.videoOk ??
                                    s.videoUrl.trim().isNotEmpty)
                                ? const Color(0xFF16A34A)
                                : const Color(0xFF94A3B8),
                          ),
                        if (isRecorded) const SizedBox(width: 6),
                        if (isRecorded)
                          Icon(
                            Icons.description_rounded,
                            size: 18,
                            color:
                                (assetPresenceBySessionId[s.id]?.htmlOk ??
                                    s.materialsUrl.trim().isNotEmpty)
                                ? const Color(0xFF2563EB)
                                : const Color(0xFF94A3B8),
                          ),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') onEditSession(i);
                            if (v == 'delete') onDeleteSession(i);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        ),
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
    this.homeworkUrl = '',
    this.serverFolderPath = '',
    this.lessonFiles = const <LessonFileAsset>[],
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
  final String homeworkUrl;
  final String serverFolderPath;
  final List<LessonFileAsset> lessonFiles;
}

class _SessionUploadQueueItem {
  const _SessionUploadQueueItem({
    required this.fileName,
    required this.kind,
    required this.sizeBytes,
    this.progress = 0,
    this.status = 'queued',
    this.startedAtMs = 0,
    this.finishedAtMs = 0,
    this.elapsedMs = 0,
    this.speedBytesPerSec = 0,
    this.etaMs = 0,
    this.error = '',
  });

  final String fileName;
  final String kind;
  final int sizeBytes;
  final double progress;
  final String status;
  final int startedAtMs;
  final int finishedAtMs;
  final int elapsedMs;
  final double speedBytesPerSec;
  final int etaMs;
  final String error;

  _SessionUploadQueueItem copyWith({
    double? progress,
    String? status,
    int? startedAtMs,
    int? finishedAtMs,
    int? elapsedMs,
    double? speedBytesPerSec,
    int? etaMs,
    String? error,
  }) {
    return _SessionUploadQueueItem(
      fileName: fileName,
      kind: kind,
      sizeBytes: sizeBytes,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      startedAtMs: startedAtMs ?? this.startedAtMs,
      finishedAtMs: finishedAtMs ?? this.finishedAtMs,
      elapsedMs: elapsedMs ?? this.elapsedMs,
      speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
      etaMs: etaMs ?? this.etaMs,
      error: error ?? this.error,
    );
  }
}

class _SessionEditorSheet extends StatefulWidget {
  const _SessionEditorSheet({
    required this.title,
    required this.initial,
    required this.isRecorded,
    required this.variantKey,
    required this.courseFolderName,
    required this.suggestedSessionNumber,
  });

  final String title;
  final _SessionDraft initial;
  final bool isRecorded;
  final String variantKey;
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
  late final TextEditingController homeworkUrlC;

  SkillType _skill = SkillType.listening;

  bool _uploadingVideo = false;
  bool _uploadingMaterials = false;
  bool _uploadingHomework = false;
  double _videoUploadProgress = 0;
  double _materialsUploadProgress = 0;
  double _homeworkUploadProgress = 0;
  bool _recordedAssetFlowBusy = false;
  bool _verifyingServerState = false;
  final bool _showLegacyFileList = false;
  bool _videoExistsOnServer = false;
  bool _materialsExistOnServer = false;
  bool _homeworkExistsOnServer = false;
  late String _serverFolderPath;
  late List<LessonFileAsset> _lessonFiles;
  List<_SessionUploadQueueItem> _uploadQueue = <_SessionUploadQueueItem>[];

  String _fmtDuration(int ms) {
    final s = (ms / 1000).floor();
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  String _fmtSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '-';
    const kb = 1024.0;
    const mb = kb * 1024;
    if (bytesPerSec >= mb) {
      return '${(bytesPerSec / mb).toStringAsFixed(2)} MB/s';
    }
    return '${(bytesPerSec / kb).toStringAsFixed(0)} KB/s';
  }

  String _fmtEta(int etaMs) {
    if (etaMs <= 0) return '-';
    return _fmtDuration(etaMs);
  }

  Future<List<LessonFileAsset>> _uploadFilesWithTracking({
    required List<PlatformFile> files,
    required String path,
    required String Function(String kind) suffixFor,
    required String Function(PlatformFile file) kindFor,
    required void Function(double progress) onOverallProgress,
  }) async {
    final uploaded = <LessonFileAsset>[];
    if (mounted) {
      setState(() {
        _uploadQueue = files
            .map(
              (f) => _SessionUploadQueueItem(
                fileName: f.name,
                kind: kindFor(f),
                sizeBytes: f.size,
              ),
            )
            .toList();
      });
    }

    for (int i = 0; i < files.length; i++) {
      final file = files[i];
      final kind = kindFor(file);
      final startMs = DateTime.now().millisecondsSinceEpoch;
      if (mounted) {
        setState(() {
          _uploadQueue[i] = _uploadQueue[i].copyWith(
            status: 'uploading',
            startedAtMs: startMs,
          );
        });
      }

      try {
        final url = await _SyllabusServerStorage.uploadPlatformFile(
          file: file,
          root: 'courses',
          path: path,
          customName: _SyllabusServerStorage.buildCustomBaseName(
            sessionNumber: widget.suggestedSessionNumber,
            suffix: suffixFor(kind),
          ),
          onProgress: (p) {
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            final elapsedMs = (nowMs - startMs).clamp(1, 1 << 30);
            final uploadedBytes = file.size * p;
            final speed = uploadedBytes / (elapsedMs / 1000.0);
            final remainingBytes = (file.size - uploadedBytes).clamp(
              0,
              file.size,
            );
            final etaMs = speed > 0
                ? ((remainingBytes / speed) * 1000).round()
                : 0;
            if (!mounted) return;
            setState(() {
              _uploadQueue[i] = _uploadQueue[i].copyWith(
                progress: p.clamp(0.0, 1.0).toDouble(),
                elapsedMs: elapsedMs,
                speedBytesPerSec: speed,
                etaMs: etaMs,
              );
              onOverallProgress(
                ((i + p) / files.length).clamp(0.0, 1.0).toDouble(),
              );
            });
          },
        );

        final finishedMs = DateTime.now().millisecondsSinceEpoch;
        final elapsedMs = (finishedMs - startMs).clamp(1, 1 << 30);
        final speed = file.size / (elapsedMs / 1000.0);
        if (mounted) {
          setState(() {
            _uploadQueue[i] = _uploadQueue[i].copyWith(
              status: 'done',
              progress: 1,
              finishedAtMs: finishedMs,
              elapsedMs: elapsedMs,
              speedBytesPerSec: speed,
              etaMs: 0,
            );
            onOverallProgress(((i + 1) / files.length).clamp(0.0, 1.0));
          });
        }

        uploaded.add(
          LessonFileAsset(
            url: url,
            name: file.name,
            ext: _fileExt(file.name),
            sizeBytes: file.size,
            uploadedAt: DateTime.now().millisecondsSinceEpoch,
            uploadedByUid: FirebaseAuth.instance.currentUser?.uid ?? '',
            kind: kind,
          ),
        );
      } catch (e) {
        if (mounted) {
          setState(() {
            _uploadQueue[i] = _uploadQueue[i].copyWith(
              status: 'failed',
              error: e.toString(),
            );
          });
        }
      }
    }

    return uploaded;
  }

  bool get _recordedAssetsBusy =>
      _recordedAssetFlowBusy ||
      _uploadingVideo ||
      _uploadingMaterials ||
      _uploadingHomework ||
      _verifyingServerState;

  bool get _hasInitialRecordedAssets =>
      widget.initial.serverFolderPath.trim().isNotEmpty ||
      widget.initial.videoUrl.trim().isNotEmpty ||
      widget.initial.materialsUrl.trim().isNotEmpty ||
      widget.initial.homeworkUrl.trim().isNotEmpty;

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
    homeworkUrlC = TextEditingController(text: widget.initial.homeworkUrl);
    _serverFolderPath = widget.initial.serverFolderPath.trim();
    _lessonFiles = List<LessonFileAsset>.from(widget.initial.lessonFiles);
    if (_lessonFiles.isEmpty) {
      final legacy = <LessonFileAsset>[];
      final videoUrl = widget.initial.videoUrl.trim();
      final htmlUrl = widget.initial.materialsUrl.trim();
      final homeworkUrl = widget.initial.homeworkUrl.trim();
      if (videoUrl.isNotEmpty) {
        legacy.add(
          LessonFileAsset(
            url: videoUrl,
            name: _fileNameFromUrl(videoUrl),
            ext: _fileExt(_fileNameFromUrl(videoUrl)),
            sizeBytes: 0,
            uploadedAt: 0,
            uploadedByUid: '',
            kind: 'video',
          ),
        );
      }
      if (htmlUrl.isNotEmpty) {
        legacy.add(
          LessonFileAsset(
            url: htmlUrl,
            name: _fileNameFromUrl(htmlUrl),
            ext: _fileExt(_fileNameFromUrl(htmlUrl)),
            sizeBytes: 0,
            uploadedAt: 0,
            uploadedByUid: '',
            kind: 'html',
          ),
        );
      }
      if (homeworkUrl.isNotEmpty) {
        legacy.add(
          LessonFileAsset(
            url: homeworkUrl,
            name: _fileNameFromUrl(homeworkUrl),
            ext: _fileExt(_fileNameFromUrl(homeworkUrl)),
            sizeBytes: 0,
            uploadedAt: 0,
            uploadedByUid: '',
            kind: 'homework',
          ),
        );
      }
      _lessonFiles = legacy;
    }
    _skill = widget.initial.skillType;

    if (widget.isRecorded) {
      unawaited(_syncRecordedAssetStateWithServer());
    }
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
    homeworkUrlC.dispose();
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

  String _canonicalSessionFolderPath() {
    final variantFolder = _SyllabusServerStorage.sanitizeSegment(
      widget.variantKey,
      fallback: 'variant',
    );
    final sessionFolder = _SyllabusServerStorage.buildSessionFolderName(
      sessionNumber: widget.suggestedSessionNumber,
      sessionTitle: titleC.text.trim(),
    );

    _serverFolderPath =
        '${widget.courseFolderName}/$variantFolder/$sessionFolder';
    return _serverFolderPath;
  }

  String _resolvedSessionFolderPath() {
    final canonical = _canonicalSessionFolderPath();
    final stored = _serverFolderPath.trim();
    if (stored.isEmpty) return canonical;
    final expectedPrefix =
        '${widget.courseFolderName}/${_SyllabusServerStorage.sanitizeSegment(widget.variantKey, fallback: 'variant')}/';
    if (!stored.startsWith(expectedPrefix)) {
      return canonical;
    }
    return stored;
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
        _lessonFiles.removeWhere((x) => x.kind == 'video');
        _videoExistsOnServer = false;
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
        _lessonFiles.removeWhere((x) => x.kind == 'html');
        _materialsExistOnServer = false;
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

  Future<void> _clearHomeworkHtmlOnly() async {
    if (_recordedAssetsBusy) {
      _debug('clearHomeworkHtml ignored busy=true');
      return;
    }

    if (homeworkUrlC.text.trim().isEmpty) {
      _debug('clearHomeworkHtml skipped (nothing to clear)');
      return;
    }

    final ok = await _confirmClearAsset(
      title: 'Remove homework HTML?',
      message:
          'This will remove the homework HTML from this session. Learners will no longer see homework in Prepare.',
      confirmText: 'Remove',
    );

    if (!ok) return;
    final oldHtmlUrl = homeworkUrlC.text.trim();
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
          } catch (e) {
            final msg = e.toString().toLowerCase();
            if (!msg.contains('item not found')) rethrow;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        homeworkUrlC.clear();
        _lessonFiles.removeWhere((x) => x.kind == 'homework');
        _homeworkExistsOnServer = false;
        _inlineError = null;
      });
    } catch (e) {
      _showInlineError('Could not remove homework HTML: $e');
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

  String _fileExt(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot >= name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  bool _isVideoExt(String ext) {
    return const {'mp4', 'm4v', 'mov', 'webm'}.contains(ext);
  }

  bool _isHtmlExt(String ext) {
    return ext == 'html' || ext == 'htm';
  }

  Future<void> _removeLessonFileAt(int index) async {
    if (index < 0 || index >= _lessonFiles.length) return;
    final file = _lessonFiles[index];
    final ok = await _confirmClearAsset(
      title: 'Delete file?',
      message: 'This will delete "${file.name}" from server and lesson data.',
      confirmText: 'Delete',
    );
    if (!ok) return;

    if (!mounted) return;
    setState(() => _recordedAssetFlowBusy = true);
    try {
      final rel = _SyllabusServerStorage.extractRelativePathFromUrl(file.url);
      if (rel.isNotEmpty) {
        await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
      }
      if (!mounted) return;
      setState(() {
        _lessonFiles.removeAt(index);
        final video = _lessonFiles.lastWhere(
          (x) => x.kind == 'video',
          orElse: () => const LessonFileAsset(
            url: '',
            name: '',
            ext: '',
            sizeBytes: 0,
            uploadedAt: 0,
            uploadedByUid: '',
            kind: 'video',
          ),
        );
        final html = _lessonFiles.lastWhere(
          (x) => x.kind == 'html',
          orElse: () => const LessonFileAsset(
            url: '',
            name: '',
            ext: '',
            sizeBytes: 0,
            uploadedAt: 0,
            uploadedByUid: '',
            kind: 'html',
          ),
        );
        final homework = _lessonFiles.lastWhere(
          (x) => x.kind == 'homework',
          orElse: () => const LessonFileAsset(
            url: '',
            name: '',
            ext: '',
            sizeBytes: 0,
            uploadedAt: 0,
            uploadedByUid: '',
            kind: 'homework',
          ),
        );
        videoUrlC.text = video.url;
        if (video.url.isEmpty) videoThumbC.clear();
        materialsUrlC.text = html.url;
        homeworkUrlC.text = homework.url;
        _videoExistsOnServer = video.url.isNotEmpty;
        _materialsExistOnServer = html.url.isNotEmpty;
        _homeworkExistsOnServer = homework.url.isNotEmpty;
      });
    } catch (e) {
      _showInlineError('Could not delete file: $e');
    } finally {
      if (mounted) setState(() => _recordedAssetFlowBusy = false);
    }
  }

  Future<bool> _assetUrlExistsOnServer(
    String url,
    Map<String, List<Map<String, dynamic>>> listCache,
  ) async {
    final rel = _SyllabusServerStorage.extractRelativePathFromUrl(url);
    if (rel.isEmpty) return false;

    final segments = rel
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (segments.length < 2) return false;

    final fileName = segments.last;
    final folderPath = segments.sublist(0, segments.length - 1).join('/');

    if (!listCache.containsKey(folderPath)) {
      listCache[folderPath] = await _SyllabusServerStorage.listItems(
        root: 'courses',
        path: folderPath,
      );
    }

    final items = listCache[folderPath] ?? const <Map<String, dynamic>>[];
    for (final item in items) {
      final type = (item['type'] ?? '').toString().trim().toLowerCase();
      final name = (item['name'] ?? '').toString().trim();
      if (type != 'folder' && name == fileName) {
        return true;
      }
    }
    return false;
  }

  Future<void> _syncRecordedAssetStateWithServer() async {
    final videoUrl = videoUrlC.text.trim();
    final materialsUrl = materialsUrlC.text.trim();
    final homeworkUrl = homeworkUrlC.text.trim();

    if (videoUrl.isEmpty && materialsUrl.isEmpty && homeworkUrl.isEmpty) {
      if (!mounted) return;
      setState(() {
        _videoExistsOnServer = false;
        _materialsExistOnServer = false;
        _homeworkExistsOnServer = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _verifyingServerState = true);

    try {
      final listCache = <String, List<Map<String, dynamic>>>{};
      final videoExists = videoUrl.isNotEmpty
          ? await _assetUrlExistsOnServer(videoUrl, listCache)
          : false;
      final htmlExists = materialsUrl.isNotEmpty
          ? await _assetUrlExistsOnServer(materialsUrl, listCache)
          : false;
      final homeworkExists = homeworkUrl.isNotEmpty
          ? await _assetUrlExistsOnServer(homeworkUrl, listCache)
          : false;

      if (!mounted) return;
      setState(() {
        _videoExistsOnServer = videoExists;
        _materialsExistOnServer = htmlExists;
        _homeworkExistsOnServer = homeworkExists;

        if (videoUrl.isNotEmpty && !videoExists) {
          videoUrlC.clear();
          videoThumbC.clear();
        }
        if (materialsUrl.isNotEmpty && !htmlExists) {
          materialsUrlC.clear();
        }
        if (homeworkUrl.isNotEmpty && !homeworkExists) {
          homeworkUrlC.clear();
        }

        if ((videoUrl.isNotEmpty && !videoExists) ||
            (materialsUrl.isNotEmpty && !htmlExists) ||
            (homeworkUrl.isNotEmpty && !homeworkExists)) {
          _inlineError =
              'Some stored asset URLs were stale and have been auto-cleared because files are missing on server.';
        }
      });
    } catch (e) {
      _debug('asset server sync error=$e');
      if (!mounted) return;
      setState(() {
        _inlineError =
            'Could not verify existing assets on server. You can still upload new files.';
      });
    } finally {
      if (mounted) {
        setState(() => _verifyingServerState = false);
      }
    }
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

      final prepared = await _prepareRecordedReplacementIfNeeded();
      if (!prepared) {
        _debug('video upload aborted by prepareReplacement=false');
        return;
      }

      setState(() => _uploadingVideo = true);
      setState(() => _videoUploadProgress = 0);

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        type: FileType.video,
      );

      if (result == null || result.files.isEmpty) {
        _debug('video upload cancelled at file picker');
        return;
      }

      final path = _resolvedSessionFolderPath();
      final nextFiles = List<LessonFileAsset>.from(_lessonFiles);
      final uploaded = await _uploadFilesWithTracking(
        files: result.files,
        path: path,
        suffixFor: (_) => 'video',
        kindFor: (_) => 'video',
        onOverallProgress: (p) => _videoUploadProgress = p,
      );
      nextFiles.addAll(uploaded);
      final latest = uploaded.isNotEmpty ? uploaded.last.url : '';

      if (!mounted) return;
      setState(() {
        _lessonFiles = nextFiles;
        if (latest.isNotEmpty) videoUrlC.text = latest;
        videoThumbC.clear();
        _videoExistsOnServer = latest.isNotEmpty;
        _inlineError = null;
      });
      _debug('video upload success count=${result.files.length}');
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

      final prepared = await _prepareRecordedReplacementIfNeeded();
      if (!prepared) {
        _debug('html upload aborted by prepareReplacement=false');
        return;
      }

      setState(() => _uploadingMaterials = true);
      setState(() => _materialsUploadProgress = 0);

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
        type: FileType.custom,
        allowedExtensions: const ['html', 'htm'],
      );

      if (result == null || result.files.isEmpty) {
        _debug('html upload cancelled at file picker');
        return;
      }

      final path = _resolvedSessionFolderPath();
      final nextFiles = List<LessonFileAsset>.from(_lessonFiles)
        ..removeWhere((x) => x.kind == 'html');
      final uploaded = await _uploadFilesWithTracking(
        files: result.files,
        path: path,
        suffixFor: (_) => 'materials',
        kindFor: (_) => 'html',
        onOverallProgress: (p) => _materialsUploadProgress = p,
      );
      nextFiles.addAll(uploaded);
      final latest = uploaded.isNotEmpty ? uploaded.last.url : '';

      if (!mounted) return;
      setState(() {
        _lessonFiles = nextFiles;
        if (latest.isNotEmpty) materialsUrlC.text = latest;
        _materialsExistOnServer = latest.isNotEmpty;
        _inlineError = null;
      });
      _debug('html upload success count=${result.files.length}');
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

  Future<void> _pickAndUploadHomeworkHtml() async {
    if (_recordedAssetsBusy) return;

    final title = titleC.text.trim();
    if (title.isEmpty) {
      _showInlineError('Enter session title first.');
      return;
    }

    if (mounted) {
      setState(() => _recordedAssetFlowBusy = true);
    }

    try {
      _clearInlineError();
      final prepared = await _prepareRecordedReplacementIfNeeded();
      if (!prepared) return;

      setState(() => _uploadingHomework = true);
      setState(() => _homeworkUploadProgress = 0);

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
        type: FileType.custom,
        allowedExtensions: const ['html', 'htm'],
      );

      if (result == null || result.files.isEmpty) return;

      final path = _resolvedSessionFolderPath();
      final nextFiles = List<LessonFileAsset>.from(_lessonFiles)
        ..removeWhere((x) => x.kind == 'homework');
      final uploaded = await _uploadFilesWithTracking(
        files: result.files,
        path: path,
        suffixFor: (_) => 'homework',
        kindFor: (_) => 'homework',
        onOverallProgress: (p) => _homeworkUploadProgress = p,
      );
      nextFiles.addAll(uploaded);
      final latest = uploaded.isNotEmpty ? uploaded.last.url : '';

      if (!mounted) return;
      setState(() {
        _lessonFiles = nextFiles;
        if (latest.isNotEmpty) homeworkUrlC.text = latest;
        _homeworkExistsOnServer = latest.isNotEmpty;
        _inlineError = null;
      });
    } catch (e) {
      _showInlineError('Homework HTML upload failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _uploadingHomework = false;
          _homeworkUploadProgress = 0;
          _recordedAssetFlowBusy = false;
        });
      }
    }
  }

  Future<void> _pickAndUploadAnyFiles() async {
    if (_recordedAssetsBusy) return;
    final title = titleC.text.trim();
    if (title.isEmpty) {
      _showInlineError('Enter session title first.');
      return;
    }

    if (mounted) setState(() => _recordedAssetFlowBusy = true);
    try {
      setState(() => _materialsUploadProgress = 0);
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;

      final path = _resolvedSessionFolderPath();
      final nextFiles = List<LessonFileAsset>.from(_lessonFiles);
      final uploaded = await _uploadFilesWithTracking(
        files: result.files,
        path: path,
        suffixFor: (kind) => kind,
        kindFor: (file) {
          final ext = _fileExt(file.name);
          if (_isVideoExt(ext)) return 'video';
          if (_isHtmlExt(ext)) return 'html';
          return 'file';
        },
        onOverallProgress: (p) => _materialsUploadProgress = p,
      );
      nextFiles.addAll(uploaded);
      for (final file in uploaded) {
        if (file.kind == 'video') {
          videoUrlC.text = file.url;
          _videoExistsOnServer = true;
        } else if (file.kind == 'html') {
          materialsUrlC.text = file.url;
          _materialsExistOnServer = true;
        }
      }

      if (!mounted) return;
      setState(() {
        _lessonFiles = nextFiles;
        _inlineError = null;
      });
    } catch (e) {
      _showInlineError('File upload failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _materialsUploadProgress = 0;
          _recordedAssetFlowBusy = false;
        });
      }
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
                        if (_verifyingServerState)
                          Text(
                            'Checking server state…',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.6),
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        else if (_videoExistsOnServer)
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
                                : (!_videoExistsOnServer
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
                        if (_videoExistsOnServer) ...[
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
                          'Lesson',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        if (_verifyingServerState)
                          Text(
                            'Checking server state…',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.6),
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        else if (_materialsExistOnServer)
                          Text(
                            _fileNameFromUrl(materialsUrlC.text.trim()),
                            style: TextStyle(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        else
                          const Text(
                            'No lesson HTML uploaded yet.',
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
                                : (!_materialsExistOnServer
                                      ? 'Upload Lesson'
                                      : 'Replace Lesson'),
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
                        if (_materialsExistOnServer) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _recordedAssetsBusy
                                ? null
                                : _clearHtmlOnly,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Remove Lesson'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red.shade700,
                              side: BorderSide(color: Colors.red.shade200),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        const Text(
                          'Homework',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        if (_verifyingServerState)
                          Text(
                            'Checking server state…',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.6),
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        else if (_homeworkExistsOnServer)
                          Text(
                            _fileNameFromUrl(homeworkUrlC.text.trim()),
                            style: TextStyle(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        else
                          const Text(
                            'No homework HTML uploaded yet.',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _recordedAssetsBusy
                              ? null
                              : _pickAndUploadHomeworkHtml,
                          icon: _uploadingHomework
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.assignment_rounded),
                          label: Text(
                            _uploadingHomework
                                ? 'Uploading ${(_homeworkUploadProgress * 100).round()}%'
                                : (!_homeworkExistsOnServer
                                      ? 'Upload Homework'
                                      : 'Replace Homework'),
                          ),
                        ),
                        if (_uploadingHomework) ...[
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 7,
                              value: _homeworkUploadProgress
                                  .clamp(0.0, 1.0)
                                  .toDouble(),
                            ),
                          ),
                        ],
                        if (_homeworkExistsOnServer) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _recordedAssetsBusy
                                ? null
                                : _clearHomeworkHtmlOnly,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Remove Homework'),
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
                  const SizedBox(height: 16),
                  const Text(
                    'Lesson and homework files (HTML)',
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
                        Text(
                          materialsUrlC.text.trim().isEmpty
                              ? 'No HTML materials uploaded yet.'
                              : _fileNameFromUrl(materialsUrlC.text.trim()),
                          style: TextStyle(
                            color: materialsUrlC.text.trim().isEmpty
                                ? Colors.black.withValues(alpha: 0.72)
                                : Colors.blue.shade700,
                            fontWeight: FontWeight.w700,
                          ),
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
                                      ? 'Upload Lesson'
                                      : 'Replace Lesson'),
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
                            label: const Text('Remove Lesson'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red.shade700,
                              side: BorderSide(color: Colors.red.shade200),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          homeworkUrlC.text.trim().isEmpty
                              ? 'No homework HTML uploaded yet.'
                              : _fileNameFromUrl(homeworkUrlC.text.trim()),
                          style: TextStyle(
                            color: homeworkUrlC.text.trim().isEmpty
                                ? Colors.black.withValues(alpha: 0.72)
                                : Colors.blue.shade700,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _recordedAssetsBusy
                              ? null
                              : _pickAndUploadHomeworkHtml,
                          icon: _uploadingHomework
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.assignment_rounded),
                          label: Text(
                            _uploadingHomework
                                ? 'Uploading ${(_homeworkUploadProgress * 100).round()}%'
                                : (homeworkUrlC.text.trim().isEmpty
                                      ? 'Upload Homework'
                                      : 'Replace Homework'),
                          ),
                        ),
                        if (homeworkUrlC.text.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _recordedAssetsBusy
                                ? null
                                : _clearHomeworkHtmlOnly,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Remove Homework'),
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
                if (_showLegacyFileList) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Lesson files in this session',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _recordedAssetsBusy
                        ? null
                        : _pickAndUploadAnyFiles,
                    icon: const Icon(Icons.upload_file_rounded),
                    label: const Text('Upload files'),
                  ),
                  const SizedBox(height: 8),
                  if (_uploadQueue.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Upload queue',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          ...List.generate(_uploadQueue.length, (i) {
                            final q = _uploadQueue[i];
                            final percent = (q.progress * 100).round();
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${q.fileName} (${q.kind.toUpperCase()})',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Status: ${q.status}  $percent%  Time: ${_fmtDuration(q.elapsedMs)}  Speed: ${_fmtSpeed(q.speedBytesPerSec)}  ETA: ${_fmtEta(q.etaMs)}',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: q.status == 'failed'
                                          ? Colors.red.shade700
                                          : Colors.black.withValues(alpha: 0.7),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      minHeight: 6,
                                      value: q.progress
                                          .clamp(0.0, 1.0)
                                          .toDouble(),
                                    ),
                                  ),
                                  if (q.error.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      q.error,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.red.shade700,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_lessonFiles.isEmpty)
                    Text(
                      'No uploaded files yet.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else
                    ...List.generate(_lessonFiles.length, (i) {
                      final f = _lessonFiles[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ListTile(
                          dense: true,
                          title: Text(
                            f.name.isEmpty ? _fileNameFromUrl(f.url) : f.name,
                          ),
                          subtitle: Text(
                            '${f.kind.toUpperCase()}  ${f.ext.toUpperCase()}',
                          ),
                          trailing: IconButton(
                            onPressed: _recordedAssetsBusy
                                ? null
                                : () => _removeLessonFileAt(i),
                            icon: const Icon(Icons.delete_outline_rounded),
                            color: Colors.red.shade700,
                            tooltip: 'Delete from server',
                          ),
                        ),
                      );
                    }),
                ],
                const SizedBox(height: 14),
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
                                homeworkUrl: homeworkUrlC.text.trim(),
                                serverFolderPath: _serverFolderPath.trim(),
                                lessonFiles: _lessonFiles,
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

class _BulkUploadResult {
  const _BulkUploadResult({
    required this.updates,
    this.successCount = 0,
    this.failedCount = 0,
  });

  final List<_BulkSessionUpdate> updates;
  final int successCount;
  final int failedCount;
}

class _BulkSessionUpdate {
  const _BulkSessionUpdate({
    required this.unitIndex,
    required this.sessionIndex,
    this.videoUrl,
    this.materialsUrl,
    this.serverFolderPath,
  });

  final int unitIndex;
  final int sessionIndex;
  final String? videoUrl;
  final String? materialsUrl;
  final String? serverFolderPath;
}

class _BulkSessionEntry {
  const _BulkSessionEntry({
    required this.key,
    required this.unitIndex,
    required this.sessionIndex,
    required this.sessionId,
    required this.unitTitle,
    required this.sessionTitle,
    required this.sessionNumber,
    required this.existingVideoUrl,
    required this.existingMaterialsUrl,
  });

  final String key;
  final int unitIndex;
  final int sessionIndex;
  final String sessionId;
  final String unitTitle;
  final String sessionTitle;
  final int sessionNumber;
  final String existingVideoUrl;
  final String existingMaterialsUrl;
}

enum _BulkAssetStatus { idle, queued, uploading, done, failed }

enum _BulkAssetAction { keep, replace, remove }

class _BulkAssetSlot {
  const _BulkAssetSlot({
    this.file,
    this.status = _BulkAssetStatus.idle,
    this.action = _BulkAssetAction.keep,
    this.progress = 0,
    this.uploadedUrl,
    this.error,
  });

  final PlatformFile? file;
  final _BulkAssetStatus status;
  final _BulkAssetAction action;
  final double progress;
  final String? uploadedUrl;
  final String? error;

  _BulkAssetSlot copyWith({
    PlatformFile? file,
    bool clearFile = false,
    _BulkAssetStatus? status,
    _BulkAssetAction? action,
    double? progress,
    String? uploadedUrl,
    bool clearUploadedUrl = false,
    String? error,
    bool clearError = false,
  }) {
    return _BulkAssetSlot(
      file: clearFile ? null : (file ?? this.file),
      status: status ?? this.status,
      action: action ?? this.action,
      progress: progress ?? this.progress,
      uploadedUrl: clearUploadedUrl ? null : (uploadedUrl ?? this.uploadedUrl),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

enum _BulkReplaceType { html, video }

class _BulkReplaceOp {
  const _BulkReplaceOp({
    required this.entryKey,
    required this.sessionNumber,
    required this.type,
    required this.file,
  });

  final String entryKey;
  final int sessionNumber;
  final _BulkReplaceType type;
  final PlatformFile file;
}

class _RecordedBulkSimpleUploadSheet extends StatefulWidget {
  const _RecordedBulkSimpleUploadSheet({
    required this.units,
    required this.courseFolderName,
    required this.courseTitle,
    required this.courseId,
  });

  final List<SyllabusUnit> units;
  final String courseFolderName;
  final String courseTitle;
  final String courseId;

  @override
  State<_RecordedBulkSimpleUploadSheet> createState() =>
      _RecordedBulkSimpleUploadSheetState();
}

class _RecordedBulkSimpleUploadSheetState
    extends State<_RecordedBulkSimpleUploadSheet> {
  final List<_BulkSessionEntry> _entries = <_BulkSessionEntry>[];
  final Map<int, PlatformFile> _htmlBySession = <int, PlatformFile>{};
  final Map<int, PlatformFile> _videoBySession = <int, PlatformFile>{};
  final Map<String, String> _currentHtmlUrlByEntry = <String, String>{};
  final Map<String, String> _currentVideoUrlByEntry = <String, String>{};
  final Map<String, String> _serverPathByEntry = <String, String>{};

  final Stopwatch _watch = Stopwatch();

  bool _running = false;
  int _totalOps = 0;
  int _doneOps = 0;
  double _currentOpProgress = 0;
  String _currentLabel = '';
  int _lastSuccessCount = 0;
  int _lastFailedCount = 0;

  List<_BulkReplaceOp> _failedOps = <_BulkReplaceOp>[];
  List<_BulkSessionUpdate> _latestUpdates = <_BulkSessionUpdate>[];

  @override
  void initState() {
    super.initState();

    for (int ui = 0; ui < widget.units.length; ui++) {
      final unit = widget.units[ui];
      for (int si = 0; si < unit.sessions.length; si++) {
        final s = unit.sessions[si];
        final sessionNo = s.sessionNumber > 0 ? s.sessionNumber : (si + 1);
        final key = '${ui}_$si';
        _entries.add(
          _BulkSessionEntry(
            key: key,
            unitIndex: ui,
            sessionIndex: si,
            sessionId: s.id,
            unitTitle: unit.title.trim().isEmpty
                ? 'Unit ${ui + 1}'
                : unit.title,
            sessionTitle: s.title.trim().isEmpty
                ? 'Session $sessionNo'
                : s.title,
            sessionNumber: sessionNo,
            existingVideoUrl: s.videoUrl.trim(),
            existingMaterialsUrl: s.materialsUrl.trim(),
          ),
        );
        _currentVideoUrlByEntry[key] = s.videoUrl.trim();
        _currentHtmlUrlByEntry[key] = s.materialsUrl.trim();
        final sessionFolder = _SyllabusServerStorage.buildSessionFolderName(
          sessionNumber: sessionNo,
          sessionTitle: s.title,
        );
        _serverPathByEntry[key] = '${widget.courseFolderName}/$sessionFolder';
      }
    }
  }

  double get _globalProgress {
    if (_totalOps <= 0) return 0;
    return ((_doneOps + _currentOpProgress.clamp(0.0, 1.0)) / _totalOps).clamp(
      0.0,
      1.0,
    );
  }

  String _elapsedLabel() {
    final s = _watch.elapsed.inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Future<void> _pickAllFiles() async {
    if (_running) return;
    if (_entries.isEmpty) {
      AppToast.show(context, 'No sessions found.', type: AppToastType.error);
      return;
    }

    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.custom,
      allowedExtensions: const [
        'html',
        'htm',
        'mp4',
        'mov',
        'm4v',
        'webm',
        'mkv',
      ],
    );
    if (picked == null || picked.files.isEmpty) return;

    final nextHtml = <int, PlatformFile>{};
    final nextVideo = <int, PlatformFile>{};
    final issues = <String>[];
    final totalSessions = _entries.length;
    final nameReg = RegExp(r'^(\d+)\.([a-z0-9]+)$', caseSensitive: false);

    bool isHtmlExt(String ext) => ext == 'html' || ext == 'htm';
    bool isVideoExt(String ext) =>
        ext == 'mp4' ||
        ext == 'mov' ||
        ext == 'm4v' ||
        ext == 'webm' ||
        ext == 'mkv';

    for (final file in picked.files) {
      final m = nameReg.firstMatch(file.name.trim());
      if (m == null) {
        issues.add('Invalid file name: ${file.name} (use 1.html, 1.mp4, etc)');
        continue;
      }

      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      final ext = (m.group(2) ?? '').toLowerCase();
      if (n <= 0 || n > totalSessions) {
        issues.add(
          'Out of range: ${file.name} (session must be 1..$totalSessions)',
        );
        continue;
      }

      if (isHtmlExt(ext)) {
        if (nextHtml.containsKey(n)) {
          issues.add('Duplicate HTML session $n');
          continue;
        }
        nextHtml[n] = file;
        continue;
      }

      if (isVideoExt(ext)) {
        if (nextVideo.containsKey(n)) {
          issues.add('Duplicate video session $n');
          continue;
        }
        nextVideo[n] = file;
        continue;
      }

      issues.add('Unsupported extension: ${file.name}');
    }

    if (nextHtml.isEmpty && nextVideo.isEmpty) {
      if (!mounted) return;
      AppToast.show(
        context,
        issues.isEmpty ? 'No valid files selected.' : issues.first,
        type: AppToastType.error,
      );
      return;
    }

    bool hasCoverage(Map<int, PlatformFile> map, String label) {
      if (map.isEmpty) return true;
      if (map.length != totalSessions) {
        issues.add('$label files must be exactly $totalSessions.');
        return false;
      }
      for (int i = 1; i <= totalSessions; i++) {
        if (!map.containsKey(i)) {
          issues.add('$label missing session $i');
          return false;
        }
      }
      return true;
    }

    hasCoverage(nextHtml, 'HTML');
    hasCoverage(nextVideo, 'Video');

    if (issues.isNotEmpty) {
      if (!mounted) return;
      AppToast.show(context, issues.first, type: AppToastType.error);
      return;
    }

    if (!mounted) return;
    setState(() {
      _htmlBySession
        ..clear()
        ..addAll(nextHtml);
      _videoBySession
        ..clear()
        ..addAll(nextVideo);
      _failedOps = <_BulkReplaceOp>[];
      _latestUpdates = <_BulkSessionUpdate>[];
      _lastSuccessCount = 0;
      _lastFailedCount = 0;
    });

    final parts = <String>[];
    if (nextHtml.isNotEmpty) {
      parts.add('HTML ${nextHtml.length}/$totalSessions');
    }
    if (nextVideo.isNotEmpty) {
      parts.add('Video ${nextVideo.length}/$totalSessions');
    }
    AppToast.show(
      context,
      'Mapped ${parts.join(' • ')}',
      type: AppToastType.success,
    );
  }

  bool _isIgnorableDeleteError(Object err) {
    final m = err.toString().toLowerCase();
    return m.contains('not found') ||
        m.contains('already missing') ||
        m.contains('item not found') ||
        m.contains('no such file');
  }

  Future<String> _uploadWithRetry({
    required PlatformFile file,
    required String serverPath,
    required int sessionNumber,
    required String customSuffix,
    required void Function(double p) onProgress,
  }) async {
    Object? lastErr;
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        return await _SyllabusServerStorage.uploadPlatformFile(
          file: file,
          root: 'courses',
          path: serverPath,
          customName: _SyllabusServerStorage.buildCustomBaseName(
            sessionNumber: sessionNumber,
            suffix: customSuffix,
          ),
          onProgress: onProgress,
        );
      } catch (err) {
        lastErr = err;
        if (attempt == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }
    }
    throw lastErr ?? Exception('Upload failed.');
  }

  Future<void> _runBulkReplace({bool retryFailedOnly = false}) async {
    if (_running) return;
    if (_entries.isEmpty) {
      AppToast.show(context, 'No sessions found.', type: AppToastType.error);
      return;
    }

    final bySessionNumber = <int, _BulkSessionEntry>{
      for (final e in _entries) e.sessionNumber: e,
    };

    final ops = <_BulkReplaceOp>[];
    if (retryFailedOnly) {
      ops.addAll(_failedOps);
    } else {
      for (final entry in _entries) {
        final n = entry.sessionNumber;
        final htmlFile = _htmlBySession[n];
        if (htmlFile != null) {
          ops.add(
            _BulkReplaceOp(
              entryKey: entry.key,
              sessionNumber: n,
              type: _BulkReplaceType.html,
              file: htmlFile,
            ),
          );
        }
        final videoFile = _videoBySession[n];
        if (videoFile != null) {
          ops.add(
            _BulkReplaceOp(
              entryKey: entry.key,
              sessionNumber: n,
              type: _BulkReplaceType.video,
              file: videoFile,
            ),
          );
        }
      }
    }

    if (ops.isEmpty) {
      AppToast.show(
        context,
        retryFailedOnly
            ? 'No failed items to retry.'
            : 'Pick and map files first.',
        type: AppToastType.info,
      );
      return;
    }

    final successfulVideoByKey = <String, String>{};
    final successfulHtmlByKey = <String, String>{};
    final failed = <_BulkReplaceOp>[];
    int successCount = 0;

    if (!mounted) return;
    setState(() {
      _running = true;
      _totalOps = ops.length;
      _doneOps = 0;
      _currentOpProgress = 0;
      _currentLabel = 'Preparing...';
      _lastSuccessCount = 0;
      _lastFailedCount = 0;
    });
    _watch
      ..reset()
      ..start();

    try {
      for (final op in ops) {
        final entry = bySessionNumber[op.sessionNumber];
        if (entry == null) {
          failed.add(op);
          continue;
        }

        final isHtml = op.type == _BulkReplaceType.html;
        final labelType = isHtml ? 'HTML' : 'Video';
        final oldUrl = isHtml
            ? (_currentHtmlUrlByEntry[op.entryKey] ?? '')
            : (_currentVideoUrlByEntry[op.entryKey] ?? '');

        if (!mounted) return;
        setState(() {
          _currentLabel = 'Session ${op.sessionNumber} • $labelType';
          _currentOpProgress = 0;
        });

        try {
          if (oldUrl.trim().isNotEmpty) {
            final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
              oldUrl,
            );
            if (rel.isNotEmpty) {
              try {
                await _SyllabusServerStorage.deletePath(
                  root: 'courses',
                  path: rel,
                );
              } catch (err) {
                if (!_isIgnorableDeleteError(err)) rethrow;
              }
            }
          }

          if (isHtml) {
            _currentHtmlUrlByEntry[op.entryKey] = '';
          } else {
            _currentVideoUrlByEntry[op.entryKey] = '';
          }

          final serverPath =
              _serverPathByEntry[op.entryKey] ??
              '${widget.courseFolderName}/${_SyllabusServerStorage.buildSessionFolderName(sessionNumber: op.sessionNumber, sessionTitle: entry.sessionTitle)}';

          final url = await _uploadWithRetry(
            file: op.file,
            serverPath: serverPath,
            sessionNumber: op.sessionNumber,
            customSuffix: isHtml ? 'materials' : 'video',
            onProgress: (p) {
              if (!mounted) return;
              setState(() => _currentOpProgress = p.clamp(0.0, 1.0));
            },
          );

          if (isHtml) {
            _currentHtmlUrlByEntry[op.entryKey] = url;
            successfulHtmlByKey[op.entryKey] = url;
          } else {
            _currentVideoUrlByEntry[op.entryKey] = url;
            successfulVideoByKey[op.entryKey] = url;
          }

          successCount++;
          if (mounted) {
            AppToast.show(
              context,
              'Uploaded ${op.file.name} -> Session ${op.sessionNumber} $labelType',
              type: AppToastType.success,
            );
          }
        } catch (err) {
          failed.add(op);
          if (mounted) {
            AppToast.show(
              context,
              'Failed Session ${op.sessionNumber} $labelType: ${toHumanError(err, fallback: 'Upload failed.')}',
              type: AppToastType.error,
            );
          }
        } finally {
          if (mounted) {
            setState(() {
              _doneOps += 1;
              _currentOpProgress = 0;
            });
          }
        }
      }
    } finally {
      _watch.stop();
      if (mounted) {
        setState(() => _running = false);
      }
    }

    final updates = <_BulkSessionUpdate>[];
    for (final entry in _entries) {
      final htmlUrl = successfulHtmlByKey[entry.key];
      final videoUrl = successfulVideoByKey[entry.key];
      if (htmlUrl == null && videoUrl == null) continue;
      final serverPath =
          _serverPathByEntry[entry.key] ??
          '${widget.courseFolderName}/${_SyllabusServerStorage.buildSessionFolderName(sessionNumber: entry.sessionNumber, sessionTitle: entry.sessionTitle)}';
      updates.add(
        _BulkSessionUpdate(
          unitIndex: entry.unitIndex,
          sessionIndex: entry.sessionIndex,
          videoUrl: videoUrl,
          materialsUrl: htmlUrl,
          serverFolderPath: serverPath,
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _failedOps = failed;
      _latestUpdates = updates;
      _lastSuccessCount = successCount;
      _lastFailedCount = failed.length;
      _currentLabel = failed.isEmpty
          ? 'Completed'
          : 'Completed with ${failed.length} failed';
    });

    AppToast.show(
      context,
      'Bulk done. Success: $successCount • Failed: ${failed.length}',
      type: failed.isEmpty ? AppToastType.success : AppToastType.info,
    );
  }

  void _applyAndClose() {
    if (_running || _latestUpdates.isEmpty) return;
    Navigator.pop(
      context,
      _BulkUploadResult(
        updates: _latestUpdates,
        successCount: _lastSuccessCount,
        failedCount: _lastFailedCount,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalSessions = _entries.length;
    final hasHtml = _htmlBySession.isNotEmpty;
    final hasVideo = _videoBySession.isNotEmpty;
    final progressPct = (_globalProgress * 100).toStringAsFixed(1);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Bulk Replace Recorded Assets',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _running ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              'Use numeric names like 1.html / 1.mp4. Matches Session 1, 2, ... exactly.',
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.65),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Pill(label: 'Sessions $totalSessions'),
                if (hasHtml)
                  _Pill(label: 'HTML ${_htmlBySession.length}/$totalSessions'),
                if (hasVideo)
                  _Pill(
                    label: 'Video ${_videoBySession.length}/$totalSessions',
                  ),
                if (_lastSuccessCount > 0 || _lastFailedCount > 0)
                  _Pill(
                    label: 'Last run ✓$_lastSuccessCount ✕$_lastFailedCount',
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : _pickAllFiles,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Pick all files'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_running || _totalOps > 0)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentLabel.isEmpty ? 'Waiting...' : _currentLabel,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: _globalProgress,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$progressPct% • $_doneOps/$_totalOps • ${_elapsedLabel()}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.black.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            if (_failedOps.isNotEmpty)
              Text(
                'Failed items: ${_failedOps.length}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFB91C1C),
                ),
              ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_running || _failedOps.isEmpty)
                        ? null
                        : () => _runBulkReplace(retryFailedOnly: true),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry failed'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : _runBulkReplace,
                    icon: _running
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_rounded),
                    label: Text(_running ? 'Running…' : 'Run replace'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: (_running || _latestUpdates.isEmpty)
                        ? null
                        : _applyAndClose,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Apply and close'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordedBulkUploadSheet extends StatefulWidget {
  const _RecordedBulkUploadSheet({
    required this.units,
    required this.courseFolderName,
    required this.courseTitle,
    required this.courseId,
  });

  final List<SyllabusUnit> units;
  final String courseFolderName;
  final String courseTitle;
  final String courseId;

  @override
  State<_RecordedBulkUploadSheet> createState() =>
      _RecordedBulkUploadSheetState();
}

class _RecordedBulkUploadSheetState extends State<_RecordedBulkUploadSheet> {
  static const int _maxUploadBytes = 250 * 1024 * 1024;

  final Map<String, _BulkAssetSlot> _videoSlots = <String, _BulkAssetSlot>{};
  final Map<String, _BulkAssetSlot> _htmlSlots = <String, _BulkAssetSlot>{};

  late final List<_BulkSessionEntry> _entries;
  bool _uploading = false;
  bool _checkingServerAssets = false;
  final Map<String, bool> _serverHasVideo = <String, bool>{};
  final Map<String, bool> _serverHasHtml = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _entries = <_BulkSessionEntry>[];
    for (int ui = 0; ui < widget.units.length; ui++) {
      final unit = widget.units[ui];
      for (int si = 0; si < unit.sessions.length; si++) {
        final s = unit.sessions[si];
        final sessionNo = s.sessionNumber > 0 ? s.sessionNumber : (si + 1);
        _entries.add(
          _BulkSessionEntry(
            key: '${ui}_$si',
            unitIndex: ui,
            sessionIndex: si,
            sessionId: s.id,
            unitTitle: unit.title.trim().isEmpty
                ? 'Unit ${ui + 1}'
                : unit.title,
            sessionTitle: s.title.trim().isEmpty
                ? 'Session $sessionNo'
                : s.title,
            sessionNumber: sessionNo,
            existingVideoUrl: s.videoUrl.trim(),
            existingMaterialsUrl: s.materialsUrl.trim(),
          ),
        );
      }
    }

    unawaited(_loadServerAssetState());
  }

  _BulkAssetSlot _videoOf(String key) =>
      _videoSlots[key] ?? const _BulkAssetSlot();
  _BulkAssetSlot _htmlOf(String key) =>
      _htmlSlots[key] ?? const _BulkAssetSlot();

  int get _queuedFileCount {
    int n = 0;
    for (final e in _entries) {
      final vs = _videoOf(e.key);
      final hs = _htmlOf(e.key);
      if (vs.action != _BulkAssetAction.keep) n++;
      if (hs.action != _BulkAssetAction.keep) n++;
    }
    return n;
  }

  int get _completedFileCount {
    int n = 0;
    for (final e in _entries) {
      if (_videoOf(e.key).status == _BulkAssetStatus.done) n++;
      if (_htmlOf(e.key).status == _BulkAssetStatus.done) n++;
    }
    return n;
  }

  int get _failedFileCount {
    int n = 0;
    for (final e in _entries) {
      if (_videoOf(e.key).status == _BulkAssetStatus.failed) n++;
      if (_htmlOf(e.key).status == _BulkAssetStatus.failed) n++;
    }
    return n;
  }

  String _fileNameOnly(String fullPath) {
    final p = fullPath.replaceAll('\\', '/');
    final i = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }

  int? _inferModuleFromCourseContext() {
    final sources = <String>[widget.courseTitle, widget.courseId];
    final moduleWord = RegExp(r'module\s*([0-9]+)', caseSensitive: false);
    final compact = RegExp(r'\bm\s*([0-9]+)\b', caseSensitive: false);

    for (final s in sources) {
      final t = s.trim();
      if (t.isEmpty) continue;
      final m1 = moduleWord.firstMatch(t);
      if (m1 != null) {
        final n = int.tryParse(m1.group(1) ?? '');
        if (n != null && n > 0) return n;
      }
      final m2 = compact.firstMatch(t);
      if (m2 != null) {
        final n = int.tryParse(m2.group(1) ?? '');
        if (n != null && n > 0) return n;
      }
    }
    return null;
  }

  Future<int?> _pickModuleFromSet(List<int> modules) async {
    if (modules.isEmpty) return null;
    if (modules.length == 1) return modules.first;

    int selected = modules.first;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose module to import'),
        content: StatefulBuilder(
          builder: (ctx, setD) => DropdownButtonFormField<int>(
            initialValue: selected,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Module',
            ),
            items: modules
                .map(
                  (m) =>
                      DropdownMenuItem<int>(value: m, child: Text('Module $m')),
                )
                .toList(),
            onChanged: (v) {
              if (v == null) return;
              setD(() => selected = v);
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, selected),
            child: const Text('Use module'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _importHtmlFromFiles() async {
    if (_uploading) return;

    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.custom,
      allowedExtensions: const ['html', 'htm'],
    );
    if (picked == null || picked.files.isEmpty) return;

    final strictReg = RegExp(
      r'^TESP_M(\d+)_U(\d+)_(L(\d+)|Revision)\.(html|htm)$',
      caseSensitive: false,
    );
    final looseReg = RegExp(
      r'M(\d+)_U(\d+)_(L(\d+)|Revision)(?:\.|_|\b)',
      caseSensitive: false,
    );

    final candidates = picked.files;

    final numericReg = RegExp(r'^(\d+)\.(html|htm)$', caseSensitive: false);
    final numericParsed = <Map<String, dynamic>>[];
    for (final file in candidates) {
      final pathOrName = (file.path ?? '').trim().isNotEmpty
          ? file.path!
          : file.name;
      final name = _fileNameOnly(pathOrName);
      final m = numericReg.firstMatch(name);
      if (m == null) continue;
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n <= 0) continue;
      numericParsed.add({'file': file, 'index': n});
    }

    if (numericParsed.isNotEmpty && numericParsed.length == candidates.length) {
      final bySessionNumber = <int, _BulkSessionEntry>{};
      for (final e in _entries) {
        if (e.sessionNumber > 0) bySessionNumber[e.sessionNumber] = e;
      }

      int matched = 0;
      int skipped = 0;
      int duplicate = 0;
      final used = <String>{};
      final draftUpdates = <Map<String, dynamic>>[];

      numericParsed.sort(
        (a, b) => (a['index'] as int).compareTo(b['index'] as int),
      );

      for (final row in numericParsed) {
        final idx = row['index'] as int;
        final file = row['file'] as PlatformFile;
        final target = bySessionNumber[idx];
        if (target == null) {
          skipped++;
          continue;
        }
        if (used.contains(target.key)) {
          duplicate++;
          skipped++;
          continue;
        }
        used.add(target.key);
        draftUpdates.add({'key': target.key, 'file': file});
        matched++;
      }

      if (!mounted) return;
      final proceed =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Numbered import summary'),
              content: Text(
                'Selected: ${candidates.length}\nMatched by session number: $matched\nSkipped: $skipped\nDuplicate targets: $duplicate',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Queue files'),
                ),
              ],
            ),
          ) ??
          false;
      if (!proceed) return;

      setState(() {
        for (final u in draftUpdates) {
          final key = u['key'] as String;
          final file = u['file'] as PlatformFile;
          _htmlSlots[key] = _htmlOf(key).copyWith(
            file: file,
            action: _BulkAssetAction.replace,
            status: _BulkAssetStatus.queued,
            progress: 0,
            clearUploadedUrl: true,
            clearError: true,
          );
        }
      });

      if (!mounted) return;
      AppToast.show(
        context,
        'Queued $matched numbered HTML file(s)${skipped > 0 ? ' • skipped $skipped' : ''}.',
        type: matched > 0 ? AppToastType.success : AppToastType.info,
      );
      return;
    }

    final parsed = <Map<String, dynamic>>[];
    final moduleSet = <int>{};
    for (final file in candidates) {
      final pathOrName = (file.path ?? '').trim().isNotEmpty
          ? file.path!
          : file.name;
      final name = _fileNameOnly(pathOrName);
      final m = strictReg.firstMatch(name) ?? looseReg.firstMatch(name);
      if (m == null) continue;
      final moduleNo = int.tryParse(m.group(1) ?? '') ?? 0;
      final unitNo = int.tryParse(m.group(2) ?? '') ?? 0;
      final lessonNo = int.tryParse(m.group(4) ?? '') ?? 0;
      final isRevision = (m.group(3) ?? '').toLowerCase() == 'revision';
      if (moduleNo <= 0 || unitNo <= 0) continue;

      moduleSet.add(moduleNo);
      parsed.add({
        'file': file,
        'module': moduleNo,
        'unit': unitNo,
        'lesson': lessonNo,
        'revision': isRevision,
      });
    }

    if (parsed.isEmpty) {
      if (!mounted) return;
      AppToast.show(
        context,
        'No files matched naming pattern (e.g. TESP_M1_U2_L3.html).',
        type: AppToastType.error,
      );
      return;
    }

    final modules = moduleSet.toList()..sort();
    final inferredModule = _inferModuleFromCourseContext();
    int? chosenModule;
    if (inferredModule != null && modules.contains(inferredModule)) {
      chosenModule = inferredModule;
    } else {
      chosenModule = await _pickModuleFromSet(modules);
    }
    if (chosenModule == null) return;

    final byUnit = <int, List<_BulkSessionEntry>>{};
    for (final e in _entries) {
      final unitNo = e.unitIndex + 1;
      byUnit.putIfAbsent(unitNo, () => <_BulkSessionEntry>[]).add(e);
    }

    int matched = 0;
    int skipped = 0;
    int duplicateTargets = 0;
    int missingUnits = 0;
    final usedEntryKeys = <String>{};

    final draftUpdates = <Map<String, dynamic>>[];

    for (final p in parsed) {
      if (p['module'] != chosenModule) continue;

      final unitNo = p['unit'] as int;
      final lessonNo = p['lesson'] as int;
      final isRevision = p['revision'] as bool;
      final file = p['file'] as PlatformFile;
      final unitEntries = byUnit[unitNo] ?? const <_BulkSessionEntry>[];
      if (unitEntries.isEmpty) {
        missingUnits++;
        skipped++;
        continue;
      }

      _BulkSessionEntry? target;
      if (isRevision) {
        for (final e in unitEntries) {
          if (e.sessionTitle.toLowerCase().contains('revision')) {
            target = e;
            break;
          }
        }
        target ??= unitEntries.isNotEmpty ? unitEntries.last : null;
      } else {
        for (final e in unitEntries) {
          final localLessonIndex = e.sessionIndex + 1;
          if (localLessonIndex == lessonNo) {
            target = e;
            break;
          }
        }
      }

      if (target == null || usedEntryKeys.contains(target.key)) {
        duplicateTargets++;
        skipped++;
        continue;
      }

      usedEntryKeys.add(target.key);
      draftUpdates.add({'key': target.key, 'file': file});
      matched++;
    }

    if (!mounted) return;
    final proceed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import summary'),
            content: Text(
              'Selected: ${candidates.length}\nParsed: ${parsed.length}\nModule used: $chosenModule${inferredModule != null ? ' (course hint: $inferredModule)' : ''}\nMatched: $matched\nSkipped: $skipped\nMissing unit in screen: $missingUnits\nDuplicate/overlap: $duplicateTargets',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Queue files'),
              ),
            ],
          ),
        ) ??
        false;
    if (!proceed) return;

    setState(() {
      for (final u in draftUpdates) {
        final key = u['key'] as String;
        final file = u['file'] as PlatformFile;
        _htmlSlots[key] = _htmlOf(key).copyWith(
          file: file,
          action: _BulkAssetAction.replace,
          status: _BulkAssetStatus.queued,
          progress: 0,
          clearUploadedUrl: true,
          clearError: true,
        );
      }
    });

    if (!mounted) return;
    AppToast.show(
      context,
      'Queued $matched HTML file(s)${skipped > 0 ? ' • skipped $skipped' : ''}.',
      type: matched > 0 ? AppToastType.success : AppToastType.info,
    );
  }

  Future<bool> _assetUrlExistsOnServer(
    String url,
    Map<String, List<Map<String, dynamic>>> listCache,
  ) async {
    final rel = _SyllabusServerStorage.extractRelativePathFromUrl(url);
    if (rel.isEmpty) return false;

    final segments = rel
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (segments.length < 2) return false;

    final fileName = segments.last;
    final folderPath = segments.sublist(0, segments.length - 1).join('/');

    if (!listCache.containsKey(folderPath)) {
      listCache[folderPath] = await _SyllabusServerStorage.listItems(
        root: 'courses',
        path: folderPath,
      );
    }

    final items = listCache[folderPath] ?? const <Map<String, dynamic>>[];
    for (final item in items) {
      final type = (item['type'] ?? '').toString().trim().toLowerCase();
      final name = (item['name'] ?? '').toString().trim();
      if (type != 'folder' && name == fileName) return true;
    }
    return false;
  }

  Future<void> _loadServerAssetState() async {
    if (!mounted) return;
    setState(() => _checkingServerAssets = true);

    final listCache = <String, List<Map<String, dynamic>>>{};
    final nextVideo = <String, bool>{};
    final nextHtml = <String, bool>{};

    try {
      for (final e in _entries) {
        if (e.existingVideoUrl.isNotEmpty) {
          try {
            nextVideo[e.key] = await _assetUrlExistsOnServer(
              e.existingVideoUrl,
              listCache,
            );
          } catch (_) {
            nextVideo[e.key] = false;
          }
        } else {
          nextVideo[e.key] = false;
        }

        if (e.existingMaterialsUrl.isNotEmpty) {
          try {
            nextHtml[e.key] = await _assetUrlExistsOnServer(
              e.existingMaterialsUrl,
              listCache,
            );
          } catch (_) {
            nextHtml[e.key] = false;
          }
        } else {
          nextHtml[e.key] = false;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _serverHasVideo
            ..clear()
            ..addAll(nextVideo);
          _serverHasHtml
            ..clear()
            ..addAll(nextHtml);
          _checkingServerAssets = false;
        });
      }
    }
  }

  Future<void> _pickVideo(_BulkSessionEntry entry) async {
    if (_uploading) return;
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.video,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.size > _maxUploadBytes) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Video is too large. Maximum is 250 MB.',
        type: AppToastType.error,
      );
      return;
    }
    setState(() {
      _videoSlots[entry.key] = _videoOf(entry.key).copyWith(
        file: file,
        action: _BulkAssetAction.replace,
        status: _BulkAssetStatus.queued,
        progress: 0,
        clearUploadedUrl: true,
        clearError: true,
      );
    });
  }

  Future<void> _pickHtml(_BulkSessionEntry entry) async {
    if (_uploading) return;
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.custom,
      allowedExtensions: const ['html', 'htm'],
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.size > _maxUploadBytes) {
      if (!mounted) return;
      AppToast.show(
        context,
        'HTML file is too large. Maximum is 250 MB.',
        type: AppToastType.error,
      );
      return;
    }
    setState(() {
      _htmlSlots[entry.key] = _htmlOf(entry.key).copyWith(
        file: file,
        action: _BulkAssetAction.replace,
        status: _BulkAssetStatus.queued,
        progress: 0,
        clearUploadedUrl: true,
        clearError: true,
      );
    });
  }

  void _markKeep(_BulkSessionEntry entry, {required bool isVideo}) {
    if (_uploading) return;
    setState(() {
      if (isVideo) {
        _videoSlots.remove(entry.key);
      } else {
        _htmlSlots.remove(entry.key);
      }
    });
  }

  void _markRemove(_BulkSessionEntry entry, {required bool isVideo}) {
    if (_uploading) return;
    setState(() {
      final current = isVideo ? _videoOf(entry.key) : _htmlOf(entry.key);
      final next = current.copyWith(
        action: _BulkAssetAction.remove,
        status: _BulkAssetStatus.queued,
        progress: 0,
        clearFile: true,
        clearUploadedUrl: true,
        clearError: true,
      );
      if (isVideo) {
        _videoSlots[entry.key] = next;
      } else {
        _htmlSlots[entry.key] = next;
      }
    });
  }

  String _serverStateLabel({
    required bool hasUrl,
    required bool existsOnServer,
  }) {
    if (!hasUrl) return 'No URL in RTDB';
    return existsOnServer ? 'Available on server' : 'Missing on server';
  }

  void _clearSelections() {
    if (_uploading) return;
    setState(() {
      _videoSlots.clear();
      _htmlSlots.clear();
    });
  }

  String _fmtBytes(int size) {
    if (size < 1024) return '$size B';
    final kb = size / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }

  String _statusLabel(_BulkAssetSlot slot) {
    if (slot.action == _BulkAssetAction.remove &&
        slot.status == _BulkAssetStatus.queued) {
      return 'Ready to remove';
    }
    switch (slot.status) {
      case _BulkAssetStatus.idle:
        return 'Not selected';
      case _BulkAssetStatus.queued:
        return slot.action == _BulkAssetAction.replace
            ? 'Ready to replace'
            : 'Ready';
      case _BulkAssetStatus.uploading:
        return slot.action == _BulkAssetAction.remove
            ? 'Removing old file...'
            : 'Uploading ${(slot.progress * 100).round()}%';
      case _BulkAssetStatus.done:
        return slot.action == _BulkAssetAction.remove ? 'Removed' : 'Uploaded';
      case _BulkAssetStatus.failed:
        return 'Failed';
    }
  }

  Color _statusColor(_BulkAssetSlot slot) {
    switch (slot.status) {
      case _BulkAssetStatus.done:
        return const Color(0xFF15803D);
      case _BulkAssetStatus.failed:
        return const Color(0xFFB91C1C);
      case _BulkAssetStatus.uploading:
        return const Color(0xFF1D4ED8);
      case _BulkAssetStatus.queued:
        return const Color(0xFF334155);
      case _BulkAssetStatus.idle:
        return const Color(0xFF64748B);
    }
  }

  Future<void> _uploadAll() async {
    if (_uploading) return;

    final hasQueued = _entries.any(
      (e) =>
          _videoOf(e.key).action != _BulkAssetAction.keep ||
          _htmlOf(e.key).action != _BulkAssetAction.keep,
    );
    if (!hasQueued) {
      AppToast.show(
        context,
        'Choose at least one action (replace/remove) first.',
        type: AppToastType.info,
      );
      return;
    }

    setState(() => _uploading = true);

    bool isIgnorableDeleteError(Object err) {
      final m = err.toString().toLowerCase();
      return m.contains('not found') ||
          m.contains('already missing') ||
          m.contains('item not found') ||
          m.contains('no such file');
    }

    Future<String> uploadWithRetry({
      required PlatformFile file,
      required String serverPath,
      required int sessionNumber,
      required String customSuffix,
      required void Function(double p) onProgress,
    }) async {
      Object? lastErr;
      for (int attempt = 1; attempt <= 2; attempt++) {
        try {
          return await _SyllabusServerStorage.uploadPlatformFile(
            file: file,
            root: 'courses',
            path: serverPath,
            customName: _SyllabusServerStorage.buildCustomBaseName(
              sessionNumber: sessionNumber,
              suffix: customSuffix,
            ),
            onProgress: onProgress,
          );
        } catch (err) {
          lastErr = err;
          if (attempt == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 700));
          }
        }
      }
      throw lastErr ?? Exception('Upload failed.');
    }

    Future<void> processAsset({
      required _BulkSessionEntry entry,
      required bool isVideo,
      required String existingUrl,
      required String serverPath,
      required String customSuffix,
    }) async {
      final key = entry.key;
      final read = isVideo ? _videoOf : _htmlOf;
      void write(_BulkAssetSlot s) {
        if (isVideo) {
          _videoSlots[key] = s;
        } else {
          _htmlSlots[key] = s;
        }
      }

      final slot = read(key);
      if (slot.action == _BulkAssetAction.keep) return;

      if (mounted) {
        setState(() {
          write(
            slot.copyWith(
              status: _BulkAssetStatus.uploading,
              progress: 0,
              clearError: true,
            ),
          );
        });
      }

      if (existingUrl.trim().isNotEmpty) {
        final rel = _SyllabusServerStorage.extractRelativePathFromUrl(
          existingUrl,
        );
        if (rel.isNotEmpty) {
          try {
            await _SyllabusServerStorage.deletePath(root: 'courses', path: rel);
          } catch (err) {
            if (isIgnorableDeleteError(err)) {
              // old file already missing is acceptable in replace/remove flow
            } else {
              if (!mounted) return;
              setState(() {
                write(
                  read(key).copyWith(
                    status: _BulkAssetStatus.failed,
                    error: toHumanError(
                      err,
                      fallback: 'Could not delete old file.',
                    ),
                  ),
                );
              });
              return;
            }
          }
        }
      }

      if (slot.action == _BulkAssetAction.remove) {
        if (!mounted) return;
        setState(() {
          write(
            read(key).copyWith(
              status: _BulkAssetStatus.done,
              progress: 1,
              uploadedUrl: '',
              clearError: true,
            ),
          );
          if (isVideo) {
            _serverHasVideo[key] = false;
          } else {
            _serverHasHtml[key] = false;
          }
        });
        return;
      }

      final fresh = read(key);
      if (fresh.file == null) {
        if (!mounted) return;
        setState(() {
          write(
            fresh.copyWith(
              status: _BulkAssetStatus.failed,
              error: 'Pick a file for replace.',
            ),
          );
        });
        return;
      }

      try {
        final url = await uploadWithRetry(
          file: fresh.file!,
          serverPath: serverPath,
          sessionNumber: entry.sessionNumber,
          customSuffix: customSuffix,
          onProgress: (p) {
            if (!mounted) return;
            setState(() {
              write(read(key).copyWith(progress: p.clamp(0.0, 1.0)));
            });
          },
        );
        if (!mounted) return;
        setState(() {
          write(
            read(key).copyWith(
              status: _BulkAssetStatus.done,
              progress: 1,
              uploadedUrl: url,
              clearError: true,
            ),
          );
          if (isVideo) {
            _serverHasVideo[key] = true;
          } else {
            _serverHasHtml[key] = true;
          }
        });
      } catch (err) {
        if (!mounted) return;
        setState(() {
          write(
            read(key).copyWith(
              status: _BulkAssetStatus.failed,
              error: toHumanError(err, fallback: 'Upload failed.'),
            ),
          );
        });
      }
    }

    try {
      for (final e in _entries) {
        final sessionFolder = _SyllabusServerStorage.buildSessionFolderName(
          sessionNumber: e.sessionNumber,
          sessionTitle: e.sessionTitle,
        );
        final serverPath = '${widget.courseFolderName}/$sessionFolder';

        await processAsset(
          entry: e,
          isVideo: true,
          existingUrl: e.existingVideoUrl,
          serverPath: serverPath,
          customSuffix: 'video',
        );

        await processAsset(
          entry: e,
          isVideo: false,
          existingUrl: e.existingMaterialsUrl,
          serverPath: serverPath,
          customSuffix: 'materials',
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }

    if (!mounted) return;

    if (_failedFileCount == 0 && _completedFileCount > 0) {
      _applyUploaded();
      return;
    }

    if (_completedFileCount > 0) {
      AppToast.show(
        context,
        'Completed $_completedFileCount changes. $_failedFileCount failed. You can apply successful changes.',
        type: AppToastType.info,
      );
    } else {
      AppToast.show(
        context,
        'No files uploaded successfully. Check errors and retry.',
        type: AppToastType.error,
      );
    }
  }

  void _applyUploaded() {
    final updates = <_BulkSessionUpdate>[];
    for (final e in _entries) {
      final v = _videoOf(e.key);
      final h = _htmlOf(e.key);
      final videoChanged =
          v.status == _BulkAssetStatus.done &&
          v.action != _BulkAssetAction.keep;
      final htmlChanged =
          h.status == _BulkAssetStatus.done &&
          h.action != _BulkAssetAction.keep;
      if (!videoChanged && !htmlChanged) continue;

      final videoUrl = videoChanged ? (v.uploadedUrl ?? '') : null;
      final htmlUrl = htmlChanged ? (h.uploadedUrl ?? '') : null;

      final sessionFolder = _SyllabusServerStorage.buildSessionFolderName(
        sessionNumber: e.sessionNumber,
        sessionTitle: e.sessionTitle,
      );
      final serverPath = '${widget.courseFolderName}/$sessionFolder';

      updates.add(
        _BulkSessionUpdate(
          unitIndex: e.unitIndex,
          sessionIndex: e.sessionIndex,
          videoUrl: videoUrl,
          materialsUrl: htmlUrl,
          serverFolderPath: serverPath,
        ),
      );
    }

    if (updates.isEmpty) {
      AppToast.show(
        context,
        'No successful changes to apply yet.',
        type: AppToastType.info,
      );
      return;
    }

    Navigator.pop(context, _BulkUploadResult(updates: updates));
  }

  Widget _buildAssetCell({
    required _BulkSessionEntry entry,
    required bool isVideo,
    required String label,
    required _BulkAssetSlot slot,
    required VoidCallback onPick,
  }) {
    final hasExistingUrl = isVideo
        ? entry.existingVideoUrl.isNotEmpty
        : entry.existingMaterialsUrl.isNotEmpty;
    final existsOnServer = isVideo
        ? (_serverHasVideo[entry.key] ?? false)
        : (_serverHasHtml[entry.key] ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          _serverStateLabel(
            hasUrl: hasExistingUrl,
            existsOnServer: existsOnServer,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: hasExistingUrl
                ? (existsOnServer
                      ? const Color(0xFF166534)
                      : const Color(0xFFB45309))
                : Colors.black.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 6),
        if (slot.file != null)
          Text(
            '${slot.file!.name} • ${_fmtBytes(slot.file!.size)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          )
        else
          Text(
            'No file selected',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('Keep'),
              selected: slot.action == _BulkAssetAction.keep,
              onSelected: _uploading
                  ? null
                  : (_) => _markKeep(entry, isVideo: isVideo),
            ),
            ChoiceChip(
              label: Text(hasExistingUrl ? 'Replace' : 'Add'),
              selected: slot.action == _BulkAssetAction.replace,
              onSelected: _uploading ? null : (_) => onPick(),
            ),
            if (hasExistingUrl)
              ChoiceChip(
                label: const Text('Remove'),
                selected: slot.action == _BulkAssetAction.remove,
                onSelected: _uploading
                    ? null
                    : (_) => _markRemove(entry, isVideo: isVideo),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _uploading
                  ? null
                  : () {
                      onPick();
                    },
              icon: const Icon(Icons.attach_file_rounded, size: 16),
              label: Text(hasExistingUrl ? 'Pick replace file' : 'Pick file'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _statusLabel(slot),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: _statusColor(slot),
                ),
              ),
            ),
          ],
        ),
        if (slot.status == _BulkAssetStatus.uploading ||
            slot.status == _BulkAssetStatus.done) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: slot.status == _BulkAssetStatus.done
                  ? 1
                  : slot.progress.clamp(0.0, 1.0),
            ),
          ),
        ],
        if ((slot.error ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            slot.error!,
            style: const TextStyle(
              color: Color(0xFFB91C1C),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _queuedFileCount;
    final done = _completedFileCount;
    final failed = _failedFileCount;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(
                  Icons.cloud_upload_rounded,
                  color: Color(0xFF1A2B48),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Bulk Upload Recorded Assets',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: _uploading ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Pick video/HTML per session, then upload all together. Progress is shown per file.',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_checkingServerAssets)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Checking current server files...',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Pill(label: 'Selected $selected'),
                _Pill(label: 'Completed $done'),
                if (failed > 0) _Pill(label: 'Failed $failed'),
                TextButton.icon(
                  onPressed: _uploading ? null : _importHtmlFromFiles,
                  icon: const Icon(Icons.folder_open_rounded, size: 17),
                  label: const Text('Import HTML files'),
                ),
                TextButton.icon(
                  onPressed: _uploading ? null : _clearSelections,
                  icon: const Icon(Icons.layers_clear_rounded, size: 17),
                  label: const Text('Clear all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: _entries.length,
                separatorBuilder: (_, ignoredSeparator) =>
                    const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final e = _entries[i];
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'U${e.unitIndex + 1} • S${e.sessionNumber} • ${e.unitTitle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF1A2B48),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          e.sessionTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.black.withValues(alpha: 0.65),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            _Pill(
                              label:
                                  'Server HTML: ${(_serverHasHtml[e.key] ?? false) ? 'Yes' : 'No'}',
                            ),
                            _Pill(
                              label:
                                  'Server Video: ${(_serverHasVideo[e.key] ?? false) ? 'Yes' : 'No'}',
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _buildAssetCell(
                                entry: e,
                                isVideo: true,
                                label: 'Video',
                                slot: _videoOf(e.key),
                                onPick: () => _pickVideo(e),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildAssetCell(
                                entry: e,
                                isVideo: false,
                                label: 'HTML',
                                slot: _htmlOf(e.key),
                                onPick: () => _pickHtml(e),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_uploading || done == 0)
                        ? null
                        : _applyUploaded,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Apply uploaded'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _uploading ? null : _uploadAll,
                    icon: _uploading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_rounded),
                    label: Text(_uploading ? 'Uploading…' : 'Upload all'),
                  ),
                ),
              ],
            ),
          ],
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
    this.homeworkUrl = '',
    this.serverFolderPath = '',
    this.lessonFiles = const <LessonFileAsset>[],
    this.materialsHidden = false,
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
  final String homeworkUrl;
  final String serverFolderPath;
  final List<LessonFileAsset> lessonFiles;
  final bool materialsHidden;

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
    String? homeworkUrl,
    String? serverFolderPath,
    List<LessonFileAsset>? lessonFiles,
    bool? materialsHidden,
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
      homeworkUrl: homeworkUrl ?? this.homeworkUrl,
      serverFolderPath: serverFolderPath ?? this.serverFolderPath,
      lessonFiles: lessonFiles ?? this.lessonFiles,
      materialsHidden: materialsHidden ?? this.materialsHidden,
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
      map['homeworkUrl'] = homeworkUrl;
      map['serverFolderPath'] = serverFolderPath;
      map['materialsHidden'] = materialsHidden;
    }

    if (includeOnlineExtras) {
      map['materialsUrl'] = materialsUrl;
      map['homeworkUrl'] = homeworkUrl;
      map['serverFolderPath'] = serverFolderPath;
    }

    if (lessonFiles.isNotEmpty) {
      map['lessonFiles'] = lessonFiles.map((x) => x.toMap()).toList();
    }

    return map;
  }

  factory SyllabusSession.fromMap(Map m) {
    final lessonFilesRaw = m['lessonFiles'];
    final lessonFiles = <LessonFileAsset>[];
    if (lessonFilesRaw is List) {
      for (final item in lessonFilesRaw) {
        final parsed = LessonFileAsset.fromAny(item);
        if (parsed != null) lessonFiles.add(parsed);
      }
    } else if (lessonFilesRaw is Map) {
      for (final item in lessonFilesRaw.values) {
        final parsed = LessonFileAsset.fromAny(item);
        if (parsed != null) lessonFiles.add(parsed);
      }
    }

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
      homeworkUrl: (m['homeworkUrl'] ?? '').toString(),
      serverFolderPath: (m['serverFolderPath'] ?? '').toString(),
      lessonFiles: lessonFiles,
      materialsHidden: m['materialsHidden'] == true,
    );
  }
}
