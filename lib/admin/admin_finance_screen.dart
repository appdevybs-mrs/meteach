import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_finance_ledger_screen.dart';
import '../shared/finance_allocations.dart';
import '../shared/admin_web_layout.dart';
import '../shared/study_variant.dart';

class AdminFinanceScreen extends StatefulWidget {
  const AdminFinanceScreen({super.key});

  static const primary = Color(0xFF1A2B48);
  static const appBg = Color(0xFFF4F7F9);
  static const waiting = Color(0xFFF0A526);
  static const tbpaid = Color(0xFF3666D8);
  static const done = Color(0xFF22945A);

  @override
  State<AdminFinanceScreen> createState() => _AdminFinanceScreenState();
}

class _AdminFinanceScreenState extends State<AdminFinanceScreen> {
  static const _pin = '0000';
  static const _prefsFromMsKey = 'admin_finance_from_ms';
  static const _prefsToMsKey = 'admin_finance_to_ms';

  final DatabaseReference _paymentsRef = FirebaseDatabase.instance.ref(
    'payments',
  );
  final DatabaseReference _classesRef = FirebaseDatabase.instance.ref(
    'classes',
  );
  final DatabaseReference _usersRef = FirebaseDatabase.instance.ref('users');
  final DatabaseReference _financeDoneRef = FirebaseDatabase.instance.ref(
    'finance_done_marks',
  );
  final DatabaseReference _financePayoutPeriodsRef = FirebaseDatabase.instance
      .ref('finance_payout_periods');
  final DatabaseReference _financePaymentMetaRef = FirebaseDatabase.instance
      .ref('finance_payment_meta');

  bool _unlocked = false;
  bool _loadingFilter = true;
  DateTime? _fromDate;
  DateTime? _toDate;
  final Set<String> _clearingTeacherScopes = <String>{};

