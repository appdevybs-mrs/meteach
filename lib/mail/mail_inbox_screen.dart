import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/mail_thread_by_id_screen.dart';

class MailInboxScreen extends StatefulWidget {
  const MailInboxScreen({super.key});

  @override
  State<MailInboxScreen> createState() => _MailInboxScreenState();
}

class _MailInboxScreenState extends State<MailInboxScreen> {
  final _db = FirebaseDatabase.instance;
  String get _meUid => FirebaseAuth.instance.currentUser!.uid;

  DatabaseReference get _indexRef => _db.ref('mail_index');

  late final Stream<DatabaseEvent> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _indexRef.child(_meUid).onValue.asBroadcastStream();
  }

  List<_InboxRow> _parse(dynamic v) {
    if (v is! Map) return [];
    final out = <_InboxRow>[];
    v.forEach((k, val) {
      if (k == null || val == null) return;
      if (val is! Map) return;
      final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
      final deletedAt = m['deletedAt'];
      if (deletedAt != null) return; // hide deleted threads for this user
      out.add(_InboxRow(threadId: k.toString(), m: m));
    });

    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
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

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final r = rows[i];
              return Card(
                child: ListTile(
                  title: Text(r.subject.isEmpty ? '(No subject)' : r.subject),
                  subtitle: Text(
                    '${r.peerName} • ${r.lastMessage}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: r.unreadCount > 0
                      ? CircleAvatar(
                          radius: 12,
                          child: Text(
                            '${r.unreadCount}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        )
                      : null,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MailThreadByIdScreen(
                          threadId: r.threadId,
                          peerUid: r.peerUid,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _InboxRow {
  _InboxRow({required this.threadId, required this.m});

  final String threadId;
  final Map<String, dynamic> m;

  String get subject => (m['subject'] ?? '').toString().trim();
  String get lastMessage => (m['lastMessage'] ?? '').toString().trim();
  String get peerUid => (m['peerUid'] ?? '').toString().trim();
  String get peerName => (m['peerName'] ?? 'User').toString().trim();

  int get unreadCount {
    final v = m['unreadCount'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  int get updatedAt {
    final v = m['updatedAt'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
