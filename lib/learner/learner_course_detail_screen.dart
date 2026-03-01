// learner_course_detail_screen.dart
// ✅ FULL DROP-IN REPLACEMENT (SAFE)
// Keeps your working Firebase/loading logic intact.
// Implements your requested changes:
//
// ✅ Progress changes (per your list):
// 1) Removed filter chips (All / Passed / Coming / Homework)
// 2) Removed "Next up"
// 3) Removed "X sessions include homework"
// 4) Removed duration + skillType + any extra session meta chips (no type/id/duration shown)
// 5) Ensures bottom sheet + list content are NOT covered by phone bottom navigation bar
//    -> uses SafeArea + bottom padding with MediaQuery.viewPadding.bottom
//
// ✅ Attendance tab kept unchanged (your logic)
// ✅ Payment tab kept unchanged (your logic)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
              final unitDesc = (unit['description'] ?? '').toString();
              final unitOtherTitle = (unit['otherTitle'] ?? '').toString();
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
                    'unitDescription': unitDesc,
                    'unitOtherTitle': unitOtherTitle,
                    'order': sess['order'] ?? 0,
                    'sessionId': (sess['id'] ?? '').toString(),
                    'title': (sess['title'] ?? '').toString(),
                    'skillType': (sess['skillType'] ?? '').toString(),
                    'objective': (sess['objective'] ?? '').toString(),
                    'content': (sess['content'] ?? '').toString(),
                    'homework': (sess['homework'] ?? '').toString(),
                    'durationMinutes': sess['durationMinutes'] ?? 0,
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
    final Map<String, Map<String, dynamic>> groups = {};

    int n(dynamic v) => (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    for (final s in _syllabiFlat) {
      final unitId = (s['unitId'] ?? '').toString();
      final unitTitle = (s['unitTitle'] ?? '').toString();
      final unitDesc = (s['unitDescription'] ?? '').toString();
      final unitOrder = n(s['unitOrder']);

      final key = unitId.isNotEmpty ? unitId : 'unit_$unitOrder|$unitTitle';

      groups.putIfAbsent(key, () {
        return {
          'unitId': unitId,
          'unitTitle': unitTitle.isEmpty ? 'Unit' : unitTitle,
          'unitDescription': unitDesc,
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

  // -------------------- Homework parsing (UI-only) --------------------

  List<_HwBlock> _parseHomework(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return [];

    final lines = text.replaceAll('\r\n', '\n').split('\n');

    bool isHeader(String l) {
      final t = l.trim();
      if (t.isEmpty) return false;
      final up = t.toUpperCase();
      if (t.startsWith('📘') || t.startsWith('📤') || t.startsWith('✅')) return true;
      if (up.startsWith('PART ')) return true;
      if (up.startsWith('SUBMISSION')) return true;
      if (up.startsWith('FOCUS:')) return true;
      if (up.startsWith('UNIT ')) return true;
      if (up.startsWith('PREP')) return true;
      if (up.startsWith('POST')) return true;
      if (up.startsWith('FINAL')) return true;
      if (t.endsWith(':') && t.length <= 40) return true;
      return false;
    }

    bool isBullet(String l) => l.trimLeft().startsWith('- ') || l.trimLeft().startsWith('• ');

    final List<_HwBlock> blocks = [];
    _HwBlock current = _HwBlock(title: '', lines: []);

    void pushCurrent() {
      final cleaned = current.lines.where((x) => x.trim().isNotEmpty).toList();
      if (current.title.trim().isNotEmpty || cleaned.isNotEmpty) {
        blocks.add(_HwBlock(title: current.title.trim(), lines: cleaned));
      }
    }

    for (final l in lines) {
      final t = l.trimRight();
      if (t.trim().isEmpty) {
        current.lines.add('');
        continue;
      }

      if (isHeader(t)) {
        if (current.title.trim().isNotEmpty || current.lines.any((x) => x.trim().isNotEmpty)) {
          pushCurrent();
        }
        current = _HwBlock(title: t.trim(), lines: []);
        continue;
      }

      if (isBullet(t)) {
        final bl = t.trimLeft();
        final normalized = bl.startsWith('- ') ? bl.substring(2) : bl.startsWith('• ') ? bl.substring(2) : bl;
        current.lines.add('• $normalized');
      } else {
        current.lines.add(t.trim());
      }
    }

    pushCurrent();

    for (int i = 0; i < blocks.length; i++) {
      if (blocks[i].title.isEmpty) blocks[i] = blocks[i].copyWith(title: 'Homework');
    }

    return blocks;
  }

  // -------------------- Build --------------------

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

  // -------------------- PROGRESS TAB (CLEAN PRO UI, per your changes) --------------------

  Widget _progressTab({required int progPct, required int covered, required int totalS}) {
    final units = _groupSyllabiByUnit();
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + (bottomPad > 0 ? bottomPad : 12)),
      children: [
        _progressSummaryCard(progPct: progPct, covered: covered, totalS: totalS),
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
          ...units.map(_unitModuleCard).toList(),
      ],
    );
  }

  Widget _progressSummaryCard({required int progPct, required int covered, required int totalS}) {
    return Card(
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
            Text(
              'Code: ${_courseCode.isEmpty ? '-' : _courseCode} • Class: ${_classId.isEmpty ? '-' : _classId}',
              style: UiK.subtleText(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.insights_rounded, size: 18, color: UiK.actionOrange),
                const SizedBox(width: 8),
                const Text('Overall', style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
                const Spacer(),
                Text('$progPct%', style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
              ],
            ),
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
            Text('Passed: $covered / $totalS sessions', style: UiK.subtleText()),
          ],
        ),
      ),
    );
  }

  Widget _unitModuleCard(Map<String, dynamic> u) {
    final unitTitle = (u['unitTitle'] ?? 'Unit').toString();
    final unitDesc = (u['unitDescription'] ?? '').toString().trim();
    final sessions = (u['sessions'] as List<Map<String, dynamic>>);

    int unitTotal = sessions.length;
    int unitPassed = 0;
    for (final s in sessions) {
      final sid = (s['sessionId'] ?? '').toString();
      if (_coveredSessionIds.contains(sid)) unitPassed++;
    }

    final bool completed = unitTotal > 0 && unitPassed >= unitTotal;
    final bool started = unitPassed > 0;

    final statusText = completed ? 'Completed' : started ? 'In progress' : 'Not started';
    final statusBg = completed
        ? UiK.primaryBlue.withOpacity(0.10)
        : started
        ? UiK.actionOrange.withOpacity(0.10)
        : UiK.uiBorder.withOpacity(0.18);
    final statusFg = completed ? UiK.primaryBlue : started ? UiK.actionOrange : UiK.primaryBlue.withOpacity(0.7);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        color: Colors.white,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: CircleAvatar(
              backgroundColor: UiK.primaryBlue.withOpacity(0.08),
              child: Icon(completed ? Icons.verified_rounded : Icons.folder_open_rounded, color: UiK.primaryBlue),
            ),
            title: Text(
              unitTitle.isEmpty ? 'Unit' : unitTitle,
              style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: unitTotal == 0 ? 0 : (unitPassed / unitTotal).clamp(0, 1),
                          minHeight: 8,
                          backgroundColor: UiK.primaryBlue.withOpacity(0.08),
                          valueColor: const AlwaysStoppedAnimation(UiK.actionOrange),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$unitPassed/$unitTotal',
                      style: TextStyle(color: UiK.mainText.withOpacity(0.75), fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
                if (unitDesc.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    unitDesc,
                    style: UiK.subtleText(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _pill(
                    text: statusText,
                    icon: completed
                        ? Icons.check_circle_rounded
                        : started
                        ? Icons.timelapse_rounded
                        : Icons.hourglass_empty_rounded,
                    bg: statusBg,
                    fg: statusFg,
                    dense: true,
                  ),
                ),
              ],
            ),
            children: [
              const SizedBox(height: 8),
              ...sessions.map(_sessionLessonRow).toList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sessionLessonRow(Map<String, dynamic> s) {
    final title = (s['title'] ?? '').toString().trim();
    final sessionId = (s['sessionId'] ?? '').toString().trim();
    final objective = (s['objective'] ?? '').toString().trim();
    final hw = (s['homework'] ?? '').toString().trim();

    final passed = _coveredSessionIds.contains(sessionId);
    final statusText = passed ? 'Passed' : 'Coming';

    return InkWell(
      onTap: () => _openSessionDetailsSheet(s),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
          color: Colors.white,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: (passed ? UiK.primaryBlue : UiK.uiBorder).withOpacity(0.10),
              child: Icon(
                passed ? Icons.check_circle_rounded : Icons.schedule_rounded,
                color: passed ? UiK.primaryBlue : UiK.primaryBlue.withOpacity(0.55),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? 'Session' : title,
                    style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),

                  // Only status + homework indicator (no duration/type/id)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniChip(
                        icon: passed ? Icons.check_rounded : Icons.schedule_rounded,
                        text: statusText,
                        fg: passed ? UiK.primaryBlue : UiK.primaryBlue.withOpacity(0.75),
                        bg: passed ? UiK.primaryBlue.withOpacity(0.10) : UiK.uiBorder.withOpacity(0.18),
                      ),
                      if (hw.isNotEmpty)
                        _miniChip(
                          icon: Icons.assignment_rounded,
                          text: 'Homework',
                          fg: UiK.actionOrange,
                          bg: UiK.actionOrange.withOpacity(0.10),
                        ),
                    ],
                  ),

                  if (objective.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      objective,
                      style: TextStyle(color: UiK.mainText.withOpacity(0.70), fontWeight: FontWeight.w700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_right_rounded, color: UiK.primaryBlue.withOpacity(0.65)),
          ],
        ),
      ),
    );
  }

  // -------------------- Session details bottom sheet --------------------

  void _openSessionDetailsSheet(Map<String, dynamic> s) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SafeArea(
          top: false,
          child: DraggableScrollableSheet(
            initialChildSize: 0.84,
            minChildSize: 0.55,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              final title = (s['title'] ?? '').toString().trim();
              final unitTitle = (s['unitTitle'] ?? '').toString().trim();
              final sessionId = (s['sessionId'] ?? '').toString().trim();
              final objective = (s['objective'] ?? '').toString().trim();
              final content = (s['content'] ?? '').toString().trim();
              final hw = (s['homework'] ?? '').toString().trim();

              final passed = _coveredSessionIds.contains(sessionId);
              final statusText = passed ? 'Passed' : 'Coming';

              final hwBlocks = _parseHomework(hw);

              final bottomPad = MediaQuery.of(context).viewPadding.bottom;

              return Container(
                decoration: BoxDecoration(
                  color: UiK.appBg,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
                  border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 8),
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: UiK.uiBorder.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: controller,
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + (bottomPad > 0 ? bottomPad : 12)),
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
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      CircleAvatar(
                                        backgroundColor: (passed ? UiK.primaryBlue : UiK.uiBorder).withOpacity(0.10),
                                        child: Icon(
                                          passed ? Icons.check_circle_rounded : Icons.schedule_rounded,
                                          color: passed ? UiK.primaryBlue : UiK.primaryBlue.withOpacity(0.6),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title.isEmpty ? 'Session' : title,
                                              style: const TextStyle(
                                                color: UiK.mainText,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            if (unitTitle.isNotEmpty) Text(unitTitle, style: UiK.subtleText()),
                                            const SizedBox(height: 10),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _miniChip(
                                                  icon: passed ? Icons.check_rounded : Icons.schedule_rounded,
                                                  text: statusText,
                                                  fg: passed ? UiK.primaryBlue : UiK.primaryBlue.withOpacity(0.75),
                                                  bg: passed ? UiK.primaryBlue.withOpacity(0.10) : UiK.uiBorder.withOpacity(0.18),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 12),

                          if (objective.isNotEmpty)
                            _sectionCard(
                              icon: Icons.flag_rounded,
                              title: 'Learning Outcome',
                              child: Text(objective, style: UiK.subtleText()),
                            ),

                          if (objective.isNotEmpty) const SizedBox(height: 12),

                          _sectionCard(
                            icon: Icons.assignment_rounded,
                            title: 'Homework',
                            accent: UiK.actionOrange,
                            child: hw.isEmpty
                                ? Text('No homework for this session.', style: UiK.subtleText())
                                : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Follow the tasks below and submit as instructed.',
                                        style: UiK.subtleText(),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Copy homework',
                                      icon: const Icon(Icons.copy_rounded, color: UiK.primaryBlue),
                                      onPressed: () async {
                                        await Clipboard.setData(ClipboardData(text: hw));
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Homework copied')),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                ..._buildHomeworkBrief(hwBlocks),
                              ],
                            ),
                          ),

                          const SizedBox(height: 12),

                          if (content.isNotEmpty)
                            _sectionCard(
                              icon: Icons.menu_book_rounded,
                              title: 'Session Content',
                              child: _collapsibleText(content),
                            ),
                        ],
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

  List<Widget> _buildHomeworkBrief(List<_HwBlock> blocks) {
    if (blocks.isEmpty) return [Text('Homework details are not available.', style: UiK.subtleText())];

    bool looksLikeSubmission(String t) {
      final up = t.toUpperCase();
      return up.contains('SUBMISSION') || t.startsWith('📤') || up.contains('UPLOAD');
    }

    final widgets = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final title = b.title.trim();
      final lines = b.lines;
      final submission = looksLikeSubmission(title);

      widgets.add(
        Container(
          width: double.infinity,
          margin: EdgeInsets.only(bottom: i == blocks.length - 1 ? 0 : 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
            color: submission ? UiK.actionOrange.withOpacity(0.07) : UiK.primaryBlue.withOpacity(0.04),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty) ...[
                Row(
                  children: [
                    Icon(
                      submission ? Icons.upload_rounded : Icons.description_rounded,
                      size: 18,
                      color: submission ? UiK.actionOrange : UiK.primaryBlue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              ..._renderHwLines(lines),
            ],
          ),
        ),
      );
    }

    return widgets;
  }

  List<Widget> _renderHwLines(List<String> lines) {
    final out = <Widget>[];
    for (final l in lines) {
      final t = l.trim();
      if (t.isEmpty) {
        out.add(const SizedBox(height: 8));
        continue;
      }

      final isBullet = t.startsWith('• ');
      if (isBullet) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ', style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
                Expanded(child: Text(t.substring(2), style: UiK.subtleText())),
              ],
            ),
          ),
        );
      } else {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(t, style: UiK.subtleText()),
          ),
        );
      }
    }
    return out;
  }

  Widget _collapsibleText(String text) {
    return _ReadMore(
      text: text,
      collapsedLines: 6,
      style: UiK.subtleText(),
      linkStyle: const TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required Widget child,
    Color? accent,
  }) {
    final a = accent ?? UiK.primaryBlue;
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: a),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _miniChip({
    required IconData icon,
    required String text,
    Color? fg,
    Color? bg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        color: bg ?? UiK.primaryBlue.withOpacity(0.05),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg ?? UiK.primaryBlue),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required String text,
    required IconData icon,
    required Color bg,
    required Color fg,
    bool dense = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12, vertical: dense ? 6 : 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: bg,
        border: Border.all(color: UiK.uiBorder.withOpacity(0.70)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 14 : 16, color: fg),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900, fontSize: dense ? 12 : 13),
          ),
        ],
      ),
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

// -------------------- Small UI model + ReadMore widget --------------------

class _HwBlock {
  final String title;
  final List<String> lines;

  _HwBlock({required this.title, required this.lines});

  _HwBlock copyWith({String? title, List<String>? lines}) {
    return _HwBlock(title: title ?? this.title, lines: lines ?? this.lines);
  }
}

class _ReadMore extends StatefulWidget {
  final String text;
  final int collapsedLines;
  final TextStyle style;
  final TextStyle linkStyle;

  const _ReadMore({
    required this.text,
    this.collapsedLines = 6,
    required this.style,
    required this.linkStyle,
  });

  @override
  State<_ReadMore> createState() => _ReadMoreState();
}

class _ReadMoreState extends State<_ReadMore> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final span = TextSpan(text: widget.text, style: widget.style);
        final tp = TextPainter(
          text: span,
          maxLines: widget.collapsedLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: c.maxWidth);

        final overflow = tp.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: _expanded ? null : widget.collapsedLines,
              overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
            if (overflow) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Show less' : 'Show more', style: widget.linkStyle),
              ),
            ],
          ],
        );
      },
    );
  }
}