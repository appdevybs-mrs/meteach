import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import 'learner_mail_thread_screen.dart';

class LearnerMailScreen extends StatefulWidget {
  const LearnerMailScreen({super.key});

  @override
  State<LearnerMailScreen> createState() => _LearnerMailScreenState();
}

class _LearnerMailScreenState extends State<LearnerMailScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Color get _navy => UiK.primaryBlue;
  Color get _orange => UiK.actionOrange;
  Color get _navyDark => UiK.primaryBlue.withOpacity(0.92);

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  String _short(String s, int max) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    if (max <= 1) return '…';
    return '${t.substring(0, max - 1)}…';
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _looksLikeThreadObject(Map<String, dynamic> m) {
    return m.containsKey('peerUid') ||
        m.containsKey('peerName') ||
        m.containsKey('subject') ||
        m.containsKey('updatedAt') ||
        m.containsKey('lastMessage') ||
        m.containsKey('unreadCount');
  }

  List<_TopicRow> _parse(dynamic v) {
    if (v is! Map) return [];
    final out = <_TopicRow>[];

    void addIfThreadObject(String threadId, Map obj) {
      final m = obj.map((kk, vvv) => MapEntry(kk.toString(), vvv));
      final row = _TopicRow.fromMap(threadId, m);
      if (row.deletedAtMs != null) return;
      if (row.threadId.trim().isEmpty) return;
      if (row.peerUid.trim().isEmpty && row.subject.trim().isEmpty) return;
      out.add(row);
    }

    v.forEach((k, vv) {
      if (k == null || vv == null) return;
      final key = k.toString();

      if (vv is Map) {
        final asMap = vv.map((kk, vvv) => MapEntry(kk.toString(), vvv));

        if (_looksLikeThreadObject(asMap)) {
          addIfThreadObject(key, vv);
          return;
        }

        asMap.forEach((innerK, innerV) {
          if (innerK.trim().isEmpty || innerV == null) return;
          if (innerV is Map) {
            final innerMap = innerV.map((kk, vvv) => MapEntry(kk.toString(), vvv));
            if (_looksLikeThreadObject(innerMap)) {
              addIfThreadObject(innerK, innerV);
            }
          }
        });
      }
    });

    final byId = <String, _TopicRow>{};
    for (final r in out) {
      final existing = byId[r.threadId];
      if (existing == null || r.updatedAtMs > existing.updatedAtMs) {
        byId[r.threadId] = r;
      }
    }

    final rows = byId.values.toList();
    rows.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return rows;
  }

  Future<void> _composeNewTopic() async {
    final meUid = _meUid.trim();
    if (meUid.isEmpty) {
      _snack('Not logged in.');
      return;
    }

    try {
      final picked = await showModalBottomSheet<_LearnerComposeResult>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        builder: (ctx) => _LearnerComposeSheet(db: _db, meUid: meUid),
      );

      if (picked == null) return;

      final subject = picked.subject.trim();
      if (subject.isEmpty) {
        _snack('Write subject.');
        return;
      }

      const placeholderLastMessage = '(No messages yet)';
      final now = _nowMs();

      Future<String> create1to1({
        required String toUid,
        required String toName,
        required String myName,
      }) async {
        final threadId = _db.child('mail_threads').push().key;
        if (threadId == null) throw Exception('Failed to create thread id.');

        final Map<String, dynamic> updates = {
          'mail_threads/$threadId/subject': subject,
          'mail_threads/$threadId/createdAt': now,
          'mail_threads/$threadId/updatedAt': now,
          'mail_threads/$threadId/lastMessage': placeholderLastMessage,
          'mail_threads/$threadId/participants/$meUid': true,
          'mail_threads/$threadId/participants/$toUid': true,

          'mail_index/$meUid/$threadId/subject': subject,
          'mail_index/$meUid/$threadId/updatedAt': now,
          'mail_index/$meUid/$threadId/lastMessage': placeholderLastMessage,
          'mail_index/$meUid/$threadId/unreadCount': 0,
          'mail_index/$meUid/$threadId/peerUid': toUid,
          'mail_index/$meUid/$threadId/peerName': toName,
          'mail_index/$meUid/$threadId/deletedAt': null,

          'mail_index/$toUid/$threadId/subject': subject,
          'mail_index/$toUid/$threadId/updatedAt': now,
          'mail_index/$toUid/$threadId/lastMessage': placeholderLastMessage,
          'mail_index/$toUid/$threadId/unreadCount': 1,
          'mail_index/$toUid/$threadId/peerUid': meUid,
          'mail_index/$toUid/$threadId/peerName': myName,
          'mail_index/$toUid/$threadId/deletedAt': null,
        };

        await _db.update(updates);
        return threadId;
      }

      final myName = picked.myName.trim().isEmpty ? 'Learner' : picked.myName.trim();

      if (picked.mode == _LearnerComposeMode.single) {
        if (picked.sendToAllAdmins == true) {
          final admins = picked.adminUids;
          if (admins.isEmpty) {
            _snack('No admins found.');
            return;
          }

          int sent = 0;
          for (final aUid in admins) {
            if (aUid.trim().isEmpty) continue;
            if (aUid.trim() == meUid) continue;

            await create1to1(
              toUid: aUid.trim(),
              toName: picked.adminNameByUid[aUid] ?? 'Admin',
              myName: myName,
            );
            sent++;
          }

          _snack('Created $sent admin topic(s) ✅');
          return;
        }

        final toUid = picked.receiverUid?.trim() ?? '';
        final toName = picked.receiverName?.trim() ?? '';
        if (toUid.isEmpty) {
          _snack('Pick a receiver.');
          return;
        }

        final threadId = await create1to1(
          toUid: toUid,
          toName: toName.isEmpty ? 'User' : toName,
          myName: myName,
        );

        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            settings: RouteSettings(name: '/mail/thread/$threadId'),
            builder: (_) => LearnerMailThreadScreen(
              threadId: threadId,
              peerUid: toUid,
              peerName: toName.isEmpty ? 'User' : toName,
              subject: subject,
            ),
          ),
        );
        return;
      }

      if (picked.mode == _LearnerComposeMode.classGroup) {
        final classId = picked.classId?.trim() ?? '';
        if (classId.isEmpty) {
          _snack('Pick a class.');
          return;
        }

        final classmates = picked.classmateUidsByClass[classId] ?? <String>[];
        final targets = classmates.where((u) => u.trim().isNotEmpty && u.trim() != meUid).toList();

        if (targets.isEmpty) {
          _snack('No classmates found in this class.');
          return;
        }

        int sent = 0;
        for (final cUid in targets) {
          await create1to1(
            toUid: cUid.trim(),
            toName: picked.nameByUid[cUid] ?? 'Classmate',
            myName: myName,
          );
          sent++;
        }

        _snack('Created $sent class topic(s) ✅');
        return;
      }
    } catch (e) {
      _snack('Compose failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _meUid;
    final ref = _db.child('mail_index/$uid');

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: IconThemeData(color: _navy),
        title: Text(
          'Mail',
          style: TextStyle(color: _navy, fontWeight: FontWeight.w900),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _navy.withOpacity(0.14)),
        ),
      ),
      floatingActionButton: uid.isEmpty
          ? null
          : FloatingActionButton.extended(
        onPressed: _composeNewTopic,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New message'),
      ),
      body: WatermarkBackground(
        child: uid.isEmpty
            ? Center(
          child: Text(
            'Not logged in.',
            style: TextStyle(fontWeight: FontWeight.w900, color: _navy),
          ),
        )
            : StreamBuilder<DatabaseEvent>(
          stream: ref.onValue,
          builder: (context, snap) {
            final rows = _parse(snap.data?.snapshot.value);

            if (rows.isEmpty) {
              return Center(
                child: Text(
                  'No mail yet.',
                  style: TextStyle(fontWeight: FontWeight.w900, color: _navyDark),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final r = rows[i];

                final threadId = r.threadId;
                final peerUid = r.peerUid;
                final peerName = r.peerName.trim().isEmpty ? 'User' : r.peerName.trim();
                final subject = r.subject;
                final lastMessage = r.lastMessage;
                final unread = r.unreadCount;
                final updatedAt = r.updatedAtMs;

                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LearnerMailThreadScreen(
                          threadId: threadId,
                          peerUid: peerUid,
                          peerName: peerName,
                          subject: subject,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _navy.withOpacity(0.14)),
                    ),
                    child: Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: _navy.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: _navy.withOpacity(0.14)),
                              ),
                              child: Icon(
                                Icons.mail_rounded,
                                color: _navy.withOpacity(0.92),
                              ),
                            ),
                            if (unread > 0)
                              Positioned(
                                right: -8,
                                top: -8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _orange,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    unread > 99 ? '99+' : '$unread',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      peerName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: _navy,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    updatedAt <= 0 ? '' : _fmt(updatedAt),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: _navy.withOpacity(0.55),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              if (subject.trim().isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _orange.withOpacity(0.14),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: _orange.withOpacity(0.24)),
                                  ),
                                  child: Text(
                                    _short(subject, 60),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: _navyDark,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Text(
                                lastMessage.trim().isEmpty ? '—' : _short(lastMessage, 90),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: _navy.withOpacity(0.62),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(Icons.chevron_right_rounded, color: _orange.withOpacity(0.85)),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

enum _LearnerComposeMode { single, classGroup }
enum _LearnerRecipientType { adminAll, admin, teacher, classmate }

class _LearnerRecipientRow {
  _LearnerRecipientRow({
    required this.uid,
    required this.name,
    required this.type,
  });

  final String uid;
  final String name;
  final _LearnerRecipientType type;
}

class _LearnerClassRow {
  _LearnerClassRow({required this.classId, required this.title});
  final String classId;
  final String title;
}

class _LearnerComposeResult {
  _LearnerComposeResult({
    required this.mode,
    required this.subject,
    required this.myName,
    required this.receiverUid,
    required this.receiverName,
    required this.sendToAllAdmins,
    required this.adminUids,
    required this.adminNameByUid,
    required this.classId,
    required this.classmateUidsByClass,
    required this.nameByUid,
  });

  final _LearnerComposeMode mode;
  final String subject;
  final String myName;

  final String? receiverUid;
  final String? receiverName;

  final bool sendToAllAdmins;
  final List<String> adminUids;
  final Map<String, String> adminNameByUid;

  final String? classId;
  final Map<String, List<String>> classmateUidsByClass;
  final Map<String, String> nameByUid;
}

class _LearnerComposeSheet extends StatefulWidget {
  const _LearnerComposeSheet({required this.db, required this.meUid});

  final DatabaseReference db;
  final String meUid;

  @override
  State<_LearnerComposeSheet> createState() => _LearnerComposeSheetState();
}

class _LearnerComposeSheetState extends State<_LearnerComposeSheet> {
  bool _loading = true;

  final _subjectC = TextEditingController();

  String _myName = 'Learner';

  _LearnerComposeMode _mode = _LearnerComposeMode.single;

  List<_LearnerRecipientRow> _recipients = [];
  _LearnerRecipientRow? _picked;

  List<_LearnerClassRow> _classes = [];
  _LearnerClassRow? _pickedClass;

  final Map<String, String> _nameByUid = {};
  final List<String> _adminUids = [];
  final Map<String, String> _adminNameByUid = {};
  final Map<String, List<String>> _classmateUidsByClass = {};

  @override
  void initState() {
    super.initState();
    _loadEverything();
  }

  @override
  void dispose() {
    _subjectC.dispose();
    super.dispose();
  }

  String _normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'admin' || s == 'adin' || s == 'admn' || s == 'adm' || s == 'administration' || s == 'administrator') {
      return 'admin';
    }
    if (s == 'teacher' || s == 'teach' || s == 'instructor' || s == 'prof') return 'teacher';
    if (s == 'learner' || s == 'lerner' || s == 'student' || s == 'pupil') return 'learner';
    return 'learner';
  }

  IconData _recipientIcon(_LearnerRecipientType t) {
    if (t == _LearnerRecipientType.adminAll || t == _LearnerRecipientType.admin) {
      return Icons.admin_panel_settings_rounded;
    }
    if (t == _LearnerRecipientType.teacher) {
      return Icons.school_rounded;
    }
    return Icons.person_rounded;
  }

  String _recipientSubtitle(_LearnerRecipientType t) {
    if (t == _LearnerRecipientType.adminAll) return 'School administration';
    if (t == _LearnerRecipientType.admin) return 'Administration';
    if (t == _LearnerRecipientType.teacher) return 'Teacher';
    return 'Classmate';
  }

  Color _recipientTint(_LearnerRecipientType t) {
    if (t == _LearnerRecipientType.adminAll || t == _LearnerRecipientType.admin) {
      return Colors.deepPurple;
    }
    if (t == _LearnerRecipientType.teacher) {
      return Colors.teal;
    }
    return Colors.blueGrey;
  }

  Future<void> _loadEverything() async {
    try {
      final meSnap = await widget.db.child('users/${widget.meUid}').get();
      if (meSnap.exists && meSnap.value is Map) {
        final m = (meSnap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
        final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
        final email = (m['email'] ?? '').toString().trim();
        final full = ('$fn $ln').trim();
        _myName = full.isNotEmpty ? full : (email.isNotEmpty ? email : 'Learner');
      }

      final usersSnap = await widget.db.child('users').get();
      final usersVal = usersSnap.value;

      if (usersVal is Map) {
        usersVal.forEach((uid, vv) {
          if (uid == null || vv == null || vv is! Map) return;
          final m = vv.map((k, v) => MapEntry(k.toString(), v));
          final role = _normalizeRole(m['role']);

          final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
          final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
          final email = (m['email'] ?? '').toString().trim();
          final full = ('$fn $ln').trim();
          final display = full.isNotEmpty ? full : (email.isNotEmpty ? email : uid.toString());

          final u = uid.toString();
          _nameByUid[u] = display;

          if (role == 'admin') {
            _adminUids.add(u);
            _adminNameByUid[u] = display;
          }
        });
      }

      final classesSnap = await widget.db.child('classes').get();
      final classesVal = classesSnap.value;

      final teachers = <String>{};
      final classmates = <String>{};
      final myClasses = <_LearnerClassRow>[];

      if (classesVal is Map) {
        classesVal.forEach((classId, classVal) {
          if (classId == null || classVal == null || classVal is! Map) return;
          final c = classVal.map((k, v) => MapEntry(k.toString(), v));

          final learners = c['learners'];
          bool imIn = false;
          if (learners is Map) {
            imIn = learners.containsKey(widget.meUid) || learners[widget.meUid] == true;
          }
          if (!imIn) return;

          final title = (c['course_title'] ?? c['courseTitle'] ?? c['name'] ?? classId).toString().trim();
          myClasses.add(
            _LearnerClassRow(
              classId: classId.toString(),
              title: title.isEmpty ? classId.toString() : title,
            ),
          );

          final cur = c['instructor_current'];
          if (cur is Map) {
            final curM = cur.map((k, v) => MapEntry(k.toString(), v));
            final tUid = (curM['uid'] ?? '').toString().trim();
            if (tUid.isNotEmpty && tUid != widget.meUid) teachers.add(tUid);
          }

          final classmateList = <String>[];
          if (learners is Map) {
            learners.forEach((u, _) {
              final s = u.toString().trim();
              if (s.isEmpty) return;
              if (s == widget.meUid) return;
              classmates.add(s);
              classmateList.add(s);
            });
          }
          _classmateUidsByClass[classId.toString()] = classmateList;
        });
      }

      myClasses.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

      final all = <_LearnerRecipientRow>[];

      all.add(
        _LearnerRecipientRow(
          uid: '__ADMINS__',
          name: 'Administration (all)',
          type: _LearnerRecipientType.adminAll,
        ),
      );

      for (final tUid in teachers) {
        all.add(
          _LearnerRecipientRow(
            uid: tUid,
            name: _nameByUid[tUid] ?? 'Teacher',
            type: _LearnerRecipientType.teacher,
          ),
        );
      }

      for (final cUid in classmates) {
        all.add(
          _LearnerRecipientRow(
            uid: cUid,
            name: _nameByUid[cUid] ?? 'Classmate',
            type: _LearnerRecipientType.classmate,
          ),
        );
      }

      int rank(_LearnerRecipientType t) {
        if (t == _LearnerRecipientType.adminAll) return 0;
        if (t == _LearnerRecipientType.teacher) return 1;
        if (t == _LearnerRecipientType.admin) return 2;
        return 3;
      }

      all.sort((a, b) {
        final r = rank(a.type).compareTo(rank(b.type));
        if (r != 0) return r;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _classes = myClasses;
        _pickedClass = myClasses.isNotEmpty ? myClasses.first : null;
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
    final subject = _subjectC.text.trim();
    if (subject.isEmpty) return;

    if (_mode == _LearnerComposeMode.single) {
      final r = _picked;
      if (r == null) return;

      if (r.type == _LearnerRecipientType.adminAll) {
        Navigator.pop(
          context,
          _LearnerComposeResult(
            mode: _LearnerComposeMode.single,
            subject: subject,
            myName: _myName,
            receiverUid: null,
            receiverName: null,
            sendToAllAdmins: true,
            adminUids: _adminUids,
            adminNameByUid: _adminNameByUid,
            classId: null,
            classmateUidsByClass: _classmateUidsByClass,
            nameByUid: _nameByUid,
          ),
        );
        return;
      }

      Navigator.pop(
        context,
        _LearnerComposeResult(
          mode: _LearnerComposeMode.single,
          subject: subject,
          myName: _myName,
          receiverUid: r.uid,
          receiverName: r.name,
          sendToAllAdmins: false,
          adminUids: _adminUids,
          adminNameByUid: _adminNameByUid,
          classId: null,
          classmateUidsByClass: _classmateUidsByClass,
          nameByUid: _nameByUid,
        ),
      );
      return;
    }

    final c = _pickedClass;
    if (c == null) return;

    Navigator.pop(
      context,
      _LearnerComposeResult(
        mode: _LearnerComposeMode.classGroup,
        subject: subject,
        myName: _myName,
        receiverUid: null,
        receiverName: null,
        sendToAllAdmins: false,
        adminUids: _adminUids,
        adminNameByUid: _adminNameByUid,
        classId: c.classId,
        classmateUidsByClass: _classmateUidsByClass,
        nameByUid: _nameByUid,
      ),
    );
  }

  Widget _buildRecipientItem(_LearnerRecipientRow r) {
    final tint = _recipientTint(r.type);
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: tint.withOpacity(0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tint.withOpacity(0.18)),
          ),
          child: Icon(_recipientIcon(r.type), color: tint.withOpacity(0.95), size: 19),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Text(
                _recipientSubtitle(r.type),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.black.withOpacity(0.58),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildClassItem(_LearnerClassRow c) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.indigo.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.indigo.withOpacity(0.16)),
          ),
          child: Icon(
            Icons.groups_rounded,
            color: Colors.indigo.withOpacity(0.95),
            size: 19,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Text(
                'Whole class',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.black.withOpacity(0.58),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = media.viewInsets.bottom + media.padding.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              const Text(
                'New message',
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
                      Text('Loading...'),
                    ],
                  ),
                )
              else ...[
                SegmentedButton<_LearnerComposeMode>(
                  segments: const [
                    ButtonSegment(
                      value: _LearnerComposeMode.single,
                      icon: Icon(Icons.person_rounded),
                      label: Text('One person'),
                    ),
                    ButtonSegment(
                      value: _LearnerComposeMode.classGroup,
                      icon: Icon(Icons.groups_rounded),
                      label: Text('Whole class'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                const SizedBox(height: 12),
                if (_mode == _LearnerComposeMode.single)
                  DropdownButtonFormField<_LearnerRecipientRow>(
                    value: _picked,
                    isExpanded: true,
                    items: _recipients.map((r) {
                      return DropdownMenuItem<_LearnerRecipientRow>(
                        value: r,
                        child: _buildRecipientItem(r),
                      );
                    }).toList(),
                    selectedItemBuilder: (_) {
                      return _recipients.map((r) {
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${r.name} • ${_recipientSubtitle(r.type)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        );
                      }).toList();
                    },
                    onChanged: (v) => setState(() => _picked = v),
                    decoration: const InputDecoration(
                      labelText: 'Send to',
                      border: OutlineInputBorder(),
                    ),
                  )
                else
                  DropdownButtonFormField<_LearnerClassRow>(
                    value: _pickedClass,
                    isExpanded: true,
                    items: _classes.map((c) {
                      return DropdownMenuItem<_LearnerClassRow>(
                        value: c,
                        child: _buildClassItem(c),
                      );
                    }).toList(),
                    selectedItemBuilder: (_) {
                      return _classes.map((c) {
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${c.title} • Whole class',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        );
                      }).toList();
                    },
                    onChanged: (v) => setState(() => _pickedClass = v),
                    decoration: const InputDecoration(
                      labelText: 'Class',
                      border: OutlineInputBorder(),
                    ),
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _subjectC,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Topic / Subject',
                    hintText: 'Example: Homework question',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.send_rounded),
                    label: Text(
                      _mode == _LearnerComposeMode.classGroup ? 'Create class topics' : 'Create topic',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
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