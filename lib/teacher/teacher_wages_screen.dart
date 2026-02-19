import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherWagesScreen extends StatelessWidget {
  const TeacherWagesScreen({super.key});

  // Same brand colors
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _monthKeyFromPaidAtMs(int ms) {
    if (ms <= 0) return 'Unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}'; // yyyy-MM
  }

  static String _prettyMonthLabel(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return monthKey;

    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final name = (m >= 1 && m <= 12) ? names[m - 1] : parts[1];
    return '$name $y';
  }

  static String _fmtYmdFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  /// Teacher can ONLY confirm if:
  /// - Admin already marked teacherPaid=true
  /// - teacherConfirmed=false
  ///
  /// Teacher cannot toggle paid/unpaid, and cannot unconfirm.
  Future<void> _confirmPaidByTeacher({
    required BuildContext context,
    required String paymentId,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirm this wage?'),
        content: const Text(
          'Only confirm if you really received the money from the admin.\n'
              'After confirming, you cannot undo it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
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

    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myUid.trim().isEmpty) return;

    final ref = FirebaseDatabase.instance.ref('payments/$paymentId');

    try {
      // ✅ Safety: re-check from server so teacher can't confirm UNPAID due to UI glitch
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

      // Must belong to this teacher
      final teacherId = (m['teacherId'] ?? '').toString().trim();
      if (teacherId != myUid) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not allowed: this is not your payment.')),
        );
        return;
      }

      // Admin must mark it paid first
      final adminPaid = _asBool(m['teacherPaid']);
      if (!adminPaid) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Admin has not marked this as PAID yet.')),
        );
        return;
      }

      // If already confirmed, do nothing
      final alreadyConfirmed = _asBool(m['teacherConfirmed']);
      if (alreadyConfirmed) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Already confirmed ✅')),
        );
        return;
      }

      // ✅ Write confirm only (teacher cannot change teacherPaid)
      await ref.update({
        'teacherConfirmed': true,
        'teacherConfirmedAt': ServerValue.timestamp,
        'teacherConfirmedBy': myUid,
      });

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Confirmed ✅'), duration: Duration(milliseconds: 900)),
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
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'My Wages',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: FirebaseDatabase.instance.ref('payments').onValue,
        builder: (context, snap) {
          final raw = snap.data?.snapshot.value;

          if (snap.hasError) {
            return const Center(child: Text('Could not load wages.'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (raw is! Map) {
            return const Center(child: Text('No payments found.'));
          }

          // Filter only payments for this teacher
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
            return const Center(child: Text('No payments assigned to you yet.'));
          }

          // Sort newest first
          mine.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

          // Group by month
          final Map<String, List<Map<String, dynamic>>> byMonth = {};
          for (final p in mine) {
            final monthKey = _monthKeyFromPaidAtMs(_asInt(p['paidAt']));
            byMonth.putIfAbsent(monthKey, () => []);
            byMonth[monthKey]!.add(p);
          }

          // Month keys desc
          final monthKeys = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));

          // TOTALS
          // totalAll = sum of ALL payments assigned
          // paidByAdminAll = sum of teacherPaid==true
          // confirmedAll = sum of teacherConfirmed==true (only possible if paid by admin)
          int totalAll = 0;
          int paidByAdminAll = 0;
          int confirmedAll = 0;

          for (final p in mine) {
            final amt = _asInt(p['amount']);
            totalAll += amt;
            if (_asBool(p['teacherPaid'])) paidByAdminAll += amt;
            if (_asBool(p['teacherConfirmed'])) confirmedAll += amt;
          }

          final leftToBePaidByAdmin = totalAll - paidByAdminAll;
          final leftToBeConfirmed = paidByAdminAll - confirmedAll;

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            children: [
              // ===== TOTAL card =====
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: uiBorder.withOpacity(0.8)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    )
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: actionOrange.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: uiBorder.withOpacity(0.8)),
                      ),
                      child: const Icon(Icons.payments_rounded, color: actionOrange),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Total',
                            style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'All payments assigned to you',
                            style: TextStyle(
                              color: Colors.black.withOpacity(0.55),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$totalAll DA',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: primaryBlue,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Admin Paid: $paidByAdminAll DA',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Colors.green,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'To confirm: $leftToBeConfirmed DA',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Colors.red,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Not paid yet: $leftToBePaidByAdmin DA',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Colors.black.withOpacity(0.55),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ===== Months =====
              for (final monthKey in monthKeys) ...[
                _MonthSection(
                  monthKey: monthKey,
                  payments: byMonth[monthKey] ?? const [],
                  onConfirmPaid: (paymentId) => _confirmPaidByTeacher(
                    context: context,
                    paymentId: paymentId,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _MonthSection extends StatelessWidget {
  const _MonthSection({
    required this.monthKey,
    required this.payments,
    required this.onConfirmPaid,
  });

  final String monthKey;
  final List<Map<String, dynamic>> payments;
  final Future<void> Function(String paymentId) onConfirmPaid;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static String _prettyMonthLabel(String key) {
    final parts = key.split('-');
    if (parts.length != 2) return key;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return key;

    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final name = (m >= 1 && m <= 12) ? names[m - 1] : parts[1];
    return '$name $y';
  }

  @override
  Widget build(BuildContext context) {
    final items = [...payments]..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

    // Month totals:
    int total = 0; // all assigned in this month
    int adminPaid = 0; // teacherPaid==true
    int confirmed = 0; // teacherConfirmed==true

    for (final p in items) {
      final amt = _asInt(p['amount']);
      total += amt;
      if (_asBool(p['teacherPaid'])) adminPaid += amt;
      if (_asBool(p['teacherConfirmed'])) confirmed += amt;
    }

    final notPaidYet = total - adminPaid;
    final toConfirm = adminPaid - confirmed;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: uiBorder.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Text(
          _prettyMonthLabel(monthKey),
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: primaryBlue,
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          'Total: $total DA • Admin Paid: $adminPaid DA • To confirm: $toConfirm DA • Not paid yet: $notPaidYet DA',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.black.withOpacity(0.6),
            fontSize: 12,
          ),
        ),
        children: [
          for (final p in items) ...[
            _TeacherPaymentRow(
              payment: p,
              onConfirmPaid: onConfirmPaid,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _TeacherPaymentRow extends StatelessWidget {
  const _TeacherPaymentRow({
    required this.payment,
    required this.onConfirmPaid,
  });

  final Map<String, dynamic> payment;
  final Future<void> Function(String paymentId) onConfirmPaid;

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtYmdFromMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final paymentId = (payment['paymentId'] ?? '').toString().trim();

    final learnerName = (payment['learner_name'] ?? '').toString().trim();
    final serial = (payment['learner_serial'] ?? '').toString().trim();

    final paidAt = _fmtYmdFromMs(_asInt(payment['paidAt']));
    final startDate = (payment['startDate'] ?? '').toString().trim();

    final amount = _asInt(payment['amount']);

    // ✅ Admin paid flag + Teacher confirmed flag
    final adminPaid = _asBool(payment['teacherPaid']);
    final confirmed = _asBool(payment['teacherConfirmed']);

    // 3-state chip:
    // - UNPAID (adminPaid=false) -> red, not clickable
    // - PAID (adminPaid=true, confirmed=false) -> green, clickable to confirm
    // - CONFIRMED (adminPaid=true, confirmed=true) -> dark green, not clickable
    String chipText;
    Color chipBorder;
    Color chipBg;
    bool canTap;

    if (!adminPaid) {
      chipText = 'UNPAID';
      chipBorder = Colors.red;
      chipBg = Colors.red.withOpacity(0.12);
      canTap = false;
    } else if (adminPaid && !confirmed) {
      chipText = 'PAID';
      chipBorder = Colors.green;
      chipBg = Colors.green.withOpacity(0.15);
      canTap = true;
    } else {
      chipText = 'CONFIRMED';
      chipBorder = Colors.green.shade800;
      chipBg = Colors.green.withOpacity(0.18);
      canTap = false;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  learnerName.isEmpty ? '(No name)' : learnerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (serial.isNotEmpty) serial,
                    if (paidAt.isNotEmpty) 'Paid: $paidAt',
                    if (startDate.isNotEmpty) 'Start: $startDate',
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black.withOpacity(0.65),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$amount DA',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A2B48),
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
              opacity: canTap ? 1.0 : 0.75,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: chipBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: chipBorder.withOpacity(0.75)),
                ),
                child: Text(
                  chipText,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: chipBorder,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
