import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/mail_consistency_service.dart';
import '../services/mail_thread_by_id_screen.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import 'mail_topic_thread_screen.dart';

class AdminMailInboxScreen extends StatefulWidget {
  const AdminMailInboxScreen({super.key});

  @override
  State<AdminMailInboxScreen> createState() => _AdminMailInboxScreenState();
}

class _AdminMailInboxScreenState extends State<AdminMailInboxScreen> {
  final _db = FirebaseDatabase.instance;
  final _searchC = TextEditingController();

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  DatabaseReference get _indexRef => _db.ref('mail_index/$_meUid');
  DatabaseReference get _stateRef => _db.ref('mail_state/$_meUid');

  late final Stream<DatabaseEvent> _stream;
  bool _repairInProgress = false;
  bool _didInitialRepair = false;
  _AdminMailFilter _filter = _AdminMailFilter.all;
  final Map<String, String> _peerRoleCache = <String, String>{};

  @override
  void initState() {
    super.initState();
    _stream = _indexRef.onValue.asBroadcastStream();
    _runIntegritySweepOnce();
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  void _snack(String s) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, SnackBar(content: Text(s)));
  }

  Future<void> _deleteForMe(String threadId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _stateRef.child(threadId).update({'deletedAt': now});
    await _indexRef.child(threadId).remove();
    _snack('Deleted (only for you) ✅');
  }

  Future<void> _runIntegritySweepOnce() async {
    if (_repairInProgress || _didInitialRepair) return;
    final uid = _meUid.trim();
    if (uid.isEmpty) return;

    _repairInProgress = true;
    try {
      await MailConsistencyService.runAdminInboxIntegritySweep(
        db: _db,
        adminUid: uid,
      );
    } catch (_) {
      // Keep UI responsive.
    } finally {
      _repairInProgress = false;
      _didInitialRepair = true;
    }
  }

  List<_InboxRow> _parse(dynamic data) {
    if (data is! Map) return [];
    final out = <_InboxRow>[];
    data.forEach((k, v) {
      if (k == null || v == null) return;
      if (v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      if (m['deletedAt'] != null) return;
      out.add(_InboxRow(threadId: k.toString(), item: _InboxItem.fromMap(m)));
    });

    final seen = <String>{};
    final unique = <_InboxRow>[];
    for (final row in out) {
      if (seen.contains(row.threadId)) continue;
      seen.add(row.threadId);
      unique.add(row);
    }

    unique.sort((a, b) => b.item.updatedAtMs.compareTo(a.item.updatedAtMs));
    return unique;
  }

  List<_InboxRow> _applyFilters(List<_InboxRow> rows) {
    final search = _searchC.text.trim().toLowerCase();

    return rows.where((row) {
      final r = row.item;
      final cachedRole = _peerRoleCache[r.peerUid] ?? r.peerRole;
      final role = MailConsistencyService.normalizeRole(cachedRole);
      final isUnread = r.unreadCount > 0;
      final isLearner = role == 'learner';
      final isStaff = MailConsistencyService.isStaffOrTeacherRole(role);

      final matchesFilter = switch (_filter) {
        _AdminMailFilter.all => true,
        _AdminMailFilter.learners => isLearner,
        _AdminMailFilter.staffTeachers => isStaff,
        _AdminMailFilter.unread => isUnread,
      };

      final matchesSearch = search.isEmpty
          ? true
          : r.subject.toLowerCase().contains(search) ||
                r.lastMessage.toLowerCase().contains(search) ||
                r.peerName.toLowerCase().contains(search) ||
                r.peerUid.toLowerCase().contains(search);

      return matchesFilter && matchesSearch;
    }).toList();
  }

  Future<void> _openThread(_InboxRow row) async {
    final peerUid = row.item.peerUid.trim();
    final peerName = row.item.peerName.trim().isEmpty
        ? 'User'
        : row.item.peerName;

    if (!mounted) return;
    if (peerUid.isEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              MailThreadByIdScreen(threadId: row.threadId, peerUid: ''),
        ),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: RouteSettings(name: '/mail/thread/${row.threadId}'),
        builder: (_) => MailTopicThreadScreen(
          threadId: row.threadId,
          peerUid: peerUid,
          peerName: peerName,
        ),
      ),
    );
  }

  void _resolveRoleFallback(_InboxRow row) {
    final peerUid = row.item.peerUid.trim();
    if (peerUid.isEmpty) return;
    if (_peerRoleCache.containsKey(peerUid)) return;

    final seeded = row.item.peerRole.trim();
    if (MailConsistencyService.normalizeRole(seeded) != 'unknown') {
      _peerRoleCache[peerUid] = seeded;
      return;
    }

    unawaited(() async {
      final role = await MailConsistencyService.resolveUserRole(
        _db,
        peerUid,
        seedRole: seeded,
      );
      if (!mounted) return;
      setState(() => _peerRoleCache[peerUid] = role);
      if (role != 'unknown') {
        await _db.ref('mail_index/${_meUid}/${row.threadId}').update({
          'peerRole': role,
        });
      }
    }());
  }

  Widget _filterChip(_AdminMailFilter value, String label) {
    final selected = _filter == value;
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Mail'),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Repair inbox index',
            icon: _repairInProgress
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
            onPressed: _repairInProgress
                ? null
                : () async {
                    _didInitialRepair = false;
                    await _runIntegritySweepOnce();
                    if (!mounted) return;
                    _snack('Inbox scan complete ✅');
                  },
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1400,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                controller: _searchC,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search by name, subject, preview…',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _filterChip(_AdminMailFilter.all, 'All'),
                  const SizedBox(width: 8),
                  _filterChip(_AdminMailFilter.learners, 'Learners'),
                  const SizedBox(width: 8),
                  _filterChip(_AdminMailFilter.staffTeachers, 'Staff/Teachers'),
                  const SizedBox(width: 8),
                  _filterChip(_AdminMailFilter.unread, 'Unread'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _stream,
                builder: (_, snap) {
                  if (snap.hasError) {
                    return const Center(child: Text('Failed to load inbox.'));
                  }
                  final rows = _applyFilters(_parse(snap.data?.snapshot.value));
                  if (rows.isEmpty) {
                    return const Center(child: Text('Inbox is empty.'));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final row = rows[i];
                      _resolveRoleFallback(row);
                      final item = row.item;
                      final hasUnread = item.unreadCount > 0;
                      final role = MailConsistencyService.normalizeRole(
                        _peerRoleCache[item.peerUid] ?? item.peerRole,
                      );

                      final roleLabel = switch (role) {
                        'learner' => 'Learner',
                        'teacher' => 'Teacher',
                        'staff' => 'Staff',
                        'admin' => 'Admin',
                        _ => 'Unknown',
                      };

                      return Card(
                        child: ListTile(
                          title: Text(
                            item.subject.isEmpty
                                ? '(No subject)'
                                : item.subject,
                            style: TextStyle(
                              fontWeight: hasUnread
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${item.peerName.isEmpty ? 'User' : item.peerName} • $roleLabel\n${item.lastMessage.isEmpty ? 'No messages yet' : item.lastMessage}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hasUnread)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    item.unreadCount > 99
                                        ? '99+'
                                        : '${item.unreadCount}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              PopupMenuButton<String>(
                                onSelected: (v) async {
                                  if (v == 'delete') {
                                    await _deleteForMe(row.threadId);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete (for me)'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () => _openThread(row),
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
    );
  }
}

enum _AdminMailFilter { all, learners, staffTeachers, unread }

class _InboxRow {
  _InboxRow({required this.threadId, required this.item});
  final String threadId;
  final _InboxItem item;
}

class _InboxItem {
  _InboxItem({
    required this.subject,
    required this.lastMessage,
    required this.updatedAtMs,
    required this.unreadCount,
    required this.peerUid,
    required this.peerName,
    required this.peerRole,
  });

  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final String peerUid;
  final String peerName;
  final String peerRole;

  factory _InboxItem.fromMap(Map<String, dynamic> m) {
    int toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    return _InboxItem(
      subject: (m['subject'] ?? '').toString(),
      lastMessage: (m['lastMessage'] ?? '').toString(),
      updatedAtMs: toInt(m['updatedAt']),
      unreadCount: toInt(m['unreadCount'] ?? m['unread']),
      peerUid: (m['peerUid'] ?? '').toString(),
      peerName: (m['peerName'] ?? '').toString(),
      peerRole: (m['peerRole'] ?? '').toString(),
    );
  }
}
