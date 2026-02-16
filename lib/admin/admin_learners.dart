import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fluttertoast/fluttertoast.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'payment_dialog_shared.dart';
import 'admin_payments.dart';
import '../services/push_client.dart';
import 'admin_learner_mail_topics_screen.dart';
import '../calls/audio_call_screen.dart';

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

class _AdminLearnersScreenState extends State<AdminLearnersScreen> with SingleTickerProviderStateMixin {
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
  LearnerStatus? _statusFilter; // only used on Users tab

  DatabaseReference get _usersRef => _db.ref(_usersPath);
  DatabaseReference get _deletedRef => _db.ref(_deletedPath);
  DatabaseReference get _blockedRef => _db.ref(_blockedPath);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);

    // broadcast streams once
    _usersStream = _usersRef.onValue.asBroadcastStream();
    _deletedStream = _deletedRef.onValue.asBroadcastStream();
    _blockedStream = _blockedRef.onValue.asBroadcastStream();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;

    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
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
    _toast('Learner paused ✅');
  }

  Future<void> _activateLearner(String uid) async {
    await _usersRef.child(uid).update({
      'status': LearnerStatus.active.value,
      'updatedAt': ServerValue.timestamp,
    });
    _toast('Learner activated ✅');
  }

  Future<void> _moveToDeleted(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Delete learner?',
      message: 'This will move the learner to "deleted".\n\nYou can restore later.',
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

    _toast('Moved to deleted 🗑️');
  }

  Future<void> _moveToBlocked(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Block learner?',
      message: 'This will move the learner to "blocked".\n\nYou can restore later.',
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

    _toast('Moved to blocked ⛔');
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

    _toast('Restored ✅');
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

    _toast('Unblocked ✅');
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
    _toast('Deleted permanently ✅');
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
          unselectedLabelColor: AdminLearnersScreen.primaryBlue.withOpacity(0.55),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Users'),
            Tab(text: 'Deleted'),
            Tab(text: 'Blocked'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Payments',
            icon: const Icon(Icons.payments_rounded, color: AdminLearnersScreen.primaryBlue),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => AdminPaymentsScreen()),
              );
            },
          ),
          AnimatedBuilder(
            animation: _tab,
            builder: (_, __) {
              final isUsersTab = _tab.index == 0;
              if (!isUsersTab) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Add learner',
                icon: const Icon(Icons.person_add_alt_1_rounded, color: AdminLearnersScreen.actionOrange),
                onPressed: () async {
                  final created = await Navigator.of(context).push<Learner?>(
                    MaterialPageRoute(
                      builder: (_) => const LearnerEditorScreen(
                        mode: EditorMode.create,
                      ),
                    ),
                  );
                  if (created != null) _toast('Learner created ✅');
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
            stream: _usersStream,
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
              if (updated != null) _toast('Learner updated ✅');
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
            stream: _deletedStream,
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
            stream: _blockedStream,
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
enum _QuickLearnerReminder { payment, absence, empty }

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

  final List<PopupMenuEntry<_RowAction>> Function(String uid, Learner learner) actionsBuilder;
  final Future<void> Function(String uid, Learner learner, _RowAction action) onAction;
  final Future<void> Function(String uid, Learner learner)? onEdit;

  @override
  State<_LearnersList> createState() => _LearnersListState();
}

class _LearnersListState extends State<_LearnersList> with AutomaticKeepAliveClientMixin {
  void _toast(String msg) {
    if (!mounted) return;

    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
  }

  String? _expandedUid;

  Future<String?> _getLearnerFcmToken(String learnerUid) async {
    final snap = await FirebaseDatabase.instance.ref('fcm_tokens/$learnerUid/token').get();
    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  String get _adminUid => FirebaseAuth.instance.currentUser!.uid;

  /// Sum unread mail (for THIS admin) coming from a specific learner (peerUid).
  /// Reads mail_index/{adminUid} threads where peerUid == learnerUid and sums unreadCount.
  Stream<int> _unreadForLearnerStream(String learnerUid) {
    final q = FirebaseDatabase.instance.ref('mail_index/$_adminUid').orderByChild('peerUid').equalTo(learnerUid);

    return q.onValue.map((event) {
      final v = event.snapshot.value;
      if (v is! Map) return 0;

      int sum = 0;
      v.forEach((_, raw) {
        if (raw is! Map) return;
        final m = raw.map((k, vv) => MapEntry(k.toString(), vv));

        // ignore deleted threads (deleted for admin)
        if (m['deletedAt'] != null) return;

        final uc = m['unreadCount'];
        int toInt(dynamic x) {
          if (x is int) return x;
          if (x is num) return x.toInt();
          return int.tryParse(x?.toString() ?? '') ?? 0;
        }

        sum += toInt(uc);
      });

      return sum;
    });
  }

  Widget _badge(int count) {
    if (count <= 0) return const SizedBox.shrink();
    final label = count > 99 ? '99+' : '$count';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }

  Future<void> _sendLearnerQuickReminder({
    required String uid,
    required Learner learner,
    required _QuickLearnerReminder type,
  }) async {
    final token = await _getLearnerFcmToken(uid);
    if (token == null) {
      if (!mounted) return;
      _toast('Cannot send reminder: learner is not connected (no notification token).');

      return;
    }

    String title;
    String message;

    switch (type) {
      case _QuickLearnerReminder.payment:
        title = 'Payment Reminder';
        message = 'Your payment is due. Please contact the academy.';
        break;
      case _QuickLearnerReminder.absence:
        title = 'Absence Reminder';
        message = 'We noticed an absence. Please confirm with the academy.';
        break;
      case _QuickLearnerReminder.empty:
        return; // mail is opened from the sheet
    }

    await PushClient.sendToToken(
      token: token,
      title: title,
      message: message,
      data: {
        'type': 'reminder',
        'route': 'learner',
        'learnerUid': uid,
        'kind': type.name,
      },
    );

    if (!mounted) return;
    _toast('Reminder sent to ${learner.fullName.isEmpty ? 'learner' : learner.fullName} ✅');

  }

  Future<void> _showQuickReminderSheet({
    required String uid,
    required Learner learner,
  }) async {
    if (!mounted) return;

    final picked = await showModalBottomSheet<_QuickLearnerReminder>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            ListTile(
              leading: const Icon(Icons.payments_rounded),
              title: const Text('Payment'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.payment),
            ),
            ListTile(
              leading: const Icon(Icons.event_busy_rounded),
              title: const Text('Absence'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.absence),
            ),
            ListTile(
              leading: const Icon(Icons.mail_rounded),
              title: const Text('Mail'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.empty),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (picked == null) return;

    try {
      if (picked == _QuickLearnerReminder.empty) {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AdminLearnerMailTopicsScreen(
              learnerUid: uid,
              learnerName: learner.fullName.isEmpty ? 'Learner' : learner.fullName,
            ),
          ),
        );
      } else {
        await _sendLearnerQuickReminder(uid: uid, learner: learner, type: picked);
      }
    } catch (e) {
      if (!mounted) return;
      _toast('Could not send reminder. Please try again.');

    }
  }

  final _db = FirebaseDatabase.instance;
  static const List<String> _methods = ['Cash', 'Card', 'Transfer', 'Other'];

  // --- Due helpers (UI only) ---
  bool _isDue({
    required int sessionsPaidTotal,
    required int sessionsDone,
  }) {
    return sessionsPaidTotal > 0 && sessionsDone >= (sessionsPaidTotal - 1);
  }

  // compute due and pass to builder (avatar red)
  Widget _withLearnerDueFlag({
    required String uid,
    required Widget Function(bool due) builder,
  }) {
    final coursesRef = _db.ref('users/$uid/courses');

    return StreamBuilder<DatabaseEvent>(
      stream: coursesRef.onValue,
      builder: (context, snap) {
        bool due = false;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          v.forEach((courseKey, courseVal) {
            if (courseKey == null || courseVal == null) return;
            if (courseVal is! Map) return;

            final courseMap = courseVal.map((k, vv) => MapEntry(k.toString(), vv));

            final attendance = courseMap['attendance'];
            final sessionsDone = attendance is Map ? attendance.length : 0;

            final sum = courseMap['payment_summary'];
            final sumMap = sum is Map ? sum.map((k, vv) => MapEntry(k.toString(), vv)) : <String, dynamic>{};
            final sp = _LearnerExpandedTabsState._asInt(sumMap['sessionsPaidTotal']);

            if (_isDue(sessionsPaidTotal: sp, sessionsDone: sessionsDone)) due = true;
          });
        }

        return builder(due);
      },
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        _TopBar(
          hint: widget.titleHint,
          value: widget.search,
          onChanged: widget.onSearchChanged,
          filters: const <_FilterChipItem>[],
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

              if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
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

                final matchesStatus = widget.statusFilter == null ? true : (l.status == widget.statusFilter);

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
                  final isExpanded = _expandedUid == row.uid;

                  return _withLearnerDueFlag(
                    uid: row.uid,
                    builder: (due) {
                      final avatarBg = due ? Colors.red : AdminLearnersScreen.appBg;
                      final avatarFg = due ? Colors.white : AdminLearnersScreen.primaryBlue;

                      String compactLine2() {
                        final parts = <String>[];
                        if (l.dob.trim().isNotEmpty) parts.add('🎂 ${l.dob}');
                     //   if (l.serial.trim().isNotEmpty) parts.add(l.serial);
                        if (l.phone2.trim().isNotEmpty) parts.add('📞2 ${l.phone2}');
                        return parts.join('  •  ');
                      }


                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AdminLearnersScreen.uiBorders),
                        ),
                        child: Column(
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                setState(() {
                                  _expandedUid = isExpanded ? null : row.uid;
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    GestureDetector(
                                    onTap: () async {
                              final ok = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                              title: const Text('Call learner?'),
                              content: Text('Call ${l.fullName.isEmpty ? 'this learner' : l.fullName}?'),
                              actions: [
                              TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                              ),
                              FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Call'),
                              ),
                              ],
                              ),
                              ) ?? false;

                              if (!ok) return;

                              await Navigator.of(context).push(
                              MaterialPageRoute(
                              builder: (_) => AudioCallScreen(
                              peerUid: row.uid,
                              peerName: l.fullName.isEmpty ? 'Learner' : l.fullName,
                              isCaller: true,
                              callerName: 'Admin', // you can improve later like staff version
                              startWithVideo: true,
                              ),
                              ),
                              );
                              },
                                onLongPress: () => _showQuickReminderSheet(uid: row.uid, learner: l),
                                      child: StreamBuilder<int>(
                                        stream: _unreadForLearnerStream(row.uid),
                                        builder: (context, snapUnread) {
                                          final unread = snapUnread.data ?? 0;

                                          return Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              CircleAvatar(
                                                backgroundColor: avatarBg,
                                                child: Text(
                                                  l.firstName.isNotEmpty ? l.firstName[0].toUpperCase() : 'L',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    color: avatarFg,
                                                  ),
                                                ),
                                              ),
                                              if (unread > 0)
                                                Positioned(
                                                  right: -6,
                                                  top: -6,
                                                  child: _badge(unread),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
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
                                                  l.fullName.isEmpty ? '(No name)' : l.fullName,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    color: AdminLearnersScreen.primaryBlue,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              if (l.email.trim().isNotEmpty)
                                                Expanded(
                                                  child: Text(
                                                    l.email,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w700,
                                                      color: Colors.black.withOpacity(0.6),
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    textAlign: TextAlign.right,
                                                  ),
                                                ),
                                              const SizedBox(width: 10),

                                              // ✅ show ONLY Inactive, hide Active
                                              if (l.status == LearnerStatus.paused)
                                                const _Pill(
                                                  label: 'Inactive',
                                                  bg: Color(0xFFFFF3D6),
                                                  fg: Color(0xFF9A6B00),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),

// ✅ Phone (clickable)
                                          if (l.phone1.trim().isNotEmpty)
                                            InkWell(
                                              onTap: () async {
                                                final phone = l.phone1.trim();
                                                final uri = Uri(scheme: 'tel', path: phone);
                                                if (await canLaunchUrl(uri)) {
                                                  await launchUrl(uri);
                                                } else {
                                                  _toast('Cannot open phone dialer on this device.');
                                                }
                                              },
                                              child: Text(
                                                '📞 ${l.phone1}',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w800,
                                                  color: AdminLearnersScreen.primaryBlue.withOpacity(0.9),
                                                  decoration: TextDecoration.underline,
                                                ),
                                              ),
                                            )
                                          else
                                            Text(
                                              '📞 (No phone)',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black.withOpacity(0.5),
                                              ),
                                            ),

// ✅ extra info line (dob + serial + phone2)
                                          const SizedBox(height: 4),
                                          if (compactLine2().isNotEmpty)
                                            Text(
                                              compactLine2(),
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black.withOpacity(0.65),
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),

                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                      color: AdminLearnersScreen.primaryBlue.withOpacity(0.7),
                                    ),
                                    const SizedBox(width: 4),
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
                            ),
                            AnimatedCrossFade(
                              firstChild: const SizedBox.shrink(),
                              secondChild: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                child: _LearnerExpandedTabs(
                                  uid: row.uid,
                                  db: _db,
                                  methods: _methods,
                                ),
                              ),
                              crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                              duration: const Duration(milliseconds: 200),
                            ),
                          ],
                        ),
                      );
                    },
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
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
              SizedBox(width: 44, height: 44, child: ColoredBox(color: AdminLearnersScreen.appBg)),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 14, width: 160, child: ColoredBox(color: AdminLearnersScreen.appBg)),
                    SizedBox(height: 10),
                    SizedBox(height: 12, width: 260, child: ColoredBox(color: AdminLearnersScreen.appBg)),
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
// Editor (NO course assignment here)
// ----------------------------

