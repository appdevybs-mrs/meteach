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

enum _InboxTabRole { learners, teachers, admin }

class _TeacherMailScreenState extends State<TeacherMailScreen> {
  final _db = FirebaseDatabase.instance;
  final _searchC = TextEditingController();
  Timer? _searchDebounce;
  String _q = '';

  String get _meUid => FirebaseAuth.instance.currentUser!.uid;
  DatabaseReference get _indexRef => _db.ref('mail_index/$_meUid');

  late final Stream<DatabaseEvent> _stream;

  final Map<String, String> _nameCache = {};
  final Map<String, String> _roleCache = {};
  final Map<String, Future<void>> _userFetchPending = {};

  @override
  void initState() {
    super.initState();
    _stream = _indexRef.onValue.asBroadcastStream();
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

  String _normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();

    if (s == 'admin' ||
        s == 'adin' ||
        s == 'admn' ||
        s == 'adm' ||
        s == 'administration' ||
        s == 'administrator') {
      return 'admin';
    }

    if (s == 'teacher' ||
        s == 'teach' ||
        s == 'instructor' ||
        s == 'prof') {
      return 'teacher';
    }

    if (s == 'learner' ||
        s == 'lerner' ||
        s == 'student' ||
        s == 'pupil') {
      return 'learner';
    }

    return 'learner';
  }

  Future<void> _ensureUserCached(String uid) {
    uid = uid.trim();
    if (uid.isEmpty) return Future.value();

    if (_nameCache.containsKey(uid) && _roleCache.containsKey(uid)) {
      return Future.value();
    }

    final pending = _userFetchPending[uid];
    if (pending != null) return pending;

    final fut = () async {
      try {
        final snap = await _db.ref('users/$uid').get();

        String resolvedName = 'User';
        String resolvedRole = 'learner';

        if (snap.exists && snap.value is Map) {
          final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

          final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
          final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
          final email = (m['email'] ?? '').toString().trim();

          final full = ('$fn $ln').trim();
          resolvedName = full.isNotEmpty ? full : (email.isNotEmpty ? email : 'User');
          resolvedRole = _normalizeRole(m['role']);
        }

        final changed = _nameCache[uid] != resolvedName || _roleCache[uid] != resolvedRole;
        _nameCache[uid] = resolvedName;
        _roleCache[uid] = resolvedRole;

        if (changed && mounted) {
          setState(() {});
        }
      } catch (_) {
        final changed = !_nameCache.containsKey(uid) || !_roleCache.containsKey(uid);
        _nameCache.putIfAbsent(uid, () => 'User');
        _roleCache.putIfAbsent(uid, () => 'learner');

        if (changed && mounted) {
          setState(() {});
        }
      } finally {
        _userFetchPending.remove(uid);
      }
    }();

    _userFetchPending[uid] = fut;
    return fut;
  }

  String _bestName(_TopicRow r) {
    final pn = r.peerName.trim();
    if (pn.isNotEmpty) return pn;

    final cached = _nameCache[r.peerUid.trim()];
    if (cached != null && cached.trim().isNotEmpty) return cached;

    return 'User';
  }

  String _bestRole(_TopicRow r) {
    return _roleCache[r.peerUid.trim()] ?? '';
  }

