import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/admin_web_layout.dart';

class AdminNotificationAuditScreen extends StatelessWidget {
  const AdminNotificationAuditScreen({super.key});

  static final DatabaseReference _eventsRef = FirebaseDatabase.instance.ref(
    'push_events',
  );
  static final DatabaseReference _errorsRef = FirebaseDatabase.instance.ref(
    'push_client_errors',
  );

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _safe(dynamic value) => (value ?? '').toString().trim();

  _PushEventStats _buildEventStats(dynamic raw) {
    if (raw is! Map) return const _PushEventStats.empty();

    final now = DateTime.now().millisecondsSinceEpoch;
    final dayMs = const Duration(hours: 24).inMilliseconds;
    final data = Map<dynamic, dynamic>.from(raw);

    var total = 0;
    var sent = 0;
    var failed = 0;
    var pending = 0;
    var last24h = 0;
    var recordedComment = 0;
    var jobApplication = 0;

    for (final v in data.values) {
      if (v is! Map) continue;
      total += 1;

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final status = _safe(m['status']).toLowerCase();
      final type = _safe(m['type']).toLowerCase();
      final updatedAt = _toInt(m['updatedAt']);

      if (status == 'sent') sent += 1;
      if (status == 'failed') failed += 1;
      if (status == 'pending') pending += 1;
      if (type == 'recorded_comment') recordedComment += 1;
      if (type == 'job_application') jobApplication += 1;
      if (updatedAt > 0 && now - updatedAt <= dayMs) {
        last24h += 1;
      }
    }

    return _PushEventStats(
      total: total,
      sent: sent,
      failed: failed,
      pending: pending,
      last24h: last24h,
      recordedComment: recordedComment,
      jobApplication: jobApplication,
    );
  }

  _PushErrorStats _buildErrorStats(dynamic raw) {
    if (raw is! Map) return const _PushErrorStats.empty();

    final now = DateTime.now().millisecondsSinceEpoch;
    final dayMs = const Duration(hours: 24).inMilliseconds;
    final actors = Map<dynamic, dynamic>.from(raw);

    var total = 0;
    var last24h = 0;
    final latest = <_PushErrorItem>[];

    for (final actorBucket in actors.values) {
      if (actorBucket is! Map) continue;
      final records = Map<dynamic, dynamic>.from(actorBucket);
      for (final rec in records.values) {
        if (rec is! Map) continue;
        total += 1;
        final m = rec.map((k, vv) => MapEntry(k.toString(), vv));
        final createdAt = _toInt(m['createdAt']);
        if (createdAt > 0 && now - createdAt <= dayMs) {
          last24h += 1;
        }

        latest.add(
          _PushErrorItem(
            createdAt: createdAt,
            action: _safe(m['action']),
            screen: _safe(m['screen']),
            message: _safe(m['errorMessage']),
            eventId: _safe(m['eventId']),
          ),
        );
      }
    }

    latest.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return _PushErrorStats(total: total, last24h: last24h, latest: latest);
  }

  String _fmtDateTime(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _metricCard({
    required BuildContext context,
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                    color: cs.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Audit')),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1320,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            children: [
              StreamBuilder<DatabaseEvent>(
                stream: _eventsRef.onValue,
                builder: (context, snap) {
                  final stats = _buildEventStats(snap.data?.snapshot.value);
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 260,
                        child: _metricCard(
                          context: context,
                          title: 'Push Events Total',
                          value: '${stats.total}',
                          icon: Icons.notifications_active_rounded,
                          color: const Color(0xFF2563EB),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: _metricCard(
                          context: context,
                          title: 'Sent',
                          value: '${stats.sent}',
                          icon: Icons.check_circle_rounded,
                          color: const Color(0xFF059669),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: _metricCard(
                          context: context,
                          title: 'Failed',
                          value: '${stats.failed}',
                          icon: Icons.error_rounded,
                          color: const Color(0xFFDC2626),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: _metricCard(
                          context: context,
                          title: 'Pending',
                          value: '${stats.pending}',
                          icon: Icons.schedule_rounded,
                          color: const Color(0xFFD97706),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: _metricCard(
                          context: context,
                          title: 'Recorded Comments',
                          value: '${stats.recordedComment}',
                          icon: Icons.video_library_rounded,
                          color: const Color(0xFF7C3AED),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: _metricCard(
                          context: context,
                          title: 'Job Applications',
                          value: '${stats.jobApplication}',
                          icon: Icons.work_history_rounded,
                          color: const Color(0xFF0E7490),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        child: _metricCard(
                          context: context,
                          title: 'Events (24h)',
                          value: '${stats.last24h}',
                          icon: Icons.query_stats_rounded,
                          color: const Color(0xFF4338CA),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Expanded(
                child: StreamBuilder<DatabaseEvent>(
                  stream: _errorsRef.onValue,
                  builder: (context, snap) {
                    final stats = _buildErrorStats(snap.data?.snapshot.value);
                    return Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.outline.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                            child: Row(
                              children: [
                                const Icon(Icons.bug_report_rounded),
                                const SizedBox(width: 8),
                                Text(
                                  'Push Error Logs',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w900),
                                ),
                                const Spacer(),
                                Text(
                                  'Total ${stats.total} • Last 24h ${stats.last24h}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: stats.latest.isEmpty
                                ? const Center(
                                    child: Text('No push failures logged yet.'),
                                  )
                                : ListView.separated(
                                    itemCount: stats.latest.length > 40
                                        ? 40
                                        : stats.latest.length,
                                    separatorBuilder: (_, _) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, index) {
                                      final item = stats.latest[index];
                                      return ListTile(
                                        leading: const Icon(
                                          Icons.error_outline_rounded,
                                          color: Color(0xFFDC2626),
                                        ),
                                        title: Text(
                                          item.action.isEmpty
                                              ? 'push_failure'
                                              : item.action,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        subtitle: Text(
                                          '${item.screen}\n${item.message}',
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: SizedBox(
                                          width: 180,
                                          child: Text(
                                            '${_fmtDateTime(item.createdAt)}\n${item.eventId}',
                                            textAlign: TextAlign.right,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.black54,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PushEventStats {
  const _PushEventStats({
    required this.total,
    required this.sent,
    required this.failed,
    required this.pending,
    required this.last24h,
    required this.recordedComment,
    required this.jobApplication,
  });

  const _PushEventStats.empty()
    : total = 0,
      sent = 0,
      failed = 0,
      pending = 0,
      last24h = 0,
      recordedComment = 0,
      jobApplication = 0;

  final int total;
  final int sent;
  final int failed;
  final int pending;
  final int last24h;
  final int recordedComment;
  final int jobApplication;
}

class _PushErrorStats {
  const _PushErrorStats({
    required this.total,
    required this.last24h,
    required this.latest,
  });

  const _PushErrorStats.empty()
    : total = 0,
      last24h = 0,
      latest = const <_PushErrorItem>[];

  final int total;
  final int last24h;
  final List<_PushErrorItem> latest;
}

class _PushErrorItem {
  const _PushErrorItem({
    required this.createdAt,
    required this.action,
    required this.screen,
    required this.message,
    required this.eventId,
  });

  final int createdAt;
  final String action;
  final String screen;
  final String message;
  final String eventId;
}
