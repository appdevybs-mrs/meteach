import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'learner_mail_thread_screen.dart';

// ============================
// TOP-LEVEL enums (Dart rule)
// ============================
enum _MailFilter { all, unread, teachers, admins, classmates }
enum _MailSort { recent, unreadFirst, subjectAZ, personAZ }

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

  // -------------------------
  // Search + filter + sort
  // -------------------------
  final _searchC = TextEditingController();
  Timer? _searchDebounce;
  String _q = '';

  _MailFilter _filter = _MailFilter.all;
  _MailSort _sort = _MailSort.recent;

  // -------------------------
  // Name cache (uid -> "First Last")
  // -------------------------
  final Map<String, String> _nameCache = {};

  Future<String> _fetchDisplayName(String uid) async {
    final snap = await _db.ref('users/$uid').get();
    if (!snap.exists || snap.value is! Map) return '';

    final m = Map<String, dynamic>.from(snap.value as Map);
    final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
    final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
    return ('$first $last').trim();
  }

  Future<void> _ensureNameCached(String uid, {String fallback = ''}) async {
    if (uid.isEmpty) return;
    if (_nameCache.containsKey(uid)) return;

    final name = await _fetchDisplayName(uid);
    if (!mounted) return;

    setState(() {
      _nameCache[uid] = name.isNotEmpty ? name : fallback;
    });
  }

  String _displayPeerName(_TopicRow r) {
    final cached = (_nameCache[r.peerUid] ?? '').trim();
    if (cached.isNotEmpty) return cached;

    final raw = r.peerName.trim();
    // if peerName is already a real name (not email), use it
    if (raw.isNotEmpty && !raw.contains('@')) return raw;

    return 'Staff';
  }

  // -------------------------
  // Role cache for filtering
  // admin | teacher | learner | ''
  // -------------------------
  final Map<String, String> _roleCache = {};

  Future<String> _fetchRole(String uid) async {
    final snap = await _db.ref('users/$uid/role').get();
    return snap.value?.toString().toLowerCase().trim() ?? '';
  }

  Future<void> _ensureRoleCached(String uid) async {
    if (uid.isEmpty) return;
    if (_roleCache.containsKey(uid)) return;

    final role = await _fetchRole(uid);
    if (!mounted) return;

    setState(() => _roleCache[uid] = role);
  }

  _RecipientType _peerTypeFromUid(String uid) {
    final r = (_roleCache[uid] ?? '').toLowerCase().trim();
    if (r == 'admin') return _RecipientType.admin;
    if (r == 'teacher') return _RecipientType.teacher;
    if (r == 'learner') return _RecipientType.learner;

    // keep old behavior: unknown treated as staff/teacher
    return _RecipientType.teacher;
  }

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
  // Search / Filter / Sort (local-only)
  // -------------------------
  List<_TopicRow> _applySearch(List<_TopicRow> rows) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return rows;

    bool hit(_TopicRow r) {
      final subject = r.subject.toLowerCase();
      final last = r.lastMessage.toLowerCase();
      final peer = _displayPeerName(r).toLowerCase();
      return subject.contains(q) || last.contains(q) || peer.contains(q);
    }

    return rows.where(hit).toList();
  }

  List<_TopicRow> _applyFilter(List<_TopicRow> rows) {
    if (_filter == _MailFilter.all) return rows;

    return rows.where((r) {
      if (_filter == _MailFilter.unread) return r.unreadCount > 0;

      final t = _peerTypeFromUid(r.peerUid);
      if (_filter == _MailFilter.teachers) return t == _RecipientType.teacher;
      if (_filter == _MailFilter.admins) return t == _RecipientType.admin;
      if (_filter == _MailFilter.classmates) return t == _RecipientType.learner;

      return true;
    }).toList();
  }

  List<_TopicRow> _applySort(List<_TopicRow> rows) {
    final out = List<_TopicRow>.from(rows);

    switch (_sort) {
      case _MailSort.recent:
        out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
        break;

      case _MailSort.unreadFirst:
        out.sort((a, b) {
          final u = b.unreadCount.compareTo(a.unreadCount);
          if (u != 0) return u;
          return b.updatedAtMs.compareTo(a.updatedAtMs);
        });
        break;

      case _MailSort.subjectAZ:
        out.sort((a, b) {
          final aa = a.subject.trim().toLowerCase();
          final bb = b.subject.trim().toLowerCase();
          return aa.compareTo(bb);
        });
        break;

      case _MailSort.personAZ:
        out.sort((a, b) {
          final aa = _displayPeerName(a).trim().toLowerCase();
          final bb = _displayPeerName(b).trim().toLowerCase();
          return aa.compareTo(bb);
        });
        break;
    }

    return out;
  }

  String _sortLabel(_MailSort s) {
    switch (s) {
      case _MailSort.recent:
        return 'Recent';
      case _MailSort.unreadFirst:
        return 'Unread first';
      case _MailSort.subjectAZ:
        return 'Subject A–Z';
      case _MailSort.personAZ:
        return 'Person A–Z';
    }
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
  // create topic only (no first message)
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

      final subject = picked.subject.trim();
      const lastMessage = '';

      // 1) thread meta
      await _db.ref('mail_threads/$threadId').set({
        'subject': subject,
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': lastMessage,
      });

      // 2) index (sender) unread 0
      await _db.ref('mail_index/$_meUid/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': lastMessage,
        'unreadCount': 0,
        'peerUid': picked.receiverUid,
        'peerName': picked.receiverName,
        'deletedAt': null,
      });

      // 3) index (receiver) unread 0 (because no message was sent yet)
      await _db.ref('mail_index/${picked.receiverUid}/$threadId').set({
        'subject': subject,
        'updatedAt': now,
        'lastMessage': lastMessage,
        'unreadCount': 0,
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
      appBar: AppBar(
        title: const Text('Mail'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(
              children: [
                TextField(
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
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Wrap(
                          spacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('All'),
                              selected: _filter == _MailFilter.all,
                              onSelected: (_) => setState(() => _filter = _MailFilter.all),
                            ),
                            ChoiceChip(
                              label: const Text('Unread'),
                              selected: _filter == _MailFilter.unread,
                              onSelected: (_) => setState(() => _filter = _MailFilter.unread),
                            ),
                            ChoiceChip(
                              label: const Text('Teachers'),
                              selected: _filter == _MailFilter.teachers,
                              onSelected: (_) => setState(() => _filter = _MailFilter.teachers),
                            ),
                            ChoiceChip(
                              label: const Text('Admins'),
                              selected: _filter == _MailFilter.admins,
                              onSelected: (_) => setState(() => _filter = _MailFilter.admins),
                            ),
                            ChoiceChip(
                              label: const Text('Classmates'),
                              selected: _filter == _MailFilter.classmates,
                              onSelected: (_) => setState(() => _filter = _MailFilter.classmates),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<_MailSort>(
                      tooltip: 'Sort',
                      onSelected: (v) => setState(() => _sort = v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: _MailSort.recent, child: Text('Recent')),
                        PopupMenuItem(value: _MailSort.unreadFirst, child: Text('Unread first')),
                        PopupMenuItem(value: _MailSort.subjectAZ, child: Text('Subject A–Z')),
                        PopupMenuItem(value: _MailSort.personAZ, child: Text('Person A–Z')),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.sort, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              _sortLabel(_sort),
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _composeNewMail,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _stream,
        builder: (_, snap) {
          final base = _parse(snap.data?.snapshot.value);

          if (base.isEmpty) {
            return const Center(child: Text('No mail yet.'));
          }

          // Cache names + roles without blocking UI
          for (final r in base) {
            unawaited(_ensureNameCached(
              r.peerUid,
              fallback: (r.peerName.isNotEmpty ? r.peerName : 'Staff'),
            ));
            unawaited(_ensureRoleCached(r.peerUid));
          }

          var rows = base;
          rows = _applySearch(rows);
          rows = _applyFilter(rows);
          rows = _applySort(rows);

          if (rows.isEmpty) {
            return Center(
              child: Text(
                _q.trim().isEmpty ? 'No results.' : 'No results for "${_q.trim()}".',
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final r = rows[i];

              final peer = _displayPeerName(r);
              final last = r.lastMessage.trim();
              final subtitleText = last.isEmpty ? peer : '$peer • $last';

              IconData leadingIcon;
              final t = _peerTypeFromUid(r.peerUid);
              if (t == _RecipientType.admin) {
                leadingIcon = Icons.shield_rounded;
              } else if (t == _RecipientType.learner) {
                leadingIcon = Icons.school_rounded;
              } else {
                leadingIcon = Icons.person_rounded;
              }

              return ListTile(
                tileColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                leading: CircleAvatar(child: Icon(leadingIcon)),
                title: Text(
                  r.subject.isEmpty ? '(No topic)' : r.subject,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  subtitleText,
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
      final userRoleByUid = <String, String>{};
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
          userRoleByUid[u] = role;

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

      // Teachers list:
      // - from classes
      // - plus any user with role == teacher (optional safety)
      final teacherRoleUids = userRoleByUid.entries
          .where((e) => e.value == 'teacher')
          .map((e) => e.key)
          .toSet();

      final allTeacherUids = <String>{
        ...teacherUids,
        ...teacherRoleUids,
      }..remove(widget.meUid);

      final teachers = allTeacherUids.map((tUid) {
        final name = userNameByUid[tUid] ?? 'Teacher';
        return _RecipientRow(uid: tUid, name: name, type: _RecipientType.teacher);
      }).toList();

      final classmates = classmateUids.map((u) {
        final name = userNameByUid[u] ?? 'Learner';
        return _RecipientRow(uid: u, name: name, type: _RecipientType.learner);
      }).toList();

      // ---------- merge + unique by uid ----------
      final byUid = <String, _RecipientRow>{};
      for (final r in [...teachers, ...admins, ...classmates]) {
        byUid[r.uid] = r;
      }
      final all = byUid.values.toList();

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
    if (subject.isEmpty) return;

    Navigator.pop(
      context,
      _RecipientPickResult(
        receiverUid: r.uid,
        receiverName: r.name,
        subject: subject,
        senderName: _senderName,
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
  });

  final String receiverUid;
  final String receiverName;
  final String subject;
  final String senderName;
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
