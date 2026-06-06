import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/mail_consistency_service.dart';
import '../services/homework_review_sync_service.dart';
import '../services/internal_mail_service.dart';
import '../services/push_dispatch_service.dart';
import '../services/mail_thread_by_id_screen.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import 'admin_mail_person_list_navigation.dart';
import 'mail_topic_thread_screen.dart';

class AdminMailInboxScreen extends StatefulWidget {
  const AdminMailInboxScreen({super.key});

  @override
  State<AdminMailInboxScreen> createState() => _AdminMailInboxScreenState();
}

class _AdminMailInboxScreenState extends State<AdminMailInboxScreen> {
  static const Color _personNameColor = Color(0xFF616161);

  final _db = FirebaseDatabase.instance;
  final _searchC = TextEditingController();

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  DatabaseReference get _indexRef => _db.ref('mail_index/$_meUid');
  DatabaseReference get _stateRef => _db.ref('mail_state/$_meUid');

  late final Stream<DatabaseEvent> _stream;
  bool _repairInProgress = false;
  bool _didInitialRepair = false;
  bool _groupBackfillRunning = false;
  bool _homeworkReviewBackfillRunning = false;
  _AdminMailFilter _filter = _AdminMailFilter.all;
  _AdminInboxTab _tab = _AdminInboxTab.mail;
  final Map<String, String> _peerRoleCache = <String, String>{};

