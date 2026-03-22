import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'admin_teacher_mail_thread_screen.dart'; // reuse your existing thread screen

class AdminMailInboxScreen extends StatefulWidget {
  const AdminMailInboxScreen({super.key});

  @override
  State<AdminMailInboxScreen> createState() => _AdminMailInboxScreenState();
}

class _AdminMailInboxScreenState extends State<AdminMailInboxScreen> {
  final _db = FirebaseDatabase.instance;
  String get _meUid => FirebaseAuth.instance.currentUser!.uid;

  DatabaseReference get _indexRef => _db.ref('mail_index/$_meUid');
  DatabaseReference get _stateRef => _db.ref('mail_state/$_meUid');

  late final Stream<DatabaseEvent> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _indexRef.onValue.asBroadcastStream();
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _deleteForMe(String threadId) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1) mark deleted in state
    await _stateRef.child(threadId).update({'deletedAt': now});

    // 2) remove from inbox index (so it disappears immediately)
    await _indexRef.child(threadId).remove();

    _snack('Deleted (only for you) ✅');
  }

  List<_InboxRow> _parse(dynamic data) {
    if (data is! Map) return [];
    final out = <_InboxRow>[];
    data.forEach((k, v) {
      if (k == null || v == null) return;
      if (v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      out.add(_InboxRow(threadId: k.toString(), item: _InboxItem.fromMap(m)));
    });
    out.sort((a, b) => b.item.updatedAtMs.compareTo(a.item.updatedAtMs));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mail'),
        actions: [
          IconButton(
            tooltip: 'New mail',
            icon: const Icon(Icons.edit),
            onPressed: () async {
              // You will connect this to "NewMailScreen" (below)
              _snack('Open New Mail screen here');
            },
          ),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _stream,
        builder: (_, snap) {
          if (snap.hasError)
            return const Center(child: Text('Failed to load inbox.'));
          final rows = _parse(snap.data?.snapshot.value);
          if (rows.isEmpty) return const Center(child: Text('Inbox is empty.'));

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final row = rows[i];
              final item = row.item;

              return Card(
                child: ListTile(
                  title: Text(
                    item.subject.isEmpty ? '(No subject)' : item.subject,
                  ),
                  subtitle: Text(
                    '${item.peerName.isEmpty ? 'User' : item.peerName}\n${item.lastMessage}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: PopupMenuButton<String>(
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
                  onTap: () async {
                    // This opens your existing thread screen.
                    // We need teacherUid + teacher object.
                    // Since inbox only stores peerUid/peerName, we must fetch Staff from /users/{peerUid}.
                    final peerUid = item.peerUid.trim();
                    if (peerUid.isEmpty) return;

                    final userSnap = await _db.ref('users/$peerUid').get();
                    final v = userSnap.value;

                    if (v is! Map) {
                      _snack('Could not load user.');
                      return;
                    }

                    // build a minimal "teacher" object shape expected by your screen
                    final m = v.map((k, vv) => MapEntry(k.toString(), vv));
                    final teacher = _MinimalStaff(
                      firstName: (m['first_name'] ?? '').toString(),
                      lastName: (m['last_name'] ?? '').toString(),
                      email: (m['email'] ?? '').toString(),
                    );

                    if (!mounted) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AdminTeacherMailThreadScreen(
                          teacherUid: peerUid,
                          teacher: teacher,
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
  });

  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final String peerUid;
  final String peerName;

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
      unreadCount: toInt(m['unreadCount']),
      peerUid: (m['peerUid'] ?? '').toString(),
      peerName: (m['peerName'] ?? '').toString(),
    );
  }
}

/// minimal object so your thread screen can read: teacher.fullName + teacher.email
class _MinimalStaff {
  _MinimalStaff({
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  final String firstName;
  final String lastName;
  final String email;

  String get fullName => '${firstName.trim()} ${lastName.trim()}'.trim();
}
