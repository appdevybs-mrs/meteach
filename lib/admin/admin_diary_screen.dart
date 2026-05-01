import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';

class AdminDiaryScreen extends StatefulWidget {
  const AdminDiaryScreen({super.key});

  @override
  State<AdminDiaryScreen> createState() => _AdminDiaryScreenState();
}

enum _DiaryScope { active, archived }

enum _DiaryActionType { all, call, money, message, visit, followUp, other }

class _AdminDiaryScreenState extends State<AdminDiaryScreen> {
  final DatabaseReference _entriesRef = FirebaseDatabase.instance.ref(
    'admin_diary_entries',
  );

  String _myUid = '';
  String _myName = 'Admin';
  String _query = '';
  _DiaryScope _scope = _DiaryScope.active;
  _DiaryActionType _actionFilter = _DiaryActionType.all;
  bool _pinnedOnly = false;
  bool _followUpOpenOnly = false;
  bool _todayOnly = false;
  bool _selectionMode = false;
  final Set<String> _selectedEntryIds = <String>{};
  final Set<String> _expandedDays = <String>{};

  @override
  void initState() {
    super.initState();
    _myUid = (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    _loadMyName();
    _expandedDays.add(_todayKey());
  }

  Future<void> _loadMyName() async {
    final uid = _myUid.trim();
    if (uid.isEmpty) return;
    try {
      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();
      final raw = snap.value;
      if (raw is! Map) return;
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
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

  String _todayKey() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  String _dateKeyFromMs(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  _DiaryActionType _detectActionType(String text) {
    final t = text.toLowerCase();
    if (t.contains('call') || t.contains('phone') || t.contains('called')) {
      return _DiaryActionType.call;
    }
    if (t.contains('pay') ||
        t.contains('money') ||
        t.contains('received') ||
        t.contains(r'$') ||
        t.contains('usd') ||
        t.contains('lbp')) {
      return _DiaryActionType.money;
    }
    if (t.contains('text') ||
        t.contains('message') ||
        t.contains('whatsapp') ||
        t.contains('msg')) {
      return _DiaryActionType.message;
    }
    if (t.contains('visit') || t.contains('came') || t.contains('met')) {
      return _DiaryActionType.visit;
    }
    if (t.contains('follow') || t.contains('remind')) {
      return _DiaryActionType.followUp;
    }
    return _DiaryActionType.other;
  }

  List<String> _extractKeywords(String text) {
    final cleaned = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'));
    final stop = <String>{
      'the',
      'and',
      'for',
      'with',
      'this',
      'that',
      'from',
      'have',
      'has',
      'had',
      'was',
      'were',
      'you',
      'your',
      'our',
      'about',
      'will',
      'then',
      'them',
      'they',
      'today',
    };
    final out = <String>[];
    for (final token in cleaned) {
      if (token.length < 3) continue;
      if (stop.contains(token)) continue;
      if (out.contains(token)) continue;
      out.add(token);
      if (out.length >= 12) break;
    }
    return out;
  }

  Future<void> _toastError(
    Object e, {
    String fallback = 'Operation failed.',
  }) async {
    if (!mounted) return;
    AppToast.show(
      context,
      toHumanError(e, fallback: fallback),
      type: AppToastType.error,
    );
  }

  Future<void> _createEntry({
    required String text,
    required bool isPinned,
    required String followUpStatus,
    required int followUpAt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final action = _detectActionType(text);
    final keywords = _extractKeywords(text);
    final node = _entriesRef.push();
    await node.set({
      'text': text.trim(),
      'dateKey': _dateKeyFromMs(now),
      'createdAt': now,
      'createdByUid': _myUid,
      'createdByName': _myName,
      'updatedAt': now,
      'updatedByUid': _myUid,
      'updatedByName': _myName,
      'actionType': action.name,
      'keywords': keywords,
      'isPinned': isPinned,
      'pinnedAt': isPinned ? now : null,
      'pinnedByUid': isPinned ? _myUid : null,
      'followUpStatus': followUpStatus,
      'followUpAt': followUpAt > 0 ? followUpAt : null,
      'archivedAt': null,
      'archivedByUid': null,
    });
  }

  Future<void> _editEntry(
    _DiaryRow row, {
    required String text,
    required bool isPinned,
    required String followUpStatus,
    required int followUpAt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final action = _detectActionType(text);
    final keywords = _extractKeywords(text);
    await _entriesRef.child(row.id).update({
      'text': text.trim(),
      'actionType': action.name,
      'keywords': keywords,
      'isPinned': isPinned,
      'pinnedAt': isPinned
          ? (row.entry.pinnedAtMs > 0 ? row.entry.pinnedAtMs : now)
          : null,
      'pinnedByUid': isPinned
          ? (row.entry.pinnedByUid.isNotEmpty ? row.entry.pinnedByUid : _myUid)
          : null,
      'followUpStatus': followUpStatus,
      'followUpAt': followUpAt > 0 ? followUpAt : null,
      'updatedAt': now,
      'updatedByUid': _myUid,
      'updatedByName': _myName,
    });
  }

  Future<void> _setPinned(_DiaryRow row, bool pinned) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _entriesRef.child(row.id).update({
      'isPinned': pinned,
      'pinnedAt': pinned ? now : null,
      'pinnedByUid': pinned ? _myUid : null,
      'updatedAt': now,
      'updatedByUid': _myUid,
      'updatedByName': _myName,
    });
  }

  Future<void> _archiveEntry(_DiaryRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Archive entry?'),
        content: const Text('You can restore it later from Archived.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _entriesRef.child(row.id).update({
      'archivedAt': now,
      'archivedByUid': _myUid,
      'updatedAt': now,
      'updatedByUid': _myUid,
      'updatedByName': _myName,
    });
  }

  Future<void> _restoreEntry(_DiaryRow row) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _entriesRef.child(row.id).update({
      'archivedAt': null,
      'archivedByUid': null,
      'updatedAt': now,
      'updatedByUid': _myUid,
      'updatedByName': _myName,
    });
  }

  Future<void> _deletePermanently(_DiaryRow row) async {
    final textController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This cannot be undone.'),
            const SizedBox(height: 8),
            const Text('Type DELETE to confirm.'),
            const SizedBox(height: 8),
            TextField(
              controller: textController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'DELETE',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              final token = textController.text.trim().toUpperCase();
              if (token != 'DELETE') return;
              Navigator.pop(context, true);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _entriesRef.child(row.id).remove();
  }

  Future<void> _archiveSelected(Map<String, _DiaryRow> byId) async {
    final rows = _selectedEntryIds
        .map((id) => byId[id])
        .whereType<_DiaryRow>()
        .where((row) => row.entry.archivedAtMs <= 0)
        .toList();
    if (rows.isEmpty) {
      AppToast.show(context, 'No active entries selected.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Archive selected entries?'),
        content: Text(
          'Archive ${rows.length} selected entr${rows.length == 1 ? 'y' : 'ies'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in rows) {
        await _entriesRef.child(row.id).update({
          'archivedAt': now,
          'archivedByUid': _myUid,
          'updatedAt': now,
          'updatedByUid': _myUid,
          'updatedByName': _myName,
        });
      }
      if (!mounted) return;
      setState(() => _selectedEntryIds.clear());
      AppToast.show(context, 'Archived ${rows.length} entries.');
    } catch (e) {
      await _toastError(e, fallback: 'Could not archive selected entries.');
    }
  }

  Future<void> _deleteSelectedPermanently(Map<String, _DiaryRow> byId) async {
    final rows = _selectedEntryIds
        .map((id) => byId[id])
        .whereType<_DiaryRow>()
        .where((row) => row.entry.archivedAtMs > 0)
        .toList();
    if (rows.isEmpty) {
      AppToast.show(context, 'No archived entries selected.');
      return;
    }
    final textController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete selected permanently?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete ${rows.length} archived entr${rows.length == 1 ? 'y' : 'ies'} permanently.',
            ),
            const SizedBox(height: 8),
            const Text('Type DELETE to confirm.'),
            const SizedBox(height: 8),
            TextField(
              controller: textController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'DELETE',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              if (textController.text.trim().toUpperCase() != 'DELETE') return;
              Navigator.pop(context, true);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      for (final row in rows) {
        await _entriesRef.child(row.id).remove();
      }
      if (!mounted) return;
      setState(() => _selectedEntryIds.clear());
      AppToast.show(context, 'Deleted ${rows.length} archived entries.');
    } catch (e) {
      await _toastError(e, fallback: 'Could not delete selected entries.');
    }
  }

  String _fmtDateTime(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _fmtDay(String dateKey) {
    final parts = dateKey.split('-');
    if (parts.length != 3) return dateKey;
    return '${parts[2]}/${parts[1]}/${parts[0]}';
  }

  Future<void> _openComposeDialog({_DiaryRow? editing}) async {
    final c = TextEditingController(text: editing?.entry.text ?? '');
    bool pinned = editing?.entry.isPinned ?? false;
    String followUpStatus = editing?.entry.followUpStatus ?? 'none';
    int followUpAt = editing?.entry.followUpAtMs ?? 0;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(editing == null ? 'Add Diary Entry' : 'Edit Diary Entry'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: c,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Write what happened in the office...',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Checkbox(
                        value: pinned,
                        onChanged: (v) => setLocal(() => pinned = v ?? false),
                      ),
                      const Text('Pinned entry'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: followUpStatus,
                    decoration: const InputDecoration(
                      labelText: 'Follow-up status',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'none', child: Text('None')),
                      DropdownMenuItem(value: 'open', child: Text('Open')),
                      DropdownMenuItem(value: 'done', child: Text('Done')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setLocal(() {
                        followUpStatus = v;
                        if (followUpStatus != 'open') followUpAt = 0;
                      });
                    },
                  ),
                  if (followUpStatus == 'open') ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            followUpAt > 0
                                ? 'Due: ${_fmtDateTime(followUpAt)}'
                                : 'No due date set',
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            final now = DateTime.now();
                            final picked = await showDatePicker(
                              context: context,
                              firstDate: DateTime(now.year - 1),
                              lastDate: DateTime(now.year + 3),
                              initialDate: now,
                            );
                            if (picked == null) return;
                            if (!context.mounted) return;
                            final t = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay.now(),
                            );
                            if (t == null) return;
                            final due = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              t.hour,
                              t.minute,
                            ).millisecondsSinceEpoch;
                            setLocal(() => followUpAt = due);
                          },
                          child: const Text('Set due'),
                        ),
                        if (followUpAt > 0)
                          TextButton(
                            onPressed: () => setLocal(() => followUpAt = 0),
                            child: const Text('Clear'),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    final text = c.text.trim();
    if (ok != true) return;
    if (text.isEmpty) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Please enter diary text.',
        type: AppToastType.error,
      );
      return;
    }

