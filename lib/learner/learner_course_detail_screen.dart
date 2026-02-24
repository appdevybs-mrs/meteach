// learner_course_detail_screen.dart
// ✅ FULL DROP-IN REPLACEMENT
// Keeps your working logic intact, but improves UI/UX exactly as requested:
//
// ✅ Payment tab updates:
// - Removes "Total paid"
// - Shows LAST payment (lastAmount + lastMethod + lastPaymentAt)
// - Table: Sessions paid | Sessions passed | Sessions left
// - Renames "sessionsDone/used" -> "sessionsPassed"
//
// ✅ Progress tab upgrades (PRO UX):
// - 2-level collapsible: Unit -> Sessions (ExpansionTile)
// - Uses your SAME syllabi loading logic (no DB changes)
// - Passed/Coming status based on _coveredSessionIds (same logic)
//
// ✅ Attendance tab unchanged (your logic kept)

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';

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
  StreamSubscription<DatabaseEvent>? _paySub;
  Map<String, dynamic> _paymentSummary = {};
  bool _payLoading = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _paySub?.cancel();
    _tab.dispose();
    super.dispose();
  }

  // -------------------- Safe helpers --------------------

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _fmtDateFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String _fmtMoney(int v) {
    // Simple grouping: 30000 -> 30,000
    final s = v.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final left = s.length - i;
      buf.write(s[i]);
      if (left > 1 && left % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  Map<String, dynamic> get _cls =>
      (_course['class'] is Map) ? Map<String, dynamic>.from(_course['class'] as Map) : <String, dynamic>{};

  String get _courseTitle => (_course['title'] ?? _course['course_title'] ?? 'Course').toString();
  String get _courseCode => (_course['course_code'] ?? '').toString();
  String get _classId => (_cls['class_id'] ?? '').toString();
  String get _courseId => (_cls['course_id'] ?? _course['id'] ?? '').toString(); // syllabi key

  DatabaseReference get _paymentSummaryRef =>
      _usersRef.child(_uid).child('courses').child(widget.courseKey).child('payment_summary');

  // -------------------- Load (keeps your working logic) --------------------

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

      // ✅ start payment listener (safe: one listener only)
      await _paySub?.cancel();
      _payLoading = true;

      _paySub = _paymentSummaryRef.onValue.listen((event) {
        final raw = event.snapshot.value;
        final sum = raw is Map ? raw.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};

        if (!mounted) return;
        setState(() {
          _paymentSummary = Map<String, dynamic>.from(sum);
          _payLoading = false;
        });
      }, onError: (_) {
        if (!mounted) return;
        setState(() {
          _paymentSummary = {};
          _payLoading = false;
        });
      });

      // Reload course live (so it reflects new attendance/payment_summary)
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

  // -------------------- Progress grouping helper --------------------

  List<Map<String, dynamic>> _groupSyllabiByUnit() {
    // Returns a list of unit groups:
    // [
    //   { unitId, unitTitle, unitOrder, sessions: [ ... ] },
    //   ...
    // ]
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

    // sort sessions inside each unit by order
    for (final u in list) {
      final sessions = (u['sessions'] as List<Map<String, dynamic>>);
      sessions.sort((a, b) => n(a['order']).compareTo(n(b['order'])));
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final counts = _attendanceCounts();
    final totalSessionsPassed = counts['total'] ?? 0; // sessions passed = attendance count
    final present = counts['present'] ?? 0;
    final attPct = totalSessionsPassed == 0 ? 0 : ((present / totalSessionsPassed) * 100).round();

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
            Tab(icon: Icon(Icons.payments_rounded), text: 'Payment'),
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
            _paymentTab(sessionsPassed: totalSessionsPassed),
            _attendanceTab(attPct: attPct, present: present, total: totalSessionsPassed),
            _progressTab(progPct: progPct, covered: covered, totalS: totalS),
          ],
        ),
      ),
    );
  }

  // -------------------- PAYMENT TAB --------------------

  Widget _paymentTab({required int sessionsPassed}) {
    if (_payLoading) return const Center(child: CircularProgressIndicator());

    final sum = _paymentSummary;

    final sessionsPaidTotal = _asInt(sum['sessionsPaidTotal']);
    final remindBeforeSession = _asInt(sum['remindBeforeSession']);

    final lastAmount = _asInt(sum['lastAmount']);
    final lastMethod = (sum['lastMethod'] ?? '').toString();
    final lastPaymentAt = _fmtDateFromMs(sum['lastPaymentAt']);

    final bool hasPayments = sessionsPaidTotal > 0;

    final left = sessionsPaidTotal - sessionsPassed;
    final bool overdue = hasPayments && left <= 0;
    final bool dueSoon = hasPayments && left > 0 && left <= remindBeforeSession;

    final int leftSafe = left < 0 ? 0 : left;

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
                Text('Course', style: UiK.titleText()),
                const SizedBox(height: 8),
                Text(
                  'Code: ${_courseCode.isEmpty ? '-' : _courseCode} • Class: ${_classId.isEmpty ? '-' : _classId}',
                  style: UiK.subtleText(),
                ),
                const SizedBox(height: 12),

                if (overdue || dueSoon) _dueBanner(overdue: overdue, left: leftSafe),

                _sessionsTable(
                  paid: hasPayments ? sessionsPaidTotal : null,
                  passed: sessionsPassed,
                  left: hasPayments ? leftSafe : null,
                ),

                const SizedBox(height: 12),

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
                          Icon(Icons.receipt_long_rounded, size: 18, color: UiK.actionOrange),
                          SizedBox(width: 8),
                          Text('Last payment', style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (!hasPayments)
                        Text(
                          'Your payment info is not available yet. If you already paid, contact the academy to sync it.',
                          style: UiK.subtleText(),
                        )
                      else ...[
                        _kvRow('Amount', lastAmount > 0 ? _fmtMoney(lastAmount) : '—'),
                        const SizedBox(height: 6),
                        _kvRow('Method', lastMethod.isNotEmpty ? lastMethod : '—'),
                        const SizedBox(height: 6),
                        _kvRow('Date', lastPaymentAt.isNotEmpty ? lastPaymentAt : '—'),
                      ],
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                          color: Colors.white,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.tips_and_updates_rounded, size: 18, color: UiK.actionOrange),
                                SizedBox(width: 8),
                                Text('Recommendation',
                                    style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              !hasPayments
                                  ? 'Payment is not synced yet.'
                                  : overdue
                                  ? 'Payment is due now. Please contact the academy to renew your sessions.'
                                  : dueSoon
                                  ? (leftSafe == 1
                                  ? 'Payment due in 1 session. It’s a good time to renew now.'
                                  : 'Payment due soon. It’s a good time to renew.')
                                  : 'Everything looks good. Keep attending and track your progress.',
                              style: UiK.subtleText(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sessionsTable({required int? paid, required int passed, required int? left}) {
    Widget cell(String v, {bool strong = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        child: Text(
          v,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: UiK.mainText,
            fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        color: Colors.white,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: BorderSide(color: UiK.uiBorder.withOpacity(0.65)),
            verticalInside: BorderSide(color: UiK.uiBorder.withOpacity(0.65)),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(color: UiK.primaryBlue.withOpacity(0.04)),
              children: [
                cell('Sessions paid', strong: true),
                cell('Sessions passed', strong: true),
                cell('Sessions left', strong: true),
              ],
            ),
            TableRow(
              children: [
                cell(paid == null ? '—' : '$paid'),
                cell('$passed'),
                cell(left == null ? '—' : '$left'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(String k, String v) {
    return Row(
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(color: UiK.mainText.withOpacity(0.70), fontWeight: FontWeight.w800),
          ),
        ),
        Text(
          v,
          style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }

  Widget _dueBanner({required bool overdue, required int left}) {
    final title = overdue ? 'Payment is due' : 'Payment due soon';
    final msg = overdue
        ? 'You have reached the last paid session. Please renew your payment.'
        : 'You have $left session(s) left before payment is due.';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withOpacity(0.35)),
        color: Colors.red.withOpacity(0.08),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_rounded, color: Colors.red),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: UiK.mainText)),
                const SizedBox(height: 4),
                Text(msg, style: TextStyle(color: UiK.mainText.withOpacity(0.75), fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------- ATTENDANCE TAB (unchanged) --------------------

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
                Text(
                  'Code: ${_courseCode.isEmpty ? '-' : _courseCode} • Class: ${_classId.isEmpty ? '-' : _classId}',
                  style: UiK.subtleText(),
                ),
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
              child: Text(
                'No attendance records yet.',
                style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800),
              ),
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

    final taught = (a['taught'] is Map) ? Map<String, dynamic>.from(a['taught'] as Map) : <String, dynamic>{};
    final taughtTitle = (taught['title'] ?? '').toString();
    final unitTitle = (taught['unitTitle'] ?? '').toString();

    // ✅ Homework (safe if missing)
    final hw = (a['homework'] is Map) ? Map<String, dynamic>.from(a['homework'] as Map) : <String, dynamic>{};
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
              child: Icon(isPresent ? Icons.check_rounded : Icons.close_rounded, color: isPresent ? UiK.primaryBlue : Colors.red),
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

  // -------------------- PROGRESS TAB (2-level collapsible: Unit -> Sessions) --------------------

  Widget _progressTab({required int progPct, required int covered, required int totalS}) {
    final units = _groupSyllabiByUnit();

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
                Text('Passed: $covered / $totalS sessions', style: UiK.subtleText()),
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
              child: Text(
                'Syllabus not found for this course.',
                style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800),
              ),
            ),
          )
        else
          ...units.map(_unitExpansion).toList(),
      ],
    );
  }

  Widget _unitExpansion(Map<String, dynamic> u) {
    final unitTitle = (u['unitTitle'] ?? 'Unit').toString();
    final sessions = (u['sessions'] as List<Map<String, dynamic>>);

    // Unit progress summary
    int unitTotal = sessions.length;
    int unitPassed = 0;
    for (final s in sessions) {
      final sessionId = (s['sessionId'] ?? '').toString();
      if (_coveredSessionIds.contains(sessionId)) unitPassed++;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
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
              backgroundColor: UiK.primaryBlue.withOpacity(0.08),
              child: const Icon(Icons.folder_open_rounded, color: UiK.primaryBlue),
            ),
            title: Text(
              unitTitle.isEmpty ? 'Unit' : unitTitle,
              style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              'Passed: $unitPassed / $unitTotal',
              style: UiK.subtleText(),
            ),
            children: [
              ...sessions.map(_sessionExpansion).toList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sessionExpansion(Map<String, dynamic> s) {
    final title = (s['title'] ?? '').toString();
    final sessionId = (s['sessionId'] ?? '').toString();
    final skill = (s['skillType'] ?? '').toString();
    final objective = (s['objective'] ?? '').toString();
    final content = (s['content'] ?? '').toString();

    final isPassed = _coveredSessionIds.contains(sessionId);
    final statusText = isPassed ? 'Passed' : 'Coming';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
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
              backgroundColor: (isPassed ? UiK.primaryBlue : UiK.uiBorder).withOpacity(0.10),
              child: Icon(
                isPassed ? Icons.check_circle_rounded : Icons.schedule_rounded,
                color: isPassed ? UiK.primaryBlue : UiK.primaryBlue.withOpacity(0.55),
              ),
            ),
            title: Text(
              title.isEmpty ? 'Session' : title,
              style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              [
                if (skill.isNotEmpty) skill,
                statusText,
              ].join(' • '),
              style: UiK.subtleText(),
            ),
            children: [
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
                    _detailLine('Status', statusText),
                    if (sessionId.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _detailLine('Session ID', sessionId),
                    ],
                    if (objective.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text('Objective', style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 6),
                      Text(objective, style: UiK.subtleText()),
                    ],
                    if (content.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const Text('Content', style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 6),
                      Text(content, style: UiK.subtleText()),
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
            style: TextStyle(color: UiK.mainText.withOpacity(0.70), fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }

  // -------------------- UI helper --------------------

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