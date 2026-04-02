import 'dart:io';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/material_webview_screen.dart';
import '../shared/learner_tour_guide.dart';
import '../shared/learner_web_layout.dart';
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

  final Set<String> _expandedUnitIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  DatabaseReference get _usersRef => _db.ref(_usersNode);

  DatabaseReference get _syllabiRef => _db.ref(_syllabiNode);

  DatabaseReference get _courseUserRef =>
      _usersRef.child(_uid).child('courses').child(widget.courseKey);

  DatabaseReference get _recordedAccessRef =>
      _courseUserRef.child(_recordedAccessNode);

  DatabaseReference get _recordedProgressRef =>
      _courseUserRef.child(_recordedProgressNode);

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
        _syllabiRef.child(_courseId).child('recorded').get(),
      ]);

      final DataSnapshot accessSnap = results[0] as DataSnapshot;
      final DataSnapshot progressSnap = results[1] as DataSnapshot;
      final DataSnapshot syllabusSnap = results[2] as DataSnapshot;
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
        final rawUnits = _asListOfMaps(root['units']);

        for (final u in rawUnits) {
          final unit = _RecordedUnit.fromMap(u);
          units.add(unit);
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
        _ensureExpandedUnits();
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

  void _ensureExpandedUnits() {
    if (_units.isEmpty) return;

    if (_expandedUnitIds.isEmpty) {
      _expandedUnitIds.add(_units.first.id.isNotEmpty ? _units.first.id : '0');
    }

    final validIds = _units
        .asMap()
        .entries
        .map((e) => e.value.id.isNotEmpty ? e.value.id : '${e.key}')
        .toSet();

    _expandedUnitIds.removeWhere((id) => !validIds.contains(id));
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

  String _lessonUnavailableMessage({required String lessonType}) {
    return '$lessonType is currently unavailable or misconfigured. '
        'Please refresh. If this continues, contact academy support and share your course name + session number.';
  }

  Future<void> _openMaterials(_RecordedSession session) async {
    final url = session.materialsUrl.trim();
    _debug('openMaterials sessionId=${session.id} hasUrl=${url.isNotEmpty}');
    if (!_isValidWebUrl(url)) {
      _snack(_lessonUnavailableMessage(lessonType: 'Reading lesson'));
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: session.title.isEmpty ? 'Session Reading' : session.title,
          url: url,
        ),
      ),
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                    style: const TextStyle(
                      fontSize: 12.5,
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
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
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
    final unitCount = _totalUnits;

    if (unitCount <= 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          minHeight: 5,
          value: _progressValue.clamp(0, 1),
          backgroundColor: const Color(0xFFE2E8F0),
          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF4F46E5)),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 16,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 5,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    value: _progressValue.clamp(0, 1),
                    backgroundColor: const Color(0xFFE2E8F0),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF4F46E5),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(unitCount, (i) {
                    final unitDone = _isUnitCompleted(_units[i]);
                    return Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: unitDone
                            ? const Color(0xFF16A34A)
                            : const Color(0xFFFFFFFF),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: unitDone
                              ? const Color(0xFF15803D)
                              : const Color(0xFF94A3B8),
                          width: 1.4,
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Module milestones: $_completedUnits/$unitCount',
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openVideoPlaceholder(_RecordedSession session) async {
    final hasVideo = session.videoUrl.trim().isNotEmpty;
    final videoUrl = session.videoUrl.trim();
    _debug('openVideo sessionId=${session.id} hasVideo=$hasVideo');
    if (!hasVideo || !_isValidWebUrl(videoUrl)) {
      _snack(_lessonUnavailableMessage(lessonType: 'Video lesson'));
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecordedVideoPlayerScreen(
          uid: _uid,
          courseKey: widget.courseKey,
          sessionId: session.id,
          sessionTitle: session.title,
          videoUrl: videoUrl,
        ),
      ),
    );

    if (!mounted) return;
    await _loadAll();
  }

  Future<String> _learnerDisplayName() async {
    try {
      final snap = await _usersRef.child(_uid).get();
      if (!snap.exists || snap.value is! Map) return 'Learner';
      final m = Map<String, dynamic>.from(snap.value as Map);
      final first = (m['first_name'] ?? '').toString().trim();
      final last = (m['last_name'] ?? '').toString().trim();
      final full = '$first $last'.trim();
      if (full.isNotEmpty) return full;
    } catch (_) {}
    return 'Learner';
  }

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

    final logoImage = logo != null ? pw.MemoryImage(logo) : null;

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
      final learnerName = await _learnerDisplayName();
      final bytes = await _buildCertificatePdfBytes(
        learnerName: learnerName,
        courseTitle: _title,
      );
      await _presentCertificate(
        bytes: bytes,
        defaultFileName: 'course_certificate_${widget.courseKey}.pdf',
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

  Future<void> _onUnitCertificateTap({
    required _RecordedUnit unit,
    required int unitIndex,
  }) async {
    try {
      final learnerName = await _learnerDisplayName();
      final bytes = await _buildCertificatePdfBytes(
        learnerName: learnerName,
        courseTitle: _title,
        moduleTitle: unit.displayTitle,
        moduleNumber: unitIndex + 1,
        moduleCount: _totalUnits,
      );
      await _presentCertificate(
        bytes: bytes,
        defaultFileName:
            'module_${unitIndex + 1}_certificate_${widget.courseKey}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(e, fallback: 'Could not generate milestone certificate.'),
        type: AppToastType.error,
      );
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

  Widget _buildUnitMilestoneCard({
    required _RecordedUnit unit,
    required int unitIndex,
  }) {
    final completed = _isUnitCompleted(unit);

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
                'Milestone • ${unit.displayTitle}',
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
              onPressed: completed
                  ? () =>
                        _onUnitCertificateTap(unit: unit, unitIndex: unitIndex)
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: _kYbsDeepBlue,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE5E7EB),
                disabledForegroundColor: const Color(0xFF94A3B8),
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: const Icon(Icons.download_rounded, size: 15),
              label: const Text('Module certificate'),
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
                    Text(
                      _title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 14),
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
                    _InfoTile(
                      icon: Icons.rule_folder_outlined,
                      title: 'Session rule',
                      value:
                          'Finish either the Video or the Read content to mark the session as completed and unlock the next session.',
                      iconColor: const Color(0xFF4F46E5),
                    ),
                    if (_durationMonths > 0)
                      _InfoTile(
                        icon: Icons.calendar_month_rounded,
                        title: 'Access duration',
                        value:
                            '$_durationMonths month${_durationMonths == 1 ? '' : 's'}',
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
    required _RecordedUnit unit,
    required _RecordedSession session,
    required int flatIndex,
  }) {
    final progress = _progressOf(session.id);
    final isUnlocked = _isSessionUnlocked(flatIndex);
    final isCompleted = _isSessionCompleted(session);
    final requiresVideo = _sessionRequiresVideo(session);
    final requiresMaterials = _sessionRequiresMaterials(session);

    final number = session.sessionNumber > 0
        ? session.sessionNumber
        : (flatIndex + 1);

    final Color accent = isCompleted
        ? const Color(0xFF15803D)
        : isUnlocked
        ? const Color(0xFF4F46E5)
        : const Color(0xFF6B7280);

    final Color bg = isCompleted
        ? const Color(0xFFF0FDF4)
        : isUnlocked
        ? const Color(0xFFFFFFFF)
        : const Color(0xFFF8FAFC);

    final Color border = isCompleted
        ? const Color(0xFFBBF7D0)
        : const Color(0xFFE5E7EB);

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isCompleted
                      ? const Color(0xFFDCFCE7)
                      : isUnlocked
                      ? const Color(0xFFEEF2FF)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$number',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w900,
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  session.title.isEmpty ? 'Untitled Session' : session.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    fontSize: 14,
                  ),
                ),
              ),
              _SessionBadge(
                label: isCompleted ? '✓' : (isUnlocked ? 'Open' : '🔒'),
                fg: accent,
                bg: isCompleted
                    ? const Color(0xFFDCFCE7)
                    : isUnlocked
                    ? const Color(0xFFEEF2FF)
                    : const Color(0xFFF1F5F9),
              ),
            ],
          ),
          if (session.objective.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              session.objective.trim(),
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.67),
                fontWeight: FontWeight.w600,
                height: 1.3,
                fontSize: 12.5,
              ),
            ),
          ],
          if (requiresVideo || requiresMaterials) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (requiresVideo)
                  _StatusMiniPill(
                    label: progress.videoCompleted ? '✓ Video' : 'Video',
                    fg: progress.videoCompleted
                        ? const Color(0xFF15803D)
                        : const Color(0xFF475569),
                    bg: progress.videoCompleted
                        ? const Color(0xFFF0FDF4)
                        : const Color(0xFFFFFFFF),
                    border: progress.videoCompleted
                        ? const Color(0xFFBBF7D0)
                        : const Color(0xFFE2E8F0),
                  ),
                if (requiresMaterials)
                  _StatusMiniPill(
                    label: progress.materialsCompleted ? '✓ Read' : 'Read',
                    fg: progress.materialsCompleted
                        ? const Color(0xFF15803D)
                        : const Color(0xFF475569),
                    bg: progress.materialsCompleted
                        ? const Color(0xFFF0FDF4)
                        : const Color(0xFFFFFFFF),
                    border: progress.materialsCompleted
                        ? const Color(0xFFBBF7D0)
                        : const Color(0xFFE2E8F0),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (!isUnlocked)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 15,
                    color: Color(0xFF64748B),
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Finish the previous session to unlock this one.',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF64748B),
                        fontSize: 12.3,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (requiresVideo || requiresMaterials)
            Row(
              children: [
                if (requiresVideo) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openVideoPlaceholder(session),
                      icon: const Icon(Icons.ondemand_video_rounded, size: 18),
                      label: Text(
                        progress.videoCompleted ? 'Rewatch 🔁' : 'Watch ▶',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF0F172A),
                        side: const BorderSide(color: Color(0xFFE2E8F0)),
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                ],
                if (requiresVideo && requiresMaterials)
                  const SizedBox(width: 8),
                if (requiresMaterials) ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _openMaterials(session),
                      icon: const Icon(Icons.menu_book_rounded, size: 18),
                      label: Text(
                        progress.materialsCompleted
                            ? 'Read again 🔁'
                            : 'Read 📘',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF111827),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildUnitsList() {
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

    int flatIndex = 0;

    return Column(
      children: [
        for (int ui = 0; ui < _units.length; ui++) ...[
          Builder(
            builder: (_) {
              final unit = _units[ui];
              final unitId = unit.id.isNotEmpty ? unit.id : '$ui';
              final isExpanded = _expandedUnitIds.contains(unitId);
              final completedInUnit = _countCompletedInUnit(unit);
              final totalInUnit = unit.sessions.length;
              final isUnitDone = _isUnitCompleted(unit);

              final List<Widget> sessionWidgets = [];
              for (int si = 0; si < unit.sessions.length; si++) {
                sessionWidgets.add(
                  _buildSessionCard(
                    unit: unit,
                    session: unit.sessions[si],
                    flatIndex: flatIndex++,
                  ),
                );
              }

              return Column(
                children: [
                  Container(
                    width: double.infinity,
                    margin: EdgeInsets.only(top: ui == 0 ? 0 : 10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFFFFFF), Color(0xFFF8FAFC)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.035),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () {
                            setState(() {
                              if (isExpanded) {
                                _expandedUnitIds.remove(unitId);
                              } else {
                                _expandedUnitIds.add(unitId);
                              }
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 13,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: isUnitDone
                                        ? const Color(0xFFDCFCE7)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: Icon(
                                    isUnitDone
                                        ? Icons.check_rounded
                                        : Icons.folder_open_rounded,
                                    color: isUnitDone
                                        ? const Color(0xFF15803D)
                                        : const Color(0xFF475569),
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        unit.displayTitle,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 14.5,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '$completedInUnit of $totalInUnit completed',
                                        style: const TextStyle(
                                          color: Color(0xFF64748B),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isExpanded
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                  color: const Color(0xFF64748B),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (isExpanded)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (unit.description.trim().isNotEmpty) ...[
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF8FAFC),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: const Color(0xFFE2E8F0),
                                      ),
                                    ),
                                    child: Text(
                                      unit.description.trim(),
                                      style: TextStyle(
                                        color: Colors.black.withValues(
                                          alpha: 0.70,
                                        ),
                                        fontWeight: FontWeight.w600,
                                        height: 1.3,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                ...sessionWidgets,
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (ui < _units.length - 1)
                    _buildUnitMilestoneCard(unit: unit, unitIndex: ui),
                ],
              );
            },
          ),
        ],
      ],
    );
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
    LearnerTourGuide.schedule(
      context,
      screenId: 'learner_recorded_course',
      hints: const [
        LearnerTourHint(
          title: 'الدروس المسجلة',
          line: 'اختر الوحدة، ثم افتح الفيديو أو مواد القراءة لكل جلسة.',
        ),
        LearnerTourHint(
          title: 'شهادة الدورة',
          line: 'بعد استكمال المتطلبات يمكنك تنزيل الشهادة أو طباعتها.',
        ),
      ],
    );

    final Widget content;

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
                  'If this issue continues, please contact academy support and share your course title + session number.',
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
            ListView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
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
          if (kDebugMode)
            IconButton(
              tooltip: 'Debug certificate',
              onPressed: _onCertificateTap,
              icon: const Icon(Icons.bug_report_rounded),
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

class _SessionBadge extends StatelessWidget {
  const _SessionBadge({
    required this.label,
    required this.fg,
    required this.bg,
  });

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w900,
          fontSize: 10.5,
        ),
      ),
    );
  }
}

class _StatusMiniPill extends StatelessWidget {
  const _StatusMiniPill({
    required this.label,
    required this.fg,
    required this.bg,
    required this.border,
  });

  final String label;
  final Color fg;
  final Color bg;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w800,
          fontSize: 10.5,
        ),
      ),
    );
  }
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
