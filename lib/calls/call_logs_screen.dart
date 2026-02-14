import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

class CallLogsScreen extends StatelessWidget {
  const CallLogsScreen({super.key});

  // ===== Brand-ish palette (matches your other dashboards) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _fmtDate(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year.toString();
    return '$d/$m/$y';
  }

  String _fmtDuration(int? sec) {
    if (sec == null) return '';
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _cap(String s) {
    final t = s.trim();
    if (t.isEmpty) return t;
    if (t.length == 1) return t.toUpperCase();
    return '${t[0].toUpperCase()}${t.substring(1).toLowerCase()}';
    // e.g. accepted -> Accepted
  }

  Color _statusColor(String status) {
    final s = status.trim().toLowerCase();
    if (s == 'accepted') return Colors.green;
    if (s == 'ended') return Colors.grey;
    if (s == 'ringing') return Colors.orange;
    if (s == 'missed') return Colors.red;
    return Colors.blueGrey;
  }

  IconData _directionIcon(String direction) {
    return direction.trim().toLowerCase() == 'incoming'
        ? Icons.call_received_rounded
        : Icons.call_made_rounded;
  }

  String _directionLabel(String direction) {
    return direction.trim().toLowerCase() == 'incoming' ? 'Incoming' : 'Outgoing';
  }

  Widget _chip({
    required String text,
    required Color color,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 12,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Not logged in')));
    }

    final ref = FirebaseDatabase.instance.ref('call_logs/$uid');

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        title: const Text(
          'Call Logs',
          style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: ref.onValue,
        builder: (context, snap) {
          final v = snap.data?.snapshot.value;
          if (v == null || v is! Map) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: uiBorder.withOpacity(0.75)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.history_rounded, size: 44, color: primaryBlue),
                      SizedBox(height: 12),
                      Text(
                        'No calls yet',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Your call history will appear here with status and duration.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          final items = <Map<String, dynamic>>[];
          v.forEach((key, value) {
            if (value is Map) items.add(Map<String, dynamic>.from(value));
          });

          // newest first
          items.sort((a, b) {
            final ta = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
            final tb = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
            return tb.compareTo(ta);
          });

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final it = items[i];

              final peerName = (it['peerName'] ?? 'User').toString();
              final direction = (it['direction'] ?? '').toString(); // incoming/outgoing
              final status = (it['status'] ?? '').toString();

              final createdAt = (it['createdAt'] is int) ? it['createdAt'] as int : 0;
              final durationSec =
              (it['durationSec'] is int) ? it['durationSec'] as int : null;

              final dirIcon = _directionIcon(direction);
              final dirLabel = _directionLabel(direction);
              final statusColor = _statusColor(status);

              return Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: uiBorder.withOpacity(0.8)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    )
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left: icon badge
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: primaryBlue.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: primaryBlue.withOpacity(0.12)),
                        ),
                        child: Icon(dirIcon, color: primaryBlue),
                      ),
                      const SizedBox(width: 12),

                      // Middle: name + chips
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _chip(
                                  text: dirLabel,
                                  color: actionOrange,
                                  icon: dirLabel == 'Incoming'
                                      ? Icons.call_received_rounded
                                      : Icons.call_made_rounded,
                                ),
                                _chip(
                                  text: _cap(status),
                                  color: statusColor,
                                  icon: Icons.circle_rounded,
                                ),
                                if (durationSec != null && durationSec >= 0)
                                  _chip(
                                    text: _fmtDuration(durationSec),
                                    color: Colors.indigo,
                                    icon: Icons.timer_rounded,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // Right: time + date
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (createdAt > 0)
                            Text(
                              _fmtTime(createdAt),
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: primaryBlue,
                              ),
                            ),
                          const SizedBox(height: 4),
                          if (createdAt > 0)
                            Text(
                              _fmtDate(createdAt),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Colors.grey.shade600,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
