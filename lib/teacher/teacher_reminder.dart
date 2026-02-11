import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Teacher side reminders:
/// - Reads from: /reminders/{teacherUid}
/// - Tap -> expands
///   - on FIRST expand: mark READ (status=read, readAt=ServerValue.timestamp)
/// - Inside expanded:
///   - Image preview if image
///   - Otherwise Open/Download (external browser)
///   - Mark done (status=done, doneAt=timestamp)
///
/// Fixes:
/// - Normalize urls like "//www...." => "https://www...."
/// - Defensive open: try externalApplication then platformDefault, else show dialog with copyable link
class TeacherReminderScreen extends StatefulWidget {
  const TeacherReminderScreen({super.key});

  @override
  State<TeacherReminderScreen> createState() => _TeacherReminderScreenState();
}

class _TeacherReminderScreenState extends State<TeacherReminderScreen> {
  final _db = FirebaseDatabase.instance;

  String? _uid;
  late DatabaseReference _ref;
  Stream<DatabaseEvent>? _stream;

  final Set<String> _expanded = <String>{};
  final Set<String> _markingRead = <String>{};
  final Set<String> _markingDone = <String>{};

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;

    if (_uid != null) {
      _ref = _db.ref('reminders/$_uid');
      _stream = _ref.onValue.asBroadcastStream();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmtDate(int? ms) {
    if (ms == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Color _statusColor(String status) {
    final s = status.toLowerCase().trim();
    if (s == 'done') return Colors.green;
    if (s == 'read') return Colors.orange;
    return Colors.red;
  }

  List<_ReminderRow> _parse(dynamic data) {
    if (data is! Map) return [];
    final out = <_ReminderRow>[];

    data.forEach((k, v) {
      if (k == null || v == null) return;
      if (v is Map) {
        final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
        out.add(_ReminderRow(id: k.toString(), r: _TeacherReminder.fromMap(m)));
      }
    });

    return out;
  }

  Future<void> _markReadIfNeeded(String reminderId, _TeacherReminder r) async {
    final status = r.status.toLowerCase().trim();
    if (status != 'new') return;
    if (_markingRead.contains(reminderId)) return;

    setState(() => _markingRead.add(reminderId));
    try {
      await _ref.child(reminderId).update({
        'status': 'read',
        'readAt': ServerValue.timestamp,
      });
    } catch (e) {
      _snack('Failed to mark read: $e');
    } finally {
      if (mounted) setState(() => _markingRead.remove(reminderId));
    }
  }

  Future<void> _markDone(String reminderId) async {
    if (_markingDone.contains(reminderId)) return;

    setState(() => _markingDone.add(reminderId));
    try {
      await _ref.child(reminderId).update({
        'status': 'done',
        'doneAt': ServerValue.timestamp,
      });
      _snack('Marked done ✅');
    } catch (e) {
      _snack('Failed to mark done: $e');
    } finally {
      if (mounted) setState(() => _markingDone.remove(reminderId));
    }
  }

  // ---- Attachment helpers ----

  String _normalizeUrl(String raw) {
    final u = raw.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('www.')) return 'https://$u';
    return 'https://$u';
  }

  String _extFromNameOrUrl({required String name, required String url}) {
    String s = name.trim();
    if (s.isEmpty) s = url.trim();
    s = s.split('?').first;
    final dot = s.lastIndexOf('.');
    if (dot == -1) return '';
    return s.substring(dot + 1).toLowerCase().trim();
  }

  bool _isImageExt(String ext) => <String>{'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(ext);
  bool _isAudioExt(String ext) => <String>{'mp3', 'wav', 'm4a', 'aac', 'ogg', 'opus'}.contains(ext);

  Future<void> _showOpenLinkDialog(String url) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Open link'),
        content: SelectableText(url),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _openInBrowser(String rawUrl) async {
    final normalized = _normalizeUrl(rawUrl);
    if (normalized.isEmpty) return;

    final uri = Uri.tryParse(normalized);
    if (uri == null) {
      _snack('Invalid url');
      return;
    }

    // 1) external browser (Chrome)
    try {
      final ok1 = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok1) return;
    } catch (_) {}

    // 2) platform default
    try {
      final ok2 = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (ok2) return;
    } catch (e) {
      _snack('Could not open link (plugin error). Showing link…');
      await _showOpenLinkDialog(normalized);
      return;
    }

    // 3) if both returned false
    _snack('Could not open link. Showing link…');
    await _showOpenLinkDialog(normalized);
  }

  Future<void> _showImagePreview(BuildContext context, String url, String title) async {
    final normalized = _normalizeUrl(url);
    if (normalized.isEmpty) return;

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
                  normalized,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Could not load image.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black.withOpacity(0.7), fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => _openInBrowser(normalized),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open in browser (fallback)'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          normalized,
                          style: TextStyle(color: Colors.black.withOpacity(0.55), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _openInBrowser(normalized),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in browser'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_uid == null) {
      return const Scaffold(
        body: SafeArea(child: Center(child: Text('Not logged in'))),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My reminders')),
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
            final ad = a.r.dueAtMs ?? (1 << 62);
            final bd = b.r.dueAtMs ?? (1 << 62);
            final c = ad.compareTo(bd);
            if (c != 0) return c;
            return (b.r.createdAtMs ?? 0).compareTo(a.r.createdAtMs ?? 0);
          });

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final row = rows[i];
              final r = row.r;
              final isExpanded = _expanded.contains(row.id);

              final rawUrl = (r.attachmentUrl ?? '').trim();
              final rawName = (r.attachmentName ?? '').trim();
              final normalizedUrl = _normalizeUrl(rawUrl);

              final ext = _extFromNameOrUrl(name: rawName, url: normalizedUrl);
              final hasAttachment = normalizedUrl.isNotEmpty;

              final isImage = hasAttachment && _isImageExt(ext);
              final isAudio = hasAttachment && _isAudioExt(ext);

              return Card(
                child: InkWell(
                  onTap: () async {
                    setState(() {
                      if (isExpanded) {
                        _expanded.remove(row.id);
                      } else {
                        _expanded.add(row.id);
                      }
                    });

                    if (!isExpanded) {
                      await _markReadIfNeeded(row.id, r);
                    }
                  },
                  child: Column(
                    children: [
                      ListTile(
                        leading: CircleAvatar(backgroundColor: _statusColor(r.status), radius: 10),
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
                                'Attachment: ${rawName.isNotEmpty ? rawName : 'file'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                        trailing: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                      ),
                      if (isExpanded)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Divider(height: 18),
                              if (r.description.trim().isNotEmpty)
                                Text(r.description)
                              else
                                Text('No description', style: TextStyle(color: Colors.black.withOpacity(0.6))),
                              const SizedBox(height: 12),

                              if (hasAttachment) ...[
                                Row(
                                  children: [
                                    const Icon(Icons.attach_file, size: 18),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        rawName.isNotEmpty ? rawName : 'Attachment',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w800),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                if (isImage)
                                  InkWell(
                                    onTap: () => _showImagePreview(context, normalizedUrl, rawName),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: AspectRatio(
                                        aspectRatio: 16 / 9,
                                        child: Image.network(
                                          normalizedUrl,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => Container(
                                            alignment: Alignment.center,
                                            color: Colors.black.withOpacity(0.05),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Text('Image preview failed'),
                                                const SizedBox(height: 8),
                                                FilledButton.icon(
                                                  onPressed: () => _openInBrowser(normalizedUrl),
                                                  icon: const Icon(Icons.open_in_new),
                                                  label: const Text('Open in browser'),
                                                ),
                                              ],
                                            ),
                                          ),
                                          loadingBuilder: (context, child, loadingProgress) {
                                            if (loadingProgress == null) return child;
                                            return Container(
                                              alignment: Alignment.center,
                                              color: Colors.black.withOpacity(0.03),
                                              child: const CircularProgressIndicator(),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  )
                                else if (isAudio)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: () => _openInBrowser(normalizedUrl),
                                          icon: const Icon(Icons.play_arrow),
                                          label: const Text('Play'),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: FilledButton.icon(
                                          onPressed: () => _openInBrowser(normalizedUrl),
                                          icon: const Icon(Icons.download),
                                          label: const Text('Open / Download'),
                                        ),
                                      ),
                                    ],
                                  )
                                else
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: () => _openInBrowser(normalizedUrl),
                                      icon: const Icon(Icons.open_in_new),
                                      label: const Text('Open / Download'),
                                    ),
                                  ),

                                const SizedBox(height: 8),
                                SelectableText(
                                  normalizedUrl,
                                  style: TextStyle(fontSize: 12, color: Colors.black.withOpacity(0.55)),
                                ),
                                const SizedBox(height: 12),
                              ],

                              Text(
                                'Status: ${r.status.toUpperCase()}'
                                    '${r.readAtMs != null ? ' • Read: ${_fmtDate(r.readAtMs)}' : ''}'
                                    '${r.doneAtMs != null ? ' • Done: ${_fmtDate(r.doneAtMs)}' : ''}',
                                style: TextStyle(color: Colors.black.withOpacity(0.65), fontSize: 12),
                              ),

                              const SizedBox(height: 12),

                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: (r.status.toLowerCase().trim() == 'done' || _markingDone.contains(row.id))
                                      ? null
                                      : () => _markDone(row.id),
                                  icon: _markingDone.contains(row.id)
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.check_circle),
                                  label: Text(
                                    r.status.toLowerCase().trim() == 'done'
                                        ? 'Done'
                                        : _markingDone.contains(row.id)
                                        ? 'Marking…'
                                        : 'Mark done',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ReminderRow {
  _ReminderRow({required this.id, required this.r});
  final String id;
  final _TeacherReminder r;
}

class _TeacherReminder {
  _TeacherReminder({
    required this.title,
    required this.description,
    required this.dueAtMs,
    required this.createdAtMs,
    required this.status,
    required this.readAtMs,
    required this.doneAtMs,
    required this.attachmentUrl,
    required this.attachmentName,
  });

  final String title;
  final String description;
  final int? dueAtMs;
  final int? createdAtMs;

  final String status; // new | read | done
  final int? readAtMs;
  final int? doneAtMs;

  final String? attachmentUrl;
  final String? attachmentName;

  factory _TeacherReminder.fromMap(Map<String, dynamic> m) {
    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return _TeacherReminder(
      title: (m['title'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      dueAtMs: parseInt(m['dueAt']),
      createdAtMs: parseInt(m['createdAt']),
      status: (m['status'] ?? 'new').toString(),
      readAtMs: parseInt(m['readAt']),
      doneAtMs: parseInt(m['doneAt']),
      attachmentUrl: (m['attachment_url'] ?? '').toString(),
      attachmentName: (m['attachment_name'] ?? '').toString(),
    );
  }
}
