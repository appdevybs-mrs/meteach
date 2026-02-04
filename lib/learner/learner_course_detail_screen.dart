import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'learner_homework_screen.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

class LearnerCourseDetailScreen extends StatefulWidget {
  final String courseKey; // course_1, course_2 ...
  final Map<String, dynamic> courseData; // snapshot of user/courses/<courseKey>

  const LearnerCourseDetailScreen({
    super.key,
    required this.courseKey,
    required this.courseData,
  });

  @override
  State<LearnerCourseDetailScreen> createState() => _LearnerCourseDetailScreenState();
}

class _LearnerCourseDetailScreenState extends State<LearnerCourseDetailScreen> with SingleTickerProviderStateMixin {
  static const usersNode = 'users';
  static const syllabiNode = 'syllabi';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  bool _busy = true;
  String? _error;

  String _uid = '';
  Map<String, dynamic> _course = {};
  List<Map<String, dynamic>> _attendance = [];

  List<Map<String, dynamic>> _syllabiFlat = [];
  Set<String> _coveredSessionIds = {};

  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _cls =>
      (_course['class'] is Map) ? Map<String, dynamic>.from(_course['class'] as Map) : <String, dynamic>{};

  String get _courseTitle => (_course['title'] ?? _course['course_title'] ?? 'Course').toString();
  String get _courseCode => (_course['course_code'] ?? '').toString();
  String get _classId => (_cls['class_id'] ?? '').toString();
  String get _courseId => (_cls['course_id'] ?? _course['id'] ?? '').toString(); // syllabi key

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _course = {};
      _attendance = [];
      _syllabiFlat = [];
      _coveredSessionIds = {};
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      // Reload course live (so it reflects new attendance)
      final snap = await _usersRef.child(_uid).child('courses').child(widget.courseKey).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) throw Exception('Course not found.');
      _course = Map<String, dynamic>.from(snap.value as Map);

      // Attendance list
      final att = _course['attendance'];
      final List<Map<String, dynamic>> attList = [];
      final Set<String> covered = {};

      if (att is Map) {
        final m = Map<String, dynamic>.from(att);
        for (final entry in m.entries) {
          final sessionId = entry.key.toString();
          if (entry.value is! Map) continue;
          final rec = Map<String, dynamic>.from(entry.value as Map);
          final taught = (rec['taught'] is Map) ? Map<String, dynamic>.from(rec['taught'] as Map) : <String, dynamic>{};
          final taughtSessionId = (taught['sessionId'] ?? '').toString().trim();
          if (taughtSessionId.isNotEmpty) covered.add(taughtSessionId);

          attList.add({
            'sessionId': sessionId,
            ...rec,
          });
        }
      }

      attList.sort((a, b) {
        final ad = (a['date'] ?? '').toString();
        final bd = (b['date'] ?? '').toString();
        return bd.compareTo(ad);
      });

      _attendance = attList;
      _coveredSessionIds = covered;

      // Load syllabi flat list
      if (_courseId.isNotEmpty) {
        final sSnap = await _syllabiRef.child(_courseId).get();
        if (sSnap.exists && sSnap.value != null && sSnap.value is Map) {
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
        }
      }

      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Map<String, int> _attendanceCounts() {
    final total = _attendance.length;
    final present = _attendance.where((x) => (x['status'] ?? '').toString().toLowerCase() == 'present').length;
    return {'total': total, 'present': present};
  }

  @override
  Widget build(BuildContext context) {
    final counts = _attendanceCounts();
    final total = counts['total'] ?? 0;
    final present = counts['present'] ?? 0;
    final attPct = total == 0 ? 0 : ((present / total) * 100).round();

    final totalS = _syllabiFlat.length;
    final covered = _coveredSessionIds.length;
    final progPct = totalS == 0 ? 0 : ((covered / totalS) * 100).round();

    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: Text(_courseTitle, style: const TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'Homework',
            icon: const Icon(Icons.assignment_rounded, color: UiK.actionOrange),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LearnerHomeworkScreen(
                    courseKey: widget.courseKey,
                    courseTitle: _courseTitle,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],

        bottom: TabBar(
          controller: _tab,
          labelColor: UiK.primaryBlue,
          indicatorColor: UiK.actionOrange,
          tabs: const [
            Tab(icon: Icon(Icons.how_to_reg_rounded), text: 'Attendance'),
            Tab(icon: Icon(Icons.insights_rounded), text: 'Progress'),
          ],
        ),
      ),
      body: WatermarkBackground(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
          ),
        )
            : TabBarView(
          controller: _tab,
          children: [
            _attendanceTab(attPct: attPct, present: present, total: total),
            _progressTab(progPct: progPct, covered: covered, totalS: totalS),
          ],
        ),
      ),
    );
  }

  Widget _attendanceTab({required int attPct, required int present, required int total}) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          elevation: 0,
          color: Colors.white,
          shape: UiK.cardShape(),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Course Summary', style: UiK.titleText()),
                const SizedBox(height: 8),
                Text('Code: ${_courseCode.isEmpty ? '-' : _courseCode} • Class: ${_classId.isEmpty ? '-' : _classId}',
                    style: UiK.subtleText()),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _kpi(icon: Icons.how_to_reg_rounded, label: 'Attendance', value: '$attPct%'),
                    _kpi(icon: Icons.check_circle_rounded, label: 'Present', value: '$present/$total'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        if (_attendance.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No attendance records yet.',
                  style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800)),
            ),
          )
        else
          ..._attendance.map(_attendanceCard).toList(),
      ],
    );
  }

  Widget _attendanceCard(Map<String, dynamic> a) {
    final date = (a['date'] ?? '').toString();
    final status = (a['status'] ?? '').toString().toLowerCase();
    final rate = (a['successRate'] ?? '').toString();

    final taught = (a['taught'] is Map)
        ? Map<String, dynamic>.from(a['taught'] as Map)
        : <String, dynamic>{};
    final taughtTitle = (taught['title'] ?? '').toString();
    final unitTitle = (taught['unitTitle'] ?? '').toString();

    // ✅ Homework (safe if missing)
    final hw = (a['homework'] is Map)
        ? Map<String, dynamic>.from(a['homework'] as Map)
        : <String, dynamic>{};
    final hwText = (hw['text'] ?? '').toString().trim();
    final hwDue = (hw['dueDate'] ?? '').toString().trim();

    final isPresent = status == 'present';

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: (isPresent ? UiK.primaryBlue : Colors.red).withOpacity(0.08),
              child: Icon(isPresent ? Icons.check_rounded : Icons.close_rounded,
                  color: isPresent ? UiK.primaryBlue : Colors.red),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(date.isEmpty ? 'Session' : date, style: UiK.titleText(size: 15)),
                  const SizedBox(height: 6),
                  Text(
                    'Status: ${isPresent ? 'Present' : 'Absent'}${rate.isEmpty ? '' : ' • Success: $rate%'}',
                    style: UiK.subtleText(),
                  ),

                  if (taughtTitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text('Taught: $taughtTitle', style: UiK.subtleText()),
                  ],
                  if (unitTitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Unit: $unitTitle',
                      style: TextStyle(color: UiK.mainText.withOpacity(0.6), fontWeight: FontWeight.w700),
                    ),
                  ],

                  // ✅ Homework display
                  if (hwText.isNotEmpty || hwDue.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                        color: UiK.primaryBlue.withOpacity(0.04),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.assignment_rounded, size: 18, color: UiK.actionOrange),
                              SizedBox(width: 8),
                              Text('Homework', style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
                            ],
                          ),
                          if (hwDue.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text('Due: $hwDue', style: UiK.subtleText()),
                          ],
                          if (hwText.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(hwText, style: UiK.subtleText()),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _progressTab({required int progPct, required int covered, required int totalS}) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          elevation: 0,
          color: Colors.white,
          shape: UiK.cardShape(),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Progress', style: UiK.titleText()),
                const SizedBox(height: 8),
                Text('Covered: $covered / $totalS sessions', style: UiK.subtleText()),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: totalS == 0 ? 0 : (covered / totalS).clamp(0, 1),
                    minHeight: 10,
                    backgroundColor: UiK.primaryBlue.withOpacity(0.10),
                    valueColor: const AlwaysStoppedAnimation(UiK.actionOrange),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Progress: $progPct%', style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        if (_syllabiFlat.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Syllabus not found for this course.',
                  style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800)),
            ),
          )
        else
          ..._syllabiFlat.map(_syllabiTile).toList(),
      ],
    );
  }

  Widget _syllabiTile(Map<String, dynamic> s) {
    final unitTitle = (s['unitTitle'] ?? '').toString();
    final title = (s['title'] ?? '').toString();
    final sessionId = (s['sessionId'] ?? '').toString();
    final skill = (s['skillType'] ?? '').toString();

    final covered = _coveredSessionIds.contains(sessionId);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        color: Colors.white,
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: (covered ? UiK.primaryBlue : UiK.uiBorder).withOpacity(0.10),
          child: Icon(covered ? Icons.check_circle_rounded : Icons.lock_outline_rounded,
              color: covered ? UiK.primaryBlue : UiK.primaryBlue.withOpacity(0.55)),
        ),
        title: Text(
          title.isEmpty ? 'Session' : title,
          style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
        ),
        subtitle: Text(
          [
            if (unitTitle.isNotEmpty) unitTitle,
            if (skill.isNotEmpty) skill,
            covered ? 'Covered' : 'Not covered yet',
          ].join(' • '),
          style: UiK.subtleText(),
        ),
      ),
    );
  }

  Widget _kpi({required IconData icon, required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        color: UiK.primaryBlue.withOpacity(0.04),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: UiK.actionOrange),
          const SizedBox(width: 10),
          Text(value, style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: UiK.mainText.withOpacity(0.7), fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
