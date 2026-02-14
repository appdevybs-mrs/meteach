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
  // Compose mail (admins + my teachers + my classmates)
  // -------------------------
  Future<void> _composeNewMail() async {
    try {
      final picked = await showModalBottomSheet<_RecipientPickResult>(
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
        'senderName': picked.senderName,
        'createdAt': now,
      });

      // 3) index (sender) unread 0
      await _db.ref('mail_index/$_meUid/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': text,
        'unreadCount': 0,
        'peerUid': picked.receiverUid,
        'peerName': picked.receiverName,
        'deletedAt': null,
      });

      // 4) index (receiver) unread 1
      await _db.ref('mail_index/${picked.receiverUid}/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': text,
        'unreadCount': 1,
        'peerUid': _meUid,
        'peerName': picked.senderName,
        'deletedAt': null,
      });

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          settings: RouteSettings(name: '/mail/thread/$threadId'),
          builder: (_) => LearnerMailThreadScreen(
            threadId: threadId,
            peerUid: picked.receiverUid,
            peerName: picked.receiverName.isEmpty ? 'Staff' : picked.receiverName,
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

  final _subjectC = TextEditingController();
  final _messageC = TextEditingController();

  String _senderName = 'Learner';

  List<_RecipientRow> _recipients = [];
  _RecipientRow? _picked;

  @override
  void initState() {
    super.initState();
    _loadRecipients();
  }

  @override
  void dispose() {
    _subjectC.dispose();
    _messageC.dispose();
    super.dispose();
  }

  Future<void> _loadRecipients() async {
    try {
      // ---------- my name ----------
      final meSnap = await widget.db.ref('users/${widget.meUid}').get();
      final meVal = meSnap.value;
      if (meVal is Map) {
        final mm = meVal.map((k, v) => MapEntry(k.toString(), v));
        final fn = (mm['first_name'] ?? mm['firstName'] ?? '').toString().trim();
        final ln = (mm['last_name'] ?? mm['lastName'] ?? '').toString().trim();
        final full = '$fn $ln'.trim();
        if (full.isNotEmpty) _senderName = full;
      }

      // ---------- load users once (names + admins) ----------
      final usersSnap = await widget.db.ref('users').get();
      final usersVal = usersSnap.value;

      final userNameByUid = <String, String>{};
      final admins = <_RecipientRow>[];

      if (usersVal is Map) {
        usersVal.forEach((uid, vv) {
          if (uid == null || vv == null || vv is! Map) return;
          final m = vv.map((k, v) => MapEntry(k.toString(), v));

          final role = (m['role'] ?? '').toString().toLowerCase().trim();
          final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
          final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
          final email = (m['email'] ?? '').toString().trim();

          final name = ('$fn $ln').trim();
          final display = name.isNotEmpty ? name : (email.isNotEmpty ? email : uid.toString());

          final u = uid.toString();
          userNameByUid[u] = display;

          if (role == 'admin') {
            admins.add(_RecipientRow(uid: u, name: display, type: _RecipientType.admin));
          }
        });
      }

      // ---------- teachers + classmates from my classes ----------
      final classesSnap = await widget.db.ref('classes').get();
      final classesVal = classesSnap.value;

      final teacherUids = <String>{};
      final classmateUids = <String>{};

      if (classesVal is Map) {
        classesVal.forEach((classId, classVal) {
          if (classId == null || classVal == null || classVal is! Map) return;
          final c = classVal.map((k, v) => MapEntry(k.toString(), v));

          final learners = c['learners'];
          if (learners is! Map) return;

          final hasMe = learners.keys.any((k) => k.toString() == widget.meUid);
          if (!hasMe) return;

          // teacher uid from instructor_current.uid
          final cur = c['instructor_current'];
          if (cur is Map) {
            final curM = cur.map((k, v) => MapEntry(k.toString(), v));
            final tUid = (curM['uid'] ?? '').toString().trim();
            if (tUid.isNotEmpty) teacherUids.add(tUid);
          }

          // classmates
          learners.forEach((uid, _) {
            final u = uid.toString().trim();
            if (u.isEmpty) return;
            if (u == widget.meUid) return;
            classmateUids.add(u);
          });
        });
      }

      final teachers = teacherUids.map((tUid) {
        final name = userNameByUid[tUid] ?? 'Teacher';
        return _RecipientRow(uid: tUid, name: name, type: _RecipientType.teacher);
      }).toList();

      final classmates = classmateUids.map((u) {
        final name = userNameByUid[u] ?? 'Learner';
        return _RecipientRow(uid: u, name: name, type: _RecipientType.learner);
      }).toList();

      // ---------- merge + sort ----------
      final all = <_RecipientRow>[
        ...teachers,
        ...admins,
        ...classmates,
      ];

      int rank(_RecipientType t) {
        switch (t) {
          case _RecipientType.teacher:
            return 0;
          case _RecipientType.admin:
            return 1;
          case _RecipientType.learner:
            return 2;
        }
      }

      all.sort((a, b) {
        final r = rank(a.type).compareTo(rank(b.type));
        if (r != 0) return r;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _recipients = all;
        _picked = all.isNotEmpty ? all.first : null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _submit() {
    final r = _picked;
    if (r == null) return;

    final subject = _subjectC.text.trim();
    final msg = _messageC.text.trim();

    if (subject.isEmpty || msg.isEmpty) return;

    Navigator.pop(
      context,
      _RecipientPickResult(
        receiverUid: r.uid,
        receiverName: r.name,
        subject: subject,
        senderName: _senderName,
        firstMessage: msg,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    String prefixFor(_RecipientType t) {
      if (t == _RecipientType.teacher) return '👩‍🏫 ';
      if (t == _RecipientType.admin) return '🛡️ ';
      return '🎓 ';
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          const Text('New mail', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          const SizedBox(height: 12),

          if (_loading)
            const Padding(
              padding: EdgeInsets.all(18),
              child: Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Loading recipients...'),
                ],
              ),
            )
          else if (_recipients.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No teachers, admins, or classmates found for you.'),
            )
          else
            DropdownButtonFormField<_RecipientRow>(
              value: _picked,
              items: _recipients.map((r) {
                return DropdownMenuItem<_RecipientRow>(
                  value: r,
                  child: Text('${prefixFor(r.type)}${r.name}'),
                );
              }).toList(),
              onChanged: (v) => setState(() => _picked = v),
              decoration: const InputDecoration(
                labelText: 'Send to',
                border: OutlineInputBorder(),
              ),
            ),

          const SizedBox(height: 12),

          TextFormField(
            controller: _subjectC,
            decoration: const InputDecoration(
              labelText: 'Topic / Subject',
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

// ----------------------------
// Models
// ----------------------------

class _RecipientPickResult {
  _RecipientPickResult({
    required this.receiverUid,
    required this.receiverName,
    required this.subject,
    required this.senderName,
    required this.firstMessage,
  });

  final String receiverUid;
  final String receiverName;
  final String subject;
  final String senderName;
  final String firstMessage;
}

enum _RecipientType { admin, teacher, learner }

class _RecipientRow {
  _RecipientRow({
    required this.uid,
    required this.name,
    required this.type,
  });

  final String uid;
  final String name;
  final _RecipientType type;
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
