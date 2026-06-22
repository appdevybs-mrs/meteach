import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../services/push_dispatch_service.dart';
import '../shared/ui_constants.dart';
import '../shared/learner_web_layout.dart';
import '../shared/responsive_layout.dart';
import '../shared/watermark_background.dart';
import 'learner_mail_thread_screen.dart';
import '../shared/learner_notice_popup.dart';
import '../shared/profile_avatar.dart';

class LearnerMailScreen extends StatefulWidget {
  const LearnerMailScreen({super.key});

  @override
  State<LearnerMailScreen> createState() => _LearnerMailScreenState();
}

class _LearnerMailScreenState extends State<LearnerMailScreen>
    with SingleTickerProviderStateMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final Map<String, String> _photoCache = {};
  final Map<String, Future<void>> _userFetchPending = {};
  final Set<String> _selfHealInFlight = <String>{};

  Color get _navy => UiK.primaryBlue;
  Color get _orange => UiK.actionOrange;
  Color get _navyDark => UiK.primaryBlue.withValues(alpha: 0.92);
  Color get _hwAccent => const Color(0xFF0E8B76);

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';
  late final TabController _tabController;
  String? _desktopSelectedThreadId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!mounted || _tabController.indexIsChanging) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  String _short(String s, int max) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    if (max <= 1) return '…';
    return '${t.substring(0, max - 1)}…';
  }

  String _reportPreview(String raw) {
    try {
      final parsed = jsonDecode(raw.trim());
      if (parsed is Map) {
        final month = (parsed['month'] ?? '').toString().trim();
        if (month.isNotEmpty) return '📋 $month';
      }
    } catch (_) {}
    return _short(raw, 90);
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _snack(String msg) {
    if (!mounted) return;
    unawaited(
      showLearnerNoticePopup(
        context,
        message: msg,
        tone: learnerNoticeToneForMessage(msg),
      ),
    );
  }

  Future<void> _ensureUserPhotoCached(String uid) {
    uid = uid.trim();
    if (uid.isEmpty) return Future.value();
    if (_photoCache.containsKey(uid)) return Future.value();

    final pending = _userFetchPending[uid];
    if (pending != null) return pending;

    final fut = () async {
      try {
        final snap = await _db.child('users/$uid').get();
        String photo = '';
        if (snap.value is Map) {
          photo = ProfileAvatar.resolvePhotoFromMap(snap.value as Map);
        }
        final changed = _photoCache[uid] != photo;
        _photoCache[uid] = photo;
        if (changed && mounted) setState(() {});
      } catch (_) {
        _photoCache.putIfAbsent(uid, () => '');
      } finally {
        _userFetchPending.remove(uid);
      }
    }();

    _userFetchPending[uid] = fut;
    return fut;
  }

  String _bestPhoto(String uid) => _photoCache[uid.trim()] ?? '';

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
      final now = _nowMs();
      await _db.child('mail_index/$_meUid/${row.threadId}').update({
        'deletedAt': now,
      });
      await _db.child('mail_state/$_meUid/${row.threadId}').remove();
      _snack('Deleted for you.');
    } catch (e) {
      _snack('Could not delete this topic: $e');
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

    if (action == 'open') {
      final peerName = row.peerName.trim().isEmpty
          ? 'User'
          : row.peerName.trim();
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LearnerMailThreadScreen(
            threadId: row.threadId,
            peerUid: row.peerUid,
            peerName: peerName,
            subject: row.subject,
          ),
        ),
      );
    }
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

  int _toIntAny(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Future<void> _selfHealIndexRow(
    String threadId,
    Map<String, dynamic> row,
  ) async {
    final meUid = _meUid.trim();
    if (meUid.isEmpty) return;
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
        final tSnap = await _db.child('mail_threads/$threadId').get();
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
            await _db.child('mail_threads/$threadId').update(threadUpdates);
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
        await _db.child('mail_index/$meUid/$threadId').update(idxUpdates);
      }
    } catch (_) {
      // best-effort migration only
    } finally {
      _selfHealInFlight.remove(threadId);
    }
  }

  bool _isHomeworkRow(_TopicRow r) {
    if (r.type.trim().toLowerCase() == 'report') return false;
    final type = r.type.trim().toLowerCase();
    if (type == 'homework') return true;
    if (r.homeworkRef.trim().isNotEmpty) return true;
    return r.subject.trim().toLowerCase().startsWith('[hw]');
  }

  List<_TopicRow> _parse(dynamic v) {
    if (v is! Map) return [];
    final out = <_TopicRow>[];

    void addIfThreadObject(String threadId, Map obj) {
      final m = obj.map((kk, vvv) => MapEntry(kk.toString(), vvv));
      unawaited(_selfHealIndexRow(threadId, m));
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
            final innerMap = innerV.map(
              (kk, vvv) => MapEntry(kk.toString(), vvv),
            );
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
          'mail_threads/$threadId/type': 'mail',
          'mail_threads/$threadId/createdAt': now,
          'mail_threads/$threadId/updatedAt': now,
          'mail_threads/$threadId/lastMessage': placeholderLastMessage,
          'mail_threads/$threadId/participants/$meUid': true,
          'mail_threads/$threadId/participants/$toUid': true,

          'mail_index/$meUid/$threadId/subject': subject,
          'mail_index/$meUid/$threadId/type': 'mail',
          'mail_index/$meUid/$threadId/updatedAt': now,
          'mail_index/$meUid/$threadId/lastMessage': placeholderLastMessage,
          'mail_index/$meUid/$threadId/unreadCount': 0,
          'mail_index/$meUid/$threadId/peerUid': toUid,
          'mail_index/$meUid/$threadId/peerName': toName,
          'mail_index/$meUid/$threadId/peerRole': 'unknown',
          'mail_index/$meUid/$threadId/deletedAt': null,

          'mail_index/$toUid/$threadId/subject': subject,
          'mail_index/$toUid/$threadId/type': 'mail',
          'mail_index/$toUid/$threadId/updatedAt': now,
          'mail_index/$toUid/$threadId/lastMessage': placeholderLastMessage,
          'mail_index/$toUid/$threadId/unreadCount': 1,
          'mail_index/$toUid/$threadId/peerUid': meUid,
          'mail_index/$toUid/$threadId/peerName': myName,
          'mail_index/$toUid/$threadId/peerRole': 'learner',
          'mail_index/$toUid/$threadId/deletedAt': null,
          'mail_state/$meUid/$threadId/lastReadAt': now,
          'mail_state/$meUid/$threadId/lastDeliveredAt': now,
          'mail_state/$toUid/$threadId/lastDeliveredAt': now,
        };

        await _db.update(updates);
        unawaited(() async {
          try {
            await PushDispatchService.dispatchMailToUser(
              targetUid: toUid,
              threadId: threadId,
              peerUid: meUid,
              title: subject,
              preview: 'New topic',
              nowMs: now,
              context: const PushDispatchContext(
                screen: 'learner/learner_mail',
                action: 'mail_push',
              ),
            );
          } catch (_) {}
        }());
        return threadId;
      }

      final myName = picked.myName.trim().isEmpty
          ? 'Learner'
          : picked.myName.trim();

      if (picked.mode == _LearnerComposeMode.single) {
        final selectedUids = picked.receiverUids ?? const <String>[];
        final targets = selectedUids
            .map((u) => u.trim())
            .where((u) => u.isNotEmpty && u != meUid)
            .toSet()
            .toList();

        if (targets.isEmpty) {
          _snack('Pick at least one receiver.');
          return;
        }

        String? firstThreadId;
        String? firstUid;
        String firstName = '';
        int sent = 0;

        for (final toUid in targets) {
          final toName = (picked.nameByUid[toUid] ?? '').trim();

          final threadId = await create1to1(
            toUid: toUid,
            toName: toName.isEmpty ? 'User' : toName,
            myName: myName,
          );

          firstThreadId ??= threadId;
          firstUid ??= toUid;
          if (firstName.isEmpty) {
            firstName = toName.isEmpty ? 'User' : toName;
          }
          sent++;
        }

        if (!mounted) return;
        if (sent == 1 && firstThreadId != null && firstUid != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              settings: RouteSettings(name: '/mail/thread/$firstThreadId'),
              builder: (_) => LearnerMailThreadScreen(
                threadId: firstThreadId!,
                peerUid: firstUid!,
                peerName: firstName,
                subject: subject,
              ),
            ),
          );
        } else {
          _snack('Created $sent topic(s) ✅');
        }
        return;
      }

      if (picked.mode == _LearnerComposeMode.classGroup) {
        final classId = picked.classId?.trim() ?? '';
        if (classId.isEmpty) {
          _snack('Pick a class.');
          return;
        }

        final classmates = picked.classmateUidsByClass[classId] ?? <String>[];
        final targets = classmates
            .where((u) => u.trim().isNotEmpty && u.trim() != meUid)
            .toList();

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

  Future<void> _openThread(_TopicRow row, {required bool desktop}) async {
    if (desktop) {
      setState(() => _desktopSelectedThreadId = row.threadId);
      return;
    }

    final peerName = row.peerName.trim().isEmpty ? 'User' : row.peerName.trim();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LearnerMailThreadScreen(
          threadId: row.threadId,
          peerUid: row.peerUid,
          peerName: peerName,
          subject: row.subject,
        ),
      ),
    );
  }

  _TopicRow? _desktopSelectedRow(List<_TopicRow> rows) {
    if (rows.isEmpty) return null;
    final selectedId = _desktopSelectedThreadId?.trim() ?? '';
    if (selectedId.isNotEmpty) {
      for (final row in rows) {
        if (row.threadId == selectedId) return row;
      }
    }
    return rows.first;
  }

  @override
  Widget build(BuildContext context) {
    final uid = _meUid;
    final ref = _db.child('mail_index/$uid');
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

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
        actions: [
          if (desktopWorkspace && uid.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: _composeNewTopic,
                icon: const Icon(Icons.edit_rounded),
                label: const Text('New message'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Column(
            children: [
              TabBar(
                controller: _tabController,
                labelColor: _navy,
                unselectedLabelColor: _navy.withValues(alpha: 0.58),
                indicatorColor: _orange,
                indicatorWeight: 3,
                tabs: const [
                  Tab(text: 'Individual'),
                  Tab(text: 'Group'),
                ],
              ),
              Container(height: 1, color: _navy.withValues(alpha: 0.14)),
            ],
          ),
        ),
      ),
      floatingActionButton: desktopWorkspace || uid.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _composeNewTopic,
              icon: const Icon(Icons.edit_rounded),
              label: const Text('New message'),
            ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1400,
        child: WatermarkBackground(
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
                    final nonHomeworkRows = rows
                        .where((r) => !_isHomeworkRow(r))
                        .toList();
                    final showingGroups = _tabController.index == 1;
                    final shown = nonHomeworkRows
                        .where((r) => showingGroups ? r.isGroup : !r.isGroup)
                        .toList();

                    shown.sort(
                      (a, b) => b.updatedAtMs.compareTo(a.updatedAtMs),
                    );

                    if (nonHomeworkRows.isEmpty) {
                      return Center(
                        child: Text(
                          'No mail yet.',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: _navyDark,
                          ),
                        ),
                      );
                    }

                    final selectedRow = desktopWorkspace
                        ? _desktopSelectedRow(shown)
                        : null;

                    final inboxBody = Column(
                      children: [
                        Expanded(
                          child: shown.isEmpty
                              ? Center(
                                  child: Text(
                                    showingGroups
                                        ? 'No group conversations yet.'
                                        : 'No individual conversations yet.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: _navyDark,
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    16,
                                  ),
                                  itemCount: shown.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (context, i) {
                                    final r = shown[i];
                                    final isHomework = _isHomeworkRow(r);
                                    final isReport =
                                        r.type.trim().toLowerCase() == 'report';

                                    final peerUid = r.peerUid;
                                    final isGroup = r.isGroup;
                                    if (peerUid.trim().isNotEmpty) {
                                      _ensureUserPhotoCached(peerUid);
                                    }
                                    final peerName = isGroup
                                        ? (r.groupName.trim().isEmpty
                                              ? 'Group conversation'
                                              : r.groupName.trim())
                                        : (r.peerName.trim().isEmpty
                                              ? 'User'
                                              : r.peerName.trim());
                                    final lastMessage = r.lastMessage;
                                    final unread = r.unreadCount;
                                    final updatedAt = r.updatedAtMs;

                                    return InkWell(
                                      borderRadius: BorderRadius.circular(18),
                                      onLongPress: () => _showThreadActions(r),
                                      onTap: () => _openThread(
                                        r,
                                        desktop: desktopWorkspace,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: isReport
                                              ? const Color(0xFFE8F1FB)
                                              : Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                          border: Border.all(
                                            color: isReport
                                                ? const Color(
                                                    0xFF1F4E79,
                                                  ).withValues(alpha: 0.30)
                                                : (isHomework
                                                      ? _hwAccent.withValues(
                                                          alpha: 0.26,
                                                        )
                                                      : _navy.withValues(
                                                          alpha: 0.14,
                                                        )),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            if (isHomework || isReport) ...[
                                              Container(
                                                width: 4,
                                                height: 46,
                                                decoration: BoxDecoration(
                                                  color: isReport
                                                      ? const Color(0xFF1F4E79)
                                                      : _hwAccent.withValues(
                                                          alpha: 0.92,
                                                        ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                            ],
                                            Stack(
                                              clipBehavior: Clip.none,
                                              children: [
                                                isGroup
                                                    ? CircleAvatar(
                                                        radius: 23,
                                                        backgroundColor: Colors
                                                            .indigo
                                                            .withValues(
                                                              alpha: 0.12,
                                                            ),
                                                        foregroundImage:
                                                            r.groupPicUrl
                                                                .trim()
                                                                .isNotEmpty
                                                            ? NetworkImage(
                                                                r.groupPicUrl
                                                                    .trim(),
                                                              )
                                                            : null,
                                                        child:
                                                            r.groupPicUrl
                                                                .trim()
                                                                .isNotEmpty
                                                            ? null
                                                            : const Icon(
                                                                Icons
                                                                    .groups_rounded,
                                                                color: Colors
                                                                    .indigo,
                                                              ),
                                                      )
                                                    : ProfileAvatar(
                                                        name: peerName,
                                                        photoUrl: _bestPhoto(
                                                          peerUid,
                                                        ),
                                                        radius: 23,
                                                        fallbackBg: _navy
                                                            .withValues(
                                                              alpha: 0.10,
                                                            ),
                                                        fallbackFg: isHomework
                                                            ? _hwAccent
                                                            : (isReport
                                                                  ? const Color(
                                                                      0xFF1F4E79,
                                                                    )
                                                                  : _navy.withValues(
                                                                      alpha:
                                                                          0.92,
                                                                    )),
                                                        borderColor: _navy
                                                            .withValues(
                                                              alpha: 0.15,
                                                            ),
                                                      ),
                                                if (unread > 0)
                                                  Positioned(
                                                    right: -8,
                                                    top: -8,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 4,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: _orange,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              999,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        unread > 99
                                                            ? '99+'
                                                            : '$unread',
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.w900,
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
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Text(
                                                          peerName,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            color: _navy,
                                                            fontSize: 15,
                                                          ),
                                                        ),
                                                      ),
                                                      if (isGroup)
                                                        Container(
                                                          margin:
                                                              const EdgeInsets.only(
                                                                right: 8,
                                                              ),
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 8,
                                                                vertical: 2,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color: Colors.indigo
                                                                .withValues(
                                                                  alpha: 0.12,
                                                                ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  999,
                                                                ),
                                                          ),
                                                          child: const Text(
                                                            'Group',
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                              color:
                                                                  Colors.indigo,
                                                            ),
                                                          ),
                                                        ),
                                                      if (isReport)
                                                        Container(
                                                          margin:
                                                              const EdgeInsets.only(
                                                                right: 8,
                                                              ),
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 8,
                                                                vertical: 2,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color:
                                                                const Color(
                                                                  0xFF1F4E79,
                                                                ).withValues(
                                                                  alpha: 0.14,
                                                                ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  999,
                                                                ),
                                                          ),
                                                          child: const Text(
                                                            'Report',
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w900,
                                                              color: Color(
                                                                0xFF1F4E79,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      const SizedBox(width: 10),
                                                      Text(
                                                        updatedAt <= 0
                                                            ? ''
                                                            : _fmt(updatedAt),
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          color: _navy
                                                              .withValues(
                                                                alpha: 0.55,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 6),
                                                  if (r.subject
                                                      .trim()
                                                      .isNotEmpty)
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 10,
                                                            vertical: 6,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: isHomework
                                                            ? _hwAccent
                                                                  .withValues(
                                                                    alpha: 0.12,
                                                                  )
                                                            : (isReport
                                                                  ? const Color(
                                                                      0xFF1F4E79,
                                                                    ).withValues(
                                                                      alpha:
                                                                          0.12,
                                                                    )
                                                                  : _orange.withValues(
                                                                      alpha:
                                                                          0.14,
                                                                    )),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              999,
                                                            ),
                                                        border: Border.all(
                                                          color: isHomework
                                                              ? _hwAccent
                                                                    .withValues(
                                                                      alpha:
                                                                          0.28,
                                                                    )
                                                              : (isReport
                                                                    ? const Color(
                                                                        0xFF1F4E79,
                                                                      ).withValues(
                                                                        alpha:
                                                                            0.24,
                                                                      )
                                                                    : _orange.withValues(
                                                                        alpha:
                                                                            0.24,
                                                                      )),
                                                        ),
                                                      ),
                                                      child: Text(
                                                        _short(r.subject, 60),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          color: isHomework
                                                              ? _hwAccent
                                                                    .withValues(
                                                                      alpha:
                                                                          0.92,
                                                                    )
                                                              : (isReport
                                                                    ? const Color(
                                                                        0xFF1F4E79,
                                                                      )
                                                                    : _navyDark),
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    isReport
                                                        ? _reportPreview(
                                                            lastMessage,
                                                          )
                                                        : lastMessage
                                                              .trim()
                                                              .isEmpty
                                                        ? '—'
                                                        : _short(
                                                            lastMessage,
                                                            90,
                                                          ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w400,
                                                      color: _navy.withValues(
                                                        alpha: 0.62,
                                                      ),
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Icon(
                                              Icons.chevron_right_rounded,
                                              color: isHomework
                                                  ? _hwAccent.withValues(
                                                      alpha: 0.78,
                                                    )
                                                  : (isReport
                                                        ? const Color(
                                                            0xFF1F4E79,
                                                          ).withValues(
                                                            alpha: 0.85,
                                                          )
                                                        : _orange.withValues(
                                                            alpha: 0.85,
                                                          )),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    );

                    if (!desktopWorkspace) return inboxBody;

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 5, child: inboxBody),
                        Container(
                          width: 1,
                          color: _navy.withValues(alpha: 0.10),
                        ),
                        Expanded(
                          flex: 6,
                          child: selectedRow == null
                              ? Center(
                                  child: Text(
                                    'Select a conversation to use the larger desktop workspace.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: _navyDark,
                                    ),
                                  ),
                                )
                              : LearnerMailThreadScreen(
                                  key: ValueKey(
                                    'desktop_learner_mail_${selectedRow.threadId}',
                                  ),
                                  threadId: selectedRow.threadId,
                                  peerUid: selectedRow.peerUid,
                                  peerName: selectedRow.peerName.trim().isEmpty
                                      ? 'User'
                                      : selectedRow.peerName.trim(),
                                  subject: selectedRow.subject,
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

enum _LearnerComposeMode { single, classGroup }

enum _LearnerRecipientType { admin, teacher, classmate }

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
    required this.receiverUids,
    required this.classId,
    required this.classmateUidsByClass,
    required this.nameByUid,
  });

  final _LearnerComposeMode mode;
  final String subject;
  final String myName;

  final List<String>? receiverUids;

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
  final Set<String> _pickedRecipientUids = <String>{};

  List<_LearnerClassRow> _classes = [];
  _LearnerClassRow? _pickedClass;

  final Map<String, String> _nameByUid = {};
  final Set<String> _teacherUids = <String>{};
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

  IconData _recipientIcon(_LearnerRecipientType t) {
    if (t == _LearnerRecipientType.admin) {
      return Icons.admin_panel_settings_rounded;
    }
    if (t == _LearnerRecipientType.teacher) {
      return Icons.school_rounded;
    }
    return Icons.person_rounded;
  }

  String _recipientSubtitle(_LearnerRecipientType t) {
    if (t == _LearnerRecipientType.admin) return 'Administration';
    if (t == _LearnerRecipientType.teacher) return 'Teacher';
    return 'Classmate';
  }

  Color _recipientTint(_LearnerRecipientType t) {
    if (t == _LearnerRecipientType.admin) {
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
        final m = (meSnap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
        final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
        final email = (m['email'] ?? '').toString().trim();
        final full = ('$fn $ln').trim();
        _myName = full.isNotEmpty
            ? full
            : (email.isNotEmpty ? email : 'Learner');
      }

      final usersSnap = await widget.db.child('users').get();
      final usersVal = usersSnap.value;
      final adminRecipients = <_LearnerRecipientRow>[];
      final teacherRecipients = <_LearnerRecipientRow>[];

      _teacherUids.clear();

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
          final full = ('$fn $ln').trim();
          final display = full.isNotEmpty
              ? full
              : (email.isNotEmpty ? email : uid.toString());

          final u = uid.toString();
          _nameByUid[u] = display;

          if (role == 'admin') {
            if (u == widget.meUid) return;
            adminRecipients.add(
              _LearnerRecipientRow(
                uid: u,
                name: display,
                type: _LearnerRecipientType.admin,
              ),
            );
            return;
          }

          if (role == 'teacher') {
            if (u == widget.meUid) return;
            _teacherUids.add(u);
            teacherRecipients.add(
              _LearnerRecipientRow(
                uid: u,
                name: display,
                type: _LearnerRecipientType.teacher,
              ),
            );
          }
        });
      }

      final classesSnap = await widget.db.child('classes').get();
      final classesVal = classesSnap.value;

      final classmates = <String>{};
      final myClasses = <_LearnerClassRow>[];

      if (classesVal is Map) {
        classesVal.forEach((classId, classVal) {
          if (classId == null || classVal == null || classVal is! Map) return;
          final c = classVal.map((k, v) => MapEntry(k.toString(), v));

          final learners = c['learners'];
          bool imIn = false;
          if (learners is Map) {
            imIn =
                learners.containsKey(widget.meUid) ||
                learners[widget.meUid] == true;
          }
          if (!imIn) return;

          final title =
              (c['course_title'] ?? c['courseTitle'] ?? c['name'] ?? classId)
                  .toString()
                  .trim();
          myClasses.add(
            _LearnerClassRow(
              classId: classId.toString(),
              title: title.isEmpty ? classId.toString() : title,
            ),
          );

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

      myClasses.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );

      final all = <_LearnerRecipientRow>[];

      all.addAll(adminRecipients);
      all.addAll(teacherRecipients);

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
        if (t == _LearnerRecipientType.admin) return 0;
        if (t == _LearnerRecipientType.teacher) return 1;
        return 2;
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
        _pickedRecipientUids.clear();
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
      final selected = _recipients
          .where((r) => _pickedRecipientUids.contains(r.uid))
          .toList();
      if (selected.isEmpty) return;

      Navigator.pop(
        context,
        _LearnerComposeResult(
          mode: _LearnerComposeMode.single,
          subject: subject,
          myName: _myName,
          receiverUids: selected.map((e) => e.uid).toList(),
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
        receiverUids: null,
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
            color: tint.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tint.withValues(alpha: 0.18)),
          ),
          child: Icon(
            _recipientIcon(r.type),
            color: tint.withValues(alpha: 0.95),
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
                r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _recipientSubtitle(r.type),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.black.withValues(alpha: 0.58),
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
            color: Colors.indigo.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.indigo.withValues(alpha: 0.16)),
          ),
          child: Icon(
            Icons.groups_rounded,
            color: Colors.indigo.withValues(alpha: 0.95),
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
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Whole class',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: Colors.black.withValues(alpha: 0.58),
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
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.14),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Send to',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        if (_recipients.isEmpty)
                          const Text('No recipients found.')
                        else ...[
                          Row(
                            children: [
                              TextButton(
                                onPressed: _teacherUids.isEmpty
                                    ? null
                                    : () {
                                        setState(() {
                                          _pickedRecipientUids.addAll(
                                            _teacherUids,
                                          );
                                        });
                                      },
                                child: const Text('All teachers'),
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
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 260),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _recipients.length,
                              itemBuilder: (context, index) {
                                final r = _recipients[index];
                                final checked = _pickedRecipientUids.contains(
                                  r.uid,
                                );
                                return CheckboxListTile(
                                  value: checked,
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: _buildRecipientItem(r),
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _pickedRecipientUids.add(r.uid);
                                      } else {
                                        _pickedRecipientUids.remove(r.uid);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_pickedRecipientUids.length} selected',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: Colors.black.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                else
                  DropdownButtonFormField<_LearnerClassRow>(
                    initialValue: _pickedClass,
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
                      _mode == _LearnerComposeMode.classGroup
                          ? 'Create class topics'
                          : 'Create topic',
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
    required this.type,
    required this.subject,
    required this.lastMessage,
    required this.updatedAtMs,
    required this.unreadCount,
    required this.deletedAtMs,
    required this.homeworkRef,
    required this.isGroup,
    required this.groupName,
    required this.groupPicUrl,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String type;
  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final int? deletedAtMs;
  final String homeworkRef;
  final bool isGroup;
  final String groupName;
  final String groupPicUrl;

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
      type: (m['type'] ?? '').toString(),
      subject: (m['subject'] ?? '').toString(),
      lastMessage: (m['lastMessage'] ?? '').toString(),
      updatedAtMs: toInt(m['updatedAt']),
      unreadCount: toInt(m['unreadCount'] ?? m['unread']),
      deletedAtMs: toIntN(m['deletedAt']),
      homeworkRef: (m['homeworkRef'] ?? '').toString(),
      isGroup: m['isGroup'] == true,
      groupName: (m['groupName'] ?? '').toString(),
      groupPicUrl: (m['groupPicUrl'] ?? '').toString(),
    );
  }
}