  bool _matchesTab(_InboxTabRole tab, _TopicRow r) {
    final role = _bestRole(r);
    final normalized = role.isEmpty ? 'learner' : role;

    if (tab == _InboxTabRole.teachers) return normalized == 'teacher';
    if (tab == _InboxTabRole.admin) return normalized == 'admin';
    return normalized == 'learner';
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
            return;
          }
        });

        return;
      }
    });

    final byId = <String, _TopicRow>{};
    for (final r in out) {
      final existing = byId[r.threadId];
      if (existing == null) {
        byId[r.threadId] = r;
      } else {
        if (r.updatedAtMs > existing.updatedAtMs) {
          byId[r.threadId] = r;
        }
      }
    }

    final rows = byId.values.toList();
    rows.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return rows;
  }

  List<_TopicRow> _applyFilter(List<_TopicRow> rows) {
    final q = _q.trim();
    if (q.isEmpty) return rows;

    bool hit(_TopicRow r) {
      final subject = r.subject.toLowerCase();
      final last = r.lastMessage.toLowerCase();
      final peer = _bestName(r).toLowerCase();
      return subject.contains(q) || last.contains(q) || peer.contains(q);
    }

    return rows.where(hit).toList();
  }

  Map<String, List<_TopicRow>> _groupByPeer(List<_TopicRow> rows) {
    final Map<String, List<_TopicRow>> grouped = {};
    for (final r in rows) {
      final key = r.peerUid.isNotEmpty ? r.peerUid : r.peerName;
      grouped.putIfAbsent(key, () => []).add(r);
    }

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

  String _previewFromMessage(String body) {
    final clean = body.trim();
    if (clean.isEmpty) return '(No messages yet)';
    return clean.length > 80 ? clean.substring(0, 80) : clean;
  }

  String _timeLabel(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays == 1) return '1d';
    if (diff.inDays < 7) return '${diff.inDays}d';

    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    return '$day/$month';
  }

  String _roleLabel(String role) {
    if (role == 'admin') return 'Administration';
    if (role == 'teacher') return 'Teacher';
    return 'Learner';
  }

  IconData _roleIcon(String role) {
    if (role == 'admin') return Icons.shield_rounded;
    if (role == 'teacher') return Icons.school_rounded;
    return Icons.person_rounded;
  }

  Color _avatarColor(String seed, BuildContext context) {
    final colors = [
      Colors.indigo,
      Colors.blue,
      Colors.teal,
      Colors.green,
      Colors.deepOrange,
      Colors.purple,
      Colors.cyan,
      Colors.pink,
    ];
    final idx = seed.hashCode.abs() % colors.length;
    return colors[idx];
  }

  Future<String> _createThreadWithFirstMessage({
    required String subject,
    required String firstMessage,
    required String toUid,
    required String toName,
    required String teacherName,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    final threadId = _db.ref('mail_threads').push().key;
    if (threadId == null || threadId.trim().isEmpty) {
      throw Exception('Failed to create thread id.');
    }

    final msgRef = _db.ref('mail_messages/$threadId').push();
    final preview = _previewFromMessage(firstMessage);

    final updates = <String, dynamic>{
      'mail_threads/$threadId': {
        'subject': subject,
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': preview,
      },
      'mail_messages/$threadId/${msgRef.key}': {
        'fromUid': _meUid,
        'body': firstMessage.trim(),
        'toUids': {toUid: true},
        'ccUids': {},
        'bccUids': {},
        'attachments': [],
        'createdAt': now,
        'deletedFor': {},
        'reactions': {},
      },
      'mail_index/$_meUid/$threadId': {
        'subject': subject,
        'updatedAt': now,
        'lastMessage': preview,
        'unreadCount': 0,
        'peerUid': toUid,
        'peerName': toName,
        'deletedAt': null,
      },
      'mail_index/$toUid/$threadId': {
        'subject': subject,
        'updatedAt': now,
        'lastMessage': preview,
        'unreadCount': 1,
        'peerUid': _meUid,
        'peerName': teacherName,
        'deletedAt': null,
      },
    };

    await _db.ref().update(updates);
    return threadId;
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
    int score = 100;
    String note = '';
    String status = 'approved';

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

    int parsedScore = int.tryParse(scoreC.text.trim()) ?? 0;
    if (parsedScore < 0) parsedScore = 0;
    if (parsedScore > 100) parsedScore = 100;

    final noteText = noteC.text.trim();
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      await _db.ref(hwRefPath).update({
        'reviewedAt': now,
        'reviewStatus': status,
        'reviewScore': parsedScore,
        'reviewNote': noteText,
      });

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
      final firstMessage = picked.firstMessage.trim();

      if (subject.isEmpty) {
        _snack('Write subject.');
        return;
      }

      if (firstMessage.isEmpty) {
        _snack('Write your message.');
        return;
      }

      if (picked.mode == _ComposeMode.single && picked.receiverUid != null) {
        final toUid = picked.receiverUid!;
        final toName = picked.receiverName ?? '';

        final threadId = await _createThreadWithFirstMessage(
          subject: subject,
          firstMessage: firstMessage,
          toUid: toUid,
          toName: toName,
          teacherName: picked.teacherName,
        );

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

      if (picked.mode == _ComposeMode.classGroup) {
        final classId = picked.classId;
        if (classId == null || classId.trim().isEmpty) {
          _snack('No class selected.');
          return;
        }

        final cSnap = await _db.ref('classes/$classId/learners').get();
        final cVal = cSnap.value;

        if (cVal is! Map || cVal.isEmpty) {
          _snack('This class has no learners.');
          return;
        }

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
            nameByUid[uid.toString()] =
            n.isNotEmpty ? n : (email.isNotEmpty ? email : uid.toString());
          });
        }

        int sent = 0;
        final classSubject = '[$classId] $subject';

        for (final entry in cVal.entries) {
          final learnerUid = entry.key.toString().trim();
          if (learnerUid.isEmpty) continue;
          if (learnerUid == _meUid) continue;

          final learnerName = nameByUid[learnerUid] ??
              (entry.value is Map
                  ? (((entry.value as Map)['name'] ?? '').toString())
                  : 'Learner');

          await _createThreadWithFirstMessage(
            subject: classSubject,
            firstMessage: firstMessage,
            toUid: learnerUid,
            toName: learnerName,
            teacherName: picked.teacherName,
          );

          sent++;
        }

        _snack('Sent to $sent learners ✅');
        return;
      }
    } catch (e) {
      _snack('Compose failed: $e');
    }
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(icon, size: 34, color: scheme.primary),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(color: Colors.grey.shade700, height: 1.35),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryHeader(List<_TopicRow> rows) {
    final learnersCount = rows.where((r) => _matchesTab(_InboxTabRole.learners, r)).length;
    final teachersCount = rows.where((r) => _matchesTab(_InboxTabRole.teachers, r)).length;
    final adminCount = rows.where((r) => _matchesTab(_InboxTabRole.admin, r)).length;
    final totalUnread = rows.fold<int>(0, (sum, r) => sum + r.unreadCount);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _MiniStatCard(
              icon: Icons.mark_email_unread_rounded,
              title: 'Unread',
              value: '$totalUnread',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _MiniStatCard(
              icon: Icons.person_rounded,
              title: 'Learners',
              value: '$learnersCount',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _MiniStatCard(
              icon: Icons.school_rounded,
              title: 'Teachers',
              value: '$teachersCount',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _MiniStatCard(
              icon: Icons.shield_rounded,
              title: 'Admin',
              value: '$adminCount',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab(_InboxTabRole tabRole, List<_TopicRow> allRows) {
    if (allRows.isEmpty) {
      return _buildEmptyState(
        icon: Icons.mail_outline_rounded,
        title: 'No mail yet',
        subtitle: 'New conversations will appear here.',
      );
    }

    final roleRows = allRows.where((r) => _matchesTab(tabRole, r)).toList();
    final filtered = _applyFilter(roleRows);

    if (filtered.isEmpty) {
      return _buildEmptyState(
        icon: Icons.search_off_rounded,
        title: _q.isEmpty ? 'Nothing here yet' : 'No results found',
        subtitle: _q.isEmpty
            ? 'This tab is empty for now.'
            : 'Try a different search term or switch tabs.',
      );
    }

    final grouped = _groupByPeer(filtered);
    final groupKeys = grouped.keys.toList();

    groupKeys.sort((a, b) {
      final aRows = grouped[a]!;
      final bRows = grouped[b]!;
      final aUnread = _sumUnread(aRows);
      final bUnread = _sumUnread(bRows);
      if (aUnread != bUnread) return bUnread.compareTo(aUnread);

      final aTop = aRows.isEmpty ? 0 : aRows.first.updatedAtMs;
      final bTop = bRows.isEmpty ? 0 : bRows.first.updatedAtMs;
      return bTop.compareTo(aTop);
    });

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
      children: [
        if (tabRole == _InboxTabRole.learners) _buildSummaryHeader(allRows),
        ...groupKeys.map((k) {
          final items = grouped[k]!;
          final top = items.first;
          final displayName = _bestName(top);
          final role = _bestRole(top).isEmpty ? 'learner' : _bestRole(top);
          final unreadTotal = _sumUnread(items);
          final latest = items.first;
          final latestSubject =
          latest.subject.trim().isEmpty ? '(No topic)' : latest.subject.trim();
          final latestPreview = latest.lastMessage.trim().isEmpty
              ? '(No messages yet)'
              : latest.lastMessage.trim();

          return _InboxGroupCard(
            displayName: displayName,
            role: _roleLabel(role),
            roleIcon: _roleIcon(role),
            avatarColor: _avatarColor(
              top.peerUid.isEmpty ? displayName : top.peerUid,
              context,
            ),
            latestSubject: latestSubject,
            latestPreview: latestPreview,
            latestTime: _timeLabel(latest.updatedAtMs),
            unreadTotal: unreadTotal,
            totalTopics: items.length,
            children: items.map((r) {
              return _ThreadTile(
                row: r,
                timeLabel: _timeLabel(r.updatedAtMs),
                onDelete: () => _deleteThreadForMe(r),
                onReview: () => _tryOpenHomeworkReview(r),
                onOpen: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      settings: RouteSettings(name: '/mail/thread/${r.threadId}'),
                      builder: (_) => TeacherMailThreadScreen(
                        threadId: r.threadId,
                        peerUid: r.peerUid,
                        peerName: _bestName(r),
                        subject: r.subject,
                      ),
                    ),
                  );
                },
              );
            }).toList(),
          );
        }),
      ],
    );
  }

  Widget _buildTopSearch() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withOpacity(0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: TextField(
        controller: _searchC,
        decoration: InputDecoration(
          hintText: 'Search subject, message or person...',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: (_q.isEmpty)
              ? null
              : IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.close_rounded),
            onPressed: () {
              _searchDebounce?.cancel();
              _searchC.clear();
              setState(() => _q = '');
            },
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        ),
        onChanged: (v) {
          _searchDebounce?.cancel();
          _searchDebounce = Timer(const Duration(milliseconds: 220), () {
            if (!mounted) return;
            setState(() => _q = v.trim().toLowerCase());
          });
        },
      ),
    );
  }

  Widget _buildTabBarShell() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: TabBar(
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        tabs: const [
          Tab(text: 'Learners'),
          Tab(text: 'Teachers'),
          Tab(text: 'Admin'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Color.alphaBlend(
          scheme.primary.withOpacity(0.03),
          Theme.of(context).scaffoldBackgroundColor,
        ),
        appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 72,
          titleSpacing: 16,
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mailbox',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22),
              ),
              SizedBox(height: 2),
              Text(
                'Organized conversations with learners, teachers and administration',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _composeNewTopic,
          icon: const Icon(Icons.edit_rounded),
          label: const Text('New topic'),
        ),
        body: Column(
          children: [
            _buildTopSearch(),
            _buildTabBarShell(),
            const SizedBox(height: 2),
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _stream,
                builder: (context, snap) {
                  final allRows = _parse(snap.data?.snapshot.value);

                  for (final r in allRows) {
                    final uid = r.peerUid.trim();
                    if (uid.isNotEmpty) {
                      _ensureUserCached(uid);
                    }
                  }

                  return TabBarView(
                    children: [
                      _buildTab(_InboxTabRole.learners, allRows),
                      _buildTab(_InboxTabRole.teachers, allRows),
                      _buildTab(_InboxTabRole.admin, allRows),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxGroupCard extends StatefulWidget {
  const _InboxGroupCard({
    required this.displayName,
    required this.role,
    required this.roleIcon,
    required this.avatarColor,
    required this.latestSubject,
    required this.latestPreview,
    required this.latestTime,
    required this.unreadTotal,
    required this.totalTopics,
    required this.children,
  });

  final String displayName;
  final String role;
  final IconData roleIcon;
  final Color avatarColor;
  final String latestSubject;
  final String latestPreview;
  final String latestTime;
  final int unreadTotal;
  final int totalTopics;
  final List<Widget> children;

  @override
  State<_InboxGroupCard> createState() => _InboxGroupCardState();
}

class _InboxGroupCardState extends State<_InboxGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _expanded
              ? scheme.primary.withOpacity(0.30)
              : scheme.outline.withOpacity(0.14),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_expanded ? 0.07 : 0.04),
            blurRadius: _expanded ? 22 : 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          onExpansionChanged: (v) => setState(() => _expanded = v),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          leading: CircleAvatar(
            radius: 24,
            backgroundColor: widget.avatarColor.withOpacity(0.14),
            child: Text(
              widget.displayName.isEmpty ? '?' : widget.displayName.trim().characters.first.toUpperCase(),
              style: TextStyle(
                color: widget.avatarColor,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  widget.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.latestTime,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SoftPill(
                      icon: widget.roleIcon,
                      text: widget.role,
                    ),
                    _SoftPill(
                      icon: Icons.forum_rounded,
                      text: '${widget.totalTopics} topic${widget.totalTopics == 1 ? '' : 's'}',
                    ),
                    if (widget.unreadTotal > 0)
                      _UnreadPill(value: widget.unreadTotal),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  widget.latestSubject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.latestPreview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    height: 1.25,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          children: widget.children,
        ),
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.row,
    required this.timeLabel,
    required this.onDelete,
    required this.onReview,
    required this.onOpen,
  });

  final _TopicRow row;
  final String timeLabel;
  final VoidCallback onDelete;
  final VoidCallback onReview;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subject = row.subject.trim().isEmpty ? '(No topic)' : row.subject.trim();
    final preview = row.lastMessage.trim().isEmpty ? '(No messages yet)' : row.lastMessage.trim();

    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: row.unreadCount > 0
            ? scheme.primary.withOpacity(0.05)
            : scheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: row.unreadCount > 0
              ? scheme.primary.withOpacity(0.18)
              : scheme.outline.withOpacity(0.10),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Expanded(
              child: Text(
                subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: row.unreadCount > 0 ? FontWeight.w900 : FontWeight.w800,
                  fontSize: 14.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timeLabel,
              style: TextStyle(
                color: Colors.grey.shade700,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey.shade800, height: 1.25),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row.unreadCount > 0) ...[
              _UnreadPill(value: row.unreadCount),
              const SizedBox(width: 4),
            ],
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'delete') {
                  onDelete();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete (for me)'),
                ),
              ],
            ),
          ],
        ),
        onLongPress: onReview,
        onTap: onOpen,
      ),
    );
  }
}

