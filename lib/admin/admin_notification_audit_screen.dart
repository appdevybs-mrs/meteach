import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/admin_web_layout.dart';

class AdminNotificationAuditScreen extends StatefulWidget {
  const AdminNotificationAuditScreen({super.key});

  @override
  State<AdminNotificationAuditScreen> createState() =>
      _AdminNotificationAuditScreenState();
}

class _AdminNotificationAuditScreenState
    extends State<AdminNotificationAuditScreen> {
  static final DatabaseReference _eventsRef = FirebaseDatabase.instance.ref(
    'push_events',
  );
  static final DatabaseReference _errorsRef = FirebaseDatabase.instance.ref(
    'push_client_errors',
  );

  String _query = '';

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

  _PushIncidentStats _buildIncidentStats({
    required dynamic eventRaw,
    required dynamic errorRaw,
  }) {
    final incidents = <String, _PushIncident>{};
    var backendFailures = 0;
    var clientLogs = 0;

    if (eventRaw is Map) {
      final data = Map<dynamic, dynamic>.from(eventRaw);
      for (final entry in data.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final m = value.map((k, vv) => MapEntry(k.toString(), vv));
        final status = _safe(m['status']).toLowerCase();
        if (status != 'failed') continue;

        backendFailures += 1;
        final eventId = _safe(m['eventId']);
        final key = eventId.isEmpty ? 'event:${entry.key}' : eventId;
        incidents[key] = _PushIncident(
          key: key,
          eventId: eventId,
          status: status,
          latestAt: _toInt(m['updatedAt']),
          backend: _PushBackendFailure(
            createdAt: _toInt(m['updatedAt']),
            status: status,
            type: _safe(m['type']),
            mode: _safe(m['mode']),
            target: _safe(m['target']),
            targetUid: _safe(m['targetUid']),
            topic: _safe(m['topic']),
            route: _safe(m['route']),
            actorUid: _safe(m['actorUid']),
            actorRole: _safe(m['actorRole']),
            title: _safe(m['title']),
            message: _safe(m['error']),
            failureCategory: _safe(m['failureCategory']),
            recommendedFix: _safe(m['recommendedFix']),
            errorType: _safe(m['errorType']),
            errorCode: _safe(m['errorCode']),
            responseStatus: _toInt(m['responseStatus']),
            responseSnippet: _safe(m['responseSnippet']),
          ),
          attempts: const <_PushClientAttempt>[],
        );
      }
    }

    if (errorRaw is Map) {
      final actorBuckets = Map<dynamic, dynamic>.from(errorRaw);
      for (final actorEntry in actorBuckets.entries) {
        final actorBucket = actorEntry.value;
        if (actorBucket is! Map) continue;
        final records = Map<dynamic, dynamic>.from(actorBucket);
        for (final recordEntry in records.entries) {
          final rec = recordEntry.value;
          if (rec is! Map) continue;
          clientLogs += 1;

          final m = rec.map((k, vv) => MapEntry(k.toString(), vv));
          final eventId = _safe(m['eventId']);
          final key = eventId.isEmpty
              ? 'client:${actorEntry.key}:${recordEntry.key}'
              : eventId;
          final incident =
              incidents[key] ??
              _PushIncident(
                key: key,
                eventId: eventId,
                status: 'failed',
                latestAt: 0,
                backend: null,
                attempts: const <_PushClientAttempt>[],
              );
          final attempt = _PushClientAttempt(
            createdAt: _toInt(m['createdAt']),
            screen: _safe(m['screen']),
            action: _safe(m['action']),
            attemptStage: _safe(m['attemptStage']),
            mode: _safe(m['mode']),
            target: _safe(m['target']),
            type: _safe(m['type']),
            route: _safe(m['route']),
            targetUid: _safe(m['targetUid']),
            topic: _safe(m['topic']),
            tokenSuffix: _safe(m['tokenSuffix']),
            endpoint: _safe(m['endpoint']),
            errorType: _safe(m['errorType']),
            message: _safe(m['errorMessage']),
            failureCategory: _safe(m['failureCategory']),
            recommendedFix: _safe(m['recommendedFix']),
            statusCode: _toInt(m['statusCode']),
            responseSnippet: _safe(m['responseSnippet']),
            stackTop: _safe(m['stackTop']),
          );

          incidents[key] = incident.copyWith(
            latestAt: incident.latestAt > attempt.createdAt
                ? incident.latestAt
                : attempt.createdAt,
            attempts: [...incident.attempts, attempt],
          );
        }
      }
    }

    final merged = incidents.values.map((incident) {
      final attempts = [...incident.attempts]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final latestAttempt = attempts.isEmpty ? null : attempts.last;
      final backend = incident.backend;
      final latestAt = [
        incident.latestAt,
        backend?.createdAt ?? 0,
        latestAttempt?.createdAt ?? 0,
      ].reduce((a, b) => a > b ? a : b);
      final failureCategory = backend?.failureCategory.isNotEmpty == true
          ? backend!.failureCategory
          : (latestAttempt?.failureCategory ?? '');
      final recommendedFix = backend?.recommendedFix.isNotEmpty == true
          ? backend!.recommendedFix
          : (latestAttempt?.recommendedFix ?? '');
      final primaryMessage = backend?.message.isNotEmpty == true
          ? backend!.message
          : (latestAttempt?.message ?? 'No failure message stored.');
      final type = backend?.type.isNotEmpty == true
          ? backend!.type
          : (latestAttempt?.type ?? '');
      final mode = backend?.mode.isNotEmpty == true
          ? backend!.mode
          : (latestAttempt?.mode ?? '');
      final target = backend?.target.isNotEmpty == true
          ? backend!.target
          : (latestAttempt?.target ?? '');
      final targetUid = backend?.targetUid.isNotEmpty == true
          ? backend!.targetUid
          : (latestAttempt?.targetUid ?? '');
      final route = backend?.route.isNotEmpty == true
          ? backend!.route
          : (latestAttempt?.route ?? '');
      final topic = backend?.topic.isNotEmpty == true
          ? backend!.topic
          : (latestAttempt?.topic ?? '');
      final tokenSuffix = latestAttempt?.tokenSuffix ?? '';
      final searchText = [
        incident.eventId,
        type,
        mode,
        target,
        targetUid,
        route,
        topic,
        tokenSuffix,
        failureCategory,
        primaryMessage,
        recommendedFix,
        for (final attempt in attempts) ...[
          attempt.action,
          attempt.screen,
          attempt.message,
        ],
      ].join(' ').toLowerCase();

      return incident.copyWith(
        latestAt: latestAt,
        attempts: attempts,
        summary: _PushIncidentSummary(
          type: type,
          mode: mode,
          target: target,
          targetUid: targetUid,
          route: route,
          topic: topic,
          tokenSuffix: tokenSuffix,
          failureCategory: failureCategory,
          recommendedFix: recommendedFix,
          primaryMessage: primaryMessage,
          searchText: searchText,
        ),
      );
    }).toList()..sort((a, b) => b.latestAt.compareTo(a.latestAt));

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? merged
        : merged.where((x) => x.summary.searchText.contains(q)).toList();

    return _PushIncidentStats(
      backendFailures: backendFailures,
      clientLogs: clientLogs,
      incidents: filtered,
    );
  }

  String _incidentCopyText(_PushIncident incident) {
    final b = incident.backend;
    final s = incident.summary;
    final lines = <String>[
      'eventId=${incident.eventId.isEmpty ? incident.key : incident.eventId}',
      'status=${incident.status}',
      'type=${s.type}',
      'mode=${s.mode}',
      'target=${s.target}',
      'targetUid=${s.targetUid}',
      'route=${s.route}',
      'topic=${s.topic}',
      'tokenSuffix=${s.tokenSuffix}',
      'failureCategory=${s.failureCategory}',
      'recommendedFix=${s.recommendedFix}',
      'primaryMessage=${s.primaryMessage}',
      'latestAt=${_fmtDateTime(incident.latestAt)}',
      if (b != null) 'backend.errorType=${b.errorType}',
      if (b != null) 'backend.errorCode=${b.errorCode}',
      if (b != null) 'backend.responseStatus=${b.responseStatus}',
      if (b != null) 'backend.actorUid=${b.actorUid}',
      if (b != null) 'backend.actorRole=${b.actorRole}',
      if (b != null) 'backend.title=${b.title}',
      if (b != null) 'backend.responseSnippet=${b.responseSnippet}',
    ];

    for (var i = 0; i < incident.attempts.length; i++) {
      final a = incident.attempts[i];
      lines.addAll([
        'attempt[$i].createdAt=${_fmtDateTime(a.createdAt)}',
        'attempt[$i].stage=${a.attemptStage}',
        'attempt[$i].action=${a.action}',
        'attempt[$i].screen=${a.screen}',
        'attempt[$i].statusCode=${a.statusCode}',
        'attempt[$i].endpoint=${a.endpoint}',
        'attempt[$i].errorType=${a.errorType}',
        'attempt[$i].message=${a.message}',
        'attempt[$i].responseSnippet=${a.responseSnippet}',
        'attempt[$i].stackTop=${a.stackTop}',
      ]);
    }

    return lines.join('\n');
  }

  Future<void> _copyIncident(_PushIncident incident) async {
    await Clipboard.setData(ClipboardData(text: _incidentCopyText(incident)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Copied failure details for ${incident.eventId.isEmpty ? incident.key : incident.eventId}',
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodyMedium,
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  Widget _buildIncidentTile(BuildContext context, _PushIncident incident) {
    final s = incident.summary;
    final colorScheme = Theme.of(context).colorScheme;
    final category = s.failureCategory.isEmpty
        ? 'uncategorized'
        : s.failureCategory;
    final targetLine = [
      if (s.type.isNotEmpty) s.type,
      if (s.mode.isNotEmpty) s.mode,
      if (s.targetUid.isNotEmpty) s.targetUid,
      if (s.target.isNotEmpty) s.target,
    ].join(' • ');

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        leading: Icon(
          incident.backend == null
              ? Icons.phone_android_rounded
              : Icons.cloud_off_rounded,
          color: const Color(0xFFDC2626),
        ),
        title: Text(
          category,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        subtitle: Text(
          [if (targetLine.isNotEmpty) targetLine, s.primaryMessage].join('\n'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _fmtDateTime(incident.latestAt),
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            IconButton(
              tooltip: 'Copy everything',
              onPressed: () => _copyIncident(incident),
              icon: const Icon(Icons.copy_all_rounded),
            ),
          ],
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _AuditChip(
                  label: incident.backend == null ? 'client' : 'backend',
                ),
                _AuditChip(label: 'attempts ${incident.attempts.length}'),
                if (incident.eventId.isNotEmpty)
                  _AuditChip(label: incident.eventId),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _detailRow(context, 'Recommended fix', s.recommendedFix),
          _detailRow(
            context,
            'Event ID',
            incident.eventId.isEmpty ? incident.key : incident.eventId,
          ),
          _detailRow(context, 'Type', s.type),
          _detailRow(context, 'Mode', s.mode),
          _detailRow(context, 'Target', s.target),
          _detailRow(context, 'Target UID', s.targetUid),
          _detailRow(context, 'Route', s.route),
          _detailRow(context, 'Topic', s.topic),
          _detailRow(context, 'Token suffix', s.tokenSuffix),
          if (incident.backend != null) ...[
            const Divider(height: 22),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Backend',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 8),
            _detailRow(context, 'Message', incident.backend!.message),
            _detailRow(context, 'Error type', incident.backend!.errorType),
            _detailRow(context, 'Error code', incident.backend!.errorCode),
            _detailRow(
              context,
              'Response status',
              incident.backend!.responseStatus <= 0
                  ? ''
                  : '${incident.backend!.responseStatus}',
            ),
            _detailRow(
              context,
              'Response snippet',
              incident.backend!.responseSnippet,
            ),
            _detailRow(context, 'Actor UID', incident.backend!.actorUid),
            _detailRow(context, 'Actor role', incident.backend!.actorRole),
            _detailRow(context, 'Title', incident.backend!.title),
          ],
          if (incident.attempts.isNotEmpty) ...[
            const Divider(height: 22),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Client Attempts',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < incident.attempts.length; i++)
              _AttemptCard(
                attempt: incident.attempts[i],
                fmtDateTime: _fmtDateTime,
                detailRowBuilder: (label, value) =>
                    _detailRow(context, label, value),
              ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: () => _copyIncident(incident),
              icon: const Icon(Icons.copy_all_rounded),
              label: const Text('Copy Everything'),
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
                    stream: _eventsRef.onValue,
                    builder: (context, eventSnap) {
                      final eventRaw = eventSnap.data?.snapshot.value;
                      return StreamBuilder<DatabaseEvent>(
                        stream: _errorsRef.onValue,
                        builder: (context, errorSnap) {
                          final stats = _buildIncidentStats(
                            eventRaw: eventRaw,
                            errorRaw: errorSnap.data?.snapshot.value,
                          );
                          final isCompact =
                              MediaQuery.sizeOf(context).width < 700;
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
                                    10,
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.bug_report_rounded,
                                            size: isCompact ? 18 : 22,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Push Failure Incidents',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: isCompact
                                                        ? 16
                                                        : null,
                                                  ),
                                            ),
                                          ),
                                          Flexible(
                                            child: Text(
                                              'Incidents ${stats.incidents.length} • Backend ${stats.backendFailures} • Client logs ${stats.clientLogs}',
                                              textAlign: TextAlign.right,
                                              maxLines: 2,
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
                                      const SizedBox(height: 10),
                                      TextField(
                                        onChanged: (value) =>
                                            setState(() => _query = value),
                                        decoration: const InputDecoration(
                                          prefixIcon: Icon(
                                            Icons.search_rounded,
                                          ),
                                          hintText:
                                              'Search eventId, targetUid, category, message, action',
                                          border: OutlineInputBorder(),
                                          isDense: true,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                                Expanded(
                                  child: stats.incidents.isEmpty
                                      ? const Center(
                                          child: Text(
                                            'No push failures logged yet.',
                                          ),
                                        )
                                      : ListView.builder(
                                          padding: EdgeInsets.only(
                                            top: 2,
                                            bottom: bottomInset + 12,
                                          ),
                                          itemCount: stats.incidents.length > 60
                                              ? 60
                                              : stats.incidents.length,
                                          itemBuilder: (context, index) =>
                                              _buildIncidentTile(
                                                context,
                                                stats.incidents[index],
                                              ),
                                        ),
                                ),
                              ],
                            ),
                          );
                        },
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

class _AttemptCard extends StatelessWidget {
  const _AttemptCard({
    required this.attempt,
    required this.fmtDateTime,
    required this.detailRowBuilder,
  });

  final _PushClientAttempt attempt;
  final String Function(int) fmtDateTime;
  final Widget Function(String, String) detailRowBuilder;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${fmtDateTime(attempt.createdAt)} • ${attempt.attemptStage.isEmpty ? attempt.action : attempt.attemptStage}',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          detailRowBuilder('Action', attempt.action),
          detailRowBuilder('Screen', attempt.screen),
          detailRowBuilder('Message', attempt.message),
          detailRowBuilder(
            'Status code',
            attempt.statusCode <= 0 ? '' : '${attempt.statusCode}',
          ),
          detailRowBuilder('Endpoint', attempt.endpoint),
          detailRowBuilder('Error type', attempt.errorType),
          detailRowBuilder('Response snippet', attempt.responseSnippet),
          detailRowBuilder('Stack top', attempt.stackTop),
        ],
      ),
    );
  }
}

class _AuditChip extends StatelessWidget {
  const _AuditChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Theme.of(context).colorScheme.primary,
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

class _PushIncidentStats {
  const _PushIncidentStats({
    required this.backendFailures,
    required this.clientLogs,
    required this.incidents,
  });

  final int backendFailures;
  final int clientLogs;
  final List<_PushIncident> incidents;
}

class _PushIncident {
  const _PushIncident({
    required this.key,
    required this.eventId,
    required this.status,
    required this.latestAt,
    required this.backend,
    required this.attempts,
    this.summary = const _PushIncidentSummary.empty(),
  });

  final String key;
  final String eventId;
  final String status;
  final int latestAt;
  final _PushBackendFailure? backend;
  final List<_PushClientAttempt> attempts;
  final _PushIncidentSummary summary;

  _PushIncident copyWith({
    int? latestAt,
    _PushBackendFailure? backend,
    List<_PushClientAttempt>? attempts,
    _PushIncidentSummary? summary,
  }) {
    return _PushIncident(
      key: key,
      eventId: eventId,
      status: status,
      latestAt: latestAt ?? this.latestAt,
      backend: backend ?? this.backend,
      attempts: attempts ?? this.attempts,
      summary: summary ?? this.summary,
    );
  }
}

class _PushIncidentSummary {
  const _PushIncidentSummary({
    required this.type,
    required this.mode,
    required this.target,
    required this.targetUid,
    required this.route,
    required this.topic,
    required this.tokenSuffix,
    required this.failureCategory,
    required this.recommendedFix,
    required this.primaryMessage,
    required this.searchText,
  });

  const _PushIncidentSummary.empty()
    : type = '',
      mode = '',
      target = '',
      targetUid = '',
      route = '',
      topic = '',
      tokenSuffix = '',
      failureCategory = '',
      recommendedFix = '',
      primaryMessage = '',
      searchText = '';

  final String type;
  final String mode;
  final String target;
  final String targetUid;
  final String route;
  final String topic;
  final String tokenSuffix;
  final String failureCategory;
  final String recommendedFix;
  final String primaryMessage;
  final String searchText;
}

class _PushBackendFailure {
  const _PushBackendFailure({
    required this.createdAt,
    required this.status,
    required this.type,
    required this.mode,
    required this.target,
    required this.targetUid,
    required this.topic,
    required this.route,
    required this.actorUid,
    required this.actorRole,
    required this.title,
    required this.message,
    required this.failureCategory,
    required this.recommendedFix,
    required this.errorType,
    required this.errorCode,
    required this.responseStatus,
    required this.responseSnippet,
  });

  final int createdAt;
  final String status;
  final String type;
  final String mode;
  final String target;
  final String targetUid;
  final String topic;
  final String route;
  final String actorUid;
  final String actorRole;
  final String title;
  final String message;
  final String failureCategory;
  final String recommendedFix;
  final String errorType;
  final String errorCode;
  final int responseStatus;
  final String responseSnippet;
}

class _PushClientAttempt {
  const _PushClientAttempt({
    required this.createdAt,
    required this.screen,
    required this.action,
    required this.attemptStage,
    required this.mode,
    required this.target,
    required this.type,
    required this.route,
    required this.targetUid,
    required this.topic,
    required this.tokenSuffix,
    required this.endpoint,
    required this.errorType,
    required this.message,
    required this.failureCategory,
    required this.recommendedFix,
    required this.statusCode,
    required this.responseSnippet,
    required this.stackTop,
  });

  final int createdAt;
  final String screen;
  final String action;
  final String attemptStage;
  final String mode;
  final String target;
  final String type;
  final String route;
  final String targetUid;
  final String topic;
  final String tokenSuffix;
  final String endpoint;
  final String errorType;
  final String message;
  final String failureCategory;
  final String recommendedFix;
  final int statusCode;
  final String responseSnippet;
  final String stackTop;
}
