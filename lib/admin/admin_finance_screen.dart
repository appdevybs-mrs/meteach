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

  bool _unlocked = false;
  bool _loadingFilter = true;
  DateTime? _fromDate;
  DateTime? _toDate;

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

  void _replacePaymentRow(Map<String, dynamic> payment) {
    final paymentId = (payment['paymentId'] ?? '').toString().trim();
    if (paymentId.isEmpty) return;
    final next = payment.map((k, v) => MapEntry(k.toString(), v));
    final index = _rows.indexWhere(
      (row) => (row['paymentId'] ?? '').toString().trim() == paymentId,
    );
    if (index < 0) return;
    setState(() {
      _rows[index] = next.cast<String, dynamic>();
      _rows.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));
    });
  }

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

  int _teacherPercentFrom(Map<String, dynamic> row) {
    if (row['isFinanceAllocation'] == true) {
      final p = _asInt(row['financeTeacherPercent']);
      if (p <= 0) return 100;
      if (p > 100) return 100;
      return p;
    }
    if (row['financeAllocations'] is Map) {
      final allocations = financeAllocationsFromPayment(row);
      if (allocations.length == 1) return allocations.first.teacherPercent;
      if (allocations.isNotEmpty) return 0;
    }
    final p = _asInt(row['financeTeacherPercent']);
    if (p <= 0) return 100;
    if (p > 100) return 100;
    return p;
  }

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher' || r == 'teachers' || r == 'teacher(s)';
  }

  String _teacherLabelFor(String uid, Map<String, dynamic> row) {
    final first = (row['first_name'] ?? row['firstName'] ?? '')
        .toString()
        .trim();
    final last = (row['last_name'] ?? row['lastName'] ?? '').toString().trim();
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    final name = (row['name'] ?? row['full_name'] ?? row['fullName'] ?? '')
        .toString()
        .trim();
    if (name.isNotEmpty) return name;
    final email = (row['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;
    return uid;
  }

  Future<List<Map<String, String>>> _loadTeachers() async {
    final snap = await widget.usersRef.get();
    final raw = snap.value;
    final out = <Map<String, String>>[];
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is! Map) return;
        final row = v.map((kk, vv) => MapEntry(kk.toString(), vv));
        if (!_isTeacherRole(row['role'])) return;
        final uid = k.toString().trim();
        if (uid.isEmpty) return;
        out.add({'uid': uid, 'name': _teacherLabelFor(uid, row)});
      });
    }
    out.sort(
      (a, b) => (a['name'] ?? '').toLowerCase().compareTo(
        (b['name'] ?? '').toLowerCase(),
      ),
    );
    return out;
  }

  Future<void> _openAllocationEditor(Map<String, dynamic> row) async {
    final paymentId = (row['paymentId'] ?? '').toString().trim();
    if (paymentId.isEmpty) return;
    final variantKey = _variantKeyFrom(row);
    final isFlexible = variantKey == 'flexible';
    final isRecorded = variantKey == 'recorded';
    if (!isFlexible && !isRecorded) return;

    final payout = _amountsFrom(row);
    final totalAmount = payout.payoutAmount;
    final totalSessions = _asInt(row['sessionsPaid']);
    final existingAllocations = financeAllocationsFromPayment(
      row,
    ).where((a) => !a.isLegacy || row['financeAllocations'] is Map).toList();
    final teachers = await _loadTeachers();
    if (!mounted) return;

    final entries = <Map<String, dynamic>>[];
    if (existingAllocations.isNotEmpty && row['financeAllocations'] is Map) {
      for (final alloc in existingAllocations) {
        entries.add({
          'teacherId': alloc.teacherId,
          'teacherName': alloc.teacherName,
          'assignedSessions': alloc.assignedSessions ?? 0,
          'teacherPercent': alloc.teacherPercent,
        });
      }
    } else {
      entries.add({
        'teacherId': (row['teacherId'] ?? '').toString().trim(),
        'teacherName': _teacherLabelFrom(row),
        'assignedSessions': isFlexible
            ? (totalSessions > 0 ? totalSessions : 1)
            : 0,
        'teacherPercent': _initialTeacherPercentForPicker(row),
      });
    }

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setD) {
            List<int> distributed = const [];
            if (isFlexible) {
              distributed = distributeAmountBySessions(
                totalAmount: totalAmount,
                assignedSessions: entries
                    .map((e) => _asInt(e['assignedSessions']))
                    .toList(),
              );
            } else {
              distributed = [totalAmount];
            }

            return AlertDialog(
              title: Text(
                isFlexible ? 'Flexible allocations' : 'Recorded allocation',
              ),
              content: SizedBox(
                width: 760,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isFlexible
                            ? 'Assign teacher rows and session split. Money follows assigned sessions.'
                            : 'Assign one teacher and percentage for this recorded payment.',
                      ),
                      const SizedBox(height: 12),
                      ...entries.asMap().entries.map((entry) {
                        final index = entry.key;
                        final item = entry.value;
                        final grossShare = distributed.length > index
                            ? distributed[index]
                            : 0;
                        final percent = _pickerPercent(
                          _asInt(item['teacherPercent']),
                        );
                        final teacherNet = ((grossShare * percent) / 100)
                            .round();
                        final schoolNet = grossShare - teacherNet;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.black.withValues(alpha: 0.08),
                              ),
                            ),
                            child: Column(
                              children: [
                                DropdownButtonFormField<String>(
                                  initialValue:
                                      (item['teacherId'] ?? '')
                                          .toString()
                                          .trim()
                                          .isEmpty
                                      ? null
                                      : (item['teacherId'] ?? '')
                                            .toString()
                                            .trim(),
                                  decoration: const InputDecoration(
                                    labelText: 'Teacher',
                                  ),
                                  items: teachers
                                      .map(
                                        (teacher) => DropdownMenuItem<String>(
                                          value: teacher['uid'],
                                          child: Text(teacher['name'] ?? ''),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) {
                                    final selected = teachers.firstWhere(
                                      (teacher) => teacher['uid'] == value,
                                      orElse: () => const {
                                        'uid': '',
                                        'name': '',
                                      },
                                    );
                                    setD(() {
                                      item['teacherId'] = selected['uid'] ?? '';
                                      item['teacherName'] =
                                          selected['name'] ?? '';
                                    });
                                  },
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    if (isFlexible)
                                      Expanded(
                                        child: TextFormField(
                                          initialValue:
                                              '${_asInt(item['assignedSessions'])}',
                                          keyboardType: TextInputType.number,
                                          decoration: const InputDecoration(
                                            labelText: 'Assigned sessions',
                                          ),
                                          onChanged: (value) =>
                                              item['assignedSessions'] =
                                                  int.tryParse(value.trim()) ??
                                                  0,
                                        ),
                                      ),
                                    if (isFlexible) const SizedBox(width: 10),
                                    Expanded(
                                      child: DropdownButtonFormField<int>(
                                        initialValue: percent,
                                        decoration: const InputDecoration(
                                          labelText: 'Teacher %',
                                        ),
                                        items:
                                            List<int>.generate(
                                                  66,
                                                  (i) => i + 35,
                                                )
                                                .map(
                                                  (value) =>
                                                      DropdownMenuItem<int>(
                                                        value: value,
                                                        child: Text('$value%'),
                                                      ),
                                                )
                                                .toList(),
                                        onChanged: (value) {
                                          if (value == null) return;
                                          setD(
                                            () =>
                                                item['teacherPercent'] = value,
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Gross: ${widget.money(grossShare)} · Teacher: ${widget.money(teacherNet)} · School: ${widget.money(schoolNet)} · School %: ${100 - percent}%',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (entries.length > 1)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      onPressed: () =>
                                          setD(() => entries.removeAt(index)),
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                      label: const Text('Remove row'),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }),
                      if (isFlexible)
                        Text(
                          'Assigned total: ${entries.fold<int>(0, (sum, item) => sum + _asInt(item['assignedSessions']))} / $totalSessions sessions',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: isRecorded && entries.isNotEmpty
                            ? null
                            : () => setD(() {
                                entries.add({
                                  'teacherId': '',
                                  'teacherName': '',
                                  'assignedSessions': isFlexible ? 1 : 0,
                                  'teacherPercent': 50,
                                });
                              }),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add row'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (entries.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Add at least one teacher row.'),
                        ),
                      );
                      return;
                    }
                    if (isRecorded && entries.length != 1) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Recorded allows one teacher only.'),
                        ),
                      );
                      return;
                    }
                    for (final item in entries) {
                      if ((item['teacherId'] ?? '').toString().trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Each row needs a teacher.'),
                          ),
                        );
                        return;
                      }
                    }
                    if (isFlexible) {
                      final assignedTotal = entries.fold<int>(
                        0,
                        (sum, item) => sum + _asInt(item['assignedSessions']),
                      );
                      if (assignedTotal != totalSessions) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Assigned sessions must equal $totalSessions.',
                            ),
                          ),
                        );
                        return;
                      }
                    }

                    final grossShares = isFlexible
                        ? distributeAmountBySessions(
                            totalAmount: totalAmount,
                            assignedSessions: entries
                                .map((item) => _asInt(item['assignedSessions']))
                                .toList(),
                          )
                        : <int>[totalAmount];

                    final payload = <String, dynamic>{};
                    var teacherTotal = 0;
                    var schoolTotal = 0;
                    for (var i = 0; i < entries.length; i++) {
                      final item = entries[i];
                      final grossShare = grossShares[i];
                      final allocation = buildFinanceAllocationPayload(
                        teacherId: (item['teacherId'] ?? '').toString().trim(),
                        teacherName: (item['teacherName'] ?? '')
                            .toString()
                            .trim(),
                        variantKey: variantKey,
                        grossShare: grossShare,
                        teacherPercent: _asInt(item['teacherPercent']),
                        assignedSessions: isFlexible
                            ? _asInt(item['assignedSessions'])
                            : null,
                      );
                      teacherTotal += financeAsInt(allocation['teacherNet']);
                      schoolTotal += financeAsInt(allocation['schoolNet']);
                      payload['alloc_${i + 1}'] = allocation;
                    }

                    final first = entries.first;
                    try {
                      await widget.paymentsRef.child(paymentId).update({
                        'financeAllocations': payload,
                        'teacherId': isRecorded
                            ? (first['teacherId'] ?? '').toString().trim()
                            : '',
                        'teacherName': isRecorded
                            ? (first['teacherName'] ?? '').toString().trim()
                            : (isFlexible ? 'Flexible' : ''),
                        'financeTeacherGross': totalAmount,
                        'financeTeacherNet': teacherTotal,
                        'financeSchoolNet': schoolTotal,
                        'financeTeacherPercent': isRecorded
                            ? _asInt(first['teacherPercent'])
                            : 0,
                        'financePushedAt': null,
                        'financePushedBy': null,
                        'financePushedStatus': null,
                        'financeUpdatedAt': ServerValue.timestamp,
                      });
                      final refreshedSnap = await widget.paymentsRef
                          .child(paymentId)
                          .get();
                      if (refreshedSnap.value is Map && mounted) {
                        final refreshed = (refreshedSnap.value as Map).map(
                          (k, v) => MapEntry(k.toString(), v),
                        );
                        refreshed['paymentId'] = paymentId;
                        _replacePaymentRow(refreshed.cast<String, dynamic>());
                      }
                      if (!context.mounted) return;
                      Navigator.of(dialogCtx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Allocations saved successfully.'),
                        ),
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Could not save allocations: $e'),
                        ),
                      );
                    }
                  },
                  child: const Text('Save allocations'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  int _initialTeacherPercentForPicker(Map<String, dynamic> row) {
    final p = _asInt(row['financeTeacherPercent']);
    if (p <= 0) return 50;
    if (p < 35) return 35;
    if (p > 100) return 100;
    return p;
  }

  String _variantKeyFrom(Map<String, dynamic> row) {
    return normalizeVariantKey(
      (row['variantKey'] ?? row['variant'] ?? row['deliveryKey'] ?? '')
          .toString(),
      fallback: 'inclass',
    );
  }

  String _studyModeFrom(Map<String, dynamic> row) {
    return normalizeStudyMode(
      (row['studyMode'] ??
              row['study_mode'] ??
              row['privateStudyMode'] ??
              row['private_study_mode'] ??
              '')
          .toString(),
      variantKey: _variantKeyFrom(row),
    );
  }

  _VariantVisual _variantVisualFrom(Map<String, dynamic> row) {
    final variantKey = _variantKeyFrom(row);
    final studyMode = _studyModeFrom(row);
    final label = variantLabelWithStudyMode(
      variantKey: variantKey,
      studyMode: studyMode,
    );

    switch (variantKey) {
      case 'private':
        if (studyMode == 'online') {
          return _VariantVisual(
            label: label,
            icon: Icons.videocam_rounded,
            color: const Color(0xFF178F8B),
          );
        }
        return _VariantVisual(
          label: label,
          icon: Icons.person_rounded,
          color: const Color(0xFF178F8B),
        );
      case 'flexible':
        return _VariantVisual(
          label: label,
          icon: Icons.schedule_rounded,
          color: const Color(0xFFF0A526),
        );
      case 'recorded':
        return _VariantVisual(
          label: label,
          icon: Icons.play_circle_fill_rounded,
          color: const Color(0xFFD14B4B),
        );
      case 'inclass':
      default:
        return _VariantVisual(
          label: label,
          icon: Icons.school_rounded,
          color: const Color(0xFF3666D8),
        );
    }
  }

  static int _pickerPercent(int v) {
    if (v < 35) return 35;
    if (v > 100) return 100;
    return v;
  }

  Future<int?> _askPercent(int initial) {
    int selected = _pickerPercent(initial);
    final options = List<int>.generate(66, (i) => i + 35);
    return showDialog<int>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (_, setD) {
            return AlertDialog(
              title: const Text('Teacher percentage'),
              content: DropdownButtonFormField<int>(
                initialValue: selected,
                decoration: const InputDecoration(
                  labelText: 'Share % (35-100)',
                ),
                items: options
                    .map(
                      (p) =>
                          DropdownMenuItem<int>(value: p, child: Text('$p%')),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setD(() => selected = v);
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(selected),
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _setMethod(Map<String, dynamic> row, String method) async {
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
    final raw = (row['financeMethod'] ?? row['method'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
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

  Widget _pulseIfMissing({required bool missing, required Widget child}) {
    final active = missing;
    final scale = active ? (_pulseOn ? 1.045 : 0.96) : 1.0;
    final opacity = active ? (_pulseOn ? 1.0 : 0.72) : 1.0;
    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOut,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeInOut,
        child: child,
      ),
    );
  }

  Future<void> _setTeacherPercent(Map<String, dynamic> row) async {
    final variantKey = _variantKeyFrom(row);
    if (variantKey == 'flexible' || variantKey == 'recorded') {
      await _openAllocationEditor(row);
      return;
    }
    final paymentId = (row['paymentId'] ?? '').toString().trim();
    if (paymentId.isEmpty) return;

    if (_isEffectiveSchoolOnly(row)) {
      final alloc = _amountsFrom(row);
      final gross = alloc.payoutAmount;
      await widget.paymentsRef.child(paymentId).update({
        'financeTeacherPercent': 0,
        'financeTeacherGross': gross,
        'financeTeacherNet': 0,
        'financeSchoolNet': gross,
        'financePushedAt': null,
        'financePushedBy': null,
        'financePushedStatus': null,
        'financeUpdatedAt': ServerValue.timestamp,
      });
      if (!mounted) return;
      setState(() {
        row['financeTeacherPercent'] = 0;
        row['financeTeacherGross'] = gross;
        row['financeTeacherNet'] = 0;
        row['financeSchoolNet'] = gross;
        row.remove('financePushedAt');
        row.remove('financePushedBy');
        row.remove('financePushedStatus');
      });
      return;
    }

    final p = await _askPercent(_initialTeacherPercentForPicker(row));
    if (p == null) return;

    final alloc = _amountsFrom(row);
    final gross = alloc.payoutAmount;
    final teacherNet = ((gross * p) / 100).round();
    final schoolNet = gross - teacherNet;
    await widget.paymentsRef.child(paymentId).update({
      'financeTeacherPercent': p,
      'financeTeacherGross': gross,
      'financeTeacherNet': teacherNet,
      'financeSchoolNet': schoolNet,
      'financePushedAt': null,
      'financePushedBy': null,
      'financePushedStatus': null,
      'financeUpdatedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    setState(() {
      row['financeTeacherPercent'] = p;
      row['financeTeacherGross'] = gross;
      row['financeTeacherNet'] = teacherNet;
      row['financeSchoolNet'] = schoolNet;
      row.remove('financePushedAt');
      row.remove('financePushedBy');
      row.remove('financePushedStatus');
    });
  }

  Future<void> _toggleSchoolOnlyLock(Map<String, dynamic> row) async {
    final paymentId = (row['paymentId'] ?? '').toString().trim();
    if (paymentId.isEmpty) return;
    if (!_isSchoolOnlyTeacherLabel(row)) return;

    final newUnlocked = !_isTeacherShareUnlocked(row);
    await widget.paymentsRef.child(paymentId).update({
      'financeTeacherShareUnlocked': newUnlocked,
      'financeUpdatedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    setState(() {
      row['financeTeacherShareUnlocked'] = newUnlocked;
    });

    if (!newUnlocked) {
      await _setTeacherPercent(row);
    }
  }

  String _fmtDateMs(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _editPaymentStatus(Map<String, dynamic> row) async {
    var status = _normalizeStatus(row['financePayoutStatus']);
    var splitPaidStatus =
        _normalizeStatus(row['financeSplitPaidStatus']) == 'done'
        ? 'done'
        : 'tbpaid';
    final amount = _asInt(row['amount']);
    final existingSplitPaid = _asInt(row['financeSplitPaidAmount']);
    final existingSplitWaiting = _asInt(row['financeSplitWaitingAmount']);
    final defaultSplitPaid = amount ~/ 2;
    final defaultSplitWaiting = amount - defaultSplitPaid;

    final paidCtrl = TextEditingController(
      text: existingSplitPaid > 0
          ? existingSplitPaid.toString()
          : defaultSplitPaid.toString(),
    );
    final waitingCtrl = TextEditingController(
      text: existingSplitWaiting > 0
          ? existingSplitWaiting.toString()
          : defaultSplitWaiting.toString(),
    );

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (_, setD) {
            return AlertDialog(
              title: const Text('Set learner payment status'),
              content: SizedBox(
                width: 430,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Done'),
                            selected: status == 'done',
                            selectedColor: const Color(0xFFDDF5E8),
                            onSelected: (_) => setD(() => status = 'done'),
                          ),
                          ChoiceChip(
                            label: const Text('Ready'),
                            selected: status == 'tbpaid',
                            selectedColor: const Color(0xFFDCE8FF),
                            onSelected: (_) => setD(() => status = 'tbpaid'),
                          ),
                          ChoiceChip(
                            label: const Text('Split'),
                            selected: status == 'split',
                            selectedColor: const Color(0xFFFFEDD9),
                            onSelected: (_) => setD(() {
                              status = 'split';
                              if (existingSplitPaid <= 0 &&
                                  existingSplitWaiting <= 0) {
                                paidCtrl.text = defaultSplitPaid.toString();
                                waitingCtrl.text = defaultSplitWaiting
                                    .toString();
                              }
                            }),
                          ),
                        ],
                      ),
                      if (status == 'split') ...[
                        const SizedBox(height: 14),
                        DropdownButtonFormField<String>(
                          initialValue: splitPaidStatus,
                          decoration: const InputDecoration(
                            labelText: 'Ready part marked as',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'done',
                              child: Text('Done'),
                            ),
                            DropdownMenuItem(
                              value: 'tbpaid',
                              child: Text('Ready'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setD(() => splitPaidStatus = v);
                          },
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: paidCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Ready amount',
                            hintText: 'Amount ready or received',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: waitingCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Pending amount',
                            hintText: 'Amount left',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final out = <String, dynamic>{'status': status};
                    if (status == 'split') {
                      final paid = int.tryParse(paidCtrl.text.trim()) ?? -1;
                      final waiting =
                          int.tryParse(waitingCtrl.text.trim()) ?? -1;
                      if (paid < 0 || waiting < 0 || paid + waiting != amount) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Split requires two valid amounts and they must equal full payment.',
                            ),
                          ),
                        );
                        return;
                      }
                      out['splitPaidAmount'] = paid;
                      out['splitWaitingAmount'] = waiting;
                      out['splitPaidStatus'] = splitPaidStatus;
                    }
                    Navigator.of(dialogCtx).pop(out);
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
    final paymentId = (row['paymentId'] ?? '').toString().trim();
    if (paymentId.isEmpty) return;

    final statusResult = _normalizeStatus(result['status']);
    final updates = <String, dynamic>{
      'financePayoutStatus': statusResult,
      'financePushedAt': null,
      'financePushedBy': null,
      'financePushedStatus': null,
      'financeUpdatedAt': ServerValue.timestamp,
    };

    if (statusResult == 'split') {
      updates['financeSplitPaidAmount'] = _asInt(result['splitPaidAmount']);
      updates['financeSplitWaitingAmount'] = _asInt(
        result['splitWaitingAmount'],
      );
      updates['financeSplitPaidStatus'] =
          _normalizeStatus(result['splitPaidStatus']) == 'done'
          ? 'done'
          : 'tbpaid';
    } else {
      updates['financeSplitPaidAmount'] = null;
      updates['financeSplitWaitingAmount'] = null;
      updates['financeSplitPaidStatus'] = null;
    }

    await widget.paymentsRef.child(paymentId).update(updates);

    if (!mounted) return;
    setState(() {
      row['financePayoutStatus'] = statusResult;
      row.remove('financePushedAt');
      row.remove('financePushedBy');
      row.remove('financePushedStatus');
      if (statusResult == 'split') {
        row['financeSplitPaidAmount'] = _asInt(result['splitPaidAmount']);
        row['financeSplitWaitingAmount'] = _asInt(result['splitWaitingAmount']);
        row['financeSplitPaidStatus'] = updates['financeSplitPaidStatus'];
      } else {
        row.remove('financeSplitPaidAmount');
        row.remove('financeSplitWaitingAmount');
        row.remove('financeSplitPaidStatus');
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Learner payout status updated.')),
    );
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

  List<Map<String, String>> _teacherClassRoster(dynamic raw) {
    final out = <Map<String, String>>[];
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
        });
      }
    }
    return out;
  }

  Map<String, _SessionCounts> _attendanceCountsByLearnerCourse(dynamic raw) {
    final out = <String, _SessionCounts>{};
    if (raw is! Map) return out;
    final classes = Map<dynamic, dynamic>.from(raw);
    final teacherId = widget.teacherId.trim();
    final teacherName = widget.teacherName.trim().toLowerCase();

    for (final e in classes.entries) {
      final clsRaw = e.value;
      if (clsRaw is! Map) continue;
      final cls = Map<dynamic, dynamic>.from(clsRaw);

      String instUid = '';
      final instCur = cls['instructor_current'];
      if (instCur is Map) {
        instUid = (instCur['uid'] ?? '').toString().trim();
      }
      final instName = (cls['instructor'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final classMatchByUid =
          teacherId.isNotEmpty && instUid.isNotEmpty && instUid == teacherId;
      final classMatchByName =
          teacherId.isEmpty &&
          teacherName.isNotEmpty &&
          instUid.isEmpty &&
          instName == teacherName;
      if (!classMatchByUid && !classMatchByName) continue;

      final courseId = (cls['course_id'] ?? '').toString().trim();
      if (courseId.isEmpty) continue;

      final attendanceRaw = cls['attendance'];
      if (attendanceRaw is! Map) continue;
      final attendance = Map<dynamic, dynamic>.from(attendanceRaw);
      for (final recEntry in attendance.entries) {
        final recRaw = recEntry.value;
        if (recRaw is! Map) continue;
        final rec = Map<dynamic, dynamic>.from(recRaw);

        final recTeacherUid = (rec['teacherUid'] ?? '').toString().trim();
        final recTeacherName = (rec['teacherName'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final taughtByTeacher = teacherId.isNotEmpty
            ? (recTeacherUid.isEmpty
                  ? classMatchByUid
                  : recTeacherUid == teacherId)
            : (recTeacherName.isNotEmpty
                  ? recTeacherName == teacherName
                  : classMatchByName);
        if (!taughtByTeacher) continue;

        final present = (rec['present'] is Map)
            ? Map<dynamic, dynamic>.from(rec['present'] as Map)
            : <dynamic, dynamic>{};
        final absent = (rec['absent'] is Map)
            ? Map<dynamic, dynamic>.from(rec['absent'] as Map)
            : <dynamic, dynamic>{};
        final allUids = <String>{
          ...present.keys.map((k) => k.toString().trim()),
          ...absent.keys.map((k) => k.toString().trim()),
        }..removeWhere((x) => x.isEmpty);

        for (final uid in allUids) {
          final key = _sessionKey(uid: uid, courseId: courseId);
          final cur = out[key] ?? const _SessionCounts();
          out[key] = _SessionCounts(held: cur.held + 1, present: cur.present);
        }

        for (final uid in present.keys.map((k) => k.toString().trim())) {
          if (uid.isEmpty) continue;
          final key = _sessionKey(uid: uid, courseId: courseId);
          final cur = out[key] ?? const _SessionCounts();
          out[key] = _SessionCounts(held: cur.held, present: cur.present + 1);
        }
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
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: const Text('Use previous payment'),
                subtitle: const Text('Pick old date/fee then set left amount'),
                onTap: () => Navigator.of(sheetCtx).pop('history'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('Skip and enter manually'),
                subtitle: const Text('Type fee, method, date, note, and left'),
                onTap: () => Navigator.of(sheetCtx).pop('manual'),
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
    if (choice == null) return;
    await _addManualPayment(learnerRow, forceManual: choice == 'manual');
  }

  Future<void> _addManualPayment(
    Map<String, dynamic> learnerRow, {
    bool forceManual = false,
  }) async {
    final uid = (learnerRow['uid'] ?? '').toString().trim();
    if (uid.isEmpty) return;
    final learnerSerial =
        (learnerRow['learner_serial'] ?? learnerRow['serial'] ?? '')
            .toString()
            .trim();
    final learnerNameNorm = _learnerNameFrom(learnerRow).trim().toLowerCase();

    final history = <Map<String, dynamic>>[];
    if (!forceManual) {
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
    }

    if (!mounted) return;

    const manualSourceId = '__manual__';
    String sourcePaymentId = forceManual
        ? manualSourceId
        : (history.isEmpty
              ? manualSourceId
              : (history.first['paymentId'] ?? '').toString());
    Map<String, dynamic>? sourcePayment = history.isEmpty
        ? null
        : history.first;

    final originalFeeCtrl = TextEditingController(
      text: sourcePayment == null
          ? ''
          : _asInt(sourcePayment['amount']).toString(),
    );
    final leftCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String method = sourcePayment == null
        ? 'cash'
        : _AdminFinanceScreenState._normalizeMethod(
            sourcePayment['financeMethod'] ?? sourcePayment['method'],
          );
    DateTime selectedDate = DateTime.now();
    if (sourcePayment != null && !forceManual) {
      final srcDate = _asInt(sourcePayment['paidAt']);
      if (srcDate > 0) {
        selectedDate = DateTime.fromMillisecondsSinceEpoch(srcDate);
      }
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
                            const DropdownMenuItem<String>(
                              value: manualSourceId,
                              child: Text('Skip history (manual entry)'),
                            ),
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
                            if (v != manualSourceId && history.isNotEmpty) {
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
                              } else {
                                originalFeeCtrl.text = '';
                                method = 'cash';
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: originalFeeCtrl,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          readOnly: sourcePayment != null,
                          decoration: InputDecoration(
                            labelText: sourcePayment != null
                                ? 'Original fee (from selected source)'
                                : 'Fee',
                            hintText: sourcePayment != null
                                ? null
                                : 'Type original fee in DA',
                            filled: sourcePayment != null,
                            fillColor: sourcePayment != null
                                ? const Color(0xFFF8EED8)
                                : null,
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

    final ref = widget.paymentsRef.push();
    await ref.set({
      'uid': uid,
      'learner_name': _learnerNameFrom(learnerRow),
      'learner_serial':
          (learnerRow['learner_serial'] ?? learnerRow['serial'] ?? '')
              .toString()
              .trim(),
      'teacherId': widget.teacherId,
      'teacherName': widget.teacherName,
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
      'oldWaitingSourcePaymentId': sourcePaymentId == manualSourceId
          ? ''
          : sourcePaymentId,
      'oldWaitingOriginalAmount': sourceAmount,
      'oldWaitingSourcePaidAt': sourcePaidAt,
      'oldWaitingSourceMethod': sourceMethod,
      'oldWaitingSourceCourseId': sourceCourseId,
      'oldWaitingSourceCourseTitle': sourceCourseTitle,
      'oldWaitingSourceCourseCode': sourceCourseCode,
      'oldWaitingSourceMode': sourcePaymentId == manualSourceId
          ? 'manual'
          : 'history',
      'oldWaitingCreatedBy': 'admin',
      'oldWaitingCreatedAt': ServerValue.timestamp,
      'createdAt': ServerValue.timestamp,
      'variantKey': 'inclass',
      'variantLabel': 'Inclass',
    });

    final newRow = <String, dynamic>{
      'paymentId': ref.key,
      'uid': uid,
      'learner_name': _learnerNameFrom(learnerRow),
      'learner_serial':
          (learnerRow['learner_serial'] ?? learnerRow['serial'] ?? '')
              .toString()
              .trim(),
      'teacherId': widget.teacherId,
      'teacherName': widget.teacherName,
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
      'oldWaitingSourcePaymentId': sourcePaymentId == manualSourceId
          ? ''
          : sourcePaymentId,
      'oldWaitingOriginalAmount': sourceAmount,
      'oldWaitingSourcePaidAt': sourcePaidAt,
      'oldWaitingSourceMethod': sourceMethod,
      'oldWaitingSourceCourseId': sourceCourseId,
      'oldWaitingSourceCourseTitle': sourceCourseTitle,
      'oldWaitingSourceCourseCode': sourceCourseCode,
      'oldWaitingSourceMode': sourcePaymentId == manualSourceId
          ? 'manual'
          : 'history',
      'oldWaitingCreatedBy': 'admin',
      'variantKey': 'inclass',
      'variantLabel': 'Inclass',
    };
    if (!mounted) return;
    setState(() {
      _rows.add(newRow);
      _rows.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));
    });
  }

  Future<void> _editOldWaitingPayment(Map<String, dynamic> row) async {
    final paymentId = (row['paymentId'] ?? '').toString().trim();
    if (paymentId.isEmpty) return;

    final amountCtrl = TextEditingController(
      text: _asInt(row['amount']).toString(),
    );
    final noteCtrl = TextEditingController(
      text: (row['notes'] ?? '').toString().trim(),
    );
    String method = _AdminFinanceScreenState._normalizeMethod(
      row['financeMethod'] ?? row['method'],
    );

    final existingPaidAt = _asInt(row['paidAt']);
    DateTime selectedDate = existingPaidAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(existingPaidAt)
        : DateTime.now();

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
              title: const Text('Edit old waiting'),
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
                        TextField(
                          controller: amountCtrl,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Remaining amount',
                            hintText: 'Type the leftover amount in DA',
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
                    final amt = int.tryParse(amountCtrl.text.trim()) ?? 0;
                    if (amt <= 0) return;
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

    final amount = int.tryParse(amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) return;
    final note = noteCtrl.text.trim();
    final paidAt = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      12,
      0,
      0,
    ).millisecondsSinceEpoch;

    await widget.paymentsRef.child(paymentId).update({
      'amount': amount,
      'method': method,
      'financeMethod': method,
      'paidAt': paidAt,
      'notes': note,
      'financePushedAt': null,
      'financePushedBy': null,
      'financePushedStatus': null,
      'financeUpdatedAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    setState(() {
      row['amount'] = amount;
      row['method'] = method;
      row['financeMethod'] = method;
      row['paidAt'] = paidAt;
      row['notes'] = note;
      row.remove('financePushedAt');
      row.remove('financePushedBy');
      row.remove('financePushedStatus');
    });
  }

  @override
  Widget build(BuildContext context) {
    var originalTotal = 0;
    var payoutTotal = 0;
    var waitingTotal = 0;
    for (final row in _rows.where((r) => !_isNoPaymentRow(r))) {
      final effective = _AdminFinanceScreenState._effectiveFinanceFromPayment(
        row,
      );
      originalTotal += effective.originalAmount;
      payoutTotal += effective.teacherNet;
      waitingTotal += effective.waitingAmount;
    }

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
          final attendanceCounts = _attendanceCountsByLearnerCourse(
            classSnap.data?.snapshot.value,
          );
          return StreamBuilder<DatabaseEvent>(
            stream: widget.financeDoneRef.child(widget.teacherScopeKey).onValue,
            builder: (context, doneSnap) {
              final manualDone = _manualDoneKeys(doneSnap.data?.snapshot.value);
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

              final noPaymentRows = <Map<String, dynamic>>[];
              if (widget.showNoPaymentRows) {
                for (final e in classRoster) {
                  final uid = (e['uid'] ?? '').toString().trim();
                  final courseId = (e['course_id'] ?? '').toString().trim();
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
                  };
                  final markKey = _doneMarkKey(row);
                  noPaymentRows.add({
                    ...row,
                    'financePayoutStatus':
                        manualDone.contains(markKey) || manualDone.contains(uid)
                        ? 'done'
                        : 'tbpaid',
                  });
                }
              }

              final rowsToShow =
                  <Map<String, dynamic>>[..._rows, ...noPaymentRows]
                    ..sort((a, b) {
                      final am = _asInt(a['paidAt']);
                      final bm = _asInt(b['paidAt']);
                      if (am != bm) return bm.compareTo(am);
                      return _learnerNameFrom(a).toLowerCase().compareTo(
                        _learnerNameFrom(b).toLowerCase(),
                      );
                    });

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
                        text: 'Original: ${widget.money(originalTotal)}',
                        strong: true,
                      ),
                      _FinancePill(
                        icon: Icons.account_balance_wallet_rounded,
                        text: 'Teacher total: ${widget.money(payoutTotal)}',
                        strong: true,
                      ),
                      _FinancePill(
                        icon: Icons.schedule_send_rounded,
                        text: 'Waiting: ${widget.money(waitingTotal)}',
                        strong: true,
                      ),
                      _FinancePill(
                        icon: Icons.groups_rounded,
                        text: 'Learners listed: ${rowsToShow.length}',
                        strong: true,
                      ),
                      FilledButton.icon(
                        onPressed: _isPushingAll ? null : _pushAllEligibleRows,
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
                        label: Text(_isPushingAll ? 'Pushing...' : 'Push all'),
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
                    ...rowsToShow.map((row) {
                      final learner = _learnerNameFrom(row);
                      final amount = _asInt(row['amount']);
                      final paidAt = _fmtDateMs(_asInt(row['paidAt']));
                      final isNoPayment = _isNoPaymentRow(row);
                      final a = _amountsFrom(row);
                      final color = _statusColor(a);
                      final method = _methodFrom(row);
                      final percent = _teacherPercentFrom(row);
                      final variant = _variantVisualFrom(row);
                      final schoolOnlyType =
                          !isNoPayment && _isSchoolOnlyTeacherLabel(row);
                      final schoolOnlyLocked =
                          schoolOnlyType && _isEffectiveSchoolOnly(row);
                      final isOldWaiting = row['oldWaiting'] == true;
                      final isLegacyManual = row['manualPayment'] == true;
                      final editableOldWaiting =
                          !isNoPayment && (isOldWaiting || isLegacyManual);
                      final methodLabel = method == 'cash'
                          ? '💵 CASH'
                          : method == 'ccp'
                          ? '🏤 CCP'
                          : '❔ UNSPECIFIED';
                      final hasPushed = _asInt(row['financePushedAt']) > 0;
                      final pushedStatus = (row['financePushedStatus'] ?? '')
                          .toString()
                          .trim()
                          .toLowerCase();
                      final uid = (row['uid'] ?? '').toString().trim();
                      final markKey = _doneMarkKey(row);
                      final manualDoneMarked =
                          manualDone.contains(markKey) ||
                          manualDone.contains(uid);
                      final courseId = _courseIdFromRow(row);
                      final courseCode = (row['course_code'] ?? '')
                          .toString()
                          .trim();
                      final courseTitle = (row['course_title'] ?? '')
                          .toString()
                          .trim();
                      final courseLabel = courseTitle.isNotEmpty
                          ? (courseCode.isNotEmpty
                                ? '$courseCode · $courseTitle'
                                : courseTitle)
                          : (courseId.isEmpty ? '' : 'Course: $courseId');
                      final sess = (uid.isEmpty || courseId.isEmpty)
                          ? const _SessionCounts()
                          : (attendanceCounts[_sessionKey(
                                  uid: uid,
                                  courseId: courseId,
                                )] ??
                                const _SessionCounts());

                      final methodMissing = !isNoPayment && !_isMethodSet(row);
                      final teacherMissing =
                          !isNoPayment && !_isTeacherPercentSet(row);
                      final statusMissing =
                          !isNoPayment &&
                          !_isStatusSet(row, isNoPayment: false);
                      final needsNoPaymentAction =
                          isNoPayment && !manualDoneMarked;
                      final missingLabels = <String>[
                        if (statusMissing) 'Status',
                        if (methodMissing) 'Method',
                        if (teacherMissing) 'Share %',
                        if (needsNoPaymentAction) 'Add old waiting or Done',
                      ];

                      final payoutBase = a.payoutAmount;
                      int teacherPart = 0;
                      int schoolPart = 0;
                      final effective =
                          _AdminFinanceScreenState._effectiveFinanceFromPayment(
                            row,
                          );
                      if (!isNoPayment && payoutBase > 0) {
                        final hasTeacherNet =
                            row.containsKey('financeTeacherNet') &&
                            row['financeTeacherNet'] != null;
                        final hasSchoolNet =
                            row.containsKey('financeSchoolNet') &&
                            row['financeSchoolNet'] != null;

                        if (hasTeacherNet && hasSchoolNet) {
                          teacherPart = _asInt(row['financeTeacherNet']);
                          schoolPart = _asInt(row['financeSchoolNet']);
                        } else if (schoolOnlyLocked) {
                          teacherPart = 0;
                          schoolPart = payoutBase;
                        } else {
                          var p = _asInt(row['financeTeacherPercent']);
                          if (p < 0) p = 0;
                          if (p > 100) p = 100;
                          teacherPart = ((payoutBase * p) / 100).round();
                          schoolPart = payoutBase - teacherPart;
                        }

                        if (teacherPart < 0) teacherPart = 0;
                        if (schoolPart < 0) schoolPart = 0;
                      }

                      if (!isNoPayment &&
                          _normalizeStatus(row['financePayoutStatus']) ==
                              'done') {
                        teacherPart = effective.teacherNet;
                        schoolPart = effective.schoolNet;
                      }

                      String statusText;
                      if (isNoPayment) {
                        statusText = manualDoneMarked
                            ? 'DONE (manual, no payment record)'
                            : 'NO PAYMENT RECORD';
                      } else if (a.status == 'split') {
                        statusText =
                            'SPLIT ${(a.splitPaidStatus ?? 'tbpaid').toUpperCase()} ${widget.money(a.payoutAmount)} · WAITING ${widget.money(a.waitingAmount)}';
                      } else {
                        statusText = a.status.toUpperCase();
                      }

                      return Card(
                        elevation: 0,
                        color: color.withValues(alpha: 0.07),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: color.withValues(alpha: 0.35),
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: isNoPayment
                              ? () => _startOldWaitingSetup(row)
                              : null,
                          onLongPress: editableOldWaiting
                              ? () => _editOldWaitingPayment(row)
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _pulseIfMissing(
                                      missing:
                                          statusMissing || needsNoPaymentAction,
                                      child: InkWell(
                                        onTap: isNoPayment
                                            ? () => _setManualDone(
                                                row,
                                                !manualDoneMarked,
                                              )
                                            : () => _editPaymentStatus(row),
                                        customBorder: const CircleBorder(),
                                        child: CircleAvatar(
                                          backgroundColor: Colors.transparent,
                                          child: Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              CircleAvatar(
                                                backgroundColor: color
                                                    .withValues(alpha: 0.15),
                                                child: Icon(
                                                  a.status == 'done'
                                                      ? Icons.verified_rounded
                                                      : a.status == 'tbpaid'
                                                      ? Icons
                                                            .pending_actions_rounded
                                                      : Icons
                                                            .call_split_rounded,
                                                  size: 18,
                                                  color: color,
                                                ),
                                              ),
                                              Positioned(
                                                right: -2,
                                                bottom: -2,
                                                child: Container(
                                                  width: 18,
                                                  height: 18,
                                                  decoration: BoxDecoration(
                                                    color: variant.color,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: Colors.white,
                                                      width: 1.5,
                                                    ),
                                                  ),
                                                  child: Icon(
                                                    variant.icon,
                                                    size: 11,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            learner,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: AdminFinanceScreen.primary,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          Text(
                                            isNoPayment
                                                ? 'No payment yet'
                                                : paidAt,
                                            style: TextStyle(
                                              color: AdminFinanceScreen.primary
                                                  .withValues(alpha: 0.72),
                                              fontWeight: FontWeight.w700,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!isNoPayment)
                                      Text(
                                        widget.money(amount),
                                        style: const TextStyle(
                                          color: AdminFinanceScreen.primary,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 13,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  isNoPayment
                                      ? 'No payment yet · Serial: ${(row['learner_serial'] ?? '').toString().trim().isEmpty ? '—' : (row['learner_serial'] ?? '').toString().trim()}'
                                      : 'Serial: ${(row['learner_serial'] ?? '').toString().trim().isEmpty ? '—' : (row['learner_serial'] ?? '').toString().trim()}',
                                  style: const TextStyle(
                                    color: AdminFinanceScreen.primary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11.5,
                                  ),
                                ),
                                if (courseLabel.isNotEmpty)
                                  Text(
                                    courseLabel,
                                    style: TextStyle(
                                      color: AdminFinanceScreen.primary
                                          .withValues(alpha: 0.78),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                if (courseId.isNotEmpty)
                                  Text(
                                    'Sessions with teacher: ${sess.held} · Present: ${sess.present}',
                                    style: TextStyle(
                                      color: AdminFinanceScreen.primary
                                          .withValues(alpha: 0.78),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (!isNoPayment)
                                      _pulseIfMissing(
                                        missing: methodMissing,
                                        child: InkWell(
                                          onTap: () => _pickMethod(row),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                0xFF1A2B48,
                                              ).withValues(alpha: 0.08),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                color: const Color(
                                                  0xFF1A2B48,
                                                ).withValues(alpha: 0.2),
                                              ),
                                            ),
                                            child: Text(
                                              'Method: $methodLabel',
                                              style: const TextStyle(
                                                color:
                                                    AdminFinanceScreen.primary,
                                                fontWeight: FontWeight.w800,
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (isOldWaiting)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFFF0A526,
                                          ).withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFFF0A526,
                                            ).withValues(alpha: 0.35),
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.history_rounded,
                                              size: 13,
                                              color: Color(0xFF8A5A00),
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              'Old waiting',
                                              style: TextStyle(
                                                color: Color(0xFF8A5A00),
                                                fontWeight: FontWeight.w800,
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (!isOldWaiting && isLegacyManual)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF178F8B,
                                          ).withValues(alpha: 0.11),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFF178F8B,
                                            ).withValues(alpha: 0.28),
                                          ),
                                        ),
                                        child: const Text(
                                          'Manual',
                                          style: TextStyle(
                                            color: Color(0xFF178F8B),
                                            fontWeight: FontWeight.w800,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                    if (schoolOnlyType)
                                      InkWell(
                                        onTap: () => _toggleSchoolOnlyLock(row),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: schoolOnlyLocked
                                                ? const Color(
                                                    0xFFF0A526,
                                                  ).withValues(alpha: 0.13)
                                                : const Color(
                                                    0xFF4B67D1,
                                                  ).withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            border: Border.all(
                                              color: schoolOnlyLocked
                                                  ? const Color(
                                                      0xFFF0A526,
                                                    ).withValues(alpha: 0.32)
                                                  : const Color(
                                                      0xFF4B67D1,
                                                    ).withValues(alpha: 0.28),
                                            ),
                                          ),
                                          child: Text(
                                            schoolOnlyLocked
                                                ? 'School-only 🔒'
                                                : 'Teacher-share 🔓',
                                            style: TextStyle(
                                              color: schoolOnlyLocked
                                                  ? const Color(0xFF8A5A00)
                                                  : const Color(0xFF4B67D1),
                                              fontWeight: FontWeight.w800,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (!isNoPayment)
                                      if (!schoolOnlyLocked)
                                        _pulseIfMissing(
                                          missing: teacherMissing,
                                          child: InkWell(
                                            onTap: () =>
                                                _setTeacherPercent(row),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 3,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(
                                                  0xFF3666D8,
                                                ).withValues(alpha: 0.1),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                border: Border.all(
                                                  color: const Color(
                                                    0xFF3666D8,
                                                  ).withValues(alpha: 0.3),
                                                ),
                                              ),
                                              child: Text(
                                                'Share: $percent%',
                                                style: const TextStyle(
                                                  color: Color(0xFF3666D8),
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ),
                                          ),
                                        )
                                      else
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              0xFF8A5A00,
                                            ).withValues(alpha: 0.09),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            border: Border.all(
                                              color: const Color(
                                                0xFF8A5A00,
                                              ).withValues(alpha: 0.26),
                                            ),
                                          ),
                                          child: const Text(
                                            'Share: N/A',
                                            style: TextStyle(
                                              color: Color(0xFF8A5A00),
                                              fontWeight: FontWeight.w800,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ),
                                    if (isNoPayment)
                                      _pulseIfMissing(
                                        missing: needsNoPaymentAction,
                                        child: InkWell(
                                          onTap: () =>
                                              _startOldWaitingSetup(row),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                0xFF3666D8,
                                              ).withValues(alpha: 0.1),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                color: const Color(
                                                  0xFF3666D8,
                                                ).withValues(alpha: 0.3),
                                              ),
                                            ),
                                            child: const Text(
                                              'Add old waiting',
                                              style: TextStyle(
                                                color: Color(0xFF3666D8),
                                                fontWeight: FontWeight.w800,
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (isNoPayment)
                                      InkWell(
                                        onTap: () => _setManualDone(
                                          row,
                                          !manualDoneMarked,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AdminFinanceScreen.done
                                                .withValues(alpha: 0.11),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            border: Border.all(
                                              color: AdminFinanceScreen.done
                                                  .withValues(alpha: 0.28),
                                            ),
                                          ),
                                          child: Text(
                                            manualDoneMarked
                                                ? 'Unmark done'
                                                : 'Mark done',
                                            style: const TextStyle(
                                              color: AdminFinanceScreen.done,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                if (!isNoPayment && payoutBase > 0)
                                  Text(
                                    'Teacher part: ${widget.money(teacherPart)} · School part: ${widget.money(schoolPart)}',
                                    style: TextStyle(
                                      color: AdminFinanceScreen.primary
                                          .withValues(alpha: 0.86),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                if (!isNoPayment && payoutBase > 0)
                                  const SizedBox(height: 4),
                                Text(
                                  '$statusText${hasPushed ? ' · SYNC ${pushedStatus.toUpperCase()}' : ''}',
                                  style: const TextStyle(
                                    color: AdminFinanceScreen.primary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11.5,
                                  ),
                                ),
                                if (missingLabels.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Missing: ${missingLabels.join(', ')}',
                                    style: TextStyle(
                                      color: const Color(0xFFD14B4B),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                                if (editableOldWaiting) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    'Long press card to edit old waiting',
                                    style: TextStyle(
                                      color: AdminFinanceScreen.primary
                                          .withValues(alpha: 0.68),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                ],
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
  });

  final _TeacherCardData data;
  final String Function(int amount) money;
  final VoidCallback onTap;

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
                TextButton.icon(
                  onPressed: onTap,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Open'),
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
          ],
        ),
      ),
    );
  }
}

class _VariantVisual {
  const _VariantVisual({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
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
