import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/material_webview_screen.dart';
import 'recorded_video_player_screen.dart';

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
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

  bool get _courseCompleted {
    return _totalSessions > 0 && _completedSessions == _totalSessions;
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

  Future<void> _openMaterials(_RecordedSession session) async {
    final url = session.materialsUrl.trim();
    if (url.isEmpty) {
      _snack('No reading content available for this session.');
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
        title: const Text('Finish this reading?'),
        content: const Text(
          'Mark this session as completed only if you finished the reading.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mark as done'),
          ),
        ],
      ),
    );

    if (finished == true) {
      await _markMaterialsCompleted(session);
      if (!mounted) return;
      _snack('Session marked as completed.');
    }
  }

  Future<void> _openVideoPlaceholder(_RecordedSession session) async {
    final hasVideo = session.videoUrl.trim().isNotEmpty;
    if (!hasVideo) {
      _snack('No video available for this session.');
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
          videoUrl: session.videoUrl.trim(),
        ),
      ),
    );

    if (!mounted) return;
    await _loadAll();
  }

  void _onCertificateTap() {
    _snack('Certificate download will be added soon.');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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

  Widget _buildExpiryCard() {
    final style = _expiryStyle;

    String subtitle;
    if (_expiresAt <= 0) {
      subtitle = 'Recorded access information was not found for this course.';
    } else if (_daysLeft < 0) {
      subtitle =
      'Your recorded access expired on ${_formatDateMs(_expiresAt)}.';
    } else if (_daysLeft == 0) {
      subtitle =
      'Your recorded access expires today (${_formatDateMs(_expiresAt)}).';
    } else if (_daysLeft == 1) {
      subtitle =
      'Your recorded access expires tomorrow (${_formatDateMs(_expiresAt)}).';
    } else {
      subtitle =
      'Your recorded access expires on ${_formatDateMs(_expiresAt)} • $_daysLeft days left.';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: style.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.88),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(style.icon, color: style.fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  style.label,
                  style: TextStyle(
                    color: style.fg,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: style.fg,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                if (_durationMonths > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Access duration: $_durationMonths month${_durationMonths == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: style.fg.withOpacity(0.92),
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopSummaryCard() {
    final pct = (_progressValue * 100).round();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF111827), Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Track progress and continue session by session.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.78),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _MetricTile(
                  title: 'Completed',
                  value: '$_completedSessions/$_totalSessions',
                  icon: Icons.check_circle_outline_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricTile(
                  title: 'Progress',
                  value: '$pct%',
                  icon: Icons.trending_up_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: _progressValue.clamp(0, 1),
              minHeight: 9,
              backgroundColor: Colors.white.withOpacity(0.14),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFA78BFA)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCertificateCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _courseCompleted
            ? const Color(0xFFF0FDF4)
            : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: _courseCompleted
              ? const Color(0xFFBBF7D0)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _courseCompleted
                  ? const Color(0xFFDCFCE7)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              _courseCompleted
                  ? Icons.workspace_premium_rounded
                  : Icons.lock_outline_rounded,
              color: _courseCompleted
                  ? const Color(0xFF15803D)
                  : const Color(0xFF6B7280),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _courseCompleted
                      ? 'Certificate unlocked'
                      : 'Certificate locked',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: _courseCompleted
                        ? const Color(0xFF15803D)
                        : const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _courseCompleted
                      ? 'All sessions are completed. Your certificate is now available.'
                      : 'Complete all sessions to unlock your certificate.',
                  style: TextStyle(
                    color: Colors.black.withOpacity(0.68),
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _courseCompleted ? _onCertificateTap : null,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF111827),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFE5E7EB),
              disabledForegroundColor: const Color(0xFF9CA3AF),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Certificate'),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.rule_folder_outlined,
              color: Color(0xFF4F46E5),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Session rule: finish either the Video or the Read content to mark the session as completed and unlock the next session.',
              style: TextStyle(
                color: const Color(0xFF334155),
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
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
        : isUnlocked
        ? const Color(0xFFE5E7EB)
        : const Color(0xFFE5E7EB);

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isCompleted
                      ? const Color(0xFFDCFCE7)
                      : isUnlocked
                      ? const Color(0xFFEEF2FF)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$number',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w900,
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
                    fontSize: 14.5,
                  ),
                ),
              ),
              _SessionBadge(
                label: isCompleted
                    ? 'Completed'
                    : (isUnlocked ? 'Unlocked' : 'Locked'),
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
            const SizedBox(height: 10),
            Text(
              session.objective.trim(),
              style: TextStyle(
                color: Colors.black.withOpacity(0.68),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusMiniPill(
                label: requiresVideo
                    ? (progress.videoCompleted ? 'Video done' : 'Video pending')
                    : 'No video',
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
              _StatusMiniPill(
                label: requiresMaterials
                    ? (progress.materialsCompleted ? 'Read done' : 'Read pending')
                    : 'No read',
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
          const SizedBox(height: 12),
          if (!isUnlocked)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Text(
                'Complete the previous session to unlock this one.',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF64748B),
                ),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: requiresVideo
                        ? () => _openVideoPlaceholder(session)
                        : null,
                    icon: const Icon(Icons.ondemand_video_rounded),
                    label: Text(
                      progress.videoCompleted ? 'Video done' : 'Video',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF0F172A),
                      side: const BorderSide(color: Color(0xFFE2E8F0)),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: requiresMaterials
                        ? () => _openMaterials(session)
                        : null,
                    icon: const Icon(Icons.menu_book_rounded),
                    label: Text(
                      progress.materialsCompleted ? 'Read done' : 'Read',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF111827),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFE5E7EB),
                      disabledForegroundColor: const Color(0xFF9CA3AF),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
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
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
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
              final isUnitDone =
                  totalInUnit > 0 && completedInUnit == totalInUnit;

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

              return Container(
                width: double.infinity,
                margin: EdgeInsets.only(top: ui == 0 ? 0 : 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(22),
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
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: isUnitDone
                                    ? const Color(0xFFDCFCE7)
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                isUnitDone
                                    ? Icons.check_rounded
                                    : Icons.folder_open_rounded,
                                color: isUnitDone
                                    ? const Color(0xFF15803D)
                                    : const Color(0xFF475569),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    unit.displayTitle,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 15.5,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$completedInUnit of $totalInUnit completed',
                                    style: const TextStyle(
                                      color: Color(0xFF64748B),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0xFFE2E8F0),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    isExpanded ? 'Collapse' : 'Expand',
                                    style: const TextStyle(
                                      color: Color(0xFF475569),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    isExpanded
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    size: 18,
                                    color: const Color(0xFF475569),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (isExpanded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (unit.description.trim().isNotEmpty) ...[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: Text(
                                  unit.description.trim(),
                                  style: TextStyle(
                                    color: Colors.black.withOpacity(0.7),
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            ...sessionWidgets,
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF1F5F9),
        surfaceTintColor: const Color(0xFFF1F5F9),
        elevation: 0,
        titleSpacing: 0,
        title: const Text(
          'Recorded Course',
          style: TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.w900,
            fontSize: 17,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _loadAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFFECACA)),
            ),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFB91C1C),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      )
          : RefreshIndicator(
        onRefresh: _loadAll,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _buildTopSummaryCard(),
            const SizedBox(height: 14),
            _buildExpiryCard(),
            const SizedBox(height: 14),
            _buildCertificateCard(),
            const SizedBox(height: 14),
            _buildRuleCard(),
            const SizedBox(height: 14),
            _buildUnitsList(),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w900,
          fontSize: 11,
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
          fontSize: 11.5,
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
      materialsCompletedAt:
      materialsCompletedAt ?? this.materialsCompletedAt,
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
    final rawSessions =
    _RecordedCourseStudyScreenState._asListOfMaps(map['sessions']);
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
      sessionNumber:
      _RecordedCourseStudyScreenState._asInt(map['sessionNumber']),
      videoUrl: (map['videoUrl'] ?? '').toString(),
      materialsUrl: (map['materialsUrl'] ?? '').toString(),
    );
  }
}