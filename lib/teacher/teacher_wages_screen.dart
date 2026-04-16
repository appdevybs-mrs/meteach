import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/teacher_web_layout.dart';

class TeacherWagesScreen extends StatefulWidget {
  const TeacherWagesScreen({super.key});

  static int asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final raw = v.toString().trim();
    if (raw.isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9-]'), '');
    if (cleaned.isEmpty || cleaned == '-') return 0;
    return int.tryParse(cleaned) ?? 0;
  }

  static String two(int n) => n.toString().padLeft(2, '0');

  static String fmtYmdFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  @override
  State<TeacherWagesScreen> createState() => _TeacherWagesScreenState();
}

class _TeacherWagesScreenState extends State<TeacherWagesScreen> {
  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  String _money(int amount) => '$amount DA';

  static String _normalizeStatus(dynamic v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    if (s == 'done' || s == 'tbpaid' || s == 'split' || s == 'waiting') {
      return s;
    }
    return 'tbpaid';
  }

  static _TeacherAllocation _allocationFromPayment(
    Map<String, dynamic> payment,
  ) {
    final original = TeacherWagesScreen.asInt(payment['amount']);
    final status = _normalizeStatus(payment['financePayoutStatus']);

    if (status == 'done') {
      return _TeacherAllocation(
        original: original,
        tbpaid: 0,
        waiting: 0,
        done: original,
        paidStatusForSplit: null,
      );
    }
    if (status == 'waiting') {
      return _TeacherAllocation(
        original: original,
        tbpaid: 0,
        waiting: original,
        done: 0,
        paidStatusForSplit: null,
      );
    }
    if (status == 'tbpaid') {
      return _TeacherAllocation(
        original: original,
        tbpaid: original,
        waiting: 0,
        done: 0,
        paidStatusForSplit: null,
      );
    }

    final splitPaid = TeacherWagesScreen.asInt(
      payment['financeSplitPaidAmount'],
    );
    var splitWaiting = TeacherWagesScreen.asInt(
      payment['financeSplitWaitingAmount'],
    );
    if (splitWaiting <= 0) splitWaiting = original - splitPaid;
    final paid = splitPaid.clamp(0, original);
    final waiting = splitWaiting.clamp(0, original - paid);
    final paidStatus =
        _normalizeStatus(payment['financeSplitPaidStatus']) == 'done'
        ? 'done'
        : 'tbpaid';

    return _TeacherAllocation(
      original: original,
      tbpaid: paidStatus == 'tbpaid' ? paid : 0,
      waiting: waiting,
      done: paidStatus == 'done' ? paid : 0,
      paidStatusForSplit: paidStatus,
    );
  }

  static int _teacherPercent(dynamic v) {
    final p = TeacherWagesScreen.asInt(v);
    if (p <= 0) return 100;
    if (p > 100) return 100;
    return p;
  }

  static int _netOf(int amount, int percent) {
    if (amount <= 0) return 0;
    return ((amount * percent) / 100).round();
  }

