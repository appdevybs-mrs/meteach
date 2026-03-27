import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/study_variant.dart';
import '../shared/teacher_tour_guide.dart';

class TeacherClassProgressScreen extends StatefulWidget {
  final String classId;
  final Map<String, dynamic> classData;

  const TeacherClassProgressScreen({
    super.key,
    required this.classId,
    required this.classData,
  });

  @override
  State<TeacherClassProgressScreen> createState() =>
      _TeacherClassProgressScreenState();
}

class _TeacherClassProgressScreenState
    extends State<TeacherClassProgressScreen> {
  static const Color successGreen = Color(0xFF10B981);
  static const Color warningOrange = Color(0xFFF59E0B);
  static const Color dangerRed = Color(0xFFEF4444);

  static const String classesNode = "classes";
  static const String syllabiNode = "syllabi";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _classRef = _db
      .child(classesNode)
      .child(widget.classId);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  StreamSubscription<DatabaseEvent>? _classSub;

  bool _busy = true;
  String? _error;

  Map<String, dynamic> _class = {};
  Map<String, dynamic> _attendance = {};
  Map<String, dynamic> _learners = {};

  List<Map<String, dynamic>> _syllabiFlat = [];
  int _totalSyllabusSessions = 0;

  Set<String> _classCoveredSessionIds = {};
  int _classProgressPct = 0;

  String? _selectedLearnerUid;
  bool _learnerView = false;

  AppPalette get palette => appThemeController.palette;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _boot();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _classSub?.cancel();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String get _courseTitle =>
      (widget.classData['course_title'] ??
              widget.classData['courseTitle'] ??
              'Class')
          .toString();

  String get _courseCode => (widget.classData['course_code'] ?? '').toString();

  String get _courseId => (widget.classData['course_id'] ?? '').toString();
  String get _variantKey => normalizeVariantKey(
    (widget.classData['variantKey'] ?? widget.classData['variant'] ?? '')
        .toString(),
  );

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  Future<void> _boot() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await _loadSyllabus();

      await _classSub?.cancel();
      _classSub = _classRef.onValue.listen(
        (event) {
          final raw = event.snapshot.value;
          final data = raw is Map
              ? Map<String, dynamic>.from(raw)
              : <String, dynamic>{};

          final att = (data['attendance'] is Map)
              ? Map<String, dynamic>.from(data['attendance'] as Map)
              : <String, dynamic>{};

          final learners = (data['learners'] is Map)
              ? Map<String, dynamic>.from(data['learners'] as Map)
              : <String, dynamic>{};

          final covered = _computeCoveredFromClassAttendance(att);
          final pct = _totalSyllabusSessions <= 0
              ? 0
              : ((covered.length / _totalSyllabusSessions) * 100).round().clamp(
                  0,
                  100,
                );

          String? selected = _selectedLearnerUid;
          if ((selected == null ||
                  selected.isEmpty ||
                  !learners.containsKey(selected)) &&
              learners.isNotEmpty) {
            selected = learners.keys.first.toString();
          }

          if (!mounted) return;
          setState(() {
            _class = data;
            _attendance = att;
            _learners = learners;
            _classCoveredSessionIds = covered;
            _classProgressPct = pct;
            _selectedLearnerUid = selected;
            if (_learners.isEmpty) _learnerView = false;
            _busy = false;
          });
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _error = toHumanError(e);
            _busy = false;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Future<void> _loadSyllabus() async {
    _syllabiFlat = [];
    _totalSyllabusSessions = 0;

    final cid = _courseId.trim();
    if (cid.isEmpty) return;

    final syllabusVariant = syllabusVariantForScheduledAttendance(_variantKey);
    var sSnap = await _syllabiRef.child(cid).child(syllabusVariant).get();
    if ((!sSnap.exists || sSnap.value == null || sSnap.value is! Map) &&
        syllabusVariant == 'private') {
      sSnap = await _syllabiRef.child(cid).child('inclass').get();
    }
    if (!sSnap.exists || sSnap.value == null || sSnap.value is! Map) return;

    final s = Map<String, dynamic>.from(sSnap.value as Map);
    final units = s['units'];
    final List<Map<String, dynamic>> flat = [];

    if (units is List) {
      for (final u in units) {
        if (u is! Map) continue;
        final unit = Map<String, dynamic>.from(u);
        final unitId = (unit['id'] ?? '').toString();
        final unitTitle = ((unit['title'] ?? '').toString().trim().isNotEmpty)
            ? (unit['title'] ?? '').toString()
            : (unit['description'] ?? '').toString();
        final unitOrder = unit['order'] ?? 0;

        final sessions = unit['sessions'];
        if (sessions is List) {
          for (final ss in sessions) {
            if (ss is! Map) continue;
            final sess = Map<String, dynamic>.from(ss);

            flat.add({
              'unitOrder': unitOrder,
              'unitId': unitId,
              'unitTitle': unitTitle,
              'order': sess['order'] ?? 0,
              'sessionId': (sess['id'] ?? '').toString(),
              'title': (sess['title'] ?? '').toString(),
              'skillType': (sess['skillType'] ?? '').toString(),
              'objective': (sess['objective'] ?? '').toString(),
              'content': (sess['content'] ?? '').toString(),
            });
          }
        }
      }
    }

    int n(dynamic v) =>
        (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    flat.sort((a, b) {
      final uo = n(a['unitOrder']).compareTo(n(b['unitOrder']));
      if (uo != 0) return uo;
      return n(a['order']).compareTo(n(b['order']));
    });

    _syllabiFlat = flat;
    _totalSyllabusSessions = flat.length;
  }

  Set<String> _computeCoveredFromClassAttendance(Map<String, dynamic> att) {
    final Set<String> covered = {};

    for (final entry in att.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;
      final r = Map<String, dynamic>.from(rec);

      if (r['taughtItems'] is List) {
        final items = (r['taughtItems'] as List).whereType<Map>().toList();
        for (final item in items) {
          final m = Map<String, dynamic>.from(item);
          final sid = (m['sessionId'] ?? '').toString().trim();
          if (sid.isNotEmpty) covered.add(sid);
        }
      }

      final taught = r['taught'];
      if (taught is Map) {
        final tm = Map<String, dynamic>.from(taught);
        final sid = (tm['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) covered.add(sid);
      }
    }

    return covered;
  }

  Set<String> _computeCoveredForLearner(String learnerUid) {
    final Set<String> covered = {};

    for (final entry in _attendance.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;

      final r = Map<String, dynamic>.from(rec);

      bool isPresent = false;
      final p = r['present'];
      if (p is Map) {
        final pm = Map<String, dynamic>.from(p);
        if (pm.containsKey(learnerUid) && pm[learnerUid] == true) {
          isPresent = true;
        }
      }

      if (!isPresent) continue;

      if (r['taughtItems'] is List) {
        final items = (r['taughtItems'] as List).whereType<Map>().toList();
        for (final item in items) {
          final m = Map<String, dynamic>.from(item);
          final sid = (m['sessionId'] ?? '').toString().trim();
          if (sid.isNotEmpty) covered.add(sid);
        }
      }

      final taught = r['taught'];
      if (taught is Map) {
        final tm = Map<String, dynamic>.from(taught);
        final sid = (tm['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) covered.add(sid);
      }
    }

    return covered;
  }

  _LearnerStats _statsForLearner(String learnerUid) {
    int present = 0;
    int absent = 0;
    int held = 0;

    for (final entry in _attendance.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;
      held++;

      final r = Map<String, dynamic>.from(rec);
      final p = r['present'];
      final a = r['absent'];

      if (p is Map && p.containsKey(learnerUid) && (p[learnerUid] == true)) {
        present++;
      }
      if (a is Map && a.containsKey(learnerUid) && (a[learnerUid] == true)) {
        absent++;
      }
    }

    return _LearnerStats(sessionsHeld: held, present: present, absent: absent);
  }

  String _learnerName(String uid) {
    final node = _learners[uid];
    if (node is Map) {
      final m = Map<String, dynamic>.from(node);
      final name = (m['name'] ?? '').toString().trim();
      if (name.isNotEmpty) return name;
    }
    return 'Learner';
  }

  String _dropdownLabelFor(String uid) {
    final name = _learnerName(uid);
    final stats = _statsForLearner(uid);
    return '$name — ${stats.present}/${stats.sessionsHeld} present';
  }

  List<Map<String, dynamic>> _groupSyllabiByUnit() {
    final Map<String, Map<String, dynamic>> groups = {};

    int n(dynamic v) =>
        (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    for (final s in _syllabiFlat) {
      final unitId = (s['unitId'] ?? '').toString();
      final unitTitle = (s['unitTitle'] ?? '').toString();
      final unitOrder = n(s['unitOrder']);

      final key = unitId.isNotEmpty ? unitId : 'unit_$unitOrder|$unitTitle';

      groups.putIfAbsent(key, () {
        return {
          'unitId': unitId,
          'unitTitle': unitTitle.isEmpty ? 'Unit' : unitTitle,
          'unitOrder': unitOrder,
          'sessions': <Map<String, dynamic>>[],
        };
      });

      (groups[key]!['sessions'] as List<Map<String, dynamic>>).add(s);
    }

    final list = groups.values.toList();
    list.sort((a, b) => n(a['unitOrder']).compareTo(n(b['unitOrder'])));

    for (final u in list) {
      final sessions = (u['sessions'] as List<Map<String, dynamic>>);
      sessions.sort((a, b) => n(a['order']).compareTo(n(b['order'])));
    }

    return list;
  }

  String _progressLabel(int pct) {
    if (pct >= 90) return 'Excellent';
    if (pct >= 75) return 'Strong';
    if (pct >= 50) return 'Fair';
    if (pct >= 25) return 'Started';
    return 'Not started';
  }

  Color _progressColor(int pct) {
    if (pct >= 75) return successGreen;
    if (pct >= 40) return warningOrange;
    return dangerRed;
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final mq = MediaQuery.of(context);
    final scale = mq.textScaleFactor;
    final clampedScale = scale.clamp(0.85, 1.20);

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_class_progress',
      hints: const [
        TeacherTourHint(
          title: 'Class progress',
          line:
              'Check learner progress, completion percentage, and pacing health here.',
        ),
      ],
    );

    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(clampedScale.toDouble())),
      child: Scaffold(
        backgroundColor: p.appBg,
        appBar: AppBar(
          backgroundColor: p.cardBg,
          elevation: 0,
          surfaceTintColor: p.cardBg,
          iconTheme: IconThemeData(color: p.primary),
          title: Text(
            'Class Progress',
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh_rounded, color: p.primary),
              onPressed: _busy ? null : _boot,
            ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.04,
                  child: Center(
                    child: Icon(
                      Icons.auto_graph_rounded,
                      size: 220,
                      color: p.primary.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
            ),
            _busy
                ? Center(child: CircularProgressIndicator(color: p.primary))
                : _error != null
                ? _buildErrorState(p)
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _headerHeroCard(p),
                      const SizedBox(height: 12),
                      _viewModeCard(p),
                      const SizedBox(height: 12),
                      if (_learners.isNotEmpty) ...[
                        _learnerPickerCard(p),
                        const SizedBox(height: 12),
                      ],
                      _progressOverviewCard(p),
                      const SizedBox(height: 12),
                      _unitsProgressCard(p),
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  Widget _headerHeroCard(AppPalette p) {
    final learnersCount = _learners.length;
    final sessionsHeld = _attendance.length;

    return Container(
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
              Icons.timeline_rounded,
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
                  _courseTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Class: ${widget.classId}${_courseCode.isEmpty ? '' : ' • Code: $_courseCode'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _heroChip(
                      label:
                          'Syllabus ${_totalSyllabusSessions <= 0 ? '-' : _totalSyllabusSessions}',
                    ),
                    _heroChip(label: 'Held $sessionsHeld'),
                    _heroChip(label: 'Learners $learnersCount'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroChip({required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _viewModeCard(AppPalette p) {
    final canUseLearnerView = _learners.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'View',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.border.withValues(alpha: 0.9)),
              color: p.primary.withValues(alpha: 0.04),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _toggleBtn(
                    p,
                    label: 'Class',
                    selected: !_learnerView,
                    onTap: () {
                      setState(() => _learnerView = false);
                    },
                  ),
                ),
                Expanded(
                  child: _toggleBtn(
                    p,
                    label: 'Learner',
                    selected: _learnerView,
                    onTap: canUseLearnerView
                        ? () {
                            setState(() => _learnerView = true);
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ),
          if (!canUseLearnerView)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Learner view is disabled because there are no learners in this class.',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.75),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toggleBtn(
    AppPalette p, {
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected ? p.cardBg : Colors.transparent,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? p.primary : p.primary.withValues(alpha: 0.7),
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }

  Widget _learnerPickerCard(AppPalette p) {
    final uids = _learners.keys.map((e) => e.toString()).toList();

    if (uids.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withValues(alpha: 0.85)),
        ),
        child: Text(
          'No learners in this class.',
          style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
        ),
      );
    }

    final items = uids.map((uid) {
      final label = _dropdownLabelFor(uid);
      return DropdownMenuItem<String>(
        value: uid,
        child: SizedBox(
          width: double.infinity,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w800, color: p.text),
          ),
        ),
      );
    }).toList();

    final selectedBuilder = uids.map((uid) {
      final label = _dropdownLabelFor(uid);
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w800, color: p.text),
        ),
      );
    }).toList();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Learner',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _selectedLearnerUid,
            isExpanded: true,
            selectedItemBuilder: (_) => selectedBuilder,
            dropdownColor: p.cardBg,
            iconEnabledColor: p.primary,
            items: items,
            decoration: InputDecoration(
              filled: true,
              fillColor: p.primary.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: p.border.withValues(alpha: 0.9)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: p.accent, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            onChanged: (v) {
              if (v == null) return;
              setState(() => _selectedLearnerUid = v);
            },
          ),
        ],
      ),
    );
  }

  Widget _progressOverviewCard(AppPalette p) {
    final totalS = _totalSyllabusSessions;

    Set<String> coveredSet = _classCoveredSessionIds;
    int pct = _classProgressPct;

    _LearnerStats stats = const _LearnerStats(
      sessionsHeld: 0,
      present: 0,
      absent: 0,
    );

    if (_learnerView &&
        _selectedLearnerUid != null &&
        _selectedLearnerUid!.isNotEmpty) {
      final uid = _selectedLearnerUid!;
      stats = _statsForLearner(uid);
      coveredSet = _computeCoveredForLearner(uid);
      pct = totalS <= 0
          ? 0
          : ((coveredSet.length / totalS) * 100).round().clamp(0, 100);
    }

    final coveredCount = coveredSet.length;
    final progressColor = _progressColor(pct);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _learnerView ? 'Learner Progress' : 'Class Progress',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _kpi(
                p,
                label: 'Progress',
                value: '$pct%',
                icon: Icons.insights_rounded,
              ),
              _kpi(
                p,
                label: 'Passed',
                value: '$coveredCount/${totalS <= 0 ? '-' : totalS}',
                icon: Icons.check_circle_rounded,
              ),
              if (_learnerView) ...[
                _kpi(
                  p,
                  label: 'Present',
                  value: '${stats.present}/${stats.sessionsHeld}',
                  icon: Icons.event_available_rounded,
                ),
                _kpi(
                  p,
                  label: 'Absent',
                  value: '${stats.absent}',
                  icon: Icons.event_busy_rounded,
                ),
              ] else ...[
                _kpi(
                  p,
                  label: 'Held',
                  value: '${_attendance.length}',
                  icon: Icons.calendar_month_rounded,
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: totalS <= 0 ? 0 : (coveredCount / totalS).clamp(0, 1),
              minHeight: 10,
              backgroundColor: progressColor.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(progressColor),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                _progressLabel(pct),
                style: TextStyle(
                  color: progressColor,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _learnerView
                      ? 'Learner progress is based on covered sessions where this learner was present.'
                      : 'Class progress is based on syllabus sessions already taught.',
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _unitsProgressCard(AppPalette p) {
    if (_syllabiFlat.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withValues(alpha: 0.85)),
        ),
        child: Text(
          'Syllabus not found for this course.',
          style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
        ),
      );
    }

    final units = _groupSyllabiByUnit();

    Set<String> coveredSet = _classCoveredSessionIds;
    if (_learnerView &&
        _selectedLearnerUid != null &&
        _selectedLearnerUid!.isNotEmpty) {
      coveredSet = _computeCoveredForLearner(_selectedLearnerUid!);
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Syllabus Units',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _learnerView
                ? 'Sessions marked as Passed were taught and attended by the selected learner.'
                : 'Sessions marked as Passed were already taught in class.',
            style: TextStyle(
              color: p.text.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          ...units.map((u) => _unitExpansion(p, u, coveredSet)),
        ],
      ),
    );
  }

  Widget _unitExpansion(
    AppPalette p,
    Map<String, dynamic> u,
    Set<String> coveredSet,
  ) {
    final unitTitle = (u['unitTitle'] ?? 'Unit').toString();
    final sessions = (u['sessions'] as List<Map<String, dynamic>>);

    int unitTotal = sessions.length;
    int unitPassed = 0;
    for (final s in sessions) {
      final sid = (s['sessionId'] ?? '').toString();
      if (sid.isNotEmpty && coveredSet.contains(sid)) unitPassed++;
    }

    final unitPct = unitTotal == 0
        ? 0
        : ((unitPassed / unitTotal) * 100).round();
    final unitColor = _progressColor(unitPct);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        color: p.cardBg,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.folder_open_rounded, color: p.primary),
            ),
            title: Text(
              unitTitle.isEmpty ? 'Unit' : unitTitle,
              style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Passed: $unitPassed / $unitTotal',
                      style: TextStyle(
                        color: p.text.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$unitPct%',
                    style: TextStyle(
                      color: unitColor,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: unitTotal == 0 ? 0 : unitPassed / unitTotal,
                  minHeight: 8,
                  backgroundColor: unitColor.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(unitColor),
                ),
              ),
              const SizedBox(height: 12),
              ...sessions.map((s) => _sessionExpansion(p, s, coveredSet)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sessionExpansion(
    AppPalette p,
    Map<String, dynamic> s,
    Set<String> coveredSet,
  ) {
    final title = (s['title'] ?? '').toString();
    final sessionId = (s['sessionId'] ?? '').toString();
    final skill = (s['skillType'] ?? '').toString();
    final objective = (s['objective'] ?? '').toString();
    final content = (s['content'] ?? '').toString();

    final bool passed = sessionId.isNotEmpty && coveredSet.contains(sessionId);
    final statusText = passed ? 'Passed' : 'Coming';
    final statusColor = passed ? successGreen : warningOrange;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        color: p.cardBg,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                passed ? Icons.check_circle_rounded : Icons.schedule_rounded,
                color: statusColor,
              ),
            ),
            title: Text(
              title.isEmpty ? 'Session' : title,
              style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [if (skill.isNotEmpty) skill, statusText].join(' • '),
              style: TextStyle(
                color: p.text.withValues(alpha: 0.7),
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: p.border.withValues(alpha: 0.85)),
                  color: p.primary.withValues(alpha: 0.04),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailLine(p, 'Status', statusText),
                    if (sessionId.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _detailLine(p, 'Session ID', sessionId),
                    ],
                    if (objective.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Objective',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        objective,
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w700,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (content.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Content',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        content,
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w700,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailLine(AppPalette p, String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.70),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }

  Widget _kpi(
    AppPalette p, {
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        color: p.primary.withValues(alpha: 0.04),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: p.primary),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.7),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: dangerRed.withValues(alpha: 0.20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 56,
                color: dangerRed,
              ),
              const SizedBox(height: 12),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: dangerRed,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LearnerStats {
  final int sessionsHeld;
  final int present;
  final int absent;

  const _LearnerStats({
    required this.sessionsHeld,
    required this.present,
    required this.absent,
  });
}
