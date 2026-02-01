import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'package:firebase_core/firebase_core.dart';

class AdminLearnersScreen extends StatefulWidget {
  const AdminLearnersScreen({super.key});

  // Brand palette (match your admin screens)
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const accentCyan = Color(0xFF00D4FF);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorders = Color(0xFFD1D9E0);

  @override
  State<AdminLearnersScreen> createState() => _AdminLearnersScreenState();
}

class _AdminLearnersScreenState extends State<AdminLearnersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  final _db = FirebaseDatabase.instance;

  // Nodes
  static const _usersPath = 'users';
  static const _blockedPath = 'users_blocked';
  static const _deletedPath = 'users_deleted';
  static const _coursesPath = 'courses';

  String _search = '';

  DatabaseReference get _usersRef => _db.ref(_usersPath);
  DatabaseReference get _blockedRef => _db.ref(_blockedPath);
  DatabaseReference get _deletedRef => _db.ref(_deletedPath);
  DatabaseReference get _coursesRef => _db.ref(_coursesPath);

  // Courses cache for dropdown
  List<_CoursePick> _courses = [];
  bool _loadingCourses = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _loadCourses();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadCourses() async {
    setState(() => _loadingCourses = true);
    try {
      final snap = await _coursesRef.get();
      final v = snap.value;
      final list = <_CoursePick>[];

      if (v is Map) {
        v.forEach((key, value) {
          if (key == null || value == null) return;
          if (value is Map) {
            final title = (value['title'] ?? '').toString().trim();
            if (title.isEmpty) return;
            list.add(_CoursePick(id: key.toString(), title: title));
          }
        });
      }

      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

      if (!mounted) return;
      setState(() => _courses = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _courses = []);
    } finally {
      if (mounted) setState(() => _loadingCourses = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminLearnersScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminLearnersScreen.primaryBlue),
        title: const Text(
          'Learners',
          style: TextStyle(
            color: AdminLearnersScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        bottom: TabBar(
          controller: _tab,
          labelColor: AdminLearnersScreen.primaryBlue,
          unselectedLabelColor: AdminLearnersScreen.primaryBlue.withOpacity(0.55),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Learners'),
            Tab(text: 'Blocked'),
            Tab(text: 'Deleted'),
          ],
        ),
        actions: [
          AnimatedBuilder(
            animation: _tab,
            builder: (context, _) {
              final onLearnersTab = _tab.index == 0;
              if (!onLearnersTab) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Add learner',
                icon: const Icon(Icons.person_add_alt_1, color: AdminLearnersScreen.actionOrange),
                onPressed: () async {
                  await _openLearnerEditorCreate(context);
                },
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _TopSearch(
            value: _search,
            onChanged: (v) => setState(() => _search = v),
            onRefreshCourses: _loadCourses,
            coursesLoading: _loadingCourses,
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _LearnersList(
                  stream: _usersRef.onValue,
                  search: _search,
                  emptyMessage: 'No learners yet. Tap + to add the first learner.',
                  onEdit: _openLearnerEditorEditActive,
                  onPauseToggle: _pauseToggleActive,
                  onBlock: _blockActive,
                  onDelete: _deleteActive,
                ),
                _LearnersList(
                  stream: _blockedRef.onValue,
                  search: _search,
                  emptyMessage: 'No blocked learners.',
                  onEdit: null, // typically don’t edit blocked; you can enable if you want
                  onPauseToggle: null,
                  onBlock: _unblockToActive,
                  onDelete: _deleteFromBlocked,
                  isBlockedTab: true,
                ),
                _LearnersList(
                  stream: _deletedRef.onValue,
                  search: _search,
                  emptyMessage: 'No deleted learners.',
                  onEdit: null,
                  onPauseToggle: null,
                  onBlock: null,
                  onDelete: null,
                  isDeletedTab: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // CREATE learner: secondary auth app (NO admin sign-out)
  // ------------------------------------------------------------
  Future<void> _openLearnerEditorCreate(BuildContext context) async {
    final result = await showModalBottomSheet<_LearnerFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LearnerEditorSheet(
        title: 'Add Learner',
        courses: _courses,
        initial: null,
        requirePassword: true,
      ),
    );

    if (result == null) return;

    // 1) Create Auth user via secondary app
    try {
      final secondary = await _getOrCreateSecondaryApp();

      final secondaryAuth = FirebaseAuth.instanceFor(app: secondary);

      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: result.email.trim(),
        password: result.password!.trim(),
      );

      final uid = cred.user?.uid;
      if (uid == null) {
        throw Exception('Auth created but UID is null (unexpected).');
      }

      // 2) Save profile to RTDB users/{uid}
      final nowTs = ServerValue.timestamp;

      final data = {
        'role': 'learner',
        'status': 'active',
        'serial': result.serial.trim(),
        'firstName': result.firstName.trim(),
        'lastName': result.lastName.trim(),
        'dob': result.dob.trim(), // YYYY-MM-DD
        'phone1': result.phone1.trim(),
        'phone2': result.phone2.trim(),
        'email': result.email.trim(),
        'courseId': result.courseId?.trim() ?? '',
        'courseTitle': result.courseTitle?.trim() ?? '',
        'createdAt': nowTs,
        'updatedAt': nowTs,
      };

      await _usersRef.child(uid).set(data);

      // 3) Cleanup: sign out secondary (admin stays logged in)
      await secondaryAuth.signOut();

      if (!mounted) return;
      _snack('Learner created ✅');
    } catch (e) {
      if (!mounted) return;
      _snack('Create failed: $e');
    }
  }

  Future<FirebaseApp> _getOrCreateSecondaryApp() async {
    try {
      return Firebase.app('secondary');
    } catch (_) {
      return Firebase.initializeApp(
        name: 'secondary',
        options: Firebase.app().options, // ✅ re-use your default app options
      );
    }
  }


  // ------------------------------------------------------------
  // EDIT active learner (profile only; auth email/password not changed here)
  // ------------------------------------------------------------
  Future<void> _openLearnerEditorEditActive(BuildContext context, String uid, _LearnerRow row) async {
    final result = await showModalBottomSheet<_LearnerFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LearnerEditorSheet(
        title: 'Edit Learner',
        courses: _courses,
        initial: row,
        requirePassword: false, // don’t ask password on edit
      ),
    );

    if (result == null) return;

    try {
      await _usersRef.child(uid).update({
        'serial': result.serial.trim(),
        'firstName': result.firstName.trim(),
        'lastName': result.lastName.trim(),
        'dob': result.dob.trim(),
        'phone1': result.phone1.trim(),
        'phone2': result.phone2.trim(),
        'email': result.email.trim(), // (note: auth email not changed here)
        'courseId': result.courseId?.trim() ?? '',
        'courseTitle': result.courseTitle?.trim() ?? '',
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      _snack('Updated ✅');
    } catch (e) {
      if (!mounted) return;
      _snack('Update failed: $e');
    }
  }

  // ------------------------------------------------------------
  // PAUSE / RESUME (active tab)
  // ------------------------------------------------------------
  Future<void> _pauseToggleActive(BuildContext context, String uid, _LearnerRow row) async {
    final current = (row.status.isEmpty ? 'active' : row.status);
    final next = current == 'paused' ? 'active' : 'paused';

    final ok = await _confirm(
      context,
      title: next == 'paused' ? 'Pause learner?' : 'Resume learner?',
      message: next == 'paused'
          ? 'This learner will stay in users, but status becomes paused.'
          : 'This learner will become active again.',
      confirmText: next == 'paused' ? 'Pause' : 'Resume',
      danger: next == 'paused',
    );
    if (!ok) return;

    await _usersRef.child(uid).update({
      'status': next,
      'updatedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    _snack(next == 'paused' ? 'Paused ⏸️' : 'Resumed ▶️');
  }

  // ------------------------------------------------------------
  // BLOCK (move users/{uid} -> users_blocked/{uid})
  // ------------------------------------------------------------
  Future<void> _blockActive(BuildContext context, String uid, _LearnerRow row) async {
    final ok = await _confirm(
      context,
      title: 'Block learner?',
      message: 'This will move the learner to users_blocked.',
      confirmText: 'Block',
      danger: true,
    );
    if (!ok) return;

    final adminUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    final data = row.toMap()
      ..addAll({
        'status': 'blocked',
        'blockedAt': ServerValue.timestamp,
        'blockedBy': adminUid,
      });

    await _blockedRef.child(uid).set(data);
    await _usersRef.child(uid).remove();

    if (!mounted) return;
    _snack('Blocked 🚫');
  }

  // UNBLOCK (move users_blocked/{uid} -> users/{uid})
  Future<void> _unblockToActive(BuildContext context, String uid, _LearnerRow row) async {
    final ok = await _confirm(
      context,
      title: 'Unblock learner?',
      message: 'This will move the learner back to users.',
      confirmText: 'Unblock',
    );
    if (!ok) return;

    final data = row.toMap()
      ..addAll({
        'status': 'active',
        'updatedAt': ServerValue.timestamp,
      })
      ..remove('blockedAt')
      ..remove('blockedBy')
      ..remove('blockedReason');

    await _usersRef.child(uid).set(data);
    await _blockedRef.child(uid).remove();

    if (!mounted) return;
    _snack('Unblocked ✅');
  }

  // ------------------------------------------------------------
  // DELETE (move users/{uid} -> users_deleted/{uid})
  // ------------------------------------------------------------
  Future<void> _deleteActive(BuildContext context, String uid, _LearnerRow row) async {
    final ok = await _confirm(
      context,
      title: 'Delete learner?',
      message: 'This will move the learner to users_deleted.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    final adminUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    final data = row.toMap()
      ..addAll({
        'status': 'deleted',
        'deletedAt': ServerValue.timestamp,
        'deletedBy': adminUid,
      });

    await _deletedRef.child(uid).set(data);
    await _usersRef.child(uid).remove();

    if (!mounted) return;
    _snack('Moved to Deleted 🗑️');
  }

  Future<void> _deleteFromBlocked(BuildContext context, String uid, _LearnerRow row) async {
    final ok = await _confirm(
      context,
      title: 'Delete blocked learner?',
      message: 'This will move the learner to users_deleted.',
      confirmText: 'Delete',
      danger: true,
    );
    if (!ok) return;

    final adminUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    final data = row.toMap()
      ..addAll({
        'status': 'deleted',
        'deletedAt': ServerValue.timestamp,
        'deletedBy': adminUid,
      });

    await _deletedRef.child(uid).set(data);
    await _blockedRef.child(uid).remove();

    if (!mounted) return;
    _snack('Moved to Deleted 🗑️');
  }

  // ------------------------------------------------------------
  // UI helpers
  // ------------------------------------------------------------
  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirm(
      BuildContext context, {
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
}

// ============================================================
// LIST WIDGET (reusable for active/blocked/deleted)
// ============================================================

class _LearnersList extends StatelessWidget {
  const _LearnersList({
    required this.stream,
    required this.search,
    required this.emptyMessage,
    required this.onEdit,
    required this.onPauseToggle,
    required this.onBlock,
    required this.onDelete,
    this.isBlockedTab = false,
    this.isDeletedTab = false,
  });

  final Stream<DatabaseEvent> stream;
  final String search;
  final String emptyMessage;

  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onEdit;
  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onPauseToggle;
  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onBlock; // block OR unblock
  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onDelete;

  final bool isBlockedTab;
  final bool isDeletedTab;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return const _StateCard(
            title: 'Error',
            message: 'Could not load learners.',
            icon: Icons.error_outline,
          );
        }
        if (!snap.hasData) {
          return const _LoadingList();
        }

        final v = snap.data!.snapshot.value;
        final rows = _parseLearnersMap(v);

        // filter: learners only
        final filteredRole = rows.where((r) => r.row.role == 'learner').toList();

        // search
        final q = search.trim().toLowerCase();
        final filtered = q.isEmpty
            ? filteredRole
            : filteredRole.where((r) {
          final s = '${r.row.firstName} ${r.row.lastName} ${r.row.email} ${r.row.serial}'
              .toLowerCase();
          return s.contains(q);
        }).toList();

        // sort by updatedAt desc (fallback createdAt)
        filtered.sort((a, b) => (b.row.updatedAtMs ?? b.row.createdAtMs ?? 0)
            .compareTo(a.row.updatedAtMs ?? a.row.createdAtMs ?? 0));

        if (filtered.isEmpty) {
          return _StateCard(
            title: 'No results',
            message: emptyMessage,
            icon: Icons.people_outline,
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          itemCount: filtered.length,
          itemBuilder: (context, i) {
            final item = filtered[i];
            return _LearnerCard(
              uid: item.id,
              row: item.row,
              isBlockedTab: isBlockedTab,
              isDeletedTab: isDeletedTab,
              onEdit: onEdit,
              onPauseToggle: onPauseToggle,
              onBlock: onBlock,
              onDelete: onDelete,
            );
          },
        );
      },
    );
  }
}

class _LearnerCard extends StatelessWidget {
  const _LearnerCard({
    required this.uid,
    required this.row,
    required this.isBlockedTab,
    required this.isDeletedTab,
    required this.onEdit,
    required this.onPauseToggle,
    required this.onBlock,
    required this.onDelete,
  });

  final String uid;
  final _LearnerRow row;

  final bool isBlockedTab;
  final bool isDeletedTab;

  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onEdit;
  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onPauseToggle;
  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onBlock; // block OR unblock
  final Future<void> Function(BuildContext, String uid, _LearnerRow row)? onDelete;

  @override
  Widget build(BuildContext context) {
    final fullName = '${row.firstName} ${row.lastName}'.trim();
    final subtitle = row.email.isNotEmpty ? row.email : '(no email)';

    final status = row.status.isEmpty ? 'active' : row.status;
    final statusLabel = status == 'paused'
        ? 'Paused'
        : status == 'blocked'
        ? 'Blocked'
        : status == 'deleted'
        ? 'Deleted'
        : 'Active';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _Avatar(name: fullName.isEmpty ? 'L' : fullName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fullName.isEmpty ? '(Unnamed learner)' : fullName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: AdminLearnersScreen.primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.black.withOpacity(0.6), fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Pill(
                        label: statusLabel,
                        bg: _statusBg(status),
                        fg: _statusFg(status),
                      ),
                      if (row.serial.isNotEmpty) _Pill(label: row.serial),
                      if (row.phone1.isNotEmpty) _Pill(label: row.phone1),
                      if (row.courseTitle.isNotEmpty) _Pill(label: row.courseTitle),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<_LearnerAction>(
              tooltip: 'Actions',
              onSelected: (a) async {
                switch (a) {
                  case _LearnerAction.edit:
                    if (onEdit != null) await onEdit!(context, uid, row);
                    break;
                  case _LearnerAction.pauseToggle:
                    if (onPauseToggle != null) await onPauseToggle!(context, uid, row);
                    break;
                  case _LearnerAction.blockToggle:
                    if (onBlock != null) await onBlock!(context, uid, row);
                    break;
                  case _LearnerAction.deleteMove:
                    if (onDelete != null) await onDelete!(context, uid, row);
                    break;
                }
              },
              itemBuilder: (_) {
                if (isDeletedTab) {
                  return const [
                    PopupMenuItem(
                      value: _LearnerAction.edit,
                      enabled: false,
                      child: Text('Deleted record'),
                    ),
                  ];
                }

                final items = <PopupMenuEntry<_LearnerAction>>[];

                if (!isBlockedTab) {
                  items.add(
                    const PopupMenuItem(
                      value: _LearnerAction.edit,
                      child: Text('Edit'),
                    ),
                  );
                  if (onPauseToggle != null) {
                    items.add(
                      PopupMenuItem(
                        value: _LearnerAction.pauseToggle,
                        child: Text(row.status == 'paused' ? 'Resume' : 'Pause'),
                      ),
                    );
                  }
                }

                if (onBlock != null) {
                  items.add(const PopupMenuDivider());
                  items.add(
                    PopupMenuItem(
                      value: _LearnerAction.blockToggle,
                      child: Text(isBlockedTab ? 'Unblock' : 'Block'),
                    ),
                  );
                }

                if (onDelete != null) {
                  items.add(
                    const PopupMenuDivider(),
                  );
                  items.add(
                    const PopupMenuItem(
                      value: _LearnerAction.deleteMove,
                      child: Text('Delete'),
                    ),
                  );
                }

                return items;
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _LearnerAction { edit, pauseToggle, blockToggle, deleteMove }

class _TopSearch extends StatelessWidget {
  const _TopSearch({
    required this.value,
    required this.onChanged,
    required this.onRefreshCourses,
    required this.coursesLoading,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefreshCourses;
  final bool coursesLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              onChanged: onChanged,
              decoration: InputDecoration(
                hintText: 'Search learners…',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: AdminLearnersScreen.appBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Refresh courses for dropdown',
            onPressed: coursesLoading ? null : onRefreshCourses,
            icon: coursesLoading
                ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
                : const Icon(Icons.refresh, color: AdminLearnersScreen.primaryBlue),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? 'L' : name.trim()[0].toUpperCase();
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AdminLearnersScreen.appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AdminLearnersScreen.uiBorders),
      ),
      child: Text(
        letter,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: AdminLearnersScreen.primaryBlue,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg ?? AdminLearnersScreen.appBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: fg ?? AdminLearnersScreen.primaryBlue,
        ),
      ),
    );
  }
}

Color _statusBg(String status) {
  switch (status) {
    case 'paused':
      return const Color(0xFFFFF3D6);
    case 'blocked':
      return const Color(0xFFFFE8EA);
    case 'deleted':
      return const Color(0xFFE8E8E8);
    case 'active':
    default:
      return const Color(0xFFDFF7E8);
  }
}

Color _statusFg(String status) {
  switch (status) {
    case 'paused':
      return const Color(0xFF9A6B00);
    case 'blocked':
      return const Color(0xFFB00020);
    case 'deleted':
      return const Color(0xFF444444);
    case 'active':
    default:
      return const Color(0xFF157A3D);
  }
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
              Icon(icon, size: 36, color: AdminLearnersScreen.primaryBlue),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: AdminLearnersScreen.primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black.withOpacity(0.7)),
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
              SizedBox(width: 46, height: 46, child: ColoredBox(color: AdminLearnersScreen.appBg)),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 14, width: 160, child: ColoredBox(color: AdminLearnersScreen.appBg)),
                    SizedBox(height: 10),
                    SizedBox(height: 12, width: 260, child: ColoredBox(color: AdminLearnersScreen.appBg)),
                    SizedBox(height: 10),
                    SizedBox(height: 12, width: 200, child: ColoredBox(color: AdminLearnersScreen.appBg)),
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

// ============================================================
// LEARNER EDITOR SHEET
// ============================================================

class _LearnerEditorSheet extends StatefulWidget {
  const _LearnerEditorSheet({
    required this.title,
    required this.courses,
    required this.initial,
    required this.requirePassword,
  });

  final String title;
  final List<_CoursePick> courses;
  final _LearnerRow? initial;
  final bool requirePassword;

  @override
  State<_LearnerEditorSheet> createState() => _LearnerEditorSheetState();
}

class _LearnerEditorSheetState extends State<_LearnerEditorSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController firstNameC;
  late final TextEditingController lastNameC;
  late final TextEditingController dobC;
  late final TextEditingController phone1C;
  late final TextEditingController phone2C;
  late final TextEditingController emailC;
  late final TextEditingController passwordC;
  late final TextEditingController serialC;

  String? _courseId;
  String? _courseTitle;

  @override
  void initState() {
    super.initState();

    final i = widget.initial;
    firstNameC = TextEditingController(text: i?.firstName ?? '');
    lastNameC = TextEditingController(text: i?.lastName ?? '');
    dobC = TextEditingController(text: i?.dob ?? ''); // YYYY-MM-DD
    phone1C = TextEditingController(text: i?.phone1 ?? '');
    phone2C = TextEditingController(text: i?.phone2 ?? '');
    emailC = TextEditingController(text: i?.email ?? '');
    passwordC = TextEditingController(text: '');
    serialC = TextEditingController(text: i?.serial ?? '');

    _courseId = (i?.courseId.trim().isNotEmpty == true) ? i!.courseId : null;
    _courseTitle = (i?.courseTitle.trim().isNotEmpty == true) ? i!.courseTitle : null;
  }

  @override
  void dispose() {
    firstNameC.dispose();
    lastNameC.dispose();
    dobC.dispose();
    phone1C.dispose();
    phone2C.dispose();
    emailC.dispose();
    passwordC.dispose();
    serialC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: AdminLearnersScreen.appBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: AdminLearnersScreen.primaryBlue,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        _section(
                          title: 'Personal',
                          child: Column(
                            children: [
                              _tf(
                                controller: serialC,
                                label: 'Student serial number *',
                                hint: 'Example: STU-2026-000123',
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: _tf(
                                      controller: firstNameC,
                                      label: 'First name *',
                                      hint: 'Name',
                                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _tf(
                                      controller: lastNameC,
                                      label: 'Last name *',
                                      hint: 'Last name',
                                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _tf(
                                controller: dobC,
                                label: 'Date of birth',
                                hint: 'YYYY-MM-DD',
                                validator: (v) {
                                  final t = (v ?? '').trim();
                                  if (t.isEmpty) return null;
                                  final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t);
                                  return ok ? null : 'Use YYYY-MM-DD';
                                },
                              ),
                              const SizedBox(height: 12),
                              _tf(
                                controller: phone1C,
                                label: 'Phone 1',
                                hint: '+213...',
                              ),
                              const SizedBox(height: 12),
                              _tf(
                                controller: phone2C,
                                label: 'Phone 2',
                                hint: 'Optional',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _section(
                          title: 'Account',
                          child: Column(
                            children: [
                              _tf(
                                controller: emailC,
                                label: 'Email *',
                                hint: 'learner@email.com',
                                keyboardType: TextInputType.emailAddress,
                                validator: (v) {
                                  final t = (v ?? '').trim();
                                  if (t.isEmpty) return 'Required';
                                  if (!t.contains('@')) return 'Invalid email';
                                  return null;
                                },
                              ),
                              const SizedBox(height: 12),
                              if (widget.requirePassword) ...[
                                _tf(
                                  controller: passwordC,
                                  label: 'Password *',
                                  hint: 'At least 6 characters',
                                  obscureText: true,
                                  validator: (v) {
                                    final t = (v ?? '').trim();
                                    if (t.isEmpty) return 'Required';
                                    if (t.length < 6) return 'Min 6 characters';
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 12),
                              ],
                              _courseDropdown(),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _submit,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: Text('Save'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _courseDropdown() {
    return DropdownButtonFormField<String>(
      value: _courseId,
      decoration: InputDecoration(
        labelText: 'Link to course (optional)',
        filled: true,
        fillColor: AdminLearnersScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      items: [
        const DropdownMenuItem<String>(
          value: null,
          child: Text('None'),
        ),
        ...widget.courses.map(
              (c) => DropdownMenuItem<String>(
            value: c.id,
            child: Text(c.title),
          ),
        ),
      ],
      onChanged: (v) {
        setState(() {
          _courseId = v;
          _courseTitle = widget.courses.firstWhere((x) => x.id == v, orElse: () => const _CoursePick(id: '', title: '')).title;
          if ((_courseId ?? '').trim().isEmpty) {
            _courseId = null;
            _courseTitle = null;
          }
        });
      },
    );
  }

  Widget _section({required String title, required Widget child}) {
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
                color: AdminLearnersScreen.primaryBlue,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _tf({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboardType,
    bool obscureText = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: AdminLearnersScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.pop(
      context,
      _LearnerFormResult(
        serial: serialC.text,
        firstName: firstNameC.text,
        lastName: lastNameC.text,
        dob: dobC.text,
        phone1: phone1C.text,
        phone2: phone2C.text,
        email: emailC.text,
        password: widget.requirePassword ? passwordC.text : null,
        courseId: _courseId,
        courseTitle: _courseTitle,
      ),
    );
  }
}

// ============================================================
// DATA
// ============================================================

class _CoursePick {
  const _CoursePick({required this.id, required this.title});
  final String id;
  final String title;
}

class _LearnerFormResult {
  _LearnerFormResult({
    required this.serial,
    required this.firstName,
    required this.lastName,
    required this.dob,
    required this.phone1,
    required this.phone2,
    required this.email,
    required this.password,
    required this.courseId,
    required this.courseTitle,
  });

  final String serial;
  final String firstName;
  final String lastName;
  final String dob;
  final String phone1;
  final String phone2;
  final String email;
  final String? password;

  final String? courseId;
  final String? courseTitle;
}

class _LearnerRow {
  _LearnerRow({
    required this.role,
    required this.status,
    required this.serial,
    required this.firstName,
    required this.lastName,
    required this.dob,
    required this.phone1,
    required this.phone2,
    required this.email,
    required this.courseId,
    required this.courseTitle,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String role;
  final String status;
  final String serial;

  final String firstName;
  final String lastName;
  final String dob;

  final String phone1;
  final String phone2;

  final String email;

  final String courseId;
  final String courseTitle;

  final int? createdAtMs;
  final int? updatedAtMs;

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'status': status,
      'serial': serial,
      'firstName': firstName,
      'lastName': lastName,
      'dob': dob,
      'phone1': phone1,
      'phone2': phone2,
      'email': email,
      'courseId': courseId,
      'courseTitle': courseTitle,
      'createdAt': createdAtMs,
      'updatedAt': updatedAtMs,
    };
  }

  factory _LearnerRow.fromMap(Map<dynamic, dynamic> m) {
    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return _LearnerRow(
      role: (m['role'] ?? 'learner').toString(),
      status: (m['status'] ?? 'active').toString(),
      serial: (m['serial'] ?? '').toString(),
      firstName: (m['firstName'] ?? '').toString(),
      lastName: (m['lastName'] ?? '').toString(),
      dob: (m['dob'] ?? '').toString(),
      phone1: (m['phone1'] ?? '').toString(),
      phone2: (m['phone2'] ?? '').toString(),
      email: (m['email'] ?? '').toString(),
      courseId: (m['courseId'] ?? '').toString(),
      courseTitle: (m['courseTitle'] ?? '').toString(),
      createdAtMs: parseInt(m['createdAt']),
      updatedAtMs: parseInt(m['updatedAt']),
    );
  }
}

class _LearnerIdRow {
  _LearnerIdRow({required this.id, required this.row});
  final String id;
  final _LearnerRow row;
}

List<_LearnerIdRow> _parseLearnersMap(dynamic data) {
  if (data == null) return [];

  if (data is Map) {
    final out = <_LearnerIdRow>[];
    data.forEach((key, value) {
      if (key == null || value == null) return;
      if (value is Map) {
        final row = _LearnerRow.fromMap(value);
        out.add(_LearnerIdRow(id: key.toString(), row: row));
      }
    });
    return out;
  }
  return [];
}
