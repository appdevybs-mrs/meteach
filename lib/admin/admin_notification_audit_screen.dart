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

  Widget _statChip({
    required BuildContext context,
    required String label,
    required String shortLabel,
    required String value,
    required IconData icon,
    required Color color,
    required bool compactLabel,
  }) {
    final cs = Theme.of(context).colorScheme;
    final title = compactLabel ? shortLabel : label;
    return Container(
      constraints: const BoxConstraints(minWidth: 124),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      padding: const EdgeInsets.fromLTRB(9, 7, 10, 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 15),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
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
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Audit')),
      body: SafeArea(
        top: false,
        bottom: true,
        child: adminWebBodyFrame(
          context: context,
          maxWidth: 1320,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              children: [
                StreamBuilder<DatabaseEvent>(
                  stream: _eventsRef.onValue,
                  builder: (context, snap) {
                    final stats = _buildEventStats(snap.data?.snapshot.value);
                    final chips = <_StatChipData>[
                      _StatChipData(
                        label: 'Push Events Total',
                        shortLabel: 'Total',
                        value: '${stats.total}',
                        icon: Icons.notifications_active_rounded,
                        color: const Color(0xFF2563EB),
                      ),
                      _StatChipData(
                        label: 'Sent',
                        shortLabel: 'Sent',
                        value: '${stats.sent}',
                        icon: Icons.check_circle_rounded,
                        color: const Color(0xFF059669),
                      ),
                      _StatChipData(
                        label: 'Failed',
                        shortLabel: 'Failed',
                        value: '${stats.failed}',
                        icon: Icons.error_rounded,
                        color: const Color(0xFFDC2626),
                      ),
                      _StatChipData(
                        label: 'Pending',
                        shortLabel: 'Pending',
                        value: '${stats.pending}',
                        icon: Icons.schedule_rounded,
                        color: const Color(0xFFD97706),
                      ),
                      _StatChipData(
                        label: 'Recorded Comments',
                        shortLabel: 'Recorded',
                        value: '${stats.recordedComment}',
                        icon: Icons.video_library_rounded,
                        color: const Color(0xFF7C3AED),
                      ),
                      _StatChipData(
                        label: 'Job Applications',
                        shortLabel: 'Jobs',
                        value: '${stats.jobApplication}',
                        icon: Icons.work_history_rounded,
                        color: const Color(0xFF0E7490),
                      ),
                      _StatChipData(
                        label: 'Events (24h)',
                        shortLabel: '24h',
                        value: '${stats.last24h}',
                        icon: Icons.query_stats_rounded,
                        color: const Color(0xFF4338CA),
                      ),
                    ];
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final isPhone = constraints.maxWidth < 760;
                        final useShortLabel = constraints.maxWidth < 420;
                        if (isPhone) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: EdgeInsets.zero,
                            child: Row(
                              children: [
                                for (var i = 0; i < chips.length; i++) ...[
                                  if (i > 0) const SizedBox(width: 8),
                                  _statChip(
                                    context: context,
                                    label: chips[i].label,
                                    shortLabel: chips[i].shortLabel,
                                    value: chips[i].value,
                                    icon: chips[i].icon,
                                    color: chips[i].color,
                                    compactLabel: useShortLabel,
                                  ),
                                ],
                              ],
                            ),
                          );
                        }
                        final chipWidth = constraints.maxWidth < 1040
                            ? 170.0
                            : 182.0;
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: chips
                              .map(
                                (chip) => SizedBox(
                                  width: chipWidth,
                                  child: _statChip(
                                    context: context,
                                    label: chip.label,
                                    shortLabel: chip.shortLabel,
                                    value: chip.value,
                                    icon: chip.icon,
                                    color: chip.color,
                                    compactLabel: false,
                                  ),
                                ),
                              )
                              .toList(),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: StreamBuilder<DatabaseEvent>(
                    stream: _errorsRef.onValue,
                    builder: (context, snap) {
                      final stats = _buildErrorStats(snap.data?.snapshot.value);
                      final isCompact = MediaQuery.sizeOf(context).width < 700;
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
                              padding: EdgeInsets.fromLTRB(
                                isCompact ? 10 : 14,
                                isCompact ? 10 : 12,
                                isCompact ? 10 : 14,
                                8,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.bug_report_rounded,
                                    size: isCompact ? 18 : 22,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Push Error Logs',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w900,
                                            fontSize: isCompact ? 16 : null,
                                          ),
                                    ),
                                  ),
                                  Flexible(
                                    child: Text(
                                      'Total ${stats.total} • Last 24h ${stats.last24h}',
                                      textAlign: TextAlign.right,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: isCompact ? 12 : 13,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: stats.latest.isEmpty
                                  ? const Center(
                                      child: Text(
                                        'No push failures logged yet.',
                                      ),
                                    )
                                  : ListView.separated(
                                      padding: EdgeInsets.only(
                                        bottom: bottomInset + 12,
                                      ),
                                      itemCount: stats.latest.length > 40
                                          ? 40
                                          : stats.latest.length,
                                      separatorBuilder: (_, _) =>
                                          const Divider(height: 1),
                                      itemBuilder: (context, index) {
                                        final item = stats.latest[index];
                                        return ListTile(
                                          dense: isCompact,
                                          visualDensity: isCompact
                                              ? const VisualDensity(
                                                  horizontal: -1,
                                                  vertical: -1.3,
                                                )
                                              : VisualDensity.compact,
                                          leading: Icon(
                                            Icons.error_outline_rounded,
                                            color: const Color(0xFFDC2626),
                                            size: isCompact ? 20 : 24,
                                          ),
                                          title: Text(
                                            item.action.isEmpty
                                                ? 'push_failure'
                                                : item.action,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: isCompact ? 13 : 14,
                                            ),
                                          ),
                                          subtitle: Text(
                                            '${item.screen}\n${item.message}',
                                            maxLines: isCompact ? 2 : 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: isCompact ? 12 : 13,
                                            ),
                                          ),
                                          trailing: SizedBox(
                                            width: isCompact ? 136 : 180,
                                            child: Text(
                                              '${_fmtDateTime(item.createdAt)}\n${item.eventId}',
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: isCompact ? 11 : 12,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
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
      ),
    );
  }
}

class _StatChipData {
  const _StatChipData({
    required this.label,
    required this.shortLabel,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String shortLabel;
  final String value;
  final IconData icon;
  final Color color;
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
