import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/push_client.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';

class AdminAdminTodosScreen extends StatefulWidget {
  const AdminAdminTodosScreen({super.key});

  @override
  State<AdminAdminTodosScreen> createState() => _AdminAdminTodosScreenState();
}

enum _TodoFilter { all, newOnly, seenOnly, doneOnly, overdueOnly }

enum _TodoViewMode { assignedToMe, assignedByMe }

class _AdminAdminTodosScreenState extends State<AdminAdminTodosScreen> {
  final _db = FirebaseDatabase.instance;

  String _search = '';
  _TodoFilter _filter = _TodoFilter.all;
  _TodoViewMode _viewMode = _TodoViewMode.assignedToMe;

  String? _myUid;
  String _myName = 'Admin';
  Stream<DatabaseEvent>? _inboxTodosStream;
  Stream<DatabaseEvent>? _allTodosStream;

  final Set<String> _expanded = <String>{};
  final Set<String> _updatingIds = <String>{};

  @override
  void initState() {
    super.initState();
    _myUid = FirebaseAuth.instance.currentUser?.uid;
    if (_myUid != null && _myUid!.trim().isNotEmpty) {
      final uid = _myUid!.trim();
      _inboxTodosStream = _db.ref('admin_todos/$uid').onValue;
      _allTodosStream = _db.ref('admin_todos').onValue;
      _loadMyName();
      _backfillOutboxFromInboxes();
    }
  }

  Stream<DatabaseEvent>? get _activeTodosStream {
    return _viewMode == _TodoViewMode.assignedByMe
        ? _allTodosStream
        : _inboxTodosStream;
  }

  Future<void> _loadMyName() async {
    final uid = _myUid?.trim() ?? '';
    if (uid.isEmpty) return;

    try {
      final snap = await _db.ref('users/$uid').get();
      final val = snap.value;
      if (val is! Map) return;
      final m = val.map((k, v) => MapEntry(k.toString(), v));
      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      final name = full.isNotEmpty
          ? full
          : (email.isNotEmpty ? email : 'Admin');
      if (!mounted) return;
      setState(() => _myName = name);
    } catch (_) {}
  }