  Future<void> _confirmReceived({
    required BuildContext context,
    required _TeacherWageRowData row,
  }) async {
    if (row.tbpaidGross <= 0) return;

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: p.cardBg,
            title: Text(
              'Confirm received?',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
            content: Text(
              'This will mark TBPAID as DONE for ${row.learnerName}.',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.82),
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: TextStyle(color: p.primary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;

    try {
      final ref = FirebaseDatabase.instance.ref('payments/${row.paymentId}');
      final snap = await ref.get();
      final v = snap.value;
      if (v is! Map) {
        if (!context.mounted) return;
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Payment not found.')),
        );
        return;
      }

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final status = _normalizeStatus(m['financePayoutStatus']);

      final updates = <String, dynamic>{
        'teacherConfirmed': true,
        'teacherConfirmedAt': ServerValue.timestamp,
        'teacherConfirmedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
      };

      if (status == 'tbpaid') {
        updates['financePayoutStatus'] = 'done';
      } else if (status == 'split') {
        updates['financeSplitPaidStatus'] = 'done';
      }

      await ref.update(updates);

      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Marked received ✅')),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not confirm this payment.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'My Wages',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Pushed from finance by admin',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1540,
        child: StreamBuilder<DatabaseEvent>(
          stream: myUid.isEmpty
              ? const Stream<DatabaseEvent>.empty()
              : FirebaseDatabase.instance
                    .ref('payments')
                    .orderByChild('teacherId')
                    .equalTo(myUid)
                    .onValue,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Text(
                  'Could not load wages.',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              );
            }

            if (!snap.hasData) {
              return Center(child: CircularProgressIndicator(color: p.accent));
            }

            final raw = snap.data?.snapshot.value;
            if (raw is! Map) {
              return _EmptyWagesState(
                palette: p,
                text: 'No pushed wage items found.',
              );
            }

            final rows = <_TeacherWageRowData>[];
            raw.forEach((k, v) {
              if (k == null || v == null || v is! Map) return;
              final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));

              final pushedAt = TeacherWagesScreen.asInt(m['financePushedAt']);
              if (pushedAt <= 0) return;

              final alloc = _allocationFromPayment(m.cast<String, dynamic>());
              final percent = _teacherPercent(m['financeTeacherPercent']);
              final learner =
                  (m['learner_name'] ?? m['learnerName'] ?? '(No name)')
                      .toString();

              final tbpaidNet = _netOf(alloc.tbpaid, percent);
              final waitingNet = _netOf(alloc.waiting, percent);
              final doneNet = _netOf(alloc.done, percent);

              rows.add(
                _TeacherWageRowData(
                  paymentId: k.toString(),
                  learnerName: learner.trim().isEmpty
                      ? '(No name)'
                      : learner.trim(),
                  learnerSerial: (m['learner_serial'] ?? '').toString().trim(),
                  paidAtMs: TeacherWagesScreen.asInt(m['paidAt']),
                  teacherPercent: percent,
                  originalGross: alloc.original,
                  tbpaidGross: alloc.tbpaid,
                  waitingGross: alloc.waiting,
                  doneGross: alloc.done,
                  tbpaidNet: tbpaidNet,
                  waitingNet: waitingNet,
                  doneNet: doneNet,
                  confirmed: (m['teacherConfirmed'] == true),
                ),
              );
            });

            if (rows.isEmpty) {
              return _EmptyWagesState(
                palette: p,
                text: 'No pushed items right now.',
              );
            }

            rows.sort((a, b) => b.paidAtMs.compareTo(a.paidAtMs));

            final learnerSet = <String>{};
            var incomeNet = 0;
            var waitingNet = 0;
            var doneNet = 0;
            for (final r in rows) {
              learnerSet.add(r.learnerName);
              incomeNet += r.tbpaidNet;
              waitingNet += r.waitingNet;
              doneNet += r.doneNet;
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [p.primary, p.primary.withValues(alpha: 0.88)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _HeroPill(
                        label: 'Learners',
                        value: '${learnerSet.length}',
                      ),
                      _HeroPill(
                        label: 'Income (TBPAID net)',
                        value: _money(incomeNet),
                      ),
                      _HeroPill(
                        label: 'Waiting (net)',
                        value: _money(waitingNet),
                      ),
                      _HeroPill(label: 'Done (net)', value: _money(doneNet)),
                      _HeroPill(label: 'Rows', value: '${rows.length}'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                ...rows.map((row) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _TeacherWageRow(
                      palette: p,
                      row: row,
                      onConfirm: row.tbpaidGross > 0
                          ? () => _confirmReceived(context: context, row: row)
                          : null,
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TeacherAllocation {
  const _TeacherAllocation({
    required this.original,
    required this.tbpaid,
    required this.waiting,
    required this.done,
    required this.paidStatusForSplit,
  });

  final int original;
  final int tbpaid;
  final int waiting;
  final int done;
  final String? paidStatusForSplit;
}

class _TeacherWageRowData {
  const _TeacherWageRowData({
    required this.paymentId,
    required this.learnerName,
    required this.learnerSerial,
    required this.paidAtMs,
    required this.teacherPercent,
    required this.originalGross,
    required this.tbpaidGross,
    required this.waitingGross,
    required this.doneGross,
    required this.tbpaidNet,
    required this.waitingNet,
    required this.doneNet,
    required this.confirmed,
  });

  final String paymentId;
  final String learnerName;
  final String learnerSerial;
  final int paidAtMs;
  final int teacherPercent;
  final int originalGross;
  final int tbpaidGross;
  final int waitingGross;
  final int doneGross;
  final int tbpaidNet;
  final int waitingNet;
  final int doneNet;
  final bool confirmed;
}

class _TeacherWageRow extends StatelessWidget {
  const _TeacherWageRow({
    required this.palette,
    required this.row,
    this.onConfirm,
  });

  final AppPalette palette;
  final _TeacherWageRowData row;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final paidAt = TeacherWagesScreen.fmtYmdFromMs(row.paidAtMs);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF3666D8).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF3666D8).withValues(alpha: 0.38),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.learnerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.text,
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                paidAt,
                style: TextStyle(
                  color: palette.text.withValues(alpha: 0.66),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            [
              if (row.learnerSerial.isNotEmpty) row.learnerSerial,
              'Payment: ${row.originalGross} DA',
              'Teacher %: ${row.teacherPercent}%',
            ].join(' • '),
            style: TextStyle(
              color: palette.text.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _WageChip(
                label: 'TBPAID',
                value: '${row.tbpaidGross} DA (net ${row.tbpaidNet})',
                color: const Color(0xFF3666D8),
              ),
              _WageChip(
                label: 'WAITING',
                value: '${row.waitingGross} DA (net ${row.waitingNet})',
                color: const Color(0xFFF0A526),
              ),
              _WageChip(
                label: 'DONE',
                value: '${row.doneGross} DA (net ${row.doneNet})',
                color: const Color(0xFF22945A),
              ),
              _WageChip(
                label: 'CONFIRM',
                value: row.confirmed ? 'RECEIVED' : 'NOT YET',
                color: row.confirmed
                    ? const Color(0xFF22945A)
                    : const Color(0xFFB84A4A),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: onConfirm,
            icon: const Icon(Icons.verified_rounded),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            label: const Text('Received (Move TBPAID to DONE)'),
          ),
        ],
      ),
    );
  }
}

class _WageChip extends StatelessWidget {
  const _WageChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _EmptyWagesState extends StatelessWidget {
  const _EmptyWagesState({required this.palette, required this.text});

  final AppPalette palette;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.86)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: palette.soft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.payments_outlined,
                color: palette.primary,
                size: 30,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
