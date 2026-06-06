import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../services/mail_consistency_service.dart';
import '../services/internal_mail_service.dart';
import '../services/push_dispatch_service.dart';
import '../services/homework_review_sync_service.dart';
import '../shared/human_error.dart';
import '../shared/profile_avatar.dart';
import '../shared/responsive_layout.dart';
import '../shared/teacher_web_layout.dart';

import 'teacher_mail_thread_screen.dart';
import '../shared/app_feedback.dart';

class TeacherMailScreen extends StatefulWidget {
  const TeacherMailScreen({super.key});

  @override
  State<TeacherMailScreen> createState() => _TeacherMailScreenState();
}

enum _InboxTabRole { learners, teachers, admin }

enum _MailViewMode { latestFirst, byLearner }

enum _ThreadTypeView { individual, group }

class _TeacherMailScreenState extends State<TeacherMailScreen> {
  final _db = FirebaseDatabase.instance;
  final _searchC = TextEditingController();
  Timer? _searchDebounce;
  String _q = '';
  _MailViewMode _viewMode = _MailViewMode.latestFirst;
  _ThreadTypeView _threadTypeView = _ThreadTypeView.individual;
  bool _searchMode = false;
  String? _desktopSelectedThreadId;

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';
  DatabaseReference get _indexRef => _db.ref('mail_index/$_meUid');

  late final Stream<DatabaseEvent> _stream;

  final Map<String, String> _nameCache = {};
  final Map<String, String> _roleCache = {};
  final Map<String, String> _photoCache = {};
  final Map<String, int> _userCacheFetchedAtMs = {};
  final Map<String, Future<void>> _userFetchPending = {};
  final Set<String> _selfHealInFlight = <String>{};
  final Set<String> _locallyDeletedThreadIds = <String>{};

