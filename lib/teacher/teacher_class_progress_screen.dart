// teacher_class_progress_screen.dart
// ✅ FULL DROP-IN REPLACEMENT (copy/paste)
// Upgrades (safe + professional):
// ✅ Unit -> Sessions collapsible (ExpansionTile)
// ✅ Class vs Learner toggle (teacher can switch view)
// ✅ Learner dropdown label fixed (no misleading class % inside label)
// ✅ Session tiles expandable with details (objective + content + sessionId)
// ✅ Learner progress is computed from existing attendance node ONLY:
//    - Present map: attendance/<anyKey>/present/<uid> == true
//    - Covered sessionId: attendance/<anyKey>/taught/sessionId
//    - In Learner view: a session is "Passed" only if it was held AND that learner was present for it.
// ✅ Keeps your responsive dropdown safety: isExpanded + selectedItemBuilder + ellipsis
// ✅ Keeps your soft text scale clamp (you can remove it if you want)

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherClassProgressScreen extends StatefulWidget {
  final String classId;
  final Map<String, dynamic> classData;

  const TeacherClassProgressScreen({
    super.key,
    required this.classId,
    required this.classData,
  });

  @override
  State<TeacherClassProgressScreen> createState() => _TeacherClassProgressScreenState();
}

class _TeacherClassProgressScreenState extends State<TeacherClassProgressScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  static const String classesNode = "classes";
  static const String syllabiNode = "syllabi";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _classRef = _db.child(classesNode).child(widget.classId);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  StreamSubscription<DatabaseEvent>? _classSub;

  bool _busy = true;
  String? _error;

  Map<String, dynamic> _class = {};
  Map<String, dynamic> _attendance = {};
  Map<String, dynamic> _learners = {};

  List<Map<String, dynamic>> _syllabiFlat = [];
  int _totalSyllabusSessions = 0;

  // Class coverage (from taught/sessionId)
  Set<String> _classCoveredSessionIds = {};
  int _classProgressPct = 0;

  String? _selectedLearnerUid;

  // ✅ view toggle
  bool _learnerView = false; // false = Class view, true = Learner view

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _classSub?.cancel();
    super.dispose();
  }

  String get _courseTitle =>
      (widget.classData['course_title'] ?? widget.classData['courseTitle'] ?? 'Class').toString();

  String get _courseCode => (widget.classData['course_code'] ?? '').toString();
  String get _courseId => (widget.classData['course_id'] ?? '').toString(); // syllabi key

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
      _classSub = _classRef.onValue.listen((event) {
        final raw = event.snapshot.value;
        final data = raw is Map ? Map<String, dynamic>.from(raw as Map) : <String, dynamic>{};

        final att = (data['attendance'] is Map)
            ? Map<String, dynamic>.from(data['attendance'] as Map)
            : <String, dynamic>{};

        final learners = (data['learners'] is Map)
            ? Map<String, dynamic>.from(data['learners'] as Map)
            : <String, dynamic>{};

        final covered = _computeCoveredFromClassAttendance(att);
        final pct = _totalSyllabusSessions <= 0
            ? 0
            : ((covered.length / _totalSyllabusSessions) * 100).round().clamp(0, 100);

        String? selected = _selectedLearnerUid;
        if ((selected == null || selected.isEmpty || !learners.containsKey(selected)) && learners.isNotEmpty) {
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

          // if no learners, force class view
          if (_learners.isEmpty) _learnerView = false;

          _busy = false;
        });
      }, onError: (e) {
        if (!mounted) return;
        setState(() {
          _error = e.toString();
          _busy = false;
        });
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _loadSyllabus() async {
    _syllabiFlat = [];
    _totalSyllabusSessions = 0;

    final cid = _courseId.trim();
    if (cid.isEmpty) return;

    final sSnap = await _syllabiRef.child(cid).child('inclass').get();
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

    int n(dynamic v) => (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
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
      final taught = r['taught'];
      if (taught is Map) {
        final tm = Map<String, dynamic>.from(taught);
        final sid = (tm['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) covered.add(sid);
      }
    }
    return covered;
  }

  // ✅ Learner coverage: sessionId is counted only if it was HELD and learner is PRESENT
  Set<String> _computeCoveredForLearner(String learnerUid) {
    final Set<String> covered = {};
    for (final entry in _attendance.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;

      final r = Map<String, dynamic>.from(rec);

      // taught/sessionId
      String taughtSid = '';
      final taught = r['taught'];
      if (taught is Map) {
        final tm = Map<String, dynamic>.from(taught);
        taughtSid = (tm['sessionId'] ?? '').toString().trim();
      }
      if (taughtSid.isEmpty) continue;

      // present/<uid> == true
      bool isPresent = false;
      final p = r['present'];
      if (p is Map) {
        final pm = Map<String, dynamic>.from(p);
        if (pm.containsKey(learnerUid) && pm[learnerUid] == true) isPresent = true;
      }

      if (isPresent) covered.add(taughtSid);
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

      if (p is Map && p.containsKey(learnerUid) && (p[learnerUid] == true)) present++;
      if (a is Map && a.containsKey(learnerUid) && (a[learnerUid] == true)) absent++;
    }

    return _LearnerStats(
      sessionsHeld: held,
      present: present,
      absent: absent,
    );
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
    // ✅ fixed: no class % here (that was misleading)
    return '$name — ${stats.present}/${stats.sessionsHeld} present';
  }

  // -------------------- Unit grouping helper --------------------

  List<Map<String, dynamic>> _groupSyllabiByUnit() {
    final Map<String, Map<String, dynamic>> groups = {};

    int n(dynamic v) => (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

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

  // -------------------- Build --------------------

  @override
  Widget build(BuildContext context) {
    // ✅ Soft clamp text scale JUST for this screen (keep or remove as you prefer)
    final mq = MediaQuery.of(context);
    final scale = mq.textScaleFactor;
    final clampedScale = scale.clamp(0.85, 1.20);

    return MediaQuery(
      data: mq.copyWith(textScaleFactor: clampedScale.toDouble()),
      child: Scaffold(
        backgroundColor: appBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          iconTheme: const IconThemeData(color: primaryBlue),
          title: const Text(
            'Class Progress',
            style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
          ),
        ),
        body: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        )
            : ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _headerCard(),
            const SizedBox(height: 12),
            _viewModeCard(),
            const SizedBox(height: 12),
            if (_learners.isNotEmpty) ...[
              _learnerPickerCard(),
              const SizedBox(height: 12),
            ],
            _progressCard(),
            const SizedBox(height: 12),
            _unitsProgressCard(),
          ],
        ),
      ),
    );
  }

  // -------------------- UI Cards --------------------

  Widget _headerCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.85)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _courseTitle,
              style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900, fontSize: 16),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              'Class: ${widget.classId}${_courseCode.isEmpty ? '' : ' • Code: $_courseCode'}',
              style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Text(
              'Syllabus sessions: ${_totalSyllabusSessions <= 0 ? '-' : _totalSyllabusSessions}',
              style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewModeCard() {
    final canUseLearnerView = _learners.isNotEmpty;

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.85)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('View', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: uiBorder.withOpacity(0.9)),
                color: primaryBlue.withOpacity(0.04),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _toggleBtn(
                      label: 'Class',
                      selected: !_learnerView,
                      onTap: () {
                        setState(() => _learnerView = false);
                      },
                    ),
                  ),
                  Expanded(
                    child: _toggleBtn(
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
                  style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w700),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toggleBtn({required String label, required bool selected, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected ? Colors.white : Colors.transparent,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? primaryBlue : primaryBlue.withOpacity(0.7),
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }

  Widget _learnerPickerCard() {
    final uids = _learners.keys.map((e) => e.toString()).toList();

    if (uids.isEmpty) {
      return Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: uiBorder.withOpacity(0.85)),
        ),
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'No learners in this class.',
            style: TextStyle(color: mainText, fontWeight: FontWeight.w900),
          ),
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
            style: const TextStyle(fontWeight: FontWeight.w800, color: mainText),
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
          style: const TextStyle(fontWeight: FontWeight.w800, color: mainText),
        ),
      );
    }).toList();

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.85)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Learner', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _selectedLearnerUid,
              isExpanded: true,
              selectedItemBuilder: (_) => selectedBuilder,
              items: items,
              decoration: InputDecoration(
                filled: true,
                fillColor: primaryBlue.withOpacity(0.04),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: uiBorder.withOpacity(0.9)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _selectedLearnerUid = v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard() {
    final totalS = _totalSyllabusSessions;

    // Decide which "covered" set to use based on view mode
    Set<String> coveredSet = _classCoveredSessionIds;
    int pct = _classProgressPct;

    _LearnerStats stats = const _LearnerStats(sessionsHeld: 0, present: 0, absent: 0);

    if (_learnerView && _selectedLearnerUid != null && _selectedLearnerUid!.isNotEmpty) {
      final uid = _selectedLearnerUid!;
      stats = _statsForLearner(uid);
      coveredSet = _computeCoveredForLearner(uid);
      pct = totalS <= 0 ? 0 : ((coveredSet.length / totalS) * 100).round().clamp(0, 100);
    }

    final coveredCount = coveredSet.length;

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.85)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _learnerView ? 'Learner Progress' : 'Class Progress',
              style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _kpi(label: 'Progress', value: '$pct%'),
                _kpi(label: 'Passed', value: '$coveredCount/${totalS <= 0 ? '-' : totalS}'),
                if (_learnerView) ...[
                  _kpi(label: 'Present', value: '${stats.present}/${stats.sessionsHeld}'),
                  _kpi(label: 'Absent', value: '${stats.absent}'),
                ] else ...[
                  _kpi(label: 'Held', value: '${_attendance.length}'),
                ],
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: totalS <= 0 ? 0 : (coveredCount / totalS).clamp(0, 1),
                minHeight: 10,
                backgroundColor: primaryBlue.withOpacity(0.10),
                valueColor: const AlwaysStoppedAnimation(actionOrange),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              (_learnerView ? 'Learner progress: $pct%' : 'Class progress: $pct%'),
              style: const TextStyle(color: mainText, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  Widget _unitsProgressCard() {
    if (_syllabiFlat.isEmpty) {
      return Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: uiBorder.withOpacity(0.85)),
        ),
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'Syllabus not found for this course.',
            style: TextStyle(color: mainText, fontWeight: FontWeight.w900),
          ),
        ),
      );
    }

    final units = _groupSyllabiByUnit();

    // Choose covered set depending on view
    Set<String> coveredSet = _classCoveredSessionIds;
    if (_learnerView && _selectedLearnerUid != null && _selectedLearnerUid!.isNotEmpty) {
      coveredSet = _computeCoveredForLearner(_selectedLearnerUid!);
    }

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.85)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Syllabus', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            ...units.map((u) => _unitExpansion(u, coveredSet)).toList(),
          ],
        ),
      ),
    );
  }

  Widget _unitExpansion(Map<String, dynamic> u, Set<String> coveredSet) {
    final unitTitle = (u['unitTitle'] ?? 'Unit').toString();
    final sessions = (u['sessions'] as List<Map<String, dynamic>>);

    int unitTotal = sessions.length;
    int unitPassed = 0;
    for (final s in sessions) {
      final sid = (s['sessionId'] ?? '').toString();
      if (sid.isNotEmpty && coveredSet.contains(sid)) unitPassed++;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
        color: Colors.white,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: CircleAvatar(
              backgroundColor: primaryBlue.withOpacity(0.08),
              child: const Icon(Icons.folder_open_rounded, color: primaryBlue),
            ),
            title: Text(
              unitTitle.isEmpty ? 'Unit' : unitTitle,
              style: const TextStyle(color: mainText, fontWeight: FontWeight.w900),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              'Passed: $unitPassed / $unitTotal',
              style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w800),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            children: [
              ...sessions.map((s) => _sessionExpansion(s, coveredSet)).toList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sessionExpansion(Map<String, dynamic> s, Set<String> coveredSet) {
    final title = (s['title'] ?? '').toString();
    final sessionId = (s['sessionId'] ?? '').toString();
    final skill = (s['skillType'] ?? '').toString();
    final objective = (s['objective'] ?? '').toString();
    final content = (s['content'] ?? '').toString();

    final bool passed = sessionId.isNotEmpty && coveredSet.contains(sessionId);
    final statusText = passed ? 'Passed' : 'Coming';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
        color: Colors.white,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: CircleAvatar(
              backgroundColor: (passed ? primaryBlue : uiBorder).withOpacity(0.10),
              child: Icon(
                passed ? Icons.check_circle_rounded : Icons.schedule_rounded,
                color: passed ? primaryBlue : primaryBlue.withOpacity(0.55),
              ),
            ),
            title: Text(
              title.isEmpty ? 'Session' : title,
              style: const TextStyle(color: mainText, fontWeight: FontWeight.w900),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                if (skill.isNotEmpty) skill,
                statusText,
              ].join(' • '),
              style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: uiBorder.withOpacity(0.85)),
                  color: primaryBlue.withOpacity(0.04),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailLine('Status', statusText),
                    if (sessionId.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _detailLine('Session ID', sessionId),
                    ],
                    if (objective.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text('Objective', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 6),
                      Text(objective, style: TextStyle(color: mainText, fontWeight: FontWeight.w700)),
                    ],
                    if (content.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text('Content', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 6),
                      Text(content, style: TextStyle(color: mainText, fontWeight: FontWeight.w700)),
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

  Widget _detailLine(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(color: mainText.withOpacity(0.70), fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: const TextStyle(color: mainText, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }

  Widget _kpi({required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
        color: primaryBlue.withOpacity(0.04),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(color: mainText, fontWeight: FontWeight.w900)),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w800)),
        ],
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