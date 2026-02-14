import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'teacher_mail_thread_screen.dart';

class TeacherMailScreen extends StatefulWidget {
  const TeacherMailScreen({super.key});

  @override
  State<TeacherMailScreen> createState() => _TeacherMailScreenState();
}

class _TeacherMailScreenState extends State<TeacherMailScreen> {
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

      if (row.deletedAtMs != null) return;

      out.add(row);
    });

    out.sort((a, b) => (b.updatedAtMs).compareTo(a.updatedAtMs));
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

  // -------------------------
  // ✅ New: Compose to admin
  // -------------------------
  Future<void> _composeNewTopic() async {
    try {
      final picked = await showModalBottomSheet<_PickResult>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => _ComposeSheet(db: _db, meUid: _meUid),
      );

      if (picked == null) return;

      final subject = picked.subject.trim();
      final text = picked.firstMessage.trim();

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

      // 1) Thread header
      await _db.ref('mail_threads/$threadId').set({
        'subject': subject,
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': text,
      });

      // 2) First message
      await _db.ref('mail_threads/$threadId/messages/$msgId').set({
        'id': msgId,
        'text': text,
        'senderUid': _meUid,
        'senderName': picked.teacherName,
        'createdAt': now,
      });

      // 3) Teacher index (sender) -> unread 0
      await _db.ref('mail_index/$_meUid/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': text,
        'unreadCount': 0,
        'peerUid': picked.adminUid,
        'peerName': picked.adminName,
        'deletedAt': null,
      });

      // 4) Admin index (receiver) -> unread 1 ✅
      await _db.ref('mail_index/${picked.adminUid}/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': text,
        'unreadCount': 1,
        'peerUid': _meUid,
        'peerName': picked.teacherName,
        'deletedAt': null,
      });

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          settings: RouteSettings(name: '/mail/thread/$threadId'),
          builder: (_) => TeacherMailThreadScreen(
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


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mail')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _composeNewTopic,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _stream,
        builder: (context, snap) {
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
                  '${r.peerName.isEmpty ? "Admin" : r.peerName} • ${r.lastMessage}',
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
                      builder: (_) => TeacherMailThreadScreen(
                        threadId: r.threadId,
                        peerUid: r.peerUid,
                        peerName: r.peerName.isEmpty ? 'Admin' : r.peerName,
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
// Compose Sheet
// ----------------------------

class _ComposeSheet extends StatefulWidget {
  const _ComposeSheet({required this.db, required this.meUid});

  final FirebaseDatabase db;
  final String meUid;

  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  final _messageC = TextEditingController();

  bool _loading = true;
  List<_AdminRow> _admins = [];
  _AdminRow? _picked;
  final _subjectC = TextEditingController();
  String _teacherName = 'Teacher';

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
      // teacher name
      final meSnap = await widget.db.ref('users/${widget.meUid}').get();
      final meVal = meSnap.value;
      if (meVal is Map) {
        final mm = meVal.map((k, v) => MapEntry(k.toString(), v));
        final fn = (mm['first_name'] ?? mm['firstName'] ?? '').toString().trim();
        final ln = (mm['last_name'] ?? mm['lastName'] ?? '').toString().trim();
        final full = '$fn $ln'.trim();
        if (full.isNotEmpty) _teacherName = full;
      }

      // admins list
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

          final name = ('$fn $ln').trim();
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
      _PickResult(
        adminUid: _picked!.uid,
        adminName: _picked!.name,
        subject: subject,
        teacherName: _teacherName,
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
            'New topic',
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
            controller: _subjectC,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Topic / Subject',
              hintText: 'Example: Attendance issue',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),



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

class _PickResult {
  _PickResult({
    required this.adminUid,
    required this.adminName,
    required this.subject,
    required this.teacherName,
    required this.firstMessage,
  });

  final String adminUid;
  final String adminName;
  final String subject;
  final String teacherName;
  final String firstMessage;
}

// ----------------------------
// Topic model (unchanged)
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