  @override
  void initState() {
    super.initState();
    _stream = _indexRef.onValue.asBroadcastStream();
    _runIntegritySweepOnce();
    _runGroupBackfillOnce();
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  void _snack(String s) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, SnackBar(content: Text(s)));
  }

  Future<void> _deleteForMe(String threadId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _stateRef.child(threadId).update({'deletedAt': now});
    await _indexRef.child(threadId).remove();
    _snack('Deleted (only for you) ✅');
  }

  Future<void> _runIntegritySweepOnce() async {
    if (_repairInProgress || _didInitialRepair) return;
    final uid = _meUid.trim();
    if (uid.isEmpty) return;

    _repairInProgress = true;
    try {
      await MailConsistencyService.runAdminInboxIntegritySweep(
        db: _db,
        adminUid: uid,
      );
    } catch (_) {
      // Keep UI responsive.
    } finally {
      _repairInProgress = false;
      _didInitialRepair = true;
    }
  }

  Future<void> _runGroupBackfillOnce() async {
    if (_groupBackfillRunning) return;
    _groupBackfillRunning = true;
    try {
      final markerRef = _db.ref('appConfig/mail/groupIndexBackfillV1');
      final markerSnap = await markerRef.get();
      final marker = markerSnap.value is Map
          ? (markerSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final doneAt = MailConsistencyService.toInt(marker['doneAt']);
      if (doneAt > 0) return;

      final touched = await MailConsistencyService.runGroupIndexBackfill(
        db: _db,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      await markerRef.update({
        'doneAt': now,
        'doneByUid': _meUid,
        'touchedRows': touched,
      });
      if (!mounted) return;
      _snack('Group mail backfill completed ($touched repaired).');
    } catch (_) {
      // Keep inbox responsive even if migration check fails.
    } finally {
      _groupBackfillRunning = false;
    }
  }

  Future<void> _runHomeworkReviewBackfill() async {
    if (_homeworkReviewBackfillRunning) return;

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Repair old homework reviews?'),
            content: const Text(
              'This scans homework mail threads and fills missing review fields only when an old evaluation message is detected. Already reviewed homework is not overwritten.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.build_circle_rounded),
                label: const Text('Run repair'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    setState(() => _homeworkReviewBackfillRunning = true);
    try {
      final result = await HomeworkReviewSyncService.runBulkReviewBackfill(
        db: _db,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      await _db.ref('appConfig/homework/reviewBackfillV1').update({
        'lastRunAt': now,
        'lastRunByUid': _meUid,
        ...result.toMap(),
      });
      if (!mounted) return;
      _snack(
        'Homework repair complete: ${result.repaired} repaired, ${result.homeworkThreads} homework threads checked.',
      );
    } catch (e) {
      if (!mounted) return;
      _snack('Homework repair failed: $e');
    } finally {
      if (mounted) {
        setState(() => _homeworkReviewBackfillRunning = false);
      }
    }
  }

  Future<List<Map<String, String>>> _loadRecipients() async {
    final snap = await _db.ref('users').get();
    final raw = snap.value;
    if (raw is! Map) return const [];
    final out = <Map<String, String>>[];
    raw.forEach((uid, vv) {
      if (uid == null || vv is! Map) return;
      final m = vv.map((k, v) => MapEntry(k.toString(), v));
      final id = uid.toString().trim();
      if (id.isEmpty || id == _meUid) return;
      final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final email = (m['email'] ?? '').toString().trim();
      final role = MailConsistencyService.normalizeRole(m['role']);
      final name = ('$fn $ln').trim();
      out.add({
        'uid': id,
        'name': name.isEmpty ? (email.isEmpty ? id : email) : name,
        'role': role,
      });
    });
    out.sort(
      (a, b) => (a['name'] ?? '').toLowerCase().compareTo(
        (b['name'] ?? '').toLowerCase(),
      ),
    );
    return out;
  }

  Future<void> _openCreateGroup() async {
    final recipients = await _loadRecipients();
    if (!mounted) return;
    if (recipients.isEmpty) {
      _snack('No recipients available.');
      return;
    }

    final subjectC = TextEditingController();
    final groupNameC = TextEditingController();
    final bodyC = TextEditingController();
    final memberSearchC = TextEditingController();
    String groupPicUrl = '';
    String memberQuery = '';
    final picked = <String>{};
    var uploading = false;
    var submitting = false;

    Future<void> uploadGroupPic(StateSetter setLocal) async {
      if (uploading) return;
      if (kIsWeb) {
        _snack('Group picture upload is not supported on web yet.');
        return;
      }
      final file = await FilePicker.platform.pickFiles(withData: false);
      final path = file?.files.single.path;
      if (path == null || path.trim().isEmpty) return;
      setLocal(() => uploading = true);
      try {
        final url = await MailUploadClient.defaultClient().uploadFile(
          file: File(path),
        );
        setLocal(() => groupPicUrl = url.trim());
      } catch (e) {
        _snack('Upload failed: $e');
      } finally {
        if (mounted) setLocal(() => uploading = false);
      }
    }

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) {
          final bottom =
              MediaQuery.of(ctx).viewInsets.bottom +
              MediaQuery.of(ctx).padding.bottom;
          return StatefulBuilder(
            builder: (ctx, setLocal) {
              final filtered = recipients.where((r) {
                if (memberQuery.isEmpty) return true;
                final name = (r['name'] ?? '').toLowerCase();
                return name.contains(memberQuery);
              }).toList();
              return Padding(
                padding: EdgeInsets.fromLTRB(14, 6, 14, 12 + bottom),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Create group mail',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: groupNameC,
                        decoration: const InputDecoration(
                          labelText: 'Group name',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: subjectC,
                        decoration: const InputDecoration(
                          labelText: 'Subject',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: bodyC,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'First message',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: uploading
                            ? null
                            : () => uploadGroupPic(setLocal),
                        icon: uploading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.upload_file_rounded),
                        label: const Text('Upload group picture'),
                      ),
                      if (groupPicUrl.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          groupPicUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(ctx).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      const Text(
                        'Members',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: memberSearchC,
                        onChanged: (v) => setLocal(
                          () => memberQuery = v.trim().toLowerCase(),
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
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final r = filtered[i];
                            final uid = r['uid'] ?? '';
                            final checked = picked.contains(uid);
                            return CheckboxListTile(
                              value: checked,
                              dense: true,
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -3,
                              ),
                              contentPadding: EdgeInsets.zero,
                              title: Text('${r['name']} • ${r['role']}'),
                              onChanged: (v) => setLocal(() {
                                if (v == true) {
                                  picked.add(uid);
                                } else {
                                  picked.remove(uid);
                                }
                              }),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: submitting
                              ? null
                              : () async {
                                  final groupName = groupNameC.text.trim();
                                  final subject = subjectC.text.trim();
                                  final body = bodyC.text.trim();
                                  if (groupName.isEmpty ||
                                      subject.isEmpty ||
                                      body.isEmpty) {
                                    _snack(
                                      'Please fill group name, subject, and first message.',
                                    );
                                    return;
                                  }
                                  if (picked.isEmpty) {
                                    _snack(
                                      'Please select at least one member.',
                                    );
                                    return;
                                  }
                                  setLocal(() => submitting = true);
                                  try {
                                    final now =
                                        DateTime.now().millisecondsSinceEpoch;
                                    final threadId =
                                        await InternalMailService.createGroupThread(
                                          creatorUid: _meUid,
                                          creatorName: 'Admin',
                                          creatorRole: 'admin',
                                          participantUids: picked,
                                          groupName: groupName,
                                          groupPicUrl: groupPicUrl,
                                          subject: subject,
                                          now: now,
                                        );
                                    await InternalMailService.sendGroupMessage(
                                      threadId: threadId,
                                      senderUid: _meUid,
                                      body: body,
                                    );
                                    final preview = body.trim().length > 80
                                        ? body.trim().substring(0, 80)
                                        : body.trim();
                                    unawaited(() async {
                                      try {
                                        await PushDispatchService.dispatchMailToGroup(
                                          threadId: threadId,
                                          senderUid: _meUid,
                                          senderName: 'Admin',
                                          title: subject,
                                          preview: preview.isEmpty
                                              ? 'New group message'
                                              : preview,
                                          nowMs: now,
                                          context: const PushDispatchContext(
                                            screen: 'admin/admin_mail_inbox',
                                            action: 'mail_push_group',
                                          ),
                                        );
                                      } catch (_) {}
                                    }());
                                    if (!mounted) return;
                                    if (ctx.mounted) {
                                      Navigator.pop(ctx);
                                    }
                                    _snack('Group created successfully.');
                                  } catch (e) {
                                    _snack('Failed to create group: $e');
                                  } finally {
                                    if (mounted) {
                                      setLocal(() => submitting = false);
                                    }
                                  }
                                },
                          icon: const Icon(Icons.groups_rounded),
                          label: const Text('Create group'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: submitting
                              ? null
                              : () {
                                  if (ctx.mounted) {
                                    Navigator.pop(ctx);
                                  }
                                },
                          child: const Text('Cancel'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      subjectC.dispose();
      groupNameC.dispose();
      bodyC.dispose();
      memberSearchC.dispose();
    }
  }

  List<_InboxRow> _parse(dynamic data) {
    if (data is! Map) return [];
    final out = <_InboxRow>[];
    data.forEach((k, v) {
      if (k == null || v == null) return;
      if (v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      if (m['deletedAt'] != null) return;
      out.add(_InboxRow(threadId: k.toString(), item: _InboxItem.fromMap(m)));
    });

    final seen = <String>{};
    final unique = <_InboxRow>[];
    for (final row in out) {
      if (seen.contains(row.threadId)) continue;
      seen.add(row.threadId);
      unique.add(row);
    }

    unique.sort((a, b) => b.item.updatedAtMs.compareTo(a.item.updatedAtMs));
    return unique;
  }

  List<_InboxRow> _applyFilters(List<_InboxRow> rows) {
    final search = _searchC.text.trim().toLowerCase();

    return rows.where((row) {
      final r = row.item;
      final matchesTab = _tab == _AdminInboxTab.groups ? r.isGroup : !r.isGroup;
      if (!matchesTab) return false;
      final cachedRole = _peerRoleCache[r.peerUid] ?? r.peerRole;
      final role = MailConsistencyService.normalizeRole(cachedRole);
      final isUnread = r.unreadCount > 0;
      final isLearner = role == 'learner';
      final isStaff = MailConsistencyService.isStaffOrTeacherRole(role);

      final matchesFilter = switch (_filter) {
        _AdminMailFilter.all => true,
        _AdminMailFilter.learners => isLearner,
        _AdminMailFilter.staffTeachers => isStaff,
        _AdminMailFilter.unread => isUnread,
      };

      final matchesSearch = search.isEmpty
          ? true
          : r.subject.toLowerCase().contains(search) ||
                r.lastMessage.toLowerCase().contains(search) ||
                r.peerName.toLowerCase().contains(search) ||
                r.peerUid.toLowerCase().contains(search);

      return matchesFilter && matchesSearch;
    }).toList();
  }

  Widget _buildTabButton({
    required _AdminInboxTab value,
    required String label,
    required IconData icon,
  }) {
    final selected = _tab == value;
    return ChoiceChip(
      selected: selected,
      avatar: Icon(icon, size: 16),
      label: Text(label),
      onSelected: (_) => setState(() => _tab = value),
    );
  }

  Future<void> _openThread(_InboxRow row) async {
    final peerUid = row.item.isGroup ? '' : row.item.peerUid.trim();
    final peerName = row.item.peerName.trim().isEmpty
        ? 'User'
        : row.item.peerName;

    if (!mounted) return;
    if (peerUid.isEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              MailThreadByIdScreen(threadId: row.threadId, peerUid: ''),
        ),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: RouteSettings(name: '/mail/thread/${row.threadId}'),
        builder: (_) => MailTopicThreadScreen(
          threadId: row.threadId,
          peerUid: peerUid,
          peerName: peerName,
        ),
      ),
    );
  }

  void _resolveRoleFallback(_InboxRow row) {
    final peerUid = row.item.peerUid.trim();
    if (peerUid.isEmpty) return;
    if (_peerRoleCache.containsKey(peerUid)) return;

    final seeded = row.item.peerRole.trim();
    if (MailConsistencyService.normalizeRole(seeded) != 'unknown') {
      _peerRoleCache[peerUid] = seeded;
      return;
    }

    unawaited(() async {
      final role = await MailConsistencyService.resolveUserRole(
        _db,
        peerUid,
        seedRole: seeded,
      );
      if (!mounted) return;
      setState(() => _peerRoleCache[peerUid] = role);
      if (role != 'unknown') {
        await _db.ref('mail_index/$_meUid/${row.threadId}').update({
          'peerRole': role,
        });
      }
    }());
  }

  Widget _filterChip(_AdminMailFilter value, String label) {
    final selected = _filter == value;
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Mail'),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Create group mail',
            icon: const Icon(Icons.group_add_rounded),
            onPressed: _openCreateGroup,
          ),
          IconButton(
            tooltip: 'Repair inbox index',
            icon: _repairInProgress
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
            onPressed: _repairInProgress
                ? null
                : () async {
                    _didInitialRepair = false;
                    await _runIntegritySweepOnce();
                    if (!mounted) return;
                    _snack('Inbox scan complete ✅');
                  },
          ),
          IconButton(
            tooltip: 'Repair old homework reviews',
            icon: _homeworkReviewBackfillRunning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check_rounded),
            onPressed: _homeworkReviewBackfillRunning
                ? null
                : _runHomeworkReviewBackfill,
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1400,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                controller: _searchC,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search by name, subject, preview…',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _buildTabButton(
                    value: _AdminInboxTab.mail,
                    label: 'Mail',
                    icon: Icons.mail_outline_rounded,
                  ),
                  const SizedBox(width: 8),
                  _buildTabButton(
                    value: _AdminInboxTab.groups,
                    label: 'Groups',
                    icon: Icons.groups_rounded,
                  ),
                  const SizedBox(width: 14),
                  _filterChip(_AdminMailFilter.all, 'All'),
                  const SizedBox(width: 8),
                  _filterChip(_AdminMailFilter.learners, 'Learners'),
                  const SizedBox(width: 8),
                  _filterChip(_AdminMailFilter.staffTeachers, 'Staff/Teachers'),
                  const SizedBox(width: 8),
                  _filterChip(_AdminMailFilter.unread, 'Unread'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _stream,
                builder: (_, snap) {
                  if (snap.hasError) {
                    return const Center(child: Text('Failed to load inbox.'));
                  }
                  final rows = _applyFilters(_parse(snap.data?.snapshot.value));
                  if (rows.isEmpty) {
                    return const Center(child: Text('Inbox is empty.'));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final row = rows[i];
                      _resolveRoleFallback(row);
                      final item = row.item;
                      final hasUnread = item.unreadCount > 0;
                      final role = MailConsistencyService.normalizeRole(
                        _peerRoleCache[item.peerUid] ?? item.peerRole,
                      );
                      final isGroup = item.isGroup;

                      final roleLabel = switch (role) {
                        'learner' => 'Learner',
                        'teacher' => 'Teacher',
                        'staff' => 'Staff',
                        'admin' => 'Admin',
                        _ => 'Unknown',
                      };
                      final openListLabel = switch (role) {
                        'learner' => 'Open learner list',
                        'teacher' || 'staff' || 'admin' => 'Open staff list',
                        _ => 'Open filtered list',
                      };

                      return Card(
                        child: ListTile(
                          leading: isGroup
                              ? CircleAvatar(
                                  backgroundColor: Colors.indigo.withValues(
                                    alpha: 0.10,
                                  ),
                                  foregroundImage:
                                      item.groupPicUrl.trim().isNotEmpty
                                      ? NetworkImage(item.groupPicUrl.trim())
                                      : null,
                                  child: item.groupPicUrl.trim().isNotEmpty
                                      ? null
                                      : const Icon(
                                          Icons.groups_rounded,
                                          color: Colors.indigo,
                                        ),
                                )
                              : null,
                          title: Text(
                            isGroup
                                ? (item.groupName.isEmpty
                                      ? 'Group conversation'
                                      : item.groupName)
                                : '${item.peerName.isEmpty ? 'User' : item.peerName} • $roleLabel',
                            style: TextStyle(
                              color: _personNameColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              height: 1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item.subject.isEmpty
                                    ? '(No subject)'
                                    : item.subject,
                                style: TextStyle(
                                  fontWeight: hasUnread
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  fontSize: 14,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.lastMessage.isEmpty
                                    ? 'No messages yet'
                                    : item.lastMessage,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DefaultTextStyle.of(
                                  context,
                                ).style.copyWith(fontSize: 13, height: 1.2),
                              ),
                            ],
                          ),
                          isThreeLine: true,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isGroup)
                                IconButton(
                                  tooltip: openListLabel,
                                  icon: const Icon(Icons.manage_search_rounded),
                                  onPressed: () => openAdminFilteredPeopleList(
                                    context,
                                    peerUid: item.peerUid,
                                    peerName: item.peerName,
                                    seedRole:
                                        _peerRoleCache[item.peerUid] ??
                                        item.peerRole,
                                  ),
                                ),
                              if (hasUnread)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade600,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    item.unreadCount > 99
                                        ? '99+'
                                        : '${item.unreadCount}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              PopupMenuButton<String>(
                                onSelected: (v) async {
                                  if (v == 'open_list') {
                                    await openAdminFilteredPeopleList(
                                      context,
                                      peerUid: item.peerUid,
                                      peerName: item.peerName,
                                      seedRole:
                                          _peerRoleCache[item.peerUid] ??
                                          item.peerRole,
                                    );
                                    return;
                                  }
                                  if (v == 'delete') {
                                    await _deleteForMe(row.threadId);
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'open_list',
                                    child: Text(openListLabel),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete (for me)'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () => _openThread(row),
                        ),
                      );
                    },
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

enum _AdminMailFilter { all, learners, staffTeachers, unread }

enum _AdminInboxTab { mail, groups }

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
    required this.peerRole,
    required this.isGroup,
    required this.groupName,
    required this.groupPicUrl,
  });

  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final String peerUid;
  final String peerName;
  final String peerRole;
  final bool isGroup;
  final String groupName;
  final String groupPicUrl;

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
      unreadCount: toInt(m['unreadCount'] ?? m['unread']),
      peerUid: (m['peerUid'] ?? '').toString(),
      peerName: (m['peerName'] ?? '').toString(),
      peerRole: (m['peerRole'] ?? '').toString(),
      isGroup: m['isGroup'] == true,
      groupName: (m['groupName'] ?? '').toString(),
      groupPicUrl: (m['groupPicUrl'] ?? '').toString(),
    );
  }
}
