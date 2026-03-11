import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_theme.dart';

class CallLogsScreen extends StatefulWidget {
  const CallLogsScreen({super.key});

  @override
  State<CallLogsScreen> createState() => _CallLogsScreenState();
}

class _CallLogsScreenState extends State<CallLogsScreen> {
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
    return direction.trim().toLowerCase() == 'incoming'
        ? 'Incoming'
        : 'Outgoing';
  }

  String _statusSummary(List<Map<String, dynamic>> items) {
    int accepted = 0;
    int missed = 0;
    int other = 0;

    for (final it in items) {
      final status = (it['status'] ?? '').toString().trim().toLowerCase();
      if (status == 'accepted') {
        accepted++;
      } else if (status == 'missed') {
        missed++;
      } else {
        other++;
      }
    }

    if (items.isEmpty) return 'No calls';
    return '$accepted accepted • $missed missed • $other other';
  }

  int _totalDuration(List<Map<String, dynamic>> items) {
    int total = 0;
    for (final it in items) {
      final v = it['durationSec'];
      if (v is int) total += v;
    }
    return total;
  }

  Widget _pill({
    required String text,
    required Color color,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 12,
              letterSpacing: 0.15,
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
      return Scaffold(
        backgroundColor: p.appBg,
        body: Center(
          child: Text(
            'Not logged in',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    final ref = FirebaseDatabase.instance.ref('call_logs/$uid');

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
              'Call Logs',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: p.primary,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Recent call history, status, and duration',
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
        stream: ref.onValue,
        builder: (context, snap) {
          final v = snap.data?.snapshot.value;

          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return Center(
              child: CircularProgressIndicator(color: p.accent),
            );
          }

          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: p.cardBg,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: p.border.withOpacity(0.85)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        size: 38,
                        color: Colors.red,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Could not load call logs.',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: p.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          if (v == null || v is! Map) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: p.cardBg,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: p.border.withOpacity(0.85)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: p.soft,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.history_rounded,
                          size: 34,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'No calls yet',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your call history will appear here with direction, status, and duration.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: p.text.withOpacity(0.68),
                          height: 1.35,
                        ),
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

          items.sort((a, b) {
            final ta = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
            final tb = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
            return tb.compareTo(ta);
          });

          final totalCalls = items.length;
          final totalSeconds = _totalDuration(items);
          final totalDurationText = _fmtDuration(totalSeconds);

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            children: [
              _HeroCard(
                palette: p,
                totalCalls: totalCalls,
                statusSummary: _statusSummary(items),
                totalDuration: totalDurationText.isEmpty ? '00:00' : totalDurationText,
              ),
              const SizedBox(height: 14),
              ...items.map((it) {
                final peerName = (it['peerName'] ?? 'User').toString();
                final direction = (it['direction'] ?? '').toString();
                final status = (it['status'] ?? '').toString();

                final createdAt =
                (it['createdAt'] is int) ? it['createdAt'] as int : 0;
                final durationSec =
                (it['durationSec'] is int) ? it['durationSec'] as int : null;

                final dirIcon = _directionIcon(direction);
                final dirLabel = _directionLabel(direction);
                final statusColor = _statusColor(status);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: p.cardBg,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: p.border.withOpacity(0.88)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: p.soft,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: p.border.withOpacity(0.5),
                              ),
                            ),
                            child: Icon(dirIcon, color: p.primary),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  peerName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 15,
                                    color: p.primary,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _pill(
                                      text: dirLabel,
                                      color: p.accent,
                                      icon: dirLabel == 'Incoming'
                                          ? Icons.call_received_rounded
                                          : Icons.call_made_rounded,
                                    ),
                                    _pill(
                                      text: _cap(status),
                                      color: statusColor,
                                      icon: Icons.circle_rounded,
                                    ),
                                    if (durationSec != null && durationSec >= 0)
                                      _pill(
                                        text: _fmtDuration(durationSec),
                                        color: Colors.indigo,
                                        icon: Icons.timer_rounded,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (createdAt > 0)
                                Text(
                                  _fmtTime(createdAt),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: p.primary,
                                  ),
                                ),
                              const SizedBox(height: 4),
                              if (createdAt > 0)
                                Text(
                                  _fmtDate(createdAt),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: p.text.withOpacity(0.62),
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
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

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.palette,
    required this.totalCalls,
    required this.statusSummary,
    required this.totalDuration,
  });

  final AppPalette palette;
  final int totalCalls;
  final String statusSummary;
  final String totalDuration;

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
            'Communication History',
            style: TextStyle(
              color: Colors.white.withOpacity(0.82),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$totalCalls call${totalCalls == 1 ? '' : 's'}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 24,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            statusSummary,
            style: TextStyle(
              color: Colors.white.withOpacity(0.86),
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.timer_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Total talk time: $totalDuration',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}