  Future<void> _backfillOutboxFromInboxes() async {
    final myUid = _myUid?.trim() ?? '';
    if (myUid.isEmpty) return;

    try {
      final usersSnap = await _db.ref('users').get();
      final admins = _parseAdmins(usersSnap.value);

      for (final admin in admins) {
        final assigneeUid = admin.uid.trim();
        if (assigneeUid.isEmpty || assigneeUid == myUid) continue;

        final inboxSnap = await _db.ref('admin_todos/$assigneeUid').get();
        final raw = inboxSnap.value;
        if (raw is! Map) continue;

        for (final e in raw.entries) {
          final todoId = e.key.toString().trim();
          final val = e.value;
          if (todoId.isEmpty || val is! Map) continue;

          final m = val.map((k, v) => MapEntry(k.toString(), v));
          final creator = (m['createdByUid'] ?? '').toString().trim();
          if (creator != myUid) continue;

          m['assigneeUid'] = (m['assigneeUid'] ?? assigneeUid)
              .toString()
              .trim();
          m['assigneeName'] = (m['assigneeName'] ?? admin.name)
              .toString()
              .trim();
          await _db.ref('admin_todo_outbox/$myUid/$todoId').update(m);
        }
      }
    } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, SnackBar(content: Text(msg)));
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return 'No due date';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  List<_AdminLite> _parseAdmins(dynamic value) {
    if (value is! Map) return <_AdminLite>[];
    final out = <_AdminLite>[];

    value.forEach((k, raw) {
      if (raw is! Map) return;
      final m = raw.map((kk, vv) => MapEntry(kk.toString(), vv));
      final role = (m['role'] ?? '').toString().trim().toLowerCase();
      if (role != 'admin') return;
      final uid = k.toString().trim();
      if (uid.isEmpty) return;
      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      out.add(
        _AdminLite(
          uid: uid,
          name: full.isNotEmpty ? full : (email.isNotEmpty ? email : uid),
          email: email,
        ),
      );
    });

    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  List<_AdminTodoRow> _parseTodoRows(dynamic value) {
    if (value is! Map) return <_AdminTodoRow>[];
    final out = <_AdminTodoRow>[];

    value.forEach((k, raw) {
      if (k == null || raw == null || raw is! Map) return;
      final m = raw.map((kk, vv) => MapEntry(kk.toString(), vv));
      out.add(_AdminTodoRow(id: k.toString(), todo: _AdminTodo.fromMap(m)));
    });

    return out;
  }

  List<_AdminTodoRow> _parseAssignedByMeRows(dynamic value) {
    final myUid = _myUid?.trim() ?? '';
    if (myUid.isEmpty || value is! Map) return <_AdminTodoRow>[];

    final out = <_AdminTodoRow>[];
    value.forEach((assigneeUid, rawTodos) {
      if (rawTodos is! Map) return;
      final assignee = assigneeUid.toString().trim();
      rawTodos.forEach((todoId, rawTodo) {
        if (todoId == null || rawTodo is! Map) return;
        final m = rawTodo.map((kk, vv) => MapEntry(kk.toString(), vv));
        final createdBy = (m['createdByUid'] ?? '').toString().trim();
        if (createdBy != myUid) return;

        if ((m['assigneeUid'] ?? '').toString().trim().isEmpty &&
            assignee.isNotEmpty) {
          m['assigneeUid'] = assignee;
        }

        final rowId = '$assignee::${todoId.toString().trim()}';
        out.add(_AdminTodoRow(id: rowId, todo: _AdminTodo.fromMap(m)));
      });
    });

    out.sort((a, b) {
      final aa = a.todo.createdAtMs ?? 0;
      final bb = b.todo.createdAtMs ?? 0;
      return bb.compareTo(aa);
    });
    return out;
  }

  Color _statusColor(String status, {required bool isOverdue}) {
    final s = status.trim().toLowerCase();
    if (s == 'done') return const Color(0xFF2E7D32);
    if (isOverdue) return const Color(0xFFB71C1C);
    if (s == 'seen' || s == 'read') return const Color(0xFF1565C0);
    return const Color(0xFFEF6C00);
  }

  String _statusLabel(String status, {required bool isOverdue}) {
    final s = status.trim().toLowerCase();
    if (s == 'done') return 'Done';
    if (isOverdue) return 'Overdue';
    if (s == 'seen' || s == 'read') return 'Seen';
    return 'New';
  }

  bool _isOverdue(_AdminTodo t, int nowMs) {
    if (t.status.trim().toLowerCase() == 'done') return false;
    final dueAt = t.dueAtMs;
    if (dueAt == null || dueAt <= 0) return false;
    return dueAt < nowMs;
  }

  Future<String?> _getFcmToken(String uid) async {
    final snap = await _db.ref('fcm_tokens/$uid/token').get();
    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<void> _notifyAssigneeOnCreate({
    required _AdminLite assignee,
    required String todoId,
    required _TodoDraft draft,
  }) async {
    try {
      final token = await _getFcmToken(assignee.uid);
      if (token == null) return;
      await PushClient.sendToToken(
        token: token,
        title: 'New admin TODO',
        message: draft.title,
        data: {
          'type': 'admin_todo',
          'route': 'admin_todos',
          'todoId': todoId,
          'assigneeUid': assignee.uid,
          'createdByUid': _myUid ?? '',
        },
      );
    } catch (_) {}
  }

  Future<void> _notifyCreatorOnUpdate({
    required _AdminTodo todo,
    required String todoId,
    required String action,
  }) async {
    final creatorUid = todo.createdByUid.trim();
    final myUid = _myUid?.trim() ?? '';
    if (creatorUid.isEmpty || creatorUid == myUid) return;

    try {
      final token = await _getFcmToken(creatorUid);
      if (token == null) return;
      final title = action == 'done' ? 'TODO completed' : 'TODO seen';
      final body = '$_myName: ${todo.title.trim()}';
      await PushClient.sendToToken(
        token: token,
        title: title,
        message: body,
        data: {
          'type': 'admin_todo',
          'route': 'admin_todos',
          'todoId': todoId,
          'assigneeUid': myUid,
          'createdByUid': creatorUid,
          'action': action,
        },
      );
    } catch (_) {}
  }

  Future<void> _markSeenIfNeeded(String todoId, _AdminTodo todo) async {
    final myUid = _myUid?.trim() ?? '';
    if (myUid.isEmpty) return;
    final status = todo.status.trim().toLowerCase();
    if (status == 'seen' || status == 'read' || status == 'done') return;
    if (_updatingIds.contains(todoId)) return;

    setState(() => _updatingIds.add(todoId));
    try {
      var updated = false;
      final tx = await _db.ref('admin_todos/$myUid/$todoId').runTransaction((
        cur,
      ) {
        if (cur == null || cur is! Map) {
          return Transaction.abort();
        }
        final map = cur.map((k, v) => MapEntry(k.toString(), v));
        final currentStatus = (map['status'] ?? '').toString().toLowerCase();
        if (currentStatus == 'seen' ||
            currentStatus == 'read' ||
            currentStatus == 'done') {
          return Transaction.success(cur);
        }
        map['status'] = 'seen';
        map['seenAt'] = ServerValue.timestamp;
        map['updatedAt'] = ServerValue.timestamp;
        updated = true;
        return Transaction.success(map);
      });

      if (tx.committed && updated) {
        await _syncOutboxCopy(
          todoId: todoId,
          source: todo,
          status: 'seen',
          seenAt: ServerValue.timestamp,
        );
        await _notifyCreatorOnUpdate(
          todo: todo,
          todoId: todoId,
          action: 'seen',
        );
      }
    } catch (e) {
      _snack(toHumanError(e, fallback: 'Could not mark TODO as seen.'));
    } finally {
      if (mounted) setState(() => _updatingIds.remove(todoId));
    }
  }

  Future<void> _markDone(String todoId, _AdminTodo todo) async {
    final myUid = _myUid?.trim() ?? '';
    if (myUid.isEmpty) return;
    if (_updatingIds.contains(todoId)) return;

    setState(() => _updatingIds.add(todoId));
    try {
      var updated = false;
      final tx = await _db.ref('admin_todos/$myUid/$todoId').runTransaction((
        cur,
      ) {
        if (cur == null || cur is! Map) {
          return Transaction.abort();
        }
        final map = cur.map((k, v) => MapEntry(k.toString(), v));
        final currentStatus = (map['status'] ?? '').toString().toLowerCase();
        if (currentStatus == 'done') {
          return Transaction.success(cur);
        }
        map['status'] = 'done';
        map['doneAt'] = ServerValue.timestamp;
        map['updatedAt'] = ServerValue.timestamp;
        updated = true;
        return Transaction.success(map);
      });

      if (tx.committed && updated) {
        await _syncOutboxCopy(
          todoId: todoId,
          source: todo,
          status: 'done',
          seenAt: todo.seenAtMs ?? ServerValue.timestamp,
          doneAt: ServerValue.timestamp,
        );
        _snack('Marked done');
        await _notifyCreatorOnUpdate(
          todo: todo,
          todoId: todoId,
          action: 'done',
        );
      }
    } catch (e) {
      _snack(toHumanError(e, fallback: 'Could not mark TODO as done.'));
    } finally {
      if (mounted) setState(() => _updatingIds.remove(todoId));
    }
  }

  Future<void> _syncOutboxCopy({
    required String todoId,
    required _AdminTodo source,
    String? status,
    dynamic seenAt,
    dynamic doneAt,
  }) async {
    final creatorUid = source.createdByUid.trim();
    if (creatorUid.isEmpty || todoId.trim().isEmpty) return;

    final meUid = _myUid?.trim() ?? '';
    final meName = _myName.trim();

    final update = <String, dynamic>{
      'title': source.title,
      'description': source.description,
      'status': status ?? source.status,
      'createdByUid': creatorUid,
      'createdByName': source.createdByName,
      'assigneeUid': source.assigneeUid.isNotEmpty ? source.assigneeUid : meUid,
      'assigneeName': source.assigneeName.isNotEmpty
          ? source.assigneeName
          : (meName.isNotEmpty ? meName : 'Admin'),
      'updatedAt': ServerValue.timestamp,
    };
    if (source.dueAtMs != null) update['dueAt'] = source.dueAtMs;
    if (source.createdAtMs != null) update['createdAt'] = source.createdAtMs;
    if (seenAt != null) update['seenAt'] = seenAt;
    if (doneAt != null) update['doneAt'] = doneAt;

    await _db.ref('admin_todo_outbox/$creatorUid/$todoId').update(update);
  }

  Future<void> _openCreateTodoDialog() async {
    final myUid = _myUid?.trim() ?? '';
    if (myUid.isEmpty) return;

    final usersSnap = await _db.ref('users').get();
    final admins = _parseAdmins(
      usersSnap.value,
    ).where((a) => a.uid != myUid).toList();

    if (!mounted) return;

    if (admins.isEmpty) {
      _snack('No other admins found.');
      return;
    }

    final draft = await showDialog<_TodoDraft?>(
      context: context,
      builder: (_) => _CreateTodoDialog(admins: admins),
    );
    if (draft == null) return;

    try {
      for (final assignee in draft.assignees) {
        final ref = _db.ref('admin_todos/${assignee.uid}').push();
        final todoId = ref.key ?? '';

        final payload = {
          'title': draft.title.trim(),
          'description': draft.description.trim(),
          'dueAt': draft.dueAtMs,
          'status': 'new',
          'createdAt': ServerValue.timestamp,
          'updatedAt': ServerValue.timestamp,
          'createdByUid': myUid,
          'createdByName': _myName,
          'assigneeUid': assignee.uid,
          'assigneeName': assignee.name,
          'seenAt': null,
          'doneAt': null,
        };

        await ref.set(payload);

        if (todoId.isNotEmpty) {
          await _db.ref('admin_todo_outbox/$myUid/$todoId').set(payload);
        }

        if (todoId.isNotEmpty) {
          await _notifyAssigneeOnCreate(
            assignee: assignee,
            todoId: todoId,
            draft: draft,
          );
        }
      }

      _snack('TODO sent to ${draft.assignees.length} admin(s)');
    } catch (e) {
      _snack(toHumanError(e, fallback: 'Could not create TODO.'));
    }
  }

  List<_AdminTodoRow> _applyFilters(List<_AdminTodoRow> rows) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final q = _search.trim().toLowerCase();

    final filtered = rows.where((row) {
      final t = row.todo;
      final isOverdue = _isOverdue(t, now);

      final textMatch = q.isEmpty
          ? true
          : t.title.toLowerCase().contains(q) ||
                t.description.toLowerCase().contains(q) ||
                t.createdByName.toLowerCase().contains(q) ||
                t.assigneeName.toLowerCase().contains(q);

      final status = t.status.toLowerCase().trim();
      final statusMatch = switch (_filter) {
        _TodoFilter.all => true,
        _TodoFilter.newOnly => status == 'new',
        _TodoFilter.seenOnly => status == 'seen' || status == 'read',
        _TodoFilter.doneOnly => status == 'done',
        _TodoFilter.overdueOnly => isOverdue,
      };

      return textMatch && statusMatch;
    }).toList();

    filtered.sort((a, b) {
      final aDone = a.todo.status.trim().toLowerCase() == 'done';
      final bDone = b.todo.status.trim().toLowerCase() == 'done';
      if (aDone != bDone) return aDone ? 1 : -1;

      final aDue = a.todo.dueAtMs ?? (1 << 62);
      final bDue = b.todo.dueAtMs ?? (1 << 62);
      final c = aDue.compareTo(bDue);
      if (c != 0) return c;

      return (b.todo.createdAtMs ?? 0).compareTo(a.todo.createdAtMs ?? 0);
    });

    return filtered;
  }

  Widget _buildHeaderChips(List<_AdminTodoRow> rows) {
    final now = DateTime.now().millisecondsSinceEpoch;
    int newCount = 0;
    int seenCount = 0;
    int doneCount = 0;
    int overdueCount = 0;

    for (final row in rows) {
      final s = row.todo.status.toLowerCase().trim();
      final isOverdue = _isOverdue(row.todo, now);
      if (s == 'done') {
        doneCount++;
      } else if (s == 'seen' || s == 'read') {
        seenCount++;
      } else {
        newCount++;
      }
      if (isOverdue) overdueCount++;
    }

    Widget chip(String label, String value, Color color, Color bg) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Text(
          '$label $value',
          style: TextStyle(color: color, fontWeight: FontWeight.w900),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(
          'New',
          '$newCount',
          const Color(0xFFEF6C00),
          const Color(0xFFFFF2E7),
        ),
        chip(
          'Seen',
          '$seenCount',
          const Color(0xFF1565C0),
          const Color(0xFFE8F2FF),
        ),
        chip(
          'Done',
          '$doneCount',
          const Color(0xFF2E7D32),
          const Color(0xFFE9F8EE),
        ),
        chip(
          'Overdue',
          '$overdueCount',
          const Color(0xFFB71C1C),
          const Color(0xFFFFECEB),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_myUid == null || _myUid!.trim().isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin TODOs')),
        body: adminWebBodyFrame(
          context: context,
          child: const Center(child: Text('Not logged in.')),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Admin TODOs',
          style: TextStyle(
            color: Color(0xFF1A2B48),
            fontWeight: FontWeight.w900,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF1A2B48)),
        actions: [
          IconButton(
            tooltip: 'Add TODO',
            onPressed: _openCreateTodoDialog,
            icon: const Icon(Icons.add_task_rounded, color: Color(0xFF1A2B48)),
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1450,
        child: StreamBuilder<DatabaseEvent>(
          stream: _activeTodosStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(child: Text('Could not load TODOs.'));
            }

            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final rows = _viewMode == _TodoViewMode.assignedByMe
                ? _parseAssignedByMeRows(snap.data?.snapshot.value)
                : _parseTodoRows(snap.data?.snapshot.value);
            final filtered = _applyFilters(rows);
            final now = DateTime.now().millisecondsSinceEpoch;

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<_TodoViewMode>(
                      segments: const [
                        ButtonSegment<_TodoViewMode>(
                          value: _TodoViewMode.assignedToMe,
                          label: Text('Assigned to me'),
                          icon: Icon(Icons.inbox_rounded),
                        ),
                        ButtonSegment<_TodoViewMode>(
                          value: _TodoViewMode.assignedByMe,
                          label: Text('Assigned by me'),
                          icon: Icon(Icons.outbox_rounded),
                        ),
                      ],
                      selected: {_viewMode},
                      onSelectionChanged: (selection) {
                        final next = selection.first;
                        if (next == _viewMode) return;
                        setState(() {
                          _viewMode = next;
                          _expanded.clear();
                          _updatingIds.clear();
                          _filter = _TodoFilter.all;
                        });
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      hintText: 'Search TODOs...',
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        ChoiceChip(
                          selected: _filter == _TodoFilter.all,
                          onSelected: (_) =>
                              setState(() => _filter = _TodoFilter.all),
                          label: const Text('All'),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          selected: _filter == _TodoFilter.newOnly,
                          onSelected: (_) =>
                              setState(() => _filter = _TodoFilter.newOnly),
                          label: const Text('New'),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          selected: _filter == _TodoFilter.seenOnly,
                          onSelected: (_) =>
                              setState(() => _filter = _TodoFilter.seenOnly),
                          label: const Text('Seen'),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          selected: _filter == _TodoFilter.doneOnly,
                          onSelected: (_) =>
                              setState(() => _filter = _TodoFilter.doneOnly),
                          label: const Text('Done'),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          selected: _filter == _TodoFilter.overdueOnly,
                          onSelected: (_) =>
                              setState(() => _filter = _TodoFilter.overdueOnly),
                          label: const Text('Overdue'),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  child: _buildHeaderChips(rows),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Text(
                            _viewMode == _TodoViewMode.assignedByMe
                                ? 'No TODOs assigned by you yet.'
                                : 'No TODOs assigned to you yet.',
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final row = filtered[i];
                            final t = row.todo;
                            final isExpanded = _expanded.contains(row.id);
                            final isOverdue = _isOverdue(t, now);
                            final statusColor = _statusColor(
                              t.status,
                              isOverdue: isOverdue,
                            );
                            final statusLabel = _statusLabel(
                              t.status,
                              isOverdue: isOverdue,
                            );

                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: statusColor.withValues(alpha: 0.24),
                                ),
                              ),
                              child: Material(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(18),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: () async {
                                    setState(() {
                                      if (isExpanded) {
                                        _expanded.remove(row.id);
                                      } else {
                                        _expanded.add(row.id);
                                      }
                                    });

                                    if (!isExpanded &&
                                        _viewMode ==
                                            _TodoViewMode.assignedToMe) {
                                      await _markSeenIfNeeded(row.id, t);
                                    }
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      children: [
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Container(
                                              width: 12,
                                              height: 12,
                                              margin: const EdgeInsets.only(
                                                top: 5,
                                              ),
                                              decoration: BoxDecoration(
                                                color: statusColor,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    t.title.isEmpty
                                                        ? '(No title)'
                                                        : t.title,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color: Color(0xFF1A2B48),
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize: 15,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 7),
                                                  Wrap(
                                                    spacing: 8,
                                                    runSpacing: 8,
                                                    children: [
                                                      _TodoMetaChip(
                                                        icon:
                                                            Icons.event_rounded,
                                                        text:
                                                            'Due: ${_fmtDate(t.dueAtMs ?? 0)}',
                                                      ),
                                                      _TodoMetaChip(
                                                        icon: Icons
                                                            .person_rounded,
                                                        text:
                                                            _viewMode ==
                                                                _TodoViewMode
                                                                    .assignedByMe
                                                            ? 'To: ${t.assigneeName.isEmpty ? 'Admin' : t.assigneeName}'
                                                            : 'From: ${t.createdByName.isEmpty ? 'Admin' : t.createdByName}',
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 9,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: statusColor.withValues(
                                                  alpha: 0.12,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Text(
                                                statusLabel,
                                                style: TextStyle(
                                                  color: statusColor,
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Icon(
                                              isExpanded
                                                  ? Icons.expand_less_rounded
                                                  : Icons.expand_more_rounded,
                                              color: Colors.black.withValues(
                                                alpha: 0.4,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (isExpanded) ...[
                                          const SizedBox(height: 12),
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              t.description.trim().isEmpty
                                                  ? 'No description'
                                                  : t.description.trim(),
                                              style: TextStyle(
                                                color: Colors.black.withValues(
                                                  alpha: 0.72,
                                                ),
                                                fontWeight: FontWeight.w600,
                                                height: 1.35,
                                              ),
                                            ),
                                          ),
                                          if (_viewMode ==
                                              _TodoViewMode.assignedToMe) ...[
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              width: double.infinity,
                                              child: FilledButton.icon(
                                                onPressed:
                                                    (t.status
                                                                .toLowerCase()
                                                                .trim() ==
                                                            'done' ||
                                                        _updatingIds.contains(
                                                          row.id,
                                                        ))
                                                    ? null
                                                    : () =>
                                                          _markDone(row.id, t),
                                                icon:
                                                    _updatingIds.contains(
                                                      row.id,
                                                    )
                                                    ? const SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 2,
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                      )
                                                    : const Icon(
                                                        Icons
                                                            .check_circle_rounded,
                                                      ),
                                                label: Text(
                                                  t.status
                                                              .toLowerCase()
                                                              .trim() ==
                                                          'done'
                                                      ? 'Done'
                                                      : (_updatingIds.contains(
                                                              row.id,
                                                            )
                                                            ? 'Updating...'
                                                            : 'Mark done'),
                                                ),
                                                style: FilledButton.styleFrom(
                                                  backgroundColor: const Color(
                                                    0xFF1A2B48,
                                                  ),
                                                  foregroundColor: Colors.white,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 12,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ],
                                    ),
                                  ),
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateTodoDialog,
        backgroundColor: const Color(0xFF1A2B48),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New TODO'),
      ),
    );
  }
}

class _TodoMetaChip extends StatelessWidget {
  const _TodoMetaChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF1A2B48)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFF1A2B48),
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateTodoDialog extends StatefulWidget {
  const _CreateTodoDialog({required this.admins});

  final List<_AdminLite> admins;

  @override
  State<_CreateTodoDialog> createState() => _CreateTodoDialogState();
}

class _CreateTodoDialogState extends State<_CreateTodoDialog> {
  final titleC = TextEditingController();
  final descC = TextEditingController();
  final Set<String> _selected = <String>{};
  DateTime? _due;

  @override
  void dispose() {
    titleC.dispose();
    descC.dispose();
    super.dispose();
  }

  int? get _dueAtMs => _due?.millisecondsSinceEpoch;

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final initial = _due ?? now.add(const Duration(days: 1));
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (pickedDate == null) return;

    if (!mounted) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (pickedTime == null) return;

    setState(() {
      _due = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    String dueLabel() {
      if (_due == null) return 'Set due date';
      final d = _due!;
      String two(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    }

    return AlertDialog(
      title: const Text('Create TODO for admins'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleC,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'Short task title',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descC,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Task details',
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _pickDue,
                  icon: const Icon(Icons.event_rounded),
                  label: Text(dueLabel()),
                ),
              ),
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Assign to',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.admins.length,
                  itemBuilder: (_, i) {
                    final a = widget.admins[i];
                    final selected = _selected.contains(a.uid);
                    return CheckboxListTile(
                      dense: true,
                      value: selected,
                      title: Text(a.name),
                      subtitle: a.email.trim().isEmpty ? null : Text(a.email),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selected.add(a.uid);
                          } else {
                            _selected.remove(a.uid);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final title = titleC.text.trim();
            final description = descC.text.trim();
            final selectedAdmins = widget.admins
                .where((a) => _selected.contains(a.uid))
                .toList();

            if (title.isEmpty) {
              AppToast.fromSnackBar(
                context,
                const SnackBar(content: Text('Title is required.')),
              );
              return;
            }
            if (_dueAtMs == null) {
              AppToast.fromSnackBar(
                context,
                const SnackBar(content: Text('Please set a due date.')),
              );
              return;
            }
            if (selectedAdmins.isEmpty) {
              AppToast.fromSnackBar(
                context,
                const SnackBar(content: Text('Select at least one admin.')),
              );
              return;
            }

            Navigator.pop(
              context,
              _TodoDraft(
                title: title,
                description: description,
                dueAtMs: _dueAtMs,
                assignees: selectedAdmins,
              ),
            );
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _TodoDraft {
  _TodoDraft({
    required this.title,
    required this.description,
    required this.dueAtMs,
    required this.assignees,
  });

  final String title;
  final String description;
  final int? dueAtMs;
  final List<_AdminLite> assignees;
}

class _AdminLite {
  const _AdminLite({
    required this.uid,
    required this.name,
    required this.email,
  });

  final String uid;
  final String name;
  final String email;
}

class _AdminTodoRow {
  const _AdminTodoRow({required this.id, required this.todo});

  final String id;
  final _AdminTodo todo;
}

class _AdminTodo {
  _AdminTodo({
    required this.title,
    required this.description,
    required this.status,
    required this.createdByUid,
    required this.createdByName,
    required this.assigneeUid,
    required this.assigneeName,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.dueAtMs,
    required this.seenAtMs,
    required this.doneAtMs,
  });

  final String title;
  final String description;
  final String status;
  final String createdByUid;
  final String createdByName;
  final String assigneeUid;
  final String assigneeName;
  final int? createdAtMs;
  final int? updatedAtMs;
  final int? dueAtMs;
  final int? seenAtMs;
  final int? doneAtMs;

  factory _AdminTodo.fromMap(Map<String, dynamic> m) {
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return _AdminTodo(
      title: (m['title'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      status: (m['status'] ?? 'new').toString(),
      createdByUid: (m['createdByUid'] ?? '').toString(),
      createdByName: (m['createdByName'] ?? '').toString(),
      assigneeUid: (m['assigneeUid'] ?? '').toString(),
      assigneeName: (m['assigneeName'] ?? '').toString(),
      createdAtMs: toInt(m['createdAt']),
      updatedAtMs: toInt(m['updatedAt']),
      dueAtMs: toInt(m['dueAt']),
      seenAtMs: toInt(m['seenAt']),
      doneAtMs: toInt(m['doneAt']),
    );
  }
}