enum EditorMode { create, edit }

class LearnerPrefill {
  LearnerPrefill({
    this.firstName = '',
    this.lastName = '',
    this.phone1 = '',
    this.selectedCourseIds = const <String>{},
  });

  final String firstName;
  final String lastName;
  final String phone1;
  final Set<String> selectedCourseIds;
}

class LearnerEditorScreen extends StatefulWidget {
  const LearnerEditorScreen({
    super.key,
    required this.mode,
    this.uid,
    this.initial,
    this.prefill,
  });

  final EditorMode mode;
  final String? uid;
  final Learner? initial;
  final LearnerPrefill? prefill;

  @override
  State<LearnerEditorScreen> createState() => _LearnerEditorScreenState();
}

class _LearnerEditorScreenState extends State<LearnerEditorScreen> {
  final _formKey = GlobalKey<FormState>();

  final _db = FirebaseDatabase.instance;
  DatabaseReference get _usersRef => _db.ref('users');

  late final TextEditingController firstNameC;
  late final TextEditingController lastNameC;
  late final TextEditingController dobC;
  late final TextEditingController phone1C;
  late final TextEditingController phone2C;
  late final TextEditingController emailC;
  late final TextEditingController passwordC;
  late final TextEditingController serialC;
  bool _serialUnlocked = false;

