import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/human_error.dart';
import 'teacher_mail_thread_screen.dart';

class TeacherHomeworkInboxScreen extends StatefulWidget {
  const TeacherHomeworkInboxScreen({super.key});

  @override
  State<TeacherHomeworkInboxScreen> createState() =>
      _TeacherHomeworkInboxScreenState();
}

class _TeacherHomeworkInboxScreenState
    extends State<TeacherHomeworkInboxScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String _meUid = '';
  Stream<DatabaseEvent>? _indexStream;

  @override
  void initState() {
    super.initState();
    _meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (_meUid.isNotEmpty) {
      _indexStream = _db.child('mail_index/$_meUid').onValue;
    }
  }

  bool _isHomework(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'homework') return true;

    final subject = (m['subject'] ?? '').toString().trim().toLowerCase();
    if (subject.startsWith('[hw]')) return true;
    if (subject.contains('homework')) return true;
    return false;
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  List<_HomeworkThreadRow> _rowsFromSnapshot(dynamic value) {
    if (value is! Map) return const <_HomeworkThreadRow>[];
    final out = <_HomeworkThreadRow>[];

    value.forEach((threadIdRaw, rowRaw) {
      if (rowRaw is! Map) return;
      final m = rowRaw.map((k, v) => MapEntry(k.toString(), v));
      if (m['deletedAt'] != null) return;
      if (!_isHomework(m)) return;

      final threadId = threadIdRaw.toString().trim();
      if (threadId.isEmpty) return;

      final peerUid = (m['peerUid'] ?? '').toString().trim();
      final peerName = (m['peerName'] ?? '').toString().trim();
      final subject = (m['subject'] ?? '').toString().trim();
      final lastMessage = (m['lastMessage'] ?? '').toString().trim();

      out.add(
        _HomeworkThreadRow(
          threadId: threadId,
          peerUid: peerUid,
          peerName: peerName.isEmpty ? 'Learner' : peerName,
          subject: subject.isEmpty ? 'Homework' : subject,
          lastMessage: lastMessage,
          updatedAtMs: _toInt(m['updatedAt']),
          unreadCount: _toInt(m['unreadCount']),
        ),
      );
    });

    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$dd/$mo ${dt.year} $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Homework Inbox')),
      body: _indexStream == null
          ? const Center(child: Text('Please sign in again.'))
          : StreamBuilder<DatabaseEvent>(
              stream: _indexStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        toHumanError(snap.error ?? Exception('Unknown error')),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                }

                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final rows = _rowsFromSnapshot(snap.data?.snapshot.value);
                if (rows.isEmpty) {
                  return const Center(child: Text('No homework threads yet.'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    return Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: Colors.orange.withValues(
                            alpha: 0.15,
                          ),
                          child: const Icon(
                            Icons.assignment_rounded,
                            color: Colors.orange,
                          ),
                        ),
                        title: Text(
                          row.subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          '${row.peerName}\n${row.lastMessage.isEmpty ? '-' : row.lastMessage}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _fmtTime(row.updatedAtMs),
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.black.withValues(alpha: 0.6),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (row.unreadCount > 0) ...[
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  row.unreadCount.toString(),
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => TeacherMailThreadScreen(
                                threadId: row.threadId,
                                peerUid: row.peerUid,
                                peerName: row.peerName,
                                subject: row.subject,
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

class _HomeworkThreadRow {
  const _HomeworkThreadRow({
    required this.threadId,
    required this.peerUid,
    required this.peerName,
    required this.subject,
    required this.lastMessage,
    required this.updatedAtMs,
    required this.unreadCount,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
}
