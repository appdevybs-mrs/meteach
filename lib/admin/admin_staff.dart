import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../shared/human_error.dart';
import 'admin_teacher_reminders_screen.dart';
import 'admin_teacher_mail_topics_screen.dart';
import '../shared/profile_avatar.dart';
import '../widgets/teacher_media_sheet.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';

class AdminStaffScreen extends StatefulWidget {
  const AdminStaffScreen({super.key, this.initialSearch = ''});

  final String initialSearch;

  // Brand palette (match your style)
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const accentCyan = Color(0xFF00D4FF);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorders = Color(0xFFD1D9E0);

  @override
  State<AdminStaffScreen> createState() => _AdminStaffScreenState();
}

class _AdminStaffScreenState extends State<AdminStaffScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  final _db = FirebaseDatabase.instance;
  late final Stream<DatabaseEvent> _usersStream;
  late final Stream<DatabaseEvent> _deletedStream;
  late final Stream<DatabaseEvent> _blockedStream;

  // Nodes (match your DB)
  static const _usersPath = 'users';
  static const _deletedPath = 'users_deleted';
  static const _blockedPath = 'users_blocked';

  // UI state
  String _search = '';
  StaffStatus? _statusFilter; // only Users tab
  StaffRole? _roleFilter; // only Users tab
  bool _webDenseMode = false;

  DatabaseReference get _usersRef => _db.ref(_usersPath);
  DatabaseReference get _deletedRef => _db.ref(_deletedPath);
  DatabaseReference get _blockedRef => _db.ref(_blockedPath);

  @override
  void initState() {
    super.initState();
    _search = widget.initialSearch.trim();
    _tab = TabController(length: 3, vsync: this);

    _usersStream = _usersRef.onValue.asBroadcastStream();
    _deletedStream = _deletedRef.onValue.asBroadcastStream();
    _blockedStream = _blockedRef.onValue.asBroadcastStream();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;

    // ✅ avoid using a context that is in the middle of dispose/pop
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text(humanizeUiMessage(msg))),
      );
    });
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    bool danger = false,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger ? Colors.red : null,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmText),
              ),
            ],
          ),
        )) ??
        false;
  }

  // ---------- Actions ----------

  Future<void> _pauseStaff(String uid) async {
    await _usersRef.child(uid).update({
      'status': StaffStatus.paused.value,
      'updatedAt': ServerValue.timestamp,
    });
    _snack('Staff paused ✅');
  }

  Future<void> _activateStaff(String uid) async {
    await _usersRef.child(uid).update({
      'status': StaffStatus.active.value,
      'updatedAt': ServerValue.timestamp,
    });
    _snack('Staff activated ✅');
  }

  Future<void> _moveToDeleted(String uid, Staff staff) async {
    final ok = await _confirm(
      title: 'Delete staff?',
      message:
          'This will move the staff member to "deleted".\n\nYou can restore later.',
      confirmText: 'Move to deleted',
      danger: true,
    );
    if (!ok) return;

    try {
      // Read their courses BEFORE moving (so we can clean instructors if teacher)
      final userCoursesSnap = await _usersRef.child(uid).child('courses').get();
      final userCoursesVal = userCoursesSnap.value;

      final courseIds = <String>[];
      if (userCoursesVal is Map) {
        userCoursesVal.forEach((k, v) {
          if (v is Map) {
            final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
            final id = (mm['id'] ?? '').toString().trim();
            if (id.isNotEmpty) courseIds.add(id);
          }
        });
      }

      // If this staff is teacher: remove them from courses instructors by UID
      if (staff.role == StaffRole.teacher) {
        for (final courseId in courseIds) {
          final instrRef = _db.ref('courses/$courseId/instructors');
          final snap = await instrRef.get();
          final v = snap.value;

          final next = <dynamic>[];

          if (v is List) {
            for (final item in v) {
              if (item is Map) {
                final mm = item.map((k, vv) => MapEntry(k.toString(), vv));
                final itemUid = (mm['uid'] ?? '').toString().trim();
                if (itemUid.isNotEmpty && itemUid == uid) {
                  continue;
                }
                next.add({
                  'uid': itemUid,
                  'name': (mm['name'] ?? '').toString().trim(),
                });
              } else {
                final s = (item ?? '').toString().trim();
                if (s.isNotEmpty) next.add(s);
              }
            }
          } else if (v is Map) {
            v.forEach((_, item) {
              if (item is Map) {
                final mm = item.map((k, vv) => MapEntry(k.toString(), vv));
                final itemUid = (mm['uid'] ?? '').toString().trim();
                if (itemUid.isNotEmpty && itemUid == uid) {
                  return;
                }
                next.add({
                  'uid': itemUid,
                  'name': (mm['name'] ?? '').toString().trim(),
                });
              } else {
                final s = (item ?? '').toString().trim();
                if (s.isNotEmpty) next.add(s);
              }
            });
          }

          if (next.isEmpty) {
            await instrRef.remove();
          } else {
            await instrRef.set(next);
          }
        }
      }

      final data = staff.toMap()
        ..addAll({
          'uid': uid,
          'movedAt': ServerValue.timestamp,
          'movedFrom': _usersPath,
        });

      final updates = <String, dynamic>{
        '$_deletedPath/$uid': data,
        '$_usersPath/$uid': null,
      };

      await _db.ref().update(updates);

      _snack('Moved to deleted 🗑️');
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _moveToBlocked(String uid, Staff staff) async {
    final ok = await _confirm(
      title: 'Block staff?',
      message:
          'This will move the staff member to "blocked".\n\nYou can restore later.',
      confirmText: 'Block',
      danger: true,
    );
    if (!ok) return;

    final data = staff.toMap()
      ..addAll({'movedAt': ServerValue.timestamp, 'movedFrom': _usersPath});

    await _blockedRef.child(uid).set(data);
    await _usersRef.child(uid).remove();

    _snack('Moved to blocked ⛔');
  }

  Future<void> _restoreFromDeleted(String uid, Staff staff) async {
    final ok = await _confirm(
      title: 'Restore staff?',
      message: 'This will restore the staff member back to users.',
      confirmText: 'Restore',
    );
    if (!ok) return;

    final data = staff.toMap()
      ..remove('movedAt')
      ..remove('movedFrom')
      ..addAll({'updatedAt': ServerValue.timestamp});

    await _usersRef.child(uid).set(data);
    await _deletedRef.child(uid).remove();

    _snack('Restored ✅');
  }

  Future<void> _restoreFromBlocked(String uid, Staff staff) async {
    final ok = await _confirm(
      title: 'Unblock staff?',
      message: 'This will restore the staff member back to users.',
      confirmText: 'Unblock',
    );
    if (!ok) return;

    final data = staff.toMap()
      ..remove('movedAt')
      ..remove('movedFrom')
      ..addAll({'updatedAt': ServerValue.timestamp});

    await _usersRef.child(uid).set(data);
    await _blockedRef.child(uid).remove();

    _snack('Unblocked ✅');
  }

  Future<void> _deletePermanently(String uid, DatabaseReference fromRef) async {
    final ok = await _confirm(
      title: 'Delete permanently?',
      message: 'This cannot be undone.',
      confirmText: 'Delete forever',
      danger: true,
    );
    if (!ok) return;

    await fromRef.child(uid).remove();
    _snack('Deleted permanently ✅');
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminStaffScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminStaffScreen.primaryBlue),
        title: const Text(
          'Staff',
          style: TextStyle(
            color: AdminStaffScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        bottom: TabBar(
          controller: _tab,
          labelColor: AdminStaffScreen.primaryBlue,
          unselectedLabelColor: AdminStaffScreen.primaryBlue.withValues(
            alpha: 0.55,
          ),
          indicatorColor: AdminStaffScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Users'),
            Tab(text: 'Deleted'),
            Tab(text: 'Blocked'),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
          if (kIsWeb)
            IconButton(
              tooltip: _webDenseMode ? 'Comfort mode' : 'Dense mode',
              icon: Icon(
                _webDenseMode
                    ? Icons.view_agenda_rounded
                    : Icons.density_small_rounded,
                color: AdminStaffScreen.primaryBlue,
              ),
              onPressed: () => setState(() => _webDenseMode = !_webDenseMode),
            ),
          AnimatedBuilder(
            animation: _tab,
            builder: (_, _) {
              final isUsersTab = _tab.index == 0;
              if (!isUsersTab) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Add staff',
                icon: const Icon(
                  Icons.person_add_alt_1_rounded,
                  color: AdminStaffScreen.actionOrange,
                ),
                onPressed: () async {
                  final created = await Navigator.of(context).push<Staff?>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const StaffEditorScreen(mode: EditorMode.create),
                    ),
                  );
                  if (created != null) _snack('Staff created ✅');
                },
              );
            },
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1560,
        child: TabBarView(
          controller: _tab,
          children: [
            _StaffList(
              titleHint: 'Search staff…',
              stream: _usersStream,
              webDenseMode: _webDenseMode,
              search: _search,
              statusFilter: _statusFilter,
              roleFilter: _roleFilter,
              onSearchChanged: (v) => setState(() => _search = v),
              onStatusFilterChanged: (s) => setState(() => _statusFilter = s),
              onRoleFilterChanged: (r) => setState(() => _roleFilter = r),
              onEdit: (uid, staff) async {
                final updated = await Navigator.of(context).push<Staff?>(
                  MaterialPageRoute(
                    builder: (_) => StaffEditorScreen(
                      mode: EditorMode.edit,
                      uid: uid,
                      initial: staff,
                    ),
                  ),
                );
                if (updated != null) _snack('Staff updated ✅');
              },
              actionsBuilder: (uid, staff) => [
                PopupMenuItem(
                  value: _RowAction.pause,
                  child: Text(
                    staff.status == StaffStatus.paused ? 'Activate' : 'Pause',
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: _RowAction.block,
                  child: Text('Block'),
                ),
                const PopupMenuItem(
                  value: _RowAction.delete,
                  child: Text('Delete (move to deleted)'),
                ),
              ],
              onAction: (uid, staff, action) async {
                switch (action) {
                  case _RowAction.pause:
                    if (staff.status == StaffStatus.paused) {
                      await _activateStaff(uid);
                    } else {
                      await _pauseStaff(uid);
                    }
                    break;
                  case _RowAction.block:
                    await _moveToBlocked(uid, staff);
                    break;
                  case _RowAction.delete:
                    await _moveToDeleted(uid, staff);
                    break;
                  default:
                    break;
                }
              },
            ),
            _StaffList(
              titleHint: 'Search deleted…',
              stream: _deletedStream,
              webDenseMode: _webDenseMode,
              search: _search,
              statusFilter: null,
              roleFilter: null,
              onSearchChanged: (v) => setState(() => _search = v),
              onStatusFilterChanged: (_) {},
              onRoleFilterChanged: (_) {},
              actionsBuilder: (_, _) => const [
                PopupMenuItem(
                  value: _RowAction.restore,
                  child: Text('Restore'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: _RowAction.deleteForever,
                  child: Text('Delete permanently'),
                ),
              ],
              onAction: (uid, staff, action) async {
                switch (action) {
                  case _RowAction.restore:
                    await _restoreFromDeleted(uid, staff);
                    break;
                  case _RowAction.deleteForever:
                    await _deletePermanently(uid, _deletedRef);
                    break;
                  default:
                    break;
                }
              },
            ),
            _StaffList(
              titleHint: 'Search blocked…',
              stream: _blockedStream,
              webDenseMode: _webDenseMode,
              search: _search,
              statusFilter: null,
              roleFilter: null,
              onSearchChanged: (v) => setState(() => _search = v),
              onStatusFilterChanged: (_) {},
              onRoleFilterChanged: (_) {},
              actionsBuilder: (_, _) => const [
                PopupMenuItem(
                  value: _RowAction.restore,
                  child: Text('Unblock'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: _RowAction.deleteForever,
                  child: Text('Delete permanently'),
                ),
              ],
              onAction: (uid, staff, action) async {
                switch (action) {
                  case _RowAction.restore:
                    await _restoreFromBlocked(uid, staff);
                    break;
                  case _RowAction.deleteForever:
                    await _deletePermanently(uid, _blockedRef);
                    break;
                  default:
                    break;
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _RowAction { edit, pause, delete, block, restore, deleteForever }

// ----------------------------
// List
// ----------------------------

class _StaffList extends StatefulWidget {
  const _StaffList({
    required this.titleHint,
    required this.stream,
    required this.webDenseMode,
    required this.search,
    required this.statusFilter,
    required this.roleFilter,
    required this.onSearchChanged,
    required this.onStatusFilterChanged,
    required this.onRoleFilterChanged,
    required this.actionsBuilder,
    required this.onAction,
    this.onEdit,
  });

  final String titleHint;
  final Stream<DatabaseEvent> stream;
  final bool webDenseMode;

  final String search;
  final StaffStatus? statusFilter;
  final StaffRole? roleFilter;

  final ValueChanged<String> onSearchChanged;
  final ValueChanged<StaffStatus?> onStatusFilterChanged;
  final ValueChanged<StaffRole?> onRoleFilterChanged;

  final List<PopupMenuEntry<_RowAction>> Function(String uid, Staff staff)
  actionsBuilder;
  final Future<void> Function(String uid, Staff staff, _RowAction action)
  onAction;

  final Future<void> Function(String uid, Staff staff)? onEdit;

  @override
  State<_StaffList> createState() => _StaffListState();
}

class _StaffListState extends State<_StaffList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _db = FirebaseDatabase.instance;

  int _parseUnread(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  int _parseReminderUnread(dynamic v) {
    if (v is! Map) return 0;
    int count = 0;
    v.forEach((_, raw) {
      if (raw is! Map) return;
      final m = raw.map((k, vv) => MapEntry(k.toString(), vv));
      final status = (m['status'] ?? 'new').toString().trim().toLowerCase();
      if (status == 'new') count++;
    });
    return count;
  }

  Map<String, int> _mailUnreadByPeer(dynamic root) {
    final out = <String, int>{};
    if (root is! Map) return out;

    final index = Map<dynamic, dynamic>.from(root);
    for (final entry in index.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      if (m['deletedAt'] != null) continue;

      final peerUid = (m['peerUid'] ?? '').toString().trim();
      if (peerUid.isEmpty) continue;

      final unread = _parseUnread(m['unreadCount']);
      if (unread <= 0) continue;
      out[peerUid] = (out[peerUid] ?? 0) + unread;
    }

    return out;
  }

  String _cleanPhone(String raw) {
    final s = raw.trim();
    return s.replaceAll(RegExp(r'[^0-9+]'), '');
  }

  Future<void> _openTeacherProfileSheet(
    BuildContext context, {
    required String teacherUid,
    required Staff staff,
  }) async {
    if (staff.role != StaffRole.teacher) {
      _snackHere(context, 'Only teachers have profile media.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: TeacherMediaSheet(
          teacherUid: teacherUid,
          teacherName: staff.fullName,
        ),
      ),
    );
  }

  Future<void> _openTeacherLearners(
    BuildContext context, {
    required String teacherUid,
    required Staff staff,
  }) async {
    if (staff.role != StaffRole.teacher) {
      _snackHere(context, 'Only teachers have learners.');
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminTeacherLearnersScreen(
          teacherUid: teacherUid,
          teacherName: staff.fullName,
        ),
      ),
    );
  }

  Future<void> _launchPhoneUri(String scheme, String phone) async {
    final clean = _cleanPhone(phone);
    if (clean.isEmpty) return;
    final uri = Uri(scheme: scheme, path: clean);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _snackHere(context, 'Could not open $scheme app.');
    }
  }

  Future<void> _openPhoneActions(BuildContext context, String phone) async {
    final clean = _cleanPhone(phone);
    if (clean.isEmpty) {
      _snackHere(context, 'No phone number.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call_rounded),
              title: const Text('Call'),
              subtitle: Text(clean),
              onTap: () async {
                Navigator.pop(ctx);
                await _launchPhoneUri('tel', clean);
              },
            ),
            ListTile(
              leading: const Icon(Icons.sms_rounded),
              title: const Text('SMS'),
              subtitle: Text(clean),
              onTap: () async {
                Navigator.pop(ctx);
                await _launchPhoneUri('sms', clean);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy number'),
              subtitle: Text(clean),
              onTap: () {
                Clipboard.setData(ClipboardData(text: clean));
                Navigator.pop(ctx);
                _snackHere(context, 'Phone copied');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _openStaffCopyActions(BuildContext context, Staff staff) async {
    final fullName = staff.fullName.trim();
    final dob = staff.dob.trim();
    final phoneMain = staff.phone1.trim().isNotEmpty
        ? staff.phone1.trim()
        : staff.phone2.trim();
    final email = staff.email.trim();

    void copyField({
      required String label,
      required String value,
      required BuildContext sheetContext,
    }) {
      if (value.isEmpty) {
        Navigator.pop(sheetContext);
        _snackHere(context, 'No $label available.');
        return;
      }
      Clipboard.setData(ClipboardData(text: value));
      Navigator.pop(sheetContext);
      _snackHere(context, '$label copied');
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Copy full name'),
              subtitle: Text(fullName.isEmpty ? '(No name)' : fullName),
              onTap: () => copyField(
                label: 'Full name',
                value: fullName,
                sheetContext: ctx,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cake_outlined),
              title: const Text('Copy DOB'),
              subtitle: Text(dob.isEmpty ? '(No DOB)' : dob),
              onTap: () =>
                  copyField(label: 'DOB', value: dob, sheetContext: ctx),
            ),
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: const Text('Copy phone'),
              subtitle: Text(phoneMain.isEmpty ? '(No phone)' : phoneMain),
              onTap: () => copyField(
                label: 'Phone',
                value: phoneMain,
                sheetContext: ctx,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: const Text('Copy email'),
              subtitle: Text(email.isEmpty ? '(No email)' : email),
              onTap: () =>
                  copyField(label: 'Email', value: email, sheetContext: ctx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        _TopBar(
          hint: widget.titleHint,
          value: widget.search,
          onChanged: widget.onSearchChanged,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ChoiceChip(
                  label: const Text('All roles'),
                  selected: widget.roleFilter == null,
                  onSelected: (_) => widget.onRoleFilterChanged(null),
                ),
                const SizedBox(width: 8),
                ...StaffRole.values.map((r) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(r.label),
                      selected: widget.roleFilter == r,
                      onSelected: (_) => widget.onRoleFilterChanged(r),
                    ),
                  );
                }),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('All status'),
                  selected: widget.statusFilter == null,
                  onSelected: (_) => widget.onStatusFilterChanged(null),
                ),
                const SizedBox(width: 8),
                ...StaffStatus.values.map((s) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(s.label),
                      selected: widget.statusFilter == s,
                      onSelected: (_) => widget.onStatusFilterChanged(s),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: widget.stream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const _StateCard(
                  title: 'Error',
                  message: 'Could not load staff.',
                  icon: Icons.error_outline,
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _LoadingList();
              }

              final data = snapshot.data?.snapshot.value;
              final rows = _parseStaffMap(data);

              rows.sort((a, b) {
                final aT = a.staff.updatedAtMs ?? 0;
                final bT = b.staff.updatedAtMs ?? 0;
                return bT.compareTo(aT);
              });

              final s = widget.search.trim().toLowerCase();
              final filtered = rows.where((r) {
                final u = r.staff;

                final matchesSearch = s.isEmpty
                    ? true
                    : u.fullName.toLowerCase().contains(s) ||
                          u.email.toLowerCase().contains(s) ||
                          u.phone1.toLowerCase().contains(s) ||
                          u.phone2.toLowerCase().contains(s);

                final matchesStatus = widget.statusFilter == null
                    ? true
                    : (u.status == widget.statusFilter);
                final matchesRole = widget.roleFilter == null
                    ? true
                    : u.role.value.toLowerCase().trim() ==
                          widget.roleFilter!.value.toLowerCase().trim();

                return matchesSearch && matchesStatus && matchesRole;
              }).toList();

              if (filtered.isEmpty) {
                return const _StateCard(
                  title: 'No staff',
                  message: 'No results match your filters.',
                  icon: Icons.people_outline,
                );
              }

              final meUid = FirebaseAuth.instance.currentUser?.uid;

              Widget buildStaffList(Map<String, int> mailUnreadByPeer) {
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final row = filtered[i];
                    final u = row.staff;

                    // unread is relevant for teacher conversations
                    final canShowMailBadge =
                        meUid != null && u.role == StaffRole.teacher;
                    final unread = canShowMailBadge
                        ? (mailUnreadByPeer[row.uid] ?? 0)
                        : 0;
                    final reminderUnreadRef = u.role == StaffRole.teacher
                        ? _db.ref('reminders').child(row.uid)
                        : null;
                    final phoneMain = u.phone1.trim().isNotEmpty
                        ? u.phone1.trim()
                        : u.phone2.trim();
                    final canOpenProfile = u.role == StaffRole.teacher;
                    final profilePhoto = u.primaryProfilePhoto;
                    final dense = widget.webDenseMode && kIsWeb;

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPress: () => _openStaffCopyActions(context, u),
                      child: Card(
                        margin: EdgeInsets.only(bottom: dense ? 7 : 10),
                        elevation: 0,
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(dense ? 12 : 16),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(dense ? 9 : 12),
                          child: Row(
                            children: [
                              GestureDetector(
                                onTap: () => _openTeacherQuickActions(
                                  context,
                                  row.uid,
                                  u,
                                ),
                                onLongPress: () => _openTeacherQuickActions(
                                  context,
                                  row.uid,
                                  u,
                                ),

                                // ✅ Avatar + Mail badge
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    CircleAvatar(
                                      radius: dense ? 18 : 21,
                                      backgroundColor: Colors.transparent,
                                      child: ProfileAvatar(
                                        name: u.fullName,
                                        photoUrl: profilePhoto,
                                        radius: dense ? 18 : 21,
                                        fallbackBg: AdminStaffScreen.appBg,
                                        fallbackFg:
                                            AdminStaffScreen.primaryBlue,
                                        borderColor: AdminStaffScreen.uiBorders
                                            .withValues(alpha: 0.75),
                                      ),
                                    ),
                                    if (unread > 0)
                                      Positioned(
                                        right: -2,
                                        top: -2,
                                        child: IgnorePointer(
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.red,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 2,
                                              ),
                                            ),
                                            constraints: const BoxConstraints(
                                              minWidth: 18,
                                              minHeight: 18,
                                            ),
                                            child: Center(
                                              child: Text(
                                                unread > 99
                                                    ? '99+'
                                                    : unread.toString(),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (reminderUnreadRef != null)
                                      Positioned(
                                        left: -2,
                                        top: -2,
                                        child: StreamBuilder<DatabaseEvent>(
                                          stream: reminderUnreadRef.onValue,
                                          builder: (_, snap) {
                                            final unread = _parseReminderUnread(
                                              snap.data?.snapshot.value,
                                            );
                                            if (unread <= 0) {
                                              return const SizedBox.shrink();
                                            }

                                            final txt = unread > 9
                                                ? '9+'
                                                : unread.toString();

                                            return IgnorePointer(
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFFF98D28,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                  border: Border.all(
                                                    color: Colors.white,
                                                    width: 2,
                                                  ),
                                                ),
                                                constraints:
                                                    const BoxConstraints(
                                                      minWidth: 18,
                                                      minHeight: 18,
                                                    ),
                                                child: Center(
                                                  child: Text(
                                                    txt,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              SizedBox(width: dense ? 9 : 12),
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: canOpenProfile
                                      ? () => _openTeacherProfileSheet(
                                          context,
                                          teacherUid: row.uid,
                                          staff: u,
                                        )
                                      : null,
                                  child: Padding(
                                    // small padding so InkWell feels nice but doesn't change layout much
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 2,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          u.fullName.isEmpty
                                              ? '(No name)'
                                              : u.fullName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: AdminStaffScreen.primaryBlue,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          u.email.isEmpty
                                              ? '(No email)'
                                              : u.email,
                                          style: TextStyle(
                                            fontSize: dense ? 11 : 12,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.black.withValues(
                                              alpha: 0.55,
                                            ),
                                          ),
                                        ),
                                        SizedBox(height: dense ? 4 : 6),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            _Pill(label: u.role.label),
                                            _Pill(
                                              label: u.status.label,
                                              bg: _statusBg(u.status),
                                              fg: _statusFg(u.status),
                                            ),
                                            if (u.dob.trim().isNotEmpty)
                                              _Pill(label: '🎂 ${u.dob}'),
                                          ],
                                        ),
                                        if (!dense &&
                                            u.role == StaffRole.teacher &&
                                            phoneMain.isNotEmpty) ...[
                                          const SizedBox(height: 8),
                                          GestureDetector(
                                            onLongPress: () =>
                                                _openPhoneActions(
                                                  context,
                                                  phoneMain,
                                                ),
                                            child: _Pill(
                                              label: 'Phone: $phoneMain',
                                              bg: const Color(0xFFEAF2FF),
                                              fg: AdminStaffScreen.primaryBlue,
                                            ),
                                          ),
                                        ],
                                        if (!dense &&
                                            u.role == StaffRole.teacher) ...[
                                          const SizedBox(height: 8),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              OutlinedButton.icon(
                                                onPressed: () =>
                                                    _openTeacherLearners(
                                                      context,
                                                      teacherUid: row.uid,
                                                      staff: u,
                                                    ),
                                                icon: const Icon(
                                                  Icons.groups_rounded,
                                                  size: 18,
                                                ),
                                                label: const Text('Learners'),
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor:
                                                      AdminStaffScreen
                                                          .primaryBlue,
                                                  side: BorderSide(
                                                    color: AdminStaffScreen
                                                        .uiBorders
                                                        .withValues(alpha: 0.9),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 8,
                                                      ),
                                                ),
                                              ),
                                              OutlinedButton.icon(
                                                onPressed: () =>
                                                    _openTeacherProfileSheet(
                                                      context,
                                                      teacherUid: row.uid,
                                                      staff: u,
                                                    ),
                                                icon: const Icon(
                                                  Icons.perm_media_rounded,
                                                  size: 18,
                                                ),
                                                label: const Text('Profile'),
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor:
                                                      AdminStaffScreen
                                                          .actionOrange,
                                                  side: BorderSide(
                                                    color: AdminStaffScreen
                                                        .actionOrange
                                                        .withValues(
                                                          alpha: 0.45,
                                                        ),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 8,
                                                      ),
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
                              const SizedBox(width: 8),
                              PopupMenuButton<_RowAction>(
                                tooltip: 'Actions',
                                onSelected: (a) async {
                                  if (a == _RowAction.edit) {
                                    if (widget.onEdit != null) {
                                      await widget.onEdit!(row.uid, u);
                                    }
                                    return;
                                  }
                                  await widget.onAction(row.uid, u, a);
                                },
                                itemBuilder: (_) {
                                  final items = <PopupMenuEntry<_RowAction>>[];
                                  if (widget.onEdit != null) {
                                    items.add(
                                      const PopupMenuItem(
                                        value: _RowAction.edit,
                                        child: Text('Edit'),
                                      ),
                                    );
                                    items.add(const PopupMenuDivider());
                                  }
                                  items.addAll(
                                    widget.actionsBuilder(row.uid, u),
                                  );
                                  return items;
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              }

              if (meUid == null || meUid.trim().isEmpty) {
                return buildStaffList(const <String, int>{});
              }

              return StreamBuilder<DatabaseEvent>(
                stream: _db.ref('mail_index').child(meUid).onValue,
                builder: (context, mailSnap) {
                  final unreadByPeer = _mailUnreadByPeer(
                    mailSnap.data?.snapshot.value,
                  );
                  return buildStaffList(unreadByPeer);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String hint;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search),
          filled: true,
          fillColor: AdminStaffScreen.appBg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, this.bg, this.fg});

  final String label;
  final Color? bg;
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    final background = bg ?? AdminStaffScreen.appBg;
    final foreground = fg ?? AdminStaffScreen.primaryBlue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

void _snackHere(BuildContext context, String msg) {
  AppToast.fromSnackBar(context, SnackBar(content: Text(msg)));
}

Future<void> _openTeacherQuickActions(
  BuildContext context,
  String teacherUid,
  Staff staff,
) async {
  // Only for teachers (safe)
  if (staff.role != StaffRole.teacher) {
    _snackHere(context, 'Only teachers have reminders.');
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: const Text('Mail'),
              subtitle: Text(
                staff.email.trim().isEmpty ? '(No email)' : staff.email,
              ),
              onTap: () async {
                Navigator.pop(ctx);

                // ✅ Open in-app mail thread
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AdminTeacherMailTopicsScreen(
                      teacherUid: teacherUid,
                      teacher: staff,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Reminder'),
              onTap: () async {
                Navigator.pop(ctx);
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AdminTeacherRemindersScreen(
                      teacherUid: teacherUid,
                      teacher: staff,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.all(16),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: AdminStaffScreen.primaryBlue),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: AdminStaffScreen.primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: 6,
      itemBuilder: (context, i) => Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 10),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: ColoredBox(color: AdminStaffScreen.appBg),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 14,
                      width: 160,
                      child: ColoredBox(color: AdminStaffScreen.appBg),
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      height: 12,
                      width: 260,
                      child: ColoredBox(color: AdminStaffScreen.appBg),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------
// Editor
// ----------------------------

enum EditorMode { create, edit }

class StaffEditorScreen extends StatefulWidget {
  const StaffEditorScreen({
    super.key,
    required this.mode,
    this.uid,
    this.initial,
  });

  final EditorMode mode;
  final String? uid;
  final Staff? initial;

  @override
  State<StaffEditorScreen> createState() => _StaffEditorScreenState();
}

class _StaffEditorScreenState extends State<StaffEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  String _serial = '';

  final _db = FirebaseDatabase.instance;
  DatabaseReference get _usersRef => _db.ref('users');
  DatabaseReference get _coursesRef => _db.ref('courses');

  // fields
  late final TextEditingController firstNameC;
  late final TextEditingController lastNameC;
  late final TextEditingController dobC;
  late final TextEditingController phone1C;
  late final TextEditingController phone2C;
  late final TextEditingController emailC;
  late final TextEditingController passwordC;

  DateTime? _dob;

  StaffStatus _status = StaffStatus.active;
  StaffRole _role = StaffRole.teacher;

  bool _saving = false;

  Map<String, Map<String, dynamic>> _allCourses = {};
  final Set<String> _selectedCourseIds = {};
  bool _loadingCourses = true;
  // --- to track what was assigned BEFORE editing (needed for add/remove instructors) ---
  final Set<String> _initialCourseIds = {}; // courses before edit
  StaffRole? _initialRole; // role before edit
  String _initialTeacherName = ''; // name before edit

  @override
  void initState() {
    super.initState();

    final initial = widget.initial;
    _serial = initial?.serial ?? '';

    firstNameC = TextEditingController(text: initial?.firstName ?? '');
    lastNameC = TextEditingController(text: initial?.lastName ?? '');
    dobC = TextEditingController(text: initial?.dob ?? '');
    phone1C = TextEditingController(text: initial?.phone1 ?? '');
    phone2C = TextEditingController(text: initial?.phone2 ?? '');
    emailC = TextEditingController(text: initial?.email ?? '');
    passwordC = TextEditingController();

    _status = initial?.status ?? StaffStatus.active;
    _role = initial?.role ?? StaffRole.teacher;

    if (dobC.text.trim().isNotEmpty) {
      final parts = dobC.text.trim().split('-');
      if (parts.length == 3) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        final d = int.tryParse(parts[2]);
        if (y != null && m != null && d != null) _dob = DateTime(y, m, d);
      }
    }

    _loadCoursesAndSelection();
  }

  @override
  void dispose() {
    FocusManager.instance.primaryFocus?.unfocus(); // ✅ add this

    firstNameC.dispose();
    lastNameC.dispose();
    dobC.dispose();
    phone1C.dispose();
    phone2C.dispose();
    emailC.dispose();
    passwordC.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(humanizeUiMessage(msg))),
    );
  }

  String get _teacherFullName =>
      '${firstNameC.text.trim()} ${lastNameC.text.trim()}'.trim();

  Future<void> _loadCoursesAndSelection() async {
    try {
      // Load all courses from /courses
      final coursesSnap = await _coursesRef.get();
      final coursesVal = coursesSnap.value;

      final Map<String, Map<String, dynamic>> coursesOut = {};
      if (coursesVal is Map) {
        coursesVal.forEach((key, value) {
          if (key == null || value == null) return;
          if (value is Map) {
            coursesOut[key.toString()] = value.map(
              (k, v) => MapEntry(k.toString(), v),
            );
          }
        });
      }

      // If editing: read /users/{uid}/courses as course_1/course_2 structure
      if (widget.mode == EditorMode.edit && widget.uid != null) {
        final userCoursesSnap = await _usersRef
            .child(widget.uid!)
            .child('courses')
            .get();
        final userCoursesVal = userCoursesSnap.value;

        _selectedCourseIds.clear();
        if (userCoursesVal is Map) {
          userCoursesVal.forEach((k, v) {
            if (v is Map) {
              final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
              final id = (mm['id'] ?? '').toString().trim();
              if (id.isNotEmpty) _selectedCourseIds.add(id);
            }
          });
        }
      }
      // ✅ Save "before" state so we can know what changed on Save
      _initialCourseIds
        ..clear()
        ..addAll(_selectedCourseIds);

      _initialRole = _role;
      _initialTeacherName = _teacherFullName;

      if (!mounted) return;
      setState(() {
        _allCourses = coursesOut;
        _loadingCourses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingCourses = false);
      _snack('Failed to load courses: $e');
    }
  }

  Future<String> _generateNextSerial() async {
    final snap = await _usersRef.get();
    final v = snap.value;

    int max = 0;

    if (v is Map) {
      v.forEach((_, userVal) {
        if (userVal is Map) {
          final m = userVal.map((k, vv) => MapEntry(k.toString(), vv));
          final s = (m['serial'] ?? '').toString().trim(); // ✅ NOW serial

          if (s.contains('-')) {
            final parts = s.split('-');
            final n = int.tryParse(parts.last.trim());
            if (n != null && n > max) max = n;
          }
        }
      });
    }

    final next = max + 1;
    return '000-$next';
  }

  Future<void> _pickDob() async {
    FocusScope.of(context).unfocus();

    final now = DateTime.now();
    final initial = _dob ?? DateTime(now.year - 20, now.month, now.day);

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1940),
      lastDate: DateTime(now.year + 1),
      helpText: 'Select date of birth',
    );

    if (picked == null) return;

    setState(() => _dob = picked);

    String two(int n) => n.toString().padLeft(2, '0');
    dobC.text = '${picked.year}-${two(picked.month)}-${two(picked.day)}';
  }

  // Create auth user WITHOUT cloud functions by using a SECONDARY Firebase app
  Future<String> _createAuthUserAndGetUid({
    required String email,
    required String password,
  }) async {
    final options = Firebase.app().options;
    final name = 'secondary_${DateTime.now().microsecondsSinceEpoch}';
    final secondary = await Firebase.initializeApp(
      name: name,
      options: options,
    );

    try {
      final secondaryAuth = FirebaseAuth.instanceFor(app: secondary);
      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final uid = cred.user?.uid;
      if (uid == null) throw Exception('User created but UID is null.');
      await secondaryAuth.signOut();
      return uid;
    } finally {
      await secondary.delete();
    }
  }

  // --- course label (course_code + title) ---
  String _courseLabelFor(String courseId) {
    final c = _allCourses[courseId];
    final code = (c?['course_code'] ?? '').toString().trim();
    final title = (c?['title'] ?? '').toString().trim();

    final label = [
      if (code.isNotEmpty) code,
      if (title.isNotEmpty) title,
    ].join(' — ');

    return label.isNotEmpty ? label : courseId;
  }

  int _maxCourseIndexFromExisting(dynamic v) {
    if (v is! Map) return 0;
    int maxI = 0;
    v.forEach((k, _) {
      final key = k.toString();
      final m = RegExp(r'^course_(\d+)$').firstMatch(key);
      if (m != null) {
        final n = int.tryParse(m.group(1) ?? '');
        if (n != null && n > maxI) maxI = n;
      }
    });
    return maxI;
  }

  Future<void> _openCoursesPicker() async {
    final tempSelected = Set<String>.from(_selectedCourseIds);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Select courses'),
          content: SizedBox(
            width: double.maxFinite,
            child: _allCourses.isEmpty
                ? const Text('No courses found.')
                : ListView(
                    shrinkWrap: true,
                    children: _allCourses.entries.map((e) {
                      final id = e.key;
                      return CheckboxListTile(
                        value: tempSelected.contains(id),
                        title: Text(_courseLabelFor(id)),
                        subtitle: Text(
                          id,
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.5),
                            fontSize: 12,
                          ),
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (v) {
                          setDialogState(() {
                            if (v == true) {
                              tempSelected.add(id);
                            } else {
                              tempSelected.remove(id);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                setState(() {
                  _selectedCourseIds
                    ..clear()
                    ..addAll(tempSelected);
                });
                Navigator.pop(dialogContext);
              },
              child: const Text('Save selection'),
            ),
          ],
        ),
      ),
    );
  }

  /// Save /users/{uid}/courses as:
  /// course_1, course_2 ... each has id, course_code, title, assignedAt
  /// - does NOT wipe future nodes because it uses update() on paths
  Future<void> _saveUserCourses(String uid) async {
    final coursesRef = _usersRef.child(uid).child('courses');

    if (_selectedCourseIds.isEmpty) {
      await coursesRef.remove();
      return;
    }

    final existingSnap = await coursesRef.get();
    final existingVal = existingSnap.value;

    final Map<String, String> idToKey = {};

    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null || v == null) return;
        if (v is Map) {
          final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          final existingId = (mm['id'] ?? '').toString();
          if (existingId.isNotEmpty) idToKey[existingId] = k.toString();
        }
      });
    }

    int nextIndex = _maxCourseIndexFromExisting(existingVal) + 1;
    final Map<String, dynamic> updates = {};

    // remove unselected
    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null) return;
        final key = k.toString();
        if (!key.startsWith('course_')) return;

        String existingId = '';
        if (v is Map) {
          final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          existingId = (mm['id'] ?? '').toString();
        }

        if (existingId.isNotEmpty && !_selectedCourseIds.contains(existingId)) {
          updates[key] = null;
        }
      });
    }

    // upsert selected
    for (final courseId in _selectedCourseIds) {
      final key = idToKey[courseId] ?? 'course_${nextIndex++}';
      final c = _allCourses[courseId];

      final code = (c?['course_code'] ?? '').toString().trim();
      final title = (c?['title'] ?? c?['name'] ?? c?['level'] ?? '')
          .toString()
          .trim();

      updates['$key/id'] = courseId;
      updates['$key/course_code'] = code;
      updates['$key/title'] = title;
      updates['$key/assignedAt'] = ServerValue.timestamp;
    }

    await coursesRef.update(updates);
  }

  // ----------------------------
  // Course instructors sync (add/remove teacher as {uid, name})
  // Supports old string format during transition
  // ----------------------------

  Future<List<dynamic>> _readInstructorEntries(DatabaseReference ref) async {
    final snap = await ref.get();
    final v = snap.value;

    final out = <dynamic>[];

    if (v is List) {
      for (final item in v) {
        if (item is Map) {
          final mm = item.map((k, vv) => MapEntry(k.toString(), vv));
          final uid = (mm['uid'] ?? '').toString().trim();
          final name = (mm['name'] ?? '').toString().trim();

          if (uid.isNotEmpty || name.isNotEmpty) {
            out.add({'uid': uid, 'name': name});
          }
        } else {
          final s = (item ?? '').toString().trim();
          if (s.isNotEmpty) out.add(s);
        }
      }
    } else if (v is Map) {
      v.forEach((_, item) {
        if (item is Map) {
          final mm = item.map((k, vv) => MapEntry(k.toString(), vv));
          final uid = (mm['uid'] ?? '').toString().trim();
          final name = (mm['name'] ?? '').toString().trim();

          if (uid.isNotEmpty || name.isNotEmpty) {
            out.add({'uid': uid, 'name': name});
          }
        } else {
          final s = (item ?? '').toString().trim();
          if (s.isNotEmpty) out.add(s);
        }
      });
    }

    return out;
  }

  Future<void> _addTeacherToCourse({
    required String courseId,
    required String teacherUid,
    required String teacherName,
  }) async {
    final uid = teacherUid.trim();
    final name = teacherName.trim();
    if (uid.isEmpty || name.isEmpty) return;

    final instrRef = _coursesRef.child(courseId).child('instructors');
    final list = await _readInstructorEntries(instrRef);

    bool exists = false;
    for (final item in list) {
      if (item is Map) {
        final mm = item.map((k, vv) => MapEntry(k.toString(), vv));
        final itemUid = (mm['uid'] ?? '').toString().trim();
        if (itemUid == uid) {
          exists = true;
          break;
        }
      }
    }

    if (!exists) {
      list.add({'uid': uid, 'name': name});
      await instrRef.set(list);
    }
  }

  Future<void> _removeTeacherFromCourse({
    required String courseId,
    required String teacherUid,
    String? fallbackName,
  }) async {
    final uid = teacherUid.trim();
    final oldName = (fallbackName ?? '').trim();

    final instrRef = _coursesRef.child(courseId).child('instructors');
    final list = await _readInstructorEntries(instrRef);

    list.removeWhere((item) {
      if (item is Map) {
        final mm = item.map((k, vv) => MapEntry(k.toString(), vv));
        final itemUid = (mm['uid'] ?? '').toString().trim();
        if (uid.isNotEmpty && itemUid == uid) return true;
        return false;
      }

      // temporary fallback for old string-based data
      final s = item.toString().trim();
      if (uid.isEmpty && oldName.isNotEmpty) {
        return s.toLowerCase() == oldName.toLowerCase();
      }

      if (oldName.isNotEmpty) {
        return s.toLowerCase() == oldName.toLowerCase();
      }

      return false;
    });

    if (list.isEmpty) {
      await instrRef.remove();
    } else {
      await instrRef.set(list);
    }
  }

  Future<void> _renameTeacherInCourse({
    required String courseId,
    required String teacherUid,
    required String newTeacherName,
    String? oldTeacherName,
  }) async {
    final uid = teacherUid.trim();
    final newName = newTeacherName.trim();
    final oldName = (oldTeacherName ?? '').trim();
    if (newName.isEmpty) return;

    final instrRef = _coursesRef.child(courseId).child('instructors');
    final list = await _readInstructorEntries(instrRef);

    bool changed = false;

    for (int i = 0; i < list.length; i++) {
      final item = list[i];

      if (item is Map) {
        final mm = item.map((k, vv) => MapEntry(k.toString(), vv));
        final itemUid = (mm['uid'] ?? '').toString().trim();
        if (uid.isNotEmpty && itemUid == uid) {
          list[i] = {'uid': uid, 'name': newName};
          changed = true;
          break;
        }
      } else {
        final s = item.toString().trim();
        if (oldName.isNotEmpty && s.toLowerCase() == oldName.toLowerCase()) {
          list[i] = {'uid': uid, 'name': newName};
          changed = true;
          break;
        }
      }
    }

    if (!changed) {
      list.add({'uid': uid, 'name': newName});
    }

    await instrRef.set(list);
  }

  Future<void> _syncTeacherInstructors({
    required String teacherUid,
    required Set<String> beforeCourses,
    required Set<String> afterCourses,
    required StaffRole? beforeRole,
    required StaffRole afterRole,
    required String beforeName,
    required String afterName,
  }) async {
    final wasTeacher = (beforeRole ?? StaffRole.other) == StaffRole.teacher;
    final isTeacherNow = afterRole == StaffRole.teacher;

    if (wasTeacher) {
      final removed = isTeacherNow
          ? beforeCourses.difference(afterCourses)
          : beforeCourses;

      for (final courseId in removed) {
        await _removeTeacherFromCourse(
          courseId: courseId,
          teacherUid: teacherUid,
          fallbackName: beforeName,
        );
      }
    }

    if (wasTeacher && isTeacherNow) {
      final still = beforeCourses.intersection(afterCourses);
      final oldN = beforeName.trim();
      final newN = afterName.trim();

      if (oldN.isNotEmpty &&
          newN.isNotEmpty &&
          oldN.toLowerCase() != newN.toLowerCase()) {
        for (final courseId in still) {
          await _renameTeacherInCourse(
            courseId: courseId,
            teacherUid: teacherUid,
            newTeacherName: newN,
            oldTeacherName: oldN,
          );
        }
      }
    }

    if (isTeacherNow) {
      final added = wasTeacher
          ? afterCourses.difference(beforeCourses)
          : afterCourses;

      for (final courseId in added) {
        await _addTeacherToCourse(
          courseId: courseId,
          teacherUid: teacherUid,
          teacherName: afterName,
        );
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      final isCreate = widget.mode == EditorMode.create;
      // ✅ Serial: create only (teacher), keep same on edit
      if (isCreate && _role == StaffRole.teacher && _serial.trim().isEmpty) {
        _serial = await _generateNextSerial();
      }

      final first = firstNameC.text.trim();
      final last = lastNameC.text.trim();
      final email = emailC.text.trim();
      final pass = passwordC.text.trim();

      final dob = dobC.text.trim();
      final phone1 = phone1C.text.trim();
      final phone2 = phone2C.text.trim();

      final nowTs = ServerValue.timestamp;

      String uid;
      if (isCreate) {
        uid = await _createAuthUserAndGetUid(email: email, password: pass);
      } else {
        uid = widget.uid!;
      }

      final staff = Staff(
        uid: uid,
        firstName: first,
        lastName: last,
        dob: dob,
        phone1: phone1,
        phone2: phone2,
        email: email,
        serial: (_role == StaffRole.teacher) ? _serial : '',
        role: _role,
        status: _status,
        updatedAtMs: null,
        profilePhoto: widget.initial?.profilePhoto ?? '',
        profilePhotos: widget.initial?.profilePhotos ?? const <String>[],
      );

      if (isCreate) {
        await _usersRef.child(uid).set({
          ...staff.toMap(),
          'createdAt': nowTs,
          'updatedAt': nowTs,
        });
      } else {
        await _usersRef.child(uid).update({
          ...staff.toMap(),
          'updatedAt': nowTs,
        });
      }

      // BEFORE/AFTER diff for instructors update
      final beforeCourses = Set<String>.from(_initialCourseIds);
      final beforeRole = _initialRole;
      final beforeName = _initialTeacherName;

      if (_role == StaffRole.teacher) {
        await _saveUserCourses(uid);
      } else {
        // ✅ non-teachers must not have courses in DB
        await _usersRef.child(uid).child('courses').remove();
        _selectedCourseIds.clear();
      }

      final afterRole = _role;
      final afterName = _teacherFullName;
      final afterCourses = (_role == StaffRole.teacher)
          ? Set<String>.from(_selectedCourseIds)
          : <String>{};

      // sync instructors in /courses
      await _syncTeacherInstructors(
        teacherUid: uid,
        beforeCourses: beforeCourses,
        afterCourses: afterCourses,
        beforeRole: beforeRole,
        afterRole: afterRole,
        beforeName: beforeName,
        afterName: afterName,
      );

      // update initial cache (so edits stay consistent)
      _initialCourseIds
        ..clear()
        ..addAll(afterCourses);
      _initialRole = afterRole;
      _initialTeacherName = afterName;

      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();

      if (!mounted) return;
      Navigator.of(context).pop(staff);
    } on FirebaseAuthException catch (e) {
      String msg = 'Auth error: ${e.code}';
      if (e.code == 'email-already-in-use') msg = 'Email already exists.';
      if (e.code == 'invalid-email') msg = 'Invalid email.';
      if (e.code == 'weak-password') msg = 'Password is too weak.';
      _snack(msg);
    } catch (e) {
      _snack('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildResponsiveSections(List<Widget> sections) {
    final webWide = isWebDesktop(context, minWidth: 1200);
    if (!webWide) {
      return Column(
        children: [
          for (int i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            sections[i],
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final itemWidth = ((c.maxWidth - 12) / 2).clamp(300.0, 620.0);
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final section in sections)
              SizedBox(width: itemWidth, child: section),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.mode == EditorMode.edit;

    return Scaffold(
      backgroundColor: AdminStaffScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminStaffScreen.primaryBlue),
        title: Text(
          isEdit ? 'Edit Staff' : 'Add Staff',
          style: const TextStyle(
            color: AdminStaffScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                _saving
                    ? 'Saving…'
                    : (isEdit ? 'Save Changes' : 'Create Staff'),
              ),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        child: Form(
          key: _formKey,
          child: adminWebBodyFrame(
            context: context,
            maxWidth: 1380,
            child: _buildResponsiveSections([
              _SectionCard(
                title: 'Personal details',
                child: Column(
                  children: [
                    _TextField(
                      controller: firstNameC,
                      label: 'First name *',
                      hint: 'First name',
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: lastNameC,
                      label: 'Last name *',
                      hint: 'Last name',
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: dobC,
                      readOnly: true,
                      onTap: _pickDob,
                      decoration: InputDecoration(
                        labelText: 'Date of birth',
                        hintText: 'Tap to pick a date',
                        filled: true,
                        fillColor: AdminStaffScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.calendar_month_rounded),
                      ),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Contact',
                child: Column(
                  children: [
                    TextFormField(
                      controller: phone1C,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d+\s-]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Phone 1',
                        hintText: 'Example: 0550 00 00 00',
                        filled: true,
                        fillColor: AdminStaffScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.phone_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: phone2C,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d+\s-]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Phone 2',
                        hintText: 'Optional',
                        filled: true,
                        fillColor: AdminStaffScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.phone_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: emailC,
                      label: 'Email *',
                      hint: 'staff@email.com',
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Required';
                        if (!t.contains('@')) return 'Invalid email';
                        return null;
                      },
                      enabled: !isEdit,
                    ),
                    const SizedBox(height: 12),
                    if (!isEdit)
                      _TextField(
                        controller: passwordC,
                        label: 'Password *',
                        hint: 'Create password',
                        obscureText: true,
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (t.isEmpty) return 'Required';
                          if (t.length < 6) return 'Min 6 characters';
                          return null;
                        },
                      ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Role & status',
                child: Column(
                  children: [
                    DropdownButtonFormField<StaffRole>(
                      initialValue: _role,
                      decoration: InputDecoration(
                        labelText: 'Role',
                        filled: true,
                        fillColor: AdminStaffScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: StaffRole.values
                          .map(
                            (r) => DropdownMenuItem(
                              value: r,
                              child: Text(r.label),
                            ),
                          )
                          .toList(),
                      onChanged: (v) async {
                        if (v == null) return;

                        setState(() {
                          _role = v;

                          // ✅ only teacher can keep courses
                          if (_role != StaffRole.teacher) {
                            _selectedCourseIds.clear();
                            _serial = ''; // ✅ clear serial if not teacher
                          }
                        });

                        // ✅ if switched to teacher in CREATE mode, generate serial now (so it shows before saving)
                        final isCreate = widget.mode == EditorMode.create;
                        if (isCreate &&
                            _role == StaffRole.teacher &&
                            _serial.trim().isEmpty) {
                          final s = await _generateNextSerial();
                          if (!mounted) return;
                          setState(() => _serial = s);
                        }
                      },
                    ),
                    const SizedBox(height: 12),

                    // ✅ Show serial for teachers
                    if (_role == StaffRole.teacher) ...[
                      TextFormField(
                        readOnly: true,
                        controller: TextEditingController(
                          text: _serial.trim().isEmpty
                              ? '(auto on save)'
                              : _serial,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Serial',
                          filled: true,
                          fillColor: AdminStaffScreen.appBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(
                            Icons.confirmation_number_rounded,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    DropdownButtonFormField<StaffStatus>(
                      initialValue: _status,
                      decoration: InputDecoration(
                        labelText: 'Status',
                        filled: true,
                        fillColor: AdminStaffScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: StaffStatus.values
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(s.label),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _status = v);
                      },
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Assign Courses',
                child: _loadingCourses
                    ? const Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('Loading courses...'),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed:
                                (_allCourses.isEmpty ||
                                    _role != StaffRole.teacher)
                                ? null
                                : _openCoursesPicker,
                            icon: const Icon(Icons.school_rounded),
                            label: Text(
                              _selectedCourseIds.isEmpty
                                  ? 'Select courses'
                                  : 'Selected: ${_selectedCourseIds.length}',
                            ),
                          ),
                          if (_role != StaffRole.teacher) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Only teachers can be assigned to courses.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black.withValues(alpha: 0.55),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          if (_selectedCourseIds.isNotEmpty)
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _selectedCourseIds.map((id) {
                                return _Pill(label: _courseLabelFor(id));
                              }).toList(),
                            ),
                          if (_role == StaffRole.teacher &&
                              _selectedCourseIds.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              'Teacher will be added to each course instructors list.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black.withValues(alpha: 0.55),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: AdminStaffScreen.primaryBlue,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
    this.validator,
    this.enabled = true,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final bool enabled;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: 1,
      keyboardType: keyboardType,
      validator: validator,
      enabled: enabled,
      obscureText: obscureText,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: AdminStaffScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ----------------------------
// Model + Parsing
// ----------------------------

enum StaffRole {
  admin,
  teacher,
  internationalTeacher,
  other;

  String get value {
    switch (this) {
      case StaffRole.admin:
        return 'admin';
      case StaffRole.teacher:
        return 'teacher';
      case StaffRole.internationalTeacher:
        return 'oteacher';
      case StaffRole.other:
        return 'other';
    }
  }

  String get label {
    switch (this) {
      case StaffRole.admin:
        return 'Admin';
      case StaffRole.teacher:
        return 'Teacher';
      case StaffRole.internationalTeacher:
        return 'International Teacher';
      case StaffRole.other:
        return 'Other';
    }
  }

  static StaffRole fromValue(String? v) {
    switch ((v ?? '').toLowerCase().trim()) {
      case 'admin':
        return StaffRole.admin;
      case 'teacher':
        return StaffRole.teacher;
      case 'oteacher':
      case 'internationalteacher':
      case 'international_teacher':
        return StaffRole.internationalTeacher;
      case 'other':
      default:
        return StaffRole.other;
    }
  }
}

enum StaffStatus {
  active,
  paused;

  String get value => this == StaffStatus.paused ? 'paused' : 'active';
  String get label => this == StaffStatus.paused ? 'Paused' : 'Active';

  static StaffStatus fromValue(String? v) {
    switch ((v ?? '').toLowerCase().trim()) {
      case 'paused':
        return StaffStatus.paused;
      case 'active':
      default:
        return StaffStatus.active;
    }
  }
}

Color _statusBg(StaffStatus s) {
  switch (s) {
    case StaffStatus.paused:
      return const Color(0xFFFFF3D6);
    case StaffStatus.active:
      return const Color(0xFFDFF7E8);
  }
}

Color _statusFg(StaffStatus s) {
  switch (s) {
    case StaffStatus.paused:
      return const Color(0xFF9A6B00);
    case StaffStatus.active:
      return const Color(0xFF157A3D);
  }
}

class Staff {
  Staff({
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.dob,
    required this.phone1,
    required this.phone2,
    required this.email,
    required this.serial,
    required this.role,
    required this.status,
    required this.updatedAtMs,
    required this.profilePhoto,
    required this.profilePhotos,
  });

  final String uid;
  final String firstName;
  final String lastName;
  final String dob;
  final String phone1;
  final String phone2;
  final String email;
  final String serial; // ✅ serial

  final StaffRole role;
  final StaffStatus status;
  final int? updatedAtMs;
  final String profilePhoto;
  final List<String> profilePhotos;

  String get fullName => '${firstName.trim()} ${lastName.trim()}'.trim();

  String get primaryProfilePhoto {
    if (profilePhoto.trim().isNotEmpty) return profilePhoto.trim();
    for (final p in profilePhotos) {
      if (p.trim().isNotEmpty) return p.trim();
    }
    return '';
  }

  Map<String, dynamic> toMap() {
    return {
      'role': role.value,
      'first_name': firstName,
      'last_name': lastName,
      'dob': dob,
      'phone1': phone1,
      'phone2': phone2,
      'email': email,
      'serial': serial, // ✅ saved in DB as serial
      'status': status.value,
      'updatedAt': updatedAtMs,
      'profile_photo': profilePhoto,
      'profile_photos': profilePhotos,
    };
  }

  factory Staff.fromMap(String uid, Map<dynamic, dynamic> raw) {
    final m = raw.map((k, v) => MapEntry(k.toString(), v));

    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return Staff(
      uid: uid,
      role: StaffRole.fromValue(m['role']?.toString()),
      firstName: (m['first_name'] ?? m['firstName'] ?? '').toString(),
      lastName: (m['last_name'] ?? m['lastName'] ?? '').toString(),
      dob: (m['dob'] ?? '').toString(),
      phone1: (m['phone1'] ?? '').toString(),
      phone2: (m['phone2'] ?? '').toString(),
      email: (m['email'] ?? '').toString(),
      serial: (m['serial'] ?? '').toString(), // ✅ read from DB
      status: StaffStatus.fromValue(m['status']?.toString()),
      updatedAtMs: parseInt(m['updatedAt']),
      profilePhoto: (m['profile_photo'] ?? '').toString().trim(),
      profilePhotos: _stringList(m['profile_photos']),
    );
  }

  static List<String> _stringList(dynamic raw) {
    final out = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final s = item.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out;
    }
    if (raw is Map) {
      final entries = raw.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final e in entries) {
        final s = e.value.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out;
    }
    final one = raw?.toString().trim() ?? '';
    if (one.isNotEmpty) out.add(one);
    return out;
  }
}

class _StaffRow {
  _StaffRow({required this.uid, required this.staff});
  final String uid;
  final Staff staff;
}

List<_StaffRow> _parseStaffMap(dynamic data) {
  if (data == null) return [];

  if (data is Map) {
    final out = <_StaffRow>[];

    const allowed = {'admin', 'teacher', 'oteacher', 'other'}; // staff-only

    data.forEach((key, value) {
      if (key == null || value == null) return;
      if (value is! Map) return;

      final uid = key.toString();
      final staff = Staff.fromMap(uid, value);

      // ✅ robust: works even if stored role is "ADMIN", "Teacher", etc.
      final roleStr = (value['role'] ?? '').toString().toLowerCase().trim();

      // Prefer parsing from raw value to avoid any mismatch
      if (allowed.contains(roleStr)) {
        out.add(_StaffRow(uid: uid, staff: staff));
      }
    });

    return out;
  }

  return [];
}

// ----------------------------
// Teacher Learners Screen
// (Reads learners from /classes where instructor_current.uid == teacherUid)
// ----------------------------
class AdminTeacherLearnersScreen extends StatelessWidget {
  const AdminTeacherLearnersScreen({
    super.key,
    required this.teacherUid,
    required this.teacherName,
  });

  final String teacherUid;
  final String teacherName;

  Widget _statInline(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '$label $value',
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
    );
  }

  Widget _dot() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '•',
        style: TextStyle(
          color: Colors.black.withValues(alpha: 0.4),
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseDatabase.instance;

    return Scaffold(
      appBar: AppBar(
        title: Text(teacherName.isEmpty ? 'Teacher learners' : teacherName),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: db.ref('classes').onValue,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text('Failed to load classes.'));
          }
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snap.data?.snapshot.value;
          if (data == null || data is! Map) {
            return const Center(child: Text('No classes found.'));
          }

          // Collect learners from all classes taught by this teacher
          final Map<String, Map<String, dynamic>> learnersByUid = {};
          int matchingClasses = 0;

          int openClasses = 0;
          int closedClasses = 0;
          int totalEnrollments =
              0; // counts learners across classes (duplicates allowed)

          final classesMap = Map<dynamic, dynamic>.from(data);
          for (final entry in classesMap.entries) {
            final clsRaw = entry.value;
            if (clsRaw is! Map) continue;

            final cls = Map<String, dynamic>.from(clsRaw);

            // Prefer instructor_current.uid (most accurate)
            String instUid = '';
            final instCur = cls['instructor_current'];
            if (instCur is Map) {
              final m = Map<String, dynamic>.from(instCur);
              instUid = (m['uid'] ?? '').toString().trim();
            }

            // Fallback (only if uid missing): match name (best-effort)
            final instName = (cls['instructor'] ?? '').toString().trim();

            final isThisTeacher =
                (instUid.isNotEmpty && instUid == teacherUid) ||
                (instUid.isEmpty &&
                    teacherName.trim().isNotEmpty &&
                    instName.toLowerCase().trim() ==
                        teacherName.toLowerCase().trim());

            if (!isThisTeacher) continue;

            matchingClasses++;

            final isOpen = (cls['is_open'] ?? true) == true;
            if (isOpen) {
              openClasses++;
            } else {
              closedClasses++;
            }

            final learnersRaw = cls['learners'];
            if (learnersRaw is! Map) continue;

            final learnersMap = Map<dynamic, dynamic>.from(learnersRaw);

            // total enrollments = sum of learners in each matching class
            totalEnrollments += learnersMap.length;

            for (final l in learnersMap.entries) {
              final learnerUid = l.key.toString();
              final val = l.value;

              String name = 'Unnamed';
              String serial = 'N/A';

              if (val is Map) {
                final mm = Map<String, dynamic>.from(val);
                final n = (mm['name'] ?? '').toString().trim();
                final s = (mm['serial'] ?? '').toString().trim();
                if (n.isNotEmpty) name = n;
                if (s.isNotEmpty) serial = s;
              }

              // Store/overwrite basic data (unique by uid)
              learnersByUid[learnerUid] = {
                'uid': learnerUid,
                'name': name,
                'serial': serial,
              };
            }
          }

          final learnersList = learnersByUid.values.toList();
          learnersList.sort((a, b) {
            final an = (a['name'] ?? '').toString();
            final bn = (b['name'] ?? '').toString();
            return an.compareTo(bn);
          });

          if (matchingClasses == 0) {
            return const Center(child: Text('This teacher has no classes.'));
          }

          if (learnersList.isEmpty) {
            return const Center(
              child: Text('No learners found for this teacher.'),
            );
          }

          final uniqueLearners = learnersList.length;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.black.withValues(alpha: 0.06),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.12),
                    ),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _statInline('Learners', uniqueLearners.toString()),
                        _dot(),
                        _statInline('Classes', matchingClasses.toString()),
                        _dot(),
                        _statInline('OvC', '$openClasses/$closedClasses'),
                        _dot(),
                        _statInline('Enr', totalEnrollments.toString()),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: learnersList.length,
                  itemBuilder: (context, i) {
                    final l = learnersList[i];
                    final name = (l['name'] ?? '').toString();
                    final serial = (l['serial'] ?? '').toString();

                    return Card(
                      elevation: 0,
                      child: ListTile(
                        title: Text(
                          name.isEmpty ? 'Unnamed' : name,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          'Serial: ${serial.isEmpty ? 'N/A' : serial}',
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
