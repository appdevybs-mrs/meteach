import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/push_dispatch_service.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';

class AdminPriorityAlertsScreen extends StatefulWidget {
  const AdminPriorityAlertsScreen({super.key});

  @override
  State<AdminPriorityAlertsScreen> createState() =>
      _AdminPriorityAlertsScreenState();
}

enum _SeenFilter { all, unseen, seen }

enum _RoleFilter { all, learner, teacher, admin }

enum _ArchiveScope { active, archived, all }

class _AdminPriorityAlertsScreenState extends State<AdminPriorityAlertsScreen> {
  final FirebaseDatabase _db = FirebaseDatabase.instance;

  String _search = '';
  String _selectedTopicKey = '';
  _ArchiveScope _archiveScope = _ArchiveScope.active;
  _SeenFilter _seenFilter = _SeenFilter.all;
  _RoleFilter _roleFilter = _RoleFilter.all;

  Stream<DatabaseEvent>? _alertsStream;

  String _myUid = '';
  String _myName = 'Admin';

  @override
  void initState() {
    super.initState();
    _myUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    _alertsStream = _db.ref('flash_messages').onValue;
    _loadMyName();
  }

  Future<void> _loadMyName() async {
    if (_myUid.isEmpty) return;
    try {
      final snap = await _db.ref('users/$_myUid').get();
      final v = snap.value;
      if (v is! Map) return;
      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      if (!mounted) return;
      setState(() {
        _myName = full.isNotEmpty ? full : (email.isNotEmpty ? email : 'Admin');
      });
    } catch (_) {}
  }

