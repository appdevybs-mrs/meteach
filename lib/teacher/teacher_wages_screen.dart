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
    return int.tryParse(v.toString().trim()) ?? 0;
  }

  static String two(int n) => n.toString().padLeft(2, '0');

  static String monthKeyFromMs(int ms) {
    if (ms <= 0) return 'Unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${two(d.month)}';
  }

  static String prettyMonthLabel(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return monthKey;

    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final name = (m >= 1 && m <= 12) ? names[m - 1] : parts[1];
    return '$name $y';
  }

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

  _Allocation _allocationFromPayment(Map<String, dynamic> payment) {
    final original = TeacherWagesScreen.asInt(payment['amount']);
    final w = TeacherWagesScreen.asInt(payment['financeWaitingAmount']);
    final t = TeacherWagesScreen.asInt(payment['financeTbpaidAmount']);
    final d = TeacherWagesScreen.asInt(payment['financeDoneAmount']);
    if (w + t + d == original && original >= 0) {
      return _Allocation(original: original, waiting: w, tbpaid: t, done: d);
    }

    final status = (payment['financePayoutStatus'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (status == 'done') {
      return _Allocation(
        original: original,
        waiting: 0,
        tbpaid: 0,
        done: original,
      );
    }
    if (status == 'tbpaid') {
      return _Allocation(
        original: original,
        waiting: 0,
        tbpaid: original,
        done: 0,
      );
    }
    if (status == 'split') {
      final splitPaid = TeacherWagesScreen.asInt(
        payment['financeSplitPaidAmount'],
      );
      var splitWaiting = TeacherWagesScreen.asInt(
        payment['financeSplitWaitingAmount'],
      );
      if (splitWaiting <= 0) splitWaiting = original - splitPaid;
      final paid = splitPaid.clamp(0, original);
      final waiting = splitWaiting.clamp(0, original - paid);
      final paidStatus = (payment['financeSplitPaidStatus'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (paidStatus == 'done') {
        return _Allocation(
          original: original,
          waiting: waiting,
          tbpaid: 0,
          done: paid,
        );
      }
      return _Allocation(
        original: original,
        waiting: waiting,
        tbpaid: paid,
        done: 0,
      );
    }

    return _Allocation(
      original: original,
      waiting: original,
      tbpaid: 0,
      done: 0,
    );
  }

  Future<void> _confirmTbpaidAsDone({
    required BuildContext context,
    required _TeacherWageItem item,
  }) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: p.cardBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              'Confirm payment received?',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
            content: Text(
              'This will move ${item.tbpaidAmount} DA from TBPAID to DONE for ${item.learnerName}.',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.82),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Confirm',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;

    try {
      final ref = FirebaseDatabase.instance.ref('payments/${item.paymentId}');
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
      final allocation = _allocationFromPayment(m.cast<String, dynamic>());
      if (allocation.tbpaid <= 0) {
        if (!context.mounted) return;
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('This item has no TBPAID amount now.')),
        );
        return;
      }

      final nextDone = allocation.done + allocation.tbpaid;
      await ref.update({
        'financeWaitingAmount': allocation.waiting,
        'financeTbpaidAmount': 0,
        'financeDoneAmount': nextDone,
        'financePayoutStatus': nextDone == allocation.original
            ? 'done'
            : 'split',
        'financeAllocationUpdatedAt': ServerValue.timestamp,
        'teacherConfirmed': true,
        'teacherConfirmedAt': ServerValue.timestamp,
        'teacherConfirmedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
      });

      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Moved to DONE ✅')),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not confirm this wage item.'),
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
              'TBPAID items waiting your confirmation',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: const [SizedBox.shrink()],
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
                text: 'No TBPAID wage items found.',
              );
            }

            final items = <_TeacherWageItem>[];
            raw.forEach((k, v) {
              if (k == null || v == null || v is! Map) return;
              final map = v.map((kk, vv) => MapEntry(kk.toString(), vv));
              final allocation = _allocationFromPayment(
                map.cast<String, dynamic>(),
              );
              if (allocation.tbpaid <= 0) return;

              items.add(
                _TeacherWageItem(
                  paymentId: k.toString(),
                  learnerName: (map['learner_name'] ?? '(No name)').toString(),
                  learnerSerial: (map['learner_serial'] ?? '').toString(),
                  paidAtMs: TeacherWagesScreen.asInt(map['paidAt']),
                  originalAmount: allocation.original,
                  tbpaidAmount: allocation.tbpaid,
                  waitingAmount: allocation.waiting,
                  doneAmount: allocation.done,
                ),
              );
            });

            if (items.isEmpty) {
              return _EmptyWagesState(
                palette: p,
                text: 'No TBPAID items right now. All clear ✅',
              );
            }

            items.sort((a, b) => b.paidAtMs.compareTo(a.paidAtMs));

            int totalTbpaid = 0;
            for (final item in items) {
              totalTbpaid += item.tbpaidAmount;
            }

            final byMonth = <String, List<_TeacherWageItem>>{};
            for (final item in items) {
              final key = TeacherWagesScreen.monthKeyFromMs(item.paidAtMs);
              byMonth.putIfAbsent(key, () => <_TeacherWageItem>[]).add(item);
            }
            final monthKeys = byMonth.keys.toList()
              ..sort((a, b) => b.compareTo(a));

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
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      _HeroPill(
                        label: 'TBPAID Total',
                        value: '$totalTbpaid DA',
                      ),
                      _HeroPill(label: 'Items', value: '${items.length}'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                ...monthKeys.map((monthKey) {
                  final monthItems =
                      byMonth[monthKey] ?? const <_TeacherWageItem>[];
                  var monthTotal = 0;
                  for (final i in monthItems) {
                    monthTotal += i.tbpaidAmount;
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: p.cardBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.88),
                        ),
                      ),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          14,
                          0,
                          14,
                          14,
                        ),
                        title: Text(
                          TeacherWagesScreen.prettyMonthLabel(monthKey),
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: p.primary,
                            fontSize: 15,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'TBPAID: $monthTotal DA',
                            style: TextStyle(
                              color: p.text.withValues(alpha: 0.74),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        children: [
                          ...monthItems.map((item) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _TeacherWageRow(
                                palette: p,
                                item: item,
                                onConfirm: () => _confirmTbpaidAsDone(
                                  context: context,
                                  item: item,
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
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

class _Allocation {
  const _Allocation({
    required this.original,
    required this.waiting,
    required this.tbpaid,
    required this.done,
  });

  final int original;
  final int waiting;
  final int tbpaid;
  final int done;
}

class _TeacherWageItem {
  const _TeacherWageItem({
    required this.paymentId,
    required this.learnerName,
    required this.learnerSerial,
    required this.paidAtMs,
    required this.originalAmount,
    required this.tbpaidAmount,
    required this.waitingAmount,
    required this.doneAmount,
  });

  final String paymentId;
  final String learnerName;
  final String learnerSerial;
  final int paidAtMs;
  final int originalAmount;
  final int tbpaidAmount;
  final int waitingAmount;
  final int doneAmount;
}

class _TeacherWageRow extends StatelessWidget {
  const _TeacherWageRow({
    required this.palette,
    required this.item,
    required this.onConfirm,
  });

  final AppPalette palette;
  final _TeacherWageItem item;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final paidAt = TeacherWagesScreen.fmtYmdFromMs(item.paidAtMs);

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
                  item.learnerName,
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
          const SizedBox(height: 6),
          Text(
            [
              if (item.learnerSerial.trim().isNotEmpty) item.learnerSerial,
              'Original: ${item.originalAmount} DA',
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
                value: '${item.tbpaidAmount} DA',
                color: const Color(0xFF3666D8),
              ),
              _WageChip(
                label: 'WAITING',
                value: '${item.waitingAmount} DA',
                color: const Color(0xFFF0A526),
              ),
              _WageChip(
                label: 'DONE',
                value: '${item.doneAmount} DA',
                color: const Color(0xFF22945A),
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
            label: const Text('Confirm Received (Move to DONE)'),
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
