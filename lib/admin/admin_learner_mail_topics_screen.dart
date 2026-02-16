import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'mail_topic_thread_screen.dart'; // the topic thread screen you already have

class AdminLearnerMailTopicsScreen extends StatefulWidget {
  const AdminLearnerMailTopicsScreen({
    super.key,
    required this.learnerUid,
    required this.learnerName,
  });

  final String learnerUid;
  final String learnerName;

  @override
  State<AdminLearnerMailTopicsScreen> createState() => _AdminLearnerMailTopicsScreenState();
}

class _AdminLearnerMailTopicsScreenState extends State<AdminLearnerMailTopicsScreen> {
  final _db = FirebaseDatabase.instance;
  String get _meUid => FirebaseAuth.instance.currentUser!.uid;
  String get _meName => (FirebaseAuth.instance.currentUser?.email ?? 'Admin').trim();

  Query get _indexQuery =>
      _db.ref('mail_index/$_meUid').orderByChild('peerUid').equalTo(widget.learnerUid);
  DatabaseReference get _threadsRef => _db.ref('mail_threads');

  late final Stream<DatabaseEvent> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _indexQuery.onValue.asBroadcastStream();
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  List<_InboxRow> _parseAndFilter(dynamic data) {
    if (data is! Map) return [];
    final out = <_InboxRow>[];

    data.forEach((k, v) {
      if (k == null || v == null) return;
      if (v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));

      final item = _InboxItem.fromMap(m);

      // ✅ filter: only threads with this learner

      // ✅ ignore deleted for me
      if ((m['deletedAt'] ?? '').toString().trim().isNotEmpty) return;

      out.add(_InboxRow(threadId: k.toString(), item: item));
    });

    out.sort((a, b) => b.item.updatedAtMs.compareTo(a.item.updatedAtMs));
    return out;
  }

  Future<void> _openThread(_InboxRow row) async {
    await _db.ref('mail_index/$_meUid/${row.threadId}/unreadCount').set(0);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MailTopicThreadScreen(
          threadId: row.threadId,
          peerUid: widget.learnerUid,
          peerName: widget.learnerName,
        ),
      ),
    );
  }

  Future<void> _createNewTopic() async {
    final subjectC = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New topic'),
        content: TextField(
          controller: subjectC,
          decoration: const InputDecoration(
            hintText: 'Subject (example: Homework question)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
        ],
      ),
    ) ??
        false;

    if (!ok) return;

    final subject = subjectC.text.trim();
    if (subject.isEmpty) {
      _snack('Write a subject.');
      return;
    }

    try {
      final now = DateTime.now().millisecondsSinceEpoch;

      // ✅ new thread id per topic
      final threadId = _threadsRef.push().key!;
      await _threadsRef.child(threadId).set({
        'subject': subject,
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': '',
      });

      // ✅ update admin index
      await _db.ref('mail_index/$_meUid/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': '',
        'unreadCount': 0,
        'peerUid': widget.learnerUid,
        'peerName': widget.learnerName,
        'deletedAt': null,
      });

      // ✅ update learner index (so learner sees the new topic in inbox)
      await _db.ref('mail_index/${widget.learnerUid}/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': '',
        'unreadCount': 0,
        'peerUid': _meUid,
        'peerName': _meName.isEmpty ? 'Admin' : _meName,
        'deletedAt': null,
      });

      if (!mounted) return;

      // open thread immediately
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MailTopicThreadScreen(
            threadId: threadId,
            peerUid: widget.learnerUid,
            peerName: widget.learnerName,
          ),
        ),
      );
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mail — ${widget.learnerName.isEmpty ? 'Learner' : widget.learnerName}'),
        actions: [
          IconButton(
            tooltip: 'New topic',
            icon: const Icon(Icons.add),
            onPressed: _createNewTopic,
          ),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _stream,
        builder: (_, snap) {
          if (snap.hasError) return const Center(child: Text('Failed to load mail.'));
          final rows = _parseAndFilter(snap.data?.snapshot.value);
          if (rows.isEmpty) return const Center(child: Text('No topics yet. Tap + to create one.'));

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final row = rows[i];
              final item = row.item;
              final hasUnread = item.unreadCount > 0;

              return Card(
                child: ListTile(
                  title: Text(
                    item.subject.isEmpty ? '(No subject)' : item.subject,
                    style: TextStyle(
                      fontWeight: hasUnread ? FontWeight.w800 : FontWeight.w400,
                    ),
                  ),
                  subtitle: Text(
                    item.lastMessage.isEmpty ? 'No messages yet' : item.lastMessage,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                    trailing: hasUnread
                        ? Center(
                      widthFactor: 1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${item.unreadCount}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                        ),
                      ),
                    )
                        : null,

                  onTap: () => _openThread(row),
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