  @override
  void initState() {
    super.initState();
    _loadSavedFilter();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _askPin();
    });
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final raw = v.toString().trim();
    if (raw.isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9-]'), '');
    if (cleaned.isEmpty || cleaned == '-') return 0;
    return int.tryParse(cleaned) ?? 0;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _ymd(DateTime d) {
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static String _todayYmd() => _ymd(DateTime.now());

  static int _ymdToMs(String ymd) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(ymd.trim());
    if (m == null) return 0;
    final year = int.tryParse(m.group(1) ?? '') ?? 0;
    final month = int.tryParse(m.group(2) ?? '') ?? 0;
    final day = int.tryParse(m.group(3) ?? '') ?? 0;
    if (year <= 0 || month <= 0 || day <= 0) return 0;
    return DateTime(year, month, day).millisecondsSinceEpoch;
  }

  static String _previousDayYmd(String ymd) {
    final ms = _ymdToMs(ymd);
    if (ms <= 0) return ymd;
    return _ymd(
      DateTime.fromMillisecondsSinceEpoch(ms).subtract(const Duration(days: 1)),
    );
  }

  static String _financePeriodLabel({
    required String startDate,
    required String endDate,
  }) {
    final start = startDate.trim();
    final end = endDate.trim();
    if (start.isEmpty) return 'No finance cycle';
    return end.isEmpty ? 'From $start To ...' : 'From $start To $end';
  }

  static String _normalizeStatus(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'done' || s == 'tbpaid' || s == 'split') return s;
    return 'tbpaid';
  }

  static String _normalizeMethod(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'cash') return 'cash';
    if (s == 'ccp') return 'ccp';
    return 'unspecified';
  }

  static int _normalizePercent(dynamic v) {
    final p = _asInt(v);
    if (p <= 0) return 100;
    if (p > 100) return 100;
    return p;
  }

  static int _percentOf(int amount, int percent) {
    if (amount <= 0) return 0;
    return ((amount * percent) / 100).round();
  }

  static _MethodTotals _methodTotalsZero() {
    return const _MethodTotals(cash: 0, ccp: 0, unspecified: 0);
  }

  static _MethodTotals _addToMethodTotals({
    required _MethodTotals current,
    required String method,
    required int amount,
  }) {
    if (method == 'cash') {
      return _MethodTotals(
        cash: current.cash + amount,
        ccp: current.ccp,
        unspecified: current.unspecified,
      );
    }
    if (method == 'ccp') {
      return _MethodTotals(
        cash: current.cash,
        ccp: current.ccp + amount,
        unspecified: current.unspecified,
      );
    }
    return _MethodTotals(
      cash: current.cash,
      ccp: current.ccp,
      unspecified: current.unspecified + amount,
    );
  }

  static String _teacherNameFrom(Map<String, dynamic> p) {
    final t1 = (p['teacherName'] ?? '').toString().trim();
    if (t1.isNotEmpty) return t1;
    final t2 = (p['teacher_name'] ?? '').toString().trim();
    if (t2.isNotEmpty) return t2;
    final t3 = (p['teacher'] ?? '').toString().trim();
    if (t3.isNotEmpty) return t3;

    final variantKey = normalizeVariantKey(
      (p['variantKey'] ?? p['variant'] ?? p['deliveryKey'] ?? '').toString(),
      fallback: 'inclass',
    );
    if (variantKey == 'flexible') return 'Flexible';
    if (variantKey == 'recorded') return 'Recorded';

    return 'Unassigned';
  }

  static String _variantKeyFrom(Map<String, dynamic> row) {
    return normalizeVariantKey(
      (row['variantKey'] ?? row['variant'] ?? row['deliveryKey'] ?? '')
          .toString(),
      fallback: 'inclass',
    );
  }

  static String _teacherIdFrom(Map<String, dynamic> p) {
    final t = (p['teacherId'] ?? '').toString().trim();
    return t;
  }

  static String _slug(String s) {
    final cleaned = s.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    final squashed = cleaned.replaceAll(RegExp(r'_+'), '_');
    return squashed.replaceAll(RegExp(r'^_|_$'), '');
  }

  static String _teacherScopeKey({
    required String teacherId,
    required String teacherName,
  }) {
    final uid = teacherId.trim();
    if (uid.isNotEmpty) return uid;
    final s = _slug(teacherName);
    return s.isEmpty ? 'unassigned' : 'name_$s';
  }

  static Map<String, int> _rosterLearnersCountByTeacherScope(dynamic raw) {
    final out = <String, Set<String>>{};
    if (raw is! Map) return const {};
    final classes = Map<dynamic, dynamic>.from(raw);
    for (final e in classes.entries) {
      final clsRaw = e.value;
      if (clsRaw is! Map) continue;
      final cls = Map<dynamic, dynamic>.from(clsRaw);

      String teacherId = '';
      final instCur = cls['instructor_current'];
      if (instCur is Map) {
        teacherId = (instCur['uid'] ?? '').toString().trim();
      }
      final teacherName = (cls['instructor'] ?? '').toString().trim();
      final scope = _teacherScopeKey(
        teacherId: teacherId,
        teacherName: teacherName,
      );

      final learnersRaw = cls['learners'];
      if (learnersRaw is! Map) continue;
      final learners = Map<dynamic, dynamic>.from(learnersRaw);
      for (final l in learners.entries) {
        final uid = l.key.toString().trim();
        if (uid.isEmpty) continue;
        out.putIfAbsent(scope, () => <String>{}).add(uid);
      }
    }
    final counts = <String, int>{};
    for (final e in out.entries) {
      counts[e.key] = e.value.length;
    }
    return counts;
  }

  static String _scopeSessionKey({
    required String scope,
    required String uid,
    required String courseId,
  }) {
    return '${scope.trim()}::${uid.trim()}::${courseId.trim()}';
  }

  static int _parseTotalSessions(String duration) {
    final m = RegExp(
      r'(\d+)\s*sessions',
      caseSensitive: false,
    ).firstMatch(duration);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  }

  static int _classTotalSessions(Map<dynamic, dynamic> cls) {
    int from(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString().trim()) ?? 0;
    }

    final scheduleRaw = cls['schedule'];
    if (scheduleRaw is Map) {
      final schedule = Map<dynamic, dynamic>.from(scheduleRaw);
      final scheduleTotal = from(schedule['meetingsCount']);
      if (scheduleTotal > 0) return scheduleTotal;
      final totalMeetings = from(schedule['totalMeetings']);
      if (totalMeetings > 0) return totalMeetings;
      final sessionsCount = from(schedule['sessionsCount']);
      if (sessionsCount > 0) return sessionsCount;
    }

    final fromCourseDuration = _parseTotalSessions(
      (cls['course_duration'] ?? '').toString().trim(),
    );
    if (fromCourseDuration > 0) return fromCourseDuration;
    return _parseTotalSessions((cls['duration'] ?? '').toString().trim());
  }

  static Map<String, _SessionCounts> _attendanceByTeacherScope(dynamic raw) {
    final out = <String, _SessionCounts>{};
    if (raw is! Map) return out;
    final classes = Map<dynamic, dynamic>.from(raw);
    for (final e in classes.entries) {
      final clsRaw = e.value;
      if (clsRaw is! Map) continue;
      final cls = Map<dynamic, dynamic>.from(clsRaw);

      var teacherId = '';
      final instCur = cls['instructor_current'];
      if (instCur is Map) {
        teacherId = (instCur['uid'] ?? '').toString().trim();
      }
      final teacherName = (cls['instructor'] ?? '').toString().trim();
      final scope = _teacherScopeKey(
        teacherId: teacherId,
        teacherName: teacherName,
      );

      final courseId = (cls['course_id'] ?? '').toString().trim();
      if (courseId.isEmpty) continue;

      final attendanceRaw = cls['attendance'];
      if (attendanceRaw is! Map) continue;
      final attendance = Map<dynamic, dynamic>.from(attendanceRaw);
      for (final recEntry in attendance.entries) {
        final recRaw = recEntry.value;
        if (recRaw is! Map) continue;
        final rec = Map<dynamic, dynamic>.from(recRaw);

        final present = (rec['present'] is Map)
            ? Map<dynamic, dynamic>.from(rec['present'] as Map)
            : <dynamic, dynamic>{};
        final absent = (rec['absent'] is Map)
            ? Map<dynamic, dynamic>.from(rec['absent'] as Map)
            : <dynamic, dynamic>{};
        final allUids = <String>{
          ...present.keys.map((k) => k.toString().trim()),
          ...absent.keys.map((k) => k.toString().trim()),
        }..removeWhere((uid) => uid.isEmpty);

        for (final uid in allUids) {
          final key = _scopeSessionKey(
            scope: scope,
            uid: uid,
            courseId: courseId,
          );
          final cur = out[key] ?? const _SessionCounts();
          out[key] = _SessionCounts(held: cur.held + 1, present: cur.present);
        }

        for (final uid in present.keys.map((k) => k.toString().trim())) {
          if (uid.isEmpty) continue;
          final key = _scopeSessionKey(
            scope: scope,
            uid: uid,
            courseId: courseId,
          );
          final cur = out[key] ?? const _SessionCounts();
          out[key] = _SessionCounts(held: cur.held, present: cur.present + 1);
        }
      }
    }
    return out;
  }

  static Map<String, int> _courseTotalsByTeacherScope(dynamic raw) {
    final out = <String, int>{};
    if (raw is! Map) return out;
    final classes = Map<dynamic, dynamic>.from(raw);
    for (final e in classes.entries) {
      final clsRaw = e.value;
      if (clsRaw is! Map) continue;
      final cls = Map<dynamic, dynamic>.from(clsRaw);

      var teacherId = '';
      final instCur = cls['instructor_current'];
      if (instCur is Map) {
        teacherId = (instCur['uid'] ?? '').toString().trim();
      }
      final teacherName = (cls['instructor'] ?? '').toString().trim();
      final scope = _teacherScopeKey(
        teacherId: teacherId,
        teacherName: teacherName,
      );

      final courseId = (cls['course_id'] ?? '').toString().trim();
      if (courseId.isEmpty) continue;
      final totalSessions = _classTotalSessions(cls);

      final learnersRaw = cls['learners'];
      if (learnersRaw is! Map) continue;
      final learners = Map<dynamic, dynamic>.from(learnersRaw);
      for (final l in learners.entries) {
        final uid = l.key.toString().trim();
        if (uid.isEmpty) continue;
        final key = _scopeSessionKey(
          scope: scope,
          uid: uid,
          courseId: courseId,
        );
        final current = out[key] ?? 0;
        if (totalSessions > current) out[key] = totalSessions;
      }
    }
    return out;
  }

  static String _learnerNameFrom(Map<String, dynamic> p) {
    final n1 = (p['learner_name'] ?? '').toString().trim();
    if (n1.isNotEmpty) return n1;
    final n2 = (p['learnerName'] ?? '').toString().trim();
    if (n2.isNotEmpty) return n2;
    final n3 = (p['name'] ?? '').toString().trim();
    if (n3.isNotEmpty) return n3;
    return '(Unknown learner)';
  }

  static _FinanceAmounts _amountsFrom(Map<String, dynamic> p) {
    final amount = _asInt(p['amount']);
    final status = _normalizeStatus(p['financePayoutStatus']);

    if (status != 'split') {
      return _FinanceAmounts(
        amount: amount,
        status: status,
        splitPaidStatus: null,
        payoutAmount: amount,
        waitingAmount: 0,
      );
    }

    final splitPaid = _asInt(p['financeSplitPaidAmount']);
    var splitWaiting = _asInt(p['financeSplitWaitingAmount']);
    if (splitWaiting <= 0) splitWaiting = amount - splitPaid;
    final paid = splitPaid.clamp(0, amount);
    final waiting = splitWaiting.clamp(0, amount - paid);
    final splitPaidStatus =
        _normalizeStatus(p['financeSplitPaidStatus']) == 'done'
        ? 'done'
        : 'tbpaid';

    return _FinanceAmounts(
      amount: amount,
      status: 'split',
      splitPaidStatus: splitPaidStatus,
      payoutAmount: paid,
      waitingAmount: waiting,
    );
  }

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime _endOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

  bool _inRangeMs(int paidAtMs) {
    if (paidAtMs <= 0) return false;
    final fromMs = _fromDate == null
        ? 0
        : _startOfDay(_fromDate!).millisecondsSinceEpoch;
    final toMs = _toDate == null
        ? 0
        : _endOfDay(_toDate!).millisecondsSinceEpoch;
    if (fromMs > 0 && paidAtMs < fromMs) return false;
    if (toMs > 0 && paidAtMs > toMs) return false;
    return true;
  }

  String _money(int amount) {
    final neg = amount < 0;
    final s = (neg ? -amount : amount).toString();
    final out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final posFromEnd = s.length - i;
      out.write(s[i]);
      if (posFromEnd > 1 && posFromEnd % 3 == 1) out.write(' ');
    }
    return '${neg ? '-' : ''}${out.toString()} DA';
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _loadSavedFilter() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fromMs = prefs.getInt(_prefsFromMsKey) ?? 0;
      final toMs = prefs.getInt(_prefsToMsKey) ?? 0;
      if (!mounted) return;
      setState(() {
        _fromDate = fromMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(fromMs)
            : null;
        _toDate = toMs > 0 ? DateTime.fromMillisecondsSinceEpoch(toMs) : null;
        _loadingFilter = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingFilter = false);
    }
  }

  Future<void> _persistFilter() async {
    final prefs = await SharedPreferences.getInstance();
    if (_fromDate == null) {
      await prefs.remove(_prefsFromMsKey);
    } else {
      await prefs.setInt(
        _prefsFromMsKey,
        _startOfDay(_fromDate!).millisecondsSinceEpoch,
      );
    }

    if (_toDate == null) {
      await prefs.remove(_prefsToMsKey);
    } else {
      await prefs.setInt(
        _prefsToMsKey,
        _endOfDay(_toDate!).millisecondsSinceEpoch,
      );
    }
  }

  Future<void> _pickFromDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate ?? _toDate ?? now,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Pick from date',
    );
    if (picked == null) return;
    setState(() {
      _fromDate = picked;
      if (_toDate != null &&
          _startOfDay(_fromDate!).isAfter(_endOfDay(_toDate!))) {
        _toDate = picked;
      }
    });
    await _persistFilter();
  }

  Future<void> _pickToDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate ?? _fromDate ?? now,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Pick to date',
    );
    if (picked == null) return;
    setState(() {
      _toDate = picked;
      if (_fromDate != null &&
          _startOfDay(_toDate!).isBefore(_startOfDay(_fromDate!))) {
        _fromDate = picked;
      }
    });
    await _persistFilter();
  }

  Future<void> _clearFilter() async {
    setState(() {
      _fromDate = null;
      _toDate = null;
    });
    await _persistFilter();
  }

  Future<void> _askPin() async {
    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return AlertDialog(
          title: const Text('Finance access'),
          content: TextField(
            controller: passCtrl,
            obscureText: true,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (_) =>
                Navigator.of(dialogCtx).pop(passCtrl.text.trim() == _pin),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogCtx).pop(passCtrl.text.trim() == _pin),
              child: const Text('Unlock'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;
    if (ok == true) {
      setState(() => _unlocked = true);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Wrong password or access cancelled.')),
    );
  }

  Future<void> _setPaymentMethod({
    required String paymentId,
    required String method,
  }) async {
    final normalized = _normalizeMethod(method);
    await _paymentsRef.child(paymentId).update({
      'financeMethod': normalized,
      'financePushedAt': null,
      'financePushedBy': null,
      'financePushedStatus': null,
      'financeUpdatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _clearTeacherCardSetup(_TeacherCardData card) async {
    final scope = card.teacherScopeKey;
    if (_clearingTeacherScopes.contains(scope)) return;
    final paymentIds = card.payments
        .map((row) => (row['paymentId'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (paymentIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No payment rows to clear for ${card.teacherName}.'),
        ),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Clear teacher setup'),
        content: Text(
          'Clear finance setup for ${paymentIds.length} payment item${paymentIds.length == 1 ? '' : 's'} for ${card.teacherName}? This will unpush and reset method, status, split, share, and allocations.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Clear setup'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _clearingTeacherScopes.add(scope));
    try {
      final patch = <String, dynamic>{
        'financeMethod': '',
        'financePayoutStatus': null,
        'financeSplitPaidAmount': null,
        'financeSplitWaitingAmount': null,
        'financeSplitPaidStatus': null,
        'financeTeacherPercent': null,
        'financeTeacherGross': null,
        'financeTeacherNet': null,
        'financeSchoolNet': null,
        'financeAllocations': null,
        'financeTeacherShareUnlocked': null,
        'financePushedAt': null,
        'financePushedBy': null,
        'financePushedStatus': null,
        'financePeriodId': null,
        'financePeriodStartDate': null,
        'financePeriodStartAtMs': null,
        'financePeriodEndDate': null,
        'financePeriodEndAtMs': null,
        'financeUpdatedAt': ServerValue.timestamp,
      };
      for (final paymentId in paymentIds) {
        await _paymentsRef.child(paymentId).update(patch);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cleared setup for ${paymentIds.length} item${paymentIds.length == 1 ? '' : 's'} for ${card.teacherName}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not clear setup: $e')));
    } finally {
      if (mounted) {
        setState(() => _clearingTeacherScopes.remove(scope));
      }
    }
  }

  void _openLedger() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AdminFinanceLedgerScreen()));
  }

  Future<String?> _pickFinancePeriodStartDate({
    required String initialYmd,
  }) async {
    final initialMs = _ymdToMs(initialYmd);
    final initialDate = initialMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(initialMs)
        : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2018, 1, 1),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      helpText: 'Pick finance cycle start date',
    );
    if (picked == null) return null;
    return _ymd(picked);
  }

  Future<void> _openFinanceFreshStartDialog({
    required _FinancePayoutPeriodRecord? activePeriod,
  }) async {
    String startDateYmd = _todayYmd();
    bool isSaving = false;
    bool saveLocked = false;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setD) {
          return AlertDialog(
            title: const Text('Finance fresh start'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (activePeriod != null) ...[
                    Text(
                      'Current cycle: ${activePeriod.displayLabel}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                  ],
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_rounded),
                    title: const Text('New cycle start date'),
                    subtitle: Text(startDateYmd),
                    onTap: () async {
                      final picked = await _pickFinancePeriodStartDate(
                        initialYmd: startDateYmd,
                      );
                      if (picked == null) return;
                      startDateYmd = picked;
                      setD(() {});
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving
                    ? null
                    : () => Navigator.of(dialogCtx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        if (saveLocked) return;
                        saveLocked = true;
                        final startAtMs = _ymdToMs(startDateYmd);
                        if (startAtMs <= 0) {
                          saveLocked = false;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Pick a valid start date.'),
                            ),
                          );
                          return;
                        }
                        if (activePeriod != null &&
                            startAtMs <= activePeriod.startAtMs) {
                          saveLocked = false;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'New finance cycle must start after the current one.',
                              ),
                            ),
                          );
                          return;
                        }

                        setD(() => isSaving = true);
                        try {
                          final periodsSnap = await _financePayoutPeriodsRef
                              .get();
                          final rootUpdate = <String, Object?>{};
                          if (periodsSnap.value is Map) {
                            final existing = periodsSnap.value as Map;
                            existing.forEach((k, value) {
                              if (value is! Map) return;
                              final rec = value.map(
                                (kk, vv) => MapEntry(kk.toString(), vv),
                              );
                              if (rec['isActive'] == true) {
                                rootUpdate['finance_payout_periods/${k.toString()}/isActive'] =
                                    false;
                              }
                            });
                          }
                          if (activePeriod != null) {
                            final endDate = _previousDayYmd(startDateYmd);
                            final endAtMs = _ymdToMs(endDate);
                            rootUpdate['finance_payout_periods/${activePeriod.id}/endDate'] =
                                endDate;
                            rootUpdate['finance_payout_periods/${activePeriod.id}/endAtMs'] =
                                endAtMs;
                            rootUpdate['finance_payout_periods/${activePeriod.id}/updatedAt'] =
                                ServerValue.timestamp;
                          }

                          final newRef = _financePayoutPeriodsRef.push();
                          final periodId = newRef.key;
                          if (periodId == null || periodId.trim().isEmpty) {
                            throw Exception('Could not create finance cycle.');
                          }
                          rootUpdate['finance_payout_periods/$periodId'] = {
                            'id': periodId,
                            'startDate': startDateYmd,
                            'startAtMs': startAtMs,
                            'endDate': '',
                            'endAtMs': 0,
                            'isActive': true,
                            'createdAt': ServerValue.timestamp,
                            'updatedAt': ServerValue.timestamp,
                          };
                          await FirebaseDatabase.instance.ref().update(
                            rootUpdate,
                          );
                          if (!mounted || !dialogCtx.mounted) return;
                          Navigator.of(dialogCtx).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Finance cycle started.'),
                            ),
                          );
                        } catch (e) {
                          saveLocked = false;
                          setD(() => isSaving = false);
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Could not start finance cycle: $e',
                              ),
                            ),
                          );
                        }
                      },
                child: Text(isSaving ? 'Saving...' : 'Start'),
              ),
            ],
          );
        },
      ),
    );
  }

  static int _schoolNetFromPayment(Map<String, dynamic> p) {
    if (p['isFinanceAllocation'] == true) {
      if (_asInt(p['financePushedAt']) <= 0) return 0;
      final saved = _asInt(p['financeSchoolNet']);
      return saved < 0 ? 0 : saved;
    }
    if (p['financeAllocations'] is Map) {
      var total = 0;
      for (final allocation in financeAllocationsFromPayment(p)) {
        if (allocation.pushedAt <= 0) continue;
        total += allocation.schoolNet;
      }
      return total;
    }
    final pushed = _asInt(p['financePushedAt']) > 0;
    if (!pushed) return 0;

    final teacherLabel =
        (p['teacherName'] ?? p['teacher_name'] ?? p['teacher'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    final unlocked = p['financeTeacherShareUnlocked'] == true;
    final schoolOnlyType =
        teacherLabel == 'service' || teacherLabel == 'waiting';
    if (schoolOnlyType && !unlocked) {
      final gross = _amountsFrom(p).payoutAmount;
      return gross < 0 ? 0 : gross;
    }

    final saved = _asInt(p['financeSchoolNet']);
    if (saved > 0) return saved;

    var gross = _asInt(p['financeTeacherGross']);
    if (gross <= 0) {
      gross = _amountsFrom(p).payoutAmount;
    }
    var teacherNet = _asInt(p['financeTeacherNet']);
    if (teacherNet <= 0 && gross > 0) {
      teacherNet = _percentOf(
        gross,
        _normalizePercent(p['financeTeacherPercent']),
      );
    }
    final net = gross - teacherNet;
    return net < 0 ? 0 : net;
  }

  static int _teacherNetFromPayment(Map<String, dynamic> p) {
    if (p['isFinanceAllocation'] == true) {
      if (_asInt(p['financePushedAt']) <= 0) return 0;
      final saved = _asInt(p['financeTeacherNet']);
      return saved < 0 ? 0 : saved;
    }
    if (p['financeAllocations'] is Map) {
      var total = 0;
      for (final allocation in financeAllocationsFromPayment(p)) {
        if (allocation.pushedAt <= 0) continue;
        total += allocation.teacherNet;
      }
      return total;
    }
    final pushed = _asInt(p['financePushedAt']) > 0;
    if (!pushed) return 0;

    final teacherLabel =
        (p['teacherName'] ?? p['teacher_name'] ?? p['teacher'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    final unlocked = p['financeTeacherShareUnlocked'] == true;
    final schoolOnlyType =
        teacherLabel == 'service' || teacherLabel == 'waiting';
    if (schoolOnlyType && !unlocked) {
      return 0;
    }

    final hasSavedTeacherNet =
        p.containsKey('financeTeacherNet') && p['financeTeacherNet'] != null;
    if (hasSavedTeacherNet) {
      final saved = _asInt(p['financeTeacherNet']);
      return saved < 0 ? 0 : saved;
    }

    var gross = _asInt(p['financeTeacherGross']);
    if (gross <= 0) {
      gross = _amountsFrom(p).payoutAmount;
    }

    final rawPercent = p['financeTeacherPercent'];
    int percent;
    if (rawPercent == null || rawPercent.toString().trim().isEmpty) {
      percent = 100;
    } else {
      percent = _asInt(rawPercent);
      if (percent < 0) percent = 0;
      if (percent > 100) percent = 100;
    }

    final net = _percentOf(gross, percent);
    return net < 0 ? 0 : net;
  }

  static _EffectiveFinanceAmounts _effectiveFinanceFromPayment(
    Map<String, dynamic> p,
  ) {
    final status = _normalizeStatus(p['financePayoutStatus']);
    final method = _normalizeMethod(p['financeMethod']);
    if (status == 'done') {
      return _EffectiveFinanceAmounts(
        originalAmount: 0,
        teacherNet: 0,
        schoolNet: 0,
        waitingAmount: 0,
        method: method,
      );
    }
    final alloc = _amountsFrom(p);
    return _EffectiveFinanceAmounts(
      originalAmount: _asInt(p['amount']),
      teacherNet: _teacherNetFromPayment(p),
      schoolNet: _schoolNetFromPayment(p),
      waitingAmount: alloc.waitingAmount,
      method: method,
    );
  }

  void _openWaitingDetailsDialog(List<Map<String, dynamic>> rows) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: const Text('Pending (All Teachers)'),
          content: SizedBox(
            width: 760,
            child: rows.isEmpty
                ? const Center(child: Text('No waiting items in this range.'))
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                    itemBuilder: (_, i) {
                      final p = rows[i];
                      final alloc = _amountsFrom(p);
                      final learner = _learnerNameFrom(p);
                      final teacher = _teacherNameFrom(p);
                      final amount = _asInt(p['amount']);
                      final method = _normalizeMethod(p['financeMethod']);
                      final paidAt = _asInt(p['paidAt']);
                      final date = paidAt > 0
                          ? _fmtDate(
                              DateTime.fromMillisecondsSinceEpoch(paidAt),
                            )
                          : '—';
                      final paidPartLabel =
                          (alloc.splitPaidStatus ?? alloc.status).toUpperCase();
                      final paymentId = (p['paymentId'] ?? '')
                          .toString()
                          .trim();

                      return ListTile(
                        dense: true,
                        title: Text(
                          learner,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: AdminFinanceScreen.primary,
                          ),
                        ),
                        subtitle: Text(
                          'Teacher: $teacher · Date: $date · Method: ${method.toUpperCase()}\nPayment: ${_money(amount)} · ${paidPartLabel == 'DONE' ? 'Received' : 'Ready'}: ${_money(alloc.payoutAmount)} · Pending: ${_money(alloc.waitingAmount)}\nID: ${paymentId.isEmpty ? '-' : paymentId}',
                          style: const TextStyle(
                            color: AdminFinanceScreen.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _openSchoolDetailsDialog(List<Map<String, dynamic>> rows) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        var totalTeacherIncome = 0;
        final byTeacher = <String, Map<String, int>>{};
        for (final row in rows) {
          final teacher = _teacherNameFrom(row);
          final schoolNet = _schoolNetFromPayment(row);
          final teacherNet = _teacherNetFromPayment(row);
          final teacherPercent = _normalizePercent(
            row['financeTeacherPercent'],
          );
          totalTeacherIncome += teacherNet;
          final item = byTeacher.putIfAbsent(
            teacher,
            () => {
              'schoolNet': 0,
              'teacherNet': 0,
              'schoolPercentTotal': 0,
              'count': 0,
            },
          );
          item['schoolNet'] = (item['schoolNet'] ?? 0) + schoolNet;
          item['teacherNet'] = (item['teacherNet'] ?? 0) + teacherNet;
          item['schoolPercentTotal'] =
              (item['schoolPercentTotal'] ?? 0) + (100 - teacherPercent);
          item['count'] = (item['count'] ?? 0) + 1;
        }
        final teacherLines = byTeacher.entries.map((entry) {
          final count = (entry.value['count'] ?? 1).clamp(1, 999999);
          final avgSchoolPercent =
              (((entry.value['schoolPercentTotal'] ?? 0) / count) as num)
                  .round();
          return '${entry.key}: ${_money(entry.value['schoolNet'] ?? 0)} school · ${_money(entry.value['teacherNet'] ?? 0)} teachers · ~$avgSchoolPercent% school';
        }).toList()..sort();
        return AlertDialog(
          title: const Text('School (Pushed Only)'),
          content: SizedBox(
            width: 760,
            child: rows.isEmpty
                ? const Center(
                    child: Text('No pushed school items in this range.'),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length + 1,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: Colors.black.withValues(alpha: 0.08),
                    ),
                    itemBuilder: (_, i) {
                      if (i == 0) {
                        return ListTile(
                          dense: true,
                          title: Text(
                            'Teachers paid total: ${_money(totalTeacherIncome)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: AdminFinanceScreen.primary,
                            ),
                          ),
                          subtitle: Text(
                            teacherLines.join('\n'),
                            style: const TextStyle(
                              color: AdminFinanceScreen.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          isThreeLine: teacherLines.length > 1,
                        );
                      }
                      final p = rows[i - 1];
                      final learner = _learnerNameFrom(p);
                      final teacher = _teacherNameFrom(p);
                      final method = _normalizeMethod(p['financeMethod']);
                      final percent = _normalizePercent(
                        p['financeTeacherPercent'],
                      );
                      final gross = _asInt(p['financeTeacherGross']) > 0
                          ? _asInt(p['financeTeacherGross'])
                          : _asInt(p['amount']);
                      final teacherNet = _asInt(p['financeTeacherNet']) > 0
                          ? _asInt(p['financeTeacherNet'])
                          : _percentOf(gross, percent);
                      final schoolNet = _schoolNetFromPayment(p);
                      final pushedStatus = (p['financePushedStatus'] ?? '')
                          .toString()
                          .trim()
                          .toUpperCase();
                      final confirmed = (p['teacherConfirmed'] == true)
                          ? 'YES'
                          : 'NO';
                      final paidAt = _asInt(p['paidAt']);
                      final date = paidAt > 0
                          ? _fmtDate(
                              DateTime.fromMillisecondsSinceEpoch(paidAt),
                            )
                          : '—';

                      return ListTile(
                        dense: true,
                        title: Text(
                          learner,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: AdminFinanceScreen.primary,
                          ),
                        ),
                        subtitle: Text(
                          'Teacher: $teacher · Date: $date · Method: ${method.toUpperCase()}\nGross: ${_money(gross)} · Net: ${_money(teacherNet)} · School: ${_money(schoolNet)} · Share: $percent%\nSync: ${pushedStatus.isEmpty ? '-' : pushedStatus} · Received: $confirmed',
                          style: const TextStyle(
                            color: AdminFinanceScreen.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) {
      return Scaffold(
        backgroundColor: AdminFinanceScreen.appBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          iconTheme: const IconThemeData(color: AdminFinanceScreen.primary),
          actions: [
            IconButton(
              tooltip: 'Ledger notes',
              onPressed: _openLedger,
              icon: const Icon(Icons.account_balance_wallet_rounded),
            ),
          ],
          title: const Text(
            'Finance by Teacher',
            style: TextStyle(
              color: AdminFinanceScreen.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        body: Center(
          child: FilledButton.icon(
            onPressed: _askPin,
            icon: const Icon(Icons.lock_open_rounded),
            label: const Text('Enter password'),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AdminFinanceScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminFinanceScreen.primary),
        actions: [
          IconButton(
            tooltip: 'Ledger notes',
            onPressed: _openLedger,
            icon: const Icon(Icons.account_balance_wallet_rounded),
          ),
        ],
        title: const Text(
          'Finance by Teacher',
          style: TextStyle(
            color: AdminFinanceScreen.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1700,
        child: _loadingFilter
            ? const Center(child: CircularProgressIndicator())
            : StreamBuilder<DatabaseEvent>(
                stream: _financePayoutPeriodsRef.onValue,
                builder: (context, periodsSnap) {
                  if (periodsSnap.hasError) {
                    return const Center(
                      child: Text('Error loading finance cycles.'),
                    );
                  }
                  final periods = <_FinancePayoutPeriodRecord>[];
                  final rawPeriods = periodsSnap.data?.snapshot.value;
                  if (rawPeriods is Map) {
                    rawPeriods.forEach((k, v) {
                      if (v is! Map) return;
                      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
                      periods.add(
                        _FinancePayoutPeriodRecord.fromMap(
                          id: k.toString(),
                          map: m.cast<String, dynamic>(),
                        ),
                      );
                    });
                  }
                  periods.sort((a, b) => b.startAtMs.compareTo(a.startAtMs));
                  _FinancePayoutPeriodRecord? activeFinancePeriod;
                  for (final period in periods) {
                    if (period.isActive && activeFinancePeriod == null) {
                      activeFinancePeriod = period;
                    }
                  }
                  return StreamBuilder<DatabaseEvent>(
                    stream: _classesRef.onValue,
                    builder: (context, classSnapshot) {
                      final rosterCountsByScope =
                          _rosterLearnersCountByTeacherScope(
                            classSnapshot.data?.snapshot.value,
                          );
                      final attendanceByScope = _attendanceByTeacherScope(
                        classSnapshot.data?.snapshot.value,
                      );
                      final courseTotalsByScope = _courseTotalsByTeacherScope(
                        classSnapshot.data?.snapshot.value,
                      );
                      return StreamBuilder<DatabaseEvent>(
                        stream: _paymentsRef
                            .orderByChild('paidAt')
                            .limitToLast(5000)
                            .onValue,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return const Center(
                              child: Text('Error loading finance data.'),
                            );
                          }
                          if (snapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          final raw = snapshot.data?.snapshot.value;
                          final all = <Map<String, dynamic>>[];
                          if (raw is Map) {
                            raw.forEach((k, v) {
                              if (v is! Map) return;
                              final m = v.map(
                                (kk, vv) => MapEntry(kk.toString(), vv),
                              );
                              m['paymentId'] = k.toString();
                              all.add(m.cast<String, dynamic>());
                            });
                          }

                          final visible =
                              all
                                  .where((p) => _inRangeMs(_asInt(p['paidAt'])))
                                  .toList()
                                ..sort(
                                  (a, b) => _asInt(
                                    b['paidAt'],
                                  ).compareTo(_asInt(a['paidAt'])),
                                );
                          final financeRows = <Map<String, dynamic>>[];
                          final flexibleRows = <Map<String, dynamic>>[];
                          final recordedRows = <Map<String, dynamic>>[];
                          for (final payment in visible) {
                            final variantKey = _variantKeyFrom(payment);
                            if (variantKey == 'flexible') {
                              flexibleRows.add(payment);
                            } else if (variantKey == 'recorded') {
                              recordedRows.add(payment);
                            }
                            final allocations = financeAllocationsFromPayment(
                              payment,
                            );
                            for (final allocation in allocations) {
                              financeRows.add(allocation.toRow());
                            }
                          }

                          var originalIncome = 0;
                          var waitingTotal = 0;
                          var schoolTotal = 0;
                          var originalByMethod = _methodTotalsZero();
                          var waitingByMethod = _methodTotalsZero();
                          var schoolByMethod = _methodTotalsZero();
                          final waitingRows = <Map<String, dynamic>>[];
                          final schoolRows = <Map<String, dynamic>>[];
                          final teacherMap =
                              <String, List<Map<String, dynamic>>>{};

                          _TeacherCardData? buildCardData({
                            required String name,
                            required List<Map<String, dynamic>> rows,
                            bool includeRoster = false,
                          }) {
                            if (rows.isEmpty) return null;
                            var original = 0;
                            var payout = 0;
                            var waiting = 0;
                            var school = 0;
                            var originalMethods = _methodTotalsZero();
                            var payoutMethods = _methodTotalsZero();
                            var waitingMethods = _methodTotalsZero();
                            final learners = <String>{};
                            final doneLearners = <String>{};
                            final fallbackTotalsByLearnerCourse =
                                <String, int>{};

                            for (final p in rows) {
                              final effective = _effectiveFinanceFromPayment(p);
                              final alloc = _amountsFrom(p);

                              original += effective.originalAmount;
                              payout += effective.teacherNet;
                              waiting += effective.waitingAmount;
                              school += effective.schoolNet;

                              originalMethods = _addToMethodTotals(
                                current: originalMethods,
                                method: effective.method,
                                amount: effective.originalAmount,
                              );
                              payoutMethods = _addToMethodTotals(
                                current: payoutMethods,
                                method: effective.method,
                                amount: effective.teacherNet,
                              );
                              waitingMethods = _addToMethodTotals(
                                current: waitingMethods,
                                method: effective.method,
                                amount: effective.waitingAmount,
                              );

                              final uid = (p['uid'] ?? '').toString().trim();
                              final learnerName = _learnerNameFrom(p);
                              final learnerKey = uid.isNotEmpty
                                  ? uid
                                  : learnerName;
                              if (learnerKey.isNotEmpty) {
                                learners.add(learnerKey);
                              }

                              final courseId = (p['course_id'] ?? '')
                                  .toString()
                                  .trim();
                              if (uid.isNotEmpty && courseId.isNotEmpty) {
                                final learnerCourseKey = '$uid|$courseId';
                                final fallbackTotal = _asInt(p['sessionsPaid']);
                                final currentFallback =
                                    fallbackTotalsByLearnerCourse[learnerCourseKey] ??
                                    0;
                                if (fallbackTotal > currentFallback) {
                                  fallbackTotalsByLearnerCourse[learnerCourseKey] =
                                      fallbackTotal;
                                }
                              }

                              final pushedStatus =
                                  (p['financePushedStatus'] ?? '')
                                      .toString()
                                      .trim()
                                      .toLowerCase();
                              final payoutStatus = _normalizeStatus(
                                p['financePayoutStatus'],
                              );
                              final doneLike =
                                  pushedStatus == 'done' ||
                                  payoutStatus == 'done' ||
                                  (payoutStatus == 'split' &&
                                      (alloc.splitPaidStatus == 'done' ||
                                          _normalizeStatus(
                                                p['financeSplitPaidStatus'],
                                              ) ==
                                              'done'));
                              if (doneLike && learnerKey.isNotEmpty) {
                                doneLearners.add(learnerKey);
                              }
                            }

                            final teacherId = rows.isEmpty
                                ? ''
                                : _teacherIdFrom(rows.first);
                            final scope = _teacherScopeKey(
                              teacherId: teacherId,
                              teacherName: name,
                            );
                            final rosterCount = includeRoster
                                ? (rosterCountsByScope[scope] ?? 0)
                                : 0;
                            var progressDoneSessions = 0;
                            var progressTotalSessions = 0;
                            for (final entry
                                in fallbackTotalsByLearnerCourse.entries) {
                              final parts = entry.key.split('|');
                              if (parts.length < 2) continue;
                              final uid = parts.first.trim();
                              final courseId = parts.last.trim();
                              if (uid.isEmpty || courseId.isEmpty) continue;
                              final scopedKey = _scopeSessionKey(
                                scope: scope,
                                uid: uid,
                                courseId: courseId,
                              );
                              final counts =
                                  attendanceByScope[scopedKey] ??
                                  const _SessionCounts();
                              progressDoneSessions += counts.held;
                              final totalFromClasses =
                                  courseTotalsByScope[scopedKey] ?? 0;
                              final total = totalFromClasses > 0
                                  ? totalFromClasses
                                  : entry.value;
                              if (total > 0) {
                                progressTotalSessions += total;
                              }
                            }

                            return _TeacherCardData(
                              teacherId: teacherId,
                              teacherScopeKey: scope,
                              teacherName: name,
                              originalTotal: original,
                              payoutTotal: payout,
                              waitingTotal: waiting,
                              originalByMethod: originalMethods,
                              payoutByMethod: payoutMethods,
                              waitingByMethod: waitingMethods,
                              learnersCount: learners.length > rosterCount
                                  ? learners.length
                                  : rosterCount,
                              doneLearnersCount: doneLearners.length,
                              paymentsCount: rows.length,
                              schoolTotal: school,
                              progressDoneSessions: progressDoneSessions,
                              progressTotalSessions: progressTotalSessions,
                              payments: rows,
                            );
                          }

                          for (final p in visible) {
                            final effective = _effectiveFinanceFromPayment(p);
                            originalIncome += effective.originalAmount;
                            originalByMethod = _addToMethodTotals(
                              current: originalByMethod,
                              method: effective.method,
                              amount: effective.originalAmount,
                            );
                          }

                          for (final p in financeRows) {
                            final effective = _effectiveFinanceFromPayment(p);
                            final teacher = _teacherNameFrom(p);
                            final isVariantPseudoTeacher =
                                (teacher == 'Flexible' ||
                                    teacher == 'Recorded') &&
                                _teacherIdFrom(p).isEmpty;
                            if (!isVariantPseudoTeacher) {
                              teacherMap
                                  .putIfAbsent(
                                    teacher,
                                    () => <Map<String, dynamic>>[],
                                  )
                                  .add(p);
                            }
                            waitingTotal += effective.waitingAmount;
                            waitingByMethod = _addToMethodTotals(
                              current: waitingByMethod,
                              method: effective.method,
                              amount: effective.waitingAmount,
                            );

                            if (effective.waitingAmount > 0) {
                              waitingRows.add(p);
                            }

                            final schoolNet = effective.schoolNet;
                            if (schoolNet > 0) {
                              schoolTotal += schoolNet;
                              schoolRows.add(p);
                              schoolByMethod = _addToMethodTotals(
                                current: schoolByMethod,
                                method: effective.method,
                                amount: schoolNet,
                              );
                            }
                          }

                          final variantCards = <_TeacherCardData>[];
                          final flexibleCard = buildCardData(
                            name: 'Flexible',
                            rows: flexibleRows,
                          );
                          if (flexibleCard != null) {
                            variantCards.add(flexibleCard);
                          }
                          final recordedCard = buildCardData(
                            name: 'Recorded',
                            rows: recordedRows,
                          );
                          if (recordedCard != null) {
                            variantCards.add(recordedCard);
                          }

                          final teacherCards = <_TeacherCardData>[];
                          for (final entry in teacherMap.entries) {
                            final card = buildCardData(
                              name: entry.key,
                              rows: entry.value,
                              includeRoster: true,
                            );
                            if (card != null) teacherCards.add(card);
                          }

                          teacherCards.sort(
                            (a, b) => a.teacherName.toLowerCase().compareTo(
                              b.teacherName.toLowerCase(),
                            ),
                          );

                          return ListView(
                            padding: EdgeInsets.fromLTRB(
                              12,
                              12,
                              12,
                              20 + MediaQuery.of(context).padding.bottom + 20,
                            ),
                            children: [
                              _FilterHeader(
                                fromLabel: _fromDate == null
                                    ? 'From: not set'
                                    : 'From: ${_fmtDate(_fromDate!)}',
                                toLabel: _toDate == null
                                    ? 'To: not set'
                                    : 'To: ${_fmtDate(_toDate!)}',
                                onPickFrom: _pickFromDate,
                                onPickTo: _pickToDate,
                                onReset: _clearFilter,
                                originalIncome: _money(originalIncome),
                                waitingTotal: _money(waitingTotal),
                                originalByMethod: originalByMethod,
                                waitingByMethod: waitingByMethod,
                                teachersCount:
                                    teacherCards.length + variantCards.length,
                                financeCycleLabel: activeFinancePeriod == null
                                    ? 'Finance cycle: not started'
                                    : 'Finance cycle: ${activeFinancePeriod.displayLabel}',
                                onFreshStart: () =>
                                    _openFinanceFreshStartDialog(
                                      activePeriod: activeFinancePeriod,
                                    ),
                              ),
                              const SizedBox(height: 12),
                              _ResponsiveCardWrap(
                                minItemWidth: 260,
                                maxColumns: 2,
                                children: [
                                  _WaitingCard(
                                    totalWaiting: waitingTotal,
                                    byMethod: waitingByMethod,
                                    money: _money,
                                    onTap: () =>
                                        _openWaitingDetailsDialog(waitingRows),
                                  ),
                                  _SchoolCard(
                                    totalSchool: schoolTotal,
                                    byMethod: schoolByMethod,
                                    money: _money,
                                    onTap: () =>
                                        _openSchoolDetailsDialog(schoolRows),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              if (variantCards.isEmpty && teacherCards.isEmpty)
                                const Card(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text(
                                      'No finance cards in this date range.',
                                    ),
                                  ),
                                )
                              else ...[
                                if (variantCards.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: _ResponsiveCardWrap(
                                      minItemWidth: 320,
                                      maxColumns: 2,
                                      children: variantCards
                                          .map(
                                            (card) => _TeacherSquareCard(
                                              data: card,
                                              money: _money,
                                              isClearingSetup:
                                                  _clearingTeacherScopes
                                                      .contains(
                                                        card.teacherScopeKey,
                                                      ),
                                              onClearSetup: () =>
                                                  _clearTeacherCardSetup(card),
                                              onTap: () {
                                                Navigator.of(context).push(
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        _TeacherFinanceDetailsScreen(
                                                          teacherId:
                                                              card.teacherId,
                                                          teacherScopeKey: card
                                                              .teacherScopeKey,
                                                          teacherName:
                                                              card.teacherName,
                                                          initialPayments:
                                                              card.payments,
                                                          paymentsRef:
                                                              _paymentsRef,
                                                          classesRef:
                                                              _classesRef,
                                                          usersRef: _usersRef,
                                                          financeDoneRef:
                                                              _financeDoneRef,
                                                          financePaymentMetaRef:
                                                              _financePaymentMetaRef,
                                                          activeFinancePeriod:
                                                              activeFinancePeriod,
                                                          money: _money,
                                                          onSetMethod:
                                                              _setPaymentMethod,
                                                          showNoPaymentRows:
                                                              false,
                                                        ),
                                                  ),
                                                );
                                              },
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  ),
                              ],
                              if (teacherCards.isNotEmpty)
                                _ResponsiveCardWrap(
                                  minItemWidth: 340,
                                  maxColumns: 2,
                                  children: teacherCards
                                      .map(
                                        (card) => _TeacherSquareCard(
                                          data: card,
                                          money: _money,
                                          isClearingSetup:
                                              _clearingTeacherScopes.contains(
                                                card.teacherScopeKey,
                                              ),
                                          onClearSetup: () =>
                                              _clearTeacherCardSetup(card),
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    _TeacherFinanceDetailsScreen(
                                                      teacherId: card.teacherId,
                                                      teacherScopeKey:
                                                          card.teacherScopeKey,
                                                      teacherName:
                                                          card.teacherName,
                                                      initialPayments:
                                                          card.payments,
                                                      paymentsRef: _paymentsRef,
                                                      classesRef: _classesRef,
                                                      usersRef: _usersRef,
                                                      financeDoneRef:
                                                          _financeDoneRef,
                                                      financePaymentMetaRef:
                                                          _financePaymentMetaRef,
                                                      activeFinancePeriod:
                                                          activeFinancePeriod,
                                                      money: _money,
                                                      onSetMethod:
                                                          _setPaymentMethod,
                                                      showNoPaymentRows: true,
                                                    ),
                                              ),
                                            );
                                          },
                                        ),
                                      )
                                      .toList(),
                                ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _TeacherFinanceDetailsScreen extends StatefulWidget {
  const _TeacherFinanceDetailsScreen({
    required this.teacherId,
    required this.teacherScopeKey,
    required this.teacherName,
    required this.initialPayments,
    required this.paymentsRef,
    required this.classesRef,
    required this.usersRef,
    required this.financeDoneRef,
    required this.financePaymentMetaRef,
    required this.activeFinancePeriod,
    required this.money,
    required this.onSetMethod,
    this.showNoPaymentRows = true,
  });

  final String teacherId;
  final String teacherScopeKey;
  final String teacherName;
  final List<Map<String, dynamic>> initialPayments;
  final DatabaseReference paymentsRef;
  final DatabaseReference classesRef;
  final DatabaseReference usersRef;
  final DatabaseReference financeDoneRef;
  final DatabaseReference financePaymentMetaRef;
  final _FinancePayoutPeriodRecord? activeFinancePeriod;
  final String Function(int amount) money;
  final bool showNoPaymentRows;
  final Future<void> Function({
    required String paymentId,
    required String method,
  })
  onSetMethod;

  @override
  State<_TeacherFinanceDetailsScreen> createState() =>
      _TeacherFinanceDetailsScreenState();
}

class _TeacherFinanceDetailsScreenState
    extends State<_TeacherFinanceDetailsScreen> {
  late List<Map<String, dynamic>> _rows;
  Timer? _pulseTimer;
  bool _pulseOn = true;
  bool _isPushingAll = false;
  bool _isClearingSetup = false;

  void _applyLocalPaymentPatch(String paymentId, Map<String, dynamic> fields) {
    if (paymentId.isEmpty) return;
    setState(() {
      for (var i = 0; i < _rows.length; i++) {
        final rowPaymentId = (_rows[i]['paymentId'] ?? '').toString().trim();
        if (rowPaymentId != paymentId) continue;
        final next = Map<String, dynamic>.from(_rows[i]);
        fields.forEach((key, value) {
          if (value == null) {
            next.remove(key);
          } else {
            next[key] = value;
          }
        });
        _rows[i] = next;
      }
      _rows.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));
    });
  }

  @override
  void initState() {
    super.initState();
    _rows = List<Map<String, dynamic>>.from(widget.initialPayments)
      ..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      setState(() => _pulseOn = !_pulseOn);
    });
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final raw = v.toString().trim();
    if (raw.isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9-]'), '');
    if (cleaned.isEmpty || cleaned == '-') return 0;
    return int.tryParse(cleaned) ?? 0;
  }

  static String _normalizeStatus(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'done' || s == 'tbpaid' || s == 'split') return s;
    return 'tbpaid';
  }

  static String _learnerNameFrom(Map<String, dynamic> p) {
    final n1 = (p['learner_name'] ?? '').toString().trim();
    if (n1.isNotEmpty) return n1;
    final n2 = (p['learnerName'] ?? '').toString().trim();
    if (n2.isNotEmpty) return n2;
    final n3 = (p['name'] ?? '').toString().trim();
    if (n3.isNotEmpty) return n3;
    return '(Unknown learner)';
  }

  static _FinanceAmounts _amountsFrom(Map<String, dynamic> p) {
    final amount = _asInt(p['amount']);
    final status = _normalizeStatus(p['financePayoutStatus']);
    if (status != 'split') {
      return _FinanceAmounts(
        amount: amount,
        status: status,
        splitPaidStatus: null,
        payoutAmount: amount,
        waitingAmount: 0,
      );
    }

    final splitPaid = _asInt(p['financeSplitPaidAmount']);
    var splitWaiting = _asInt(p['financeSplitWaitingAmount']);
    if (splitWaiting <= 0) splitWaiting = amount - splitPaid;
    final paid = splitPaid.clamp(0, amount);
    final waiting = splitWaiting.clamp(0, amount - paid);
    final splitPaidStatus =
        _normalizeStatus(p['financeSplitPaidStatus']) == 'done'
        ? 'done'
        : 'tbpaid';

    return _FinanceAmounts(
      amount: amount,
      status: 'split',
      splitPaidStatus: splitPaidStatus,
      payoutAmount: paid,
      waitingAmount: waiting,
    );
  }

  Color _statusColor(_FinanceAmounts a) {
    if (a.status == 'done') return AdminFinanceScreen.done;
    if (a.status == 'tbpaid') return AdminFinanceScreen.tbpaid;
    return AdminFinanceScreen.waiting;
  }

  String _methodFrom(Map<String, dynamic> row) {
    final s = (row['financeMethod'] ?? '').toString().trim().toLowerCase();
    if (s == 'cash') return 'cash';
    if (s == 'ccp') return 'ccp';
    return 'unspecified';
  }

  String _variantKeyFrom(Map<String, dynamic> row) {
    return normalizeVariantKey(
      (row['variantKey'] ?? row['variant'] ?? row['deliveryKey'] ?? '')
          .toString(),
      fallback: 'inclass',
    );
  }

  Future<void> _setMethod(Map<String, dynamic> row, String method) async {
    if (row['isFinanceDoneMarkEntry'] == true) {
      final markKey = (row['financeDoneMarkKey'] ?? '').toString().trim();
      if (markKey.isEmpty) return;
      await widget.financeDoneRef
          .child(widget.teacherScopeKey)
          .child(markKey)
          .update({
            'financeMethod': method,
            'method': method,
            'updatedAt': ServerValue.timestamp,
          });
      if (!mounted) return;
      setState(() {
        row['financeMethod'] = method;
        row['method'] = method;
      });
      return;
    }

    final paymentId = (row['paymentId'] ?? '').toString().trim();
    if (paymentId.isEmpty) return;
    await widget.onSetMethod(paymentId: paymentId, method: method);
    if (!mounted) return;
    _applyLocalPaymentPatch(paymentId, {
      'financeMethod': method,
      'financePushedAt': null,
      'financePushedBy': null,
      'financePushedStatus': null,
    });
  }

  Future<void> _pickMethod(Map<String, dynamic> row) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Text('💵'),
                title: const Text('Cash'),
                onTap: () => Navigator.of(sheetCtx).pop('cash'),
              ),
              ListTile(
                leading: const Text('🏤'),
                title: const Text('CCP'),
                onTap: () => Navigator.of(sheetCtx).pop('ccp'),
              ),
              ListTile(
                leading: const Text('❔'),
                title: const Text('Unspecified'),
                onTap: () => Navigator.of(sheetCtx).pop('unspecified'),
              ),
              const SizedBox(height: 4),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    await _setMethod(row, selected);
  }

  bool _isMethodSet(Map<String, dynamic> row) {
    String raw;
    if (row.containsKey('financeMethod')) {
      raw = (row['financeMethod'] ?? '').toString().trim().toLowerCase();
    } else {
      raw = (row['method'] ?? '').toString().trim().toLowerCase();
    }
    return raw.isNotEmpty;
  }

  String _teacherLabelFrom(Map<String, dynamic> row) {
    final t1 = (row['teacherName'] ?? '').toString().trim();
    if (t1.isNotEmpty) return t1;
    final t2 = (row['teacher_name'] ?? '').toString().trim();
    if (t2.isNotEmpty) return t2;
    final t3 = (row['teacher'] ?? '').toString().trim();
    if (t3.isNotEmpty) return t3;
    return '';
  }

  bool _isSchoolOnlyTeacherLabel(Map<String, dynamic> row) {
    final t = _teacherLabelFrom(row).toLowerCase();
    return t == 'service' || t == 'waiting';
  }

  bool _isTeacherShareUnlocked(Map<String, dynamic> row) {
    return row['financeTeacherShareUnlocked'] == true;
  }

  bool _isEffectiveSchoolOnly(Map<String, dynamic> row) {
    if (!_isSchoolOnlyTeacherLabel(row)) return false;
    return !_isTeacherShareUnlocked(row);
  }

  bool _isTeacherPercentSet(Map<String, dynamic> row) {
    if (_isEffectiveSchoolOnly(row)) return true;
    final alloc = _amountsFrom(row);
    if (alloc.payoutAmount <= 0) return true;
    final p = _asInt(row['financeTeacherPercent']);
    return p >= 35 && p <= 100;
  }

  bool _isStatusSet(Map<String, dynamic> row, {required bool isNoPayment}) {
    if (isNoPayment) {
      return (row['financePayoutStatus'] ?? '').toString().trim().isNotEmpty;
    }
    final statusRaw = (row['financePayoutStatus'] ?? '').toString().trim();
    if (statusRaw.isEmpty) return false;
    final status = _normalizeStatus(statusRaw);
    if (status != 'split') return true;
    final amount = _asInt(row['amount']);
    final paid = _asInt(row['financeSplitPaidAmount']);
    final waiting = _asInt(row['financeSplitWaitingAmount']);
    return paid >= 0 && waiting >= 0 && paid + waiting == amount;
  }

  String _fmtDateMs(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _applyStatusUpdate(
    Map<String, dynamic> row,
    Map<String, dynamic> updates,
  ) async {
    final isDoneMarkEntry = row['isFinanceDoneMarkEntry'] == true;
    final doneMarkKey = (row['financeDoneMarkKey'] ?? '').toString().trim();
    final paymentId = (row['paymentId'] ?? '').toString().trim();
    if (!isDoneMarkEntry && paymentId.isEmpty) return;
    if (isDoneMarkEntry && doneMarkKey.isEmpty) return;

    final payload = <String, dynamic>{
      ...updates,
      'financePushedAt': null,
      'financePushedBy': null,
      'financePushedStatus': null,
      'financeUpdatedAt': ServerValue.timestamp,
    };

    if (isDoneMarkEntry) {
      await widget.financeDoneRef
          .child(widget.teacherScopeKey)
          .child(doneMarkKey)
          .update({...payload, 'updatedAt': ServerValue.timestamp});
    } else {
      await widget.paymentsRef.child(paymentId).update(payload);
    }

    if (!mounted) return;
    setState(() {
      for (final entry in payload.entries) {
        if (entry.value == null) {
          row.remove(entry.key);
        } else {
          row[entry.key] = entry.value;
        }
      }
      if (!isDoneMarkEntry) {
        row.remove('financePushedAt');
        row.remove('financePushedBy');
        row.remove('financePushedStatus');
      }
    });
  }

  Future<void> _setDoneQuick(Map<String, dynamic> row) async {
    await _applyStatusUpdate(row, {
      'financePayoutStatus': 'done',
      'financeSplitPaidAmount': null,
      'financeSplitWaitingAmount': null,
      'financeSplitPaidStatus': null,
    });
  }

  Future<void> _setWaitingQuick(Map<String, dynamic> row) async {
    final amount = _asInt(row['amount']);
    await _applyStatusUpdate(row, {
      'financePayoutStatus': 'split',
      'financeSplitPaidAmount': 0,
      'financeSplitWaitingAmount': amount,
      'financeSplitPaidStatus': 'tbpaid',
      'financeTeacherNet': 0,
      'financeSchoolNet': 0,
      'financeTeacherPercent': 0,
    });
  }

  Future<void> _editSplitBreakdown(Map<String, dynamic> row) async {
    final amount = _asInt(row['amount']);
    if (amount <= 0) return;

    int initialWaiting = _asInt(row['financeSplitWaitingAmount']);
    if (initialWaiting < 0 || initialWaiting > amount) initialWaiting = 0;
    int initialPaid = _asInt(row['financeSplitPaidAmount']);
    if (initialPaid <= 0 || initialPaid > amount) {
      initialPaid = amount - initialWaiting;
    }
    if (initialPaid < 0) initialPaid = amount;

    int initialClass = _asInt(row['financeTeacherNet']);
    int initialSchool = _asInt(row['financeSchoolNet']);
    if (initialClass < 0 ||
        initialSchool < 0 ||
        initialClass + initialSchool != initialPaid) {
      final p = _asInt(row['financeTeacherPercent']).clamp(0, 100);
      initialClass = ((initialPaid * p) / 100).round();
      initialSchool = initialPaid - initialClass;
    }

    final classCtrl = TextEditingController(text: '$initialClass');
    final schoolCtrl = TextEditingController(text: '$initialSchool');
    final waitingCtrl = TextEditingController(text: '$initialWaiting');

    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (_, setD) {
            int classAmount() => int.tryParse(classCtrl.text.trim()) ?? 0;
            int schoolAmount() => int.tryParse(schoolCtrl.text.trim()) ?? 0;
            int waitingAmount() => int.tryParse(waitingCtrl.text.trim()) ?? 0;
            final classAmountNow = classAmount();
            final percent = amount > 0
                ? ((classAmountNow * 100) / amount).round().clamp(0, 100)
                : 0;

            return AlertDialog(
              title: const Text('Split payment'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total: ${widget.money(amount)}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: classCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Class (teacher)',
                            ),
                            onChanged: (_) => setD(() {}),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDCE8FF),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$percent%',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: AdminFinanceScreen.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: schoolCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'School'),
                      onChanged: (_) => setD(() {}),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: waitingCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Waiting'),
                      onChanged: (_) => setD(() {}),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Check: ${classAmount()} + ${schoolAmount()} + ${waitingAmount()} = ${classAmount() + schoolAmount() + waitingAmount()}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.black.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final classAmount =
                        int.tryParse(classCtrl.text.trim()) ?? -1;
                    final schoolAmount =
                        int.tryParse(schoolCtrl.text.trim()) ?? -1;
                    final waitingAmount =
                        int.tryParse(waitingCtrl.text.trim()) ?? -1;
                    final sum = classAmount + schoolAmount + waitingAmount;
                    if (classAmount < 0 ||
                        schoolAmount < 0 ||
                        waitingAmount < 0 ||
                        sum != amount) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Class + School + Waiting must equal total amount.',
                          ),
                        ),
                      );
                      return;
                    }
                    Navigator.of(dialogCtx).pop({
                      'class': classAmount,
                      'school': schoolAmount,
                      'waiting': waitingAmount,
                    });
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;
    final classAmount = result['class'] ?? 0;
    final schoolAmount = result['school'] ?? 0;
    final waitingAmount = result['waiting'] ?? 0;
    final paidPart = classAmount + schoolAmount;
    final percent = amount > 0
        ? ((classAmount * 100) / amount).round().clamp(0, 100)
        : 0;

    await _applyStatusUpdate(row, {
      'financePayoutStatus': 'split',
      'financeSplitPaidAmount': paidPart,
      'financeSplitWaitingAmount': waitingAmount,
      'financeSplitPaidStatus': waitingAmount == 0 ? 'done' : 'tbpaid',
      'financeTeacherPercent': percent,
      'financeTeacherGross': paidPart,
      'financeTeacherNet': classAmount,
      'financeSchoolNet': schoolAmount,
    });
  }

  bool _isNoPaymentRow(Map<String, dynamic> row) => row['isNoPayment'] == true;

  String _courseIdFromRow(Map<String, dynamic> row) {
    return (row['course_id'] ?? row['courseId'] ?? '').toString().trim();
  }

  String _sessionKey({required String uid, required String courseId}) {
    return '${uid.trim()}|${courseId.trim()}';
  }

  String _doneMarkKey(Map<String, dynamic> row) {
    final uid = (row['uid'] ?? '').toString().trim();
    final courseId = _courseIdFromRow(row);
    if (uid.isEmpty) return '';
    if (courseId.isEmpty) return uid;
    return '${uid}__$courseId';
  }

  String _derivedPushedStatus(Map<String, dynamic> row) {
    final payout = _normalizeStatus(row['financePayoutStatus']);
    if (payout != 'split') return payout;
    final alloc = _amountsFrom(row);
    return (alloc.splitPaidStatus ?? 'tbpaid') == 'done' ? 'done' : 'tbpaid';
  }

  bool _isPushEligibleRow(Map<String, dynamic> row) {
    if (_isNoPaymentRow(row)) return false;
    if (row['isFinanceDoneMarkEntry'] == true) return false;
    if (!_isMethodSet(row)) return false;
    if (!_isStatusSet(row, isNoPayment: false)) return false;
    final variantKey = _variantKeyFrom(row);
    if (variantKey == 'flexible' || variantKey == 'recorded') {
      if (row['financeAllocations'] is! Map) return false;
      final allocations = financeAllocationsFromPayment(
        row,
      ).where((a) => !a.isLegacy || row['financeAllocations'] is Map).toList();
      if (allocations.isEmpty) return false;
      for (final allocation in allocations) {
        if (allocation.teacherId.trim().isEmpty) return false;
      }
      return true;
    }
    return _isTeacherPercentSet(row);
  }

  Future<void> _pushAllEligibleRows() async {
    if (_isPushingAll) return;
    final activeFinancePeriod = widget.activeFinancePeriod;
    if (activeFinancePeriod == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Start a finance cycle before pushing.')),
      );
      return;
    }
    final eligible = _rows.where(_isPushEligibleRow).toList();
    final eligiblePaymentIds = eligible
        .map((row) => (row['paymentId'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No eligible rows to push yet.')),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Push all to teacher'),
        content: Text(
          'Push ${eligiblePaymentIds.length} eligible item${eligiblePaymentIds.length == 1 ? '' : 's'} for ${widget.teacherName}? Already pushed rows will be refreshed too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Push all'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _isPushingAll = true);
    try {
      final processedPaymentIds = <String>{};
      final localPatches = <String, Map<String, dynamic>>{};
      final pushedAtMs = DateTime.now().millisecondsSinceEpoch;

      for (final row in eligible) {
        final paymentId = (row['paymentId'] ?? '').toString().trim();
        if (paymentId.isEmpty || processedPaymentIds.contains(paymentId)) {
          continue;
        }
        processedPaymentIds.add(paymentId);
        final pushedStatus = _derivedPushedStatus(row);
        await widget.paymentsRef.child(paymentId).update({
          'financePushedAt': ServerValue.timestamp,
          'financePushedBy': 'admin',
          'financePushedStatus': pushedStatus,
          'financePeriodId': activeFinancePeriod.id,
          'financePeriodStartDate': activeFinancePeriod.startDate,
          'financePeriodStartAtMs': activeFinancePeriod.startAtMs,
          'financePeriodEndDate': activeFinancePeriod.endDate,
          'financePeriodEndAtMs': activeFinancePeriod.endAtMs,
          'financeUpdatedAt': ServerValue.timestamp,
        });
        localPatches[paymentId] = {
          'financePushedAt': pushedAtMs,
          'financePushedBy': 'admin',
          'financePushedStatus': pushedStatus,
          'financePeriodId': activeFinancePeriod.id,
          'financePeriodStartDate': activeFinancePeriod.startDate,
          'financePeriodStartAtMs': activeFinancePeriod.startAtMs,
          'financePeriodEndDate': activeFinancePeriod.endDate,
          'financePeriodEndAtMs': activeFinancePeriod.endAtMs,
        };
      }

      if (!mounted) return;
      for (final entry in localPatches.entries) {
        _applyLocalPaymentPatch(entry.key, entry.value);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Pushed ${processedPaymentIds.length} item${processedPaymentIds.length == 1 ? '' : 's'} for ${widget.teacherName}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not push items: $e')));
    } finally {
      if (mounted) setState(() => _isPushingAll = false);
    }
  }

  Future<void> _clearTeacherSetup() async {
    if (_isClearingSetup) return;
    final targetRows = _rows
        .where(
          (row) =>
              !_isNoPaymentRow(row) && row['isFinanceDoneMarkEntry'] != true,
        )
        .toList();
    final paymentIds = targetRows
        .map((row) => (row['paymentId'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (paymentIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No payment rows to clear.')),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Clear teacher setup'),
        content: Text(
          'Clear finance setup for ${paymentIds.length} payment item${paymentIds.length == 1 ? '' : 's'} for ${widget.teacherName}? This will unpush and reset method, status, split, share, and allocations.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Clear setup'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _isClearingSetup = true);
    try {
      final localPatch = <String, dynamic>{
        'financeMethod': '',
        'financePayoutStatus': null,
        'financeSplitPaidAmount': null,
        'financeSplitWaitingAmount': null,
        'financeSplitPaidStatus': null,
        'financeTeacherPercent': null,
        'financeTeacherGross': null,
        'financeTeacherNet': null,
        'financeSchoolNet': null,
        'financeAllocations': null,
        'financeTeacherShareUnlocked': null,
        'financePushedAt': null,
        'financePushedBy': null,
        'financePushedStatus': null,
        'financePeriodId': null,
        'financePeriodStartDate': null,
        'financePeriodStartAtMs': null,
        'financePeriodEndDate': null,
        'financePeriodEndAtMs': null,
      };

      for (final paymentId in paymentIds) {
        await widget.paymentsRef.child(paymentId).update({
          ...localPatch,
          'financeUpdatedAt': ServerValue.timestamp,
        });
        _applyLocalPaymentPatch(paymentId, localPatch);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cleared setup for ${paymentIds.length} item${paymentIds.length == 1 ? '' : 's'} for ${widget.teacherName}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not clear setup: $e')));
    } finally {
      if (mounted) setState(() => _isClearingSetup = false);
    }
  }

  int _classTotalSessions(Map<dynamic, dynamic> cls) {
    int from(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString().trim()) ?? 0;
    }

    final scheduleRaw = cls['schedule'];
    if (scheduleRaw is Map) {
      final schedule = Map<dynamic, dynamic>.from(scheduleRaw);
      final scheduleTotal = from(schedule['meetingsCount']);
      if (scheduleTotal > 0) return scheduleTotal;
      final totalMeetings = from(schedule['totalMeetings']);
      if (totalMeetings > 0) return totalMeetings;
      final sessionsCount = from(schedule['sessionsCount']);
      if (sessionsCount > 0) return sessionsCount;
    }

    final fromCourseDuration = _AdminFinanceScreenState._parseTotalSessions(
      (cls['course_duration'] ?? '').toString().trim(),
    );
    if (fromCourseDuration > 0) return fromCourseDuration;
    return _AdminFinanceScreenState._parseTotalSessions(
      (cls['duration'] ?? '').toString().trim(),
    );
  }

  Map<String, int> _monthIndexByPaymentId(dynamic raw) {
    final out = <String, int>{};
    final grouped = <String, List<Map<String, dynamic>>>{};
    if (raw is! Map) return out;
    final items = Map<dynamic, dynamic>.from(raw);
    for (final e in items.entries) {
      final paymentId = e.key.toString().trim();
      if (paymentId.isEmpty) continue;
      final v = e.value;
      if (v is! Map) continue;
      final m = v.map((k, val) => MapEntry(k.toString(), val));
      final uid = (m['uid'] ?? '').toString().trim();
      final courseId = (m['course_id'] ?? m['courseId'] ?? '')
          .toString()
          .trim();
      if (uid.isEmpty || courseId.isEmpty) continue;
      final key = _sessionKey(uid: uid, courseId: courseId);
      grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]).add({
        'paymentId': paymentId,
        'paidAt': _asInt(m['paidAt']),
      });
    }

    for (final bucket in grouped.values) {
      bucket.sort((a, b) {
        final byDate = _asInt(a['paidAt']).compareTo(_asInt(b['paidAt']));
        if (byDate != 0) return byDate;
        return (a['paymentId'] ?? '').toString().compareTo(
          (b['paymentId'] ?? '').toString(),
        );
      });
      for (var i = 0; i < bucket.length; i++) {
        final pid = (bucket[i]['paymentId'] ?? '').toString().trim();
        if (pid.isEmpty) continue;
        out[pid] = i + 1;
      }
    }
    return out;
  }

  Map<String, int> _monthOverrideByPaymentId(dynamic raw) {
    final out = <String, int>{};
    if (raw is! Map) return out;
    final items = Map<dynamic, dynamic>.from(raw);
    for (final e in items.entries) {
      final paymentId = e.key.toString().trim();
      if (paymentId.isEmpty) continue;
      final v = e.value;
      if (v is! Map) continue;
      final m = Map<dynamic, dynamic>.from(v);
      final monthOverride = _asInt(m['monthOverride']);
      if (monthOverride > 0) out[paymentId] = monthOverride;
    }
    return out;
  }

  Future<void> _editMonthOverride({
    required String paymentId,
    required int initialValue,
    required bool hasOverride,
  }) async {
    if (paymentId.isEmpty) return;
    final ctrl = TextEditingController(
      text: initialValue > 0 ? '$initialValue' : '',
    );
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: const Text('Edit month label'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Month number',
              hintText: 'Example: 3',
            ),
          ),
          actions: [
            if (hasOverride)
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop('reset'),
                child: const Text('Reset'),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop('cancel'),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogCtx).pop('save'),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (choice == null || choice == 'cancel') return;
    if (choice == 'reset') {
      await widget.financePaymentMetaRef.child(paymentId).update({
        'monthOverride': null,
        'updatedAt': ServerValue.timestamp,
      });
      return;
    }
    final month = int.tryParse(ctrl.text.trim()) ?? 0;
    if (month <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Month must be 1 or greater.')),
      );
      return;
    }
    await widget.financePaymentMetaRef.child(paymentId).update({
      'monthOverride': month,
      'updatedAt': ServerValue.timestamp,
    });
  }

  List<Map<String, dynamic>> _teacherClassRoster(dynamic raw) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    if (raw is! Map) return out;
    final classes = Map<dynamic, dynamic>.from(raw);
    for (final e in classes.entries) {
      final classId = e.key.toString().trim();
      final clsRaw = e.value;
      if (clsRaw is! Map) continue;
      final cls = Map<dynamic, dynamic>.from(clsRaw);

      String instUid = '';
      final instCur = cls['instructor_current'];
      if (instCur is Map) {
        instUid = (instCur['uid'] ?? '').toString().trim();
      }
      final instName = (cls['instructor'] ?? '').toString().trim();
      final matchByUid =
          widget.teacherId.trim().isNotEmpty &&
          instUid.isNotEmpty &&
          instUid == widget.teacherId.trim();
      final matchByName =
          widget.teacherId.trim().isEmpty &&
          widget.teacherName.trim().isNotEmpty &&
          instUid.isEmpty &&
          instName.toLowerCase() == widget.teacherName.trim().toLowerCase();
      if (!matchByUid && !matchByName) continue;

      final courseId = (cls['course_id'] ?? '').toString().trim();
      final courseTitle = (cls['course_title'] ?? '').toString().trim();
      final courseCode = (cls['course_code'] ?? '').toString().trim();
      final totalSessions = _classTotalSessions(cls);

      final learnersRaw = cls['learners'];
      if (learnersRaw is! Map) continue;
      final learners = Map<dynamic, dynamic>.from(learnersRaw);
      for (final l in learners.entries) {
        final uid = l.key.toString().trim();
        if (uid.isEmpty) continue;
        final val = l.value;
        String name = 'Unnamed learner';
        String serial = '';
        if (val is Map) {
          final mm = Map<dynamic, dynamic>.from(val);
          final n = (mm['name'] ?? '').toString().trim();
          final s = (mm['serial'] ?? '').toString().trim();
          if (n.isNotEmpty) name = n;
          if (s.isNotEmpty) serial = s;
        }
        final dedupe = '$uid|$courseId|$classId';
        if (seen.contains(dedupe)) continue;
        seen.add(dedupe);
        out.add({
          'uid': uid,
          'name': name,
          'serial': serial,
          'class_id': classId,
          'course_id': courseId,
          'course_title': courseTitle,
          'course_code': courseCode,
          'total_sessions': totalSessions,
        });
      }
    }
    return out;
  }

  Set<String> _manualDoneKeys(dynamic raw) {
    final out = <String>{};
    if (raw is! Map) return out;
    final m = Map<dynamic, dynamic>.from(raw);
    for (final e in m.entries) {
      final markKey = e.key.toString().trim();
      if (markKey.isEmpty) continue;
      final v = e.value;
      if (v == true) {
        out.add(markKey);
        continue;
      }
      if (v is Map) {
        final mm = Map<dynamic, dynamic>.from(v);
        final done =
            (mm['done'] == true) ||
            (mm['status'] ?? '').toString().trim().toLowerCase() == 'done';
        if (done) out.add(markKey);
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _oldWaitingRowsFromDoneMarks(dynamic raw) {
    final out = <Map<String, dynamic>>[];
    if (raw is! Map) return out;
    final m = Map<dynamic, dynamic>.from(raw);
    for (final e in m.entries) {
      final markKey = e.key.toString().trim();
      if (markKey.isEmpty) continue;
      final v = e.value;
      if (v is! Map) continue;
      final mm = Map<dynamic, dynamic>.from(v);
      final isOldWaiting =
          mm['oldWaitingEntry'] == true || mm['oldWaiting'] == true;
      if (!isOldWaiting) continue;

      final amount = _asInt(mm['amount']);
      if (amount <= 0) continue;
      final uid = (mm['uid'] ?? '').toString().trim();
      if (uid.isEmpty) continue;

      final paidAt = _asInt(mm['paidAt']);
      final sourcePaidAt = _asInt(mm['oldWaitingSourcePaidAt']);
      final payoutStatus = _normalizeStatus(
        mm['financePayoutStatus'] ?? mm['status'],
      );
      out.add({
        'paymentId': 'old_waiting__$markKey',
        'isFinanceDoneMarkEntry': true,
        'financeDoneMarkKey': markKey,
        'uid': uid,
        'learner_name': (mm['learnerName'] ?? mm['learner_name'] ?? '')
            .toString()
            .trim(),
        'learner_serial': (mm['learnerSerial'] ?? mm['learner_serial'] ?? '')
            .toString()
            .trim(),
        'teacherId': widget.teacherId,
        'teacherName': widget.teacherName,
        'course_id': (mm['course_id'] ?? '').toString().trim(),
        'course_title': (mm['course_title'] ?? '').toString().trim(),
        'course_code': (mm['course_code'] ?? '').toString().trim(),
        'amount': amount,
        'method': (mm['method'] ?? mm['financeMethod'] ?? '').toString().trim(),
        'financeMethod': (mm['financeMethod'] ?? mm['method'] ?? '')
            .toString()
            .trim(),
        'financePayoutStatus': payoutStatus,
        'financeSplitPaidAmount': mm['financeSplitPaidAmount'],
        'financeSplitWaitingAmount': mm['financeSplitWaitingAmount'],
        'financeSplitPaidStatus': mm['financeSplitPaidStatus'],
        'financeTeacherPercent': mm['financeTeacherPercent'],
        'financeTeacherGross': mm['financeTeacherGross'],
        'financeTeacherNet': mm['financeTeacherNet'],
        'financeSchoolNet': mm['financeSchoolNet'],
        'paidAt': paidAt > 0 ? paidAt : sourcePaidAt,
        'notes': (mm['notes'] ?? '').toString().trim(),
        'oldWaiting': true,
        'oldWaitingSourcePaymentId': (mm['oldWaitingSourcePaymentId'] ?? '')
            .toString()
            .trim(),
        'oldWaitingOriginalAmount': _asInt(mm['oldWaitingOriginalAmount']),
        'oldWaitingSourcePaidAt': sourcePaidAt,
        'oldWaitingSourceMethod': (mm['oldWaitingSourceMethod'] ?? '')
            .toString()
            .trim(),
        'oldWaitingSourceCourseId': (mm['oldWaitingSourceCourseId'] ?? '')
            .toString()
            .trim(),
        'oldWaitingSourceCourseTitle': (mm['oldWaitingSourceCourseTitle'] ?? '')
            .toString()
            .trim(),
        'oldWaitingSourceCourseCode': (mm['oldWaitingSourceCourseCode'] ?? '')
            .toString()
            .trim(),
        'oldWaitingSourceMode': (mm['oldWaitingSourceMode'] ?? 'history')
            .toString()
            .trim(),
        'oldWaitingCreatedBy': (mm['oldWaitingCreatedBy'] ?? '')
            .toString()
            .trim(),
      });
    }
    return out;
  }

  Future<void> _setManualDone(Map<String, dynamic> row, bool done) async {
    final uid = (row['uid'] ?? '').toString().trim();
    if (uid.isEmpty) return;
    final markKey = _doneMarkKey(row);
    if (markKey.isEmpty) return;
    final markRef = widget.financeDoneRef
        .child(widget.teacherScopeKey)
        .child(markKey);
    if (done) {
      await markRef.set({
        'done': true,
        'status': 'done',
        'uid': uid,
        'course_id': _courseIdFromRow(row),
        'learnerName': _learnerNameFrom(row),
        'learnerSerial': (row['learner_serial'] ?? row['serial'] ?? '')
            .toString()
            .trim(),
        'updatedAt': ServerValue.timestamp,
      });
    } else {
      await markRef.remove();
    }
  }

  Future<void> _startOldWaitingSetup(Map<String, dynamic> learnerRow) async {
    await _addManualPayment(learnerRow);
  }

  Future<void> _addManualPayment(Map<String, dynamic> learnerRow) async {
    final uid = (learnerRow['uid'] ?? '').toString().trim();
    if (uid.isEmpty) return;
    final learnerSerial =
        (learnerRow['learner_serial'] ?? learnerRow['serial'] ?? '')
            .toString()
            .trim();
    final learnerNameNorm = _learnerNameFrom(learnerRow).trim().toLowerCase();

    final history = <Map<String, dynamic>>[];
    try {
      final historySnap = await widget.paymentsRef
          .orderByChild('uid')
          .equalTo(uid)
          .get();
      final historyRaw = historySnap.value;
      if (historyRaw is Map) {
        historyRaw.forEach((k, v) {
          if (v is! Map) return;
          final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          m['paymentId'] = k.toString();
          history.add(m.cast<String, dynamic>());
        });
      }

      if (history.isEmpty) {
        final fallbackSnap = await widget.paymentsRef.get();
        final fallbackRaw = fallbackSnap.value;
        if (fallbackRaw is Map) {
          final dedupe = <String>{};
          fallbackRaw.forEach((k, v) {
            if (v is! Map) return;
            final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
            final pid = k.toString();
            final rowUid = (m['uid'] ?? '').toString().trim();
            if (rowUid == uid) {
              if (dedupe.add(pid)) {
                m['paymentId'] = pid;
                history.add(m.cast<String, dynamic>());
              }
              return;
            }

            if (learnerSerial.isNotEmpty) {
              final rowSerial = (m['learner_serial'] ?? '').toString().trim();
              if (rowSerial == learnerSerial) {
                if (dedupe.add(pid)) {
                  m['paymentId'] = pid;
                  history.add(m.cast<String, dynamic>());
                }
                return;
              }
            }

            if (learnerNameNorm.isNotEmpty) {
              final rowName = (m['learner_name'] ?? m['learnerName'] ?? '')
                  .toString()
                  .trim()
                  .toLowerCase();
              if (rowName == learnerNameNorm) {
                if (dedupe.add(pid)) {
                  m['paymentId'] = pid;
                  history.add(m.cast<String, dynamic>());
                }
              }
            }
          });
        }
      }

      history.sort(
        (a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load previous payments.')),
      );
      return;
    }

    if (history.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No previous payments found for this learner.'),
        ),
      );
      return;
    }

    if (!mounted) return;

    String sourcePaymentId = (history.first['paymentId'] ?? '').toString();
    Map<String, dynamic>? sourcePayment = history.first;

    final originalFeeCtrl = TextEditingController(
      text: _asInt(sourcePayment['amount']).toString(),
    );
    final leftCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String method = _AdminFinanceScreenState._normalizeMethod(
      sourcePayment['financeMethod'] ?? sourcePayment['method'],
    );
    DateTime selectedDate = DateTime.now();
    final srcDate = _asInt(sourcePayment['paidAt']);
    if (srcDate > 0) {
      selectedDate = DateTime.fromMillisecondsSinceEpoch(srcDate);
    }
    String dateLabel(DateTime d) {
      String two(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)}';
    }

    Future<void> pickDate(StateSetter setD) async {
      final picked = await showDatePicker(
        context: context,
        initialDate: selectedDate,
        firstDate: DateTime(2018, 1, 1),
        lastDate: DateTime.now().add(const Duration(days: 365)),
      );
      if (picked == null) return;
      setD(() => selectedDate = picked);
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (_, setD) {
            final maxDialogHeight = MediaQuery.of(dialogCtx).size.height * 0.78;
            return AlertDialog(
              title: const Text('Add old waiting amount'),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              content: SizedBox(
                width: 420,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxDialogHeight),
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: sourcePaymentId,
                          decoration: const InputDecoration(
                            labelText: 'Old payment source',
                          ),
                          items: [
                            ...history.map((p) {
                              final pid = (p['paymentId'] ?? '')
                                  .toString()
                                  .trim();
                              final amount = _asInt(p['amount']);
                              final paidAt = _fmtDateMs(_asInt(p['paidAt']));
                              final code = (p['course_code'] ?? '')
                                  .toString()
                                  .trim();
                              final title = (p['course_title'] ?? '')
                                  .toString()
                                  .trim();
                              final course = code.isNotEmpty
                                  ? code
                                  : (title.isNotEmpty ? title : 'No course');
                              return DropdownMenuItem<String>(
                                value: pid,
                                child: Text(
                                  '$paidAt · ${widget.money(amount)} · $course',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            Map<String, dynamic>? selected;
                            if (history.isNotEmpty) {
                              selected = history.firstWhere(
                                (p) => (p['paymentId'] ?? '').toString() == v,
                                orElse: () => history.first,
                              );
                            }
                            setD(() {
                              sourcePaymentId = v;
                              sourcePayment = selected;
                              if (selected != null) {
                                originalFeeCtrl.text = _asInt(
                                  selected['amount'],
                                ).toString();
                                method =
                                    _AdminFinanceScreenState._normalizeMethod(
                                      selected['financeMethod'] ??
                                          selected['method'],
                                    );
                                final srcDate = _asInt(selected['paidAt']);
                                if (srcDate > 0) {
                                  selectedDate =
                                      DateTime.fromMillisecondsSinceEpoch(
                                        srcDate,
                                      );
                                }
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: originalFeeCtrl,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          readOnly: true,
                          decoration: InputDecoration(
                            labelText: 'Original fee (from selected source)',
                            filled: true,
                            fillColor: const Color(0xFFF8EED8),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: leftCtrl,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Left amount',
                            hintText: 'This amount is used for teacher %',
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: method,
                          decoration: const InputDecoration(
                            labelText: 'Method',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'cash',
                              child: Text('💵 Cash'),
                            ),
                            DropdownMenuItem(
                              value: 'ccp',
                              child: Text('🏤 CCP'),
                            ),
                            DropdownMenuItem(
                              value: 'unspecified',
                              child: Text('❔ Unspecified'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setD(() => method = v);
                          },
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          onTap: () => pickDate(setD),
                          borderRadius: BorderRadius.circular(10),
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'Date',
                              border: OutlineInputBorder(),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.event_rounded, size: 18),
                                const SizedBox(width: 8),
                                Text(dateLabel(selectedDate)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: noteCtrl,
                          maxLines: 2,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: 'Note (optional)',
                            hintText: 'Reason / context',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final original =
                        int.tryParse(originalFeeCtrl.text.trim()) ?? 0;
                    final left = int.tryParse(leftCtrl.text.trim()) ?? 0;
                    if (original <= 0 || left <= 0) return;
                    Navigator.of(dialogCtx).pop(true);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;
    final amount = int.tryParse(leftCtrl.text.trim()) ?? 0;
    if (amount <= 0) return;
    final originalAmount = int.tryParse(originalFeeCtrl.text.trim()) ?? 0;
    if (originalAmount <= 0) return;
    final note = noteCtrl.text.trim();
    final paidAt = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      12,
      0,
      0,
    ).millisecondsSinceEpoch;
    final sourceAmount = originalAmount;
    final src = sourcePayment;
    final sourcePaidAt = src == null ? 0 : _asInt(src['paidAt']);
    final sourceMethod = src == null
        ? ''
        : _AdminFinanceScreenState._normalizeMethod(
            src['financeMethod'] ?? src['method'],
          );
    final sourceCourseId = src == null
        ? ''
        : (src['course_id'] ?? '').toString().trim();
    final sourceCourseTitle = src == null
        ? ''
        : (src['course_title'] ?? '').toString().trim();
    final sourceCourseCode = src == null
        ? ''
        : (src['course_code'] ?? '').toString().trim();

    final markKey = _doneMarkKey(learnerRow);
    if (markKey.isEmpty) return;
    final markRef = widget.financeDoneRef
        .child(widget.teacherScopeKey)
        .child(markKey);
    await markRef.set({
      'uid': uid,
      'learnerName': _learnerNameFrom(learnerRow),
      'learnerSerial':
          (learnerRow['learner_serial'] ?? learnerRow['serial'] ?? '')
              .toString()
              .trim(),
      'course_id': _courseIdFromRow(learnerRow),
      'course_title': (learnerRow['course_title'] ?? '').toString().trim(),
      'course_code': (learnerRow['course_code'] ?? '').toString().trim(),
      'amount': amount,
      'method': method,
      'financeMethod': method,
      'financePayoutStatus': 'tbpaid',
      'paidAt': paidAt,
      'notes': note,
      'oldWaiting': true,
      'oldWaitingEntry': true,
      'oldWaitingSourcePaymentId': sourcePaymentId,
      'oldWaitingOriginalAmount': sourceAmount,
      'oldWaitingSourcePaidAt': sourcePaidAt,
      'oldWaitingSourceMethod': sourceMethod,
      'oldWaitingSourceCourseId': sourceCourseId,
      'oldWaitingSourceCourseTitle': sourceCourseTitle,
      'oldWaitingSourceCourseCode': sourceCourseCode,
      'oldWaitingSourceMode': 'history',
      'oldWaitingCreatedBy': 'admin',
      'oldWaitingCreatedAt': ServerValue.timestamp,
      'status': 'tbpaid',
      'done': false,
      'teacherId': widget.teacherId,
      'teacherName': widget.teacherName,
      'updatedAt': ServerValue.timestamp,
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Old waiting added from payment history.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminFinanceScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminFinanceScreen.primary),
        title: Text(
          widget.teacherName,
          style: const TextStyle(
            color: AdminFinanceScreen.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: widget.classesRef.onValue,
        builder: (context, classSnap) {
          final classRoster = _teacherClassRoster(
            classSnap.data?.snapshot.value,
          );
          return StreamBuilder<DatabaseEvent>(
            stream: widget.financeDoneRef.child(widget.teacherScopeKey).onValue,
            builder: (context, doneSnap) {
              final doneRaw = doneSnap.data?.snapshot.value;
              return StreamBuilder<DatabaseEvent>(
                stream: widget.paymentsRef.onValue,
                builder: (context, allPaymentsSnap) {
                  final monthByPaymentId = _monthIndexByPaymentId(
                    allPaymentsSnap.data?.snapshot.value,
                  );
                  return StreamBuilder<DatabaseEvent>(
                    stream: widget.financePaymentMetaRef.onValue,
                    builder: (context, financeMetaSnap) {
                      final monthOverrides = _monthOverrideByPaymentId(
                        financeMetaSnap.data?.snapshot.value,
                      );
                      final manualDone = _manualDoneKeys(doneRaw);
                      final oldWaitingRows = _oldWaitingRowsFromDoneMarks(
                        doneRaw,
                      );
                      final paymentLearnerCourse = <String>{};
                      for (final r in _rows) {
                        final uid = (r['uid'] ?? '').toString().trim();
                        final courseId = _courseIdFromRow(r);
                        if (uid.isNotEmpty && courseId.isNotEmpty) {
                          paymentLearnerCourse.add(
                            _sessionKey(uid: uid, courseId: courseId),
                          );
                        }
                      }
                      for (final r in oldWaitingRows) {
                        final uid = (r['uid'] ?? '').toString().trim();
                        final courseId = _courseIdFromRow(r);
                        if (uid.isNotEmpty && courseId.isNotEmpty) {
                          paymentLearnerCourse.add(
                            _sessionKey(uid: uid, courseId: courseId),
                          );
                        }
                      }

                      final noPaymentRows = <Map<String, dynamic>>[];
                      if (widget.showNoPaymentRows) {
                        for (final e in classRoster) {
                          final uid = (e['uid'] ?? '').toString().trim();
                          final courseId = (e['course_id'] ?? '')
                              .toString()
                              .trim();
                          if (uid.isEmpty || courseId.isEmpty) continue;
                          if (paymentLearnerCourse.contains(
                            _sessionKey(uid: uid, courseId: courseId),
                          )) {
                            continue;
                          }
                          final row = <String, dynamic>{
                            'isNoPayment': true,
                            'uid': uid,
                            'learner_name': e['name'] ?? 'Unnamed learner',
                            'learner_serial': e['serial'] ?? '',
                            'class_id': e['class_id'] ?? '',
                            'course_id': courseId,
                            'course_title': e['course_title'] ?? '',
                            'course_code': e['course_code'] ?? '',
                            'total_sessions': e['total_sessions'] ?? 0,
                          };
                          final markKey = _doneMarkKey(row);
                          noPaymentRows.add({
                            ...row,
                            'financePayoutStatus':
                                manualDone.contains(markKey) ||
                                    manualDone.contains(uid)
                                ? 'done'
                                : 'tbpaid',
                          });
                        }
                      }

                      final rowsToShow =
                          <Map<String, dynamic>>[
                            ..._rows,
                            ...oldWaitingRows,
                            ...noPaymentRows,
                          ]..sort((a, b) {
                            final am = _asInt(a['paidAt']);
                            final bm = _asInt(b['paidAt']);
                            if (am != bm) return bm.compareTo(am);
                            return _learnerNameFrom(a).toLowerCase().compareTo(
                              _learnerNameFrom(b).toLowerCase(),
                            );
                          });

                      var originalTotal = 0;
                      var payoutTotal = 0;
                      var waitingTotal = 0;
                      var schoolTotal = 0;
                      for (final row in rowsToShow.where(
                        (r) => !_isNoPaymentRow(r),
                      )) {
                        final effective =
                            _AdminFinanceScreenState._effectiveFinanceFromPayment(
                              row,
                            );
                        originalTotal += effective.originalAmount;
                        payoutTotal += effective.teacherNet;
                        waitingTotal += effective.waitingAmount;
                        schoolTotal += effective.schoolNet;
                      }
                      final schoolGain = originalTotal - payoutTotal;

                      return ListView(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          12,
                          12,
                          20 + MediaQuery.of(context).padding.bottom + 20,
                        ),
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _FinancePill(
                                icon: Icons.payments_rounded,
                                text: 'Total: ${widget.money(originalTotal)}',
                                strong: true,
                              ),
                              _FinancePill(
                                icon: Icons.account_balance_wallet_rounded,
                                text: 'Fee: ${widget.money(payoutTotal)}',
                                strong: true,
                              ),
                              _FinancePill(
                                icon: Icons.school_rounded,
                                text: 'School: ${widget.money(schoolTotal)}',
                                strong: true,
                              ),
                              _FinancePill(
                                icon: Icons.schedule_send_rounded,
                                text: 'Waiting: ${widget.money(waitingTotal)}',
                                strong: true,
                              ),
                              _FinancePill(
                                icon: Icons.trending_up_rounded,
                                text:
                                    'School gain: ${widget.money(schoolGain)}',
                                strong: true,
                              ),
                              _FinancePill(
                                icon: Icons.groups_rounded,
                                text: 'Learners listed: ${rowsToShow.length}',
                                strong: true,
                              ),
                              FilledButton.icon(
                                onPressed: _isPushingAll
                                    ? null
                                    : _pushAllEligibleRows,
                                icon: _isPushingAll
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.upload_rounded),
                                label: Text(
                                  _isPushingAll ? 'Pushing...' : 'Push all',
                                ),
                              ),
                              IconButton(
                                onPressed: _isClearingSetup || _isPushingAll
                                    ? null
                                    : _clearTeacherSetup,
                                tooltip: 'Clear teacher setup',
                                icon: _isClearingSetup
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.cleaning_services_rounded,
                                      ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (rowsToShow.isEmpty)
                            const Card(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Text(
                                  'No learners/payments for this teacher in selected range.',
                                ),
                              ),
                            )
                          else
                            ...(() {
                              final grouped =
                                  <String, List<Map<String, dynamic>>>{};
                              for (final row in rowsToShow) {
                                final uid = (row['uid'] ?? '')
                                    .toString()
                                    .trim();
                                final key = uid.isNotEmpty
                                    ? uid
                                    : _learnerNameFrom(row).toLowerCase();
                                grouped
                                    .putIfAbsent(
                                      key,
                                      () => <Map<String, dynamic>>[],
                                    )
                                    .add(row);
                              }
                              final keys = grouped.keys.toList()
                                ..sort((a, b) => a.compareTo(b));
                              return keys.map((key) {
                                final learnerRows = grouped[key] ?? const [];
                                if (learnerRows.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                learnerRows.sort(
                                  (a, b) => _asInt(
                                    b['paidAt'],
                                  ).compareTo(_asInt(a['paidAt'])),
                                );
                                final learnerName = _learnerNameFrom(
                                  learnerRows.first,
                                );
                                return Card(
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: BorderSide(
                                      color: Colors.black.withValues(
                                        alpha: 0.08,
                                      ),
                                    ),
                                  ),
                                  child: ExpansionTile(
                                    tilePadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    childrenPadding: const EdgeInsets.fromLTRB(
                                      12,
                                      0,
                                      12,
                                      10,
                                    ),
                                    title: Text(
                                      learnerName,
                                      style: const TextStyle(
                                        color: AdminFinanceScreen.primary,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${learnerRows.length} payment item${learnerRows.length == 1 ? '' : 's'}',
                                      style: TextStyle(
                                        color: AdminFinanceScreen.primary
                                            .withValues(alpha: 0.7),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                    children: learnerRows.map((row) {
                                      final isNoPayment = _isNoPaymentRow(row);
                                      final amount = _asInt(row['amount']);
                                      final paidAt = _fmtDateMs(
                                        _asInt(row['paidAt']),
                                      );
                                      final courseCode =
                                          (row['course_code'] ?? '')
                                              .toString()
                                              .trim();
                                      final courseTitle =
                                          (row['course_title'] ?? '')
                                              .toString()
                                              .trim();
                                      final course = courseTitle.isNotEmpty
                                          ? (courseCode.isNotEmpty
                                                ? '$courseCode · $courseTitle'
                                                : courseTitle)
                                          : (_courseIdFromRow(row).isEmpty
                                                ? '-'
                                                : _courseIdFromRow(row));
                                      final method = _methodFrom(row);
                                      final methodLabel = method == 'cash'
                                          ? 'Cash'
                                          : method == 'ccp'
                                          ? 'CCP'
                                          : 'Unspecified';
                                      final a = _amountsFrom(row);
                                      final isDone =
                                          !isNoPayment &&
                                          (a.status == 'done' ||
                                              (a.status == 'split' &&
                                                  a.waitingAmount == 0 &&
                                                  (a.splitPaidStatus ?? '') ==
                                                      'done'));
                                      final monthPaymentId =
                                          ((row['paymentId'] ?? '')
                                              .toString()
                                              .trim()
                                              .isNotEmpty)
                                          ? (row['paymentId'] ?? '')
                                                .toString()
                                                .trim()
                                          : (row['oldWaitingSourcePaymentId'] ??
                                                    '')
                                                .toString()
                                                .trim();
                                      final monthValue =
                                          (monthOverrides[monthPaymentId] ??
                                                  0) >
                                              0
                                          ? (monthOverrides[monthPaymentId] ??
                                                0)
                                          : (monthByPaymentId[monthPaymentId] ??
                                                0);
                                      final baseStyle = TextStyle(
                                        color: AdminFinanceScreen.primary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                        decoration: isDone
                                            ? TextDecoration.lineThrough
                                            : TextDecoration.none,
                                      );

                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: _statusColor(
                                            a,
                                          ).withValues(alpha: 0.08),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: _statusColor(
                                              a,
                                            ).withValues(alpha: 0.32),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 6,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Text(paidAt, style: baseStyle),
                                                Text(
                                                  widget.money(amount),
                                                  style: baseStyle.copyWith(
                                                    fontWeight: FontWeight.w900,
                                                  ),
                                                ),
                                                Text(course, style: baseStyle),
                                                if (monthPaymentId.isNotEmpty)
                                                  InkWell(
                                                    onTap: () => _editMonthOverride(
                                                      paymentId: monthPaymentId,
                                                      initialValue: monthValue,
                                                      hasOverride:
                                                          (monthOverrides[monthPaymentId] ??
                                                              0) >
                                                          0,
                                                    ),
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color:
                                                            const Color(
                                                              0xFF4B67D1,
                                                            ).withValues(
                                                              alpha: 0.1,
                                                            ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              999,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        'M${monthValue > 0 ? monthValue : '-'}',
                                                        style: const TextStyle(
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          color: Color(
                                                            0xFF4B67D1,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              'Method: $methodLabel',
                                              style: TextStyle(
                                                color: AdminFinanceScreen
                                                    .primary
                                                    .withValues(alpha: 0.75),
                                                fontWeight: FontWeight.w700,
                                                fontSize: 11,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            if (isNoPayment)
                                              Wrap(
                                                spacing: 8,
                                                children: [
                                                  OutlinedButton(
                                                    onPressed: () =>
                                                        _startOldWaitingSetup(
                                                          row,
                                                        ),
                                                    child: const Text(
                                                      'Add old waiting',
                                                    ),
                                                  ),
                                                  OutlinedButton(
                                                    onPressed: () =>
                                                        _setManualDone(
                                                          row,
                                                          !(manualDone.contains(
                                                                _doneMarkKey(
                                                                  row,
                                                                ),
                                                              ) ||
                                                              manualDone.contains(
                                                                (row['uid'] ??
                                                                        '')
                                                                    .toString()
                                                                    .trim(),
                                                              )),
                                                        ),
                                                    child: const Text(
                                                      'Toggle done',
                                                    ),
                                                  ),
                                                ],
                                              )
                                            else
                                              Wrap(
                                                spacing: 8,
                                                runSpacing: 6,
                                                children: [
                                                  OutlinedButton(
                                                    onPressed: () =>
                                                        _setDoneQuick(row),
                                                    child: const Text('Done'),
                                                  ),
                                                  OutlinedButton(
                                                    onPressed: () =>
                                                        _setWaitingQuick(row),
                                                    child: const Text(
                                                      'Waiting',
                                                    ),
                                                  ),
                                                  OutlinedButton(
                                                    onPressed: () =>
                                                        _editSplitBreakdown(
                                                          row,
                                                        ),
                                                    child: const Text('Split'),
                                                  ),
                                                  OutlinedButton(
                                                    onPressed: () =>
                                                        _pickMethod(row),
                                                    child: const Text('Method'),
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                );
                              }).toList();
                            }()),
                        ],
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _FilterHeader extends StatelessWidget {
  const _FilterHeader({
    required this.fromLabel,
    required this.toLabel,
    required this.onPickFrom,
    required this.onPickTo,
    required this.onReset,
    required this.originalIncome,
    required this.waitingTotal,
    required this.originalByMethod,
    required this.waitingByMethod,
    required this.teachersCount,
    required this.financeCycleLabel,
    required this.onFreshStart,
  });

  final String fromLabel;
  final String toLabel;
  final VoidCallback onPickFrom;
  final VoidCallback onPickTo;
  final VoidCallback onReset;
  final String originalIncome;
  final String waitingTotal;
  final _MethodTotals originalByMethod;
  final _MethodTotals waitingByMethod;
  final int teachersCount;
  final String financeCycleLabel;
  final VoidCallback onFreshStart;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.07)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: onPickFrom,
              icon: const Icon(Icons.calendar_today_rounded, size: 16),
              label: Text(fromLabel),
            ),
            OutlinedButton.icon(
              onPressed: onPickTo,
              icon: const Icon(Icons.event_rounded, size: 16),
              label: Text(toLabel),
            ),
            TextButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.filter_alt_off_rounded, size: 17),
              label: const Text('Reset filter'),
            ),
            const SizedBox(width: 4),
            _FinancePill(
              icon: Icons.savings_rounded,
              text: 'Income: $originalIncome',
              strong: true,
            ),
            _FinancePill(
              icon: Icons.schedule_send_rounded,
              text: 'Waiting: $waitingTotal',
              strong: true,
            ),
            OutlinedButton.icon(
              onPressed: () {
                showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (sheetContext) {
                    return SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Finance summary',
                                style: TextStyle(
                                  color: AdminFinanceScreen.primary,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _FinancePill(
                                    icon: Icons.point_of_sale_rounded,
                                    text:
                                        'Income Cash/CCP/Un: ${originalByMethod.cash}/${originalByMethod.ccp}/${originalByMethod.unspecified}',
                                  ),
                                  _FinancePill(
                                    icon: Icons.hourglass_top_rounded,
                                    text:
                                        'Waiting Cash/CCP/Un: ${waitingByMethod.cash}/${waitingByMethod.ccp}/${waitingByMethod.unspecified}',
                                  ),
                                  _FinancePill(
                                    icon: Icons.badge_rounded,
                                    text: 'Teachers: $teachersCount',
                                    strong: true,
                                  ),
                                  _FinancePill(
                                    icon: Icons.event_repeat_rounded,
                                    text: financeCycleLabel,
                                    strong: true,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  TextButton.icon(
                                    onPressed: () {
                                      Navigator.of(sheetContext).pop();
                                      onReset();
                                    },
                                    icon: const Icon(
                                      Icons.filter_alt_off_rounded,
                                      size: 17,
                                    ),
                                    label: const Text('Reset filter'),
                                  ),
                                  FilledButton.icon(
                                    onPressed: () {
                                      Navigator.of(sheetContext).pop();
                                      onFreshStart();
                                    },
                                    icon: const Icon(Icons.restart_alt_rounded),
                                    label: const Text('Fresh start'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
              icon: const Icon(Icons.info_outline_rounded, size: 16),
              label: const Text('More'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FinancePayoutPeriodRecord {
  const _FinancePayoutPeriodRecord({
    required this.id,
    required this.startDate,
    required this.startAtMs,
    required this.endDate,
    required this.endAtMs,
    required this.isActive,
  });

  final String id;
  final String startDate;
  final int startAtMs;
  final String endDate;
  final int endAtMs;
  final bool isActive;

  factory _FinancePayoutPeriodRecord.fromMap({
    required String id,
    required Map<String, dynamic> map,
  }) {
    return _FinancePayoutPeriodRecord(
      id: id,
      startDate: (map['startDate'] ?? '').toString().trim(),
      startAtMs: _AdminFinanceScreenState._asInt(map['startAtMs']),
      endDate: (map['endDate'] ?? '').toString().trim(),
      endAtMs: _AdminFinanceScreenState._asInt(map['endAtMs']),
      isActive: map['isActive'] == true,
    );
  }

  String get displayLabel => _AdminFinanceScreenState._financePeriodLabel(
    startDate: startDate,
    endDate: endDate,
  );
}

class _FinanceAmounts {
  const _FinanceAmounts({
    required this.amount,
    required this.status,
    required this.splitPaidStatus,
    required this.payoutAmount,
    required this.waitingAmount,
  });

  final int amount;
  final String status;
  final String? splitPaidStatus;
  final int payoutAmount;
  final int waitingAmount;
}

class _SessionCounts {
  const _SessionCounts({this.held = 0, this.present = 0});

  final int held;
  final int present;
}

class _TeacherCardData {
  const _TeacherCardData({
    required this.teacherId,
    required this.teacherScopeKey,
    required this.teacherName,
    required this.originalTotal,
    required this.payoutTotal,
    required this.waitingTotal,
    required this.originalByMethod,
    required this.payoutByMethod,
    required this.waitingByMethod,
    required this.learnersCount,
    required this.doneLearnersCount,
    required this.paymentsCount,
    required this.schoolTotal,
    required this.progressDoneSessions,
    required this.progressTotalSessions,
    required this.payments,
  });

  final String teacherId;
  final String teacherScopeKey;
  final String teacherName;
  final int originalTotal;
  final int payoutTotal;
  final int waitingTotal;
  final _MethodTotals originalByMethod;
  final _MethodTotals payoutByMethod;
  final _MethodTotals waitingByMethod;
  final int learnersCount;
  final int doneLearnersCount;
  final int paymentsCount;
  final int schoolTotal;
  final int progressDoneSessions;
  final int progressTotalSessions;
  final List<Map<String, dynamic>> payments;
}

class _FinancePill extends StatelessWidget {
  const _FinancePill({
    required this.icon,
    required this.text,
    this.strong = false,
    this.bg,
    this.fg,
    this.border,
  });

  final IconData icon;
  final String text;
  final bool strong;
  final Color? bg;
  final Color? fg;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: bg ?? AdminFinanceScreen.appBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: border ?? Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: fg ?? AdminFinanceScreen.primary.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: fg ?? AdminFinanceScreen.primary.withValues(alpha: 0.92),
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({
    required this.totalWaiting,
    required this.byMethod,
    required this.money,
    required this.onTap,
  });

  final int totalWaiting;
  final _MethodTotals byMethod;
  final String Function(int amount) money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _CompactSummaryCard(
      title: 'Waiting',
      amount: money(totalWaiting),
      subtitle:
          'Cash ${money(byMethod.cash)} · CCP ${money(byMethod.ccp)} · Un ${money(byMethod.unspecified)}',
      backgroundColor: const Color(0xFFFFF6EC),
      borderColor: Colors.orange.withValues(alpha: 0.22),
      onTap: onTap,
    );
  }
}

class _SchoolCard extends StatelessWidget {
  const _SchoolCard({
    required this.totalSchool,
    required this.byMethod,
    required this.money,
    required this.onTap,
  });

  final int totalSchool;
  final _MethodTotals byMethod;
  final String Function(int amount) money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _CompactSummaryCard(
      title: 'School (Pushed Only)',
      amount: money(totalSchool),
      subtitle:
          'Cash ${money(byMethod.cash)} · CCP ${money(byMethod.ccp)} · Un ${money(byMethod.unspecified)}',
      backgroundColor: const Color(0xFFEFF4FF),
      borderColor: const Color(0xFF3666D8).withValues(alpha: 0.28),
      onTap: onTap,
    );
  }
}

class _CompactSummaryCard extends StatelessWidget {
  const _CompactSummaryCard({
    required this.title,
    required this.amount,
    required this.subtitle,
    required this.backgroundColor,
    required this.borderColor,
    required this.onTap,
  });

  final String title;
  final String amount;
  final String subtitle;
  final Color backgroundColor;
  final Color borderColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Card(
        elevation: 0,
        color: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: borderColor),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AdminFinanceScreen.primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                amount,
                style: const TextStyle(
                  color: AdminFinanceScreen.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: AdminFinanceScreen.primary.withValues(alpha: 0.74),
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResponsiveCardWrap extends StatelessWidget {
  const _ResponsiveCardWrap({
    required this.children,
    this.minItemWidth = 320,
    this.maxColumns = 2,
  });

  final List<Widget> children;
  final double minItemWidth;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        final availableWidth = constraints.maxWidth;
        var columns = (availableWidth / minItemWidth).floor();
        if (columns < 1) columns = 1;
        if (columns > maxColumns) columns = maxColumns;
        final totalSpacing = spacing * (columns - 1);
        final itemWidth = (availableWidth - totalSpacing) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: children
              .map((child) => SizedBox(width: itemWidth, child: child))
              .toList(),
        );
      },
    );
  }
}

class _TeacherSquareCard extends StatelessWidget {
  const _TeacherSquareCard({
    required this.data,
    required this.money,
    required this.onTap,
    required this.onClearSetup,
    this.isClearingSetup = false,
  });

  final _TeacherCardData data;
  final String Function(int amount) money;
  final VoidCallback onTap;
  final VoidCallback onClearSetup;
  final bool isClearingSetup;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.07)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    data.teacherName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AdminFinanceScreen.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      height: 1.05,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: isClearingSetup ? null : onClearSetup,
                      tooltip: 'Clear setup',
                      icon: isClearingSetup
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cleaning_services_rounded),
                    ),
                    TextButton.icon(
                      onPressed: onTap,
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: const Text('Open'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _FinancePill(
                  icon: Icons.account_balance_wallet_rounded,
                  text: 'Income ${money(data.originalTotal)}',
                  strong: true,
                ),
                _FinancePill(
                  icon: Icons.payments_rounded,
                  text: 'Teacher ${money(data.payoutTotal)}',
                  bg: AdminFinanceScreen.tbpaid.withValues(alpha: 0.08),
                  fg: AdminFinanceScreen.tbpaid,
                  border: AdminFinanceScreen.tbpaid.withValues(alpha: 0.22),
                  strong: true,
                ),
                _FinancePill(
                  icon: Icons.school_rounded,
                  text: 'School ${money(data.schoolTotal)}',
                  bg: const Color(0xFF3666D8).withValues(alpha: 0.08),
                  fg: const Color(0xFF3666D8),
                  border: const Color(0xFF3666D8).withValues(alpha: 0.22),
                  strong: true,
                ),
                _FinancePill(
                  icon: Icons.schedule_send_rounded,
                  text: 'Waiting ${money(data.waitingTotal)}',
                  bg: AdminFinanceScreen.waiting.withValues(alpha: 0.1),
                  fg: const Color(0xFF8A5A00),
                  border: AdminFinanceScreen.waiting.withValues(alpha: 0.28),
                  strong: true,
                ),
                _FinancePill(
                  icon: Icons.groups_rounded,
                  text: 'Learners ${data.learnersCount}',
                  strong: true,
                ),
                _FinancePill(
                  icon: Icons.receipt_long_rounded,
                  text: 'Payments ${data.paymentsCount}',
                  strong: true,
                ),
                _FinancePill(
                  icon: Icons.verified_user_rounded,
                  text: 'Done ${data.doneLearnersCount}',
                  bg: AdminFinanceScreen.done.withValues(alpha: 0.08),
                  fg: AdminFinanceScreen.done,
                  border: AdminFinanceScreen.done.withValues(alpha: 0.22),
                  strong: true,
                ),
              ],
            ),
            if (data.progressTotalSessions > 0) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AdminFinanceScreen.appBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.07),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Session progress',
                      style: TextStyle(
                        color: AdminFinanceScreen.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${data.progressDoneSessions}/${data.progressTotalSessions}',
                      style: const TextStyle(
                        color: AdminFinanceScreen.primary,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value:
                            (data.progressDoneSessions /
                                    data.progressTotalSessions)
                                .clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: Colors.white,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF157A3D),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EffectiveFinanceAmounts {
  const _EffectiveFinanceAmounts({
    required this.originalAmount,
    required this.teacherNet,
    required this.schoolNet,
    required this.waitingAmount,
    required this.method,
  });

  final int originalAmount;
  final int teacherNet;
  final int schoolNet;
  final int waitingAmount;
  final String method;
}

class _MethodTotals {
  const _MethodTotals({
    required this.cash,
    required this.ccp,
    required this.unspecified,
  });

  final int cash;
  final int ccp;
  final int unspecified;
}
