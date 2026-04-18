import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/admin_web_layout.dart';

class AdminActivityCenterScreen extends StatefulWidget {
  const AdminActivityCenterScreen({super.key});

  @override
  State<AdminActivityCenterScreen> createState() =>
      _AdminActivityCenterScreenState();
}

class _AdminActivityCenterScreenState extends State<AdminActivityCenterScreen> {
  static const int _window = 2500;

  final DatabaseReference _logsRef = FirebaseDatabase.instance.ref(
    'activity_logs',
  );
  final DatabaseReference _pushEventsRef = FirebaseDatabase.instance.ref(
    'push_events',
  );
  final DatabaseReference _pushErrorsRef = FirebaseDatabase.instance.ref(
    'push_client_errors',
  );

  String _query = '';
  String _role = 'all';
  String _domain = 'all';
  String _result = 'all';
  String _action = 'all';
  bool _failuresOnly = false;

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _safe(dynamic v) => (v ?? '').toString().trim();

  String _fmt(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  List<_ActivityItem> _parse(dynamic raw) {
    if (raw is! Map) return const <_ActivityItem>[];
    final out = <_ActivityItem>[];
    final map = Map<dynamic, dynamic>.from(raw);
    for (final entry in map.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is! Map) continue;
      final m = value.map((k, v) => MapEntry(k.toString(), v));

      final actor = (m['actor'] is Map)
          ? Map<String, dynamic>.from(m['actor'] as Map)
          : const <String, dynamic>{};
      final target = (m['target'] is Map)
          ? Map<String, dynamic>.from(m['target'] as Map)
          : const <String, dynamic>{};

      final labels = <String>[];
      final rawLabels = m['labels'];
      if (rawLabels is List) {
        for (final x in rawLabels) {
          final s = _safe(x);
          if (s.isNotEmpty) labels.add(s);
        }
      }

      final keywords = <String>[];
      final rawKeywords = m['keywords'];
      if (rawKeywords is List) {
        for (final x in rawKeywords) {
          final s = _safe(x);
          if (s.isNotEmpty) keywords.add(s);
        }
      }

      out.add(
        _ActivityItem(
          eventId: _safe(m['eventId']).isEmpty ? key : _safe(m['eventId']),
          ts: _toInt(m['ts']),
          actionKey: _safe(m['actionKey']),
          domain: _safe(m['domain']),
          result: _safe(m['result']),
          severity: _safe(m['severity']),
          summary: _safe(m['summary']),
          actorUid: _safe(actor['uid']),
          actorRole: _safe(actor['role']),
          actorName: _safe(actor['name']),
          targetType: _safe(target['type']),
          targetUid: _safe(target['uid']),
          targetId: _safe(target['id']),
          targetName: _safe(target['name']),
          labels: labels,
          keywords: keywords,
          raw: m,
        ),
      );
    }

    out.sort((a, b) => b.ts.compareTo(a.ts));
    return out;
  }

