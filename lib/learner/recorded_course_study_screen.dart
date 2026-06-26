// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:confetti/confetti.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../models/certificate_model.dart';
import '../services/certificate_pdf_service.dart';
import '../services/certificate_service.dart';
import '../services/course_feedback_service.dart';
import '../services/recorded_course_offline_cache_service.dart';
import '../services/recorded_offline_video_service.dart';
import '../services/recorded_progress_sync_service.dart';
import '../services/study_streak_service.dart';
import '../services/storage_existence.dart';
import '../shared/app_feedback.dart';
import '../shared/app_connectivity.dart';
import '../shared/offline_action_guard.dart';
import '../shared/human_error.dart';
import '../shared/material_webview_screen.dart';
import '../shared/learner_web_layout.dart';
import '../shared/learner_notice_popup.dart';
import '../shared/responsive_layout.dart';
import '../shared/web_download.dart';
import 'recorded_video_player_screen.dart';

part 'recorded_course_models.dart';
part 'recorded_course_certificate_handler.dart';

const int _kYbsDeepBlueHex = 0xFF0B2545;
const int _kYbsDeepOrangeHex = 0xFFE56A00;

const Color _kYbsDeepBlue = Color(_kYbsDeepBlueHex);
const Color _kYbsDeepOrange = Color(_kYbsDeepOrangeHex);
const Color _kYbsOrangeTextStrong = Color(0xFF7C2D12);

class RecordedCourseStudyScreen extends StatefulWidget {
  const RecordedCourseStudyScreen({
    super.key,
    required this.courseKey,
    required this.courseData,
    this.embedded = false,
    this.showOverviewCard = true,
    this.onProgressChanged,
  });

  final String courseKey;
  final Map<String, dynamic> courseData;
  final bool embedded;
  final bool showOverviewCard;
  final VoidCallback? onProgressChanged;

  @override
  State<RecordedCourseStudyScreen> createState() =>
      _RecordedCourseStudyScreenState();
}

class _RecordedCourseStudyScreenState extends State<RecordedCourseStudyScreen> {
  static const String _usersNode = 'users';
  static const String _syllabiNode = 'syllabi';
  static const String _recordedAccessNode = 'recorded_access';
  static const String _recordedProgressNode = 'recorded_progress';

  final FirebaseDatabase _db = FirebaseDatabase.instance;
  late final _CertificateHandler _certHandler = _CertificateHandler(
    certificateService: CertificateService(),
    certificatePdfService: CertificatePdfService(),
    getUid: () => _uid,
    getCourseId: () => _courseId,
    getCourseKey: () => widget.courseKey,
    getTitle: () => _title,
    getCachedCpdHours: () => _cachedCpdHours,
    getCachedShortDescription: () => _cachedShortDescription,
    getFlatSessions: () => _flatSessions,
    progressOf: _progressOf,
    isSessionCompleted: _isSessionCompleted,
    sessionCompletionAt: _sessionCompletionAt,
    isModuleCompleted: _isModuleCompleted,
    sanitizeIdPart: _sanitizeIdPart,
    fmtYmd: _fmtYmd,
    oneYearAfter: _oneYearAfter,
    learnerIdentity: _learnerIdentity,
    resolveInstructorName: _resolveInstructorName,
    snack: _snack,
  );
  final RecordedOfflineVideoService _offlineVideos =
      RecordedOfflineVideoService.instance;
  final RecordedCourseOfflineCacheService _offlineCourseCache =
      RecordedCourseOfflineCacheService.instance;
  final RecordedProgressSyncService _progressSync =
      RecordedProgressSyncService.instance;

  void _debug(String message) {
    // no-op in production build
  }

  bool _busy = true;
  String? _error;

  String _uid = '';
  String _courseId = '';

  int _expiresAt = 0;
  int _durationMonths = 0;

  List<_RecordedUnit> _units = <_RecordedUnit>[];
  final Map<String, _RecordedProgress> _progressBySessionId =
      <String, _RecordedProgress>{};
  bool _usingOfflineCourseCache = false;

  final Set<String> _expandedModuleLabels = <String>{};
  final Map<String, String> _selectedUnitByModule = <String, String>{};
  String? _openingMaterialsSessionId;
  String? _openingVideoSessionId;
  final Set<String> _expandedUnitDetails = <String>{};
  final Set<String> _expandedLessonDetails = <String>{};
  final Map<String, String> _teacherNameByUidCache = <String, String>{};
  final Map<String, StorageCheckResult> _storageCheckCacheByUrl =
      <String, StorageCheckResult>{};
  bool _hasLoaded = false;
  String _cachedCpdHours = '40';
  String _cachedShortDescription = '';
  String _cachedInstructorName = '';
  Map<String, String> _cachedIdentity = <String, String>{};

  late final ConfettiController _confettiController = ConfettiController(
    duration: const Duration(seconds: 4),
  );
  bool _celebrated = false;
  final Set<String> _celebratedMilestones = <String>{};

  @override
  void initState() {
    super.initState();
    _cachedCpdHours = (widget.courseData['cpd_hours'] ?? '40').toString();
    _cachedShortDescription = (widget.courseData['short_description'] ?? '')
        .toString();
    _offlineVideos.addListener(_onOfflineVideosChanged);
    unawaited(_offlineVideos.ensureLoaded());
    unawaited(_loadMilestonesFromPrefs());
    _loadAll();
  }

  @override
  void dispose() {
    _offlineVideos.removeListener(_onOfflineVideosChanged);
    _confettiController.dispose();
    super.dispose();
  }

  void _onOfflineVideosChanged() {
    if (!mounted) return;
    setState(() {});
  }

  DatabaseReference get _usersRef => _db.ref(_usersNode);

  DatabaseReference get _syllabiRef => _db.ref(_syllabiNode);
  DatabaseReference get _coursesRef => _db.ref('courses');

  DatabaseReference get _courseUserRef =>
      _usersRef.child(_uid).child('courses').child(widget.courseKey);

  DatabaseReference get _recordedAccessRef =>
      _courseUserRef.child(_recordedAccessNode);

  DatabaseReference get _recordedProgressRef =>
      _courseUserRef.child(_recordedProgressNode);

  DatabaseReference get _paymentSummaryRef =>
      _courseUserRef.child('payment_summary');

  Future<void> _loadAll() async {
    _debug('loadAll start courseKey=${widget.courseKey}');
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Not logged in.');
      }

      _uid = user.uid;
      _courseId = _courseIdOf(widget.courseData);
      _debug('resolved uid=$_uid courseId=$_courseId');

      if (_courseId.isEmpty) {
        throw Exception('Missing recorded course id.');
      }

      if (AppConnectivity.instance.isOffline) {
        final loaded = await _loadFromOfflineCourseCache();
        if (loaded) return;
        throw Exception('No network and no cached data available.');
      }

      final results = await Future.wait<dynamic>([
        _recordedAccessRef.get(),
        _recordedProgressRef.get(),
        _paymentSummaryRef.get(),
        _syllabiRef.child(_courseId).child('recorded').get(),
      ]).timeout(const Duration(seconds: 12));

      final DataSnapshot accessSnap = results[0] as DataSnapshot;
      final DataSnapshot progressSnap = results[1] as DataSnapshot;
      final DataSnapshot paymentSummarySnap = results[2] as DataSnapshot;
      final DataSnapshot syllabusSnap = results[3] as DataSnapshot;
      _debug(
        'snapshots access=${accessSnap.exists} progress=${progressSnap.exists} '
        'syllabus=${syllabusSnap.exists}',
      );

      int expiresAt = 0;
      int durationMonths = 0;
      if (accessSnap.value is Map) {
        final map = Map<String, dynamic>.from(accessSnap.value as Map);
        expiresAt = _asInt(map['expiresAt']);
        durationMonths = _asInt(map['durationMonths']);
      }
      if ((expiresAt <= 0 || durationMonths <= 0) &&
          paymentSummarySnap.value is Map) {
        final sum = Map<String, dynamic>.from(paymentSummarySnap.value as Map);
        if (expiresAt <= 0) {
          expiresAt = _asInt(sum['expiresAt']);
        }
        if (durationMonths <= 0) {
          durationMonths = _asInt(sum['durationMonths']);
        }
      }

      final progressById = _parseProgress(progressSnap.value);
      final units = _parseUnits(syllabusSnap.value);

      for (final unit in units) {
        for (final session in unit.sessions) {
          final existing = progressById[session.id];
          final merged = await _progressSync.mergeWithLocalProgress(
            uid: _uid,
            courseKey: widget.courseKey,
            sessionId: session.id,
            firebaseProgress: existing != null
                ? existing.toMap()
                : const <String, dynamic>{},
          );
          if (merged.isNotEmpty) {
            progressById[session.id] = _RecordedProgress.fromMap(merged);
          }
        }
      }

