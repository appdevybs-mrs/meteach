import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'mail_topic_thread_screen.dart';

class AdminTeacherMailTopicsScreen extends StatefulWidget {
  const AdminTeacherMailTopicsScreen({
    super.key,
    required this.teacherUid,
    required this.teacher,
  });

  final String teacherUid;
  final dynamic teacher; // Staff OR Map

  @override
  State<AdminTeacherMailTopicsScreen> createState() =>
      _AdminTeacherMailTopicsScreenState();
}

class _AdminTeacherMailTopicsScreenState
    extends State<AdminTeacherMailTopicsScreen> {
  final _db = FirebaseDatabase.instance;

  String get _meUid => FirebaseAuth.instance.currentUser!.uid;
  DatabaseReference get _indexRef => _db.ref('mail_index');

  late final Stream<DatabaseEvent> _topicsStream;

  @override
  void initState() {
    super.initState();

    // ✅ Only threads with this teacher (peerUid == teacherUid)
    _topicsStream = _indexRef
        .child(_meUid)
        .orderByChild('peerUid')
        .equalTo(widget.teacherUid)
        .onValue
        .asBroadcastStream();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _teacherDisplayName() {
    final t = widget.teacher;

    // Staff model (has .fullName)
    try {
      final fullName = (t?.fullName ?? '').toString().trim();
      if (fullName.isNotEmpty) return fullName;
    } catch (_) {}

    // Map from RTDB
    if (t is Map) {
      String read(dynamic key) => (t[key] ?? '').toString().trim();

      final first = read('first_name').isNotEmpty
          ? read('first_name')
          : read('firstName');
      final last = read('last_name').isNotEmpty
          ? read('last_name')
          : read('lastName');
      final full = ('$first $last').trim();
      if (full.isNotEmpty) return full;

      final email = read('email');
      if (email.isNotEmpty) return email;
    }

    return 'Teacher';
  }

  List<_TopicRow> _parseIndex(dynamic v) {
    if (v is! Map) return [];

    final out = <_TopicRow>[];

    v.forEach((k, val) {
      if (k == null || val == null) return;
      if (val is! Map) return;

      final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
      final deletedAt = m['deletedAt'];
      if (deletedAt != null) return; // ✅ hide deleted threads in list

      out.add(
        _TopicRow(
          threadId: k.toString(),
          subject: (m['subject'] ?? '').toString().trim(),
          lastMessage: (m['lastMessage'] ?? '').toString(),
          updatedAt: _toInt(m['updatedAt']),
          unreadCount: _toInt(m['unreadCount']),
          peerUid: (m['peerUid'] ?? '').toString(),
          peerName: (m['peerName'] ?? '').toString(),
        ),
      );
    });

    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Future<void> _createNewTopic() async {
    final subject = await showDialog<String?>(
      context: context,
      builder: (_) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('New topic'),
          content: TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'Topic / Subject'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, c.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (subject == null) return;
    if (subject.trim().isEmpty) {
      _snack('Please type a topic.');
      return;
    }

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final threadId = _db.ref('mail_threads').push().key!;
      final teacherName = _teacherDisplayName();
      final myName = (FirebaseAuth.instance.currentUser?.email ?? 'Admin')
          .trim();

      // 1) create thread meta
      await _db.ref('mail_threads/$threadId').set({
        'subject': subject.trim(),
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': '',
        'participants': {_meUid: true, widget.teacherUid: true},
      });

      // 2) create index item for admin (me)
      await _indexRef.child(_meUid).child(threadId).set({
        'subject': subject.trim(),
        'updatedAt': now,
        'lastMessage': '',
        'unreadCount': 0,
        'peerUid': widget.teacherUid,
        'peerName': teacherName,
        'deletedAt': null,
      });

      // 3) create index item for teacher
      await _indexRef.child(widget.teacherUid).child(threadId).set({
        'subject': subject.trim(),
        'updatedAt': now,
        'lastMessage': '',
        'unreadCount': 0,
        'peerUid': _meUid,
        'peerName': myName,
        'deletedAt': null,
      });

      // 4) open the new topic thread
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MailTopicThreadScreen(
            threadId: threadId,
            peerUid: widget.teacherUid,
            peerName: teacherName,
          ),
        ),
      );
    } catch (e) {
      _snack('Create topic failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final teacherName = _teacherDisplayName();

    return Scaffold(
      appBar: AppBar(
        title: Text('Mail — $teacherName'),
        actions: [
          IconButton(
            tooltip: 'New topic',
            onPressed: _createNewTopic,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _topicsStream,
        builder: (_, snap) {
          final rows = _parseIndex(snap.data?.snapshot.value);

          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.mail_outline, size: 42),
                    const SizedBox(height: 10),
                    const Text('No topics yet.'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _createNewTopic,
                      icon: const Icon(Icons.add),
                      label: const Text('Create a topic'),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final t = rows[i];

              return Card(
                elevation: 0,
                child: ListTile(
                  title: Text(
                    t.subject.isEmpty ? '(No subject)' : t.subject,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    t.lastMessage.isEmpty ? 'No messages yet' : t.lastMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: t.unreadCount > 0
                      ? CircleAvatar(
                          radius: 12,
                          child: Text(
                            '${t.unreadCount}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MailTopicThreadScreen(
                          threadId: t.threadId,
                          peerUid: widget.teacherUid,
                          peerName: teacherName,
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

class _TopicRow {
  _TopicRow({
    required this.threadId,
    required this.subject,
    required this.lastMessage,
    required this.updatedAt,
    required this.unreadCount,
    required this.peerUid,
    required this.peerName,
  });

  final String threadId;
  final String subject;
  final String lastMessage;
  final int updatedAt;
  final int unreadCount;
  final String peerUid;
  final String peerName;
}
