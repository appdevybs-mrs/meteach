import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'learner_mail_thread_screen.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

class LearnerHomeworkScreen extends StatefulWidget {
  final String courseKey; // course_1, course_2...
  final String courseTitle;

  const LearnerHomeworkScreen({
    super.key,
    required this.courseKey,
    required this.courseTitle,
  });

  @override
  State<LearnerHomeworkScreen> createState() => _LearnerHomeworkScreenState();
}

class _LearnerHomeworkScreenState extends State<LearnerHomeworkScreen> {
  static const usersNode = 'users';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);

  bool _busy = true;
  String? _error;

  String _uid = '';
  List<Map<String, dynamic>> _items = [];
  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  DatabaseReference _hwRef(String sessionId) {
    return _usersRef
        .child(_uid)
        .child('courses')
        .child(widget.courseKey)
        .child('attendance')
        .child(sessionId)
        .child('homework');
  }

  Future<void> _markSeen(String sessionId) async {
    try {
      await _hwRef(sessionId).update({'seenAt': _nowMs()});
    } catch (_) {}
  }


  Future<void> _createHomeworkMailAndOpen({
    required String sessionId,
    required String teacherUid,
    required String teacherName,
    required String date,
    required String dueDate,
    required String taughtTitle,
    required String homeworkText,

  }) async {
    if (teacherUid.trim().isEmpty) return;

    final now = _nowMs();

    // ✅ Deterministic thread per session (prevents duplicates/spam)
    // If learner undoes then marks done again, it continues same thread.
    final threadId = '${_uid}_${teacherUid}_$sessionId';

    final subject = '[HW] ${widget.courseTitle} • $date${taughtTitle.isEmpty ? '' : ' • $taughtTitle'}';

    final body = [
      'Homework submission',
      'Course: ${widget.courseTitle}',
      if (date.isNotEmpty) 'Session date: $date',
      if (taughtTitle.isNotEmpty) 'Lesson: $taughtTitle',
      if (dueDate.isNotEmpty) 'Due: $dueDate',
      '',
      'Task:',
      homeworkText.isEmpty ? '—' : homeworkText,
      '',
      '➡️ Please attach your homework file here (photo/PDF) or type your answer.',
    ].join('\n');

    // Push message id
    final msgKey = _db.child('mail_messages').child(threadId).push().key;
    if (msgKey == null) return;

    // Multi-location update (thread + message + my index)
    final Map<String, dynamic> updates = {
      // thread meta
      'mail_threads/$threadId/subject': subject,
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/createdAt': now,
      'mail_threads/$threadId/lastMessage': body.length > 60 ? body.substring(0, 60) : body,
      'mail_threads/$threadId/participants/$_uid': true,
      'mail_threads/$threadId/participants/$teacherUid': true,
// ✅ Homework linkage (for full cycle)
      'mail_threads/$threadId/type': 'homework',
      'mail_threads/$threadId/courseKey': widget.courseKey,
      'mail_threads/$threadId/sessionId': sessionId,
      'mail_threads/$threadId/learnerUid': _uid,
      'mail_threads/$threadId/teacherUid': teacherUid,
      'mail_threads/$threadId/homeworkRef':
      'users/$_uid/courses/${widget.courseKey}/attendance/$sessionId/homework',

      // message itself
      'mail_messages/$threadId/$msgKey/body': body,
      'mail_messages/$threadId/$msgKey/createdAt': now,
      'mail_messages/$threadId/$msgKey/fromUid': _uid,
      'mail_messages/$threadId/$msgKey/toUids/$teacherUid': true,

      // my index
      'mail_index/$_uid/$threadId/peerUid': teacherUid,
      'mail_index/$_uid/$threadId/peerName': teacherName.isEmpty ? 'Teacher' : teacherName,
      'mail_index/$_uid/$threadId/subject': subject,
      'mail_index/$_uid/$threadId/lastMessage': body.length > 60 ? body.substring(0, 60) : body,
      'mail_index/$_uid/$threadId/unreadCount': 0,
      'mail_index/$_uid/$threadId/updatedAt': now,

      // my read state (optional but consistent)
      'mail_state/$_uid/$threadId/lastReadAt': now,
    };

    await _db.update(updates);

    // Teacher index + unreadCount increment safely
    final teacherIndexRef = _db.child('mail_index').child(teacherUid).child(threadId);

    await teacherIndexRef.update({
      'peerUid': _uid,
      // if you have learner name, you can put it here; otherwise courseTitle is still helpful
      'peerName': widget.courseTitle,
      'subject': subject,
      'lastMessage': body.length > 60 ? body.substring(0, 60) : body,
      'updatedAt': now,
    });

    await teacherIndexRef.child('unreadCount').runTransaction((v) {
      final curr = (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
      return Transaction.success(curr + 1);
    });

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LearnerMailThreadScreen(
          threadId: threadId,
          peerUid: teacherUid,
          peerName: teacherName.isEmpty ? 'Teacher' : teacherName,
          subject: subject,
        ),
      ),
    );

