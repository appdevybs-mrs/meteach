import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../models/certificate_model.dart';
import '../services/certificate_pdf_service.dart';
import '../services/certificate_service.dart';
import '../services/course_feedback_service.dart';
import '../services/storage_existence.dart';
import '../shared/app_feedback.dart';
import '../shared/offline_action_guard.dart';
import '../shared/human_error.dart';
import '../shared/material_webview_screen.dart';
import '../shared/learner_web_layout.dart';
import '../shared/responsive_layout.dart';
import 'recorded_video_player_screen.dart';

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
  });

  final String courseKey;
  final Map<String, dynamic> courseData;

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
  final CertificateService _certificateService = CertificateService();
  final CertificatePdfService _certificatePdfService = CertificatePdfService();

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

  final Set<String> _expandedModuleLabels = <String>{};
  final Map<String, String> _selectedUnitByModule = <String, String>{};
  final Set<String> _expandedUnitDetails = <String>{};
  final Set<String> _expandedLessonDetails = <String>{};
  final Set<String> _generatingModuleCertificateKeys = <String>{};
  final Map<String, String> _teacherNameByUidCache = <String, String>{};
  final Map<String, StorageCheckResult> _storageCheckCacheByUrl =
      <String, StorageCheckResult>{};

  @override
  void initState() {
    super.initState();
    _loadAll();
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

      final results = await Future.wait<dynamic>([
        _recordedAccessRef.get(),
        _recordedProgressRef.get(),
        _paymentSummaryRef.get(),
        _syllabiRef.child(_courseId).child('recorded').get(),
      ]);

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

      final Map<String, _RecordedProgress> progressById =
          <String, _RecordedProgress>{};
      if (progressSnap.value is Map) {
        final rawMap = Map<String, dynamic>.from(progressSnap.value as Map);
        for (final entry in rawMap.entries) {
          if (entry.value is! Map) continue;
          progressById[entry.key] = _RecordedProgress.fromMap(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }

      final List<_RecordedUnit> units = <_RecordedUnit>[];
      if (syllabusSnap.value is Map) {
        final root = Map<String, dynamic>.from(syllabusSnap.value as Map);
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
              final unit = _RecordedUnit.fromMap({
                ...u,
                'otherTitle': moduleLabel,
                'sessions': u['lessons'],
                'order': (moduleOrder * 1000) + unitOrder,
              });
              units.add(unit);
            }
          }
        } else {
          final rawUnits = _asListOfMaps(root['units']);
          for (final u in rawUnits) {
            final unit = _RecordedUnit.fromMap(u);
            units.add(unit);
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

      if (!mounted) return;
      setState(() {
        _expiresAt = expiresAt;
        _durationMonths = durationMonths;
        _progressBySessionId
          ..clear()
          ..addAll(progressById);
        _units = units;
        _ensureExpandedModules();
        _ensureSelectedUnits();
        _busy = false;
      });
      _debug(
        'loadAll success units=${_units.length} totalSessions=$_totalSessions '
        'completed=$_completedSessions expiresAt=$_expiresAt',
      );
    } catch (e) {
      _debug('loadAll error=$e');
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  void _ensureExpandedModules() {
    final labels = <String>[];
    for (final u in _units) {
      final label = u.otherTitle.trim().isNotEmpty
          ? u.otherTitle.trim()
          : 'Module';
      if (!labels.contains(label)) labels.add(label);
    }
    if (labels.isEmpty) return;
    if (_expandedModuleLabels.isEmpty) {
      _expandedModuleLabels.add(labels.first);
    }
    _expandedModuleLabels.removeWhere((label) => !labels.contains(label));
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

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
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

  _RecordedProgress _progressOf(String sessionId) {
    return _progressBySessionId[sessionId] ?? const _RecordedProgress();
  }

  bool _sessionRequiresVideo(_RecordedSession session) {
    return session.videoUrl.trim().isNotEmpty;
  }

  bool _sessionRequiresMaterials(_RecordedSession session) {
    return session.materialsUrl.trim().isNotEmpty;
  }

  bool _isSessionCompleted(_RecordedSession session) {
    final p = _progressOf(session.id);

    final requiresVideo = _sessionRequiresVideo(session);
    final requiresMaterials = _sessionRequiresMaterials(session);

    if (!requiresVideo && !requiresMaterials) return false;

    if (requiresVideo && requiresMaterials) {
      return p.videoCompleted || p.materialsCompleted;
    }

    if (requiresVideo) return p.videoCompleted;
    if (requiresMaterials) return p.materialsCompleted;

    return false;
  }

  bool _isSessionUnlocked(int flatIndex) {
    if (flatIndex <= 0) return true;
    final previous = _flatSessions[flatIndex - 1].session;
    return _isSessionCompleted(previous);
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
    final current = _progressOf(session.id);
    final updated = current.copyWith(
      materialsCompleted: true,
      materialsCompletedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final completed = _resolveCompleted(session, updated);

    await _recordedProgressRef.child(session.id).update({
      'videoCompleted': updated.videoCompleted,
      'materialsCompleted': updated.materialsCompleted,
      'videoCompletedAt': updated.videoCompletedAt,
      'materialsCompletedAt': updated.materialsCompletedAt,
      'completed': completed,
      'updatedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    setState(() {
      _progressBySessionId[session.id] = updated.copyWith(completed: completed);
    });
    _debug(
      'markMaterialsCompleted done sessionId=${session.id} completed=$completed',
    );
  }

  bool _resolveCompleted(_RecordedSession session, _RecordedProgress progress) {
    final requiresVideo = _sessionRequiresVideo(session);
    final requiresMaterials = _sessionRequiresMaterials(session);

    if (!requiresVideo && !requiresMaterials) return false;

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
              title: session.title.isEmpty ? 'Session Reading' : session.title,
              url: url,
            ),
          ),
        );
      },
    );

    if (!mounted) return;

    final bool? finished = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Finished this reading?'),
        content: const Text(
          'Mark this only if you completed the reading content.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('✓ Mark complete'),
          ),
        ],
      ),
    );

    if (finished == true) {
      await _markMaterialsCompleted(session);
      if (!mounted) return;
      _snack('Great work! Session completed ✅');
    }
  }

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
                      minimumSize: Size(0, isNarrow ? 32 : 34),
                      padding: EdgeInsets.symmetric(
                        horizontal: isNarrow ? 8 : 10,
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
    final unitNodes = _units;
    final lessonNodes = _flatSessions.map((e) => e.session).toList();
    final lessonSplitIndex = (lessonNodes.length / 2).ceil();
    final lessonTopRow = lessonNodes.take(lessonSplitIndex).toList();
    final lessonBottomRow = lessonNodes.skip(lessonSplitIndex).toList();

    Widget buildNode({
      required bool done,
      required double size,
      required Color doneColor,
    }) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: done ? doneColor : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: done ? doneColor : const Color(0xFF94A3B8),
            width: done ? 1.5 : 1.2,
          ),
        ),
      );
    }

    Widget buildDotRow(List<Widget> dots) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: dots),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            minHeight: 5,
            value: _progressValue.clamp(0, 1),
            backgroundColor: const Color(0xFFE2E8F0),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF4F46E5)),
          ),
        ),
        const SizedBox(height: 8),
        buildDotRow([
          for (final units in moduleGroups) ...[
            buildNode(
              done:
                  _moduleCompletedUnits(units) == units.length &&
                  units.isNotEmpty,
              size: 12,
              doneColor: const Color(0xFFEA580C),
            ),
            const SizedBox(width: 5),
          ],
        ]),
        const SizedBox(height: 6),
        buildDotRow([
          for (final unit in unitNodes) ...[
            buildNode(
              done: _isUnitCompleted(unit),
              size: 9,
              doneColor: const Color(0xFF0EA5E9),
            ),
            const SizedBox(width: 4),
          ],
        ]),
        const SizedBox(height: 6),
        buildDotRow([
          for (final session in lessonTopRow) ...[
            buildNode(
              done: _isSessionCompleted(session),
              size: 6,
              doneColor: const Color(0xFF16A34A),
            ),
            const SizedBox(width: 3),
          ],
        ]),
        const SizedBox(height: 4),
        buildDotRow([
          for (final session in lessonBottomRow) ...[
            buildNode(
              done: _isSessionCompleted(session),
              size: 6,
              doneColor: const Color(0xFF16A34A),
            ),
            const SizedBox(width: 3),
          ],
        ]),
      ],
    );
  }

  Future<void> _openVideoPlaceholder(_RecordedSession session) async {
    final openTimer = Stopwatch()..start();
    final hasVideo = session.videoUrl.trim().isNotEmpty;
    final videoUrl = session.videoUrl.trim();
    _debug('openVideo sessionId=${session.id} hasVideo=$hasVideo');
    if (!hasVideo || !_isValidWebUrl(videoUrl)) {
      _snack(
        _lessonUnavailableMessage(lessonType: 'Video lesson', session: session),
      );
      return;
    }

    _debug('openVideo routePushStart sessionId=${session.id}');
    if (!mounted) return;

    await OfflineActionGuard.runExclusive(
      context,
      'learner.recorded.video.${widget.courseKey}.${session.id}',
      () async {
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
            ),
          ),
        );
      },
    );
    _debug(
      'openVideo routeReturned sessionId=${session.id} elapsedMs=${openTimer.elapsedMilliseconds}',
    );

    if (!mounted) return;
    await _loadAll();
  }

  Future<Map<String, String>> _learnerIdentity() async {
    final out = <String, String>{'fullName': 'Learner', 'nationalIdNumber': ''};
    final snap = await _usersRef.child(_uid).get();
    if (!snap.exists || snap.value is! Map) return out;
    final m = Map<String, dynamic>.from(snap.value as Map);
    final first = (m['first_name'] ?? '').toString().trim();
    final last = (m['last_name'] ?? '').toString().trim();
    final full = '$first $last'.trim();
    final nationalId = (m['national_id_number'] ?? m['nationalIdNumber'] ?? '')
        .toString();
    if (full.isNotEmpty) out['fullName'] = full;
    out['nationalIdNumber'] = nationalId.trim();
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
    try {
      if (_courseId.isNotEmpty) {
        final byCourseId = await _coursesRef.child(_courseId).get();
        if (byCourseId.exists && byCourseId.value is Map) {
          final names = await _instructorNamesFromCourseMap(
            Map<String, dynamic>.from(byCourseId.value as Map),
          );
          final joined = _joinedInstructorNames(names);
          if (joined.isNotEmpty) return joined;
        }
      }

      if (widget.courseKey.trim().isNotEmpty) {
        final byCourseKey = await _coursesRef.child(widget.courseKey).get();
        if (byCourseKey.exists && byCourseKey.value is Map) {
          final names = await _instructorNamesFromCourseMap(
            Map<String, dynamic>.from(byCourseKey.value as Map),
          );
          final joined = _joinedInstructorNames(names);
          if (joined.isNotEmpty) return joined;
        }
      }
    } catch (_) {}

    try {
      final localNames = await _instructorNamesFromCourseMap(widget.courseData);
      final joined = _joinedInstructorNames(localNames);
      if (joined.isNotEmpty) return joined;
    } catch (_) {}

    return 'Seddik. B';
  }

  int _sessionCompletionAt(_RecordedProgress p) {
    return math.max(p.videoCompletedAt, p.materialsCompletedAt);
  }

  String _courseCompletionDate() {
    int latest = 0;
    for (final ref in _flatSessions) {
      if (!_isSessionCompleted(ref.session)) continue;
      final p = _progressOf(ref.session.id);
      latest = math.max(latest, _sessionCompletionAt(p));
    }
    if (latest <= 0) return _fmtYmd(DateTime.now());
    return _fmtYmd(DateTime.fromMillisecondsSinceEpoch(latest));
  }

  String _moduleCompletionDate(List<_RecordedUnit> moduleUnits) {
    int latest = 0;
    for (final unit in moduleUnits) {
      for (final session in unit.sessions) {
        if (!_isSessionCompleted(session)) continue;
        final p = _progressOf(session.id);
        latest = math.max(latest, _sessionCompletionAt(p));
      }
    }
    if (latest <= 0) return _fmtYmd(DateTime.now());
    return _fmtYmd(DateTime.fromMillisecondsSinceEpoch(latest));
  }

  Future<Certificate> _issueRecordedCertificate({
    required String certId,
    required String certificateTitle,
    required String trainingDate,
    required String kind,
    String? moduleKey,
  }) async {
    final identity = await _learnerIdentity();
    final fullName = (identity['fullName'] ?? 'Learner').trim();
    final nationalId = (identity['nationalIdNumber'] ?? '').trim();
    final instructorName = await _resolveInstructorName();
    if (nationalId.length < 4) {
      throw Exception(
        'National ID is missing. Ask admin to add your National ID in your learner profile before issuing certificates.',
      );
    }

    return _certificateService.issueRecordedCertificate(
      learnerUid: _uid,
      certId: certId,
      fullName: fullName,
      nationalIdNumber: nationalId,
      certificateTitle: certificateTitle,
      trainingDate: trainingDate,
      expirationDate: _oneYearAfter(trainingDate),
      courseId: _courseId,
      courseKey: widget.courseKey,
      kind: kind,
      instructorName: instructorName,
      moduleKey: moduleKey,
    );
  }

  // ignore: unused_element
  Future<Uint8List> _buildCertificatePdfBytes({
    required String learnerName,
    required String courseTitle,
    String? moduleTitle,
    int? moduleNumber,
    int? moduleCount,
  }) async {
    final doc = pw.Document();
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    Uint8List? logo;
    try {
      logo = (await rootBundle.load(
        'assets/images/ybs_logo.png',
      )).buffer.asUint8List();
    } catch (_) {}

    Uint8List? certificateTemplate;
    try {
      certificateTemplate = (await rootBundle.load(
        'assets/images/DigitalCertificate.png',
      )).buffer.asUint8List();
    } catch (_) {}

    final bool isModuleCertificate =
        moduleTitle != null && moduleTitle.trim().isNotEmpty;
    final String moduleTitleText = moduleTitle?.trim() ?? '';
    final String heading = isModuleCertificate
        ? 'Module Milestone Certificate'
        : 'Certificate of Completion';
    final String completionLine = isModuleCertificate
        ? 'has successfully completed'
        : 'has successfully completed';
    final String awardTitle = isModuleCertificate
        ? moduleTitleText
        : courseTitle;

    final uidPart = _uid.substring(0, math.min(8, _uid.length)).toUpperCase();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final certificateId = isModuleCertificate
        ? 'MOD${moduleNumber ?? 0}-$uidPart-$datePart'
        : '$uidPart-$datePart';

    if (certificateTemplate != null) {
      final bg = pw.MemoryImage(certificateTemplate);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) {
            return pw.Stack(
              children: [
                pw.Positioned.fill(child: pw.Image(bg, fit: pw.BoxFit.cover)),
                pw.Positioned(
                  left: 0,
                  right: 0,
                  top: 500,
                  child: pw.Center(
                    child: pw.Text(
                      learnerName,
                      style: pw.TextStyle(
                        fontSize: 34,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromInt(0xFF111827),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                pw.Positioned(
                  left: 0,
                  right: 0,
                  top: 440,
                  child: pw.Center(
                    child: pw.Text(
                      awardTitle.toUpperCase(),
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        fontSize: 22,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromInt(0xFF111827),
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
                pw.Positioned(
                  left: 0,
                  right: 0,
                  top: 310,
                  child: pw.Center(
                    child: pw.Text(
                      'Issued on: $date',
                      style: pw.TextStyle(
                        fontSize: 15,
                        color: PdfColor.fromInt(0xFF1F2937),
                        letterSpacing: 0.25,
                        fontWeight: pw.FontWeight.normal,
                      ),
                    ),
                  ),
                ),
                pw.Positioned(
                  left: 120,
                  top: 250,
                  child: pw.Text(
                    'Course Instructor',
                    style: pw.TextStyle(
                      fontSize: 12,
                      color: PdfColor.fromInt(0xFF1F2937),
                    ),
                  ),
                ),
                pw.Positioned(
                  left: 475,
                  top: 250,
                  child: pw.Text(
                    'Academic Director',
                    style: pw.TextStyle(
                      fontSize: 12,
                      color: PdfColor.fromInt(0xFF1F2937),
                    ),
                  ),
                ),
                pw.Positioned(
                  left: 120,
                  top: 180,
                  child: pw.Text(
                    certificateId,
                    style: pw.TextStyle(
                      fontSize: 14,
                      color: PdfColor.fromInt(0xFF111827),
                      letterSpacing: 0.35,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
      return doc.save();
    }

    final logoImage = logo != null ? pw.MemoryImage(logo) : null;

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        build: (context) {
          return pw.Stack(
            children: [
              pw.Positioned.fill(
                child: pw.Container(
                  decoration: pw.BoxDecoration(
                    color: PdfColors.white,
                    border: pw.Border.all(
                      color: PdfColor.fromInt(_kYbsDeepBlueHex),
                      width: 2,
                    ),
                    borderRadius: pw.BorderRadius.circular(2),
                  ),
                ),
              ),
              pw.Positioned(
                top: 8,
                left: 8,
                right: 8,
                bottom: 8,
                child: pw.Container(
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: PdfColor.fromInt(_kYbsDeepOrangeHex),
                      width: 1,
                    ),
                  ),
                ),
              ),
              pw.Positioned(
                top: 20,
                left: 20,
                child: pw.Container(
                  width: 22,
                  height: 22,
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromInt(_kYbsDeepOrangeHex),
                    shape: pw.BoxShape.circle,
                  ),
                ),
              ),
              pw.Positioned(
                top: 16,
                right: 20,
                child: pw.Container(
                  width: 16,
                  height: 16,
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromInt(_kYbsDeepBlueHex),
                    shape: pw.BoxShape.circle,
                  ),
                ),
              ),
              pw.Positioned(
                bottom: 20,
                left: 18,
                child: pw.Container(
                  width: 18,
                  height: 18,
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromInt(0xFF7DD3FC),
                    shape: pw.BoxShape.circle,
                  ),
                ),
              ),
              pw.Positioned(
                bottom: 20,
                right: 20,
                child: pw.Container(
                  width: 26,
                  height: 26,
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromInt(0xFFFFE7CC),
                    border: pw.Border.all(
                      color: PdfColor.fromInt(_kYbsDeepOrangeHex),
                      width: 1,
                    ),
                    shape: pw.BoxShape.circle,
                  ),
                ),
              ),
              if (logoImage != null)
                pw.Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: pw.Opacity(
                    opacity: 0.02,
                    child: pw.Center(
                      child: pw.Image(logoImage, width: 260, height: 260),
                    ),
                  ),
                ),
              pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(34, 28, 34, 26),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    if (logoImage != null)
                      pw.Center(
                        child: pw.Image(logoImage, width: 58, height: 58),
                      ),
                    pw.SizedBox(height: 8),
                    pw.Center(
                      child: pw.Text(
                        'YOUR BRIDGE SCHOOL',
                        style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromInt(_kYbsDeepBlueHex),
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.Center(
                      child: pw.Text(
                        courseTitle,
                        style: pw.TextStyle(
                          fontSize: 14,
                          color: PdfColor.fromInt(_kYbsDeepOrangeHex),
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                    pw.Spacer(),
                    pw.Center(
                      child: pw.Text(
                        'This certifies that',
                        style: pw.TextStyle(
                          fontSize: 16,
                          color: PdfColor.fromInt(0xFF334155),
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 10),
                    pw.Center(
                      child: pw.Text(
                        learnerName,
                        textAlign: pw.TextAlign.center,
                        style: pw.TextStyle(
                          fontSize: 34,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromInt(_kYbsDeepBlueHex),
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 10),
                    pw.Center(
                      child: pw.Text(
                        completionLine,
                        style: pw.TextStyle(
                          fontSize: 14,
                          color: PdfColor.fromInt(0xFF334155),
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 10),
                    pw.Center(
                      child: pw.Text(
                        awardTitle,
                        textAlign: pw.TextAlign.center,
                        style: pw.TextStyle(
                          fontSize: 24,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromInt(0xFF0F172A),
                        ),
                      ),
                    ),
                    pw.Spacer(),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          'Issued on $date',
                          style: pw.TextStyle(
                            fontSize: 10,
                            color: PdfColor.fromInt(0xFF475569),
                          ),
                        ),
                        pw.Text(
                          isModuleCertificate
                              ? 'Module ${moduleNumber ?? '-'} of ${moduleCount ?? '-'}'
                              : heading,
                          style: pw.TextStyle(
                            fontSize: 8.5,
                            color: PdfColor.fromInt(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  Future<void> _onCertificateTap() async {
    try {
      final certId = 'course_${_sanitizeIdPart(_courseId)}';
      final cert = await _issueRecordedCertificate(
        certId: certId,
        certificateTitle: _title,
        trainingDate: _courseCompletionDate(),
        kind: 'course',
      );
      final bytes = await _certificatePdfService.generateCertificatePdfBytes(
        cert,
      );
      await _presentCertificate(
        bytes: bytes,
        defaultFileName:
            'course_certificate_${_sanitizeIdPart(widget.courseKey)}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not generate certificate.'),
        type: AppToastType.error,
      );
    }
  }

  String _moduleCertificateActionKey(String moduleLabel, int moduleIndex) {
    final moduleKeyBase = _sanitizeIdPart(moduleLabel);
    return moduleKeyBase.isNotEmpty
        ? '${moduleKeyBase}_${moduleIndex + 1}'
        : 'm${moduleIndex + 1}';
  }

  Widget _buildGeneratingCertificateDialog() {
    return Dialog(
      elevation: 0,
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(minHeight: 140),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: const BrandedInlineLoader(
          message: 'Preparing module certificate...',
        ),
      ),
    );
  }

  Future<void> _onModuleCertificateTap({
    required String moduleLabel,
    required List<_RecordedUnit> moduleUnits,
    required int moduleIndex,
  }) async {
    final moduleKey = _moduleCertificateActionKey(moduleLabel, moduleIndex);
    if (_generatingModuleCertificateKeys.contains(moduleKey)) return;

    if (mounted) {
      setState(() {
        _generatingModuleCertificateKeys.add(moduleKey);
      });
    } else {
      _generatingModuleCertificateKeys.add(moduleKey);
    }

    BuildContext? loadingDialogContext;

    try {
      if (mounted) {
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) {
              loadingDialogContext = dialogContext;
              return _buildGeneratingCertificateDialog();
            },
          ),
        );
      }

      final certId = 'module_${_sanitizeIdPart(_courseId)}_$moduleKey';
      final cert = await _issueRecordedCertificate(
        certId: certId,
        certificateTitle: '$_title - $moduleLabel',
        trainingDate: _moduleCompletionDate(moduleUnits),
        kind: 'milestone',
        moduleKey: moduleKey,
      );
      final bytes = await _certificatePdfService.generateCertificatePdfBytes(
        cert,
      );

      if (loadingDialogContext != null && loadingDialogContext!.mounted) {
        Navigator.of(loadingDialogContext!).pop();
        loadingDialogContext = null;
      }

      await _presentCertificate(
        bytes: bytes,
        defaultFileName:
            'module_${moduleIndex + 1}_certificate_${_sanitizeIdPart(widget.courseKey)}.pdf',
      );
    } catch (e) {
      if (loadingDialogContext != null && loadingDialogContext!.mounted) {
        Navigator.of(loadingDialogContext!).pop();
        loadingDialogContext = null;
      }
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not generate milestone certificate.'),
        type: AppToastType.error,
      );
    } finally {
      if (loadingDialogContext != null && loadingDialogContext!.mounted) {
        Navigator.of(loadingDialogContext!).pop();
      }
      if (mounted) {
        setState(() {
          _generatingModuleCertificateKeys.remove(moduleKey);
        });
      } else {
        _generatingModuleCertificateKeys.remove(moduleKey);
      }
    }
  }

  Future<void> _presentCertificate({
    required Uint8List bytes,
    required String defaultFileName,
  }) async {
    if (!mounted) return;

    final action = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Certificate Ready'),
        content: const Text('Print now or save/share to your device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'share'),
            child: const Text('Save / Share'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'print'),
            child: const Text('Print'),
          ),
        ],
      ),
    );

    if (action == 'print') {
      await Printing.layoutPdf(onLayout: (_) async => bytes);
      if (!mounted) return;
      AppToast.show(
        context,
        'Certificate opened in print preview.',
        type: AppToastType.success,
      );
      return;
    }

    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$defaultFileName',
    );
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([
      XFile(file.path, mimeType: 'application/pdf', name: defaultFileName),
    ]);

    if (!mounted) return;
    AppToast.show(
      context,
      'Certificate is ready to save or share.',
      type: AppToastType.success,
    );
  }

  Widget _buildModuleMilestoneCard({
    required String moduleLabel,
    required List<_RecordedUnit> moduleUnits,
    required int moduleIndex,
  }) {
    final completed = _isModuleCompleted(moduleUnits);
    final moduleActionKey = _moduleCertificateActionKey(
      moduleLabel,
      moduleIndex,
    );
    final generating = _generatingModuleCertificateKeys.contains(
      moduleActionKey,
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: completed ? _kYbsDeepOrange : const Color(0xFFF3D3B4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Milestone • $moduleLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _kYbsOrangeTextStrong,
                  fontSize: 13.5,
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: completed && !generating
                  ? () => _onModuleCertificateTap(
                      moduleLabel: moduleLabel,
                      moduleUnits: moduleUnits,
                      moduleIndex: moduleIndex,
                    )
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: _kYbsDeepBlue,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE5E7EB),
                disabledForegroundColor: const Color(0xFF94A3B8),
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: generating
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download_rounded, size: 15),
              label: Text(generating ? 'Preparing...' : 'Module certificate'),
            ),
          ],
        ),
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    AppToast.show(context, message, type: AppToastType.info);
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
                          minimumSize: const Size.fromHeight(46),
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

  Widget _buildSessionCard({
    required _RecordedSession session,
    required int flatIndex,
  }) {
    final isNarrow = MediaQuery.sizeOf(context).width < 420;
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

    Color dotColor = const Color(0xFF94A3B8);
    if (isCompleted) {
      dotColor = const Color(0xFF16A34A);
    } else if (isUnlocked) {
      dotColor = const Color(0xFF4F46E5);
    }

    return Container(
      margin: EdgeInsets.only(top: isNarrow ? 6 : 7),
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 9 : 10,
        vertical: isNarrow ? 8 : 9,
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
                width: isNarrow ? 20 : 22,
                height: isNarrow ? 20 : 22,
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
                    fontSize: isNarrow ? 9.5 : 10,
                  ),
                ),
              ),
              SizedBox(width: isNarrow ? 7 : 8),
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
                    fontSize: isNarrow ? 12.5 : 13,
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
                      width: isNarrow ? 22 : 24,
                      height: isNarrow ? 22 : 24,
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
              if (requiresVideo)
                Tooltip(
                  message: progress.videoCompleted
                      ? 'Rewatch video'
                      : 'Watch video',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: isUnlocked
                        ? () => _openVideoPlaceholder(session)
                        : null,
                    child: Container(
                      width: isNarrow ? 28 : 30,
                      height: isNarrow ? 28 : 30,
                      decoration: BoxDecoration(
                        color: isUnlocked
                            ? const Color(0xFFEEF2FF)
                            : const Color(0xFFF1F5F9),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        size: isNarrow ? 17 : 18,
                        color: isUnlocked
                            ? const Color(0xFF4F46E5)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                ),
              if (requiresMaterials)
                Padding(
                  padding: EdgeInsets.only(left: isNarrow ? 3 : 4),
                  child: Tooltip(
                    message: progress.materialsCompleted
                        ? 'Open reading again'
                        : 'Open reading',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: isUnlocked ? () => _openMaterials(session) : null,
                      child: Container(
                        width: isNarrow ? 28 : 30,
                        height: isNarrow ? 28 : 30,
                        decoration: BoxDecoration(
                          color: isUnlocked
                              ? const Color(0xFFFFF7ED)
                              : const Color(0xFFF1F5F9),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.menu_book_rounded,
                          size: isNarrow ? 16 : 17,
                          color: isUnlocked
                              ? const Color(0xFFEA580C)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (!isUnlocked)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Locked: finish the previous lesson first.',
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w700,
                    fontSize: 11.4,
                  ),
                ),
              ),
            ),
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
  }

  Widget _buildUnitsList() {
    final isNarrow = MediaQuery.sizeOf(context).width < 420;
    if (_units.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: const Text(
          'No recorded syllabus has been added for this course yet.',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF334155),
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
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    moduleLabel,
                                    style: TextStyle(
                                      color: Color(0xFF0F172A),
                                      fontWeight: FontWeight.w900,
                                      fontSize: isNarrow ? 14 : 14.5,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '$doneUnits/$totalUnits units • $doneLessons/$totalLessons lessons',
                                    style: TextStyle(
                                      color: Color(0xFF64748B),
                                      fontWeight: FontWeight.w700,
                                      fontSize: isNarrow ? 11.2 : 11.8,
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
      AppToast.show(
        context,
        'Only enrolled learners can add a review.',
        type: AppToastType.error,
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
      AppToast.show(
        context,
        humanizeUiMessage(e.toString()),
        type: AppToastType.error,
      );
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
                          AppToast.show(
                            ctx,
                            'Please add a comment before submitting.',
                            type: AppToastType.error,
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
      AppToast.show(context, 'Your review was submitted for approval.');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        humanizeUiMessage(e.toString()),
        type: AppToastType.error,
      );
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
                      SizedBox(
                        width: 360,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(12, 10, 8, 18),
                          children: [_buildTopOverviewCard()],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(8, 10, 12, 18),
                          children: [_buildUnitsList()],
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
                      _buildTopOverviewCard(),
                      const SizedBox(height: 10),
                      _buildUnitsList(),
                    ],
                  ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF2F6FB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.w900,
            fontSize: 17,
          ),
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
            Positioned.fill(child: content),
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

class _ExpiryStyle {
  const _ExpiryStyle({
    required this.bg,
    required this.border,
    required this.fg,
    required this.label,
    required this.icon,
  });

  final Color bg;
  final Color border;
  final Color fg;
  final String label;
  final IconData icon;
}

class _SessionRef {
  const _SessionRef({
    required this.unitIndex,
    required this.sessionIndex,
    required this.unit,
    required this.session,
  });

  final int unitIndex;
  final int sessionIndex;
  final _RecordedUnit unit;
  final _RecordedSession session;
}

class _RecordedProgress {
  const _RecordedProgress({
    this.videoCompleted = false,
    this.materialsCompleted = false,
    this.completed = false,
    this.videoCompletedAt = 0,
    this.materialsCompletedAt = 0,
  });

  final bool videoCompleted;
  final bool materialsCompleted;
  final bool completed;
  final int videoCompletedAt;
  final int materialsCompletedAt;

  _RecordedProgress copyWith({
    bool? videoCompleted,
    bool? materialsCompleted,
    bool? completed,
    int? videoCompletedAt,
    int? materialsCompletedAt,
  }) {
    return _RecordedProgress(
      videoCompleted: videoCompleted ?? this.videoCompleted,
      materialsCompleted: materialsCompleted ?? this.materialsCompleted,
      completed: completed ?? this.completed,
      videoCompletedAt: videoCompletedAt ?? this.videoCompletedAt,
      materialsCompletedAt: materialsCompletedAt ?? this.materialsCompletedAt,
    );
  }

  factory _RecordedProgress.fromMap(Map<String, dynamic> map) {
    bool asBool(dynamic v) {
      if (v is bool) return v;
      final s = (v ?? '').toString().trim().toLowerCase();
      return s == 'true' || s == '1';
    }

    return _RecordedProgress(
      videoCompleted: asBool(map['videoCompleted']),
      materialsCompleted: asBool(map['materialsCompleted']),
      completed: asBool(map['completed']),
      videoCompletedAt: _RecordedCourseStudyScreenState._asInt(
        map['videoCompletedAt'],
      ),
      materialsCompletedAt: _RecordedCourseStudyScreenState._asInt(
        map['materialsCompletedAt'],
      ),
    );
  }
}

class _RecordedUnit {
  _RecordedUnit({
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
  final List<_RecordedSession> sessions;

  String get displayTitle {
    final base = title.trim().isNotEmpty ? title.trim() : 'Untitled Unit';
    if (otherTitle.trim().isEmpty) return base;
    return '$base (${otherTitle.trim()})';
  }

  factory _RecordedUnit.fromMap(Map<String, dynamic> map) {
    final rawSessions = _RecordedCourseStudyScreenState._asListOfMaps(
      map['sessions'],
    );
    final sessions = rawSessions
        .map((e) => _RecordedSession.fromMap(e))
        .toList();

    return _RecordedUnit(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      otherTitle: (map['otherTitle'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      order: _RecordedCourseStudyScreenState._asInt(map['order']),
      sessions: sessions,
    );
  }
}

class _RecordedSession {
  _RecordedSession({
    required this.id,
    required this.title,
    required this.objective,
    required this.order,
    required this.sessionNumber,
    required this.videoUrl,
    required this.materialsUrl,
  });

  final String id;
  final String title;
  final String objective;
  final int order;
  final int sessionNumber;
  final String videoUrl;
  final String materialsUrl;

  factory _RecordedSession.fromMap(Map<String, dynamic> map) {
    return _RecordedSession(
      id: (map['id'] ?? '').toString().trim(),
      title: (map['title'] ?? '').toString(),
      objective: (map['objective'] ?? '').toString(),
      order: _RecordedCourseStudyScreenState._asInt(map['order']),
      sessionNumber: _RecordedCourseStudyScreenState._asInt(
        map['sessionNumber'],
      ),
      videoUrl: (map['videoUrl'] ?? '').toString(),
      materialsUrl: (map['materialsUrl'] ?? '').toString(),
    );
  }
}