class _MiniStatCard extends StatelessWidget {
  const _MiniStatCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withOpacity(0.14)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftPill extends StatelessWidget {
  const _SoftPill({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value > 99 ? '99+' : '$value',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
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

  String _normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'admin' ||
        s == 'adin' ||
        s == 'admn' ||
        s == 'administration' ||
        s == 'administrator') {
      return 'admin';
    }
    if (s == 'teacher' || s == 'instructor' || s == 'teach') return 'teacher';
    if (s == 'learner' || s == 'lerner' || s == 'student') return 'learner';
    return 'learner';
  }

  Future<void> _loadEverything() async {
    try {
      final meSnap = await widget.db.ref('users/${widget.meUid}').get();
      final meVal = meSnap.value;
      if (meVal is Map) {
        final mm = meVal.map((k, v) => MapEntry(k.toString(), v));
        final fn = (mm['first_name'] ?? mm['firstName'] ?? '').toString().trim();
        final ln = (mm['last_name'] ?? mm['lastName'] ?? '').toString().trim();
        final full = '$fn $ln'.trim();
        if (full.isNotEmpty) _teacherName = full;
      }

      final usersSnap = await widget.db.ref('users').get();
      final usersVal = usersSnap.value;

      final nameByUid = <String, String>{};
      final admins = <_RecipientRow>[];
      final teachers = <_RecipientRow>[];

      if (usersVal is Map) {
        usersVal.forEach((uid, vv) {
          if (uid == null || vv == null || vv is! Map) return;
          final m = vv.map((k, v) => MapEntry(k.toString(), v));

          final role = _normalizeRole(m['role']);
          final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
          final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
          final email = (m['email'] ?? '').toString().trim();

          final name = ('$fn $ln').trim();
          final display = name.isNotEmpty ? name : (email.isNotEmpty ? email : uid.toString());

          final u = uid.toString();
          nameByUid[u] = display;

          if (role == 'admin') {
            admins.add(_RecipientRow(uid: u, name: display, type: _RecipientType.admin));
          } else if (role == 'teacher' && u != widget.meUid) {
            teachers.add(_RecipientRow(uid: u, name: display, type: _RecipientType.teacher));
          }
        });
      }

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

          final title = (c['course_title'] ?? c['courseTitle'] ?? c['name'] ?? classId)
              .toString()
              .trim();
          myClasses.add(
            _ClassRow(
              classId: classId.toString(),
              title: title.isEmpty ? classId.toString() : title,
            ),
          );

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

      final all = <_RecipientRow>[...admins, ...teachers, ...learnerRecipients];

      int rank(_RecipientType t) =>
          t == _RecipientType.admin ? 0 : (t == _RecipientType.teacher ? 1 : 2);

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

    if (subject.isEmpty) return;
    if (msg.isEmpty) return;

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
    final media = MediaQuery.of(context);
    final bottom = media.viewInsets.bottom + media.padding.bottom;
    final scheme = Theme.of(context).colorScheme;

    String prefixFor(_RecipientType t) {
      if (t == _RecipientType.admin) return '🛡️ ';
      if (t == _RecipientType.teacher) return '👩‍🏫 ';
      return '🎓 ';
    }

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
                'New topic',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
              const SizedBox(height: 14),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Loading...'),
                    ],
                  ),
                )
              else ...[
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SegmentedButton<_ComposeMode>(
                    segments: const [
                      ButtonSegment(value: _ComposeMode.single, label: Text('Single')),
                      ButtonSegment(value: _ComposeMode.classGroup, label: Text('Whole class')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                ),
                const SizedBox(height: 14),
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
                    decoration: InputDecoration(
                      labelText: 'Send to',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
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
                    decoration: InputDecoration(
                      labelText: 'Class',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _subjectC,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Topic / Subject',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _messageC,
                  minLines: 4,
                  maxLines: 8,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    labelText: 'Mail message',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _submit,
                    icon: const Icon(Icons.send_rounded),
                    label: Text(
                      _mode == _ComposeMode.classGroup ? 'Send to class' : 'Create and send',
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

enum _ComposeMode { single, classGroup }
enum _RecipientType { admin, teacher, learner }

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
  final String? receiverUid;
  final String? receiverName;
  final String? classId;
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