    try {
      if (editing == null) {
        await _createEntry(
          text: text,
          isPinned: pinned,
          followUpStatus: followUpStatus,
          followUpAt: followUpAt,
        );
        if (!mounted) return;
        AppToast.show(context, 'Diary entry added.');
      } else {
        await _editEntry(
          editing,
          text: text,
          isPinned: pinned,
          followUpStatus: followUpStatus,
          followUpAt: followUpAt,
        );
        if (!mounted) return;
        AppToast.show(context, 'Diary entry updated.');
      }
    } catch (e) {
      await _toastError(e, fallback: 'Could not save diary entry.');
    }
  }

  List<_DiaryRow> _parseRows(dynamic value) {
    if (value is! Map) return <_DiaryRow>[];
    final out = <_DiaryRow>[];
    value.forEach((k, raw) {
      if (k == null || raw is! Map) return;
      final m = raw.map((kk, vv) => MapEntry(kk.toString(), vv));
      out.add(_DiaryRow(id: k.toString(), entry: _DiaryEntry.fromMap(m)));
    });
    out.sort((a, b) => b.entry.createdAtMs.compareTo(a.entry.createdAtMs));
    return out;
  }

  List<_DiaryRow> _filteredRows(List<_DiaryRow> rows) {
    final q = _query.trim().toLowerCase();
    return rows.where((row) {
      final e = row.entry;
      final archived = e.archivedAtMs > 0;
      if (_scope == _DiaryScope.active && archived) return false;
      if (_scope == _DiaryScope.archived && !archived) return false;

      if (_actionFilter != _DiaryActionType.all &&
          e.actionType != _actionFilter.name) {
        return false;
      }
      if (_pinnedOnly && !e.isPinned) return false;
      if (_followUpOpenOnly && e.followUpStatus != 'open') return false;
      if (_todayOnly) {
        final day = e.dateKey.isNotEmpty
            ? e.dateKey
            : _dateKeyFromMs(e.createdAtMs);
        if (day != _todayKey()) return false;
      }

      if (q.isEmpty) return true;
      final hay = [
        e.text,
        e.createdByName,
        e.actionType,
        ...e.keywords,
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  Map<String, List<_DiaryRow>> _groupByDay(List<_DiaryRow> rows) {
    final out = <String, List<_DiaryRow>>{};
    for (final row in rows) {
      final day = row.entry.dateKey.isNotEmpty
          ? row.entry.dateKey
          : _dateKeyFromMs(row.entry.createdAtMs);
      (out[day] ??= <_DiaryRow>[]).add(row);
    }
    for (final day in out.keys) {
      out[day]!.sort((a, b) {
        if (a.entry.isPinned != b.entry.isPinned) {
          return a.entry.isPinned ? -1 : 1;
        }
        return b.entry.createdAtMs.compareTo(a.entry.createdAtMs);
      });
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diary')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openComposeDialog,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add'),
      ),
      body: SafeArea(
        top: false,
        child: adminWebBodyFrame(
          context: context,
          maxWidth: 1450,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: StreamBuilder<DatabaseEvent>(
              stream: _entriesRef.onValue,
              builder: (context, snap) {
                final rows = _parseRows(snap.data?.snapshot.value);
                final filtered = _filteredRows(rows);
                final groups = _groupByDay(filtered);
                final days = groups.keys.toList()
                  ..sort((a, b) => b.compareTo(a));
                final selectedCount = _selectedEntryIds.length;
                final rowById = <String, _DiaryRow>{
                  for (final row in filtered) row.id: row,
                };

                return Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.outline.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  onChanged: (v) => setState(() => _query = v),
                                  decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search_rounded),
                                    hintText: 'Search keywords, names, action',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SegmentedButton<_DiaryScope>(
                                segments: const [
                                  ButtonSegment<_DiaryScope>(
                                    value: _DiaryScope.active,
                                    label: Text('Active'),
                                  ),
                                  ButtonSegment<_DiaryScope>(
                                    value: _DiaryScope.archived,
                                    label: Text('Archived'),
                                  ),
                                ],
                                selected: <_DiaryScope>{_scope},
                                onSelectionChanged: (v) {
                                  if (v.isEmpty) return;
                                  setState(() => _scope = v.first);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              DropdownButton<_DiaryActionType>(
                                value: _actionFilter,
                                items: const [
                                  DropdownMenuItem(
                                    value: _DiaryActionType.all,
                                    child: Text('All actions'),
                                  ),
                                  DropdownMenuItem(
                                    value: _DiaryActionType.call,
                                    child: Text('Calls'),
                                  ),
                                  DropdownMenuItem(
                                    value: _DiaryActionType.money,
                                    child: Text('Money'),
                                  ),
                                  DropdownMenuItem(
                                    value: _DiaryActionType.message,
                                    child: Text('Messages'),
                                  ),
                                  DropdownMenuItem(
                                    value: _DiaryActionType.visit,
                                    child: Text('Visits'),
                                  ),
                                  DropdownMenuItem(
                                    value: _DiaryActionType.followUp,
                                    child: Text('Follow-up'),
                                  ),
                                  DropdownMenuItem(
                                    value: _DiaryActionType.other,
                                    child: Text('Other'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v == null) return;
                                  setState(() => _actionFilter = v);
                                },
                              ),
                              FilterChip(
                                selected: _pinnedOnly,
                                label: const Text('Pinned only'),
                                onSelected: (v) =>
                                    setState(() => _pinnedOnly = v),
                              ),
                              FilterChip(
                                selected: _followUpOpenOnly,
                                label: const Text('Follow-up open'),
                                onSelected: (v) =>
                                    setState(() => _followUpOpenOnly = v),
                              ),
                              FilterChip(
                                selected: _todayOnly,
                                label: const Text('Today only'),
                                onSelected: (v) =>
                                    setState(() => _todayOnly = v),
                              ),
                              FilterChip(
                                selected: _selectionMode,
                                label: Text(
                                  _selectionMode
                                      ? 'Selecting ($selectedCount)'
                                      : 'Select entries',
                                ),
                                onSelected: (v) {
                                  setState(() {
                                    _selectionMode = v;
                                    if (!_selectionMode) {
                                      _selectedEntryIds.clear();
                                    }
                                  });
                                },
                              ),
                              if (_selectionMode &&
                                  _scope == _DiaryScope.active)
                                FilledButton.tonalIcon(
                                  onPressed: selectedCount == 0
                                      ? null
                                      : () => _archiveSelected(rowById),
                                  icon: const Icon(Icons.archive_outlined),
                                  label: const Text('Archive selected'),
                                ),
                              if (_selectionMode &&
                                  _scope == _DiaryScope.archived)
                                FilledButton.tonalIcon(
                                  onPressed: selectedCount == 0
                                      ? null
                                      : () =>
                                            _deleteSelectedPermanently(rowById),
                                  icon: const Icon(
                                    Icons.delete_forever_rounded,
                                  ),
                                  label: const Text('Delete selected'),
                                ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _query = '';
                                    _actionFilter = _DiaryActionType.all;
                                    _pinnedOnly = false;
                                    _followUpOpenOnly = false;
                                    _todayOnly = false;
                                    _selectionMode = false;
                                    _selectedEntryIds.clear();
                                  });
                                },
                                child: const Text('Reset filters'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: days.isEmpty
                          ? const Center(
                              child: Text(
                                'No diary entries for current filters.',
                              ),
                            )
                          : ListView.builder(
                              itemCount: days.length,
                              itemBuilder: (context, index) {
                                final day = days[index];
                                final dayRows =
                                    groups[day] ?? const <_DiaryRow>[];
                                final isOpen = _expandedDays.contains(day);
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  child: Column(
                                    children: [
                                      ListTile(
                                        title: Text(_fmtDay(day)),
                                        subtitle: Text(
                                          '${dayRows.length} entries',
                                        ),
                                        trailing: Icon(
                                          isOpen
                                              ? Icons.expand_less_rounded
                                              : Icons.expand_more_rounded,
                                        ),
                                        onTap: () {
                                          setState(() {
                                            if (isOpen) {
                                              _expandedDays.remove(day);
                                            } else {
                                              _expandedDays.add(day);
                                            }
                                          });
                                        },
                                      ),
                                      if (isOpen)
                                        ...dayRows.map(
                                          (row) => _buildEntryTile(
                                            row,
                                            selecting: _selectionMode,
                                          ),
                                        ),
                                    ],
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
        ),
      ),
    );
  }

  Widget _buildEntryTile(_DiaryRow row, {required bool selecting}) {
    final e = row.entry;
    final chips = <Widget>[];
    if (e.isPinned) {
      chips.add(
        _chip('Pinned', const Color(0xFFEF6C00), const Color(0xFFFFF3E0)),
      );
    }
    if (e.followUpStatus == 'open') {
      chips.add(
        _chip(
          'Follow-up open',
          const Color(0xFF1565C0),
          const Color(0xFFE3F2FD),
        ),
      );
    } else if (e.followUpStatus == 'done') {
      chips.add(
        _chip(
          'Follow-up done',
          const Color(0xFF2E7D32),
          const Color(0xFFE8F5E9),
        ),
      );
    }
    if (e.actionType.isNotEmpty) {
      chips.add(
        _chip(e.actionType, const Color(0xFF6A1B9A), const Color(0xFFF3E5F5)),
      );
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      leading: selecting
          ? Checkbox(
              value: _selectedEntryIds.contains(row.id),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedEntryIds.add(row.id);
                  } else {
                    _selectedEntryIds.remove(row.id);
                  }
                });
              },
            )
          : null,
      title: Text(e.text),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text('By ${e.createdByName} • ${_fmtDateTime(e.createdAtMs)}'),
          if (e.followUpStatus == 'open' && e.followUpAtMs > 0)
            Text('Due ${_fmtDateTime(e.followUpAtMs)}'),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: chips),
          ],
        ],
      ),
      trailing: selecting
          ? null
          : PopupMenuButton<String>(
              onSelected: (value) async {
                try {
                  if (value == 'edit') {
                    await _openComposeDialog(editing: row);
                    return;
                  }
                  if (value == 'pin') {
                    await _setPinned(row, !e.isPinned);
                    return;
                  }
                  if (value == 'archive') {
                    await _archiveEntry(row);
                    return;
                  }
                  if (value == 'restore') {
                    await _restoreEntry(row);
                    return;
                  }
                  if (value == 'delete') {
                    await _deletePermanently(row);
                  }
                } catch (err) {
                  await _toastError(err);
                }
              },
              itemBuilder: (_) {
                final isArchived = e.archivedAtMs > 0;
                return [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(
                    value: 'pin',
                    child: Text(e.isPinned ? 'Unpin' : 'Pin'),
                  ),
                  if (!isArchived)
                    const PopupMenuItem(
                      value: 'archive',
                      child: Text('Archive'),
                    ),
                  if (isArchived)
                    const PopupMenuItem(
                      value: 'restore',
                      child: Text('Restore'),
                    ),
                  if (isArchived)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete permanently'),
                    ),
                ];
              },
            ),
    );
  }

  Widget _chip(String text, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _DiaryRow {
  const _DiaryRow({required this.id, required this.entry});

  final String id;
  final _DiaryEntry entry;
}

class _DiaryEntry {
  const _DiaryEntry({
    required this.text,
    required this.dateKey,
    required this.createdAtMs,
    required this.createdByUid,
    required this.createdByName,
    required this.actionType,
    required this.keywords,
    required this.isPinned,
    required this.pinnedAtMs,
    required this.pinnedByUid,
    required this.followUpStatus,
    required this.followUpAtMs,
    required this.archivedAtMs,
  });

  final String text;
  final String dateKey;
  final int createdAtMs;
  final String createdByUid;
  final String createdByName;
  final String actionType;
  final List<String> keywords;
  final bool isPinned;
  final int pinnedAtMs;
  final String pinnedByUid;
  final String followUpStatus;
  final int followUpAtMs;
  final int archivedAtMs;

  factory _DiaryEntry.fromMap(Map<String, dynamic> m) {
    int toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse((v ?? '').toString()) ?? 0;
    }

    String safe(dynamic v) => (v ?? '').toString().trim();

    final kws = <String>[];
    final rawKws = m['keywords'];
    if (rawKws is List) {
      for (final x in rawKws) {
        final s = safe(x);
        if (s.isNotEmpty) kws.add(s);
      }
    }

    return _DiaryEntry(
      text: safe(m['text']),
      dateKey: safe(m['dateKey']),
      createdAtMs: toInt(m['createdAt']),
      createdByUid: safe(m['createdByUid']),
      createdByName: safe(m['createdByName']),
      actionType: safe(m['actionType']),
      keywords: kws,
      isPinned: m['isPinned'] == true,
      pinnedAtMs: toInt(m['pinnedAt']),
      pinnedByUid: safe(m['pinnedByUid']),
      followUpStatus: safe(m['followUpStatus']).isEmpty
          ? 'none'
          : safe(m['followUpStatus']),
      followUpAtMs: toInt(m['followUpAt']),
      archivedAtMs: toInt(m['archivedAt']),
    );
  }
}
