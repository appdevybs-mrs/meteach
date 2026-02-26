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
  final Set<String> _expanded = <String>{};

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

      final snap =
      await _usersRef.child(_uid).child('courses').child(widget.courseKey).child('attendance').get();
      if (!snap.exists || snap.value == null) {
        setState(() => _busy = false);
        return;
      }

      final raw = Map<String, dynamic>.from(snap.value as Map);
      final List<Map<String, dynamic>> list = [];

      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final rec = Map<String, dynamic>.from(entry.value as Map);

        final hw =
        (rec['homework'] is Map) ? Map<String, dynamic>.from(rec['homework'] as Map) : <String, dynamic>{};
        final text = (hw['text'] ?? '').toString().trim();
        final due = (hw['dueDate'] ?? '').toString().trim();

        if (text.isEmpty && due.isEmpty) continue;

        final taught = (rec['taught'] is Map) ? Map<String, dynamic>.from(rec['taught'] as Map) : <String, dynamic>{};
        final taughtTitle = (taught['title'] ?? '').toString();

        final seenAt = hw['seenAt'];
        final doneAt = hw['doneAt'];
        final submittedAt = hw['submittedAt'];

        final reviewedAt = hw['reviewedAt'];
        final reviewStatus = (hw['reviewStatus'] ?? '').toString().trim(); // pass / redo
        final reviewScore = hw['reviewScore'];
        final reviewGrade = (hw['reviewGrade'] ?? '').toString().trim(); // A/B/C/D (new)
        final reviewNote = (hw['reviewNote'] ?? '').toString();
        final needsRedo = hw['needsRedo'] == true; // new

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
          'reviewScore': reviewScore,
          'reviewGrade': reviewGrade,
          'reviewNote': reviewNote,
          'needsRedo': needsRedo,

          // ✅ needed for auto-mail
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

  Widget _statusBadge({required String text, required Color bg, required Color fg, IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(fontWeight: FontWeight.w900, color: fg, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ---------- New: compact stats ----------
  Map<String, dynamic> _calcStats(List<Map<String, dynamic>> items) {
    int total = items.length;
    int done = 0;
    int left = 0;
    int reviewed = 0;
    int redo = 0;

    final Map<String, int> gradeCount = {'A': 0, 'B': 0, 'C': 0, 'D': 0};

    for (final it in items) {
      final doneAt = it['doneAt'];
      final isDone = doneAt != null;
      if (isDone) done++;

      final submittedAt = it['submittedAt'];
      final reviewedAt = it['reviewedAt'];
      final reviewStatus = (it['reviewStatus'] ?? '').toString().trim();
      final needsRedo = it['needsRedo'] == true;

      if (reviewedAt != null) reviewed++;
      if (reviewStatus == 'redo' || needsRedo) redo++;

      final g = (it['reviewGrade'] ?? '').toString().trim().toUpperCase();
      if (gradeCount.containsKey(g)) {
        gradeCount[g] = (gradeCount[g] ?? 0) + 1;
      }

      // "Left" = not submitted yet (simple & clear)
      if (submittedAt == null) left++;
    }

    String commonGrade = '—';
    int best = 0;
    for (final e in gradeCount.entries) {
      if (e.value > best) {
        best = e.value;
        commonGrade = e.value == 0 ? '—' : e.key;
      }
    }

    return {
      'total': total,
      'done': done,
      'left': left,
      'reviewed': reviewed,
      'redo': redo,
      'commonGrade': commonGrade,
    };
  }

  // ---------- New: coloring helpers ----------
  Color _gradeTint(String grade) {
    final g = grade.trim().toUpperCase();
    if (g == 'A') return Colors.green.withOpacity(0.08);
    if (g == 'B') return Colors.blue.withOpacity(0.08);
    if (g == 'C') return Colors.orange.withOpacity(0.10);
    if (g == 'D') return Colors.red.withOpacity(0.08);
    return Colors.white;
  }

  Color _gradeAccent(String grade) {
    final g = grade.trim().toUpperCase();
    if (g == 'A') return Colors.green;
    if (g == 'B') return Colors.blue;
    if (g == 'C') return Colors.orange;
    if (g == 'D') return Colors.red;
    return UiK.primaryBlue;
  }

  Widget _statsCard() {
    final s = _calcStats(_items);

    Widget chip(String label, String value, IconData icon) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: UiK.uiBorder.withOpacity(0.7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: UiK.primaryBlue.withOpacity(0.85)),
            const SizedBox(width: 8),
            Text(
              '$label: ',
              style: TextStyle(color: UiK.mainText.withOpacity(0.75), fontWeight: FontWeight.w800, fontSize: 12),
            ),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: UiK.mainText),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_rounded, color: UiK.primaryBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your homework overview',
                    style: UiK.titleText(size: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                chip('Done', '${s['done']}/${s['total']}', Icons.check_circle_rounded),
                chip('Left', '${s['left']}', Icons.pending_actions_rounded),
                chip('Reviewed', '${s['reviewed']}', Icons.fact_check_rounded),
                chip('Redo', '${s['redo']}', Icons.refresh_rounded),
                chip('Common grade', '${s['commonGrade']}', Icons.grade_rounded),
              ],
            ),
          ],
        ),
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
          child: Text(
            'No homework yet.',
            style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800),
          ),
        )
            : ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: _items.length + 1,
          itemBuilder: (_, idx) {
            if (idx == 0) return _statsCard();

            final it = _items[idx - 1];

            final date = (it['date'] ?? '').toString();
            final due = (it['dueDate'] ?? '').toString();
            final text = (it['text'] ?? '').toString();
            final taughtTitle = (it['taughtTitle'] ?? '').toString();

            final sessionId = (it['sessionId'] ?? '').toString();
            final isExpanded = _expanded.contains(sessionId);

            final seenAt = it['seenAt'];
            final doneAt = it['doneAt'];

            final isSeen = seenAt != null;
            final isDone = doneAt != null;
            final submittedAt = it['submittedAt'];

            final reviewedAt = it['reviewedAt'];
            final reviewStatus = (it['reviewStatus'] ?? '').toString().trim(); // pass/redo
            final needsRedo = it['needsRedo'] == true;

            final reviewScore = it['reviewScore'];
            final reviewGrade = (it['reviewGrade'] ?? '').toString().trim(); // A/B/C/D
            final reviewNote = (it['reviewNote'] ?? '').toString();

            final bool isRedo = (reviewStatus == 'redo') || needsRedo;
            final bool isReviewed = reviewedAt != null;

            // Card coloring rules:
            // - If redo -> red tint
            // - else if reviewed + grade -> grade tint
            // - else white
            final Color cardBg = isRedo
                ? Colors.red.withOpacity(0.06)
                : (isReviewed && reviewGrade.isNotEmpty ? _gradeTint(reviewGrade) : Colors.white);

            final Color accent = isRedo
                ? Colors.red
                : (isReviewed && reviewGrade.isNotEmpty ? _gradeAccent(reviewGrade) : UiK.primaryBlue);

            Widget buildTopBadges() {
              if (isReviewed) {
                if (isRedo) {
                  return _statusBadge(
                    text: 'Redo',
                    bg: Colors.red.withOpacity(0.10),
                    fg: Colors.red,
                    icon: Icons.refresh_rounded,
                  );
                }
                return _statusBadge(
                  text: 'Passed',
                  bg: Colors.green.withOpacity(0.10),
                  fg: Colors.green,
                  icon: Icons.check_circle_rounded,
                );
              }

              if (submittedAt != null) {
                return _statusBadge(
                  text: 'Submitted',
                  bg: Colors.amber.withOpacity(0.15),
                  fg: Colors.orange,
                  icon: Icons.upload_file_rounded,
                );
              }

              return _statusBadge(
                text: 'Not submitted',
                bg: Colors.red.withOpacity(0.08),
                fg: Colors.red,
                icon: Icons.error_outline_rounded,
              );
            }

            return InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () async {
                final willExpand = !_expanded.contains(sessionId);

                setState(() {
                  if (willExpand) {
                    _expanded.add(sessionId);
                  } else {
                    _expanded.remove(sessionId);
                  }
                });

                // mark seen only when expanding
                if (willExpand && !isSeen) {
                  await _markSeen(sessionId);
                  if (mounted) {
                    setState(() {
                      it['seenAt'] = _nowMs();
                    });
                  }
                }
              },
              child: Card(
                elevation: 0,
                color: cardBg,
                shape: UiK.cardShape(),
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: accent.withOpacity(0.22)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      date.isEmpty ? 'Session' : date,
                                      style: UiK.titleText(size: 15),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(
                                    isExpanded
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    size: 20,
                                    color: UiK.primaryBlue.withOpacity(0.7),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            buildTopBadges(),
                            const SizedBox(width: 8),

                            // Seen / Done mini badge (keeps your old logic)
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
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: UiK.primaryBlue,
                                    fontSize: 12,
                                  ),
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
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: UiK.actionOrange,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // Collapsed vs Expanded content
                        if (!isExpanded) ...[
                          Text(
                            (due.isNotEmpty ? 'Due: $due' : (taughtTitle.isNotEmpty ? taughtTitle : 'Homework')),
                            style: UiK.subtleText(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (isReviewed && reviewGrade.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(Icons.grade_rounded, size: 18, color: accent),
                                const SizedBox(width: 6),
                                Text(
                                  'Grade: ${reviewGrade.toUpperCase()}',
                                  style: TextStyle(fontWeight: FontWeight.w900, color: accent),
                                ),
                              ],
                            ),
                          ],
                        ] else ...[
                          // Expanded: review details
                          if (isReviewed) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.grade_rounded, size: 18, color: accent),
                                const SizedBox(width: 6),
                                Text(
                                  reviewGrade.isNotEmpty
                                      ? 'Grade: ${reviewGrade.toUpperCase()}'
                                      : 'Grade: —',
                                  style: TextStyle(fontWeight: FontWeight.w900, color: accent),
                                ),
                                const SizedBox(width: 10),
                                const Icon(Icons.score_rounded, size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  'Score: ${(reviewScore ?? 0).toString()}/100',
                                  style: const TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ],
                            ),
                            if (isRedo) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Teacher asked you to redo this homework.',
                                style: TextStyle(color: Colors.red.withOpacity(0.85), fontWeight: FontWeight.w800),
                              ),
                            ],
                            if (reviewNote.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text('Teacher note:', style: TextStyle(fontWeight: FontWeight.w900, color: UiK.mainText.withOpacity(0.9))),
                              const SizedBox(height: 6),
                              Text(reviewNote, style: UiK.subtleText()),
                            ],
                          ],

                          if (taughtTitle.isNotEmpty) ...[
                            if (!isReviewed) const SizedBox(height: 6),
                            Text('Lesson: $taughtTitle', style: UiK.subtleText()),
                          ],

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
                                    if (isDone) {
                                      await _toggleDone(sessionId, currentlyDone: true);
                                      if (mounted) {
                                        setState(() => it['doneAt'] = null);
                                      }
                                      return;
                                    }

                                    final now = _nowMs();

                                    await _hwRef(sessionId).update({
                                      'doneAt': now,
                                      'submittedAt': now,
                                      'seenAt': it['seenAt'] ?? now,
                                    });

                                    if (mounted) {
                                      setState(() {
                                        it['doneAt'] = now;
                                        it['submittedAt'] = now;
                                        it['seenAt'] ??= now;
                                      });
                                    }

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

                          // Helpful quick action: open the homework mail thread (compact)
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.mail_outline_rounded),
                                  label: const Text('Open homework chat'),
                                  style: OutlinedButton.styleFrom(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                  onPressed: () async {
                                    final teacherUid = (it['teacherUid'] ?? '').toString().trim();
                                    if (teacherUid.isEmpty) return;

                                    final threadId = '${_uid}_${teacherUid}_$sessionId';
                                    final subject =
                                        '[HW] ${widget.courseTitle} • $date${taughtTitle.isEmpty ? '' : ' • $taughtTitle'}';

                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => LearnerMailThreadScreen(
                                          threadId: threadId,
                                          peerUid: teacherUid,
                                          peerName: ((it['teacherName'] ?? '').toString().trim().isEmpty)
                                              ? 'Teacher'
                                              : (it['teacherName'] ?? '').toString().trim(),
                                          subject: subject,
                                        ),
                                      ),
                                    );

                                    if (mounted) await _load();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
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