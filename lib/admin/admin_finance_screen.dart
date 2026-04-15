import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/admin_web_layout.dart';

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

  static String _normalizeStatus(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'done' || s == 'tbpaid' || s == 'split') return s;
    return 'tbpaid';
  }

  static String _teacherNameFrom(Map<String, dynamic> p) {
    final t1 = (p['teacherName'] ?? '').toString().trim();
    if (t1.isNotEmpty) return t1;
    final t2 = (p['teacher_name'] ?? '').toString().trim();
    if (t2.isNotEmpty) return t2;
    final t3 = (p['teacher'] ?? '').toString().trim();
    if (t3.isNotEmpty) return t3;
    return 'Unassigned';
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
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final raw = snapshot.data?.snapshot.value;
                  final all = <Map<String, dynamic>>[];
                  if (raw is Map) {
                    raw.forEach((k, v) {
                      if (v is! Map) return;
                      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
                      m['paymentId'] = k.toString();
                      all.add(m.cast<String, dynamic>());
                    });
                  }

                  final visible =
                      all.where((p) => _inRangeMs(_asInt(p['paidAt']))).toList()
                        ..sort(
                          (a, b) => _asInt(
                            b['paidAt'],
                          ).compareTo(_asInt(a['paidAt'])),
                        );

                  var originalIncome = 0;
                  var waitingTotal = 0;
                  final teacherMap = <String, List<Map<String, dynamic>>>{};

                  for (final p in visible) {
                    originalIncome += _asInt(p['amount']);
                    final teacher = _teacherNameFrom(p);
                    teacherMap
                        .putIfAbsent(teacher, () => <Map<String, dynamic>>[])
                        .add(p);
                    waitingTotal += _amountsFrom(p).waitingAmount;
                  }

                  final teacherCards = <_TeacherCardData>[];
                  for (final entry in teacherMap.entries) {
                    var original = 0;
                    var payout = 0;
                    final learners = <String>{};

                    for (final p in entry.value) {
                      original += _asInt(p['amount']);
                      payout += _amountsFrom(p).payoutAmount;
                      final uid = (p['uid'] ?? '').toString().trim();
                      final n = _learnerNameFrom(p);
                      final k = uid.isNotEmpty ? uid : n;
                      if (k.isNotEmpty) learners.add(k);
                    }

                    teacherCards.add(
                      _TeacherCardData(
                        teacherName: entry.key,
                        originalTotal: original,
                        payoutTotal: payout,
                        waitingTotal: entry.value.fold<int>(
                          0,
                          (sum, p) => sum + _amountsFrom(p).waitingAmount,
                        ),
                        learnersCount: learners.length,
                        paymentsCount: entry.value.length,
                        payments: entry.value,
                      ),
                    );
                  }

                  teacherCards.sort(
                    (a, b) => b.originalTotal.compareTo(a.originalTotal),
                  );

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
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
                        teachersCount: teacherCards.length,
                      ),
                      const SizedBox(height: 12),
                      _WaitingCard(totalWaiting: waitingTotal, money: _money),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final card in teacherCards)
                            _TeacherSquareCard(
                              data: card,
                              money: _money,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        _TeacherFinanceDetailsScreen(
                                          teacherName: card.teacherName,
                                          initialPayments: card.payments,
                                          paymentsRef: _paymentsRef,
                                          money: _money,
                                        ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _TeacherFinanceDetailsScreen extends StatefulWidget {
  const _TeacherFinanceDetailsScreen({
    required this.teacherName,
    required this.initialPayments,
    required this.paymentsRef,
    required this.money,
  });

  final String teacherName;
  final List<Map<String, dynamic>> initialPayments;
  final DatabaseReference paymentsRef;
  final String Function(int amount) money;

  @override
  State<_TeacherFinanceDetailsScreen> createState() =>
      _TeacherFinanceDetailsScreenState();
}

class _TeacherFinanceDetailsScreenState
    extends State<_TeacherFinanceDetailsScreen> {
  late List<Map<String, dynamic>> _rows;

  @override
  void initState() {
    super.initState();
    _rows = List<Map<String, dynamic>>.from(widget.initialPayments)
      ..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));
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

    final paidCtrl = TextEditingController(
      text: _asInt(row['financeSplitPaidAmount']) > 0
          ? _asInt(row['financeSplitPaidAmount']).toString()
          : amount.toString(),
    );
    final waitingCtrl = TextEditingController(
      text: _asInt(row['financeSplitWaitingAmount']) > 0
          ? _asInt(row['financeSplitWaitingAmount']).toString()
          : '0',
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
                            label: const Text('TBPAID'),
                            selected: status == 'tbpaid',
                            selectedColor: const Color(0xFFDCE8FF),
                            onSelected: (_) => setD(() => status = 'tbpaid'),
                          ),
                          ChoiceChip(
                            label: const Text('Split'),
                            selected: status == 'split',
                            selectedColor: const Color(0xFFFFEDD9),
                            onSelected: (_) => setD(() => status = 'split'),
                          ),
                        ],
                      ),
                      if (status == 'split') ...[
                        const SizedBox(height: 14),
                        DropdownButtonFormField<String>(
                          initialValue: splitPaidStatus,
                          decoration: const InputDecoration(
                            labelText: 'Paid part marked as',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'done',
                              child: Text('Done'),
                            ),
                            DropdownMenuItem(
                              value: 'tbpaid',
                              child: Text('TBPAID'),
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
                            labelText: 'Part to teacher',
                            hintText: 'Amount paid / to be paid',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: waitingCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Part to waiting',
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

  @override
  Widget build(BuildContext context) {
    var originalTotal = 0;
    var payoutTotal = 0;
    var waitingTotal = 0;
    for (final row in _rows) {
      final amount = _asInt(row['amount']);
      final a = _amountsFrom(row);
      originalTotal += amount;
      payoutTotal += a.payoutAmount;
      waitingTotal += a.waitingAmount;
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
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
                text: 'Rows: ${_rows.length}',
                strong: true,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_rows.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No learner payments for this teacher in selected range.',
                ),
              ),
            )
          else
            ..._rows.map((row) {
              final learner = _learnerNameFrom(row);
              final amount = _asInt(row['amount']);
              final paidAt = _fmtDateMs(_asInt(row['paidAt']));
              final a = _amountsFrom(row);
              final color = _statusColor(a);

              String statusText;
              if (a.status == 'split') {
                statusText =
                    'Split (${(a.splitPaidStatus ?? 'tbpaid').toUpperCase()}: ${widget.money(a.payoutAmount)} · WAITING: ${widget.money(a.waitingAmount)})';
              } else {
                statusText = a.status.toUpperCase();
              }

              return Card(
                elevation: 0,
                color: color.withValues(alpha: 0.07),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: color.withValues(alpha: 0.35)),
                ),
                child: ListTile(
                  onTap: () => _editPaymentStatus(row),
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Icon(
                      a.status == 'done'
                          ? Icons.verified_rounded
                          : a.status == 'tbpaid'
                          ? Icons.pending_actions_rounded
                          : Icons.call_split_rounded,
                      size: 18,
                      color: color,
                    ),
                  ),
                  title: Text(
                    learner,
                    style: const TextStyle(
                      color: AdminFinanceScreen.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  subtitle: Text(
                    'Amount: ${widget.money(amount)} · Date: $paidAt\n$statusText',
                    style: const TextStyle(
                      color: AdminFinanceScreen.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  isThreeLine: true,
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      a.status == 'split' ? 'SPLIT' : a.status.toUpperCase(),
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                        fontSize: 10.5,
                      ),
                    ),
                  ),
                ),
              );
            }),
        ],
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
    required this.teachersCount,
  });

  final String fromLabel;
  final String toLabel;
  final VoidCallback onPickFrom;
  final VoidCallback onPickTo;
  final VoidCallback onReset;
  final String originalIncome;
  final String waitingTotal;
  final int teachersCount;

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
            _FinancePill(
              icon: Icons.badge_rounded,
              text: 'Teachers: $teachersCount',
              strong: true,
            ),
          ],
        ),
      ),
    );
  }
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

