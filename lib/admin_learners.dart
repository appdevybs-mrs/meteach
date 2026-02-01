import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class AdminLearnersScreen extends StatefulWidget {
  const AdminLearnersScreen({super.key});

  // Brand palette (match your style)
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
  late final Stream<DatabaseEvent> _usersStream;
  late final Stream<DatabaseEvent> _deletedStream;
  late final Stream<DatabaseEvent> _blockedStream;

  // Nodes (as you requested)
// Nodes (match your DB)
  static const _usersPath   = 'users';
  static const _deletedPath = 'users_deleted';   // <-- was 'deleted'
  static const _blockedPath = 'users_blocked';   // <-- only if this is your real node name


  // UI state
  String _search = '';
  LearnerStatus? _statusFilter; // only used on Users tab

  DatabaseReference get _usersRef => _db.ref(_usersPath);
  DatabaseReference get _deletedRef => _db.ref(_deletedPath);
  DatabaseReference get _blockedRef => _db.ref(_blockedPath);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);

    // ✅ Make them broadcast ONCE here
    _usersStream   = _usersRef.onValue.asBroadcastStream();
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  Future<void> _pauseLearner(String uid) async {
    await _usersRef.child(uid).update({
      'status': LearnerStatus.paused.value,
      'updatedAt': ServerValue.timestamp,
    });
    _snack('Learner paused ✅');
  }

  Future<void> _activateLearner(String uid) async {
    await _usersRef.child(uid).update({
      'status': LearnerStatus.active.value,
      'updatedAt': ServerValue.timestamp,
    });
    _snack('Learner activated ✅');
  }

  Future<void> _moveToDeleted(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Delete learner?',
      message:
      'This will move the learner to "deleted".\n\nYou can restore later.',
      confirmText: 'Move to deleted',
      danger: true,
    );
    if (!ok) return;

    final data = learner.toMap()
      ..addAll({
        'movedAt': ServerValue.timestamp,
        'movedFrom': _usersPath,
      });

    await _deletedRef.child(uid).set(data);
    await _usersRef.child(uid).remove();

    _snack('Moved to deleted 🗑️');
  }

  Future<void> _moveToBlocked(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Block learner?',
      message:
      'This will move the learner to "blocked".\n\nYou can restore later.',
      confirmText: 'Block',
      danger: true,
    );
    if (!ok) return;

    final data = learner.toMap()
      ..addAll({
        'movedAt': ServerValue.timestamp,
        'movedFrom': _usersPath,
      });

    await _blockedRef.child(uid).set(data);
    await _usersRef.child(uid).remove();

    _snack('Moved to blocked ⛔');
  }

  Future<void> _restoreFromDeleted(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Restore learner?',
      message: 'This will restore the learner back to users.',
      confirmText: 'Restore',
    );
    if (!ok) return;

    final data = learner.toMap()
      ..remove('movedAt')
      ..remove('movedFrom')
      ..addAll({'updatedAt': ServerValue.timestamp});

    await _usersRef.child(uid).set(data);
    await _deletedRef.child(uid).remove();

    _snack('Restored ✅');
  }

  Future<void> _restoreFromBlocked(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Unblock learner?',
      message: 'This will restore the learner back to users.',
      confirmText: 'Unblock',
    );
    if (!ok) return;

    final data = learner.toMap()
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
          unselectedLabelColor:
          AdminLearnersScreen.primaryBlue.withOpacity(0.55),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Users'),
            Tab(text: 'Deleted'),
            Tab(text: 'Blocked'),
          ],
        ),
        actions: [
          AnimatedBuilder(
            animation: _tab,
            builder: (_, __) {
              final isUsersTab = _tab.index == 0;
              if (!isUsersTab) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Add learner',
                icon: const Icon(Icons.person_add_alt_1_rounded,
                    color: AdminLearnersScreen.actionOrange),
                onPressed: () async {
                  final created = await Navigator.of(context).push<Learner?>(
                    MaterialPageRoute(
                      builder: (_) => LearnerEditorScreen(
                        mode: EditorMode.create,
                      ),
                    ),
                  );
                  if (created != null) _snack('Learner created ✅');
                },
              );
            },
          ),
        ],
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _LearnersList(
            titleHint: 'Search learners…',
            stream: _usersStream, // ✅ use the stream created in initState
            search: _search,
            statusFilter: _statusFilter,
            onSearchChanged: (v) => setState(() => _search = v),
            onStatusFilterChanged: (s) => setState(() => _statusFilter = s),
            onEdit: (uid, learner) async {
              final updated = await Navigator.of(context).push<Learner?>(
                MaterialPageRoute(
                  builder: (_) => LearnerEditorScreen(
                    mode: EditorMode.edit,
                    uid: uid,
                    initial: learner,
                  ),
                ),
              );
              if (updated != null) _snack('Learner updated ✅');
            },
            actionsBuilder: (uid, learner) => [
              PopupMenuItem(
                value: _RowAction.pause,
                child: Text(
                  learner.status == LearnerStatus.paused ? 'Activate' : 'Pause',
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
            onAction: (uid, learner, action) async {
              switch (action) {
                case _RowAction.pause:
                  if (learner.status == LearnerStatus.paused) {
                    await _activateLearner(uid);
                  } else {
                    await _pauseLearner(uid);
                  }
                  break;
                case _RowAction.block:
                  await _moveToBlocked(uid, learner);
                  break;
                case _RowAction.delete:
                  await _moveToDeleted(uid, learner);
                  break;
                default:
                  break;
              }
            },
          ),

          _LearnersList(
            titleHint: 'Search deleted…',
            stream: _deletedStream, // ✅
            search: _search,
            statusFilter: null,
            onSearchChanged: (v) => setState(() => _search = v),
            onStatusFilterChanged: (_) {},
            actionsBuilder: (_, __) => const [
              PopupMenuItem(value: _RowAction.restore, child: Text('Restore')),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _RowAction.deleteForever,
                child: Text('Delete permanently'),
              ),
            ],
            onAction: (uid, learner, action) async {
              switch (action) {
                case _RowAction.restore:
                  await _restoreFromDeleted(uid, learner);
                  break;
                case _RowAction.deleteForever:
                  await _deletePermanently(uid, _deletedRef);
                  break;
                default:
                  break;
              }
            },
          ),

          _LearnersList(
            titleHint: 'Search blocked…',
            stream: _blockedStream, // ✅
            search: _search,
            statusFilter: null,
            onSearchChanged: (v) => setState(() => _search = v),
            onStatusFilterChanged: (_) {},
            actionsBuilder: (_, __) => const [
              PopupMenuItem(value: _RowAction.restore, child: Text('Unblock')),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _RowAction.deleteForever,
                child: Text('Delete permanently'),
              ),
            ],
            onAction: (uid, learner, action) async {
              switch (action) {
                case _RowAction.restore:
                  await _restoreFromBlocked(uid, learner);
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

    );
  }
}

enum _RowAction { edit, pause, delete, block, restore, deleteForever }

class _LearnersList extends StatefulWidget {
  const _LearnersList({
    required this.titleHint,
    required this.stream,
    required this.search,
    required this.statusFilter,
    required this.onSearchChanged,
    required this.onStatusFilterChanged,
    required this.actionsBuilder,
    required this.onAction,
    this.onEdit,
  });

  final String titleHint;
  final Stream<DatabaseEvent> stream;

  final String search;
  final LearnerStatus? statusFilter;

  final ValueChanged<String> onSearchChanged;
  final ValueChanged<LearnerStatus?> onStatusFilterChanged;

  final List<PopupMenuEntry<_RowAction>> Function(String uid, Learner learner)
  actionsBuilder;

  final Future<void> Function(String uid, Learner learner, _RowAction action)
  onAction;

  final Future<void> Function(String uid, Learner learner)? onEdit;

  @override
  State<_LearnersList> createState() => _LearnersListState();
}

class _LearnersListState extends State<_LearnersList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // IMPORTANT for keep-alive

    return Column(
      children: [
        _TopBar(
          hint: widget.titleHint,
          value: widget.search,
          onChanged: widget.onSearchChanged,
          filters: widget.statusFilter == null
              ? const []
              : [
            _FilterChipItem(
              label: 'All',
              selected: widget.statusFilter == null,
              onTap: () => widget.onStatusFilterChanged(null),
            ),
          ],
        ),
        if (widget.statusFilter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 1 + LearnerStatus.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return ChoiceChip(
                      label: const Text('All'),
                      selected: widget.statusFilter == null,
                      onSelected: (_) => widget.onStatusFilterChanged(null),
                    );
                  }
                  final s = LearnerStatus.values[i - 1];
                  return ChoiceChip(
                    label: Text(s.label),
                    selected: widget.statusFilter == s,
                    onSelected: (_) => widget.onStatusFilterChanged(s),
                  );
                },
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
                  message: 'Could not load learners.',
                  icon: Icons.error_outline,
                );
              }

              // ✅ Important: only show loading the very first time
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _LoadingList();
              }

              final data = snapshot.data?.snapshot.value;
              final rows = _parseLearnersMap(data);

              rows.sort((a, b) {
                final aT = a.learner.updatedAtMs ?? 0;
                final bT = b.learner.updatedAtMs ?? 0;
                return bT.compareTo(aT);
              });

              final s = widget.search.trim().toLowerCase();
              final filtered = rows.where((r) {
                final l = r.learner;

                final matchesSearch = s.isEmpty
                    ? true
                    : l.fullName.toLowerCase().contains(s) ||
                    l.email.toLowerCase().contains(s) ||
                    l.serial.toLowerCase().contains(s) ||
                    l.phone1.toLowerCase().contains(s) ||
                    l.phone2.toLowerCase().contains(s);

                final matchesStatus = widget.statusFilter == null
                    ? true
                    : (l.status == widget.statusFilter);

                return matchesSearch && matchesStatus;
              }).toList();

              if (filtered.isEmpty) {
                return const _StateCard(
                  title: 'No learners',
                  message: 'No results match your filters.',
                  icon: Icons.people_outline,
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final row = filtered[i];
                  final l = row.learner;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    elevation: 0,
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor:
                            AdminLearnersScreen.appBg.withOpacity(1),
                            child: Text(
                              l.firstName.isNotEmpty
                                  ? l.firstName[0].toUpperCase()
                                  : 'L',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: AdminLearnersScreen.primaryBlue,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l.fullName.isEmpty ? '(No name)' : l.fullName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: AdminLearnersScreen.primaryBlue,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  l.email.isEmpty ? '(No email)' : l.email,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black.withOpacity(0.55),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _Pill(
                                      label: l.status.label,
                                      bg: _statusBg(l.status),
                                      fg: _statusFg(l.status),
                                    ),
                                    if (l.serial.trim().isNotEmpty)
                                      _Pill(label: l.serial),
                                    if (l.phone1.trim().isNotEmpty)
                                      _Pill(label: '📞 ${l.phone1}'),
                                    if (l.dob.trim().isNotEmpty)
                                      _Pill(label: '🎂 ${l.dob}'),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          PopupMenuButton<_RowAction>(
                            tooltip: 'Actions',
                            onSelected: (a) async {
                              if (a == _RowAction.edit) {
                                if (widget.onEdit != null) {
                                  await widget.onEdit!(row.uid, l);
                                }
                                return;
                              }
                              await widget.onAction(row.uid, l, a);
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
                              items.addAll(widget.actionsBuilder(row.uid, l));
                              return items;
                            },
                          ),
                        ],
                      ),
                    ),
                  );
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
    required this.filters,
  });

  final String hint;
  final String value;
  final ValueChanged<String> onChanged;
  final List<_FilterChipItem> filters;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          TextField(
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: AdminLearnersScreen.appBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          if (filters.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: filters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final f = filters[i];
                  return ChoiceChip(
                    label: Text(f.label),
                    selected: f.selected,
                    onSelected: (_) => f.onTap(),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChipItem {
  const _FilterChipItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    this.bg,
    this.fg,
  });

  final String label;
  final Color? bg;
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    final background = bg ?? AdminLearnersScreen.appBg;
    final foreground = fg ?? AdminLearnersScreen.primaryBlue;

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
              SizedBox(
                  width: 44,
                  height: 44,
                  child: ColoredBox(color: AdminLearnersScreen.appBg)),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                        height: 14,
                        width: 160,
                        child: ColoredBox(color: AdminLearnersScreen.appBg)),
                    SizedBox(height: 10),
                    SizedBox(
                        height: 12,
                        width: 260,
                        child: ColoredBox(color: AdminLearnersScreen.appBg)),
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

class LearnerEditorScreen extends StatefulWidget {
  const LearnerEditorScreen({
    super.key,
    required this.mode,
    this.uid,
    this.initial,
  });

  final EditorMode mode;
  final String? uid;
  final Learner? initial;

  @override
  State<LearnerEditorScreen> createState() => _LearnerEditorScreenState();
}

class _LearnerEditorScreenState extends State<LearnerEditorScreen> {
  final _formKey = GlobalKey<FormState>();

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
  late final TextEditingController serialC;


  DateTime? _dob;

  LearnerStatus _status = LearnerStatus.active;

  bool _saving = false;
  Map<String, Map<String, dynamic>> _allCourses = {}; // all courses from DB
  final Set<String> _selectedCourseIds = {}; // selected course IDs
  bool _loadingCourses = true; // loading indicator


  @override
  void initState() {
    super.initState();

    final initial = widget.initial;

    firstNameC = TextEditingController(text: initial?.firstName ?? '');
    lastNameC = TextEditingController(text: initial?.lastName ?? '');
    dobC = TextEditingController(text: initial?.dob ?? '');
    phone1C = TextEditingController(text: initial?.phone1 ?? '');
    phone2C = TextEditingController(text: initial?.phone2 ?? '');
    emailC = TextEditingController(text: initial?.email ?? '');
    passwordC = TextEditingController(); // only used on create
    serialC = TextEditingController(text: initial?.serial ?? '');

    _status = initial?.status ?? LearnerStatus.active;

    // Parse DOB if present (yyyy-mm-dd)
    if (dobC.text.trim().isNotEmpty) {
      final parts = dobC.text.trim().split('-');
      if (parts.length == 3) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        final d = int.tryParse(parts[2]);
        if (y != null && m != null && d != null) {
          _dob = DateTime(y, m, d);
        }
      }
    }

    // Auto serial for create
    if (widget.mode == EditorMode.create) {
      _nextSerial().then((s) {
        if (!mounted) return;
        if (serialC.text.trim().isEmpty) serialC.text = s;
      });
    }
    _loadCoursesAndSelection();

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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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
            coursesOut[key.toString()] =
                value.map((k, v) => MapEntry(k.toString(), v));
          }
        });
      }

      // If editing, load learner's existing courses from /users/{uid}/courses
      if (widget.mode == EditorMode.edit && widget.uid != null) {
        final userCoursesSnap =
        await _usersRef.child(widget.uid!).child('courses').get();
        final userCoursesVal = userCoursesSnap.value;

        _selectedCourseIds.clear();

        if (userCoursesVal is Map) {
          userCoursesVal.forEach((k, v) {
            if (k == null) return;
            _selectedCourseIds.add(k.toString());
          });
        }
      }

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


  Future<void> _pickDob() async {
    FocusScope.of(context).unfocus();

    final now = DateTime.now();
    final initial = _dob ?? DateTime(now.year - 12, now.month, now.day);

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

  Future<String> _nextSerial() async {
    final snap = await FirebaseDatabase.instance.ref('users').get();
    int maxNum = 0;

    final v = snap.value;
    if (v is Map) {
      for (final entry in v.entries) {
        final user = entry.value;
        if (user is Map) {
          final raw = user['serial']?.toString().trim() ?? '';
          final digits = RegExp(r'(\d+)').firstMatch(raw)?.group(1);
          final n = int.tryParse(digits ?? '');
          if (n != null && n > maxNum) maxNum = n;
        }
      }
    }

    final next = maxNum + 1;
    final padded = next.toString().padLeft(6, '0');
    return '🎓-$padded';
  }

  // Create auth user WITHOUT cloud functions by using a SECONDARY Firebase app
  Future<String> _createAuthUserAndGetUid({
    required String email,
    required String password,
  }) async {
    final options = Firebase.app().options;

    // Unique name every time (safe)
    final name = 'secondary_${DateTime.now().microsecondsSinceEpoch}';
    final secondary = await Firebase.initializeApp(name: name, options: options);

    try {
      final secondaryAuth = FirebaseAuth.instanceFor(app: secondary);
      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final uid = cred.user?.uid;
      if (uid == null) {
        throw Exception('User created but UID is null.');
      }
      await secondaryAuth.signOut();
      return uid;
    } finally {
      await secondary.delete();
    }
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
                final data = e.value;

                final code = (data['course_code'] ?? '').toString().trim();
                final titleText = (data['title'] ?? data['name'] ?? '').toString().trim();
                final category = (data['category'] ?? '').toString().trim();

// What we show to admin:
                final display = [
                  if (code.isNotEmpty) code,
                  if (titleText.isNotEmpty) titleText,
                ].join(' — ');

// Fallback if DB doesn't have title/name:
                final finalTitle = display.isNotEmpty
                    ? display
                    : (category.isNotEmpty ? category : id);


                return CheckboxListTile(
                  value: tempSelected.contains(id),
                  title: Text(finalTitle),
                  subtitle: Text(
                    id,
                    style: TextStyle(
                      color: Colors.black.withOpacity(0.5),
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

  String _courseLabelFor(String courseId) {
    final c = _allCourses[courseId];
    final code = (c?['course_code'] ?? '').toString().trim();
    final title = (c?['title'] ?? c?['name'] ?? '').toString().trim();
    final category = (c?['category'] ?? '').toString().trim();

    final label = [
      if (code.isNotEmpty) code,
      if (title.isNotEmpty) title,
    ].join(' — ');

    return label.isNotEmpty ? label : (category.isNotEmpty ? category : courseId);
  }

  /// Reads existing /users/{uid}/courses and returns the largest N in course_N keys
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


  Future<void> _saveUserCourses(String uid) async {
    final coursesRef = _usersRef.child(uid).child('courses');

    // If nothing selected => remove node
    if (_selectedCourseIds.isEmpty) {
      await coursesRef.remove();
      return;
    }

    // Read current courses to avoid losing progress later
    final existingSnap = await coursesRef.get();
    final existingVal = existingSnap.value;

    // Build a map: courseId -> courseNodeKey (course_1, course_2, ...)
    final Map<String, String> idToKey = {};

    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null || v == null) return;
        if (v is Map) {
          final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          final existingId = (mm['id'] ?? '').toString();
          if (existingId.isNotEmpty) {
            idToKey[existingId] = k.toString();
          }
        }
      });
    }

    int nextIndex = _maxCourseIndexFromExisting(existingVal) + 1;

    // We will update existing + add new, and delete removed
    final Map<String, dynamic> updates = {};

    // 1) Remove courses that are no longer selected (delete whole node)
    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null) return;
        if (k.toString().startsWith('course_')) {
          // check if its id is still selected
          String existingId = '';
          if (v is Map) {
            final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
            existingId = (mm['id'] ?? '').toString();
          }
          if (existingId.isNotEmpty && !_selectedCourseIds.contains(existingId)) {
            updates[k.toString()] = null; // delete
          }
        }
      });
    }

    // 2) Upsert selected courses (keep existing course_N keys if already there)
    for (final courseId in _selectedCourseIds) {
      final key = idToKey[courseId] ?? 'course_${nextIndex++}';

      final c = _allCourses[courseId];
      final code = (c?['course_code'] ?? '').toString().trim();
      final title = (c?['title'] ?? c?['name'] ?? '').toString().trim();
      final category = (c?['category'] ?? '').toString().trim();

      // IMPORTANT: we set basic info, but DO NOT overwrite future progress/attendance nodes
      // We update only these fields.
      updates['$key/id'] = courseId;
      updates['$key/course_code'] = code;
      updates['$key/title'] = title;
      updates['$key/category'] = category;
      updates['$key/assignedAt'] = ServerValue.timestamp;
    }

    await coursesRef.update(updates);
  }


  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      final isCreate = widget.mode == EditorMode.create;

      final first = firstNameC.text.trim();
      final last = lastNameC.text.trim();
      final email = emailC.text.trim();
      final pass = passwordC.text.trim();

      final serial = serialC.text.trim();
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

      final learner = Learner(
        uid: uid,
        firstName: first,
        lastName: last,
        dob: dob,
        phone1: phone1,
        phone2: phone2,
        email: email,
        serial: serial,
        role: 'learner',
        status: _status,
        updatedAtMs: null,
      );

      if (isCreate) {
        await _usersRef.child(uid).set({
          ...learner.toMap(),
          'createdAt': nowTs,
          'updatedAt': nowTs,
        });
      } else {
        // For edit: do not touch password / auth
        await _usersRef.child(uid).update({
          ...learner.toMap(),
          'updatedAt': nowTs,
        });
      }
      await _saveUserCourses(uid);


      if (!mounted) return;
      Navigator.of(context).pop(learner);
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

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.mode == EditorMode.edit;

    return Scaffold(
      backgroundColor: AdminLearnersScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminLearnersScreen.primaryBlue),
        title: Text(
          isEdit ? 'Edit Learner' : 'Add Learner',
          style: const TextStyle(
            color: AdminLearnersScreen.primaryBlue,
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
              child: Text(_saving
                  ? 'Saving…'
                  : (isEdit ? 'Save Changes' : 'Create Learner')),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
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

                    // DOB: calendar picker
                    TextFormField(
                      controller: dobC,
                      readOnly: true,
                      onTap: _pickDob,
                      decoration: InputDecoration(
                        labelText: 'Date of birth',
                        hintText: 'Tap to pick a date',
                        filled: true,
                        fillColor: AdminLearnersScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon:
                        const Icon(Icons.calendar_month_rounded),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Serial
                    _TextField(
                      controller: serialC,
                      label: 'Serial number',
                      hint: '🎓-000001',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Contact',
                child: Column(
                  children: [
                    TextFormField(
                      controller: phone1C,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[\d+\s-]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Phone 1',
                        hintText: 'Example: 0550 00 00 00',
                        filled: true,
                        fillColor: AdminLearnersScreen.appBg,
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
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[\d+\s-]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Phone 2',
                        hintText: 'Optional',
                        filled: true,
                        fillColor: AdminLearnersScreen.appBg,
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
                      hint: 'learner@email.com',
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Required';
                        if (!t.contains('@')) return 'Invalid email';
                        return null;
                      },
                      enabled: !isEdit, // don't allow changing email in edit
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
              const SizedBox(height: 12),

              _SectionCard(
                title: 'Status',
                child: DropdownButtonFormField<LearnerStatus>(
                  value: _status,
                  decoration: InputDecoration(
                    labelText: 'Status',
                    filled: true,
                    fillColor: AdminLearnersScreen.appBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: LearnerStatus.values
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
              ),

              const SizedBox(height: 12),

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
                      onPressed: _allCourses.isEmpty ? null : _openCoursesPicker,
                      icon: const Icon(Icons.school_rounded),
                      label: Text(
                        _selectedCourseIds.isEmpty
                            ? 'Select courses'
                            : 'Selected: ${_selectedCourseIds.length}',
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_selectedCourseIds.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _selectedCourseIds.map((id) {
                          final c = _allCourses[id];
                          final code = (c?['course_code'] ?? '').toString().trim();
                          final titleText = (c?['title'] ?? c?['name'] ?? '').toString().trim();
                          final category = (c?['category'] ?? '').toString().trim();

                          final label = [
                            if (code.isNotEmpty) code,
                            if (titleText.isNotEmpty) titleText,
                          ].join(' — ');

                          return _Pill(
                            label: label.isNotEmpty ? label : (category.isNotEmpty ? category : id),
                          );

                        }).toList(),
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



class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
  });

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
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.validator,
    this.enabled = true,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final bool enabled;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      validator: validator,
      enabled: enabled,
      obscureText: obscureText,
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
}

// ----------------------------
// Model + Parsing
// ----------------------------

enum LearnerStatus {
  active,
  paused;

  String get value {
    switch (this) {
      case LearnerStatus.active:
        return 'active';
      case LearnerStatus.paused:
        return 'paused';
    }
  }

  String get label {
    switch (this) {
      case LearnerStatus.active:
        return 'Active';
      case LearnerStatus.paused:
        return 'Paused';
    }
  }

  static LearnerStatus fromValue(String? v) {
    switch ((v ?? '').toLowerCase().trim()) {
      case 'paused':
        return LearnerStatus.paused;
      case 'active':
      default:
        return LearnerStatus.active;
    }
  }
}

Color _statusBg(LearnerStatus s) {
  switch (s) {
    case LearnerStatus.paused:
      return const Color(0xFFFFF3D6);
    case LearnerStatus.active:
    default:
      return const Color(0xFFDFF7E8);
  }
}

Color _statusFg(LearnerStatus s) {
  switch (s) {
    case LearnerStatus.paused:
      return const Color(0xFF9A6B00);
    case LearnerStatus.active:
    default:
      return const Color(0xFF157A3D);
  }
}

class Learner {
  Learner({
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
  });

  final String uid;
  final String firstName;
  final String lastName;
  final String dob;
  final String phone1;
  final String phone2;
  final String email;
  final String serial;
  final String role; // 'learner'
  final LearnerStatus status;
  final int? updatedAtMs;

  String get fullName => '${firstName.trim()} ${lastName.trim()}'.trim();

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'first_name': firstName,
      'last_name': lastName,
      'dob': dob,
      'phone1': phone1,
      'phone2': phone2,
      'email': email,
      'serial': serial,
      'status': status.value,
      'updatedAt': updatedAtMs,
    };
  }

  factory Learner.fromMap(String uid, Map<dynamic, dynamic> raw) {
    final m = raw.map((k, v) => MapEntry(k.toString(), v));

    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return Learner(
      uid: uid,
      role: (m['role'] ?? 'learner').toString(),
      firstName: (m['first_name'] ?? m['firstName'] ?? '').toString(),
      lastName: (m['last_name'] ?? m['lastName'] ?? '').toString(),
      dob: (m['dob'] ?? '').toString(),
      phone1: (m['phone1'] ?? '').toString(),
      phone2: (m['phone2'] ?? '').toString(),
      email: (m['email'] ?? '').toString(),
      serial: (m['serial'] ?? '').toString(),
      status: LearnerStatus.fromValue(m['status']?.toString()),
      updatedAtMs: parseInt(m['updatedAt']),
    );
  }
}

class _LearnerRow {
  _LearnerRow({required this.uid, required this.learner});
  final String uid;
  final Learner learner;
}

List<_LearnerRow> _parseLearnersMap(dynamic data) {
  if (data == null) return [];

  if (data is Map) {
    final out = <_LearnerRow>[];
    data.forEach((key, value) {
      if (key == null || value == null) return;
      if (value is Map) {
        final uid = key.toString();
        final learner = Learner.fromMap(uid, value);
        // Only show learners (role == learner) to avoid admins in list
        final role = learner.role.toLowerCase().trim();
        if (role == 'learner') {
          out.add(_LearnerRow(uid: uid, learner: learner));
        }
      }
    });
    return out;
  }

  return [];
}