// ✅ refresh list so submittedAt appears
    if (mounted) await _load();

  }
  Future<void> _toggleDone(String sessionId, {required bool currentlyDone}) async {
    try {
      if (currentlyDone) {
        // undo
        await _hwRef(sessionId).child('doneAt').remove();
      } else {
        await _hwRef(sessionId).update({'doneAt': _nowMs()});
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _items = [];
      _uid = '';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      final snap = await _usersRef.child(_uid).child('courses').child(widget.courseKey).child('attendance').get();
      if (!snap.exists || snap.value == null) {
        setState(() => _busy = false);
        return;
      }

      final raw = Map<String, dynamic>.from(snap.value as Map);
      final List<Map<String, dynamic>> list = [];

      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final rec = Map<String, dynamic>.from(entry.value as Map);

        final hw = (rec['homework'] is Map) ? Map<String, dynamic>.from(rec['homework'] as Map) : <String, dynamic>{};
        final text = (hw['text'] ?? '').toString().trim();
        final due = (hw['dueDate'] ?? '').toString().trim();

        if (text.isEmpty && due.isEmpty) continue;

        final taught = (rec['taught'] is Map) ? Map<String, dynamic>.from(rec['taught'] as Map) : <String, dynamic>{};
        final taughtTitle = (taught['title'] ?? '').toString();

        final seenAt = hw['seenAt'];
        final doneAt = hw['doneAt'];
        final submittedAt = hw['submittedAt'];
        final reviewedAt = hw['reviewedAt'];
        final reviewStatus = (hw['reviewStatus'] ?? '').toString().trim();

        final teacherUid = (rec['teacherUid'] ?? '').toString().trim();
        final teacherName = (rec['teacherName'] ?? '').toString().trim();

        list.add({
          'sessionId': entry.key.toString(),
          'date': (rec['date'] ?? '').toString(),
          'taughtTitle': taughtTitle,
          'text': text,
          'dueDate': due,
          'seenAt': seenAt,
          'doneAt': doneAt,
          'submittedAt': submittedAt,
          'reviewedAt': reviewedAt,
          'reviewStatus': reviewStatus,


          // ✅ NEW (needed for auto-mail)
          'teacherUid': teacherUid,
          'teacherName': teacherName,
        });


      }

      list.sort((a, b) => (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString()));

      setState(() {
        _items = list;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<bool> _confirmMarkDone() async {
    final res = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit homework?'),
        content: const Text(
          'This will open a message to your teacher with the homework details.\n\nContinue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, open mail'),
          ),
        ],
      ),
    );
    return res == true;
  }

  Widget _statusBadge({required String text, required Color bg, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withOpacity(0.25)),
      ),
      child: Text(
        text,
        style: TextStyle(fontWeight: FontWeight.w900, color: fg, fontSize: 12),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: Text(
          '${widget.courseTitle} - Homework',
          style: const TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: WatermarkBackground(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
          ),
        )
            : _items.isEmpty
            ? const Center(
          child: Text('No homework yet.',
              style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800)),
        )
            : ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _items.length,
          itemBuilder: (_, i) {
            final it = _items[i];
            final date = (it['date'] ?? '').toString();
            final due = (it['dueDate'] ?? '').toString();
            final text = (it['text'] ?? '').toString();
            final taughtTitle = (it['taughtTitle'] ?? '').toString();

            final sessionId = (it['sessionId'] ?? '').toString();
            final seenAt = it['seenAt'];
            final doneAt = it['doneAt'];

            final isSeen = seenAt != null;
            final isDone = doneAt != null;
            final submittedAt = it['submittedAt'];
            final reviewedAt = it['reviewedAt'];
            final reviewStatus = (it['reviewStatus'] ?? '').toString();

            return InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () async {
                if (!isSeen) {
                  await _markSeen(sessionId);
                  // update local immediately for UI
                  if (mounted) {
                    setState(() {
                      it['seenAt'] = _nowMs();
                    });
                  }
                }
              },
              child: Card(
                elevation: 0,
                color: Colors.white,
                shape: UiK.cardShape(),
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              date.isEmpty ? 'Session' : date,
                              style: UiK.titleText(size: 15),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (reviewedAt != null)
                            _statusBadge(
                              text: reviewStatus == 'needs_work' ? 'Needs work' : 'Reviewed',
                              bg: (reviewStatus == 'needs_work' ? Colors.red : Colors.green).withOpacity(0.10),
                              fg: (reviewStatus == 'needs_work' ? Colors.red : Colors.green),
                            )
                          else if (submittedAt != null)
                            _statusBadge(
                              text: 'Submitted',
                              bg: Colors.amber.withOpacity(0.15),
                              fg: Colors.orange,
                            )
                          else
                            _statusBadge(
                              text: 'Not submitted',
                              bg: Colors.red.withOpacity(0.08),
                              fg: Colors.red,
                            ),

                          if (isDone)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: UiK.primaryBlue.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                              ),
                              child: const Text(
                                'Done',
                                style: TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue, fontSize: 12),
                              ),
                            )
                          else if (isSeen)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: UiK.actionOrange.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: UiK.actionOrange.withOpacity(0.25)),
                              ),
                              child: const Text(
                                'Seen',
                                style: TextStyle(fontWeight: FontWeight.w900, color: UiK.actionOrange, fontSize: 12),
                              ),
                            ),
                        ],
                      ),

                      const SizedBox(height: 6),

                      if (taughtTitle.isNotEmpty)
                        Text('Lesson: $taughtTitle', style: UiK.subtleText()),

                      if (due.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('Due: $due', style: UiK.subtleText()),
                      ],

                      if (text.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(text, style: UiK.subtleText()),
                      ],

                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: Icon(isDone ? Icons.undo_rounded : Icons.check_circle_rounded),
                              label: Text(isDone ? 'Undo' : 'Mark done'),
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: () async {
                                // ✅ Undo = no mail + (optional) undo submitted
                                if (isDone) {
                                  await _toggleDone(sessionId, currentlyDone: true);

                                  // OPTIONAL: if you want undo to also remove submittedAt
                                  // await _hwRef(sessionId).child('submittedAt').remove();

                                  if (mounted) {
                                    setState(() {
                                      it['doneAt'] = null;
                                      // it['submittedAt'] = null; // OPTIONAL for UI
                                    });
                                  }
                                  return;
                                }

                                // ✅ Mark done + submitted immediately
                                final now = _nowMs();

                                // 1) doneAt
                                await _hwRef(sessionId).update({
                                  'doneAt': now,
                                  'submittedAt': now, // ✅ THIS is the key
                                  'seenAt': it['seenAt'] ?? now,
                                });

                                // update local immediately
                                if (mounted) {
                                  setState(() {
                                    it['doneAt'] = now;
                                    it['submittedAt'] = now; // ✅ local UI
                                    it['seenAt'] ??= now;
                                  });
                                }

                                // ✅ Then auto-create mail + open thread
                                final teacherUid = (it['teacherUid'] ?? '').toString();
                                final teacherName = (it['teacherName'] ?? '').toString();

                                await _createHomeworkMailAndOpen(
                                  sessionId: sessionId,
                                  teacherUid: teacherUid,
                                  teacherName: teacherName,
                                  date: date,
                                  dueDate: due,
                                  taughtTitle: taughtTitle,
                                  homeworkText: text,
                                );
                              },



                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );

          },
        ),
      ),
    );
  }
}