  DateTime? _dob;
  LearnerStatus _status = LearnerStatus.active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();

    final initial = widget.initial;

    firstNameC = TextEditingController(text: initial?.firstName ?? '');
    lastNameC = TextEditingController(text: initial?.lastName ?? '');
    dobC = TextEditingController(text: initial?.dob ?? '');
    phone1C = TextEditingController(text: initial?.phone1 ?? '');

    // Optional prefill (create only) - stays as before
    if (widget.mode == EditorMode.create && widget.prefill != null) {
      final p = widget.prefill!;
      if (p.firstName.trim().isNotEmpty) firstNameC.text = p.firstName.trim();
      if (p.lastName.trim().isNotEmpty) lastNameC.text = p.lastName.trim();
      if (p.phone1.trim().isNotEmpty) phone1C.text = p.phone1.trim();
    }

    phone2C = TextEditingController(text: initial?.phone2 ?? '');
    emailC = TextEditingController(text: initial?.email ?? '');
    passwordC = TextEditingController(text: widget.mode == EditorMode.create ? '12345678' : '');
    serialC = TextEditingController(text: initial?.serial ?? '');

    _status = initial?.status ?? LearnerStatus.active;

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

    if (widget.mode == EditorMode.create) {
      _nextSerial().then((s) {
        if (!mounted) return;
        if (serialC.text.trim().isEmpty) serialC.text = s;
      });
    }
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

