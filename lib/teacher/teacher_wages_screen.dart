import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';

class TeacherWagesScreen extends StatefulWidget {
  const TeacherWagesScreen({super.key});

  static int asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static String two(int n) => n.toString().padLeft(2, '0');

  static String monthKeyFromPaidAtMs(int ms) {
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

  Future<void> _confirmPaidByTeacher({
    required BuildContext context,
    required String paymentId,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: p.cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          'Confirm this wage?',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: Text(
          'Only confirm if you really received the money from the admin.\nAfter confirming, you cannot undo it.',
          style: TextStyle(
            color: p.text.withOpacity(0.82),
            fontWeight: FontWeight.w700,
            height: 1.4,
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

    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myUid.trim().isEmpty) return;

    final ref = FirebaseDatabase.instance.ref('payments/$paymentId');

    try {
      final snap = await ref.get();
      final v = snap.value;
      if (v is! Map) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment not found.')),
        );
        return;
      }

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));

      final teacherId = (m['teacherId'] ?? '').toString().trim();
      if (teacherId != myUid) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not allowed: this is not your payment.'),
          ),
        );
        return;
      }

      final adminPaid = TeacherWagesScreen.asBool(m['teacherPaid']);
      if (!adminPaid) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Admin has not marked this as PAID yet.'),
          ),
        );
        return;
      }

      final alreadyConfirmed = TeacherWagesScreen.asBool(m['teacherConfirmed']);
      if (alreadyConfirmed) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Already confirmed ✅')),
        );
        return;
      }

      await ref.update({
        'teacherConfirmed': true,
        'teacherConfirmedAt': ServerValue.timestamp,
        'teacherConfirmedBy': myUid,
      });

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Confirmed ✅'),
          duration: Duration(milliseconds: 900),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Confirm failed: $e')),
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
              'Track paid, pending, and confirmed wages',
              style: TextStyle(
                color: p.text.withOpacity(0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: FirebaseDatabase.instance.ref('payments').onValue,
        builder: (context, snap) {
          final raw = snap.data?.snapshot.value;

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
            return Center(
              child: CircularProgressIndicator(color: p.accent),
            );
          }

          if (raw is! Map) {
            return _EmptyWagesState(palette: p, text: 'No payments found.');
          }

          final mine = <Map<String, dynamic>>[];
          raw.forEach((k, v) {
            if (k == null || v == null) return;
            if (v is! Map) return;

            final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));

            final teacherId = (m['teacherId'] ?? '').toString().trim();
            if (teacherId != myUid) return;

            mine.add({
              'paymentId': k.toString(),
              ...m,
            });
          });

          if (mine.isEmpty) {
            return _EmptyWagesState(
              palette: p,
              text: 'No payments assigned to you yet.',
            );
          }

          mine.sort(
                (a, b) => TeacherWagesScreen.asInt(b['paidAt']).compareTo(
              TeacherWagesScreen.asInt(a['paidAt']),
            ),
          );

          final Map<String, List<Map<String, dynamic>>> byMonth = {};
          for (final payment in mine) {
            final monthKey = TeacherWagesScreen.monthKeyFromPaidAtMs(
              TeacherWagesScreen.asInt(payment['paidAt']),
            );
            byMonth.putIfAbsent(monthKey, () => []);
            byMonth[monthKey]!.add(payment);
          }

          final monthKeys = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));

          int totalAll = 0;
          int paidByAdminAll = 0;
          int confirmedAll = 0;

          for (final payment in mine) {
            final amt = TeacherWagesScreen.asInt(payment['amount']);
            totalAll += amt;
            if (TeacherWagesScreen.asBool(payment['teacherPaid'])) {
              paidByAdminAll += amt;
            }
            if (TeacherWagesScreen.asBool(payment['teacherConfirmed'])) {
              confirmedAll += amt;
            }
          }

          final leftToBePaidByAdmin = totalAll - paidByAdminAll;
          final leftToBeConfirmed = paidByAdminAll - confirmedAll;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            children: [
              _WagesHeroCard(
                palette: p,
                totalAll: totalAll,
                paidByAdminAll: paidByAdminAll,
                leftToBeConfirmed: leftToBeConfirmed,
                leftToBePaidByAdmin: leftToBePaidByAdmin,
              ),
              const SizedBox(height: 14),
              ...monthKeys.map((monthKey) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _MonthSection(
                    palette: p,
                    monthKey: monthKey,
                    payments: byMonth[monthKey] ?? const [],
                    onConfirmPaid: (paymentId) => _confirmPaidByTeacher(
                      context: context,
                      paymentId: paymentId,
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

class _WagesHeroCard extends StatelessWidget {
  const _WagesHeroCard({
    required this.palette,
    required this.totalAll,
    required this.paidByAdminAll,
    required this.leftToBeConfirmed,
    required this.leftToBePaidByAdmin,
  });

  final AppPalette palette;
  final int totalAll;
  final int paidByAdminAll;
  final int leftToBeConfirmed;
  final int leftToBePaidByAdmin;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.primary,
            palette.primary.withOpacity(0.88),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withOpacity(0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Wages Overview',
            style: TextStyle(
              color: Colors.white.withOpacity(0.82),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$totalAll DA',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 26,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'All payments assigned to you',
            style: TextStyle(
              color: Colors.white.withOpacity(0.86),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _HeroMiniStat(
                  label: 'Admin Paid',
                  value: '$paidByAdminAll DA',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroMiniStat(
                  label: 'To Confirm',
                  value: '$leftToBeConfirmed DA',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _HeroMiniStat(
            label: 'Not Paid Yet',
            value: '$leftToBePaidByAdmin DA',
            fullWidth: true,
          ),
        ],
      ),
    );
  }
}

class _HeroMiniStat extends StatelessWidget {
  const _HeroMiniStat({
    required this.label,
    required this.value,
    this.fullWidth = false,
  });

  final String label;
  final String value;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: fullWidth ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
      ),
      child: Column(
        crossAxisAlignment:
        fullWidth ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.80),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );

    return child;
  }
}

class _MonthSection extends StatelessWidget {
  const _MonthSection({
    required this.palette,
    required this.monthKey,
    required this.payments,
    required this.onConfirmPaid,
  });

  final AppPalette palette;
  final String monthKey;
  final List<Map<String, dynamic>> payments;
  final Future<void> Function(String paymentId) onConfirmPaid;

  @override
  Widget build(BuildContext context) {
    final items = [...payments]
      ..sort(
            (a, b) => TeacherWagesScreen.asInt(b['paidAt']).compareTo(
          TeacherWagesScreen.asInt(a['paidAt']),
        ),
      );

    int total = 0;
    int adminPaid = 0;
    int confirmed = 0;

    for (final payment in items) {
      final amt = TeacherWagesScreen.asInt(payment['amount']);
      total += amt;
      if (TeacherWagesScreen.asBool(payment['teacherPaid'])) {
        adminPaid += amt;
      }
      if (TeacherWagesScreen.asBool(payment['teacherConfirmed'])) {
        confirmed += amt;
      }
    }

    final notPaidYet = total - adminPaid;
    final toConfirm = adminPaid - confirmed;

    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: palette.border.withOpacity(0.88)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        iconColor: palette.primary,
        collapsedIconColor: palette.primary,
        title: Text(
          TeacherWagesScreen.prettyMonthLabel(monthKey),
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: palette.primary,
            fontSize: 15,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MonthPill(
                palette: palette,
                label: 'Total',
                value: '$total DA',
              ),
              _MonthPill(
                palette: palette,
                label: 'Paid',
                value: '$adminPaid DA',
              ),
              _MonthPill(
                palette: palette,
                label: 'To Confirm',
                value: '$toConfirm DA',
              ),
              _MonthPill(
                palette: palette,
                label: 'Not Paid',
                value: '$notPaidYet DA',
              ),
            ],
          ),
        ),
        children: [
          ...items.map((payment) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TeacherPaymentRow(
                palette: palette,
                payment: payment,
                onConfirmPaid: onConfirmPaid,
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _MonthPill extends StatelessWidget {
  const _MonthPill({
    required this.palette,
    required this.label,
    required this.value,
  });

  final AppPalette palette;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.soft.withOpacity(0.8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border.withOpacity(0.75)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: palette.primary,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _TeacherPaymentRow extends StatelessWidget {
  const _TeacherPaymentRow({
    required this.palette,
    required this.payment,
    required this.onConfirmPaid,
  });

  final AppPalette palette;
  final Map<String, dynamic> payment;
  final Future<void> Function(String paymentId) onConfirmPaid;

  @override
  Widget build(BuildContext context) {
    final paymentId = (payment['paymentId'] ?? '').toString().trim();

    final learnerName = (payment['learner_name'] ?? '').toString().trim();
    final serial = (payment['learner_serial'] ?? '').toString().trim();

    final paidAt =
    TeacherWagesScreen.fmtYmdFromMs(TeacherWagesScreen.asInt(payment['paidAt']));
    final startDate = (payment['startDate'] ?? '').toString().trim();

    final amount = TeacherWagesScreen.asInt(payment['amount']);

    final adminPaid = TeacherWagesScreen.asBool(payment['teacherPaid']);
    final confirmed = TeacherWagesScreen.asBool(payment['teacherConfirmed']);

    String chipText;
    Color chipBorder;
    Color chipBg;
    bool canTap;
    IconData chipIcon;

    if (!adminPaid) {
      chipText = 'UNPAID';
      chipBorder = Colors.red;
      chipBg = Colors.red.withOpacity(0.12);
      chipIcon = Icons.cancel_rounded;
      canTap = false;
    } else if (adminPaid && !confirmed) {
      chipText = 'PAID';
      chipBorder = Colors.green;
      chipBg = Colors.green.withOpacity(0.15);
      chipIcon = Icons.payments_rounded;
      canTap = true;
    } else {
      chipText = 'CONFIRMED';
      chipBorder = Colors.green.shade800;
      chipBg = Colors.green.withOpacity(0.18);
      chipIcon = Icons.verified_rounded;
      canTap = false;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.soft.withOpacity(0.28),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border.withOpacity(0.75)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.border.withOpacity(0.8)),
            ),
            child: Icon(Icons.person_rounded, color: palette.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  learnerName.isEmpty ? '(No name)' : learnerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.text,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (serial.isNotEmpty) serial,
                    if (paidAt.isNotEmpty) 'Paid: $paidAt',
                    if (startDate.isNotEmpty) 'Start: $startDate',
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text.withOpacity(0.62),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$amount DA',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.primary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: (canTap && paymentId.isNotEmpty)
                ? () => onConfirmPaid(paymentId)
                : null,
            child: Opacity(
              opacity: canTap ? 1.0 : 0.82,
              child: Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: chipBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: chipBorder.withOpacity(0.75)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(chipIcon, size: 15, color: chipBorder),
                    const SizedBox(width: 6),
                    Text(
                      chipText,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: chipBorder,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyWagesState extends StatelessWidget {
  const _EmptyWagesState({
    required this.palette,
    required this.text,
  });

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
          border: Border.all(color: palette.border.withOpacity(0.86)),
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