class _TeacherCardData {
  const _TeacherCardData({
    required this.teacherName,
    required this.originalTotal,
    required this.payoutTotal,
    required this.waitingTotal,
    required this.learnersCount,
    required this.paymentsCount,
    required this.payments,
  });

  final String teacherName;
  final int originalTotal;
  final int payoutTotal;
  final int waitingTotal;
  final int learnersCount;
  final int paymentsCount;
  final List<Map<String, dynamic>> payments;
}

class _FinancePill extends StatelessWidget {
  const _FinancePill({
    required this.icon,
    required this.text,
    this.strong = false,
  });

  final IconData icon;
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AdminFinanceScreen.appBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: AdminFinanceScreen.primary.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              color: AdminFinanceScreen.primary.withValues(alpha: 0.92),
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({required this.totalWaiting, required this.money});

  final int totalWaiting;
  final String Function(int amount) money;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      height: 130,
      child: Card(
        elevation: 0,
        color: const Color(0xFFFFF6EC),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.orange.withValues(alpha: 0.22)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Waiting',
                style: TextStyle(
                  color: AdminFinanceScreen.primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                money(totalWaiting),
                style: const TextStyle(
                  color: AdminFinanceScreen.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 24,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
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
    return SizedBox(
      width: 250,
      height: 240,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Colors.black.withValues(alpha: 0.07)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.teacherName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AdminFinanceScreen.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  money(data.originalTotal),
                  style: const TextStyle(
                    color: AdminFinanceScreen.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 24,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Payout: ${money(data.payoutTotal)}',
                  style: const TextStyle(
                    color: AdminFinanceScreen.tbpaid,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'Waiting: ${money(data.waitingTotal)}',
                  style: const TextStyle(
                    color: AdminFinanceScreen.waiting,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '${data.learnersCount} learners · ${data.paymentsCount} payments',
                  style: TextStyle(
                    color: AdminFinanceScreen.primary.withValues(alpha: 0.82),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
