// teacher_class_progress_screen.dart
// ✅ NEW screen (responsive-safe)
// Fixes:
// - Dropdown overflow on small screens / big font scale
// - Uses isExpanded + selectedItemBuilder + ellipsis everywhere
// - Soft-clamps text scale inside this screen to avoid layout breakage

import 'dart:async';
import 'dart:math' as math;
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

  Set<String> _coveredSessionIds = {};
  int _classProgressPct = 0;

  String? _selectedLearnerUid;

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

          _coveredSessionIds = covered;
          _classProgressPct = pct;

          _selectedLearnerUid = selected;
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

    final sSnap = await _syllabiRef.child(cid).get();
    if (!sSnap.exists || sSnap.value == null || sSnap.value is! Map) return;

    final s = Map<String, dynamic>.from(sSnap.value as Map);
    final units = s['units'];
    final List<Map<String, dynamic>> flat = [];

    if (units is List) {
      for (final u in units) {
        if (u is! Map) continue;
        final unit = Map<String, dynamic>.from(u);
        final unitId = (unit['id'] ?? '').toString();
        final unitTitle = (unit['title'] ?? '').toString();
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
    return '$name — $_classProgressPct% • ${stats.present}/${stats.sessionsHeld} present';
  }

  @override
  Widget build(BuildContext context) {
    // ✅ Soft clamp text scale JUST for this screen
    // This prevents extreme accessibility font sizes from breaking layout.
    // Adjust max (1.15 / 1.2 / 1.3) as you prefer.
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
            _learnerPickerCard(),
            const SizedBox(height: 12),
            _progressCard(),
            const SizedBox(height: 12),
            _doneLeftCards(),
          ],
        ),
      ),
    );
  }

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
              'Covered sessions: ${_coveredSessionIds.length} / ${_totalSyllabusSessions <= 0 ? '-' : _totalSyllabusSessions}',
              style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w800),
            ),
          ],
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

    // Dropdown items (menu)
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

    // Selected item rendering (this is where overflow often happens)
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
              isExpanded: true, // ✅ critical
              selectedItemBuilder: (_) => selectedBuilder, // ✅ critical
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
    final uid = _selectedLearnerUid;
    final stats = (uid == null) ? const _LearnerStats(sessionsHeld: 0, present: 0, absent: 0) : _statsForLearner(uid);

    final covered = _coveredSessionIds.length;
    final totalS = _totalSyllabusSessions;

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
            const Text('Progress', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),

            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _kpi(label: 'Progress', value: '$_classProgressPct%'),
                _kpi(label: 'Covered', value: '$covered/${totalS <= 0 ? '-' : totalS}'),
                _kpi(label: 'Present', value: '${stats.present}/${stats.sessionsHeld}'),
                _kpi(label: 'Absent', value: '${stats.absent}'),
              ],
            ),

            const SizedBox(height: 12),

            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: totalS <= 0 ? 0 : (covered / totalS).clamp(0, 1),
                minHeight: 10,
                backgroundColor: primaryBlue.withOpacity(0.10),
                valueColor: const AlwaysStoppedAnimation(actionOrange),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Class progress: $_classProgressPct%',
              style: const TextStyle(color: mainText, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  Widget _doneLeftCards() {
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

    final done = _syllabiFlat.where((s) => _coveredSessionIds.contains((s['sessionId'] ?? '').toString())).toList();
    final left = _syllabiFlat.where((s) => !_coveredSessionIds.contains((s['sessionId'] ?? '').toString())).toList();

    return Column(
      children: [
        _sectionCard(
          title: '✅ Done (Covered)',
          subtitle: '${done.length} session(s)',
          items: done,
          emptyText: 'Nothing covered yet.',
        ),
        const SizedBox(height: 12),
        _sectionCard(
          title: '⏳ Left',
          subtitle: '${left.length} session(s)',
          items: left,
          emptyText: 'Everything is covered ✅',
        ),
      ],
    );
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required List<Map<String, dynamic>> items,
    required String emptyText,
  }) {
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900, fontSize: 15),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    subtitle,
                    style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w800),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  emptyText,
                  style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w800),
                ),
              )
            else
              ...items.map(_sessionTile).toList(),
          ],
        ),
      ),
    );
  }

  Widget _sessionTile(Map<String, dynamic> s) {
    final unitTitle = (s['unitTitle'] ?? '').toString();
    final title = (s['title'] ?? '').toString();
    final sessionId = (s['sessionId'] ?? '').toString();
    final skill = (s['skillType'] ?? '').toString();

    final covered = _coveredSessionIds.contains(sessionId);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
        color: Colors.white,
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: (covered ? primaryBlue : uiBorder).withOpacity(0.10),
          child: Icon(
            covered ? Icons.check_circle_rounded : Icons.lock_outline_rounded,
            color: covered ? primaryBlue : primaryBlue.withOpacity(0.55),
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
            if (unitTitle.isNotEmpty) unitTitle,
            if (skill.isNotEmpty) skill,
            covered ? 'Covered' : 'Not covered yet',
          ].join(' • '),
          style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
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