  void _toast(String msg) {
    if (!mounted) return;

    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
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
      helpText: 'Date of birth',
      initialEntryMode: DatePickerEntryMode.input,
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

  Future<String> _createAuthUserAndGetUid({
    required String email,
    required String password,
  }) async {
    final options = Firebase.app().options;

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
        await _usersRef.child(uid).update({
          ...learner.toMap(),
          'updatedAt': nowTs,
        });
      }

      if (!mounted) return;
      Navigator.of(context).pop(learner);
    } on FirebaseAuthException catch (e) {
      String msg = 'Auth error: ${e.code}';
      if (e.code == 'email-already-in-use') msg = 'Email already exists.';
      if (e.code == 'invalid-email') msg = 'Invalid email.';
      if (e.code == 'weak-password') msg = 'Password is too weak.';
      _toast(msg);
    } catch (e) {
      _toast('Save failed: $e');
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
              child: Text(_saving ? 'Saving…' : (isEdit ? 'Save Changes' : 'Create Learner')),
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
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'First name is required';
                        if (t.length < 2) return 'First name is too short';
                        if (!RegExp(r"^[a-zA-ZÀ-ÿ\s'-]+$").hasMatch(t)) return 'First name has invalid characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: lastNameC,
                      label: 'Last name *',
                      hint: 'Last name',
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Last name is required';
                        if (t.length < 2) return 'Last name is too short';
                        if (!RegExp(r"^[a-zA-ZÀ-ÿ\s'-]+$").hasMatch(t)) return 'Last name has invalid characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: dobC,
                      readOnly: true,
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Date of birth is required';
                        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)) return 'Use format YYYY-MM-DD';
                        return null;
                      },

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
                        prefixIcon: const Icon(Icons.calendar_month_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onLongPress: () {
                        setState(() => _serialUnlocked = true);
                        _toast('Serial unlocked (you can edit it now).');
                      },
                      child: TextFormField(
                        controller: serialC,
                        readOnly: !_serialUnlocked,
                        decoration: InputDecoration(
                          labelText: 'Serial number',
                          hintText: '🎓-000001',
                          filled: true,
                          fillColor: AdminLearnersScreen.appBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(Icons.confirmation_number_rounded),
                          suffixIcon: _serialUnlocked
                              ? IconButton(
                            tooltip: 'Lock',
                            icon: const Icon(Icons.lock_open_rounded),
                            onPressed: () {
                              setState(() => _serialUnlocked = false);
                              _toast('Serial locked ✅');
                            },
                          )
                              : const Icon(Icons.lock_rounded),
                        ),
                      ),
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
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+\s-]'))],
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Phone number is required';
                        final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
                        if (digits.length < 9) return 'Phone number is too short';
                        return null;
                      },

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
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+\s-]'))],
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
                      enabled: !isEdit,
                    ),
                    const SizedBox(height: 12),
                    if (!isEdit)
                      _TextField(
                        controller: passwordC,
                        label: 'Password *',
                        hint: 'Default: 12345678 (you can change it)',
                        obscureText: false,
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (t.isEmpty) return 'Password is required';
                          if (t.length < 6) return 'Password must be at least 6 characters';
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
                      .map((s) => DropdownMenuItem(
                    value: s,
                    child: Text(s.label),
                  ))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _status = v);
                  },
                ),
              ),
              const SizedBox(height: 12),
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
  final String role;
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

