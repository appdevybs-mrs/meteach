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

  // -------------------------
  // Parse topics list
  // -------------------------
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

  // -------------------------
  // Delete for me
  // -------------------------
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

  // -------------------------
  // NEW: Compose mail (choose admin)
  // -------------------------
  Future<void> _composeNewMail() async {
    try {
      final picked = await showModalBottomSheet<_AdminPickResult>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => _ComposeMailSheet(db: _db, meUid: _meUid),
      );

      if (picked == null) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      final threadId = _db.ref('mail_threads').push().key;
      if (threadId == null) {
        _snack('Failed to create thread id.');
        return;
      }

      final msgId = _db.ref('mail_threads/$threadId/messages').push().key;
      if (msgId == null) {
        _snack('Failed to create message id.');
        return;
      }

      final subject = picked.subject.trim();
      final text = picked.firstMessage.trim();

      // 1) thread meta
      await _db.ref('mail_threads/$threadId').set({
        'subject': subject,
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': text,
      });

      // 2) first message
      await _db.ref('mail_threads/$threadId/messages/$msgId').set({
        'id': msgId,
        'text': text,
        'senderUid': _meUid,
        'senderName': picked.learnerName,
        'createdAt': now,
      });

      // 3) index (learner sender) unread 0
      await _db.ref('mail_index/$_meUid/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': text,
        'unreadCount': 0,
        'peerUid': picked.adminUid,
        'peerName': picked.adminName,
        'deletedAt': null,
      });

      // 4) index (admin receiver) unread 1
      await _db.ref('mail_index/${picked.adminUid}/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': text,
        'unreadCount': 1,
        'peerUid': _meUid,
        'peerName': picked.learnerName,
        'deletedAt': null,
      });

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          settings: RouteSettings(name: '/mail/thread/$threadId'),
          builder: (_) => LearnerMailThreadScreen(
            threadId: threadId,
            peerUid: picked.adminUid,
            peerName: picked.adminName.isEmpty ? 'Admin' : picked.adminName,
            subject: subject,
          ),
        ),
      );
    } catch (e) {
      _snack('Compose failed: $e');
    }
  }

  // -------------------------
  // UI
  // -------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mail')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _composeNewMail,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New'),
      ),
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

// ----------------------------
// Compose bottom sheet
// ----------------------------

class _ComposeMailSheet extends StatefulWidget {
  const _ComposeMailSheet({
    required this.db,
    required this.meUid,
  });

  final FirebaseDatabase db;
  final String meUid;

  @override
  State<_ComposeMailSheet> createState() => _ComposeMailSheetState();
}

class _ComposeMailSheetState extends State<_ComposeMailSheet> {
  bool _loading = true;
  List<_AdminRow> _admins = [];
  _AdminRow? _picked;
  final _subjectC = TextEditingController();
  String _learnerName = 'Learner';
  final _messageC = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAdminsAndMe();
  }

  @override
  void dispose() {
    _subjectC.dispose();
    _messageC.dispose();
    super.dispose();
  }


  Future<void> _loadAdminsAndMe() async {
    try {
      // get my name (optional, but helps admin index peerName)
      final meSnap = await widget.db.ref('users/${widget.meUid}').get();
      final meVal = meSnap.value;
      if (meVal is Map) {
        final mm = meVal.map((k, v) => MapEntry(k.toString(), v));
        final fn = (mm['first_name'] ?? mm['firstName'] ?? '').toString().trim();
        final ln = (mm['last_name'] ?? mm['lastName'] ?? '').toString().trim();
        final full = '$fn $ln'.trim();
        if (full.isNotEmpty) _learnerName = full;
      }

      // load admins from users (client-side filter)
      final snap = await widget.db.ref('users').get();
      final v = snap.value;

      final out = <_AdminRow>[];
      if (v is Map) {
        v.forEach((uid, vv) {
          if (uid == null || vv == null) return;
          if (vv is! Map) return;

          final m = vv.map((k, v) => MapEntry(k.toString(), v));
          final role = (m['role'] ?? '').toString().toLowerCase().trim();
          if (role != 'admin') return;

          final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
          final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
          final email = (m['email'] ?? '').toString().trim();

          final name = ('${fn} ${ln}').trim();
          final display = name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Admin');

          out.add(_AdminRow(uid: uid.toString(), name: display));
        });
      }

      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _admins = out;
        _picked = out.isNotEmpty ? out.first : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _submit() {
    if (_picked == null) return;
    final subject = _subjectC.text.trim();
    final msg = _messageC.text.trim();
    if (subject.isEmpty || msg.isEmpty) return;

    Navigator.pop(
      context,
      _AdminPickResult(
        adminUid: _picked!.uid,
        adminName: _picked!.name,
        subject: subject,
        learnerName: _learnerName,
        firstMessage: msg,
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          const Text(
            'New mail',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
          ),
          const SizedBox(height: 12),

          if (_loading)
            const Padding(
              padding: EdgeInsets.all(18),
              child: Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Loading admins...'),
                ],
              ),
            )
          else if (_admins.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No admins found (users where role = admin).'),
            )
          else
            DropdownButtonFormField<_AdminRow>(
              value: _picked,
              items: _admins
                  .map((a) => DropdownMenuItem<_AdminRow>(
                value: a,
                child: Text(a.name),
              ))
                  .toList(),
              onChanged: (v) => setState(() => _picked = v),
              decoration: const InputDecoration(
                labelText: 'Send to',
                border: OutlineInputBorder(),
              ),
            ),

          const SizedBox(height: 12),

          TextFormField(
            controller: _messageC,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'First message',
              hintText: 'Write your message…',
              border: OutlineInputBorder(),
            ),
          ),


          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_picked == null) ? null : _submit,
              icon: const Icon(Icons.send_rounded),
              label: const Text('Create topic'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminRow {
  _AdminRow({required this.uid, required this.name});
  final String uid;
  final String name;
}

class _AdminPickResult {
  _AdminPickResult({
    required this.adminUid,
    required this.adminName,
    required this.subject,
    required this.learnerName,
    required this.firstMessage,
  });

  final String adminUid;
  final String adminName;
  final String subject;
  final String learnerName;
  final String firstMessage;
}


// ----------------------------
// Topic Row model
// ----------------------------

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