  List<_ActivityItem> _filtered(List<_ActivityItem> all) {
    final q = _query.trim().toLowerCase();
    return all.where((x) {
      if (_failuresOnly && x.result.toLowerCase() == 'success') return false;
      if (_role != 'all' && x.actorRole.toLowerCase() != _role) return false;
      if (_domain != 'all' && x.domain.toLowerCase() != _domain) return false;
      if (_result != 'all' && x.result.toLowerCase() != _result) return false;
      if (_action != 'all' && x.actionKey != _action) return false;

      if (q.isEmpty) return true;
      final hay = [
        x.summary,
        x.actionKey,
        x.actorName,
        x.actorUid,
        x.targetName,
        x.targetUid,
        x.targetId,
        ...x.labels,
        ...x.keywords,
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _resetFilters() {
    setState(() {
      _query = '';
      _role = 'all';
      _domain = 'all';
      _result = 'all';
      _action = 'all';
      _failuresOnly = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity Center')),
      body: SafeArea(
        top: false,
        child: adminWebBodyFrame(
          context: context,
          maxWidth: 1500,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              children: [
                StreamBuilder<DatabaseEvent>(
                  stream: _logsRef
                      .orderByChild('ts')
                      .limitToLast(_window)
                      .onValue,
                  builder: (context, snap) {
                    final all = _parse(snap.data?.snapshot.value);
                    final list = _filtered(all);

                    final actionSet =
                        all
                            .map((e) => e.actionKey)
                            .where((e) => e.trim().isNotEmpty)
                            .toSet()
                            .toList()
                          ..sort();
                    final domainSet =
                        all
                            .map((e) => e.domain.toLowerCase())
                            .where((e) => e.trim().isNotEmpty)
                            .toSet()
                            .toList()
                          ..sort();

                    final bottomInset = MediaQuery.of(context).padding.bottom;

                    return Expanded(
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).cardColor,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.outline.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        onChanged: (v) =>
                                            setState(() => _query = v),
                                        decoration: const InputDecoration(
                                          prefixIcon: Icon(
                                            Icons.search_rounded,
                                          ),
                                          hintText:
                                              'Search keyword, learner, teacher, action, label',
                                          border: OutlineInputBorder(),
                                          isDense: true,
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 10,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    FilterChip(
                                      visualDensity: VisualDensity.compact,
                                      selected: _failuresOnly,
                                      label: const Text('Failures only'),
                                      onSelected: (v) =>
                                          setState(() => _failuresOnly = v),
                                    ),
                                    const SizedBox(width: 6),
                                    TextButton(
                                      onPressed: _resetFilters,
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      child: const Text('Reset'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    _drop(
                                      title: 'Role',
                                      value: _role,
                                      items: const [
                                        'all',
                                        'admin',
                                        'teacher',
                                        'learner',
                                        'system',
                                      ],
                                      onChanged: (v) =>
                                          setState(() => _role = v),
                                    ),
                                    _drop(
                                      title: 'Domain',
                                      value: _domain,
                                      items: ['all', ...domainSet],
                                      onChanged: (v) =>
                                          setState(() => _domain = v),
                                    ),
                                    _drop(
                                      title: 'Result',
                                      value: _result,
                                      items: const [
                                        'all',
                                        'success',
                                        'failed',
                                        'denied',
                                      ],
                                      onChanged: (v) =>
                                          setState(() => _result = v),
                                    ),
                                    _drop(
                                      title: 'Action',
                                      value: _action,
                                      items: ['all', ...actionSet],
                                      onChanged: (v) =>
                                          setState(() => _action = v),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      'Showing ${list.length} / ${all.length}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const Spacer(),
                                    TextButton.icon(
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      icon: const Icon(
                                        Icons.notifications_active,
                                        size: 16,
                                      ),
                                      label: const Text('Back to dashboard'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: list.isEmpty
                                ? const Center(
                                    child: Text('No activity logs found.'),
                                  )
                                : ListView.separated(
                                    padding: EdgeInsets.only(
                                      bottom: bottomInset + 96,
                                    ),
                                    itemCount: list.length,
                                    separatorBuilder: (context, index) =>
                                        const SizedBox(height: 6),
                                    itemBuilder: (_, i) {
                                      final e = list[i];
                                      final isFailure =
                                          e.result.toLowerCase() != 'success';
                                      final accent = isFailure
                                          ? const Color(0xFFDC2626)
                                          : const Color(0xFF0E7490);
                                      final muted = Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.66);
                                      final actorBits = <String>[
                                        if (e.actorRole.isNotEmpty) e.actorRole,
                                        if (e.actorName.isNotEmpty) e.actorName,
                                      ];
                                      final meta = <String>[
                                        _fmt(e.ts),
                                        if (e.actionKey.isNotEmpty)
                                          'action ${e.actionKey}',
                                        if (actorBits.isNotEmpty)
                                          'actor ${actorBits.join(' / ')}',
                                        if (e.targetName.isNotEmpty)
                                          'target ${e.targetName}',
                                        e.eventId,
                                      ].join('  •  ');
                                      return Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).cardColor,
                                          borderRadius: BorderRadius.circular(
                                            9,
                                          ),
                                          border: Border.all(
                                            color: accent.withValues(
                                              alpha: 0.22,
                                            ),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    e.summary.isEmpty
                                                        ? e.actionKey
                                                        : e.summary,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      fontSize: 13,
                                                    ),
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                _chip(e.result, accent),
                                                const SizedBox(width: 4),
                                                _chip(
                                                  e.domain,
                                                  const Color(0xFF334155),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 3),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    meta,
                                                    style: TextStyle(
                                                      color: muted,
                                                      fontSize: 11,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: () => _showRaw(e),
                                                  style: TextButton.styleFrom(
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    tapTargetSize:
                                                        MaterialTapTargetSize
                                                            .shrinkWrap,
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 0,
                                                        ),
                                                  ),
                                                  child: const Text('Details'),
                                                ),
                                              ],
                                            ),
                                          ],
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
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, c) {
                    final stacked = c.maxWidth < 780;
                    if (stacked) {
                      return Column(
                        children: [
                          StreamBuilder<DatabaseEvent>(
                            stream: _pushEventsRef.onValue,
                            builder: (context, snap) {
                              int total = 0;
                              int failed = 0;
                              final raw = snap.data?.snapshot.value;
                              if (raw is Map) {
                                final m = Map<dynamic, dynamic>.from(raw);
                                total = m.length;
                                for (final v in m.values) {
                                  if (v is! Map) continue;
                                  final x = v.map(
                                    (k, vv) => MapEntry(k.toString(), vv),
                                  );
                                  if (_safe(x['status']).toLowerCase() ==
                                      'failed') {
                                    failed += 1;
                                  }
                                }
                              }
                              return _legacyTile(
                                title: 'Legacy Push Events',
                                value: '$total total • $failed failed',
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                          StreamBuilder<DatabaseEvent>(
                            stream: _pushErrorsRef.onValue,
                            builder: (context, snap) {
                              int total = 0;
                              final raw = snap.data?.snapshot.value;
                              if (raw is Map) {
                                final m = Map<dynamic, dynamic>.from(raw);
                                for (final bucket in m.values) {
                                  if (bucket is Map) {
                                    total += bucket.length;
                                  }
                                }
                              }
                              return _legacyTile(
                                title: 'Legacy Push Client Errors',
                                value: '$total records',
                              );
                            },
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(
                          child: StreamBuilder<DatabaseEvent>(
                            stream: _pushEventsRef.onValue,
                            builder: (context, snap) {
                              int total = 0;
                              int failed = 0;
                              final raw = snap.data?.snapshot.value;
                              if (raw is Map) {
                                final m = Map<dynamic, dynamic>.from(raw);
                                total = m.length;
                                for (final v in m.values) {
                                  if (v is! Map) continue;
                                  final x = v.map(
                                    (k, vv) => MapEntry(k.toString(), vv),
                                  );
                                  if (_safe(x['status']).toLowerCase() ==
                                      'failed') {
                                    failed += 1;
                                  }
                                }
                              }
                              return _legacyTile(
                                title: 'Legacy Push Events',
                                value: '$total total • $failed failed',
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: StreamBuilder<DatabaseEvent>(
                            stream: _pushErrorsRef.onValue,
                            builder: (context, snap) {
                              int total = 0;
                              final raw = snap.data?.snapshot.value;
                              if (raw is Map) {
                                final m = Map<dynamic, dynamic>.from(raw);
                                for (final bucket in m.values) {
                                  if (bucket is Map) {
                                    total += bucket.length;
                                  }
                                }
                              }
                              return _legacyTile(
                                title: 'Legacy Push Client Errors',
                                value: '$total records',
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _legacyTile({required String title, required String value}) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(value),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _drop({
    required String title,
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
  }) {
    final deduped = items.where((x) => x.trim().isNotEmpty).toSet().toList();
    if (!deduped.contains(value)) deduped.insert(0, value);
    return SizedBox(
      width: 180,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: title,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
        ),
        items: deduped
            .map((x) => DropdownMenuItem(value: x, child: Text(x)))
            .toList(),
        onChanged: (v) {
          if (v == null) return;
          onChanged(v);
        },
      ),
    );
  }

  Future<void> _showRaw(_ActivityItem item) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Event details'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: SelectableText(item.raw.toString()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _ActivityItem {
  const _ActivityItem({
    required this.eventId,
    required this.ts,
    required this.actionKey,
    required this.domain,
    required this.result,
    required this.severity,
    required this.summary,
    required this.actorUid,
    required this.actorRole,
    required this.actorName,
    required this.targetType,
    required this.targetUid,
    required this.targetId,
    required this.targetName,
    required this.labels,
    required this.keywords,
    required this.raw,
  });

  final String eventId;
  final int ts;
  final String actionKey;
  final String domain;
  final String result;
  final String severity;
  final String summary;
  final String actorUid;
  final String actorRole;
  final String actorName;
  final String targetType;
  final String targetUid;
  final String targetId;
  final String targetName;
  final List<String> labels;
  final List<String> keywords;
  final Map<String, dynamic> raw;
}
