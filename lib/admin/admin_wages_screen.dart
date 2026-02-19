import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class AdminWagesScreen extends StatelessWidget {
  const AdminWagesScreen({super.key});

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
      'December'
    ];
    final name = (m >= 1 && m <= 12) ? names[m - 1] : parts[1];
    return '$name $y';
  }

  Future<void> _togglePaid({
    required BuildContext context,
    required String paymentId,
    required bool makePaid,
  }) async {
    final db = FirebaseDatabase.instance;
    final ref = db.ref('payments/$paymentId');

    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(makePaid ? 'Mark as PAID?' : 'Mark as UNPAID?'),
        content: Text(
          makePaid
              ? 'This means you already gave the money to the teacher for this payment.'
              : 'This will mark it as not paid to the teacher yet.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: makePaid ? Colors.green : Colors.red,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(makePaid ? 'Mark PAID' : 'Mark UNPAID'),
          ),
        ],
      ),
    ) ??
        false;

    if (!ok) return;

    try {
      if (makePaid) {
        await ref.update({
          'teacherPaid': true,
          'teacherPaidAt': ServerValue.timestamp,
          'teacherPaidBy': uid,
          'updatedAt': ServerValue.timestamp,
        });
      } else {
        await ref.update({
          'teacherPaid': false,
          'teacherPaidAt': null,
          'teacherPaidBy': null,
          'updatedAt': ServerValue.timestamp,
        });
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(makePaid ? 'Marked PAID ✅' : 'Marked UNPAID ✅'),
          duration: const Duration(milliseconds: 900),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
  }

  Future<void> _adminRemoveTeacherConfirmation({
    required BuildContext context,
    required String paymentId,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove teacher confirmation?'),
        content: const Text('This will undo the teacher confirmation for this payment.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    ) ??
        false;

    if (!ok) return;

    try {
      await FirebaseDatabase.instance.ref('payments/$paymentId').update({
        'teacherConfirmed': null,
        'teacherConfirmedAt': null,
        'teacherConfirmedBy': null,
        'updatedAt': ServerValue.timestamp,
      });

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Teacher confirmation removed ✅')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final paymentsRef = FirebaseDatabase.instance.ref('payments');

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Wages',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: paymentsRef.onValue,
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

          // Flatten payments into a list with paymentId
          final payments = <Map<String, dynamic>>[];
          raw.forEach((k, v) {
            if (k == null || v == null) return;
            if (v is! Map) return;
            final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
            payments.add({
              'paymentId': k.toString(),
              ...m,
            });
          });

          // Sort newest first by paidAt
          payments.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

          // Group: month -> teacherId -> list
          final Map<String, Map<String, List<Map<String, dynamic>>>> grouped = {};

          for (final p in payments) {
            final paidAtMs = _asInt(p['paidAt']);
            final monthKey = _monthKeyFromPaidAtMs(paidAtMs);

            final teacherId = (p['teacherId'] ?? '').toString().trim();
            final teacherKey = teacherId.isEmpty ? 'UNKNOWN_TEACHER' : teacherId;

            grouped.putIfAbsent(monthKey, () => {});
            grouped[monthKey]!.putIfAbsent(teacherKey, () => []);
            grouped[monthKey]![teacherKey]!.add(p);
          }

          // Sort month keys desc
          final monthKeys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

          if (monthKeys.isEmpty) {
            return const Center(child: Text('No payments found.'));
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            itemCount: monthKeys.length,
            itemBuilder: (context, i) {
              final monthKey = monthKeys[i];
              final teacherMap = grouped[monthKey] ?? {};

              // Sort teachers by teacherName (fallback teacherId)
              final teacherKeys = teacherMap.keys.toList()
                ..sort((a, b) {
                  final aName = (teacherMap[a]!.isNotEmpty ? (teacherMap[a]!.first['teacherName'] ?? '') : '')
                      .toString();
                  final bName = (teacherMap[b]!.isNotEmpty ? (teacherMap[b]!.first['teacherName'] ?? '') : '')
                      .toString();
                  final aa = aName.trim().isEmpty ? a : aName;
                  final bb = bName.trim().isEmpty ? b : bName;
                  return aa.toLowerCase().compareTo(bb.toLowerCase());
                });

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
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
                  childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  title: Text(
                    _prettyMonthLabel(monthKey),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                      fontSize: 15,
                    ),
                  ),
                  children: [
                    for (final tKey in teacherKeys) ...[
                      _TeacherSection(
                        teacherId: tKey,
                        payments: teacherMap[tKey] ?? const [],
                        onTogglePaid: (paymentId, makePaid) => _togglePaid(
                          context: context,
                          paymentId: paymentId,
                          makePaid: makePaid,
                        ),
                        onRemoveTeacherConfirm: (paymentId) => _adminRemoveTeacherConfirmation(
                          context: context,
                          paymentId: paymentId,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _TeacherSection extends StatelessWidget {
  const _TeacherSection({
    required this.teacherId,
    required this.payments,
    required this.onTogglePaid,
    required this.onRemoveTeacherConfirm,
  });

  final String teacherId;
  final List<Map<String, dynamic>> payments;

  final Future<void> Function(String paymentId, bool makePaid) onTogglePaid;
  final Future<void> Function(String paymentId) onRemoveTeacherConfirm;

  static const primaryBlue = Color(0xFF1A2B48);
  static const uiBorder = Color(0xFFD1D9E0);

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final teacherName = (payments.isNotEmpty ? (payments.first['teacherName'] ?? '') : '').toString().trim();
    final header = teacherName.isNotEmpty ? teacherName : teacherId;

    // Sort by paidAt desc inside teacher
    final items = [...payments]..sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        title: Text(
          header,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: primaryBlue,
            fontSize: 14,
          ),
        ),
        children: [
          for (final p in items) ...[
            _PaymentRow(
              payment: p,
              onTogglePaid: onTogglePaid,
              onRemoveTeacherConfirm: onRemoveTeacherConfirm,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({
    required this.payment,
    required this.onTogglePaid,
    required this.onRemoveTeacherConfirm,
  });

  final Map<String, dynamic> payment;
  final Future<void> Function(String paymentId, bool makePaid) onTogglePaid;
  final Future<void> Function(String paymentId) onRemoveTeacherConfirm;

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

  static Widget _miniTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFD1D9E0)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }

  static Widget _chip({
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.65)),
      ),
      child: Text(
        text,
        style: TextStyle(fontWeight: FontWeight.w900, color: color, fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final paymentId = (payment['paymentId'] ?? '').toString().trim();

    final learnerName = (payment['learner_name'] ?? '').toString().trim();
    final serial = (payment['learner_serial'] ?? '').toString().trim();

    final paidAtMs = _asInt(payment['paidAt']);
    final paidDate = _fmtYmdFromMs(paidAtMs);

    final startDate = (payment['startDate'] ?? '').toString().trim();

    final sessionsPaid = _asInt(payment['sessionsPaid']);
    final left = _asInt(payment['remindBeforeSession']);
    final amount = _asInt(payment['amount']);

    // Admin paid/unpaid
    final isPaidTeacher = _asBool(payment['teacherPaid']);

    // Teacher confirmed yes/no (teacher action)
    final teacherConfirmed = _asBool(payment['teacherConfirmed']);

    final paidChipBg = isPaidTeacher ? Colors.green.withOpacity(0.15) : Colors.red.withOpacity(0.12);
    final paidChipBorder = isPaidTeacher ? Colors.green : Colors.red;
    final paidChipText = isPaidTeacher ? 'PAID' : 'UNPAID';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
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
                    if (paidDate.isNotEmpty) 'Paid: $paidDate',
                    if (startDate.isNotEmpty) 'Start: $startDate',
                  ].join(' • '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black.withOpacity(0.65),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _miniTag('Sessions: $sessionsPaid'),
                    _miniTag('Left: $left'),
                    _miniTag('Amount: $amount DA'),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _chip(
                      text: teacherConfirmed ? 'TEACHER: CONFIRMED' : 'TEACHER: NOT CONFIRMED',
                      color: teacherConfirmed ? Colors.green : Colors.red,
                    ),
                    if (teacherConfirmed && paymentId.isNotEmpty)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: const Text('Unconfirm'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: BorderSide(color: Colors.red.withOpacity(0.5)),
                        ),
                        onPressed: () => onRemoveTeacherConfirm(paymentId),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Admin toggle paid/unpaid (admin-only)
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: paymentId.isEmpty ? null : () => onTogglePaid(paymentId, !isPaidTeacher),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: paidChipBg,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: paidChipBorder.withOpacity(0.7)),
              ),
              child: Text(
                paidChipText,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: paidChipBorder,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
