import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'dart:async';

import 'teacher_mail_thread_screen.dart';

class TeacherMailScreen extends StatefulWidget {
  const TeacherMailScreen({super.key});

  @override
  State<TeacherMailScreen> createState() => _TeacherMailScreenState();
}

class _TeacherMailScreenState extends State<TeacherMailScreen> {
  final _db = FirebaseDatabase.instance;
  final _searchC = TextEditingController();
  Timer? _searchDebounce;
  String _q = '';

  String get _meUid => FirebaseAuth.instance.currentUser!.uid;

  DatabaseReference get _indexRef => _db.ref('mail_index/$_meUid');

  late final Stream<DatabaseEvent> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _indexRef.orderByChild('updatedAt').onValue.asBroadcastStream();
  }
  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchC.dispose();
    super.dispose();
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


  List<_TopicRow> _applyFilter(List<_TopicRow> rows) {
    final q = _q.trim();
    if (q.isEmpty) return rows;

    bool hit(_TopicRow r) {
      final subject = r.subject.toLowerCase();
      final last = r.lastMessage.toLowerCase();
      final peer = r.peerName.toLowerCase();
      return subject.contains(q) || last.contains(q) || peer.contains(q);
    }

    return rows.where(hit).toList();
  }

  Map<String, List<_TopicRow>> _groupByPeer(List<_TopicRow> rows) {
    // key by peerUid (stronger than name)
    final Map<String, List<_TopicRow>> grouped = {};
    for (final r in rows) {
      final key = r.peerUid.isNotEmpty ? r.peerUid : r.peerName;
      grouped.putIfAbsent(key, () => []).add(r);
    }

    // sort threads inside each group by updatedAt desc
    for (final k in grouped.keys) {
      grouped[k]!.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    }

    return grouped;
  }

  int _sumUnread(List<_TopicRow> rows) {
    int s = 0;
    for (final r in rows) {
      s += r.unreadCount;
    }
    return s;
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

  Future<void> _tryOpenHomeworkReview(_TopicRow r) async {
    try {
      final tSnap = await _db.ref('mail_threads/${r.threadId}').get();
      if (!tSnap.exists || tSnap.value is! Map) {
        _snack('Thread not found.');
        return;
      }

      final t = Map<String, dynamic>.from(tSnap.value as Map);
      final type = (t['type'] ?? '').toString().trim();

      if (type != 'homework') {
        _snack('No Homework Found.');
        return;
      }

      final hwRefPath = (t['homeworkRef'] ?? '').toString().trim();
      if (hwRefPath.isEmpty) {
        _snack('Homework link missing (homeworkRef).');
        return;
      }

      final learnerUid = (t['learnerUid'] ?? '').toString().trim();
      final teacherUid = (t['teacherUid'] ?? '').toString().trim();

      await _openHomeworkReviewDialog(
        threadId: r.threadId,
        hwRefPath: hwRefPath,
        learnerUid: learnerUid,
        teacherUid: teacherUid,
        subject: r.subject,
      );
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _openHomeworkReviewDialog({
    required String threadId,
    required String hwRefPath,
    required String learnerUid,
    required String teacherUid,
    required String subject,
  }) async {
    // load current values (optional but nice)
    int score = 100;
    String note = '';
    String status = 'approved'; // approved | needs_work

    try {
      final hwSnap = await _db.ref(hwRefPath).get();
      if (hwSnap.exists && hwSnap.value is Map) {
        final hw = Map<String, dynamic>.from(hwSnap.value as Map);
        final s = hw['reviewScore'];
        if (s is num) score = s.toInt();
        note = (hw['reviewNote'] ?? '').toString();
        final st = (hw['reviewStatus'] ?? '').toString().trim();
        if (st == 'needs_work' || st == 'approved') status = st;
      }
    } catch (_) {}

    final scoreC = TextEditingController(text: score.toString());
    final noteC = TextEditingController(text: note);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Evaluate homework'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      subject.isEmpty ? 'Homework' : subject,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: scoreC,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Score (0 - 100)',
                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 12),

                    TextField(
                      controller: noteC,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Comment',
                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 12),

                    RadioListTile<String>(
                      value: 'approved',
                      groupValue: status,
                      onChanged: (v) => setLocal(() => status = v ?? 'approved'),
                      title: const Text('Approved ✅'),
                    ),
                    RadioListTile<String>(
                      value: 'needs_work',
                      groupValue: status,
                      onChanged: (v) => setLocal(() => status = v ?? 'needs_work'),
                      title: const Text('Needs work 🔁'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;

    // parse score safely
    int parsedScore = int.tryParse(scoreC.text.trim()) ?? 0;
    if (parsedScore < 0) parsedScore = 0;
    if (parsedScore > 100) parsedScore = 100;

    final noteText = noteC.text.trim();
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      // 1) update homework node
      await _db.ref(hwRefPath).update({
        'reviewedAt': now,
        'reviewStatus': status,
        'reviewScore': parsedScore,
        'reviewNote': noteText,
      });

      // 2) update thread + both indexes preview (so inbox shows review)
      final preview = status == 'needs_work'
          ? '🔁 Needs work • $parsedScore/100'
          : '✅ Approved • $parsedScore/100';

      final Map<String, dynamic> updates = {
        'mail_threads/$threadId/updatedAt': now,
        'mail_threads/$threadId/lastMessage': preview,

        if (teacherUid.isNotEmpty) 'mail_index/$teacherUid/$threadId/updatedAt': now,
        if (teacherUid.isNotEmpty) 'mail_index/$teacherUid/$threadId/lastMessage': preview,

        if (learnerUid.isNotEmpty) 'mail_index/$learnerUid/$threadId/updatedAt': now,
        if (learnerUid.isNotEmpty) 'mail_index/$learnerUid/$threadId/lastMessage': preview,
      };

      await _db.ref().update(updates);

      _snack('Saved ✅');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }



  // -----------------------------------------
  // Compose: admin OR learner OR whole class
  // -----------------------------------------
  Future<void> _composeNewTopic() async {
    try {
      final picked = await showModalBottomSheet<_ComposeResult>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => _ComposeSheet(db: _db, meUid: _meUid),
      );

      if (picked == null) return;

      final subject = picked.subject.trim();
      final text = picked.firstMessage.trim();
      final now = DateTime.now().millisecondsSinceEpoch;

      if (subject.isEmpty || text.isEmpty) {
        _snack('Write subject and message.');
        return;
      }

      // 1) Send to ONE person (admin or learner)
      if (picked.mode == _ComposeMode.single && picked.receiverUid != null) {
        final toUid = picked.receiverUid!;
        final toName = picked.receiverName ?? '';

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

        // thread meta
        await _db.ref('mail_threads/$threadId').set({
          'subject': subject,
          'createdAt': now,
          'updatedAt': now,
          'lastMessage': text,
        });

        // first message
        await _db.ref('mail_threads/$threadId/messages/$msgId').set({
          'id': msgId,
          'text': text,
          'senderUid': _meUid,
          'senderName': picked.teacherName,
          'createdAt': now,
        });

        // teacher index (sender) unread 0
        await _db.ref('mail_index/$_meUid/$threadId').set({
          'subject': subject,
          'updatedAt': now,
          'lastMessage': text,
          'unreadCount': 0,
          'peerUid': toUid,
          'peerName': toName,
          'deletedAt': null,
        });

        // receiver index unread 1
        await _db.ref('mail_index/$toUid/$threadId').set({
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
              peerUid: toUid,
              peerName: toName.isEmpty ? 'User' : toName,
              subject: subject,
            ),
          ),
        );

        return;
      }

      // 2) Send to WHOLE CLASS: create a thread per learner
      if (picked.mode == _ComposeMode.classGroup) {
        final classId = picked.classId;
        if (classId == null || classId.trim().isEmpty) {
          _snack('No class selected.');
          return;
        }

        // load class learners
        final cSnap = await _db.ref('classes/$classId/learners').get();
        final cVal = cSnap.value;

        if (cVal is! Map || cVal.isEmpty) {
          _snack('This class has no learners.');
          return;
        }

        // optional: load users once to display names better
        final usersSnap = await _db.ref('users').get();
        final usersVal = usersSnap.value;
        final nameByUid = <String, String>{};

        if (usersVal is Map) {
          usersVal.forEach((uid, vv) {
            if (uid == null || vv == null || vv is! Map) return;
            final m = vv.map((k, v) => MapEntry(k.toString(), v));
            final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
            final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
            final email = (m['email'] ?? '').toString().trim();
            final n = ('$fn $ln').trim();
            nameByUid[uid.toString()] = n.isNotEmpty ? n : (email.isNotEmpty ? email : uid.toString());
          });
        }

        int sent = 0;

        for (final entry in cVal.entries) {
          final learnerUid = entry.key.toString().trim();
          if (learnerUid.isEmpty) continue;

          // avoid sending to self if teacher accidentally appears
          if (learnerUid == _meUid) continue;

          final learnerName = nameByUid[learnerUid] ??
              (entry.value is Map ? ((entry.value as Map)['name'] ?? '').toString() : '') ??
              'Learner';

          final threadId = _db.ref('mail_threads').push().key;
          if (threadId == null) continue;

          final msgId = _db.ref('mail_threads/$threadId/messages').push().key;
          if (msgId == null) continue;

          // thread meta
          await _db.ref('mail_threads/$threadId').set({
            'subject': '[$classId] $subject', // keeps it recognizable in inbox
            'createdAt': now,
            'updatedAt': now,
            'lastMessage': text,
          });

          // first message
          await _db.ref('mail_threads/$threadId/messages/$msgId').set({
            'id': msgId,
            'text': text,
            'senderUid': _meUid,
            'senderName': picked.teacherName,
            'createdAt': now,
          });

          // teacher index (sender)
          await _db.ref('mail_index/$_meUid/$threadId').set({
            'subject': '[$classId] $subject',
            'updatedAt': now,
            'lastMessage': text,
            'unreadCount': 0,
            'peerUid': learnerUid,
            'peerName': learnerName,
            'deletedAt': null,
          });

          // learner index (receiver)
          await _db.ref('mail_index/$learnerUid/$threadId').set({
            'subject': '[$classId] $subject',
            'updatedAt': now,
            'lastMessage': text,
            'unreadCount': 1,
            'peerUid': _meUid,
            'peerName': picked.teacherName,
            'deletedAt': null,
          });

          sent++;
        }

        _snack('Sent to $sent learners ✅');
        return;
      }
    } catch (e) {
      _snack('Compose failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mail'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              controller: _searchC,
              decoration: InputDecoration(
                hintText: 'Search topic / last message / person…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: (_q.isEmpty)
                    ? null
                    : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchC.clear();
                    setState(() => _q = '');
                  },
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) {
                _searchDebounce?.cancel();
                _searchDebounce = Timer(const Duration(milliseconds: 200), () {
                  if (!mounted) return;
                  setState(() => _q = v.trim().toLowerCase());
                });
              },
            ),
          ),
        ),
      ),
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

          final filtered = _applyFilter(rows);
          if (filtered.isEmpty) {
            return const Center(child: Text('No results.'));
          }

          final grouped = _groupByPeer(filtered);
          final groupKeys = grouped.keys.toList();

          // Sort groups by most recent thread inside group
          groupKeys.sort((a, b) {
            final aTop = grouped[a]!.isEmpty ? 0 : grouped[a]!.first.updatedAtMs;
            final bTop = grouped[b]!.isEmpty ? 0 : grouped[b]!.first.updatedAtMs;
            return bTop.compareTo(aTop);
          });

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: groupKeys.length,
            itemBuilder: (_, gi) {
              final k = groupKeys[gi];
              final items = grouped[k]!;
              final displayName = (items.first.peerName.isEmpty) ? 'User' : items.first.peerName;
              final unreadTotal = _sumUnread(items);

              return Card(
                elevation: 0,
                color: Colors.black.withOpacity(0.03),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ExpansionTile(
                  initiallyExpanded: true,
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayName,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unreadTotal > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            unreadTotal > 99 ? '99+' : '$unreadTotal',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  children: [
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final r = items[i];

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
                            '${r.lastMessage}',
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
                          onLongPress: () async {
                            _snack('Long press ✅ ${r.threadId}');
                            await _tryOpenHomeworkReview(r);
                          },
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                settings: RouteSettings(name: '/mail/thread/${r.threadId}'),
                                builder: (_) => TeacherMailThreadScreen(
                                  threadId: r.threadId,
                                  peerUid: r.peerUid,
                                  peerName: r.peerName.isEmpty ? 'User' : r.peerName,
                                  subject: r.subject,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
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
  bool _loading = true;

  final _subjectC = TextEditingController();
  final _messageC = TextEditingController();

  String _teacherName = 'Teacher';

  List<_RecipientRow> _recipients = [];
  _RecipientRow? _picked;

  // for "whole class"
  List<_ClassRow> _classes = [];
  _ClassRow? _pickedClass;

  _ComposeMode _mode = _ComposeMode.single;

  @override
  void initState() {
    super.initState();
    _loadEverything();
  }

  @override
  void dispose() {
    _subjectC.dispose();
    _messageC.dispose();
    super.dispose();
  }

  Future<void> _loadEverything() async {
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

      // load users (names + admins)
      final usersSnap = await widget.db.ref('users').get();
      final usersVal = usersSnap.value;

      final nameByUid = <String, String>{};
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
          nameByUid[u] = display;

          if (role == 'admin') {
            admins.add(_RecipientRow(uid: u, name: display, type: _RecipientType.admin));
          }
        });
      }

      // classes where I'm instructor_current.uid
      final classesSnap = await widget.db.ref('classes').get();
      final classesVal = classesSnap.value;

      final myLearners = <String>{};
      final myClasses = <_ClassRow>[];

      if (classesVal is Map) {
        classesVal.forEach((classId, classVal) {
          if (classId == null || classVal == null || classVal is! Map) return;
          final c = classVal.map((k, v) => MapEntry(k.toString(), v));

          final cur = c['instructor_current'];
          String tUid = '';
          if (cur is Map) {
            final curM = cur.map((k, v) => MapEntry(k.toString(), v));
            tUid = (curM['uid'] ?? '').toString().trim();
          }
          if (tUid != widget.meUid) return;

          final title = (c['course_title'] ?? c['courseTitle'] ?? c['name'] ?? classId).toString().trim();
          myClasses.add(_ClassRow(classId: classId.toString(), title: title.isEmpty ? classId.toString() : title));

          final learners = c['learners'];
          if (learners is Map) {
            learners.forEach((uid, _) {
              final u = uid.toString().trim();
              if (u.isEmpty) return;
              if (u == widget.meUid) return;
              myLearners.add(u);
            });
          }
        });
      }

      final learnerRecipients = myLearners.map((u) {
        final name = nameByUid[u] ?? 'Learner';
        return _RecipientRow(uid: u, name: name, type: _RecipientType.learner);
      }).toList();

      // merge recipients (admins + my learners)
      final all = <_RecipientRow>[
        ...admins,
        ...learnerRecipients,
      ];

      int rank(_RecipientType t) => t == _RecipientType.admin ? 0 : 1;

      all.sort((a, b) {
        final r = rank(a.type).compareTo(rank(b.type));
        if (r != 0) return r;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      myClasses.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _recipients = all;
        _picked = all.isNotEmpty ? all.first : null;

        _classes = myClasses;
        _pickedClass = myClasses.isNotEmpty ? myClasses.first : null;

        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _submit() {
    final subject = _subjectC.text.trim();
    final msg = _messageC.text.trim();
    if (subject.isEmpty || msg.isEmpty) return;

    if (_mode == _ComposeMode.single) {
      final r = _picked;
      if (r == null) return;

      Navigator.pop(
        context,
        _ComposeResult(
          mode: _ComposeMode.single,
          teacherName: _teacherName,
          subject: subject,
          firstMessage: msg,
          receiverUid: r.uid,
          receiverName: r.name,
          classId: null,
        ),
      );
      return;
    }

    // class group
    final c = _pickedClass;
    if (c == null) return;

    Navigator.pop(
      context,
      _ComposeResult(
        mode: _ComposeMode.classGroup,
        teacherName: _teacherName,
        subject: subject,
        firstMessage: msg,
        receiverUid: null,
        receiverName: null,
        classId: c.classId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    String prefixFor(_RecipientType t) {
      if (t == _RecipientType.admin) return '🛡️ ';
      return '🎓 ';
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            const Text('New topic', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 12),

            if (_loading)
              const Padding(
                padding: EdgeInsets.all(18),
                child: Row(
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Loading...'),
                  ],
                ),
              )
            else ...[
              // Mode selector
              SegmentedButton<_ComposeMode>(
                segments: const [
                  ButtonSegment(value: _ComposeMode.single, label: Text('Single')),
                  ButtonSegment(value: _ComposeMode.classGroup, label: Text('Whole class')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),

              const SizedBox(height: 12),

              if (_mode == _ComposeMode.single)
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
                )
              else
                DropdownButtonFormField<_ClassRow>(
                  value: _pickedClass,
                  items: _classes.map((c) {
                    return DropdownMenuItem<_ClassRow>(
                      value: c,
                      child: Text('👥 ${c.title} (${c.classId})'),
                    );
                  }).toList(),
                  onChanged: (v) => setState(() => _pickedClass = v),
                  decoration: const InputDecoration(
                    labelText: 'Class',
                    border: OutlineInputBorder(),
                  ),
                ),

              const SizedBox(height: 12),

              TextFormField(
                controller: _subjectC,
                textInputAction: TextInputAction.next,
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
                  hintText: 'Write your message…',
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(_mode == _ComposeMode.classGroup ? 'Send to class' : 'Create topic'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _ComposeMode { single, classGroup }

enum _RecipientType { admin, learner }

class _RecipientRow {
  _RecipientRow({required this.uid, required this.name, required this.type});
  final String uid;
  final String name;
  final _RecipientType type;
}

class _ClassRow {
  _ClassRow({required this.classId, required this.title});
  final String classId;
  final String title;
}

class _ComposeResult {
  _ComposeResult({
    required this.mode,
    required this.teacherName,
    required this.subject,
    required this.firstMessage,
    required this.receiverUid,
    required this.receiverName,
    required this.classId,
  });

  final _ComposeMode mode;

  final String teacherName;
  final String subject;
  final String firstMessage;

  // single
  final String? receiverUid;
  final String? receiverName;

  // class group
  final String? classId;
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