// ----------------------------
// Expanded Tabs inside learner card
// ----------------------------

class _LearnerExpandedTabs extends StatefulWidget {
  const _LearnerExpandedTabs({
    required this.uid,
    required this.db,
    required this.methods,
  });

  final String uid;
  final FirebaseDatabase db;
  final List<String> methods;

  @override
  State<_LearnerExpandedTabs> createState() => _LearnerExpandedTabsState();
}

class _LearnerExpandedTabsState extends State<_LearnerExpandedTabs> with SingleTickerProviderStateMixin {
  late final TabController _tab;

  String? _selectedCourseKey; // like "course_1"
  Map<String, dynamic> _userCourses = {}; // courseKey -> node data

  // for Assign Courses dialog
  Map<String, Map<String, dynamic>> _allCourses = {};
  bool _loadingAllCourses = false;

  DatabaseReference get _userCoursesRef => widget.db.ref('users/${widget.uid}/courses');
  DatabaseReference get _coursesRef => widget.db.ref('courses');
  DatabaseReference get _paymentsRef => widget.db.ref('payments');

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
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

  Future<void> _ensureAllCoursesLoaded() async {
    if (_allCourses.isNotEmpty) return;

    setState(() => _loadingAllCourses = true);
    try {
      final snap = await _coursesRef.get();
      final v = snap.value;

      final out = <String, Map<String, dynamic>>{};
      if (v is Map) {
        v.forEach((k, val) {
          if (k == null || val == null) return;
          if (val is Map) {
            out[k.toString()] = val.map((kk, vv) => MapEntry(kk.toString(), vv));
          }
        });
      }

      if (!mounted) return;
      setState(() => _allCourses = out);
    } finally {
      if (mounted) setState(() => _loadingAllCourses = false);
    }
  }

  Set<String> _currentlyAssignedCourseIds() {
    final ids = <String>{};
    _userCourses.forEach((_, nodeRaw) {
      final node = nodeRaw is Map ? nodeRaw : <dynamic, dynamic>{};
      final id = (node['id'] ?? '').toString().trim();
      if (id.isNotEmpty) ids.add(id);
    });
    return ids;
  }

