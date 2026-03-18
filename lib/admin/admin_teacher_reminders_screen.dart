import 'dart:convert';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/push_client.dart';

class AdminTeacherRemindersScreen extends StatefulWidget {
  const AdminTeacherRemindersScreen({
    super.key,
    this.teacherUid,
    this.teacher,
  });

  final String? teacherUid;
  final dynamic teacher;

  @override
  State<AdminTeacherRemindersScreen> createState() =>
      _AdminTeacherRemindersScreenState();
}

class _AdminTeacherRemindersScreenState
    extends State<AdminTeacherRemindersScreen> {
  final _db = FirebaseDatabase.instance;

  bool get _isSingleTeacherMode =>
      widget.teacherUid != null && widget.teacherUid!.trim().isNotEmpty;

  DatabaseReference get _usersRef => _db.ref('users');

  DatabaseReference get _singleTeacherRemindersRef =>
      _db.ref('reminders/${widget.teacherUid!.trim()}');

  DatabaseReference get _allRemindersRef => _db.ref('reminders');

  late final Stream<DatabaseEvent> _usersStream;
  Stream<DatabaseEvent>? _singleTeacherRemindersStream;
  late final Stream<DatabaseEvent> _allRemindersStream;

  final Set<String> _expanded = <String>{};

  String _search = '';
  _ReminderStatusFilter _statusFilter = _ReminderStatusFilter.all;

  @override
  void initState() {
    super.initState();
    _usersStream = _usersRef.onValue.asBroadcastStream();
    _allRemindersStream = _allRemindersRef.onValue.asBroadcastStream();

    if (_isSingleTeacherMode) {
      _singleTeacherRemindersStream =
          _singleTeacherRemindersRef.onValue.asBroadcastStream();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String?> _getTeacherFcmToken(String teacherUid) async {
    final snap = await _db.ref('fcm_tokens/$teacherUid/token').get();
    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  String _normalizeUrl(String raw) {
    final u = raw.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('www.')) return 'https://$u';
    return 'https://$u';
  }

  String _lowerExt(String nameOrUrl) {
    final s = nameOrUrl.trim().split('?').first;
    final dot = s.lastIndexOf('.');
    if (dot == -1) return '';
    return s.substring(dot + 1).toLowerCase().trim();
  }

  bool _isImageExt(String ext) =>
      {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'}.contains(ext);

  bool _isAudioExt(String ext) =>
      {'mp3', 'wav', 'm4a', 'aac', 'ogg', 'opus'}.contains(ext);

  Future<void> _openUrlExternal(String rawUrl) async {
    final url = _normalizeUrl(rawUrl);
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _snack('Invalid URL');
      return;
    }

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _snack('Could not open link');
    } catch (e) {
      _snack('Could not open link: $e');
    }
  }

  int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  List<_TeacherTarget> _parseTeachers(dynamic data) {
    if (data is! Map) return [];

    final out = <_TeacherTarget>[];

    data.forEach((k, v) {
      if (k == null || v == null || v is! Map) return;

      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      final role = (m['role'] ?? '').toString().toLowerCase().trim();

      if (role != 'teacher') return;

      final uid = k.toString().trim();
      if (uid.isEmpty) return;

      final firstName =
      (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final lastName =
      (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final fullName = ('$firstName $lastName').trim();

      out.add(
        _TeacherTarget(
          uid: uid,
          fullName: fullName,
          email: (m['email'] ?? '').toString().trim(),
          serial: (m['serial'] ?? '').toString().trim(),
          role: role,
          status: (m['status'] ?? 'active').toString().trim(),
          phone1: (m['phone1'] ?? '').toString().trim(),
          phone2: (m['phone2'] ?? '').toString().trim(),
          updatedAtMs: _parseInt(m['updatedAt']),
        ),
      );
    });

    out.sort((a, b) {
      final bt = b.updatedAtMs ?? 0;
      final at = a.updatedAtMs ?? 0;
      final c = bt.compareTo(at);
      if (c != 0) return c;
      return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
    });

    return out;
  }

  List<_ReminderRow> _parseSingleTeacherReminders(dynamic data) {
    if (data is! Map) return [];

    final out = <_ReminderRow>[];

    data.forEach((k, v) {
      if (k == null || v == null || v is! Map) return;

      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));

      out.add(
        _ReminderRow(
          teacherUid: widget.teacherUid!.trim(),
          reminderId: k.toString(),
          reminder: TeacherReminder.fromMap(m),
        ),
      );
    });

    return out;
  }

  List<_ReminderRow> _parseAllReminders(dynamic data) {
    if (data is! Map) return [];

    final out = <_ReminderRow>[];

    data.forEach((teacherUid, teacherNode) {
      if (teacherUid == null || teacherNode == null || teacherNode is! Map) {
        return;
      }

      final remindersMap = Map<dynamic, dynamic>.from(teacherNode);

      remindersMap.forEach((reminderId, reminderVal) {
        if (reminderId == null || reminderVal == null || reminderVal is! Map) {
          return;
        }

        final m = reminderVal.map((k, v) => MapEntry(k.toString(), v));

        out.add(
          _ReminderRow(
            teacherUid: teacherUid.toString(),
            reminderId: reminderId.toString(),
            reminder: TeacherReminder.fromMap(m),
          ),
        );
      });
    });

    return out;
  }

  List<_ReminderRow> _applyReminderFilters(List<_ReminderRow> rows) {
    final s = _search.trim().toLowerCase();

    return rows.where((row) {
      final r = row.reminder;

      final matchesSearch = s.isEmpty
          ? true
          : r.title.toLowerCase().contains(s) ||
          r.description.toLowerCase().contains(s) ||
          r.teacherName.toLowerCase().contains(s) ||
          r.teacherEmail.toLowerCase().contains(s) ||
          r.teacherSerial.toLowerCase().contains(s);

      final status = r.status.toLowerCase().trim();

      final matchesStatus = switch (_statusFilter) {
        _ReminderStatusFilter.all => true,
        _ReminderStatusFilter.newOnly => status == 'new',
        _ReminderStatusFilter.readOnly => status == 'read',
        _ReminderStatusFilter.doneOnly => status == 'done',
      };

      return matchesSearch && matchesStatus;
    }).toList();
  }

  Future<void> _saveReminderForTeacher({
    required String teacherUid,
    required _TeacherReminderDraft created,
  }) async {
    final ref = _db.ref('reminders/$teacherUid').push();

    await ref.set({
      'title': created.title.trim(),
      'description': created.description.trim(),
      'dueAt': created.dueAtMs,
      'attachment_url': created.attachmentUrl?.trim() ?? '',
      'attachment_name': created.attachmentName?.trim() ?? '',
      'createdAt': ServerValue.timestamp,
      'status': 'new',
      'readAt': null,
      'doneAt': null,
      'teacher': {
        'uid': teacherUid,
        'name': (created.teacherName ?? '').trim(),
        'email': (created.teacherEmail ?? '').trim(),
        'serial': (created.teacherSerial ?? '').trim(),
        'role': (created.teacherRole ?? '').trim(),
        'phone1': (created.teacherPhone1 ?? '').trim(),
        'phone2': (created.teacherPhone2 ?? '').trim(),
      },
    });

    try {
      final token = await _getTeacherFcmToken(teacherUid);
      if (token == null) return;

      await PushClient.sendToToken(
        token: token,
        title: created.title.trim(),
        message: created.description.trim().isEmpty
            ? 'You have a new reminder'
            : created.description.trim(),
        data: {
          'type': 'reminder',
          'route': 'teacher_reminders',
          'teacherUid': teacherUid,
        },
      );
    } catch (_) {
      // Reminder already saved. Ignore push failure here.
    }
  }

  Future<void> _openAddDialog() async {
    if (_isSingleTeacherMode) {
      final created = await showDialog<_TeacherReminderDraft?>(
        context: context,
        builder: (_) => _AddReminderDialog(teacher: widget.teacher),
      );

      if (created == null) return;

      try {
        await _saveReminderForTeacher(
          teacherUid: widget.teacherUid!.trim(),
          created: created,
        );

        final token = await _getTeacherFcmToken(widget.teacherUid!.trim());
        if (token == null) {
          _snack('Reminder saved ✅ but teacher has no FCM token');
        } else {
          _snack('Reminder added ✅');
        }
      } catch (e) {
        _snack('Failed: $e');
      }

      return;
    }

    final teachersSnap = await _usersRef.get();
    final teachers = _parseTeachers(teachersSnap.value);

    if (!mounted) return;

    if (teachers.isEmpty) {
      _snack('No teachers found.');
      return;
    }

    final selectedTeachers = await showDialog<List<_TeacherTarget>>(
      context: context,
      builder: (_) => _TeacherPickerDialog(teachers: teachers),
    );

    if (selectedTeachers == null || selectedTeachers.isEmpty) {
      return;
    }

    final created = await showDialog<_TeacherReminderDraft?>(
      context: context,
      builder: (_) => _AddReminderDialog.mass(
        selectedCount: selectedTeachers.length,
      ),
    );

    if (created == null) return;

    int successCount = 0;
    int failedCount = 0;
    int noPushCount = 0;

    for (final teacher in selectedTeachers) {
      try {
        final token = await _getTeacherFcmToken(teacher.uid);

        await _saveReminderForTeacher(
          teacherUid: teacher.uid,
          created: _TeacherReminderDraft(
            title: created.title,
            description: created.description,
            dueAtMs: created.dueAtMs,
            attachmentUrl: created.attachmentUrl,
            attachmentName: created.attachmentName,
            teacherName: teacher.fullName,
            teacherEmail: teacher.email,
            teacherSerial: teacher.serial,
            teacherRole: teacher.role,
            teacherPhone1: teacher.phone1,
            teacherPhone2: teacher.phone2,
          ),
        );

        if (token == null) noPushCount++;
        successCount++;
      } catch (_) {
        failedCount++;
      }
    }

    if (failedCount == 0) {
      if (noPushCount > 0) {
        _snack(
          'Reminder sent to $successCount teacher(s) ✅ '
              '($noPushCount without push token)',
        );
      } else {
        _snack('Reminder sent to $successCount teacher(s) ✅');
      }
    } else {
      _snack(
        'Done: $successCount sent, $failedCount failed'
            '${noPushCount > 0 ? ' ($noPushCount without push token)' : ''}',
      );
    }
  }

  Future<void> _deleteReminder(_ReminderRow row) async {
    try {
      await _db
          .ref('reminders/${row.teacherUid}/${row.reminderId}')
          .remove();
      _snack('Deleted ✅');
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Color _statusColor(TeacherReminder r) {
    final s = r.status.toLowerCase().trim();
    if (s == 'done') return Colors.green;
    if (s == 'read') return Colors.orange;
    return Colors.red;
  }

  String _fmtDate(int? ms) {
    if (ms == null) return 'No due date';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _showImageDialog({
    required String title,
    required String rawUrl,
  }) async {
    final url = _normalizeUrl(rawUrl);
    if (url.isEmpty) {
      _snack('No URL');
      return;
    }

    await showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.black.withOpacity(0.08)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title.isEmpty ? 'Image' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open in browser',
                    onPressed: () => _openUrlExternal(url),
                    icon: const Icon(Icons.open_in_new),
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
              child: InteractiveViewer(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Could not load image.',
                          style: TextStyle(
                            color: Colors.black.withOpacity(0.7),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => _openUrlExternal(url),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open in browser (fallback)'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _attachmentSection(TeacherReminder r) {
    final rawUrl = (r.attachmentUrl ?? '').trim();
    final rawName = (r.attachmentName ?? '').trim();

    final url = _normalizeUrl(rawUrl);
    if (url.isEmpty) return const SizedBox.shrink();

    final ext = _lowerExt(rawName.isNotEmpty ? rawName : url);
    final isImg = _isImageExt(ext);
    final isAudio = _isAudioExt(ext);

    final label = rawName.isNotEmpty ? rawName : 'Attachment';
    final typeLabel = ext.isEmpty ? 'FILE' : ext.toUpperCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Text(
          'Attachment: $label',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text(typeLabel)),
            if (isImg)
              FilledButton.icon(
                onPressed: () => _showImageDialog(title: label, rawUrl: url),
                icon: const Icon(Icons.visibility),
                label: const Text('View'),
              )
            else if (isAudio)
              FilledButton.icon(
                onPressed: () => _openUrlExternal(url),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play'),
              )
            else
              FilledButton.icon(
                onPressed: () => _openUrlExternal(url),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open'),
              ),
            OutlinedButton.icon(
              onPressed: () => _openUrlExternal(url),
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          url,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.black.withOpacity(0.55),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _expandedBody(TeacherReminder r) {
    final teacherLine = [
      r.teacherName.trim().isEmpty ? null : r.teacherName.trim(),
      r.teacherSerial.trim().isEmpty ? null : 'Serial: ${r.teacherSerial.trim()}',
      r.teacherRole.trim().isEmpty ? null : 'Role: ${r.teacherRole.trim()}',
    ].whereType<String>().join(' • ');

    final phones = [
      r.teacherPhone1.trim().isEmpty ? null : r.teacherPhone1.trim(),
      r.teacherPhone2.trim().isEmpty ? null : r.teacherPhone2.trim(),
    ].whereType<String>().join(' / ');

    final statusLine = [
      'Status: ${r.status.toUpperCase()}',
      if (r.readAtMs != null) 'Read: ${_fmtDate(r.readAtMs)}',
      if (r.doneAtMs != null) 'Done: ${_fmtDate(r.doneAtMs)}',
    ].join(' • ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 18),
          if (r.description.trim().isNotEmpty) ...[
            Text(r.description),
            const SizedBox(height: 10),
          ],
          Text(
            statusLine,
            style: TextStyle(
              color: Colors.black.withOpacity(0.65),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          if (teacherLine.isNotEmpty)
            Text(
              teacherLine,
              style: TextStyle(
                color: Colors.black.withOpacity(0.65),
                fontSize: 12,
              ),
            ),
          if (r.teacherEmail.trim().isNotEmpty || phones.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [
                r.teacherEmail.trim().isEmpty ? null : r.teacherEmail.trim(),
                phones.isEmpty ? null : 'Phones: $phones',
              ].whereType<String>().join(' • '),
              style: TextStyle(
                color: Colors.black.withOpacity(0.65),
                fontSize: 12,
              ),
            ),
          ],
          _attachmentSection(r),
        ],
      ),
    );
  }

  Widget _topFilters() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              hintText: _isSingleTeacherMode
                  ? 'Search reminders…'
                  : 'Search reminders or teachers…',
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
                  label: const Text('All'),
                  selected: _statusFilter == _ReminderStatusFilter.all,
                  onSelected: (_) {
                    setState(() => _statusFilter = _ReminderStatusFilter.all);
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('New'),
                  selected: _statusFilter == _ReminderStatusFilter.newOnly,
                  onSelected: (_) {
                    setState(
                          () => _statusFilter = _ReminderStatusFilter.newOnly,
                    );
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Read'),
                  selected: _statusFilter == _ReminderStatusFilter.readOnly,
                  onSelected: (_) {
                    setState(
                          () => _statusFilter = _ReminderStatusFilter.readOnly,
                    );
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Done'),
                  selected: _statusFilter == _ReminderStatusFilter.doneOnly,
                  onSelected: (_) {
                    setState(
                          () => _statusFilter = _ReminderStatusFilter.doneOnly,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReminderList(List<_ReminderRow> rows) {
    final filtered = _applyReminderFilters(rows);

    if (filtered.isEmpty) {
      return const Center(child: Text('No reminders found.'));
    }

    filtered.sort((a, b) {
      final ad = a.reminder.dueAtMs ?? (1 << 62);
      final bd = b.reminder.dueAtMs ?? (1 << 62);
      final c = ad.compareTo(bd);
      if (c != 0) return c;
      return (b.reminder.createdAtMs ?? 0).compareTo(a.reminder.createdAtMs ?? 0);
    });

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final row = filtered[i];
        final r = row.reminder;

        final expandedKey = '${row.teacherUid}_${row.reminderId}';
        final isExpanded = _expanded.contains(expandedKey);
        final hasAttachment =
            _normalizeUrl((r.attachmentUrl ?? '').trim()).isNotEmpty;

        return Card(
          child: InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expanded.remove(expandedKey);
                } else {
                  _expanded.add(expandedKey);
                }
              });
            },
            child: Column(
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _statusColor(r),
                    radius: 10,
                  ),
                  title: Text(r.title.isEmpty ? '(No title)' : r.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 6),
                      if (!_isSingleTeacherMode)
                        Text(
                          r.teacherName.trim().isEmpty
                              ? '(No teacher name)'
                              : r.teacherName,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      if (!_isSingleTeacherMode &&
                          r.teacherEmail.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          r.teacherEmail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text('Due: ${_fmtDate(r.dueAtMs)}'),
                      if (!isExpanded && r.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          r.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (!isExpanded && hasAttachment) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Attachment: ${r.attachmentName?.trim().isNotEmpty == true ? r.attachmentName : "file"}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                      PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'delete') {
                            await _deleteReminder(row);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isExpanded) _expandedBody(r),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSingleMode() {
    return StreamBuilder<DatabaseEvent>(
      stream: _singleTeacherRemindersStream!,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(child: Text('Could not load reminders.'));
        }
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final rows = _parseSingleTeacherReminders(snap.data?.snapshot.value);

        if (rows.isEmpty) {
          return const Center(child: Text('No reminders yet.'));
        }

        return _buildReminderList(rows);
      },
    );
  }

  Widget _buildAllMode() {
    return StreamBuilder<DatabaseEvent>(
      stream: _allRemindersStream,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(child: Text('Could not load reminders.'));
        }
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final rows = _parseAllReminders(snap.data?.snapshot.value);

        if (rows.isEmpty) {
          return const Center(child: Text('No reminders yet.'));
        }

        return _buildReminderList(rows);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final teacherName = (widget.teacher?.fullName ?? '').toString().trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSingleTeacherMode
              ? (teacherName.isEmpty
              ? 'Teacher reminders'
              : 'Reminders — $teacherName')
              : 'All reminders',
        ),
        actions: [
          IconButton(
            tooltip: _isSingleTeacherMode ? 'Add reminder' : 'Send reminder',
            onPressed: _openAddDialog,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          _topFilters(),
          Expanded(
            child: _isSingleTeacherMode ? _buildSingleMode() : _buildAllMode(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}

enum _ReminderStatusFilter {
  all,
  newOnly,
  readOnly,
  doneOnly,
}

class _TeacherTarget {
  _TeacherTarget({
    required this.uid,
    required this.fullName,
    required this.email,
    required this.serial,
    required this.role,
    required this.status,
    required this.phone1,
    required this.phone2,
    required this.updatedAtMs,
  });

  final String uid;
  final String fullName;
  final String email;
  final String serial;
  final String role;
  final String status;
  final String phone1;
  final String phone2;
  final int? updatedAtMs;
}

class _ReminderRow {
  _ReminderRow({
    required this.teacherUid,
    required this.reminderId,
    required this.reminder,
  });

  final String teacherUid;
  final String reminderId;
  final TeacherReminder reminder;
}

class TeacherReminder {
  TeacherReminder({
    required this.title,
    required this.description,
    required this.dueAtMs,
    required this.attachmentUrl,
    required this.attachmentName,
    required this.createdAtMs,
    required this.status,
    required this.readAtMs,
    required this.doneAtMs,
    required this.teacherUid,
    required this.teacherName,
    required this.teacherEmail,
    required this.teacherSerial,
    required this.teacherRole,
    required this.teacherPhone1,
    required this.teacherPhone2,
  });

  final String title;
  final String description;
  final int? dueAtMs;
  final String? attachmentUrl;
  final String? attachmentName;
  final int? createdAtMs;

  final String status;
  final int? readAtMs;
  final int? doneAtMs;

  final String teacherUid;
  final String teacherName;
  final String teacherEmail;
  final String teacherSerial;
  final String teacherRole;
  final String teacherPhone1;
  final String teacherPhone2;

  factory TeacherReminder.fromMap(Map<String, dynamic> m) {
    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    final teacherMap = (m['teacher'] is Map)
        ? (m['teacher'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    return TeacherReminder(
      title: (m['title'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      dueAtMs: parseInt(m['dueAt']),
      attachmentUrl: (m['attachment_url'] ?? '').toString(),
      attachmentName: (m['attachment_name'] ?? '').toString(),
      createdAtMs: parseInt(m['createdAt']),
      status: (m['status'] ?? 'new').toString(),
      readAtMs: parseInt(m['readAt']),
      doneAtMs: parseInt(m['doneAt']),
      teacherUid: (teacherMap['uid'] ?? '').toString(),
      teacherName: (teacherMap['name'] ?? '').toString(),
      teacherEmail: (teacherMap['email'] ?? '').toString(),
      teacherSerial: (teacherMap['serial'] ?? '').toString(),
      teacherRole: (teacherMap['role'] ?? '').toString(),
      teacherPhone1: (teacherMap['phone1'] ?? '').toString(),
      teacherPhone2: (teacherMap['phone2'] ?? '').toString(),
    );
  }
}

class _TeacherReminderDraft {
  _TeacherReminderDraft({
    required this.title,
    required this.description,
    required this.dueAtMs,
    required this.attachmentUrl,
    required this.attachmentName,
    required this.teacherName,
    required this.teacherEmail,
    required this.teacherSerial,
    required this.teacherRole,
    required this.teacherPhone1,
    required this.teacherPhone2,
  });

  final String title;
  final String description;
  final int? dueAtMs;
  final String? attachmentUrl;
  final String? attachmentName;
  final String? teacherName;
  final String? teacherEmail;
  final String? teacherSerial;
  final String? teacherRole;
  final String? teacherPhone1;
  final String? teacherPhone2;
}

class _TeacherPickerDialog extends StatefulWidget {
  const _TeacherPickerDialog({
    required this.teachers,
  });

  final List<_TeacherTarget> teachers;

  @override
  State<_TeacherPickerDialog> createState() => _TeacherPickerDialogState();
}

class _TeacherPickerDialogState extends State<_TeacherPickerDialog> {
  final Set<String> _selected = <String>{};
  String _search = '';
  _TeacherPickerStatusFilter _statusFilter = _TeacherPickerStatusFilter.all;

  List<_TeacherTarget> get _filtered {
    final s = _search.trim().toLowerCase();

    return widget.teachers.where((t) {
      final matchesSearch = s.isEmpty
          ? true
          : t.fullName.toLowerCase().contains(s) ||
          t.email.toLowerCase().contains(s) ||
          t.serial.toLowerCase().contains(s) ||
          t.phone1.toLowerCase().contains(s) ||
          t.phone2.toLowerCase().contains(s);

      final status = t.status.toLowerCase().trim();
      final matchesStatus = switch (_statusFilter) {
        _TeacherPickerStatusFilter.all => true,
        _TeacherPickerStatusFilter.active => status == 'active',
        _TeacherPickerStatusFilter.paused => status == 'paused',
      };

      return matchesSearch && matchesStatus;
    }).toList();
  }

  void _selectFiltered() {
    setState(() {
      _selected.addAll(_filtered.map((e) => e.uid));
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;

    return AlertDialog(
      title: const Text('Pick teachers'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search teachers…',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFFF4F7F9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
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
                    label: const Text('All'),
                    selected: _statusFilter == _TeacherPickerStatusFilter.all,
                    onSelected: (_) {
                      setState(
                            () => _statusFilter = _TeacherPickerStatusFilter.all,
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Active'),
                    selected:
                    _statusFilter == _TeacherPickerStatusFilter.active,
                    onSelected: (_) {
                      setState(
                            () => _statusFilter = _TeacherPickerStatusFilter.active,
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Paused'),
                    selected:
                    _statusFilter == _TeacherPickerStatusFilter.paused,
                    onSelected: (_) {
                      setState(
                            () => _statusFilter = _TeacherPickerStatusFilter.paused,
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  'Selected: ${_selected.length}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const Spacer(),
                TextButton(
                  onPressed: filtered.isEmpty ? null : _selectFiltered,
                  child: const Text('Select filtered'),
                ),
                TextButton(
                  onPressed: _selected.isEmpty ? null : _clearSelection,
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Flexible(
              child: filtered.isEmpty
                  ? const Center(child: Text('No teachers found.'))
                  : ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final t = filtered[i];
                  final selected = _selected.contains(t.uid);

                  return CheckboxListTile(
                    value: selected,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(t.uid);
                        } else {
                          _selected.remove(t.uid);
                        }
                      });
                    },
                    title: Text(
                      t.fullName.isEmpty ? '(No name)' : t.fullName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (t.email.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            t.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _MiniPill(
                              label:
                              t.status.isEmpty ? 'active' : t.status,
                            ),
                            if (t.serial.isNotEmpty)
                              _MiniPill(label: 'Serial: ${t.serial}'),
                            if (t.phone1.isNotEmpty)
                              _MiniPill(label: t.phone1),
                          ],
                        ),
                      ],
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
            final picked = widget.teachers
                .where((t) => _selected.contains(t.uid))
                .toList();
            Navigator.pop(context, picked);
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

enum _TeacherPickerStatusFilter {
  all,
  active,
  paused,
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _AddReminderDialog extends StatefulWidget {
  const _AddReminderDialog({
    this.teacher,
    this.selectedCount,
  });

  const _AddReminderDialog.mass({
    required int selectedCount,
  })  : teacher = null,
        selectedCount = selectedCount;

  final dynamic teacher;
  final int? selectedCount;

  bool get isMassMode => selectedCount != null;

  @override
  State<_AddReminderDialog> createState() => _AddReminderDialogState();
}

class _AddReminderDialogState extends State<_AddReminderDialog> {
  final _formKey = GlobalKey<FormState>();

  final titleC = TextEditingController();
  final descC = TextEditingController();

  DateTime? _due;
  bool _uploading = false;

  String _attachmentUrl = '';
  String _attachmentName = '';

  @override
  void dispose() {
    titleC.dispose();
    descC.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final initial = _due ?? now;

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: 'Select due date (optional)',
    );

    if (picked == null) return;
    setState(() => _due = picked);
  }

  Future<void> _pickAndUploadFile() async {
    setState(() => _uploading = true);

    try {
      final result = await FilePicker.platform.pickFiles(withData: false);
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      final f = File(file.path!);
      final url = await ReminderUploadClient.defaultClient().uploadFile(file: f);

      if (!mounted) return;

      setState(() {
        _attachmentUrl = url;
        _attachmentName = file.name;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final teacherName = widget.isMassMode
        ? ''
        : (widget.teacher?.fullName ?? '').toString().trim();
    final teacherEmail = widget.isMassMode
        ? ''
        : (widget.teacher?.email ?? '').toString().trim();
    final teacherSerial = widget.isMassMode
        ? ''
        : (widget.teacher?.serial ?? '').toString().trim();
    final teacherRole = widget.isMassMode
        ? ''
        : (widget.teacher?.role?.value ?? widget.teacher?.role ?? '')
        .toString()
        .trim();
    final teacherPhone1 = widget.isMassMode
        ? ''
        : (widget.teacher?.phone1 ?? '').toString().trim();
    final teacherPhone2 = widget.isMassMode
        ? ''
        : (widget.teacher?.phone2 ?? '').toString().trim();

    String dueLabel() {
      if (_due == null) return 'No due date';
      return '${_due!.year}-${_due!.month.toString().padLeft(2, '0')}-${_due!.day.toString().padLeft(2, '0')}';
    }

    return AlertDialog(
      title: Text(widget.isMassMode ? 'Send reminder' : 'Add reminder'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: titleC,
                decoration: const InputDecoration(labelText: 'Title *'),
                validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: descC,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: Text('Due: ${dueLabel()}')),
                  TextButton.icon(
                    onPressed: _pickDue,
                    icon: const Icon(Icons.calendar_month),
                    label: const Text('Pick'),
                  ),
                  if (_due != null)
                    TextButton(
                      onPressed: () => setState(() => _due = null),
                      child: const Text('Clear'),
                    ),
                ],
              ),
              const Divider(height: 18),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Attachment (optional)',
                  style: TextStyle(color: Colors.black.withOpacity(0.7)),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _attachmentName.trim().isEmpty
                          ? 'No file'
                          : _attachmentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _uploading ? null : _pickAndUploadFile,
                    icon: _uploading
                        ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : const Icon(Icons.upload),
                    label: Text(_uploading ? 'Uploading…' : 'Upload'),
                  ),
                  if (_attachmentUrl.trim().isNotEmpty)
                    IconButton(
                      tooltip: 'Remove attachment',
                      onPressed: () => setState(() {
                        _attachmentUrl = '';
                        _attachmentName = '';
                      }),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (widget.isMassMode)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Selected teachers: ${widget.selectedCount}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.black.withOpacity(0.6),
                    ),
                  ),
                )
              else if (teacherName.isNotEmpty || teacherEmail.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Teacher: ${teacherName.isEmpty ? '(no name)' : teacherName}'
                        '${teacherEmail.isEmpty ? '' : ' — $teacherEmail'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.black.withOpacity(0.6),
                    ),
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
            if (!_formKey.currentState!.validate()) return;

            Navigator.pop(
              context,
              _TeacherReminderDraft(
                title: titleC.text,
                description: descC.text,
                dueAtMs: _due?.millisecondsSinceEpoch,
                attachmentUrl:
                _attachmentUrl.trim().isEmpty ? null : _attachmentUrl.trim(),
                attachmentName: _attachmentName.trim().isEmpty
                    ? null
                    : _attachmentName.trim(),
                teacherName: teacherName,
                teacherEmail: teacherEmail,
                teacherSerial: teacherSerial,
                teacherRole: teacherRole,
                teacherPhone1: teacherPhone1,
                teacherPhone2: teacherPhone2,
              ),
            );
          },
          child: Text(widget.isMassMode ? 'Send' : 'Add'),
        ),
      ],
    );
  }
}

class ReminderUploadClient {
  ReminderUploadClient({
    required this.endpoint,
    required this.appId,
    required this.key,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String endpoint;
  final String appId;
  final String key;
  final http.Client _http;

  factory ReminderUploadClient.defaultClient() {
    return ReminderUploadClient(
      endpoint: 'https://www.yourbridgeschool.com/app/upload.php',
      appId: 'dreamenglishacademy',
      key: 'a7a995d9c499128351d827eaad7285bcc891919b',
    );
  }

  Future<String> uploadFile({required File file}) async {
    final uri = Uri.parse(endpoint);

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({'X-Requested-With': 'XMLHttpRequest'})
      ..fields['key'] = key
      ..fields['app_id'] = appId
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('Upload failed: HTTP ${streamed.statusCode}\n$body');
    }

    final decoded = _tryDecodeJson(body);
    if (decoded == null) {
      throw Exception('Upload failed: invalid JSON\n$body');
    }

    final success = decoded['success'] == true;
    final url = (decoded['url'] ?? '').toString();

    if (!success || url.trim().isEmpty) {
      throw Exception('Upload failed: $decoded');
    }

    return url;
  }

  static Map<String, dynamic>? _tryDecodeJson(String s) {
    try {
      return (jsonDecode(s) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}