      final accessMap = accessSnap.value is Map
          ? Map<String, dynamic>.from(accessSnap.value as Map)
          : <String, dynamic>{};
      final paymentMap = paymentSummarySnap.value is Map
          ? Map<String, dynamic>.from(paymentSummarySnap.value as Map)
          : <String, dynamic>{};
      final syllabusMap = syllabusSnap.value is Map
          ? Map<String, dynamic>.from(syllabusSnap.value as Map)
          : <String, dynamic>{};
      final progressMap = progressSnap.value is Map
          ? Map<String, dynamic>.from(progressSnap.value as Map)
          : <String, dynamic>{};
      if (syllabusMap.isNotEmpty) {
        final cachedCourse = Map<String, dynamic>.from(widget.courseData);
        if (accessMap.isNotEmpty) cachedCourse['recorded_access'] = accessMap;
        if (paymentMap.isNotEmpty) cachedCourse['payment_summary'] = paymentMap;
        if (progressMap.isNotEmpty) {
          cachedCourse['recorded_progress'] = progressMap;
        }
        unawaited(
          _offlineCourseCache.save(
            RecordedCourseOfflineCache(
              uid: _uid,
              courseKey: widget.courseKey,
              courseId: _courseId,
              courseData: cachedCourse,
              recordedAccess: accessMap,
              paymentSummary: paymentMap,
              recordedSyllabus: syllabusMap,
              cachedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ),
        );
      }

      _cachedCpdHours = (widget.courseData['cpd_hours'] ?? '40').toString();
      _cachedShortDescription = (widget.courseData['short_description'] ?? '')
          .toString();

      if (!mounted) return;
      setState(() {
        _expiresAt = expiresAt;
        _durationMonths = durationMonths;
        _progressBySessionId
          ..clear()
          ..addAll(progressById);
        _units = units;
        _usingOfflineCourseCache = false;
        _ensureExpandedModules();
        _ensureSelectedUnits();
        _busy = false;
        _hasLoaded = true;
      });
      _celebrateIfComplete();
      _debug(
        'loadAll success units=${_units.length} totalSessions=$_totalSessions '
        'completed=$_completedSessions expiresAt=$_expiresAt',
      );
    } catch (e) {
      _debug('loadAll error=$e');
      final loadedFromCache = await _loadFromOfflineCourseCache();
      if (loadedFromCache) return;
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Future<void> _refreshProgressFromSync() async {
    if (!_hasLoaded || _units.isEmpty) {
      await _loadAll();
      return;
    }
    for (final unit in _units) {
      for (final session in unit.sessions) {
        final existing = _progressOf(session.id);
        final merged = await _progressSync.mergeWithLocalProgress(
          uid: _uid,
          courseKey: widget.courseKey,
          sessionId: session.id,
          firebaseProgress: existing.toMap(),
        );
        if (merged.isNotEmpty) {
          _progressBySessionId[session.id] = _RecordedProgress.fromMap(merged);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _ensureExpandedModules();
      _ensureSelectedUnits();
    });
    _celebrateIfComplete();
    widget.onProgressChanged?.call();
  }

  Map<String, _RecordedProgress> _parseProgress(dynamic raw) {
    final out = <String, _RecordedProgress>{};
    if (raw is! Map) return out;
    final rawMap = Map<String, dynamic>.from(raw);
    for (final entry in rawMap.entries) {
      if (entry.value is! Map) continue;
      out[entry.key] = _RecordedProgress.fromMap(
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
    return out;
  }

  List<_RecordedUnit> _parseUnits(dynamic raw) {
    final units = <_RecordedUnit>[];
    if (raw is Map) {
      final root = Map<String, dynamic>.from(raw);
      final rawModules = _asListOfMaps(root['modules']);
      if (rawModules.isNotEmpty) {
        for (int mi = 0; mi < rawModules.length; mi++) {
          final module = rawModules[mi];
          final moduleOrder = _asInt(module['order']) > 0
              ? _asInt(module['order'])
              : (mi + 1);
          final moduleLabel =
              (module['otherTitle'] ?? '').toString().trim().isNotEmpty
              ? (module['otherTitle'] ?? '').toString().trim()
              : ((module['title'] ?? '').toString().trim().isNotEmpty
                    ? (module['title'] ?? '').toString().trim()
                    : 'Module ${mi + 1}');
          final rawUnits = _asListOfMaps(module['units']);
          for (int ui = 0; ui < rawUnits.length; ui++) {
            final u = rawUnits[ui];
            final unitOrder = _asInt(u['order']) > 0
                ? _asInt(u['order'])
                : (ui + 1);
            units.add(
              _RecordedUnit.fromMap({
                ...u,
                'otherTitle': moduleLabel,
                'sessions': u['lessons'],
                'order': (moduleOrder * 1000) + unitOrder,
              }),
            );
          }
        }
      } else {
        final rawUnits = _asListOfMaps(root['units']);
        for (final u in rawUnits) {
          units.add(_RecordedUnit.fromMap(u));
        }
      }
    }

    units.sort((a, b) => a.order.compareTo(b.order));
    for (final unit in units) {
      unit.sessions.sort((a, b) {
        final aa = a.sessionNumber > 0 ? a.sessionNumber : a.order;
        final bb = b.sessionNumber > 0 ? b.sessionNumber : b.order;
        return aa.compareTo(bb);
      });
    }
    return units;
  }

  Future<bool> _loadFromOfflineCourseCache() async {
    final cache = await _offlineCourseCache.load(
      uid: _uid,
      courseKey: widget.courseKey,
    );
    if (cache == null || cache.recordedSyllabus.isEmpty) return false;

    final units = _parseUnits(cache.recordedSyllabus);
    if (units.isEmpty) return false;
    final progressById = _parseProgress(cache.courseData['recorded_progress']);
    for (final unit in units) {
      for (final session in unit.sessions) {
        final pendingOrRemote = await _progressSync.loadSessionProgress(
          progressRef: _recordedProgressRef.child(session.id),
          uid: _uid,
          courseKey: widget.courseKey,
          sessionId: session.id,
        );
        if (pendingOrRemote.isNotEmpty) {
          progressById[session.id] = _RecordedProgress.fromMap(pendingOrRemote);
        }
      }
    }

    var expiresAt = _asInt(cache.recordedAccess['expiresAt']);
    var durationMonths = _asInt(cache.recordedAccess['durationMonths']);
    if (expiresAt <= 0) expiresAt = _asInt(cache.paymentSummary['expiresAt']);
    if (durationMonths <= 0) {
      durationMonths = _asInt(cache.paymentSummary['durationMonths']);
    }

    if (!mounted) return true;
    setState(() {
      _courseId = cache.courseId.trim().isEmpty ? _courseId : cache.courseId;
      _expiresAt = expiresAt;
      _durationMonths = durationMonths;
      _progressBySessionId
        ..clear()
        ..addAll(progressById);
      _units = units;
      _usingOfflineCourseCache = true;
      _ensureExpandedModules();
      _ensureSelectedUnits();
      _error = null;
      _busy = false;
      _hasLoaded = true;
    });
    return true;
  }

  void _ensureExpandedModules() {
    final moduleEntries = _unitsByModule.entries.toList();
    if (moduleEntries.isEmpty) return;

    String? currentModule;
    for (final entry in moduleEntries) {
      if (!_isModuleCompleted(entry.value)) {
        currentModule = entry.key;
        break;
      }
    }
    currentModule ??= moduleEntries.last.key;

    _expandedModuleLabels.clear();
    _expandedModuleLabels.add(currentModule);
  }

  void _ensureSelectedUnits() {
    final byModule = _unitsByModule;
    _selectedUnitByModule.removeWhere(
      (module, _) => !byModule.containsKey(module),
    );
    for (final entry in byModule.entries) {
      if (entry.value.isEmpty) continue;
      final selectedId = _selectedUnitByModule[entry.key];
      final hasSelected = entry.value.any((u) => _unitIdOf(u) == selectedId);
      if (!hasSelected) {
        _selectedUnitByModule[entry.key] = _unitIdOf(entry.value.first);
      }
    }
  }

  static List<Map<String, dynamic>> _asListOfMaps(dynamic node) {
    final out = <Map<String, dynamic>>[];

    if (node is List) {
      for (final item in node) {
        if (item is Map) {
          out.add(Map<String, dynamic>.from(item));
        }
      }
      return out;
    }

    if (node is Map) {
      final map = Map<dynamic, dynamic>.from(node);
      for (final entry in map.entries) {
        if (entry.value is Map) {
          out.add(Map<String, dynamic>.from(entry.value as Map));
        }
      }
      return out;
    }

    return out;
  }

  String _courseIdOf(Map<String, dynamic> course) {
    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};
    return (cls['course_id'] ?? course['id'] ?? '').toString().trim();
  }

  String get _title {
    return (widget.courseData['title'] ??
            widget.courseData['course_title'] ??
            'Recorded Course')
        .toString();
  }

  List<_SessionRef> get _flatSessions {
    final out = <_SessionRef>[];
    for (int ui = 0; ui < _units.length; ui++) {
      final unit = _units[ui];
      for (int si = 0; si < unit.sessions.length; si++) {
        out.add(
          _SessionRef(
            unitIndex: ui,
            sessionIndex: si,
            unit: unit,
            session: unit.sessions[si],
          ),
        );
      }
    }
    return out;
  }

  Map<String, List<_RecordedUnit>> get _unitsByModule {
    final byModule = <String, List<_RecordedUnit>>{};
    for (final unit in _units) {
      final moduleLabel = _moduleLabelOf(unit);
      byModule.putIfAbsent(moduleLabel, () => <_RecordedUnit>[]).add(unit);
    }
    return byModule;
  }

  String _moduleLabelOf(_RecordedUnit unit) {
    final label = unit.otherTitle.trim();
    return label.isEmpty ? 'Module' : label;
  }

  String _unitIdOf(_RecordedUnit unit) {
    final raw = unit.id.trim();
    if (raw.isNotEmpty) return raw;
    return '${unit.order}|${unit.title.trim()}|${unit.otherTitle.trim()}';
  }

  int _moduleCompletedSessions(List<_RecordedUnit> moduleUnits) {
    int done = 0;
    for (final unit in moduleUnits) {
      done += _countCompletedInUnit(unit);
    }
    return done;
  }

  int _moduleTotalSessions(List<_RecordedUnit> moduleUnits) {
    int total = 0;
    for (final unit in moduleUnits) {
      total += unit.sessions.length;
    }
    return total;
  }

  int _moduleCompletedUnits(List<_RecordedUnit> moduleUnits) {
    int done = 0;
    for (final unit in moduleUnits) {
      if (_isUnitCompleted(unit)) done++;
    }
    return done;
  }

  bool _isModuleCompleted(List<_RecordedUnit> moduleUnits) {
    if (moduleUnits.isEmpty) return false;
    return _moduleCompletedUnits(moduleUnits) == moduleUnits.length;
  }

  int _flatIndexOfSessionId(String sessionId) {
    for (int i = 0; i < _flatSessions.length; i++) {
      if (_flatSessions[i].session.id == sessionId) return i;
    }
    return -1;
  }

  int _nextIncompleteFlatIndex() {
    for (int i = 0; i < _flatSessions.length; i++) {
      final session = _flatSessions[i].session;
      if (_isSessionUnlocked(i) && !_isSessionCompleted(session)) return i;
    }
    return -1;
  }

  _RecordedProgress _progressOf(String sessionId) {
    return _progressBySessionId[sessionId] ?? const _RecordedProgress();
  }

  bool _sessionRequiresVideo(_RecordedSession session) {
    return session.videoUrl.trim().isNotEmpty;
  }

  bool _sessionRequiresMaterials(_RecordedSession session) {
    return session.materialsUrl.trim().isNotEmpty && !session.materialsHidden;
  }

  bool _isSessionCompleted(_RecordedSession session) {
    final p = _progressOf(session.id);

    final requiresVideo = _sessionRequiresVideo(session);
    final requiresMaterials = _sessionRequiresMaterials(session);

    if (requiresVideo && requiresMaterials) {
      return p.videoCompleted || p.materialsCompleted;
    }

    if (requiresVideo) return p.videoCompleted;
    if (requiresMaterials) return p.materialsCompleted;

    return false;
  }

  bool _arePreviousModulesCompleted(int flatIndex) {
    final sessionRef = _flatSessions[flatIndex];
    final currentModule = _moduleLabelOf(sessionRef.unit);
    final moduleEntries = _unitsByModule.entries.toList();
    for (int i = 0; i < moduleEntries.length; i++) {
      if (moduleEntries[i].key == currentModule) {
        for (int j = 0; j < i; j++) {
          if (!_isModuleCompleted(moduleEntries[j].value)) return false;
        }
        return true;
      }
    }
    return true;
  }

  bool _isSessionUnlocked(int flatIndex) {
    if (flatIndex <= 0) return true;
    final previous = _flatSessions[flatIndex - 1].session;
    if (!_isSessionCompleted(previous)) return false;
    return _arePreviousModulesCompleted(flatIndex);
  }

  int get _totalSessions => _flatSessions.length;

  int get _completedSessions {
    int done = 0;
    for (final ref in _flatSessions) {
      if (_isSessionCompleted(ref.session)) {
        done++;
      }
    }
    return done;
  }

  double get _progressValue {
    if (_totalSessions <= 0) return 0;
    return _completedSessions / _totalSessions;
  }

  bool get _courseCertificateUnlocked {
    return _totalUnits > 0 && _completedUnits == _totalUnits;
  }

  int get _totalUnits => _units.length;

  bool _isUnitCompleted(_RecordedUnit unit) {
    final total = unit.sessions.length;
    if (total <= 0) return false;
    return _countCompletedInUnit(unit) == total;
  }

  int get _completedUnits {
    int done = 0;
    for (final unit in _units) {
      if (_isUnitCompleted(unit)) done++;
    }
    return done;
  }

  int get _daysLeft {
    if (_expiresAt <= 0) return 0;
    final now = DateTime.now();
    final expiry = DateTime.fromMillisecondsSinceEpoch(_expiresAt);
    final today = DateTime(now.year, now.month, now.day);
    final end = DateTime(expiry.year, expiry.month, expiry.day);
    return end.difference(today).inDays;
  }

  _ExpiryStyle get _expiryStyle {
    if (_expiresAt <= 0) {
      return const _ExpiryStyle(
        bg: Color(0xFFF8FAFC),
        border: Color(0xFFE2E8F0),
        fg: Color(0xFF334155),
        label: 'No expiry found',
        icon: Icons.info_outline_rounded,
      );
    }

    if (_daysLeft < 0) {
      return const _ExpiryStyle(
        bg: Color(0xFFFEF2F2),
        border: Color(0xFFFECACA),
        fg: Color(0xFFB91C1C),
        label: 'Expired',
        icon: Icons.warning_amber_rounded,
      );
    }

    if (_daysLeft <= 3) {
      return const _ExpiryStyle(
        bg: Color(0xFFFFF7ED),
        border: Color(0xFFFED7AA),
        fg: Color(0xFFC2410C),
        label: 'Expires very soon',
        icon: Icons.timer_off_rounded,
      );
    }

    if (_daysLeft <= 7) {
      return const _ExpiryStyle(
        bg: Color(0xFFFFFBEB),
        border: Color(0xFFFDE68A),
        fg: Color(0xFFB45309),
        label: 'Expires soon',
        icon: Icons.schedule_rounded,
      );
    }

    return const _ExpiryStyle(
      bg: Color(0xFFF0FDF4),
      border: Color(0xFFBBF7D0),
      fg: Color(0xFF15803D),
      label: 'Access active',
      icon: Icons.verified_rounded,
    );
  }

  String _formatDateMs(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _markMaterialsCompleted(_RecordedSession session) async {
    _debug('markMaterialsCompleted sessionId=${session.id}');
    if (_progressOf(session.id).materialsCompleted) return;
    unawaited(
      StudyStreakService.instance.updateStreak(
        uid: _uid,
        courseKey: widget.courseKey,
      ),
    );
    final current = _progressOf(session.id);
    final updated = current.copyWith(
      materialsCompleted: true,
      materialsCompletedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final completed = _resolveCompleted(session, updated);

    await _progressSync.updateProgress(
      progressRef: _recordedProgressRef.child(session.id),
      uid: _uid,
      courseKey: widget.courseKey,
      sessionId: session.id,
      patch: {
        'videoCompleted': updated.videoCompleted,
        'materialsCompleted': updated.materialsCompleted,
        'videoCompletedAt': updated.videoCompletedAt,
        'materialsCompletedAt': updated.materialsCompletedAt,
        'completed': completed,
        'updatedAt': ServerValue.timestamp,
      },
    );

    if (!mounted) return;
    setState(() {
      _progressBySessionId[session.id] = updated.copyWith(completed: completed);
    });
    _celebrateIfComplete();
    widget.onProgressChanged?.call();
    _debug(
      'markMaterialsCompleted done sessionId=${session.id} completed=$completed',
    );
  }

  Future<void> _markVideoCompletedManually(_RecordedSession session) async {
    _debug('markVideoCompletedManually sessionId=${session.id}');
    if (_progressOf(session.id).videoCompleted) return;
    unawaited(
      StudyStreakService.instance.updateStreak(
        uid: _uid,
        courseKey: widget.courseKey,
      ),
    );
    final current = _progressOf(session.id);
    final updated = current.copyWith(
      videoCompleted: true,
      videoCompletedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final completed = _resolveCompleted(session, updated);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await _progressSync.updateProgress(
      progressRef: _recordedProgressRef.child(session.id),
      uid: _uid,
      courseKey: widget.courseKey,
      sessionId: session.id,
      patch: {
        'videoCompleted': updated.videoCompleted,
        'materialsCompleted': updated.materialsCompleted,
        'videoCompletedAt': updated.videoCompletedAt,
        'materialsCompletedAt': updated.materialsCompletedAt,
        'videoPositionMs': 0,
        'videoDurationMs': 0,
        'completed': completed,
        'updatedAt': ServerValue.timestamp,
        'lastOpenedAt': nowMs,
      },
    );

    if (!mounted) return;
    setState(() {
      _progressBySessionId[session.id] = updated.copyWith(completed: completed);
    });
    _celebrateIfComplete();
    widget.onProgressChanged?.call();
    _debug(
      'markVideoCompletedManually done sessionId=${session.id} completed=$completed',
    );
  }

  bool _resolveCompleted(_RecordedSession session, _RecordedProgress progress) {
    final requiresVideo = _sessionRequiresVideo(session);
    final requiresMaterials = _sessionRequiresMaterials(session);

    if (!requiresVideo && !requiresMaterials) return true;

    if (requiresVideo && requiresMaterials) {
      return progress.videoCompleted || progress.materialsCompleted;
    }

    if (requiresVideo) return progress.videoCompleted;
    if (requiresMaterials) return progress.materialsCompleted;

    return false;
  }

  bool _isValidWebUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  String _lessonUnavailableMessage({
    required String lessonType,
    required _RecordedSession session,
  }) {
    final sessionTitle = session.title.trim().isEmpty
        ? 'Session ${session.sessionNumber > 0 ? session.sessionNumber : '#'}'
        : session.title.trim();
    return '$lessonType is currently unavailable for "$sessionTitle". '
        'Please refresh. If this continues, contact Your Bridge School support and share your course name + session number.';
  }

  RecordedVideoDownloadRequest? _downloadRequestForSession(
    _RecordedSession session,
  ) {
    final url = session.videoUrl.trim();
    if (!_isValidWebUrl(url) || _uid.trim().isEmpty || session.id.isEmpty) {
      return null;
    }
    return RecordedVideoDownloadRequest(
      uid: _uid,
      courseKey: widget.courseKey,
      courseId: _courseId,
      sessionId: session.id,
      sessionTitle: session.title.trim().isEmpty
          ? 'Session ${session.sessionNumber}'
          : session.title.trim(),
      videoUrl: url,
      expiresAt: _expiresAt,
      materialsUrl: session.materialsUrl.trim(),
    );
  }

  List<RecordedVideoDownloadRequest> _downloadRequestsForUnit(
    _RecordedUnit unit,
  ) {
    return unit.sessions
        .map(_downloadRequestForSession)
        .whereType<RecordedVideoDownloadRequest>()
        .toList(growable: false);
  }

  List<RecordedVideoDownloadRequest> _downloadRequestsForModule(
    List<_RecordedUnit> moduleUnits,
  ) {
    return moduleUnits.expand(_downloadRequestsForUnit).toList(growable: false);
  }

  List<RecordedVideoDownloadRequest> _downloadRequestsForCourse() {
    return _units.expand(_downloadRequestsForUnit).toList(growable: false);
  }

  _DownloadSummary _downloadSummaryFor(
    List<RecordedVideoDownloadRequest> requests,
  ) {
    if (requests.isEmpty) return const _DownloadSummary();
    var downloaded = 0;
    var failed = 0;
    var active = 0;
    var bytesDone = 0;
    var bytesTotal = 0;
    for (final request in requests) {
      final info = _offlineVideos.infoFor(
        uid: request.uid,
        courseKey: request.courseKey,
        sessionId: request.sessionId,
      );
      if (info == null) continue;
      if (info.status == RecordedDownloadStatus.downloaded) downloaded++;
      if (info.status == RecordedDownloadStatus.failed) failed++;
      if (info.status == RecordedDownloadStatus.queued ||
          info.status == RecordedDownloadStatus.downloading) {
        active++;
      }
      bytesDone += info.bytesDownloaded;
      bytesTotal += info.bytesTotal;
    }
    return _DownloadSummary(
      total: requests.length,
      downloaded: downloaded,
      failed: failed,
      active: active,
      bytesDownloaded: bytesDone,
      bytesTotal: bytesTotal,
    );
  }

  Future<void> _downloadVideos(
    List<RecordedVideoDownloadRequest> requests, {
    required String emptyMessage,
  }) async {
    if (requests.isEmpty) {
      _snack(emptyMessage);
      return;
    }
    if (_daysLeft < 0) {
      _notice(
        'Your recorded access is expired. Please renew to download videos.',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }
    if (AppConnectivity.instance.isOffline) {
      _notice(
        'No internet connection. Connect to download videos.',
        tone: LearnerNoticeTone.error,
      );
      return;
    }
    await _offlineVideos.enqueueAll(requests);
    if (!mounted) return;
    _notice(
      requests.length == 1
          ? 'Download started.'
          : '${requests.length} downloads queued.',
      tone: LearnerNoticeTone.success,
    );
  }

  Future<void> _deleteDownloads(
    List<RecordedVideoDownloadRequest> requests, {
    required String title,
  }) async {
    final existing = requests
        .where((request) {
          return _offlineVideos.infoFor(
                uid: request.uid,
                courseKey: request.courseKey,
                sessionId: request.sessionId,
              ) !=
              null;
        })
        .toList(growable: false);
    if (existing.isEmpty) {
      _snack('No downloaded videos to delete.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(
          'Delete ${existing.length} offline session${existing.length == 1 ? '' : 's'} from this device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _offlineVideos.deleteMany(existing);
    if (!mounted) return;
    _notice('Offline content deleted.', tone: LearnerNoticeTone.success);
  }

  Future<bool> _isLessonAssetMissingOnServer({required String url}) async {
    final cacheKey = url.trim();
    final cached = _storageCheckCacheByUrl[cacheKey];
    if (cached != null) {
      return cached == StorageCheckResult.missing;
    }

    final check = await StorageExistence.checkUrlExistsOnManagedStorage(
      cacheKey,
      expect: 'file',
    );
    _storageCheckCacheByUrl[cacheKey] = check;
    return check == StorageCheckResult.missing;
  }

  Future<void> _openMaterials(_RecordedSession session) async {
    setState(() => _openingMaterialsSessionId = session.id);
    try {
      final url = session.materialsUrl.trim();
      _debug('openMaterials sessionId=${session.id} hasUrl=${url.isNotEmpty}');
      if (!_isValidWebUrl(url)) {
        _snack(
          _lessonUnavailableMessage(
            lessonType: 'Reading lesson',
            session: session,
          ),
        );
        return;
      }

      final localPath = await _offlineVideos.localMaterialsPathFor(
        uid: _uid,
        courseKey: widget.courseKey,
        sessionId: session.id,
      );

      if (localPath != null) {
        if (!mounted) return;
        await OfflineActionGuard.runExclusive(
          context,
          'learner.recorded.read.${widget.courseKey}.${session.id}',
          () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MaterialWebViewScreen.fromUrl(
                  title: session.title.isEmpty
                      ? 'Session Reading'
                      : session.title,
                  url: Uri.file(localPath).toString(),
                ),
              ),
            );
          },
        );
      } else if (AppConnectivity.instance.isOffline) {
        _notice(
          'Reading materials need internet. Download them beforehand to read offline.',
          tone: LearnerNoticeTone.warning,
        );
        return;
      } else {
        final isMissing = await _isLessonAssetMissingOnServer(url: url);
        if (isMissing) {
          _snack(
            _lessonUnavailableMessage(
              lessonType: 'Reading lesson',
              session: session,
            ),
          );
          return;
        }
        if (!mounted) return;

        await OfflineActionGuard.runExclusive(
          context,
          'learner.recorded.read.${widget.courseKey}.${session.id}',
          () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MaterialWebViewScreen.fromUrl(
                  title: session.title.isEmpty
                      ? 'Session Reading'
                      : session.title,
                  url: url,
                ),
              ),
            );
          },
        );
      }

      if (!mounted) return;

      await _markMaterialsCompleted(session);
      _snack('Reading marked complete ✅');
    } finally {
      if (mounted) setState(() => _openingMaterialsSessionId = null);
    }
  }

  Widget _buildCompletionBanner() => _certHandler._buildCompletionBanner(
    certificateUnlocked: _courseCertificateUnlocked,
    completedSessions: _completedSessions,
    totalSessions: _totalSessions,
    onCertificateTap: _onCertificateTap,
  );

  Widget _buildTopOverviewCard() {
    final style = _expiryStyle;
    final progressPct = (_progressValue * 100).round();
    final isNarrow = MediaQuery.sizeOf(context).width < 420;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        12,
        isNarrow ? 10 : 12,
        12,
        isNarrow ? 10 : 12,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFF8FBFF)],
        ),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -2,
            right: 0,
            child: Opacity(
              opacity: 0.08,
              child: Image.asset(
                'assets/images/ybs_logo.png',
                width: 54,
                height: 54,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.track_changes_rounded,
                    size: 16,
                    color: Color(0xFF334155),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$progressPct% complete',
                    style: TextStyle(
                      fontSize: isNarrow ? 12 : 12.5,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$_completedSessions/$_totalSessions',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              _buildUnitProgressTrack(),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _expirySubtitle(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: style.fg,
                        fontWeight: FontWeight.w700,
                        fontSize: 11.7,
                        height: 1.25,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _showCourseInfoSheet,
                    icon: const Icon(Icons.info_outline_rounded, size: 16),
                    label: const Text('Details'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1E293B),
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                      minimumSize: const Size.fromHeight(48),
                      padding: EdgeInsets.symmetric(
                        horizontal: isNarrow ? 8 : 10,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUnitProgressTrack() {
    final moduleGroups = _unitsByModule.values.toList();
    final totalUnits = _units.length;
    final doneUnits = _units.where(_isUnitCompleted).length;
    final allSessions = _flatSessions.map((e) => e.session).toList();
    final totalLessons = allSessions.length;
    final doneLessons = allSessions.where(_isSessionCompleted).length;

    final unitsValue = totalUnits == 0
        ? 0.0
        : (doneUnits / totalUnits).clamp(0.0, 1.0);
    final lessonsValue = totalLessons == 0
        ? 0.0
        : (doneLessons / totalLessons).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 340;
        final size = isNarrow ? 118.0 : 132.0;
        return Column(
          children: [
            Center(
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(13),
                      child: CircularProgressIndicator(
                        value: 1,
                        strokeWidth: 8,
                        backgroundColor: const Color(0xFFE2E8F0),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(13),
                      child: CircularProgressIndicator(
                        value: unitsValue,
                        strokeWidth: 8,
                        backgroundColor: Colors.transparent,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF0EA5E9),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(26),
                      child: CircularProgressIndicator(
                        value: 1,
                        strokeWidth: 6,
                        backgroundColor: const Color(0xFFE2E8F0),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(26),
                      child: CircularProgressIndicator(
                        value: lessonsValue,
                        strokeWidth: 6,
                        strokeCap: StrokeCap.round,
                        backgroundColor: Colors.transparent,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF16A34A),
                        ),
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${(unitsValue * 100).round()}%',
                            style: const TextStyle(
                              color: Color(0xFF0284C7),
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            '${(lessonsValue * 100).round()}%',
                            style: const TextStyle(
                              color: Color(0xFF15803D),
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                _buildModuleDots(moduleGroups),
                _legendPill(
                  label: 'Units',
                  pct: (unitsValue * 100).round(),
                  color: const Color(0xFF0284C7),
                ),
                _legendPill(
                  label: 'Lessons',
                  pct: (lessonsValue * 100).round(),
                  color: const Color(0xFF15803D),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _legendPill({
    required String label,
    required int pct,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label $pct%',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11.5,
        ),
      ),
    );
  }

  Widget _buildModuleDots(List<List<_RecordedUnit>> moduleGroups) {
    final doneModules = moduleGroups
        .where((u) => u.isNotEmpty && _moduleCompletedUnits(u) == u.length)
        .length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...moduleGroups.map((units) {
          final isDone =
              units.isNotEmpty && _moduleCompletedUnits(units) == units.length;
          return Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDone ? const Color(0xFFEA580C) : Colors.transparent,
              border: Border.all(color: const Color(0xFFEA580C), width: 2),
            ),
          );
        }),
        const SizedBox(width: 4),
        Text(
          'Modules $doneModules/${moduleGroups.length}',
          style: const TextStyle(
            color: Color(0xFFEA580C),
            fontWeight: FontWeight.w800,
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineOverviewCard() {
    final requests = _downloadRequestsForCourse();
    final summary = _downloadSummaryFor(requests);
    final pct = (summary.progress * 100).round();
    final hasActive = summary.active > 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDDE7F6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF2FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.offline_pin_rounded,
                  color: Color(0xFF4F46E5),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Offline videos',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        fontSize: 14.5,
                      ),
                    ),
                    Text(
                      summary.total == 0
                          ? 'No videos available to download.'
                          : '${summary.downloaded}/${summary.total} downloaded${summary.failed > 0 ? ' • ${summary.failed} failed' : ''}',
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$pct%',
                style: const TextStyle(
                  color: Color(0xFF4F46E5),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: summary.progress,
              minHeight: 7,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: AlwaysStoppedAnimation<Color>(
                hasActive ? const Color(0xFF0EA5E9) : const Color(0xFF4F46E5),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: requests.isEmpty
                      ? null
                      : () => _downloadVideos(
                          requests,
                          emptyMessage: 'No videos available to download.',
                        ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download all'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: requests.isEmpty ? null : _showDownloadsSheet,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('Manage'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showDownloadsSheet() async {
    final requests = _downloadRequestsForCourse();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFFF8FAFC),
      builder: (_) {
        return AnimatedBuilder(
          animation: _offlineVideos,
          builder: (context, _) {
            final summary = _downloadSummaryFor(requests);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Manage offline videos',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${summary.downloaded}/${summary.total} downloaded • ${summary.active} active • ${summary.failed} failed',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: summary.progress,
                      minHeight: 8,
                      backgroundColor: const Color(0xFFE2E8F0),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            await _downloadVideos(
                              requests,
                              emptyMessage: 'No videos available to download.',
                            );
                          },
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Retry / download'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            _offlineVideos.cancelCurrent();
                            _notice(
                              'Cancelling current download.',
                              tone: LearnerNoticeTone.info,
                            );
                          },
                          icon: const Icon(Icons.cancel_rounded),
                          label: const Text('Cancel current'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _deleteDownloads(
                        requests,
                        title: 'Delete all offline videos?',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFB91C1C),
                      ),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Delete all downloads'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openVideoPlaceholder(_RecordedSession session) async {
    setState(() => _openingVideoSessionId = session.id);
    try {
      final openTimer = Stopwatch()..start();
      final hasVideo = session.videoUrl.trim().isNotEmpty;
      final videoUrl = session.videoUrl.trim();
      _debug('openVideo sessionId=${session.id} hasVideo=$hasVideo');
      if (!hasVideo || !_isValidWebUrl(videoUrl)) {
        _snack(
          _lessonUnavailableMessage(
            lessonType: 'Video lesson',
            session: session,
          ),
        );
        return;
      }

      if (_daysLeft < 0) {
        _notice(
          'Your recorded access is expired. Please renew to watch videos.',
          tone: LearnerNoticeTone.warning,
        );
        return;
      }

      final localPath = await _offlineVideos.localPathFor(
        uid: _uid,
        courseKey: widget.courseKey,
        sessionId: session.id,
        videoUrl: videoUrl,
      );

      _debug('openVideo routePushStart sessionId=${session.id}');
      if (!mounted) return;

      await OfflineActionGuard.runExclusive(
        context,
        'learner.recorded.video.${widget.courseKey}.${session.id}',
        () async {
          final flatSessions = _flatSessions
              .map(
                (ref) => {
                  'id': ref.session.id,
                  'title': ref.session.title,
                  'videoUrl': ref.session.videoUrl.trim(),
                },
              )
              .toList();

          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RecordedVideoPlayerScreen(
                uid: _uid,
                courseKey: widget.courseKey,
                courseId: _courseId,
                sessionId: session.id,
                sessionTitle: session.title,
                videoUrl: videoUrl,
                localVideoPath: localPath,
                flatSessions: flatSessions,
              ),
            ),
          );
        },
        requireOnline: localPath == null,
      );
      _debug(
        'openVideo routeReturned sessionId=${session.id} elapsedMs=${openTimer.elapsedMilliseconds}',
      );

      if (!mounted) return;
      await _refreshProgressFromSync();
    } finally {
      if (mounted) setState(() => _openingVideoSessionId = null);
    }
  }

  Future<Map<String, String>> _learnerIdentity() async {
    if (_cachedIdentity.containsKey('fullName') &&
        _cachedIdentity['fullName'] != 'Learner') {
      return Map<String, String>.from(_cachedIdentity);
    }
    final out = <String, String>{'fullName': 'Learner', 'nationalIdNumber': ''};
    try {
      final snap = await _usersRef
          .child(_uid)
          .get()
          .timeout(const Duration(seconds: 10));
      if (!snap.exists || snap.value is! Map) return out;
      final m = Map<String, dynamic>.from(snap.value as Map);
      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();
      final full = '$first $last'.trim();
      final nationalId =
          (m['national_id_number'] ?? m['nationalIdNumber'] ?? '').toString();
      if (full.isNotEmpty) out['fullName'] = full;
      out['nationalIdNumber'] = nationalId.trim();
      _cachedIdentity = Map<String, String>.from(out);
    } catch (_) {}
    return out;
  }

  String _sanitizeIdPart(String raw) {
    final safe = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'item' : safe;
  }

  String _fmtYmd(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _oneYearAfter(String trainingDate) {
    try {
      final d = DateTime.parse(trainingDate);
      return _fmtYmd(d.add(const Duration(days: 365)));
    } catch (_) {
      return _fmtYmd(DateTime.now().add(const Duration(days: 365)));
    }
  }

  String _firstNonEmpty(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = (map[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  void _addNameParts(List<String> out, Set<String> seen, String raw) {
    final extractedMapNames = RegExp(
      r'name\s*:\s*([^,}]+)',
      caseSensitive: false,
    ).allMatches(raw);
    for (final m in extractedMapNames) {
      final cleaned = _cleanInstructorToken(m.group(1) ?? '');
      if (cleaned.isEmpty) continue;
      final key = cleaned.toLowerCase();
      if (seen.add(key)) out.add(cleaned);
    }

    final withoutMapDumps = raw
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'\{[^,]*'), ' ');
    for (final part in withoutMapDumps.split(',')) {
      final cleaned = _cleanInstructorToken(part);
      if (cleaned.isEmpty) continue;
      final key = cleaned.toLowerCase();
      if (seen.add(key)) out.add(cleaned);
    }
  }

  String _cleanInstructorToken(String raw) {
    var token = raw.trim();
    if (token.isEmpty) return '';

    final mapLikeMatch = RegExp(
      r'name\s*:\s*([^,}]+)',
      caseSensitive: false,
    ).firstMatch(token);
    if (mapLikeMatch != null) {
      token = (mapLikeMatch.group(1) ?? '').trim();
    }

    token = token
        .replaceAll(RegExp(r'[\{\}\[\]]'), ' ')
        .replaceAll(
          RegExp(
            r'(uid|teacher_?uid)\s*:\s*[A-Za-z0-9_-]{6,}',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    token = token.replaceAll(RegExp("^[\"']+|[\"']+\$"), '').trim();
    if (token.isEmpty) return '';
    final lower = token.toLowerCase();
    if (lower.contains('uid:') ||
        lower.contains('teacheruid') ||
        lower.contains('teacher_uid')) {
      return '';
    }
    if (token.contains(':')) return '';
    if (_looksLikeUidValue(token)) return '';
    return token;
  }

  bool _looksLikeUidValue(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    if (v.contains(' ') || v.contains(',')) return false;
    if (!RegExp(r'^[A-Za-z0-9_-]{20,}$').hasMatch(v)) return false;
    return RegExp(r'[A-Za-z]').hasMatch(v);
  }

  String _abbreviateInstructorName(String raw) {
    final parts = raw
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first;

    final firstName = parts.first;
    final last = parts.last;
    final match = RegExp(r'[A-Za-z]').firstMatch(last);
    if (match == null) return firstName;
    final initial = match.group(0)!.toUpperCase();
    return '$firstName $initial.';
  }

  String _joinedInstructorNames(List<String> names) {
    final out = <String>[];
    final seen = <String>{};
    for (final raw in names) {
      _addNameParts(out, seen, raw);
    }
    if (out.length <= 1) {
      return out.join(', ');
    }
    final abbreviated = out
        .map(_abbreviateInstructorName)
        .where((s) => s.isNotEmpty)
        .toList();
    return abbreviated.join(', ');
  }

  Map<String, String>? _instructorEntryFromAny(
    dynamic raw, {
    String fallbackUid = '',
  }) {
    if (raw == null) return null;

    if (raw is Map) {
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();
      final fromParts = '$first $last'.trim();

      final uid = _firstNonEmpty(m, ['uid', 'teacherUid', 'teacher_uid', 'id']);
      final name = _firstNonEmpty(m, [
        'name',
        'teacherName',
        'teacher_name',
        'instructorName',
        'instructor',
        'fullName',
        'full_name',
      ]);

      final resolvedUid = uid.isNotEmpty ? uid : fallbackUid.trim();
      final resolvedName = name.isNotEmpty ? name : fromParts;
      if (resolvedUid.isEmpty && resolvedName.isEmpty) return null;
      return {'uid': resolvedUid, 'name': resolvedName};
    }

    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    return {'uid': fallbackUid.trim(), 'name': text};
  }

  List<Map<String, String>> _instructorEntriesFromNode(dynamic node) {
    final out = <Map<String, String>>[];

    if (node == null) return out;

    if (node is List) {
      for (final item in node) {
        final entry = _instructorEntryFromAny(item);
        if (entry != null) out.add(entry);
      }
      return out;
    }

    if (node is Map) {
      final m = node.map((k, v) => MapEntry(k.toString(), v));
      if (m.containsKey('uid') ||
          m.containsKey('name') ||
          m.containsKey('teacherUid') ||
          m.containsKey('teacherName')) {
        final entry = _instructorEntryFromAny(m);
        if (entry != null) out.add(entry);
        return out;
      }

      final entries = m.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final e in entries) {
        final entry = _instructorEntryFromAny(e.value, fallbackUid: e.key);
        if (entry != null) out.add(entry);
      }
      return out;
    }

    final text = node.toString().trim();
    if (text.isNotEmpty) {
      for (final part in text.split(',')) {
        final name = part.trim();
        if (name.isNotEmpty) out.add({'uid': '', 'name': name});
      }
    }
    return out;
  }

  Future<String> _teacherNameFromUid(String uid) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return '';

    final cached = _teacherNameByUidCache[cleanUid];
    if (cached != null) return cached;

    try {
      final snap = await _usersRef.child(cleanUid).get();
      if (!snap.exists || snap.value is! Map) {
        _teacherNameByUidCache[cleanUid] = '';
        return '';
      }

      final m = Map<String, dynamic>.from(snap.value as Map);
      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();
      final full = '$first $last'.trim();

      final resolved = full.isNotEmpty
          ? full
          : _firstNonEmpty(m, [
              'name',
              'teacherName',
              'instructorName',
              'displayName',
            ]);

      _teacherNameByUidCache[cleanUid] = resolved;
      return resolved;
    } catch (_) {
      _teacherNameByUidCache[cleanUid] = '';
      return '';
    }
  }

  Future<List<String>> _instructorNamesFromCourseMap(
    Map<String, dynamic> courseMap,
  ) async {
    final out = <String>[];
    final seen = <String>{};

    final fromStructured = <Map<String, String>>[
      ..._instructorEntriesFromNode(courseMap['instructors']),
      ..._instructorEntriesFromNode(courseMap['instructors_map']),
    ];

    for (final entry in fromStructured) {
      final rawName = (entry['name'] ?? '').trim();
      final uid = (entry['uid'] ?? '').trim();

      if (rawName.isNotEmpty) {
        _addNameParts(out, seen, rawName);
      }

      if (uid.isNotEmpty) {
        final resolved = await _teacherNameFromUid(uid);
        _addNameParts(out, seen, resolved);
      } else if (_looksLikeUidValue(rawName)) {
        final resolved = await _teacherNameFromUid(rawName);
        _addNameParts(out, seen, resolved);
      }
    }

    if (out.isNotEmpty) return out;

    final cls = courseMap['class'] is Map
        ? Map<String, dynamic>.from(courseMap['class'] as Map)
        : <String, dynamic>{};
    final fromClass = _firstNonEmpty(cls, [
      'instructor',
      'teacher_name',
      'teacherName',
      'instructorName',
    ]);
    _addNameParts(out, seen, fromClass);

    final fromTop = _firstNonEmpty(courseMap, [
      'instructor',
      'teacher_name',
      'teacherName',
      'instructorName',
    ]);
    _addNameParts(out, seen, fromTop);

    return out;
  }

  Future<String> _resolveInstructorName() async {
    if (_cachedInstructorName.isNotEmpty) return _cachedInstructorName;

    try {
      final localNames = await _instructorNamesFromCourseMap(widget.courseData);
      final joined = _joinedInstructorNames(localNames);
      if (joined.isNotEmpty) {
        _cachedInstructorName = joined;
        return joined;
      }
    } catch (_) {}

    try {
      if (_courseId.isNotEmpty) {
        final byCourseId = await _coursesRef
            .child(_courseId)
            .get()
            .timeout(const Duration(seconds: 10));
        if (byCourseId.exists && byCourseId.value is Map) {
          final names = await _instructorNamesFromCourseMap(
            Map<String, dynamic>.from(byCourseId.value as Map),
          );
          final joined = _joinedInstructorNames(names);
          if (joined.isNotEmpty) {
            _cachedInstructorName = joined;
            return joined;
          }
        }
      }
    } catch (_) {}

    _cachedInstructorName = 'Seddik. B';
    return _cachedInstructorName;
  }

  int _sessionCompletionAt(_RecordedProgress p) {
    return math.max(p.videoCompletedAt, p.materialsCompletedAt);
  }

  Future<void> _onCertificateTap() => _certHandler._onCertificateTap(
    context: context,
    mounted: mounted,
    setState: setState,
  );

  Future<void> _loadMilestonesFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('rc_mstones_${widget.courseKey}') ?? '';
      if (raw.isNotEmpty) {
        _celebratedMilestones.addAll(raw.split(','));
      }
    } catch (_) {}
  }

  Future<void> _saveMilestone(String milestone) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _celebratedMilestones.add(milestone);
      await prefs.setString(
        'rc_mstones_${widget.courseKey}',
        _celebratedMilestones.join(','),
      );
    } catch (_) {}
  }

  void _celebrateIfComplete() {
    if (_totalSessions <= 0) return;

    final milestones = [25, 50, 75];
    final pct = (_progressValue * 100).round();

    if (!_celebrated &&
        _completedSessions == _totalSessions &&
        _totalSessions > 0) {
      _celebrated = true;
      _confettiController.play();
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _confettiController.play();
      });
      return;
    }

    for (final m in milestones) {
      final key = 'm$m';
      if (pct >= m && !_celebratedMilestones.contains(key)) {
        _confettiController.play();
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) _confettiController.play();
        });
        unawaited(_saveMilestone(key));
        if (mounted) {
          _notice(
            '🎉 $m% complete! Keep going!',
            tone: LearnerNoticeTone.success,
          );
        }
        break;
      }
    }
  }

  Future<void> _onModuleCertificateTap({
    required String moduleLabel,
    required List<_RecordedUnit> moduleUnits,
    required int moduleIndex,
  }) => _certHandler._onModuleCertificateTap(
    context: context,
    mounted: mounted,
    setState: setState,
    moduleLabel: moduleLabel,
    moduleUnits: moduleUnits,
    moduleIndex: moduleIndex,
  );

  Widget _buildModuleMilestoneCard({
    required String moduleLabel,
    required List<_RecordedUnit> moduleUnits,
    required int moduleIndex,
  }) => _certHandler._buildModuleMilestoneCard(
    moduleLabel: moduleLabel,
    moduleUnits: moduleUnits,
    moduleIndex: moduleIndex,
    deepOrange: _kYbsDeepOrange,
    orangeTextStrong: _kYbsOrangeTextStrong,
    deepBlue: _kYbsDeepBlue,
    onModuleCertificateTap:
        ({
          required String moduleLabel,
          required List<_RecordedUnit> moduleUnits,
          required int moduleIndex,
        }) => _onModuleCertificateTap(
          moduleLabel: moduleLabel,
          moduleUnits: moduleUnits,
          moduleIndex: moduleIndex,
        ),
  );

  void _snack(String message) {
    if (!mounted) return;
    _notice(message);
  }

  void _notice(String message, {LearnerNoticeTone? tone}) {
    if (!mounted) return;
    unawaited(
      showLearnerNoticePopup(
        context,
        message: message,
        tone: tone ?? learnerNoticeToneForMessage(message),
      ),
    );
  }

  int _countCompletedInUnit(_RecordedUnit unit) {
    int done = 0;
    for (final session in unit.sessions) {
      if (_isSessionCompleted(session)) {
        done++;
      }
    }
    return done;
  }

  String _expirySubtitle() {
    if (_expiresAt <= 0) {
      return 'Recorded access information was not found for this course.';
    } else if (_daysLeft < 0) {
      return 'Expired on ${_formatDateMs(_expiresAt)}.';
    } else if (_daysLeft == 0) {
      return 'Expires today (${_formatDateMs(_expiresAt)}).';
    } else if (_daysLeft == 1) {
      return 'Expires tomorrow (${_formatDateMs(_expiresAt)}).';
    } else {
      return 'Expires on ${_formatDateMs(_expiresAt)} • $_daysLeft days left.';
    }
  }

  Future<void> _showCourseInfoSheet() async {
    final style = _expiryStyle;
    final progressPct = (_progressValue * 100).round();
    final moduleSummaries = <Map<String, dynamic>>[];
    final byModule = <String, List<_RecordedUnit>>{};
    final moduleOrder = <String>[];
    for (final u in _units) {
      final key = u.otherTitle.trim().isNotEmpty
          ? u.otherTitle.trim()
          : 'Module';
      if (!byModule.containsKey(key)) {
        byModule[key] = <_RecordedUnit>[];
        moduleOrder.add(key);
      }
      byModule[key]!.add(u);
    }
    for (final m in moduleOrder) {
      final units = byModule[m] ?? const <_RecordedUnit>[];
      int totalLessons = 0;
      int doneLessons = 0;
      for (final u in units) {
        totalLessons += u.sessions.length;
        doneLessons += _countCompletedInUnit(u);
      }
      moduleSummaries.add({
        'name': m,
        'units': units.length,
        'done': doneLessons,
        'total': totalLessons,
      });
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.72,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            builder: (context, scrollController) {
              return SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1D5DB),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFFFFFF), Color(0xFFF2F7FF)],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFDCE6F6)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _InfoChip(
                                icon: Icons.trending_up_rounded,
                                text: '$progressPct% progress',
                              ),
                              _InfoChip(
                                icon: Icons.menu_book_rounded,
                                text:
                                    '$_completedSessions/$_totalSessions lessons',
                              ),
                              _InfoChip(
                                icon: style.icon,
                                text: style.label,
                                fg: style.fg,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _InfoTile(
                      icon: Icons.trending_up_rounded,
                      title: 'Progress',
                      value:
                          '$progressPct% ($_completedSessions/$_totalSessions)',
                    ),
                    _InfoTile(
                      icon: style.icon,
                      title: style.label,
                      value: _expirySubtitle(),
                      iconColor: style.fg,
                    ),
                    _InfoTile(
                      icon: _courseCertificateUnlocked
                          ? Icons.workspace_premium_rounded
                          : Icons.lock_outline_rounded,
                      title: 'Certificate',
                      value: _courseCertificateUnlocked
                          ? 'Unlocked'
                          : 'Locked until all modules are completed',
                      iconColor: _courseCertificateUnlocked
                          ? const Color(0xFF15803D)
                          : const Color(0xFF64748B),
                    ),
                    if (_durationMonths > 0)
                      _InfoTile(
                        icon: Icons.calendar_month_rounded,
                        title: 'Access duration',
                        value:
                            '$_durationMonths month${_durationMonths == 1 ? '' : 's'}',
                      ),
                    const SizedBox(height: 10),
                    const Text(
                      'Modules overview',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final m in moduleSummaries)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                (m['name'] ?? '').toString(),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0B3A8F),
                                ),
                              ),
                            ),
                            Text(
                              '${m['units']} units • ${m['done']}/${m['total']} lessons',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF64748B),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _courseCertificateUnlocked
                            ? _onCertificateTap
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF111827),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFE5E7EB),
                          disabledForegroundColor: const Color(0xFF9CA3AF),
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Certificate'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSessionDownloadButton({
    required _RecordedSession session,
    required bool isNarrow,
  }) {
    final request = _downloadRequestForSession(session);
    if (request == null) return const SizedBox.shrink();
    final info = _offlineVideos.infoFor(
      uid: request.uid,
      courseKey: request.courseKey,
      sessionId: request.sessionId,
    );
    final status = info?.status ?? RecordedDownloadStatus.notDownloaded;
    final progress = ((info?.progress ?? 0) * 100).round();

    IconData icon = Icons.download_rounded;
    Color color = const Color(0xFF0284C7);
    String tooltip = 'Download video & reading';
    VoidCallback? onTap = () => _downloadVideos([
      request,
    ], emptyMessage: 'No video available to download.');

    if (status == RecordedDownloadStatus.downloading ||
        status == RecordedDownloadStatus.queued) {
      icon = Icons.downloading_rounded;
      color = const Color(0xFF0EA5E9);
      tooltip = status == RecordedDownloadStatus.queued
          ? 'Download queued'
          : 'Downloading $progress%';
      onTap = null;
    } else if (status == RecordedDownloadStatus.downloaded) {
      icon = Icons.offline_pin_rounded;
      color = const Color(0xFF16A34A);
      tooltip = 'Downloaded. Tap to delete.';
      onTap = () => _deleteDownloads([request], title: 'Delete this video?');
    } else if (status == RecordedDownloadStatus.failed) {
      icon = Icons.error_outline_rounded;
      color = const Color(0xFFB91C1C);
      tooltip = 'Download failed. Tap to retry.';
    } else if (status == RecordedDownloadStatus.cancelled) {
      icon = Icons.refresh_rounded;
      color = const Color(0xFFEA580C);
      tooltip = 'Download cancelled. Tap to retry.';
    }

    return Padding(
      padding: EdgeInsets.only(left: isNarrow ? 3 : 4),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            width: isNarrow ? 28 : 30,
            height: isNarrow ? 28 : 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: status == RecordedDownloadStatus.downloading
                ? Padding(
                    padding: const EdgeInsets.all(7),
                    child: CircularProgressIndicator(
                      value: info?.bytesTotal == 0 ? null : info?.progress,
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(icon, size: isNarrow ? 16 : 17, color: color),
          ),
        ),
      ),
    );
  }

  Widget _buildScopeDownloadActions({
    required List<RecordedVideoDownloadRequest> requests,
    required String label,
    required String deleteTitle,
    bool compact = false,
  }) {
    final summary = _downloadSummaryFor(requests);
    if (summary.total <= 0) return const SizedBox.shrink();
    final isDone = summary.allDownloaded;
    final hasActive = summary.active > 0;
    final text = isDone
        ? 'Downloaded'
        : hasActive
        ? '${(summary.progress * 100).round()}%'
        : label;
    final onPressed = hasActive
        ? null
        : isDone
        ? () => _deleteDownloads(requests, title: deleteTitle)
        : () => _downloadVideos(
            requests,
            emptyMessage: 'No videos available to download.',
          );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Tooltip(
          message: text,
          child: IconButton.filledTonal(
            onPressed: onPressed,
            icon: Icon(
              isDone ? Icons.delete_outline_rounded : Icons.download_rounded,
              size: 16,
            ),
            color: isDone ? const Color(0xFF16A34A) : const Color(0xFF4F46E5),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(30),
              fixedSize: const Size.square(30),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: const Color(0xFFF8FAFC),
              disabledBackgroundColor: const Color(0xFFF8FAFC),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tight = constraints.maxWidth < 260;
        final progress = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${summary.downloaded}/${summary.total} offline',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF334155),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: summary.progress,
                minHeight: 5,
                backgroundColor: const Color(0xFFE2E8F0),
              ),
            ),
          ],
        );
        final button = TextButton.icon(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: isDone
                ? const Color(0xFF16A34A)
                : const Color(0xFF4F46E5),
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
          icon: Icon(
            isDone ? Icons.delete_outline_rounded : Icons.download_rounded,
            size: 17,
          ),
          label: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        );

        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: tight
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    progress,
                    const SizedBox(height: 6),
                    Align(alignment: Alignment.centerRight, child: button),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: progress),
                    const SizedBox(width: 8),
                    Flexible(flex: 0, child: button),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildSyncErrorBanner() {
    if (_progressSync.failedSyncCount <= 0) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: const Row(
        children: [
          Icon(Icons.cloud_off_rounded, color: Color(0xFFB91C1C), size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Some progress couldn\'t be saved yet. It will sync when possible.',
              style: TextStyle(
                color: Color(0xFF991B1B),
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineCacheBanner() {
    if (!_usingOfflineCourseCache) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: const Row(
        children: [
          Icon(Icons.cloud_off_rounded, color: Color(0xFFB45309), size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline mode: showing saved recorded lessons. Progress and notes sync when internet returns.',
              style: TextStyle(
                color: Color(0xFF92400E),
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard({
    required _RecordedSession session,
    required int flatIndex,
  }) {
    final isNarrow = MediaQuery.sizeOf(context).width < 420;
    final isWide = MediaQuery.sizeOf(context).width > 768;
    final progress = _progressOf(session.id);
    final isUnlocked = _isSessionUnlocked(flatIndex);
    final isCompleted = _isSessionCompleted(session);
    final requiresVideo = _sessionRequiresVideo(session);
    final requiresMaterials = _sessionRequiresMaterials(session);
    final canExpandDetails = session.objective.trim().isNotEmpty;
    final showDetails = _expandedLessonDetails.contains(session.id);
    final number = session.sessionNumber > 0
        ? session.sessionNumber
        : (flatIndex + 1);

    final isNextIncomplete = flatIndex == _nextIncompleteFlatIndex();

    Color dotColor = const Color(0xFF94A3B8);
    if (isCompleted) {
      dotColor = const Color(0xFF16A34A);
    } else if (isUnlocked) {
      dotColor = const Color(0xFF4F46E5);
    }

    Widget card = Container(
      margin: EdgeInsets.only(top: isNarrow ? 6 : 7),
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow
            ? 9
            : isWide
            ? 20
            : 10,
        vertical: isNarrow
            ? 8
            : isWide
            ? 16
            : 9,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCompleted
              ? const Color(0xFFBBF7D0)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: isNarrow
                    ? 20
                    : isWide
                    ? 32
                    : 22,
                height: isNarrow
                    ? 20
                    : isWide
                    ? 32
                    : 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor.withValues(alpha: 0.12),
                  border: Border.all(color: dotColor, width: 1.2),
                ),
                child: Text(
                  '$number',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: dotColor,
                    fontSize: isNarrow
                        ? 9.5
                        : isWide
                        ? 14
                        : 10,
                  ),
                ),
              ),
              SizedBox(
                width: isNarrow
                    ? 7
                    : isWide
                    ? 12
                    : 8,
              ),
              Expanded(
                child: Text(
                  session.title.trim().isEmpty
                      ? 'Untitled lesson'
                      : session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w800,
                    fontSize: isNarrow
                        ? 12.5
                        : isWide
                        ? 18
                        : 13,
                  ),
                ),
              ),
              if (canExpandDetails)
                Tooltip(
                  message: showDetails ? 'Hide details' : 'Show details',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      setState(() {
                        if (showDetails) {
                          _expandedLessonDetails.remove(session.id);
                        } else {
                          _expandedLessonDetails.add(session.id);
                        }
                      });
                    },
                    child: Container(
                      width: isNarrow
                          ? 22
                          : isWide
                          ? 34
                          : 24,
                      height: isNarrow
                          ? 22
                          : isWide
                          ? 34
                          : 24,
                      alignment: Alignment.center,
                      child: Text(
                        '!',
                        style: TextStyle(
                          color: Color(0xFF334155),
                          fontWeight: FontWeight.w900,
                          fontSize: isWide ? 20 : 14,
                        ),
                      ),
                    ),
                  ),
                ),
              if (requiresVideo)
                Padding(
                  padding: EdgeInsets.only(left: isNarrow ? 3 : 4),
                  child: Tooltip(
                    message: _openingVideoSessionId == session.id
                        ? 'Opening…'
                        : progress.videoCompleted
                        ? 'Rewatch video'
                        : 'Watch video',
                    child: TextButton.icon(
                      onPressed: isUnlocked && _openingVideoSessionId == null
                          ? () => _openVideoPlaceholder(session)
                          : null,
                      icon: Icon(
                        Icons.play_arrow_rounded,
                        size: isNarrow
                            ? 16
                            : isWide
                            ? 22
                            : 18,
                      ),
                      label: Text(
                        _openingVideoSessionId == session.id
                            ? 'Opening…'
                            : 'Watch',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: isNarrow
                              ? 12
                              : isWide
                              ? 16
                              : 13,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: isNarrow
                              ? 8
                              : isWide
                              ? 18
                              : 10,
                          vertical: isWide ? 10 : 4,
                        ),
                        foregroundColor: isUnlocked
                            ? const Color(0xFF4F46E5)
                            : const Color(0xFF94A3B8),
                        backgroundColor: isUnlocked
                            ? const Color(0xFFEEF2FF)
                            : const Color(0xFFF1F5F9),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ),
              if (requiresMaterials)
                Padding(
                  padding: EdgeInsets.only(left: isNarrow ? 3 : 4),
                  child: Tooltip(
                    message: _openingMaterialsSessionId == session.id
                        ? 'Opening…'
                        : progress.materialsCompleted
                        ? 'Open reading again'
                        : 'Open reading',
                    child: TextButton.icon(
                      onPressed:
                          isUnlocked && _openingMaterialsSessionId == null
                          ? () => _openMaterials(session)
                          : null,
                      icon: Icon(
                        Icons.menu_book_rounded,
                        size: isNarrow
                            ? 16
                            : isWide
                            ? 22
                            : 18,
                      ),
                      label: Text(
                        _openingMaterialsSessionId == session.id
                            ? 'Opening…'
                            : 'Read',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: isNarrow
                              ? 12
                              : isWide
                              ? 16
                              : 13,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: isNarrow
                              ? 8
                              : isWide
                              ? 18
                              : 10,
                          vertical: isWide ? 10 : 4,
                        ),
                        foregroundColor: isUnlocked
                            ? const Color(0xFFEA580C)
                            : const Color(0xFF94A3B8),
                        backgroundColor: isUnlocked
                            ? const Color(0xFFFFF7ED)
                            : const Color(0xFFF1F5F9),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ),
              if (!kIsWeb && (requiresVideo || requiresMaterials))
                _buildSessionDownloadButton(
                  session: session,
                  isNarrow: isNarrow,
                ),
            ],
          ),
          if (!isUnlocked)
            Padding(
              padding: EdgeInsets.only(top: isWide ? 10 : 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Locked: finish the previous lesson first.',
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    fontSize: isWide ? 15 : 11.4,
                  ),
                ),
              ),
            ),
          if (isUnlocked && !isCompleted) ...[
            if (requiresVideo && !progress.videoCompleted)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    height: isWide ? 36 : 26,
                    child: OutlinedButton.icon(
                      onPressed: () => _markVideoCompletedManually(session),
                      icon: const Icon(Icons.check_circle_outline, size: 14),
                      label: const Text(
                        'Mark video done',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        foregroundColor: const Color(0xFF4F46E5),
                        side: const BorderSide(color: Color(0xFFC7D2FE)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (requiresMaterials && !progress.materialsCompleted)
              Padding(
                padding: EdgeInsets.only(
                  top: requiresVideo && !progress.videoCompleted ? 4 : 6,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    height: isWide ? 36 : 26,
                    child: OutlinedButton.icon(
                      onPressed: () => _markMaterialsCompleted(session),
                      icon: const Icon(Icons.check_circle_outline, size: 14),
                      label: const Text(
                        'Mark reading done',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        foregroundColor: const Color(0xFFEA580C),
                        side: const BorderSide(color: Color(0xFFFED7AA)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
          if (showDetails && canExpandDetails)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  session.objective.trim(),
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    height: 1.25,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (isNextIncomplete) {
      card = _PulseWidget(child: card);
    }

    return card;
  }

  Widget _buildUnitsList() {
    final isNarrow = MediaQuery.sizeOf(context).width < 420;
    if (_units.isEmpty) {
      return const SizedBox(
        width: double.infinity,
        child: Card(
          elevation: 0,
          color: Colors.white,
          surfaceTintColor: Colors.white,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No recorded syllabus has been added for this course yet.',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF334155),
              ),
            ),
          ),
        ),
      );
    }

    final moduleEntries = _unitsByModule.entries.toList();

    return Column(
      children: [
        for (
          int moduleIndex = 0;
          moduleIndex < moduleEntries.length;
          moduleIndex++
        )
          Builder(
            builder: (_) {
              final moduleLabel = moduleEntries[moduleIndex].key;
              final moduleUnits = moduleEntries[moduleIndex].value;
              bool isModuleIndexLocked(int idx) {
                if (idx <= 0) return false;
                for (int k = 0; k < idx; k++) {
                  if (!_isModuleCompleted(moduleEntries[k].value)) return true;
                }
                return false;
              }

              final moduleLocked = isModuleIndexLocked(moduleIndex);
              final moduleExpanded = _expandedModuleLabels.contains(
                moduleLabel,
              );
              final doneUnits = _moduleCompletedUnits(moduleUnits);
              final totalUnits = moduleUnits.length;
              final doneLessons = _moduleCompletedSessions(moduleUnits);
              final totalLessons = _moduleTotalSessions(moduleUnits);
              final selectedUnitId =
                  _selectedUnitByModule[moduleLabel] ??
                  _unitIdOf(moduleUnits.first);
              final selectedUnit = moduleUnits.firstWhere(
                (u) => _unitIdOf(u) == selectedUnitId,
                orElse: () => moduleUnits.first,
              );
              final selectedUnitIdSafe = _unitIdOf(selectedUnit);
              final showUnitDetails = _expandedUnitDetails.contains(
                selectedUnitIdSafe,
              );

              return Container(
                width: double.infinity,
                margin: EdgeInsets.only(
                  top: moduleIndex == 0 ? 0 : (isNarrow ? 8 : 10),
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(isNarrow ? 14 : 16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(isNarrow ? 14 : 16),
                      onTap: () {
                        setState(() {
                          if (moduleExpanded) {
                            _expandedModuleLabels.remove(moduleLabel);
                          } else {
                            _expandedModuleLabels.add(moduleLabel);
                          }
                        });
                      },
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          isNarrow ? 10 : 12,
                          isNarrow ? 9 : 11,
                          isNarrow ? 10 : 12,
                          isNarrow ? 9 : 11,
                        ),
                        child: Row(
                          children: [
                            if (moduleLocked)
                              Padding(
                                padding: EdgeInsets.only(
                                  right: isNarrow ? 5 : 6,
                                ),
                                child: Icon(
                                  Icons.lock_rounded,
                                  size: isNarrow ? 14 : 15,
                                  color: const Color(0xFF94A3B8),
                                ),
                              ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    moduleLabel,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: moduleLocked
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF0F172A),
                                      fontWeight: FontWeight.w900,
                                      fontSize: isNarrow ? 14 : 14.5,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '$doneUnits/$totalUnits units • $doneLessons/$totalLessons lessons',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: moduleLocked
                                          ? const Color(0xFF94A3B8)
                                          : const Color(0xFF64748B),
                                      fontWeight: FontWeight.w700,
                                      fontSize: isNarrow ? 11.2 : 11.8,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!kIsWeb)
                              _buildScopeDownloadActions(
                                requests: _downloadRequestsForModule(
                                  moduleUnits,
                                ),
                                label: 'Module',
                                deleteTitle: 'Delete module downloads?',
                                compact: true,
                              ),
                            const SizedBox(width: 6),
                            Container(
                              width: isNarrow ? 24 : 26,
                              height: isNarrow ? 24 : 26,
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF7ED),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Icon(
                                moduleExpanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                color: const Color(0xFFEA580C),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (moduleExpanded)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          isNarrow ? 10 : 12,
                          0,
                          isNarrow ? 10 : 12,
                          isNarrow ? 10 : 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(height: isNarrow ? 3 : 4),
                            SizedBox(
                              height: isNarrow ? 40 : 44,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: moduleUnits.length,
                                separatorBuilder: (_, _) =>
                                    SizedBox(width: isNarrow ? 6 : 8),
                                itemBuilder: (_, i) {
                                  final unit = moduleUnits[i];
                                  final unitId = _unitIdOf(unit);
                                  final isSelected =
                                      unitId == selectedUnitIdSafe;
                                  final unitDone = _isUnitCompleted(unit);
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      setState(() {
                                        _selectedUnitByModule[moduleLabel] =
                                            unitId;
                                      });
                                    },
                                    child: Container(
                                      constraints: BoxConstraints(
                                        minWidth: isNarrow ? 104 : 120,
                                        maxWidth: isNarrow ? 180 : 220,
                                      ),
                                      padding: EdgeInsets.symmetric(
                                        horizontal: isNarrow ? 8 : 10,
                                        vertical: isNarrow ? 7 : 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? const Color(0xFFEEF2FF)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isSelected
                                              ? const Color(0xFF4F46E5)
                                              : const Color(0xFFE2E8F0),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            unitDone
                                                ? Icons.check_circle_rounded
                                                : Icons
                                                      .radio_button_unchecked_rounded,
                                            size: 15,
                                            color: unitDone
                                                ? const Color(0xFF16A34A)
                                                : const Color(0xFF64748B),
                                          ),
                                          SizedBox(width: isNarrow ? 5 : 6),
                                          Flexible(
                                            child: Text(
                                              unit.title.trim().isEmpty
                                                  ? 'Unit ${i + 1}'
                                                  : unit.title.trim(),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: const Color(0xFF1E293B),
                                                fontWeight: isSelected
                                                    ? FontWeight.w900
                                                    : FontWeight.w700,
                                                fontSize: isNarrow ? 11.5 : 12,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            SizedBox(height: isNarrow ? 6 : 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    selectedUnit.title.trim().isEmpty
                                        ? selectedUnit.displayTitle
                                        : selectedUnit.title.trim(),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Color(0xFF0F172A),
                                      fontWeight: FontWeight.w900,
                                      fontSize: isNarrow ? 13 : 13.5,
                                    ),
                                  ),
                                ),
                                if (selectedUnit.description.trim().isNotEmpty)
                                  Tooltip(
                                    message: showUnitDetails
                                        ? 'Hide unit details'
                                        : 'Show unit details',
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: () {
                                        setState(() {
                                          if (showUnitDetails) {
                                            _expandedUnitDetails.remove(
                                              selectedUnitIdSafe,
                                            );
                                          } else {
                                            _expandedUnitDetails.add(
                                              selectedUnitIdSafe,
                                            );
                                          }
                                        });
                                      },
                                      child: Container(
                                        width: isNarrow ? 24 : 26,
                                        height: isNarrow ? 24 : 26,
                                        alignment: Alignment.center,
                                        child: const Text(
                                          '!',
                                          style: TextStyle(
                                            color: Color(0xFF334155),
                                            fontWeight: FontWeight.w900,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            if (showUnitDetails &&
                                selectedUnit.description.trim().isNotEmpty)
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(top: 5),
                                padding: EdgeInsets.all(isNarrow ? 9 : 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: Text(
                                  selectedUnit.description.trim(),
                                  style: TextStyle(
                                    color: Color(0xFF475569),
                                    fontWeight: FontWeight.w600,
                                    fontSize: isNarrow ? 11.6 : 12,
                                    height: 1.25,
                                  ),
                                ),
                              ),
                            if (!kIsWeb)
                              _buildScopeDownloadActions(
                                requests: _downloadRequestsForUnit(
                                  selectedUnit,
                                ),
                                label: 'Download unit',
                                deleteTitle: 'Delete unit downloads?',
                              ),
                            const SizedBox(height: 2),
                            for (
                              int i = 0;
                              i < selectedUnit.sessions.length;
                              i++
                            )
                              _buildSessionCard(
                                session: selectedUnit.sessions[i],
                                flatIndex: _flatIndexOfSessionId(
                                  selectedUnit.sessions[i].id,
                                ),
                              ),
                            _buildModuleMilestoneCard(
                              moduleLabel: moduleLabel,
                              moduleUnits: moduleUnits,
                              moduleIndex: moduleIndex,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Future<void> _openReviewSheet() async {
    if (_uid.trim().isEmpty) return;
    final courseId = _courseId.trim().isEmpty ? widget.courseKey : _courseId;
    final enrolled = await CourseFeedbackService.isUserEnrolledInCourse(
      _uid,
      courseId,
    );
    if (!mounted) return;
    if (!enrolled) {
      _notice(
        'Only enrolled learners can add a review.',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }

    DataSnapshot existing;
    try {
      existing = await FirebaseDatabase.instance
          .ref('course_reviews/$courseId/$_uid')
          .get();
    } catch (e) {
      if (!mounted) return;
      _notice(humanizeUiMessage(e.toString()), tone: LearnerNoticeTone.error);
      return;
    }
    if (!mounted) return;

    int rating = 5;
    String comment = '';
    if (existing.exists && existing.value is Map) {
      final map = Map<String, dynamic>.from(existing.value as Map);
      final parsedRating = CourseFeedbackService.asInt(map['rating']);
      if (parsedRating >= 1 && parsedRating <= 5) rating = parsedRating;
      comment = (map['comment'] ?? '').toString();
    }

    final commentC = TextEditingController(text: comment);
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setD) {
            final media = MediaQuery.of(ctx);
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                media.viewInsets.bottom + media.padding.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Rate this recorded course',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    children: List.generate(5, (i) {
                      final v = i + 1;
                      return IconButton(
                        onPressed: () => setD(() => rating = v),
                        icon: Icon(
                          v <= rating
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: const Color(0xFFF59E0B),
                        ),
                      );
                    }),
                  ),
                  TextField(
                    controller: commentC,
                    maxLength: 500,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Comment',
                      hintText: 'Share your feedback to help others enroll.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        if (commentC.text.trim().isEmpty) {
                          unawaited(
                            showLearnerNoticePopup(
                              ctx,
                              message:
                                  'Please add a comment before submitting.',
                              tone: LearnerNoticeTone.warning,
                            ),
                          );
                          return;
                        }
                        Navigator.pop(ctx, true);
                      },
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Submit review'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (submitted != true || !mounted) return;
    try {
      await CourseFeedbackService.upsertCourseReview(
        courseId: courseId,
        uid: _uid,
        rating: rating,
        comment: commentC.text,
      );
      if (!mounted) return;
      _notice(
        'Your review was submitted for approval.',
        tone: LearnerNoticeTone.success,
      );
    } catch (e) {
      if (!mounted) return;
      _notice(humanizeUiMessage(e.toString()), tone: LearnerNoticeTone.error);
    }
  }

  PopupMenuButton<String> _buildMenuButton() {
    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (value) async {
        if (value == 'refresh') {
          await _loadAll();
        } else if (value == 'info') {
          await _showCourseInfoSheet();
        } else if (value == 'downloads' && !kIsWeb) {
          await _showDownloadsSheet();
        } else if (value == 'certificate') {
          if (_courseCertificateUnlocked) {
            _onCertificateTap();
          } else {
            _snack('Complete all modules to unlock your certificate.');
          }
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem<String>(
          value: 'info',
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 18),
              SizedBox(width: 10),
              Text('Course info'),
            ],
          ),
        ),
        if (!kIsWeb)
          PopupMenuItem<String>(
            value: 'downloads',
            child: Row(
              children: [
                Icon(Icons.offline_pin_rounded, size: 18),
                SizedBox(width: 10),
                Text('Offline videos'),
              ],
            ),
          ),
        PopupMenuItem<String>(
          value: 'refresh',
          child: Row(
            children: [
              Icon(Icons.refresh_rounded, size: 18),
              SizedBox(width: 10),
              Text('Refresh'),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'certificate',
          child: Row(
            children: [
              Icon(Icons.workspace_premium_rounded, size: 18),
              SizedBox(width: 10),
              Text('Certificate'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget content;
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

    if (_busy) {
      content = const Center(
        child: BrandedInlineLoader(message: 'Loading course...'),
      );
    } else if (_error != null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFFECACA)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFB91C1C),
                    size: 23,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Could not open this recorded course',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF991B1B),
                    fontWeight: FontWeight.w900,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'If this issue continues, please contact Your Bridge School support and share your course title + session number.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.2,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _loadAll,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Try again'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0F172A),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      final isNarrow = MediaQuery.sizeOf(context).width < 420;
      content = RefreshIndicator(
        onRefresh: _loadAll,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8, right: 8),
                    child: Opacity(
                      opacity: 0.045,
                      child: Image.asset(
                        'assets/images/ybs_logo.png',
                        width: 180,
                        height: 180,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            desktopWorkspace
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.showOverviewCard)
                        SizedBox(
                          width: 360,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(12, 10, 8, 18),
                            children: [
                              _buildTopOverviewCard(),
                              const SizedBox(height: 10),
                              if (!kIsWeb) _buildOfflineOverviewCard(),
                            ],
                          ),
                        ),
                      Expanded(
                        child: ListView(
                          padding: EdgeInsets.fromLTRB(
                            widget.showOverviewCard ? 8 : 12,
                            10,
                            12,
                            18,
                          ),
                          children: [
                            _buildSyncErrorBanner(),
                            _buildOfflineCacheBanner(),
                            _buildCompletionBanner(),
                            RepaintBoundary(child: _buildUnitsList()),
                          ],
                        ),
                      ),
                    ],
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      isNarrow ? 10 : 12,
                      isNarrow ? 8 : 10,
                      isNarrow ? 10 : 12,
                      isNarrow ? 16 : 18,
                    ),
                    children: [
                      if (widget.showOverviewCard) ...[
                        _buildTopOverviewCard(),
                        const SizedBox(height: 10),
                        if (!kIsWeb) _buildOfflineOverviewCard(),
                        const SizedBox(height: 10),
                      ],
                      _buildSyncErrorBanner(),
                      _buildOfflineCacheBanner(),
                      _buildCompletionBanner(),
                      RepaintBoundary(child: _buildUnitsList()),
                    ],
                  ),
          ],
        ),
      );
    }

    final Widget wrappedContent = ConfettiWidget(
      confettiController: _confettiController,
      blastDirectionality: BlastDirectionality.explosive,
      numberOfParticles: 60,
      emissionFrequency: 0.08,
      maxBlastForce: 40,
      minBlastForce: 15,
      colors: const [
        Color(0xFF22C55E),
        Color(0xFF3B82F6),
        Color(0xFFF59E0B),
        Color(0xFFEC4899),
        Color(0xFF8B5CF6),
        Color(0xFFEF4444),
        Color(0xFF14B8A6),
        Color(0xFFF97316),
      ],
      child: content,
    );

    if (widget.embedded) {
      return wrappedContent;
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF2F6FB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            Flexible(
              child: Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.w900,
                  fontSize: 17,
                ),
              ),
            ),
            if (_usingOfflineCourseCache) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.cloud_off_rounded,
                  size: 16,
                  color: Color(0xFF92400E),
                ),
              ),
            ],
          ],
        ),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        actions: [
          IconButton(
            tooltip: 'Review course',
            onPressed: _busy ? null : _openReviewSheet,
            icon: const Icon(Icons.reviews_rounded),
          ),
          _buildMenuButton(),
        ],
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1460,
        fullWidth: true,
        child: Stack(
          children: [
            Positioned(
              top: -110,
              right: -95,
              child: IgnorePointer(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF4F46E5).withValues(alpha: 0.06),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -120,
              left: -90,
              child: IgnorePointer(
                child: Container(
                  width: 230,
                  height: 230,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0EA5E9).withValues(alpha: 0.06),
                  ),
                ),
              ),
            ),
            Positioned.fill(child: wrappedContent),
          ],
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String value;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor ?? const Color(0xFF4F46E5)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: Color(0xFF0F172A),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text, this.fg});

  final IconData icon;
  final String text;
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    final color = fg ?? const Color(0xFF334155);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFD9E2EE)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _MilestoneConfetti extends StatefulWidget {
  const _MilestoneConfetti();

  @override
  State<_MilestoneConfetti> createState() => _MilestoneConfettiState();
}

class _MilestoneConfettiState extends State<_MilestoneConfetti>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const List<_ConfettiPiece> _pieces = [
    _ConfettiPiece(x: 0.05, size: 7, phase: 0.0, color: _kYbsDeepOrange),
    _ConfettiPiece(x: 0.12, size: 6, phase: 0.7, color: _kYbsDeepBlue),
    _ConfettiPiece(x: 0.19, size: 8, phase: 1.1, color: Color(0xFFF59E0B)),
    _ConfettiPiece(x: 0.28, size: 6, phase: 1.7, color: Color(0xFF1D4ED8)),
    _ConfettiPiece(x: 0.36, size: 7, phase: 2.2, color: _kYbsDeepOrange),
    _ConfettiPiece(x: 0.46, size: 8, phase: 2.9, color: _kYbsDeepBlue),
    _ConfettiPiece(x: 0.57, size: 6, phase: 3.4, color: Color(0xFFF59E0B)),
    _ConfettiPiece(x: 0.67, size: 7, phase: 3.9, color: _kYbsDeepOrange),
    _ConfettiPiece(x: 0.77, size: 6, phase: 4.5, color: Color(0xFF1D4ED8)),
    _ConfettiPiece(x: 0.87, size: 8, phase: 5.2, color: Color(0xFFF59E0B)),
    _ConfettiPiece(x: 0.94, size: 6, phase: 5.8, color: _kYbsDeepBlue),
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, child) {
            final t = _controller.value;
            return LayoutBuilder(
              builder: (context, c) {
                return Stack(
                  children: [
                    for (final p in _pieces)
                      Positioned(
                        left: c.maxWidth * p.x,
                        top: 2 + (math.sin((t * 8) + p.phase) * 8) + (t * 30),
                        child: Transform.rotate(
                          angle: (t * 6.2831) + p.phase,
                          child: Container(
                            width: p.size,
                            height: p.size,
                            decoration: BoxDecoration(
                              color: p.color.withValues(alpha: 0.90),
                              borderRadius: BorderRadius.circular(1.4),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ConfettiPiece {
  const _ConfettiPiece({
    required this.x,
    required this.size,
    required this.phase,
    required this.color,
  });

  final double x;
  final double size;
  final double phase;
  final Color color;
}

class _PulseWidget extends StatefulWidget {
  const _PulseWidget({required this.child});

  final Widget child;

  @override
  State<_PulseWidget> createState() => _PulseWidgetState();
}

class _PulseWidgetState extends State<_PulseWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<Color?> _borderAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _scaleAnim = Tween<double>(
      begin: 1.0,
      end: 1.06,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _borderAnim = ColorTween(
      begin: const Color(0xFFE2E8F0),
      end: const Color(0xFF4F46E5),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) => Transform.scale(
        scale: _scaleAnim.value,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _borderAnim.value ?? const Color(0xFFE2E8F0),
              width: 1.5,
            ),
          ),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