  Future<void> _saveAssignedCourses(Set<String> selectedIds) async {
    final coursesRef = _userCoursesRef;

    // Build mapping existingId -> existingCourseKey (course_1, course_2, ...)
    final existingSnap = await coursesRef.get();
    final existingVal = existingSnap.value;

    final Map<String, String> idToKey = {};
    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null || v == null) return;
        if (v is Map) {
          final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          final existingId = (mm['id'] ?? '').toString().trim();
          if (existingId.isNotEmpty) idToKey[existingId] = k.toString();
        }
      });
    }

    int nextIndex = _maxCourseIndexFromExisting(existingVal) + 1;
    final Map<String, dynamic> updates = {};

    // Remove courses that are no longer selected
    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null) return;
        final key = k.toString();
        if (!key.startsWith('course_')) return;

        String existingId = '';
        if (v is Map) {
          final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          existingId = (mm['id'] ?? '').toString().trim();
        }
        if (existingId.isNotEmpty && !selectedIds.contains(existingId)) {
          updates[key] = null;
        }
      });
    }

    // Add / keep selected
    for (final courseId in selectedIds) {
      final key = idToKey[courseId] ?? 'course_${nextIndex++}';

      final c = _allCourses[courseId];
      final code = (c?['course_code'] ?? '').toString().trim();
      final title = (c?['title'] ?? c?['name'] ?? '').toString().trim();
      final category = (c?['category'] ?? '').toString().trim();

      updates['$key/id'] = courseId;
      updates['$key/course_code'] = code;
      updates['$key/title'] = title;
      updates['$key/category'] = category;
      updates['$key/assignedAt'] = ServerValue.timestamp;
    }

    await coursesRef.update(updates);
  }

  Future<void> _openAssignCoursesDialog() async {
    await _ensureAllCoursesLoaded();

    // ✅ pre-tick already assigned (by id)
    final temp = Set<String>.from(_currentlyAssignedCourseIds());

    // compute duplicate titles across ALL courses (so show code only when needed)
    String titleOf(String id) {
      final c = _allCourses[id] ?? {};
      return (c['title'] ?? c['name'] ?? '').toString().trim();
    }

    final titleCount = <String, int>{};
    for (final id in _allCourses.keys) {
      final t = titleOf(id);
      if (t.isEmpty) continue;
      titleCount[t] = (titleCount[t] ?? 0) + 1;
    }

    String displayFor(String id) {
      final c = _allCourses[id] ?? {};
      final title = (c['title'] ?? c['name'] ?? '').toString().trim();
      final code = (c['course_code'] ?? '').toString().trim();

      if (title.isEmpty) return code.isNotEmpty ? code : id;

      final duplicate = (titleCount[title] ?? 0) > 1;
      if (duplicate && code.isNotEmpty) return '$title ($code)';
      return title;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Assign courses'),
          content: SizedBox(
            width: double.maxFinite,
            child: _loadingAllCourses
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : ListView(
              shrinkWrap: true,
              children: _allCourses.keys.map((id) {
                return CheckboxListTile(
                  value: temp.contains(id),
                  title: Text(displayFor(id)),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) {
                    setDialogState(() {
                      if (v == true) {
                        temp.add(id); // ✅ Set prevents duplicates
                      } else {
                        temp.remove(id);
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
              onPressed: () async {
                await _saveAssignedCourses(temp);
                if (mounted) setState(() {}); // refresh picker + panels
                if (mounted) Navigator.pop(dialogContext);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ✅ Assign courses button moved here (not in editor)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _openAssignCoursesDialog,
            icon: const Icon(Icons.school_rounded),
            label: const Text('Assign courses'),
          ),
        ),
        const SizedBox(height: 10),
        TabBar(
          controller: _tab,
          labelColor: AdminLearnersScreen.primaryBlue,
          unselectedLabelColor: AdminLearnersScreen.primaryBlue.withOpacity(0.55),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Payment'),
            Tab(text: 'Attendance'),
            Tab(text: 'Report'),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 320,
          child: StreamBuilder<DatabaseEvent>(
            stream: _userCoursesRef.onValue,
            builder: (context, snap) {
              final v = snap.data?.snapshot.value;

              _userCourses = {};
              if (v is Map) {
                v.forEach((k, val) {
                  if (k == null || val == null) return;
                  if (val is Map) {
                    _userCourses[k.toString()] = val.map((kk, vv) => MapEntry(kk.toString(), vv));
                  }
                });
              }

              final keys = _userCourses.keys.toList()..sort();
              if ((_selectedCourseKey == null || !_userCourses.containsKey(_selectedCourseKey)) && keys.isNotEmpty) {
                _selectedCourseKey = keys.first;
              }

              return TabBarView(
                controller: _tab,
                children: [
                  _paymentTab(context, keys),
                  _attendanceTab(context, keys),
                  _reportTab(context),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _coursePicker(List<String> keys) {
    if (keys.isEmpty) {
      return const _MiniState(text: 'No courses assigned to this learner.');
    }

    // ✅ show title only; show code only if duplicate titles
    final titleCount = <String, int>{};
    for (final k in keys) {
      final m = (_userCourses[k] ?? {}) as Map;
      final t = (m['title'] ?? '').toString().trim();
      if (t.isEmpty) continue;
      titleCount[t] = (titleCount[t] ?? 0) + 1;
    }

    String labelFor(String courseKey) {
      final m = (_userCourses[courseKey] ?? {}) as Map;
      final code = (m['course_code'] ?? '').toString().trim();
      final title = (m['title'] ?? '').toString().trim();

      if (title.isEmpty) return code.isNotEmpty ? code : courseKey;

      final duplicate = (titleCount[title] ?? 0) > 1;
      if (duplicate && code.isNotEmpty) return '$title ($code)';
      return title;
    }

    return DropdownButtonFormField<String>(
      value: _selectedCourseKey,
      decoration: InputDecoration(
        labelText: 'Course',
        filled: true,
        fillColor: AdminLearnersScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: keys.map((k) => DropdownMenuItem(value: k, child: Text(labelFor(k)))).toList(),
      onChanged: (v) => setState(() => _selectedCourseKey = v),
    );
  }

  // ---------------- PAYMENT TAB ----------------

  Widget _paymentTab(BuildContext context, List<String> keys) {
    return ListView(
      padding: const EdgeInsets.only(top: 0),
      children: [
        _coursePicker(keys),
        const SizedBox(height: 8),
        if (_selectedCourseKey == null) const SizedBox.shrink() else _paymentPanel(context),
      ],
    );
  }

  static String _fmtDateMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Widget _paymentPanel(BuildContext context) {
    final courseKey = _selectedCourseKey!;
    final courseNode = (_userCourses[courseKey] ?? {}) as Map;
    final courseId = (courseNode['id'] ?? '').toString().trim();

    if (courseId.isEmpty) {
      return const _MiniState(text: 'This course has no "id" saved on learner node.');
    }

    final attendance = courseNode['attendance'];
    final attendanceDates = <String>[];
    if (attendance is Map) {
      attendance.forEach((_, val) {
        if (val is Map) {
          final m = val.map((k, v) => MapEntry(k.toString(), v));
          final d = (m['date'] ?? '').toString().trim();
          if (d.isNotEmpty) attendanceDates.add(d);
        }
      });
    }
    attendanceDates.sort();

    int usedSince(String startDate) {
      if (startDate.trim().isEmpty) return 0;
      return attendanceDates.where((d) => d.compareTo(startDate) >= 0).length;
    }

    return FutureBuilder<DataSnapshot>(
      key: ValueKey('payment-course-$courseId'), // ✅ force reload when course changes
      future: _coursesRef.child(courseId).get(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final courseMapRaw = snap.data!.value;
        final courseMap =
        courseMapRaw is Map ? courseMapRaw.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};

        final totalSessions = _parseTotalSessions(courseMap['duration']?.toString() ?? '');
        final pricePerLevel = _asInt(courseMap['price_per_level']);
        final pricePerMonth = _asInt(courseMap['price_per_month']);

        final sessionsDone = attendance is Map ? attendance.length : 0;

        return FutureBuilder<DataSnapshot>(
          key: ValueKey('payment-sum-$courseKey'), // ✅ force reload when course changes
          future: widget.db.ref('users/${widget.uid}/courses/$courseKey/payment_summary').get(),
          builder: (context, sumSnap) {
            final sumRaw = sumSnap.data?.value;
            final sum = sumRaw is Map ? sumRaw.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};

            final sessionsPaidTotal = _asInt(sum['sessionsPaidTotal']);
            final remindBeforeSession = _asInt(sum['remindBeforeSession']);

            final bool due = sessionsPaidTotal > 0 && sessionsDone >= (sessionsPaidTotal - 1);
            final sessionsLabel = totalSessions > 0 ? '$sessionsDone / $totalSessions' : '$sessionsDone';

            return _miniCard(
              bg: Colors.white,
              borderColor: AdminLearnersScreen.uiBorders,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniPill('Sessions: $sessionsLabel'),
                      if (pricePerMonth > 0) _miniPill('Month fee: $pricePerMonth'),
                      if (pricePerLevel > 0) _miniPill('Level fee: $pricePerLevel'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final ck = _selectedCourseKey!;
                        final node = (_userCourses[ck] ?? {}) as Map;
                        final cid = (node['id'] ?? '').toString().trim();
                        if (cid.isEmpty) return;

                        await PaymentDialogShared.showAddFromLearnerTab(
                          context: context,
                          db: widget.db,
                          uid: widget.uid,
                          courseKey: ck,
                          courseId: cid,
                        );
                      },
                      icon: const Icon(Icons.add_card_rounded),
                      label: const Text('Add payment'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AdminLearnersScreen.appBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AdminLearnersScreen.uiBorders),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Payment summary', style: TextStyle(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 6),
                        Text(
                          'Reminder before session: ${remindBeforeSession > 0 ? remindBeforeSession : sessionsPaidTotal}.',
                          style: TextStyle(
                            color: Colors.black.withOpacity(0.75),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (due) ...[
                          const SizedBox(height: 8),
                          const Text(
                            '⚠️ Payment is due (near last paid session).',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('History', style: TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 160,
                    child: StreamBuilder<DatabaseEvent>(
                      stream: _paymentsRef.orderByChild('uid').equalTo(widget.uid).onValue,
                      builder: (context, snap) {
                        final v = snap.data?.snapshot.value;
                        final items = <Map<String, dynamic>>[];

                        if (v is Map) {
                          v.forEach((k, val) {
                            if (val is Map) {
                              final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
                              if ((m['courseKey'] ?? '').toString() != courseKey) return;
                              items.add({'paymentId': k.toString(), ...m});
                            }
                          });
                        }

                        items.sort((a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])));

                        if (items.isEmpty) return const _MiniState(text: 'No payments yet.');

                        return ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final p = items[i];
                            final fee = _asInt(p['amount']);
                            final sp = _asInt(p['sessionsPaid']);
                            final method = (p['method'] ?? '').toString();
                            final notes = (p['notes'] ?? '').toString();

                            final paidAt = _fmtDateMs(_asInt(p['paidAt']));
                            final startDate = (p['startDate'] ?? '').toString().trim();

                            final used = usedSince(startDate);
                            final left = (sp - used) < 0 ? 0 : (sp - used);

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: _miniCard(
                                bg: Colors.white,
                                borderColor: AdminLearnersScreen.uiBorders,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _miniPill('Fee: $fee'),
                                        _miniPill('Paid: ${paidAt.isEmpty ? '-' : paidAt}'),
                                        _miniPill('Start: ${startDate.isEmpty ? '-' : startDate}'),
                                        _miniPill('Left: $left'),
                                      ],
                                    ),
                                    if (method.trim().isNotEmpty || notes.trim().isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        [
                                          if (method.trim().isNotEmpty) method,
                                          if (notes.trim().isNotEmpty) notes
                                        ].join(' • '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.black.withOpacity(0.65),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
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
              ),
            );
          },
        );
      },
    );
  }

  // ---------------- ATTENDANCE TAB ----------------

  Widget _attendanceTab(BuildContext context, List<String> keys) {
    if (keys.isEmpty) return const _MiniState(text: 'No courses.');

    final courseKey = _selectedCourseKey;
    if (courseKey == null) return const _MiniState(text: 'Pick a course.');

    final courseNode = (_userCourses[courseKey] ?? {}) as Map;
    final attendance = courseNode['attendance'];
    final courseId = (courseNode['id'] ?? '').toString().trim();

    if (courseId.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          _coursePicker(keys),
          const SizedBox(height: 8),
          const _MiniState(text: 'This course is missing an id.'),
        ],
      );
    }

    final items = <Map<String, dynamic>>[];
    if (attendance is Map) {
      attendance.forEach((k, v) {
        if (v is Map) {
          final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          items.add(m.cast<String, dynamic>());
        }
      });
    }

    items.sort((a, b) => (a['date'] ?? '').toString().compareTo((b['date'] ?? '').toString()));

    return FutureBuilder<DataSnapshot>(
      key: ValueKey('attendance-course-$courseId'), // ✅ reload when course changes
      future: _coursesRef.child(courseId).get(),
      builder: (context, cs) {
        if (!cs.hasData) {
          return ListView(
            padding: EdgeInsets.zero,
            children: const [
              SizedBox(height: 8),
              Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          );
        }

        final cRaw = cs.data?.value;
        final cMap = cRaw is Map ? cRaw.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
        final totalSessions = _parseTotalSessions(cMap['duration']?.toString() ?? '');
        final label = totalSessions > 0 ? '${items.length} / $totalSessions' : '${items.length}';

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _coursePicker(keys),
            const SizedBox(height: 8),
            _miniCard(
              child: Text(
                'Attendance: $label',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 8),
            if (items.isEmpty)
              const _MiniState(text: 'No attendance yet.')
            else
              ...items.asMap().entries.map((entry) {
                final i = entry.key;
                final s = entry.value;

                final date = (s['date'] ?? '').toString();
                final statusRaw = (s['status'] ?? '').toString();
                final status = statusRaw.toLowerCase().trim();
                final teacher = (s['teacherName'] ?? '').toString();
                final taught = s['taught'] is Map ? (s['taught'] as Map) : null;
                final taughtTitle = taught == null ? '' : (taught['title'] ?? '').toString();

                Color bar;
                Color tint;
                if (status == 'present') {
                  bar = const Color(0xFF157A3D);
                  tint = const Color(0xFF157A3D).withOpacity(0.08);
                } else if (status == 'absent') {
                  bar = Colors.red;
                  tint = Colors.red.withOpacity(0.08);
                } else {
                  bar = const Color(0xFFF98D28);
                  tint = const Color(0xFFF98D28).withOpacity(0.10);
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AdminLearnersScreen.uiBorders),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 58,
                          decoration: BoxDecoration(
                            color: bar,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '#${i + 1}  $date — $statusRaw',
                                  style: const TextStyle(fontWeight: FontWeight.w900),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  [
                                    if (taughtTitle.trim().isNotEmpty) taughtTitle,
                                    if (teacher.trim().isNotEmpty) teacher,
                                  ].join(' • '),
                                  style: TextStyle(
                                    color: Colors.black.withOpacity(0.65),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
          ],
        );
      },
    );
  }

  // ---------------- REPORT TAB (later) ----------------

  Widget _reportTab(BuildContext context) {
    return const _MiniState(text: 'Report tab is ready (we will build it later).');
  }

  // ---------------- UI helpers ----------------

  static Widget _miniCard({
    required Widget child,
    Color bg = Colors.white,
    Color borderColor = AdminLearnersScreen.uiBorders,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    );
  }

  static Widget _miniPill(String t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AdminLearnersScreen.appBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AdminLearnersScreen.primaryBlue,
        ),
      ),
    );
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static int _parseTotalSessions(String duration) {
    final m = RegExp(r'(\d+)\s*sessions', caseSensitive: false).firstMatch(duration);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  }
}

class _MiniState extends StatelessWidget {
  const _MiniState({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _MinimalStaff {
  _MinimalStaff({required this.firstName, required this.lastName, required this.email});

  final String firstName;
  final String lastName;
  final String email;

  String get fullName => '${firstName.trim()} ${lastName.trim()}'.trim();
}
