import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'learner_mail_thread_screen.dart';

class LearnerMailScreen extends StatefulWidget {
  const LearnerMailScreen({super.key});

  @override
  State<LearnerMailScreen> createState() => _LearnerMailScreenState();
}

class _LearnerMailScreenState extends State<LearnerMailScreen> {
  final _db = FirebaseDatabase.instance;
  String get _meUid => FirebaseAuth.instance.currentUser!.uid;

  DatabaseReference get _indexRef => _db.ref('mail_index/$_meUid');
  late final Stream<DatabaseEvent> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _indexRef.orderByChild('updatedAt').onValue.asBroadcastStream();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  List<_TopicRow> _parse(dynamic v) {
    if (v is! Map) return [];
    final out = <_TopicRow>[];

    v.forEach((k, vv) {
      if (k == null || vv == null) return;
      if (vv is! Map) return;

      final m = vv.map((kk, vvv) => MapEntry(kk.toString(), vvv));
      final row = _TopicRow.fromMap(k.toString(), m);

      // hide deleted for me
      if (row.deletedAtMs != null) return;

      out.add(row);
    });

    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }

  Future<void> _deleteThreadForMe(_TopicRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete topic?'),
        content: const Text(
          'This deletes only for you.\nThe other side can still see it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
        false;

    if (!ok) return;

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _indexRef.child(row.threadId).update({'deletedAt': now});
      _snack('Deleted ✅');
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mail')),
      body: StreamBuilder<DatabaseEvent>(
        stream: _stream,
        builder: (_, snap) {
          final rows = _parse(snap.data?.snapshot.value);

          if (rows.isEmpty) {
            return const Center(child: Text('No mail yet.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final r = rows[i];

              return ListTile(
                tileColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                title: Text(
                  r.subject.isEmpty ? '(No topic)' : r.subject,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  '${r.peerName.isEmpty ? "Staff" : r.peerName} • ${r.lastMessage}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (r.unreadCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          r.unreadCount > 99 ? '99+' : '${r.unreadCount}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'delete') await _deleteThreadForMe(r);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'delete', child: Text('Delete (for me)')),
                      ],
                    ),
                  ],
                ),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      settings: RouteSettings(name: '/mail/thread/${r.threadId}'),
                      builder: (_) => LearnerMailThreadScreen(
                        threadId: r.threadId,
                        peerUid: r.peerUid,
                        peerName: r.peerName.isEmpty ? 'Staff' : r.peerName,
                        subject: r.subject,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _TopicRow {
  _TopicRow({
    required this.threadId,
    required this.peerUid,
    required this.peerName,
    required this.subject,
    required this.lastMessage,
    required this.updatedAtMs,
    required this.unreadCount,
    required this.deletedAtMs,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final int? deletedAtMs;

  factory _TopicRow.fromMap(String threadId, Map<String, dynamic> m) {
    int toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    int? toIntN(dynamic v) {
      if (v == null) return null;
      final x = toInt(v);
      return x == 0 ? null : x;
    }

    return _TopicRow(
      threadId: threadId,
      peerUid: (m['peerUid'] ?? '').toString(),
      peerName: (m['peerName'] ?? '').toString(),
      subject: (m['subject'] ?? '').toString(),
      lastMessage: (m['lastMessage'] ?? '').toString(),
      updatedAtMs: toInt(m['updatedAt']),
      unreadCount: toInt(m['unreadCount']),
      deletedAtMs: toIntN(m['deletedAt']),
    );
  }
}