  static const int _userCacheTtlMs = 5 * 60 * 1000;

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
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(humanizeUiMessage(msg))),
    );
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

    if (s == 'teacher' || s == 'teach' || s == 'instructor' || s == 'prof') {
      return 'teacher';
    }

    if (s == 'learner' || s == 'lerner' || s == 'student' || s == 'pupil') {
      return 'learner';
    }

    return 'learner';
  }

  String _displaySubject(String raw) {
    var s = raw.trim();
    while (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close <= 0) break;
      s = s.substring(close + 1).trimLeft();
    }
    return s;
  }

  Future<void> _ensureUserCached(String uid) {
    uid = uid.trim();
    if (uid.isEmpty) return Future.value();

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final hasCompleteCache =
        _nameCache.containsKey(uid) &&
        _roleCache.containsKey(uid) &&
        _photoCache.containsKey(uid);
    final lastFetchedMs = _userCacheFetchedAtMs[uid] ?? 0;
    final cacheFresh =
        hasCompleteCache && (nowMs - lastFetchedMs) < _userCacheTtlMs;

    if (cacheFresh) {
      return Future.value();
    }

    final pending = _userFetchPending[uid];
    if (pending != null) return pending;

    final fut = () async {
      try {
        final snap = await _db.ref('users/$uid').get();

        String resolvedName = 'User';
        String resolvedRole = 'learner';
        String resolvedPhoto = '';

        if (snap.exists && snap.value is Map) {
          final m = (snap.value as Map).map(
            (k, v) => MapEntry(k.toString(), v),
          );

          final fn = (m['first_name'] ?? m['firstName'] ?? '')
              .toString()
              .trim();
          final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
          final email = (m['email'] ?? '').toString().trim();

          final full = ('$fn $ln').trim();
          resolvedName = full.isNotEmpty
              ? full
              : (email.isNotEmpty ? email : 'User');
          resolvedRole = _normalizeRole(m['role']);
          resolvedPhoto = ProfileAvatar.resolvePhotoFromMap(m);
        }

        final changed =
            _nameCache[uid] != resolvedName ||
            _roleCache[uid] != resolvedRole ||
            _photoCache[uid] != resolvedPhoto;
        _nameCache[uid] = resolvedName;
        _roleCache[uid] = resolvedRole;
        _photoCache[uid] = resolvedPhoto;
        _userCacheFetchedAtMs[uid] = DateTime.now().millisecondsSinceEpoch;

        if (changed && mounted) {
          setState(() {});
        }
      } catch (_) {
        final changed =
            !_nameCache.containsKey(uid) ||
            !_roleCache.containsKey(uid) ||
            !_photoCache.containsKey(uid);
        _nameCache.putIfAbsent(uid, () => 'User');
        _roleCache.putIfAbsent(uid, () => 'learner');
        _photoCache.putIfAbsent(uid, () => '');
        _userCacheFetchedAtMs[uid] = DateTime.now().millisecondsSinceEpoch;

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
    if (r.isGroup && r.groupName.trim().isNotEmpty) return r.groupName.trim();
    final cached = _nameCache[r.peerUid.trim()];
    if (cached != null && cached.trim().isNotEmpty) return cached;

    final pn = r.peerName.trim();
    if (pn.isNotEmpty) return pn;

    return 'User';
  }

  String _bestRole(_TopicRow r) {
    return _roleCache[r.peerUid.trim()] ?? '';
  }

  String _bestPhoto(_TopicRow r) {
    if (r.isGroup) return r.groupPicUrl.trim();
    return _photoCache[r.peerUid.trim()] ?? '';
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
        m.containsKey('type') ||
        m.containsKey('homeworkRef') ||
        m.containsKey('updatedAt') ||
        m.containsKey('lastMessage') ||
        m.containsKey('lastMessagePreview') ||
        m.containsKey('unreadCount') ||
        m.containsKey('unread');
  }

  Future<void> _selfHealIndexRow(
    String threadId,
    Map<String, dynamic> row,
  ) async {
    if (_meUid.trim().isEmpty) return;
    threadId = threadId.trim();
    if (threadId.isEmpty) return;
    if (_selfHealInFlight.contains(threadId)) return;

    final rawType = (row['type'] ?? '').toString().trim().toLowerCase();
    final rawHwRef = (row['homeworkRef'] ?? '').toString().trim();
    final subject = (row['subject'] ?? '').toString().trim();
    final subjectLower = subject.toLowerCase();
    final hasUnreadCount = row.containsKey('unreadCount');
    final hasLegacyUnread = row.containsKey('unread');
    final needsType = rawType.isEmpty;
    final needsHwRef = rawHwRef.isEmpty;
    final looksHwByPrefix = subjectLower.startsWith('[hw]');
    final needsLastMessage =
        (row['lastMessage'] ?? '').toString().trim().isEmpty &&
        (row['lastMessagePreview'] ?? '').toString().trim().isNotEmpty;

    if (!needsType &&
        !needsHwRef &&
        !needsLastMessage &&
        (!hasLegacyUnread || hasUnreadCount)) {
      return;
    }

    _selfHealInFlight.add(threadId);
    try {
      final idxUpdates = <String, dynamic>{};

      if (!hasUnreadCount && hasLegacyUnread) {
        idxUpdates['unreadCount'] = _toIntAny(row['unread']);
      }

      if (needsLastMessage) {
        final preview = (row['lastMessagePreview'] ?? '').toString().trim();
        if (preview.isNotEmpty) idxUpdates['lastMessage'] = preview;
      }

      String resolvedType = rawType;
      String resolvedHwRef = rawHwRef;

      if (resolvedType.isEmpty && looksHwByPrefix) {
        resolvedType = 'homework';
      }

      final needsThreadRead =
          resolvedType.isEmpty || resolvedHwRef.isEmpty || looksHwByPrefix;

      if (needsThreadRead) {
        final tSnap = await _db.ref('mail_threads/$threadId').get();
        if (tSnap.exists && tSnap.value is Map) {
          final t = (tSnap.value as Map).map((k, v) => MapEntry('$k', v));
          final tSubject = (t['subject'] ?? '').toString().trim();
          final tType = (t['type'] ?? '').toString().trim().toLowerCase();
          final tHwRef = (t['homeworkRef'] ?? '').toString().trim();
          final tLast = (t['lastMessage'] ?? '').toString().trim();
          final tPreview = (t['lastMessagePreview'] ?? '').toString().trim();

          String inferredType = tType;
          if (inferredType.isEmpty) {
            final subjLower = tSubject.toLowerCase();
            inferredType = (tHwRef.isNotEmpty || subjLower.startsWith('[hw]'))
                ? 'homework'
                : 'mail';
          }

          if (resolvedType.isEmpty) resolvedType = inferredType;
          if (resolvedHwRef.isEmpty && tHwRef.isNotEmpty) {
            resolvedHwRef = tHwRef;
          }

          final threadUpdates = <String, dynamic>{};
          if (tType.isEmpty) threadUpdates['type'] = inferredType;
          if (tLast.isEmpty && tPreview.isNotEmpty) {
            threadUpdates['lastMessage'] = tPreview;
          }
          if (threadUpdates.isNotEmpty) {
            await _db.ref('mail_threads/$threadId').update(threadUpdates);
          }

          if ((row['subject'] ?? '').toString().trim().isEmpty &&
              tSubject.isNotEmpty) {
            idxUpdates['subject'] = tSubject;
          }
          if ((row['lastMessage'] ?? '').toString().trim().isEmpty) {
            if (tLast.isNotEmpty) idxUpdates['lastMessage'] = tLast;
            if (tLast.isEmpty && tPreview.isNotEmpty) {
              idxUpdates['lastMessage'] = tPreview;
            }
          }
        }
      }

      if (resolvedType.isNotEmpty) idxUpdates['type'] = resolvedType;
      if (resolvedHwRef.isNotEmpty) idxUpdates['homeworkRef'] = resolvedHwRef;

      if (idxUpdates.isNotEmpty) {
        await _indexRef.child(threadId).update(idxUpdates);
      }
    } catch (_) {
      // best-effort migration only
    } finally {
      _selfHealInFlight.remove(threadId);
    }
  }

  List<_TopicRow> _parse(dynamic v) {
    if (v is! Map) return [];
    final out = <_TopicRow>[];

    void addIfThreadObject(String threadId, Map obj) {
      final m = obj.map((kk, vvv) => MapEntry(kk.toString(), vvv));
      unawaited(_selfHealIndexRow(threadId, m));
      final row = _TopicRow.fromMap(threadId, m);
      if (row.deletedAtMs != null) return;
      if (_locallyDeletedThreadIds.contains(row.threadId)) return;

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
            final innerMap = innerV.map(
              (kk, vvv) => MapEntry(kk.toString(), vvv),
            );
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

  int _toIntAny(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  int _countGroupsForTab(List<_TopicRow> rows, _InboxTabRole tabRole) {
    final roleRows = rows
        .where((r) => _matchesTab(tabRole, r))
        .where((r) => !r.isHomework)
        .toList();
    if (_viewMode == _MailViewMode.latestFirst) {
      return roleRows.length;
    }
    final grouped = _groupByPeer(roleRows);
    return grouped.length;
  }

  int _unreadForTab(List<_TopicRow> rows, _InboxTabRole tabRole) {
    final roleRows = rows
        .where((r) => _matchesTab(tabRole, r))
        .where((r) => !r.isHomework)
        .toList();
    return _sumUnread(roleRows);
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
    final myRole = await MailConsistencyService.resolveUserRole(
      _db,
      _meUid,
      seedRole: 'teacher',
    );
    final peerRole = await MailConsistencyService.resolveUserRole(_db, toUid);

    final updates = <String, dynamic>{
      'mail_threads/$threadId': {
        'subject': subject,
        'type': 'mail',
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
        'type': 'mail',
        'updatedAt': now,
        'lastMessage': preview,
        'unreadCount': 0,
        'peerUid': toUid,
        'peerName': toName,
        'peerRole': peerRole,
        'deletedAt': null,
      },
      'mail_index/$toUid/$threadId': {
        'subject': subject,
        'type': 'mail',
        'updatedAt': now,
        'lastMessage': preview,
        'unreadCount': 1,
        'peerUid': _meUid,
        'peerName': teacherName,
        'peerRole': myRole,
        'deletedAt': null,
      },
      'mail_state/$_meUid/$threadId': {
        'lastReadAt': now,
        'lastDeliveredAt': now,
      },
      'mail_state/$toUid/$threadId/lastDeliveredAt': now,
    };

    await _db.ref().update(updates);
    await MailConsistencyService.verifyMailWriteOnce(
      db: _db,
      threadId: threadId,
      senderUid: _meUid,
      receiverUid: toUid,
      senderName: teacherName,
      receiverName: toName,
      senderRole: myRole,
      receiverRole: peerRole,
      subject: subject,
      lastMessage: preview,
      now: now,
      type: 'mail',
    );
    return threadId;
  }

  Future<void> _deleteThreadForMe(_TopicRow row) async {
    final ok =
        await showDialog<bool>(
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
      _locallyDeletedThreadIds.add(row.threadId);
      if (mounted) setState(() {});
      await _indexRef.child(row.threadId).update({'deletedAt': now});
      _snack('Deleted ✅');
    } catch (e) {
      _locallyDeletedThreadIds.remove(row.threadId);
      if (mounted) setState(() {});
      _snack('Delete failed: $e');
    }
  }

  Future<void> _showThreadActions(_TopicRow row) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('Open topic'),
              onTap: () => Navigator.pop(context, 'open'),
            ),
            if (row.isHomework && !row.isGroup)
              ListTile(
                leading: const Icon(Icons.rate_review_rounded),
                title: const Text('Review homework'),
                onTap: () => Navigator.pop(context, 'review'),
              ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.red,
              ),
              title: const Text('Delete for me'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;

    if (action == 'delete') {
      await _deleteThreadForMe(row);
      return;
    }

    if (action == 'review') {
      await _tryOpenHomeworkReview(row);
      return;
    }

    if (action == 'open') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          settings: RouteSettings(name: '/mail/thread/${row.threadId}'),
          builder: (_) => TeacherMailThreadScreen(
            threadId: row.threadId,
            peerUid: row.peerUid,
            peerName: _bestName(row),
            subject: _displaySubject(row.subject),
          ),
        ),
      );
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
      final type = (t['type'] ?? '').toString().trim().toLowerCase();
      var hwRefPath = (t['homeworkRef'] ?? '').toString().trim();
      if (hwRefPath.isEmpty) {
        final learnerUid = (t['learnerUid'] ?? '').toString().trim();
        final courseKey = (t['courseKey'] ?? '').toString().trim();
        final sessionId = (t['sessionId'] ?? '').toString().trim();
        if (learnerUid.isNotEmpty &&
            courseKey.isNotEmpty &&
            sessionId.isNotEmpty) {
          hwRefPath =
              'users/$learnerUid/courses/$courseKey/attendance/$sessionId/homework';
        }
      }

      if (type != 'homework' && hwRefPath.isEmpty) {
        _snack('No Homework Found.');
        return;
      }

      if (hwRefPath.isEmpty) {
        _snack('Homework link missing (homeworkRef).');
        return;
      }

      final hwSnap = await _db.ref(hwRefPath).get();
      if (!hwSnap.exists || hwSnap.value is! Map) {
        _snack('No homework detected for this thread.');
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
      _snack(toHumanError(e));
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
    String status = 'pass';

    try {
      final hwSnap = await _db.ref(hwRefPath).get();
      if (hwSnap.exists && hwSnap.value is Map) {
        final hw = Map<String, dynamic>.from(hwSnap.value as Map);
        final s = hw['reviewScore'];
        if (s is num) score = s.toInt();
        note = (hw['reviewNote'] ?? '').toString();
        final st = (hw['reviewStatus'] ?? '').toString().trim().toLowerCase();
        if (st == 'pass' || st == 'approved') status = 'pass';
        if (st == 'redo' || st == 'needs_work') status = 'redo';
      }
    } catch (_) {}

    if (!mounted) return;

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
                    RadioGroup<String>(
                      groupValue: status,
                      onChanged: (v) => setLocal(() => status = v ?? 'pass'),
                      child: Column(
                        children: const [
                          RadioListTile<String>(
                            value: 'pass',
                            title: Text('Pass ✅'),
                          ),
                          RadioListTile<String>(
                            value: 'redo',
                            title: Text('Redo 🔁'),
                          ),
                        ],
                      ),
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
        'needsRedo': status == 'redo',
      });

      final verifySnap = await _db.ref(hwRefPath).get();
      final verifyMap = verifySnap.value is Map
          ? (verifySnap.value as Map).map((k, v) => MapEntry('$k', v))
          : <String, dynamic>{};
      final savedStatus = HomeworkReviewSyncService.normalizeStatus(
        verifyMap['reviewStatus'],
      );
      if (HomeworkReviewSyncService.toInt(verifyMap['reviewedAt']) <= 0 ||
          savedStatus != status) {
        throw Exception('Homework review was not saved.');
      }

      final preview = status == 'redo'
          ? '🔁 Redo • $parsedScore/100'
          : '✅ Pass • $parsedScore/100';

      final Map<String, dynamic> updates = {
        'mail_threads/$threadId/updatedAt': now,
        'mail_threads/$threadId/lastMessage': preview,
        if (teacherUid.isNotEmpty)
          'mail_index/$teacherUid/$threadId/updatedAt': now,
        if (teacherUid.isNotEmpty)
          'mail_index/$teacherUid/$threadId/lastMessage': preview,
        if (learnerUid.isNotEmpty)
          'mail_index/$learnerUid/$threadId/updatedAt': now,
        if (learnerUid.isNotEmpty)
          'mail_index/$learnerUid/$threadId/lastMessage': preview,
      };

      await _db.ref().update(updates);

      if (learnerUid.isNotEmpty) {
        try {
          await PushDispatchService.dispatchMailToUser(
            targetUid: learnerUid,
            threadId: threadId,
            peerUid: _meUid,
            title: subject.trim().isEmpty ? 'Homework reviewed' : subject,
            preview: preview,
            nowMs: now,
            context: const PushDispatchContext(
              screen: 'teacher/teacher_mail',
              action: 'homework_review_push',
            ),
          );
        } catch (_) {}
      }

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

      if (picked.mode == _ComposeMode.single) {
        final selectedUids = picked.receiverUids ?? const [];

        if (selectedUids.isEmpty) {
          _snack('Please select at least one recipient.');
          return;
        }

        final usersSnap = await _db.ref('users').get();
        final usersVal = usersSnap.value;
        final nameByUid = <String, String>{};

        if (usersVal is Map) {
          usersVal.forEach((uid, vv) {
            if (uid == null || vv == null || vv is! Map) return;
            final m = vv.map((k, v) => MapEntry(k.toString(), v));
            final fn = (m['first_name'] ?? m['firstName'] ?? '')
                .toString()
                .trim();
            final ln = (m['last_name'] ?? m['lastName'] ?? '')
                .toString()
                .trim();
            final email = (m['email'] ?? '').toString().trim();
            final n = ('$fn $ln').trim();
            nameByUid[uid.toString()] = n.isNotEmpty
                ? n
                : (email.isNotEmpty ? email : uid.toString());
          });
        }

        String? firstThreadId;
        String? firstUid;
        String firstName = '';
        int sent = 0;

        for (final toUid in selectedUids) {
          final toName = nameByUid[toUid] ?? 'User';

          final threadId = await _createThreadWithFirstMessage(
            subject: subject,
            firstMessage: firstMessage,
            toUid: toUid,
            toName: toName,
            teacherName: picked.teacherName,
          );

          final now = DateTime.now().millisecondsSinceEpoch;
          final preview = _previewFromMessage(firstMessage);
          unawaited(() async {
            try {
              await PushDispatchService.dispatchMailToUser(
                targetUid: toUid,
                threadId: threadId,
                peerUid: _meUid,
                title: subject,
                preview: preview,
                nowMs: now,
                context: const PushDispatchContext(
                  screen: 'teacher/teacher_mail',
                  action: 'mail_push',
                ),
              );
            } catch (_) {}
          }());

          firstThreadId ??= threadId;
          firstUid ??= toUid;
          if (firstName.isEmpty) firstName = toName;
          sent++;
        }

        if (!mounted) return;

        if (sent == 1 && firstThreadId != null && firstUid != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              settings: RouteSettings(name: '/mail/thread/$firstThreadId'),
              builder: (_) => TeacherMailThreadScreen(
                threadId: firstThreadId!,
                peerUid: firstUid!,
                peerName: firstName.isEmpty ? 'User' : firstName,
                subject: subject,
              ),
            ),
          );
        } else {
          _snack('Sent to $sent recipients ✅');
        }

        return;
      }

      if (picked.mode == _ComposeMode.group) {
        final selectedUids = <String>{...(picked.receiverUids ?? const [])};
        if (selectedUids.isEmpty) {
          _snack('Please select at least one member.');
          return;
        }
        final groupName = picked.groupName?.trim() ?? '';
        if (groupName.isEmpty) {
          _snack('Please provide a group name.');
          return;
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        final threadId = await InternalMailService.createGroupThread(
          creatorUid: _meUid,
          creatorName: picked.teacherName,
          creatorRole: 'teacher',
          participantUids: selectedUids,
          groupName: groupName,
          groupPicUrl: picked.groupPicUrl,
          subject: subject,
          now: now,
        );
        await InternalMailService.sendGroupMessage(
          threadId: threadId,
          senderUid: _meUid,
          body: firstMessage,
        );

        final preview = _previewFromMessage(firstMessage);
        unawaited(() async {
          try {
            await PushDispatchService.dispatchMailToGroup(
              threadId: threadId,
              senderUid: _meUid,
              senderName: picked.teacherName,
              title: subject,
              preview: preview,
              nowMs: now,
              context: const PushDispatchContext(
                screen: 'teacher/teacher_mail',
                action: 'mail_push_group',
              ),
            );
          } catch (_) {}
        }());

        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            settings: RouteSettings(name: '/mail/thread/$threadId'),
            builder: (_) => TeacherMailThreadScreen(
              threadId: threadId,
              peerUid: '',
              peerName: groupName,
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
            final fn = (m['first_name'] ?? m['firstName'] ?? '')
                .toString()
                .trim();
            final ln = (m['last_name'] ?? m['lastName'] ?? '')
                .toString()
                .trim();
            final email = (m['email'] ?? '').toString().trim();
            final n = ('$fn $ln').trim();
            nameByUid[uid.toString()] = n.isNotEmpty
                ? n
                : (email.isNotEmpty ? email : uid.toString());
          });
        }

        int sent = 0;
        final classSubject = subject;

        for (final entry in cVal.entries) {
          final learnerUid = entry.key.toString().trim();
          if (learnerUid.isEmpty) continue;
          if (learnerUid == _meUid) continue;

          final learnerName =
              nameByUid[learnerUid] ??
              (entry.value is Map
                  ? (((entry.value as Map)['name'] ?? '').toString())
                  : 'Learner');

          final threadId = await _createThreadWithFirstMessage(
            subject: classSubject,
            firstMessage: firstMessage,
            toUid: learnerUid,
            toName: learnerName,
            teacherName: picked.teacherName,
          );

          final now = DateTime.now().millisecondsSinceEpoch;
          final preview = _previewFromMessage(firstMessage);
          unawaited(() async {
            try {
              await PushDispatchService.dispatchMailToUser(
                targetUid: learnerUid,
                threadId: threadId,
                peerUid: _meUid,
                title: classSubject,
                preview: preview,
                nowMs: now,
                context: const PushDispatchContext(
                  screen: 'teacher/teacher_mail',
                  action: 'mail_push',
                ),
              );
            } catch (_) {}
          }());

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
                color: scheme.primary.withValues(alpha: 0.10),
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

  Widget _buildTab(_InboxTabRole tabRole, List<_TopicRow> allRows) {
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

    if (allRows.isEmpty) {
      return _buildEmptyState(
        icon: Icons.mail_outline_rounded,
        title: 'No mail yet',
        subtitle: 'New conversations will appear here.',
      );
    }

    final roleRows = allRows
        .where((r) => _matchesTab(tabRole, r))
        .where((r) => !r.isHomework)
        .where(
          (r) =>
              _threadTypeView == _ThreadTypeView.group ? r.isGroup : !r.isGroup,
        )
        .toList();
    final filtered = _applyFilter(roleRows);

    if (filtered.isEmpty) {
      return _buildEmptyState(
        icon: Icons.search_off_rounded,
        title: _q.isEmpty ? 'Nothing here yet' : 'No results found',
        subtitle: _q.isEmpty
            ? (_threadTypeView == _ThreadTypeView.group
                  ? 'No group conversations in this tab yet.'
                  : 'No individual conversations in this tab yet.')
            : 'Try a different search term or switch tabs.',
      );
    }

    if (_viewMode == _MailViewMode.latestFirst) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
        itemCount: filtered.length,
        itemBuilder: (context, i) {
          final r = filtered[i];
          return _ThreadTile(
            row: r,
            displayName: _bestName(r),
            photoUrl: _bestPhoto(r),
            avatarColor: _avatarColor(
              r.peerUid.isEmpty ? _bestName(r) : r.peerUid,
              context,
            ),
            timeLabel: _timeLabel(r.updatedAtMs),
            onDelete: () => _deleteThreadForMe(r),
            onReview: r.isHomework ? () => _tryOpenHomeworkReview(r) : null,
            onLongPress: () => _showThreadActions(r),
            onOpen: () => _openThread(r, desktop: desktopWorkspace),
          );
        },
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
        ...groupKeys.map((k) {
          final items = grouped[k]!;
          final top = items.first;
          final displayName = _bestName(top);
          final unreadTotal = _sumUnread(items);

          return _InboxGroupCard(
            displayName: displayName,
            avatarColor: _avatarColor(
              top.peerUid.isEmpty ? displayName : top.peerUid,
              context,
            ),
            photoUrl: _bestPhoto(top),
            latestTime: _timeLabel(top.updatedAtMs),
            unreadTotal: unreadTotal,
            children: items.map((r) {
              return _ThreadTile(
                row: r,
                displayName: _bestName(r),
                photoUrl: _bestPhoto(r),
                avatarColor: _avatarColor(
                  r.peerUid.isEmpty ? _bestName(r) : r.peerUid,
                  context,
                ),
                timeLabel: _timeLabel(r.updatedAtMs),
                onDelete: () => _deleteThreadForMe(r),
                onReview: r.isHomework ? () => _tryOpenHomeworkReview(r) : null,
                onLongPress: () => _showThreadActions(r),
                onOpen: () => _openThread(r, desktop: desktopWorkspace),
              );
            }).toList(),
          );
        }),
      ],
    );
  }

  Future<void> _openThread(_TopicRow row, {required bool desktop}) async {
    if (desktop) {
      setState(() => _desktopSelectedThreadId = row.threadId);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: RouteSettings(name: '/mail/thread/${row.threadId}'),
        builder: (_) => TeacherMailThreadScreen(
          threadId: row.threadId,
          peerUid: row.peerUid,
          peerName: _bestName(row),
          subject: _displaySubject(row.subject),
        ),
      ),
    );
  }

  _TopicRow? _desktopSelectedRow(List<_TopicRow> allRows) {
    if (allRows.isEmpty) return null;

    final selectedId = _desktopSelectedThreadId?.trim() ?? '';
    if (selectedId.isNotEmpty) {
      for (final row in allRows) {
        if (row.threadId == selectedId) return row;
      }
    }

    for (final row in allRows) {
      if (!row.isHomework) return row;
    }
    return allRows.first;
  }

  Widget _buildTopSearch() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: _searchMode
                  ? TextField(
                      controller: _searchC,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search subject, message or person...',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onChanged: (v) {
                        _searchDebounce?.cancel();
                        _searchDebounce = Timer(
                          const Duration(milliseconds: 220),
                          () {
                            if (!mounted) return;
                            setState(() => _q = v.trim().toLowerCase());
                          },
                        );
                      },
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: const Text('Newest first'),
                            selected: _viewMode == _MailViewMode.latestFirst,
                            onSelected: (_) {
                              setState(
                                () => _viewMode = _MailViewMode.latestFirst,
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Group by learner'),
                            selected: _viewMode == _MailViewMode.byLearner,
                            onSelected: (_) {
                              setState(
                                () => _viewMode = _MailViewMode.byLearner,
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Individual'),
                            selected:
                                _threadTypeView == _ThreadTypeView.individual,
                            onSelected: (_) {
                              setState(
                                () => _threadTypeView =
                                    _ThreadTypeView.individual,
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Group'),
                            selected: _threadTypeView == _ThreadTypeView.group,
                            onSelected: (_) {
                              setState(
                                () => _threadTypeView = _ThreadTypeView.group,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
            ),
            IconButton(
              tooltip: _searchMode ? 'Close search' : 'Search',
              icon: Icon(
                _searchMode ? Icons.close_rounded : Icons.search_rounded,
              ),
              onPressed: () {
                setState(() {
                  _searchMode = !_searchMode;
                  if (!_searchMode) {
                    _searchDebounce?.cancel();
                    _searchC.clear();
                    _q = '';
                  }
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBarShell({
    required int learnersCount,
    required int teachersCount,
    required int adminCount,
    required int learnersUnread,
    required int teachersUnread,
    required int adminUnread,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final useScrollableTabs = screenWidth < 760;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: TabBar(
        isScrollable: useScrollableTabs,
        labelPadding: const EdgeInsets.symmetric(horizontal: 10),
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
        tabs: [
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Learners ($learnersCount)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (learnersUnread > 0) ...[
                  const SizedBox(width: 6),
                  _UnreadPill(value: learnersUnread),
                ],
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Teachers ($teachersCount)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (teachersUnread > 0) ...[
                  const SizedBox(width: 6),
                  _UnreadPill(value: teachersUnread),
                ],
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Admin ($adminCount)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (adminUnread > 0) ...[
                  const SizedBox(width: 6),
                  _UnreadPill(value: adminUnread),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Color.alphaBlend(
          scheme.primary.withValues(alpha: 0.03),
          Theme.of(context).scaffoldBackgroundColor,
        ),
        appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 60,
          titleSpacing: 16,
          title: const Text(
            'Mailbox',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 21),
          ),
          actions: [
            if (desktopWorkspace)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: _composeNewTopic,
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('New topic'),
                ),
              ),
          ],
        ),
        floatingActionButton: desktopWorkspace
            ? null
            : FloatingActionButton.extended(
                onPressed: _composeNewTopic,
                icon: const Icon(Icons.edit_rounded),
                label: const Text('New topic'),
              ),
        body: teacherWebBodyFrame(
          context: context,
          maxWidth: 1500,
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

              final learnersCount = _countGroupsForTab(
                allRows,
                _InboxTabRole.learners,
              );
              final teachersCount = _countGroupsForTab(
                allRows,
                _InboxTabRole.teachers,
              );
              final adminCount = _countGroupsForTab(
                allRows,
                _InboxTabRole.admin,
              );
              final learnersUnread = _unreadForTab(
                allRows,
                _InboxTabRole.learners,
              );
              final teachersUnread = _unreadForTab(
                allRows,
                _InboxTabRole.teachers,
              );
              final adminUnread = _unreadForTab(allRows, _InboxTabRole.admin);
              final selectedRow = desktopWorkspace
                  ? _desktopSelectedRow(allRows)
                  : null;
              final mailboxBody = Column(
                children: [
                  _buildTopSearch(),
                  _buildTabBarShell(
                    learnersCount: learnersCount,
                    teachersCount: teachersCount,
                    adminCount: adminCount,
                    learnersUnread: learnersUnread,
                    teachersUnread: teachersUnread,
                    adminUnread: adminUnread,
                  ),
                  const SizedBox(height: 2),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildTab(_InboxTabRole.learners, allRows),
                        _buildTab(_InboxTabRole.teachers, allRows),
                        _buildTab(_InboxTabRole.admin, allRows),
                      ],
                    ),
                  ),
                ],
              );

              if (!desktopWorkspace) return mailboxBody;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: mailboxBody),
                  Container(
                    width: 1,
                    color: scheme.outline.withValues(alpha: 0.14),
                  ),
                  Expanded(
                    flex: 6,
                    child: selectedRow == null
                        ? _buildEmptyState(
                            icon: Icons.mark_email_read_rounded,
                            title: 'Select a conversation',
                            subtitle:
                                'Choose a thread from the mailbox to use the larger desktop work area.',
                          )
                        : TeacherMailThreadScreen(
                            key: ValueKey(
                              'desktop_mail_${selectedRow.threadId}',
                            ),
                            threadId: selectedRow.threadId,
                            peerUid: selectedRow.peerUid,
                            peerName: _bestName(selectedRow),
                            subject: _displaySubject(selectedRow.subject),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _InboxGroupCard extends StatefulWidget {
  const _InboxGroupCard({
    required this.displayName,
    required this.avatarColor,
    required this.photoUrl,
    required this.latestTime,
    required this.unreadTotal,
    required this.children,
  });

  final String displayName;
  final Color avatarColor;
  final String photoUrl;
  final String latestTime;
  final int unreadTotal;
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
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _expanded
              ? scheme.primary.withValues(alpha: 0.30)
              : scheme.outline.withValues(alpha: 0.14),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _expanded ? 0.07 : 0.04),
            blurRadius: _expanded ? 18 : 12,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          onExpansionChanged: (v) => setState(() => _expanded = v),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          leading: ProfileAvatar(
            name: widget.displayName,
            photoUrl: widget.photoUrl,
            radius: 20,
            fallbackBg: widget.avatarColor.withValues(alpha: 0.14),
            fallbackFg: widget.avatarColor,
            borderColor: widget.avatarColor.withValues(alpha: 0.25),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  widget.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
              if (widget.latestTime.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  widget.latestTime,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (widget.unreadTotal > 0) ...[
                const SizedBox(width: 10),
                _UnreadPill(value: widget.unreadTotal),
              ],
            ],
          ),
          subtitle: null,
          children: widget.children,
        ),
      ),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.row,
    required this.displayName,
    required this.photoUrl,
    required this.avatarColor,
    required this.timeLabel,
    required this.onDelete,
    required this.onReview,
    required this.onLongPress,
    required this.onOpen,
  });

  final _TopicRow row;
  final String displayName;
  final String photoUrl;
  final Color avatarColor;
  final String timeLabel;
  final VoidCallback onDelete;
  final VoidCallback? onReview;
  final VoidCallback onLongPress;
  final VoidCallback onOpen;

  String _displaySubject(String raw) {
    var s = raw.trim();
    while (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close <= 0) break;
      s = s.substring(close + 1).trimLeft();
    }
    return s;
  }

  String _firstSentence(String raw) {
    final text = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return '(No messages yet)';
    final m = RegExp(r'^(.+?[.!?])(?:\s|$)').firstMatch(text);
    if (m != null) return m.group(1)!;
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final shownSubject = _displaySubject(row.subject);
    final subject = shownSubject.isEmpty ? '(No topic)' : shownSubject;
    final preview = _firstSentence(row.lastMessage);
    final isReport = row.type.trim().toLowerCase() == 'report';

    final bgColor = row.unreadCount > 0
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.07),
            scheme.surface,
          )
        : scheme.surface;
    final isGroup = row.isGroup;
    final effectiveBg = isReport
        ? Color.alphaBlend(const Color(0xFFE8F1FB), bgColor)
        : (isGroup
              ? Color.alphaBlend(Colors.indigo.withValues(alpha: 0.06), bgColor)
              : bgColor);
    final borderColor = row.unreadCount > 0
        ? (isReport
              ? const Color(0xFF1F4E79).withValues(alpha: 0.42)
              : scheme.primary.withValues(alpha: 0.28))
        : (isReport
              ? const Color(0xFF1F4E79).withValues(alpha: 0.26)
              : scheme.outline.withValues(alpha: 0.16));

    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onLongPress: onLongPress,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              isGroup
                  ? CircleAvatar(
                      radius: 19,
                      backgroundColor: Colors.indigo.withValues(alpha: 0.12),
                      foregroundImage: photoUrl.trim().isNotEmpty
                          ? NetworkImage(photoUrl.trim())
                          : null,
                      child: photoUrl.trim().isNotEmpty
                          ? null
                          : const Icon(
                              Icons.groups_rounded,
                              color: Colors.indigo,
                            ),
                    )
                  : ProfileAvatar(
                      name: displayName,
                      photoUrl: photoUrl,
                      radius: 19,
                      fallbackBg: avatarColor.withValues(alpha: 0.14),
                      fallbackFg: avatarColor,
                      borderColor: avatarColor.withValues(alpha: 0.30),
                    ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayName.trim().isEmpty ? 'User' : displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        if (isReport)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF1F4E79,
                              ).withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'Report',
                              style: TextStyle(
                                color: Color(0xFF1F4E79),
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        if (isGroup)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.indigo.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'Group',
                              style: TextStyle(
                                color: Colors.indigo,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        if (timeLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            timeLabel,
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isReport
                            ? const Color(0xFF1F4E79)
                            : (row.unreadCount > 0
                                  ? scheme.primary
                                  : scheme.onSurface),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (row.unreadCount > 0) ...[
                    _UnreadPill(value: row.unreadCount),
                    const SizedBox(height: 2),
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
            ],
          ),
        ),
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
  final _groupNameC = TextEditingController();
  final _groupPicUrlC = TextEditingController();
  final _memberSearchC = TextEditingController();
  String _memberQuery = '';
  String _teacherName = 'Teacher';

  List<_RecipientRow> _recipients = [];
  _RecipientRow? _picked;
  final Set<String> _pickedRecipientUids = {};

  List<_ClassRow> _classes = [];
  _ClassRow? _pickedClass;

  _ComposeMode _mode = _ComposeMode.single;
  bool _uploadingGroupPic = false;

  Future<void> _uploadGroupPicture() async {
    if (_uploadingGroupPic) return;
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Group picture upload is not supported on web yet.'),
        ),
      );
      return;
    }
    final picked = await FilePicker.platform.pickFiles(withData: false);
    final path = picked?.files.single.path;
    if (path == null || path.trim().isEmpty) return;
    setState(() => _uploadingGroupPic = true);
    try {
      final parts = path.replaceAll('\\', '/').split('/');
      final filename = parts.isEmpty ? 'group.jpg' : parts.last;
      final url = await MailUploadClient.defaultClient().uploadPath(
        path: path,
        filename: filename,
      );
      _groupPicUrlC.text = url.trim();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Group picture uploaded.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploadingGroupPic = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadEverything();
  }

  @override
  void dispose() {
    _subjectC.dispose();
    _messageC.dispose();
    _groupNameC.dispose();
    _groupPicUrlC.dispose();
    _memberSearchC.dispose();
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

  Map<String, dynamic> _safeMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  String _scheduleHint(Map<String, dynamic> classMap) {
    final schedule = _safeMap(classMap['schedule']);
    final firstDate = (schedule['first_session_date'] ?? '').toString().trim();

    final sessionsRaw = schedule['sessions'];
    if (sessionsRaw is List) {
      for (final s in sessionsRaw) {
        final m = _safeMap(s);
        final day = (m['day'] ?? '').toString().trim();
        final start = (m['start'] ?? '').toString().trim();
        final end = (m['end'] ?? '').toString().trim();
        final time = [
          if (start.isNotEmpty) start,
          if (end.isNotEmpty) end,
        ].join('-');
        final slot = [
          if (day.isNotEmpty) day,
          if (time.isNotEmpty) time,
        ].join(' ');
        if (slot.isNotEmpty) {
          if (firstDate.isNotEmpty) return '$slot • $firstDate';
          return slot;
        }
      }
    }

    return firstDate;
  }

  Future<void> _loadEverything() async {
    try {
      final meSnap = await widget.db.ref('users/${widget.meUid}').get();
      final meVal = meSnap.value;
      if (meVal is Map) {
        final mm = meVal.map((k, v) => MapEntry(k.toString(), v));
        final fn = (mm['first_name'] ?? mm['firstName'] ?? '')
            .toString()
            .trim();
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
          final fn = (m['first_name'] ?? m['firstName'] ?? '')
              .toString()
              .trim();
          final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
          final email = (m['email'] ?? '').toString().trim();

          final name = ('$fn $ln').trim();
          final display = name.isNotEmpty
              ? name
              : (email.isNotEmpty ? email : uid.toString());

          final u = uid.toString();
          nameByUid[u] = display;

          if (role == 'admin') {
            admins.add(
              _RecipientRow(uid: u, name: display, type: _RecipientType.admin),
            );
          } else if (role == 'teacher' && u != widget.meUid) {
            teachers.add(
              _RecipientRow(
                uid: u,
                name: display,
                type: _RecipientType.teacher,
              ),
            );
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

          final title =
              (c['course_title'] ?? c['courseTitle'] ?? c['name'] ?? classId)
                  .toString()
                  .trim();
          final classCode = (c['course_code'] ?? c['courseCode'] ?? '')
              .toString()
              .trim();
          final learnersMap = _safeMap(c['learners']);
          final learnersCount = learnersMap.length;
          final scheduleHint = _scheduleHint(c);

          final detailParts = <String>[
            if (classCode.isNotEmpty) classCode,
            'ID: ${classId.toString()}',
            if (learnersCount > 0) '$learnersCount learners',
            if (scheduleHint.isNotEmpty) scheduleHint,
          ];

          myClasses.add(
            _ClassRow(
              classId: classId.toString(),
              title: title.isEmpty ? classId.toString() : title,
              subtitle: detailParts.join(' • '),
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

      myClasses.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );

      if (!mounted) return;
      setState(() {
        _recipients = all;
        _picked = all.isNotEmpty ? all.first : null;

        _pickedRecipientUids.clear();
        if (_picked != null) {
          _pickedRecipientUids.add(_picked!.uid);
        }

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
      final selected = _recipients
          .where((r) => _pickedRecipientUids.contains(r.uid))
          .toList();

      if (selected.isEmpty) return;

      Navigator.pop(
        context,
        _ComposeResult(
          mode: _ComposeMode.single,
          teacherName: _teacherName,
          subject: subject,
          firstMessage: msg,
          receiverUid: selected.length == 1 ? selected.first.uid : null,
          receiverName: selected.length == 1 ? selected.first.name : null,
          receiverUids: selected.map((e) => e.uid).toList(),
          classId: null,
          groupName: null,
          groupPicUrl: null,
        ),
      );
      return;
    }

    if (_mode == _ComposeMode.group) {
      final selected = _recipients
          .where((r) => _pickedRecipientUids.contains(r.uid))
          .toList();
      if (selected.isEmpty) return;
      final gName = _groupNameC.text.trim();
      if (gName.isEmpty) return;
      Navigator.pop(
        context,
        _ComposeResult(
          mode: _ComposeMode.group,
          teacherName: _teacherName,
          subject: subject,
          firstMessage: msg,
          receiverUid: null,
          receiverName: null,
          receiverUids: selected.map((e) => e.uid).toList(),
          classId: null,
          groupName: gName,
          groupPicUrl: _groupPicUrlC.text.trim(),
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
        receiverUids: null,
        classId: c.classId,
        groupName: null,
        groupPicUrl: null,
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
      padding: EdgeInsets.fromLTRB(14, 6, 14, 12 + bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              Text(
                _mode == _ComposeMode.group ? 'Create group mail' : 'New topic',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
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
                    color: scheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SegmentedButton<_ComposeMode>(
                    segments: const [
                      ButtonSegment(
                        value: _ComposeMode.single,
                        label: Text('Single'),
                      ),
                      ButtonSegment(
                        value: _ComposeMode.classGroup,
                        label: Text('Whole class'),
                      ),
                      ButtonSegment(
                        value: _ComposeMode.group,
                        label: Text('Group'),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                ),
                const SizedBox(height: 10),
                if (_mode == _ComposeMode.single || _mode == _ComposeMode.group)
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.35),
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _mode == _ComposeMode.group
                              ? 'Group members'
                              : 'Send to',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 6),
                        if (_recipients.isEmpty)
                          const Text('No recipients found.')
                        else ...[
                          Row(
                            children: [
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _pickedRecipientUids
                                      ..clear()
                                      ..addAll(_recipients.map((e) => e.uid));
                                  });
                                },
                                child: const Text('Select all'),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _pickedRecipientUids.clear();
                                  });
                                },
                                child: const Text('Clear'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            controller: _memberSearchC,
                            onChanged: (v) => setState(
                              () => _memberQuery = v.trim().toLowerCase(),
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Search member name',
                              prefixIcon: Icon(Icons.search_rounded, size: 20),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 190),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _recipients.where((r) {
                                if (_memberQuery.isEmpty) return true;
                                return r.name.toLowerCase().contains(
                                  _memberQuery,
                                );
                              }).length,
                              itemBuilder: (context, index) {
                                final filtered = _recipients.where((r) {
                                  if (_memberQuery.isEmpty) return true;
                                  return r.name.toLowerCase().contains(
                                    _memberQuery,
                                  );
                                }).toList();
                                final r = filtered[index];
                                final checked = _pickedRecipientUids.contains(
                                  r.uid,
                                );

                                return CheckboxListTile(
                                  value: checked,
                                  dense: true,
                                  visualDensity: const VisualDensity(
                                    horizontal: -2,
                                    vertical: -3,
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: Text('${prefixFor(r.type)}${r.name}'),
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _pickedRecipientUids.add(r.uid);
                                        _picked = r;
                                      } else {
                                        _pickedRecipientUids.remove(r.uid);
                                        if (_picked?.uid == r.uid) {
                                          _picked = _recipients
                                              .where(
                                                (x) => _pickedRecipientUids
                                                    .contains(x.uid),
                                              )
                                              .cast<_RecipientRow?>()
                                              .firstWhere(
                                                (x) => x != null,
                                                orElse: () => null,
                                              );
                                        }
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                else
                  DropdownButtonFormField<_ClassRow>(
                    initialValue: _pickedClass,
                    isExpanded: true,
                    items: _classes.map((c) {
                      return DropdownMenuItem<_ClassRow>(
                        value: c,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '👥 ${c.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              c.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurface.withValues(alpha: 0.68),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    selectedItemBuilder: (context) {
                      return _classes
                          .map(
                            (c) => Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '👥 ${c.title} • ${c.subtitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          )
                          .toList();
                    },
                    onChanged: (v) => setState(() => _pickedClass = v),
                    decoration: InputDecoration(
                      labelText: 'Class',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                if (_mode == _ComposeMode.group) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _groupNameC,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Group name',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _uploadingGroupPic
                          ? null
                          : _uploadGroupPicture,
                      icon: _uploadingGroupPic
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file_rounded),
                      label: const Text('Upload group picture'),
                    ),
                  ),
                  if (_groupPicUrlC.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      _groupPicUrlC.text.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 8),
                TextFormField(
                  controller: _subjectC,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: _mode == _ComposeMode.group
                        ? 'Subject'
                        : 'Topic / Subject',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _messageC,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    labelText: _mode == _ComposeMode.group
                        ? 'First message'
                        : 'Mail message',
                    alignLabelWithHint: true,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _submit,
                    icon: const Icon(Icons.send_rounded),
                    label: Text(
                      _mode == _ComposeMode.classGroup
                          ? 'Send to class'
                          : _mode == _ComposeMode.group
                          ? 'Create group'
                          : 'Create and send',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
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

enum _ComposeMode { single, classGroup, group }

enum _RecipientType { admin, teacher, learner }

class _RecipientRow {
  _RecipientRow({required this.uid, required this.name, required this.type});
  final String uid;
  final String name;
  final _RecipientType type;
}

class _ClassRow {
  _ClassRow({
    required this.classId,
    required this.title,
    required this.subtitle,
  });
  final String classId;
  final String title;
  final String subtitle;
}

class _ComposeResult {
  _ComposeResult({
    required this.mode,
    required this.teacherName,
    required this.subject,
    required this.firstMessage,
    required this.receiverUid,
    required this.receiverName,
    required this.receiverUids,
    required this.classId,
    required this.groupName,
    required this.groupPicUrl,
  });

  final _ComposeMode mode;
  final String teacherName;
  final String subject;
  final String firstMessage;
  final String? receiverUid;
  final String? receiverName;
  final List<String>? receiverUids;
  final String? classId;
  final String? groupName;
  final String? groupPicUrl;
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
    required this.type,
    required this.homeworkRef,
    required this.isGroup,
    required this.groupName,
    required this.groupPicUrl,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final int? deletedAtMs;
  final String type;
  final String homeworkRef;
  final bool isGroup;
  final String groupName;
  final String groupPicUrl;

  bool get isHomework {
    if (type.toLowerCase() == 'homework') return true;
    if (homeworkRef.trim().isNotEmpty) return true;
    final s = subject.trim().toLowerCase();
    if (s.startsWith('[hw]')) return true;
    return false;
  }

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

    final subject = (m['subject'] ?? '').toString();
    final homeworkRef = (m['homeworkRef'] ?? '').toString().trim();
    final typeRaw = (m['type'] ?? '').toString().trim().toLowerCase();
    final inferredType = (typeRaw.isNotEmpty)
        ? typeRaw
        : (homeworkRef.isNotEmpty ||
                  subject.trim().toLowerCase().startsWith('[hw]')
              ? 'homework'
              : 'mail');

    return _TopicRow(
      threadId: threadId,
      peerUid: (m['peerUid'] ?? '').toString(),
      peerName: (m['peerName'] ?? '').toString(),
      subject: subject,
      lastMessage: (m['lastMessage'] ?? '').toString(),
      updatedAtMs: toInt(m['updatedAt']),
      unreadCount: toInt(m['unreadCount'] ?? m['unread']),
      deletedAtMs: toIntN(m['deletedAt']),
      type: inferredType,
      homeworkRef: homeworkRef,
      isGroup: m['isGroup'] == true,
      groupName: (m['groupName'] ?? '').toString(),
      groupPicUrl: (m['groupPicUrl'] ?? '').toString(),
    );
  }
}