  String _normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if ({
      'admin',
      'adin',
      'admn',
      'adm',
      'administrator',
      'administration',
    }.contains(s)) {
      return 'admin';
    }
    if ({
      'teacher',
      'teachers',
      'teacher(s)',
      'teach',
      'instructor',
      'prof',
    }.contains(s)) {
      return 'teacher';
    }
    if ({
      'learner',
      'learners',
      'learner(s)',
      'student',
      'pupil',
      'lerner',
    }.contains(s)) {
      return 'learner';
    }
    return '';
  }

  String _roleLabel(String role) {
    if (role == 'teacher') return 'Teacher';
    if (role == 'admin') return 'Admin';
    return 'Learner';
  }

  String _formatDateTime(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _toast(String message, {AppToastType type = AppToastType.info}) {
    if (!mounted) return;
    AppToast.show(context, message, type: type);
  }

  List<_RecipientLite> _parseRecipients(dynamic rawUsers) {
    if (rawUsers is! Map) return <_RecipientLite>[];
    final out = <_RecipientLite>[];

    rawUsers.forEach((k, v) {
      if (k == null || v == null || v is! Map) return;
      final uid = k.toString().trim();
      if (uid.isEmpty) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      final role = _normalizeRole(m['role']);
      if (role.isEmpty) return;

      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      final serial = (m['serial'] ?? '').toString().trim();
      final status = (m['status'] ?? 'active').toString().trim();
      final learnerAssignment = _learnerAssignmentLabel(m);

      out.add(
        _RecipientLite(
          uid: uid,
          role: role,
          name: full.isNotEmpty ? full : (email.isNotEmpty ? email : uid),
          email: email,
          serial: serial,
          status: status,
          learnerAssignment: learnerAssignment,
        ),
      );
    });

    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  String _learnerAssignmentLabel(Map<String, dynamic> userMap) {
    final courses = userMap['courses'];
    if (courses is! Map) return '';

    final classLabels = <String>[];
    final courseLabels = <String>[];

    courses.forEach((_, rawCourse) {
      if (rawCourse is! Map) return;
      final course = rawCourse.map((k, v) => MapEntry(k.toString(), v));

      final courseTitle = (course['title'] ?? course['name'] ?? '')
          .toString()
          .trim();
      final courseLevel = (course['level'] ?? '').toString().trim();
      final classMap = course['class'];

      if (classMap is Map) {
        final linkedClass = classMap.map((k, v) => MapEntry(k.toString(), v));
        final classTitle = (linkedClass['course_title'] ?? '')
            .toString()
            .trim();
        final classLevel = (linkedClass['course_level'] ?? '')
            .toString()
            .trim();
        final classLabel = _joinDisplayParts(classLevel, classTitle);
        if (classLabel.isNotEmpty && !classLabels.contains(classLabel)) {
          classLabels.add(classLabel);
        }
      }

      final courseLabel = _joinDisplayParts(courseLevel, courseTitle);
      if (courseLabel.isNotEmpty && !courseLabels.contains(courseLabel)) {
        courseLabels.add(courseLabel);
      }
    });

    if (classLabels.isNotEmpty) {
      final first = classLabels.first;
      final extra = classLabels.length - 1;
      return extra > 0 ? 'Class: $first +$extra more' : 'Class: $first';
    }

    if (courseLabels.isNotEmpty) {
      final first = courseLabels.first;
      final extra = courseLabels.length - 1;
      return extra > 0 ? 'Course: $first +$extra more' : 'Course: $first';
    }

    return '';
  }

  String _joinDisplayParts(String first, String second) {
    final a = first.trim();
    final b = second.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a $b';
  }

  String _topicLabel(String title) {
    final trimmed = title.trim();
    return trimmed.isEmpty ? '(No title)' : trimmed;
  }

  String _topicKey(String title) => _topicLabel(title).toLowerCase();

  bool _isArchived(_FlashAlert alert) => alert.archivedAtMs > 0;

  bool _scopeMatches(_FlashAlert alert) {
    final archived = _isArchived(alert);
    return switch (_archiveScope) {
      _ArchiveScope.active => !archived,
      _ArchiveScope.archived => archived,
      _ArchiveScope.all => true,
    };
  }

  List<_FlashAlertRow> _scopedRows(List<_FlashAlertRow> rows) {
    return rows.where((row) => _scopeMatches(row.alert)).toList();
  }

  List<_TopicSummary> _buildTopicSummaries(List<_FlashAlertRow> rows) {
    final byTopic = <String, _TopicSummaryBuilder>{};

    for (final row in rows) {
      final alert = row.alert;
      final key = _topicKey(alert.title);
      final label = _topicLabel(alert.title);
      final seen = alert.seenAtMs > 0 || alert.status == 'seen';
      final summary = byTopic.putIfAbsent(
        key,
        () => _TopicSummaryBuilder(label: label, key: key),
      );
      summary.total += 1;
      if (seen) {
        summary.seen += 1;
      } else {
        summary.unseen += 1;
      }
      if (alert.createdAtMs > summary.latestCreatedAtMs) {
        summary.latestCreatedAtMs = alert.createdAtMs;
      }
    }

    final topics = byTopic.values.map((summary) => summary.build()).toList();
    topics.sort((a, b) {
      final byDate = b.latestCreatedAtMs.compareTo(a.latestCreatedAtMs);
      if (byDate != 0) return byDate;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return topics;
  }

  List<_FlashAlertRow> _parseAlerts(dynamic raw) {
    if (raw is! Map) return <_FlashAlertRow>[];
    final out = <_FlashAlertRow>[];

    raw.forEach((targetUid, node) {
      if (targetUid == null || node == null || node is! Map) return;
      final alertsMap = Map<dynamic, dynamic>.from(node);
      alertsMap.forEach((alertId, value) {
        if (alertId == null || value == null || value is! Map) return;
        final m = value.map((k, v) => MapEntry(k.toString(), v));
        out.add(
          _FlashAlertRow(
            targetUid: targetUid.toString(),
            alertId: alertId.toString(),
            alert: _FlashAlert.fromMap(m),
          ),
        );
      });
    });

    out.sort((a, b) => b.alert.createdAtMs.compareTo(a.alert.createdAtMs));
    return out;
  }

  bool _matches(_FlashAlertRow row) {
    final alert = row.alert;
    final search = _search.trim().toLowerCase();
    final topicPass =
        _selectedTopicKey.isEmpty ||
        _topicKey(alert.title) == _selectedTopicKey;

    final seen = alert.seenAtMs > 0 || alert.status == 'seen';
    final seenPass = switch (_seenFilter) {
      _SeenFilter.all => true,
      _SeenFilter.unseen => !seen,
      _SeenFilter.seen => seen,
    };

    final rolePass = switch (_roleFilter) {
      _RoleFilter.all => true,
      _RoleFilter.learner => alert.targetRole == 'learner',
      _RoleFilter.teacher => alert.targetRole == 'teacher',
      _RoleFilter.admin => alert.targetRole == 'admin',
    };

    if (!_scopeMatches(alert) || !topicPass || !seenPass || !rolePass) {
      return false;
    }
    if (search.isEmpty) return true;

    final blob = [
      alert.title,
      alert.message,
      alert.targetName,
      alert.targetEmail,
      alert.targetRole,
    ].join(' ').toLowerCase();
    return blob.contains(search);
  }

  Future<void> _createAlert({
    required _RecipientLite target,
    required _AlertDraft draft,
    String resentFromId = '',
  }) async {
    final ref = _db.ref('flash_messages/${target.uid}').push();
    await ref.set({
      'title': draft.title,
      'message': draft.message,
      'tone': draft.tone,
      'status': 'new',
      'createdAt': ServerValue.timestamp,
      'seenAt': null,
      'resentFromId': resentFromId,
      'targetUid': target.uid,
      'targetRole': target.role,
      'targetName': target.name,
      'targetEmail': target.email,
      'createdByUid': _myUid,
      'createdByName': _myName,
    });

    try {
      await PushDispatchService.dispatchToUser(
        intent: PushIntent.flashMessage,
        targetUid: target.uid,
        title: 'Priority alert',
        message: draft.title,
        context: const PushDispatchContext(
          screen: 'admin/admin_priority_alerts',
          action: 'priority_alert_push',
        ),
        eventParts: ['flash', target.uid, ref.key ?? ''],
        data: {'targetUid': target.uid, 'alertId': ref.key ?? ''},
        route: 'flash_messages',
      );
    } catch (_) {}
  }

  Future<void> _openSendFlow(List<_RecipientLite> recipients) async {
    final picked = await showDialog<List<_RecipientLite>>(
      context: context,
      builder: (_) => _RecipientPickerDialog(recipients: recipients),
    );
    if (picked == null || picked.isEmpty) return;

    if (!mounted) return;
    final draft = await showDialog<_AlertDraft>(
      context: context,
      builder: (_) => _ComposeAlertDialog(selectedCount: picked.length),
    );
    if (draft == null) return;

    int ok = 0;

    if (picked.length > 1) {
      await ProgressDialog.run(
        context,
        message: 'Sending priority alerts...',
        total: picked.length,
        task: (reportProgress) async {
          for (int i = 0; i < picked.length; i++) {
            final target = picked[i];
            try {
              await _createAlert(target: target, draft: draft);
              ok += 1;
            } catch (e) {
              _toast(
                toHumanError(e, fallback: 'Could not send to ${target.name}.'),
                type: AppToastType.error,
              );
            }
            reportProgress(i + 1);
          }
        },
      );
    } else {
      for (final target in picked) {
        try {
          await _createAlert(target: target, draft: draft);
          ok += 1;
        } catch (e) {
          _toast(
            toHumanError(e, fallback: 'Could not send to ${target.name}.'),
            type: AppToastType.error,
          );
        }
      }
    }

    if (ok > 0) {
      _toast('Sent $ok priority alert${ok == 1 ? '' : 's'} successfully.');
    }
  }

  Future<void> _resend(_FlashAlertRow row) async {
    final a = row.alert;
    final target = _RecipientLite(
      uid: row.targetUid,
      role: a.targetRole,
      name: a.targetName,
      email: a.targetEmail,
      serial: '',
      status: 'active',
      learnerAssignment: '',
    );
    final draft = _AlertDraft(title: a.title, message: a.message, tone: a.tone);

    try {
      await _createAlert(
        target: target,
        draft: draft,
        resentFromId: row.alertId,
      );
      _toast(
        'Alert resent to ${a.targetName.isEmpty ? 'user' : a.targetName}.',
      );
    } catch (e) {
      _toast(
        toHumanError(e, fallback: 'Could not resend this alert.'),
        type: AppToastType.error,
      );
    }
  }

  Future<void> _delete(_FlashAlertRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete alert?'),
        content: const Text('This removes the alert from history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await _db.ref('flash_messages/${row.targetUid}/${row.alertId}').remove();
      _toast('Alert deleted.');
    } catch (e) {
      _toast(
        toHumanError(e, fallback: 'Could not delete alert.'),
        type: AppToastType.error,
      );
    }
  }

  Future<void> _archiveRows(List<_FlashAlertRow> rows) async {
    if (rows.isEmpty) {
      _toast('No alerts selected for archive.');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Archive alerts?'),
        content: Text(
          'Archive ${rows.length} filtered alert${rows.length == 1 ? '' : 's'}?',
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
      for (final row in rows) {
        await _db.ref('flash_messages/${row.targetUid}/${row.alertId}').update({
          'archivedAt': ServerValue.timestamp,
          'archivedByUid': _myUid,
        });
      }
      _toast('Archived ${rows.length} alert${rows.length == 1 ? '' : 's'}.');
    } catch (e) {
      _toast(
        toHumanError(e, fallback: 'Could not archive filtered alerts.'),
        type: AppToastType.error,
      );
    }
  }

  Future<void> _deleteRows(List<_FlashAlertRow> rows) async {
    if (rows.isEmpty) {
      _toast('No archived alerts selected for deletion.');
      return;
    }

    final archivedRows = rows.where((row) => _isArchived(row.alert)).toList();
    if (archivedRows.isEmpty) {
      _toast('Only archived alerts can be bulk deleted.');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete archived alerts?'),
        content: Text(
          'Delete ${archivedRows.length} archived alert${archivedRows.length == 1 ? '' : 's'} permanently?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      for (final row in archivedRows) {
        await _db
            .ref('flash_messages/${row.targetUid}/${row.alertId}')
            .remove();
      }
      _toast(
        'Deleted ${archivedRows.length} archived alert${archivedRows.length == 1 ? '' : 's'}.',
      );
    } catch (e) {
      _toast(
        toHumanError(e, fallback: 'Could not delete archived alerts.'),
        type: AppToastType.error,
      );
    }
  }

  Future<void> _archiveSeenOlderThan(
    List<_FlashAlertRow> rows,
    int days,
  ) async {
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    final targets = rows.where((row) {
      final alert = row.alert;
      final seen = alert.seenAtMs > 0 || alert.status == 'seen';
      return !_isArchived(alert) &&
          seen &&
          alert.createdAtMs > 0 &&
          alert.createdAtMs < cutoff;
    }).toList();
    await _archiveRows(targets);
  }

  Future<void> _handleBulkAction(
    String action,
    List<_FlashAlertRow> rows,
  ) async {
    if (action == 'archive_filtered') {
      await _archiveRows(rows.where((row) => !_isArchived(row.alert)).toList());
      return;
    }
    if (action == 'archive_seen_30') {
      await _archiveSeenOlderThan(rows, 30);
      return;
    }
    if (action == 'delete_archived_filtered') {
      await _deleteRows(rows);
    }
  }

  Widget _topFilters(List<_TopicSummary> topics) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              hintText: 'Search recipient, title, or message…',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: const Color(0xFFF4F7F9),
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
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ChoiceChip(
                  label: const Text('Active'),
                  selected: _archiveScope == _ArchiveScope.active,
                  onSelected: (_) =>
                      setState(() => _archiveScope = _ArchiveScope.active),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Archived'),
                  selected: _archiveScope == _ArchiveScope.archived,
                  onSelected: (_) =>
                      setState(() => _archiveScope = _ArchiveScope.archived),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('All records'),
                  selected: _archiveScope == _ArchiveScope.all,
                  onSelected: (_) =>
                      setState(() => _archiveScope = _ArchiveScope.all),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ChoiceChip(
                  label: const Text('Any topic'),
                  selected: _selectedTopicKey.isEmpty,
                  onSelected: (_) => setState(() => _selectedTopicKey = ''),
                ),
                for (final topic in topics) ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(topic.label),
                    selected: _selectedTopicKey == topic.key,
                    onSelected: (_) =>
                        setState(() => _selectedTopicKey = topic.key),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _seenFilter == _SeenFilter.all,
                  onSelected: (_) =>
                      setState(() => _seenFilter = _SeenFilter.all),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Unseen'),
                  selected: _seenFilter == _SeenFilter.unseen,
                  onSelected: (_) =>
                      setState(() => _seenFilter = _SeenFilter.unseen),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Seen'),
                  selected: _seenFilter == _SeenFilter.seen,
                  onSelected: (_) =>
                      setState(() => _seenFilter = _SeenFilter.seen),
                ),
                const SizedBox(width: 16),
                ChoiceChip(
                  label: const Text('Any role'),
                  selected: _roleFilter == _RoleFilter.all,
                  onSelected: (_) =>
                      setState(() => _roleFilter = _RoleFilter.all),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Learners'),
                  selected: _roleFilter == _RoleFilter.learner,
                  onSelected: (_) =>
                      setState(() => _roleFilter = _RoleFilter.learner),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Teachers'),
                  selected: _roleFilter == _RoleFilter.teacher,
                  onSelected: (_) =>
                      setState(() => _roleFilter = _RoleFilter.teacher),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Admins'),
                  selected: _roleFilter == _RoleFilter.admin,
                  onSelected: (_) =>
                      setState(() => _roleFilter = _RoleFilter.admin),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopicSummary(List<_TopicSummary> topics) {
    if (topics.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 132,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: topics.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final topic = topics[i];
          final selected = _selectedTopicKey == topic.key;
          return SizedBox(
            width: 220,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                setState(() {
                  _selectedTopicKey = selected ? '' : topic.key;
                });
              },
              child: Ink(
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFFFFF3E0)
                      : const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFFE67E22)
                        : const Color(0xFFE3E7ED),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        topic.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Recipients ${topic.total}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Seen ${topic.seen} • Unseen ${topic.unseen}',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.66),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Latest ${_formatDateTime(topic.latestCreatedAtMs)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.54),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(List<_FlashAlertRow> rows) {
    final scoped = _scopedRows(rows);
    final topics = _buildTopicSummaries(scoped);
    final filtered = scoped.where(_matches).toList();
    return Column(
      children: [
        _buildTopicSummary(topics),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No priority alerts found.'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final row = filtered[i];
                    final a = row.alert;
                    final seen = a.seenAtMs > 0 || a.status == 'seen';
                    final preview = a.message.trim();

                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 11,
                          backgroundColor: seen
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFFC62828),
                        ),
                        title: Text(
                          _topicLabel(a.title),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 6),
                            Text(
                              '${_roleLabel(a.targetRole)}: ${a.targetName.isEmpty ? row.targetUid : a.targetName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (preview.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 6),
                            Text('Sent: ${_formatDateTime(a.createdAtMs)}'),
                            if (_isArchived(a))
                              Text(
                                'Archived: ${_formatDateTime(a.archivedAtMs)}',
                              ),
                            Text(
                              seen
                                  ? 'Seen: ${_formatDateTime(a.seenAtMs)}'
                                  : 'Seen: Not yet',
                            ),
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'resend') {
                              await _resend(row);
                            }
                            if (v == 'archive') {
                              await _archiveRows([row]);
                            }
                            if (v == 'delete') {
                              await _delete(row);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'resend',
                              child: Text('Resend'),
                            ),
                            if (!_isArchived(a))
                              const PopupMenuItem(
                                value: 'archive',
                                child: Text('Archive'),
                              ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
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
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: _db.ref('users').onValue,
      builder: (context, userSnap) {
        final recipients = _parseRecipients(userSnap.data?.snapshot.value);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Priority Alerts'),
            actions: [
              IconButton(
                tooltip: 'Send alert',
                onPressed: recipients.isEmpty
                    ? null
                    : () => _openSendFlow(recipients),
                icon: const Icon(Icons.add_alert_rounded),
              ),
            ],
          ),
          body: adminWebBodyFrame(
            context: context,
            maxWidth: 1500,
            child: StreamBuilder<DatabaseEvent>(
              stream: _alertsStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text('Could not load priority alerts.'),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final rows = _parseAlerts(snap.data?.snapshot.value);
                final scoped = _scopedRows(rows);
                final topics = _buildTopicSummaries(scoped);
                if (_selectedTopicKey.isNotEmpty &&
                    !topics.any((topic) => topic.key == _selectedTopicKey)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    setState(() => _selectedTopicKey = '');
                  });
                }

                return Column(
                  children: [
                    _topFilters(topics),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: PopupMenuButton<String>(
                          tooltip: 'Bulk actions',
                          onSelected: (value) => _handleBulkAction(
                            value,
                            scoped.where(_matches).toList(),
                          ),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'archive_filtered',
                              child: Text('Archive filtered'),
                            ),
                            PopupMenuItem(
                              value: 'archive_seen_30',
                              child: Text('Archive seen older than 30d'),
                            ),
                            PopupMenuItem(
                              value: 'delete_archived_filtered',
                              child: Text('Delete archived filtered'),
                            ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF4F7F9),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFE3E7ED),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.tune_rounded, size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'Bulk actions',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _buildList(rows)),
                  ],
                );
              },
            ),
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: 'Send alert',
            onPressed: recipients.isEmpty
                ? null
                : () => _openSendFlow(recipients),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}

class _RecipientLite {
  const _RecipientLite({
    required this.uid,
    required this.role,
    required this.name,
    required this.email,
    required this.serial,
    required this.status,
    required this.learnerAssignment,
  });

  final String uid;
  final String role;
  final String name;
  final String email;
  final String serial;
  final String status;
  final String learnerAssignment;
}

class _AlertDraft {
  const _AlertDraft({
    required this.title,
    required this.message,
    required this.tone,
  });

  final String title;
  final String message;
  final String tone;

  static String normalizeTone(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if (s == 'info') return 'info';
    if (s == 'critical') return 'critical';
    return 'warning';
  }
}

class _FlashAlertRow {
  const _FlashAlertRow({
    required this.targetUid,
    required this.alertId,
    required this.alert,
  });

  final String targetUid;
  final String alertId;
  final _FlashAlert alert;
}

class _FlashAlert {
  const _FlashAlert({
    required this.title,
    required this.message,
    required this.tone,
    required this.status,
    required this.createdAtMs,
    required this.seenAtMs,
    required this.archivedAtMs,
    required this.targetRole,
    required this.targetName,
    required this.targetEmail,
  });

  final String title;
  final String message;
  final String tone;
  final String status;
  final int createdAtMs;
  final int seenAtMs;
  final int archivedAtMs;
  final String targetRole;
  final String targetName;
  final String targetEmail;

  static int _parseInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    if ({
      'admin',
      'adin',
      'admn',
      'adm',
      'administrator',
      'administration',
    }.contains(s)) {
      return 'admin';
    }
    if ({
      'teacher',
      'teachers',
      'teacher(s)',
      'teach',
      'instructor',
      'prof',
    }.contains(s)) {
      return 'teacher';
    }
    return 'learner';
  }

  factory _FlashAlert.fromMap(Map<String, dynamic> m) {
    return _FlashAlert(
      title: (m['title'] ?? '').toString().trim(),
      message: (m['message'] ?? '').toString().trim(),
      tone: _AlertDraft.normalizeTone(m['tone']),
      status: (m['status'] ?? 'new').toString().trim().toLowerCase(),
      createdAtMs: _parseInt(m['createdAt']),
      seenAtMs: _parseInt(m['seenAt']),
      archivedAtMs: _parseInt(m['archivedAt']),
      targetRole: _normalizeRole(m['targetRole']),
      targetName: (m['targetName'] ?? '').toString().trim(),
      targetEmail: (m['targetEmail'] ?? '').toString().trim(),
    );
  }
}

class _TopicSummaryBuilder {
  _TopicSummaryBuilder({required this.label, required this.key});

  final String label;
  final String key;
  int total = 0;
  int seen = 0;
  int unseen = 0;
  int latestCreatedAtMs = 0;

  _TopicSummary build() => _TopicSummary(
    label: label,
    key: key,
    total: total,
    seen: seen,
    unseen: unseen,
    latestCreatedAtMs: latestCreatedAtMs,
  );
}

class _TopicSummary {
  const _TopicSummary({
    required this.label,
    required this.key,
    required this.total,
    required this.seen,
    required this.unseen,
    required this.latestCreatedAtMs,
  });

  final String label;
  final String key;
  final int total;
  final int seen;
  final int unseen;
  final int latestCreatedAtMs;
}

class _RecipientPickerDialog extends StatefulWidget {
  const _RecipientPickerDialog({required this.recipients});

  final List<_RecipientLite> recipients;

  @override
  State<_RecipientPickerDialog> createState() => _RecipientPickerDialogState();
}

class _RecipientPickerDialogState extends State<_RecipientPickerDialog> {
  final Set<String> _selected = <String>{};
  String _search = '';
  _RoleFilter _roleFilter = _RoleFilter.all;

  List<_RecipientLite> get _filtered {
    final s = _search.trim().toLowerCase();
    return widget.recipients.where((r) {
      final rolePass = switch (_roleFilter) {
        _RoleFilter.all => true,
        _RoleFilter.learner => r.role == 'learner',
        _RoleFilter.teacher => r.role == 'teacher',
        _RoleFilter.admin => r.role == 'admin',
      };
      if (!rolePass) return false;

      if (s.isEmpty) return true;
      return [
        r.name,
        r.email,
        r.serial,
        r.uid,
        r.status,
      ].join(' ').toLowerCase().contains(s);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return AlertDialog(
      title: const Text('Select recipients'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search users…',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFFF4F7F9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _roleFilter == _RoleFilter.all,
                    onSelected: (_) =>
                        setState(() => _roleFilter = _RoleFilter.all),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Learners'),
                    selected: _roleFilter == _RoleFilter.learner,
                    onSelected: (_) =>
                        setState(() => _roleFilter = _RoleFilter.learner),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Teachers'),
                    selected: _roleFilter == _RoleFilter.teacher,
                    onSelected: (_) =>
                        setState(() => _roleFilter = _RoleFilter.teacher),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Admins'),
                    selected: _roleFilter == _RoleFilter.admin,
                    onSelected: (_) =>
                        setState(() => _roleFilter = _RoleFilter.admin),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Selected: ${_selected.length}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const Spacer(),
                TextButton(
                  onPressed: filtered.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _selected.addAll(filtered.map((e) => e.uid));
                          });
                        },
                  child: const Text('Select filtered'),
                ),
                TextButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => setState(_selected.clear),
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Flexible(
              child: filtered.isEmpty
                  ? const Center(child: Text('No users found.'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final r = filtered[i];
                        final subtitle = r.role == 'learner'
                            ? (r.learnerAssignment.isNotEmpty
                                  ? r.learnerAssignment
                                  : '${r.role.toUpperCase()}${r.email.isEmpty ? '' : ' • ${r.email}'}')
                            : '${r.role.toUpperCase()}${r.email.isEmpty ? '' : ' • ${r.email}'}';
                        return CheckboxListTile(
                          value: _selected.contains(r.uid),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(r.uid);
                              } else {
                                _selected.remove(r.uid);
                              }
                            });
                          },
                          title: Text(
                            r.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () {
                  final picked = widget.recipients
                      .where((r) => _selected.contains(r.uid))
                      .toList();
                  Navigator.pop(context, picked);
                },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _ComposeAlertDialog extends StatefulWidget {
  const _ComposeAlertDialog({required this.selectedCount});

  final int selectedCount;

  @override
  State<_ComposeAlertDialog> createState() => _ComposeAlertDialogState();
}

class _ComposeAlertDialogState extends State<_ComposeAlertDialog> {
  final _formKey = GlobalKey<FormState>();
  final titleC = TextEditingController();
  final messageC = TextEditingController();
  String _tone = 'warning';

  @override
  void dispose() {
    titleC.dispose();
    messageC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Send priority alert'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: titleC,
                  decoration: const InputDecoration(labelText: 'Title *'),
                  maxLength: 140,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Title is required.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: messageC,
                  decoration: const InputDecoration(labelText: 'Message *'),
                  maxLines: 6,
                  maxLength: 3000,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Message is required.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Tone',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.black.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Info'),
                        selected: _tone == 'info',
                        onSelected: (_) => setState(() => _tone = 'info'),
                      ),
                      ChoiceChip(
                        label: const Text('Warning'),
                        selected: _tone == 'warning',
                        onSelected: (_) => setState(() => _tone = 'warning'),
                      ),
                      ChoiceChip(
                        label: const Text('Critical'),
                        selected: _tone == 'critical',
                        onSelected: (_) => setState(() => _tone = 'critical'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Recipients: ${widget.selectedCount}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.black.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ],
            ),
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
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              _AlertDraft(
                title: titleC.text.trim(),
                message: messageC.text.trim(),
                tone: _tone,
              ),
            );
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}
