import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../services/push_client.dart';

class AdminTeacherRemindersScreen extends StatefulWidget {
  const AdminTeacherRemindersScreen({
    super.key,
    required this.teacherUid,
    required this.teacher,
  });

  final String teacherUid;
  final dynamic teacher;

  @override
  State<AdminTeacherRemindersScreen> createState() => _AdminTeacherRemindersScreenState();
}

class _AdminTeacherRemindersScreenState extends State<AdminTeacherRemindersScreen> {
  final _db = FirebaseDatabase.instance;


  Future<String?> _getTeacherFcmToken() async {
    final snap = await FirebaseDatabase.instance
        .ref('fcm_tokens/${widget.teacherUid}/token')
        .get();

    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }


  DatabaseReference get _remindersRef => _db.ref('reminders/${widget.teacherUid}');
  late final Stream<DatabaseEvent> _stream;

  /// store expanded cards (collapse/expand)
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _stream = _remindersRef.onValue.asBroadcastStream();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- URL helpers (FIX for "//domain/..." urls) ----

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

  bool _isImageExt(String ext) => {
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'bmp',
  }.contains(ext);

  bool _isAudioExt(String ext) => {
    'mp3',
    'wav',
    'm4a',
    'aac',
    'ogg',
    'opus',
  }.contains(ext);

  Future<void> _openUrlExternal(String rawUrl) async {
    final url = _normalizeUrl(rawUrl);
    final u = Uri.tryParse(url);
    if (u == null) {
      _snack('Invalid URL');
      return;
    }
    try {
      final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
      if (!ok) _snack('Could not open link');
    } catch (e) {
      _snack('Could not open link: $e');
    }
  }

