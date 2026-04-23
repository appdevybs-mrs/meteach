import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

class PriorityAlertGate extends StatefulWidget {
  const PriorityAlertGate({super.key, required this.child});

  final Widget child;

  @override
  State<PriorityAlertGate> createState() => _PriorityAlertGateState();
}

class _PriorityAlertGateState extends State<PriorityAlertGate> {
  final FirebaseDatabase _db = FirebaseDatabase.instance;

  StreamSubscription<DatabaseEvent>? _alertsSub;
  String _uid = '';
  dynamic _lastRaw;

  bool _dialogOpen = false;
  final Set<String> _handledIds = <String>{};

  @override
  void initState() {
    super.initState();
    _bindCurrentUser();
  }

  @override
  void dispose() {
    _alertsSub?.cancel();
    super.dispose();
  }

  void _bindCurrentUser() {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) return;

    _uid = uid;
    _alertsSub = _db.ref('flash_messages/$uid').onValue.listen((event) {
      _lastRaw = event.snapshot.value;
      _maybeShowNext();
    });
  }

  int _parseInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  String _normalizeTone(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'info') return 'info';
    if (s == 'critical') return 'critical';
    return 'warning';
  }

  _AlertToneStyle _toneStyle(String tone) {
    switch (tone) {
      case 'info':
        return const _AlertToneStyle(
          label: 'Info',
          bannerIcon: Icons.info_outline_rounded,
          headerIconColor: Color(0xFF1D4ED8),
          buttonColor: Color(0xFF1D4ED8),
          borderColor: Color(0xFF93C5FD),
          titleColor: Color(0xFF1E3A8A),
          messageBorder: Color(0xFFBFDBFE),
          surfaceGradient: [Color(0xFFEFF6FF), Color(0xFFDBEAFE)],
          headerGradient: [Color(0xFF2563EB), Color(0xFF3B82F6)],
        );
      case 'critical':
        return const _AlertToneStyle(
          label: 'Critical',
          bannerIcon: Icons.warning_amber_rounded,
          headerIconColor: Color(0xFFB91C1C),
          buttonColor: Color(0xFFB91C1C),
          borderColor: Color(0xFFFCA5A5),
          titleColor: Color(0xFF7F1D1D),
          messageBorder: Color(0xFFFECACA),
          surfaceGradient: [Color(0xFFFEF2F2), Color(0xFFFEE2E2)],
          headerGradient: [Color(0xFFB91C1C), Color(0xFFDC2626)],
        );
      default:
        return const _AlertToneStyle(
          label: 'Warning',
          bannerIcon: Icons.notification_important_rounded,
          headerIconColor: Color(0xFFD9480F),
          buttonColor: Color(0xFFD9480F),
          borderColor: Color(0xFFF59E0B),
          titleColor: Color(0xFF7C2D12),
          messageBorder: Color(0xFFFED7AA),
          surfaceGradient: [Color(0xFFFFF7ED), Color(0xFFFFEDD5)],
          headerGradient: [Color(0xFFD9480F), Color(0xFFF97316)],
        );
    }
  }

  String _fmtAlertTime(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  List<_PendingAlert> _pendingFromRaw(dynamic raw) {
    if (raw is! Map) return <_PendingAlert>[];

    final out = <_PendingAlert>[];

    raw.forEach((k, v) {
      if (k == null || v == null || v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      final id = k.toString().trim();
      if (id.isEmpty) return;

      final status = (m['status'] ?? 'new').toString().trim().toLowerCase();
      final seenAt = _parseInt(m['seenAt']);
      if (status == 'seen' || seenAt > 0) return;

      final title = (m['title'] ?? '').toString().trim();
      final message = (m['message'] ?? '').toString().trim();
      if (title.isEmpty && message.isEmpty) return;

      out.add(
        _PendingAlert(
          id: id,
          title: title.isEmpty ? 'Priority alert' : title,
          message: message,
          tone: _normalizeTone(m['tone']),
          createdAtMs: _parseInt(m['createdAt']),
        ),
      );
    });

    out.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return out;
  }

  Future<void> _acknowledge(_PendingAlert alert) async {
    if (_uid.isEmpty) return;
    final ref = _db.ref('flash_messages/$_uid/${alert.id}');

    await ref.runTransaction((cur) {
      if (cur == null || cur is! Map) return Transaction.abort();

      final map = cur.map((k, v) => MapEntry(k.toString(), v));
      final status = (map['status'] ?? '').toString().trim().toLowerCase();
      final seenAt = _parseInt(map['seenAt']);
      if (status == 'seen' || seenAt > 0) {
        return Transaction.success(cur);
      }

      map['status'] = 'seen';
      map['seenAt'] = ServerValue.timestamp;
      return Transaction.success(map);
    });
  }

  Future<void> _showAlert(_PendingAlert alert) async {
    if (!mounted) return;

    _dialogOpen = true;
    _handledIds.add(alert.id);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return PopScope(
          canPop: false,
          child: Dialog(
            elevation: 18,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 20,
            ),
            backgroundColor: Colors.transparent,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxHeight = constraints.maxHeight.isFinite
                    ? constraints.maxHeight * 0.9
                    : 560.0;
                final dialogHeight = maxHeight.clamp(320.0, 560.0);
                final createdLabel = _fmtAlertTime(alert.createdAtMs);
                final toneStyle = _toneStyle(alert.tone);

                return SizedBox(
                  width: 460,
                  height: dialogHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: toneStyle.surfaceGradient,
                      ),
                      border: Border.all(
                        color: toneStyle.borderColor,
                        width: 1.2,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 22,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          right: -24,
                          bottom: -20,
                          child: Opacity(
                            opacity: 0.08,
                            child: Image.asset(
                              'assets/images/ybs_logo.png',
                              width: 140,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  12,
                                  12,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  gradient: LinearGradient(
                                    colors: toneStyle.headerGradient,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      padding: const EdgeInsets.all(5),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.96,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Image.asset(
                                        'assets/images/ybs_logo.png',
                                        fit: BoxFit.contain,
                                        errorBuilder: (_, _, _) => Icon(
                                          Icons.school_rounded,
                                          color: toneStyle.headerIconColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'Priority Message • ${toneStyle.label}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      toneStyle.bannerIcon,
                                      color: Colors.white,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        alert.title,
                                        style: TextStyle(
                                          fontSize: 19,
                                          fontWeight: FontWeight.w900,
                                          color: toneStyle.titleColor,
                                          height: 1.2,
                                        ),
                                      ),
                                      if (createdLabel.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          createdLabel,
                                          style: TextStyle(
                                            color: Colors.black.withValues(
                                              alpha: 0.55,
                                            ),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 12),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.fromLTRB(
                                          12,
                                          12,
                                          12,
                                          12,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.92,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border: Border.all(
                                            color: toneStyle.messageBorder,
                                          ),
                                        ),
                                        child: Text(
                                          alert.message.trim().isEmpty
                                              ? 'No details.'
                                              : alert.message,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            height: 1.45,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF3F3F46),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    backgroundColor: toneStyle.buttonColor,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: () async {
                                    final navigator = Navigator.of(context);
                                    await _acknowledge(alert);
                                    if (!mounted) return;
                                    navigator.pop();
                                  },
                                  icon: const Icon(Icons.check_circle_outline),
                                  label: const Text(
                                    'OK, I Understand',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );

    _dialogOpen = false;
    _maybeShowNext();
  }

  void _maybeShowNext() {
    if (!mounted || _dialogOpen) return;

    final pending = _pendingFromRaw(_lastRaw);
    _PendingAlert? next;
    for (final alert in pending) {
      if (_handledIds.contains(alert.id)) continue;
      next = alert;
      break;
    }
    if (next == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dialogOpen) return;
      _showAlert(next!);
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class _PendingAlert {
  const _PendingAlert({
    required this.id,
    required this.title,
    required this.message,
    required this.tone,
    required this.createdAtMs,
  });

  final String id;
  final String title;
  final String message;
  final String tone;
  final int createdAtMs;
}

class _AlertToneStyle {
  const _AlertToneStyle({
    required this.label,
    required this.bannerIcon,
    required this.headerIconColor,
    required this.buttonColor,
    required this.borderColor,
    required this.titleColor,
    required this.messageBorder,
    required this.surfaceGradient,
    required this.headerGradient,
  });

  final String label;
  final IconData bannerIcon;
  final Color headerIconColor;
  final Color buttonColor;
  final Color borderColor;
  final Color titleColor;
  final Color messageBorder;
  final List<Color> surfaceGradient;
  final List<Color> headerGradient;
}