  Future<void> _openAddDialog() async {
    final created = await showDialog<_TeacherReminderDraft?>(
      context: context,
      builder: (_) => _AddReminderDialog(teacher: widget.teacher),
    );

    if (created == null) return;

    try {
      final newRef = _remindersRef.push();

      await newRef.set({
        'title': created.title.trim(),
        'description': created.description.trim(),
        'dueAt': created.dueAtMs,
        'attachment_url': created.attachmentUrl?.trim() ?? '',
        'attachment_name': created.attachmentName?.trim() ?? '',
        'createdAt': ServerValue.timestamp,

        // status tracking (teacher updates)
        'status': 'new', // new | read | done
        'readAt': null,
        'doneAt': null,

        // teacher snapshot inside reminder
        'teacher': {
          'uid': widget.teacherUid,
          'name': (created.teacherName ?? '').trim(),
          'email': (created.teacherEmail ?? '').trim(),
          'serial': (created.teacherSerial ?? '').trim(),
          'role': (created.teacherRole ?? '').trim(),
          'phone1': (created.teacherPhone1 ?? '').trim(),
          'phone2': (created.teacherPhone2 ?? '').trim(),
        },
      });
// ✅ Send push notification to teacher
      try {
        final token = await _getTeacherFcmToken();
        if (token == null) {
          _snack('Reminder saved ✅ but teacher has no FCM token');
        } else {
          await PushClient.sendToToken(
            token: token,
            title: created.title.trim(),
            message: created.description.trim().isEmpty
                ? 'You have a new reminder'
                : created.description.trim(),
            data: {
              'type': 'reminder',
              'route': 'teacher_reminders', // we will use this when handling tap
              'teacherUid': widget.teacherUid,
            },
          );
        }
      } catch (e) {
        _snack('Reminder saved ✅ but push failed: $e');
      }

      _snack('Reminder added ✅');
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  List<_TeacherReminderRow> _parse(dynamic data) {
    if (data is! Map) return [];
    final out = <_TeacherReminderRow>[];
    data.forEach((k, v) {
      if (k == null || v == null) return;
      if (v is Map) {
        final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
        out.add(_TeacherReminderRow(
          id: k.toString(),
          reminder: TeacherReminder.fromMap(m),
        ));
      }
    });
    return out;
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
                border: Border(bottom: BorderSide(color: Colors.black.withOpacity(0.08))),
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
                          style: TextStyle(color: Colors.black.withOpacity(0.7), fontWeight: FontWeight.w700),
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
          style: TextStyle(color: Colors.black.withOpacity(0.55), fontSize: 12),
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
            style: TextStyle(color: Colors.black.withOpacity(0.65), fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (teacherLine.isNotEmpty)
            Text(
              teacherLine,
              style: TextStyle(color: Colors.black.withOpacity(0.65), fontSize: 12),
            ),
          if (r.teacherEmail.trim().isNotEmpty || phones.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [
                r.teacherEmail.trim().isEmpty ? null : r.teacherEmail.trim(),
                phones.isEmpty ? null : 'Phones: $phones',
              ].whereType<String>().join(' • '),
              style: TextStyle(color: Colors.black.withOpacity(0.65), fontSize: 12),
            ),
          ],
          _attachmentSection(r),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final teacherName = (widget.teacher?.fullName ?? '').toString().trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(teacherName.isEmpty ? 'Teacher reminders' : 'Reminders — $teacherName'),
        actions: [
          IconButton(
            tooltip: 'Add reminder',
            onPressed: _openAddDialog,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return const Center(child: Text('Could not load reminders.'));
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snap.data?.snapshot.value;
          final rows = _parse(data);

          if (rows.isEmpty) return const Center(child: Text('No reminders yet.'));

          rows.sort((a, b) {
            final ad = a.reminder.dueAtMs ?? (1 << 62);
            final bd = b.reminder.dueAtMs ?? (1 << 62);
            final c = ad.compareTo(bd);
            if (c != 0) return c;
            return (b.reminder.createdAtMs ?? 0).compareTo(a.reminder.createdAtMs ?? 0);
          });

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final row = rows[i];
              final r = row.reminder;

              final isExpanded = _expanded.contains(row.id);
              final hasAttachment = _normalizeUrl((r.attachmentUrl ?? '').trim()).isNotEmpty;

              return Card(
                child: InkWell(
                  onTap: () {
                    setState(() {
                      if (isExpanded) {
                        _expanded.remove(row.id);
                      } else {
                        _expanded.add(row.id);
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
                            Text('Due: ${_fmtDate(r.dueAtMs)}'),
                            if (!isExpanded && r.description.trim().isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(r.description, maxLines: 2, overflow: TextOverflow.ellipsis),
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
                                  await _remindersRef.child(row.id).remove();
                                  _snack('Deleted ✅');
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'delete', child: Text('Delete')),
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
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _TeacherReminderRow {
  _TeacherReminderRow({required this.id, required this.reminder});
  final String id;
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

  final String status; // new | read | done
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

/// ----------------------------
/// Add dialog
/// ----------------------------
class _AddReminderDialog extends StatefulWidget {
  const _AddReminderDialog({required this.teacher});

  final dynamic teacher;

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final teacherName = (widget.teacher?.fullName ?? '').toString().trim();
    final teacherEmail = (widget.teacher?.email ?? '').toString().trim();
    final teacherSerial = (widget.teacher?.serial ?? '').toString().trim();
    final teacherRole = (widget.teacher?.role?.value ?? widget.teacher?.role ?? '').toString().trim();
    final teacherPhone1 = (widget.teacher?.phone1 ?? '').toString().trim();
    final teacherPhone2 = (widget.teacher?.phone2 ?? '').toString().trim();

    String dueLabel() {
      if (_due == null) return 'No due date';
      return '${_due!.year}-${_due!.month.toString().padLeft(2, '0')}-${_due!.day.toString().padLeft(2, '0')}';
    }

    return AlertDialog(
      title: const Text('Add reminder'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: titleC,
                decoration: const InputDecoration(labelText: 'Title *'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                      _attachmentName.trim().isEmpty ? 'No file' : _attachmentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _uploading ? null : _pickAndUploadFile,
                    icon: _uploading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
              if (teacherName.isNotEmpty || teacherEmail.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Teacher: ${teacherName.isEmpty ? '(no name)' : teacherName}'
                        '${teacherEmail.isEmpty ? '' : ' — $teacherEmail'}',
                    style: TextStyle(fontSize: 12, color: Colors.black.withOpacity(0.6)),
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
                attachmentUrl: _attachmentUrl.trim().isEmpty ? null : _attachmentUrl.trim(),
                attachmentName: _attachmentName.trim().isEmpty ? null : _attachmentName.trim(),
                teacherName: teacherName,
                teacherEmail: teacherEmail,
                teacherSerial: teacherSerial,
                teacherRole: teacherRole,
                teacherPhone1: teacherPhone1,
                teacherPhone2: teacherPhone2,
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// ----------------------------
/// Upload client
/// ----------------------------
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
