import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/push_client.dart';
import '../shared/app_theme.dart';
import '../shared/app_feedback.dart';

/// Teacher side reminders:
/// - Reads from: /reminders/{teacherUid}
/// - Tap -> expands
///   - on FIRST expand: mark READ (status=read, readAt=ServerValue.timestamp)
/// - Inside expanded:
///   - Image preview if image
///   - Otherwise Open/Download (external browser)
///   - Mark done (status=done, doneAt=timestamp)
///
/// Also:
/// - After READ/DONE, sends push notification to topic: "admins"
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
  final Set<String> _notifying = <String>{};

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);

    _uid = FirebaseAuth.instance.currentUser?.uid;
    if (_uid != null) {
      _ref = _db.ref('reminders/$_uid');
      _stream = _ref.onValue.asBroadcastStream();
    }
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  void _snack(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, SnackBar(content: Text(msg)));
  }

  String _fmtDate(int? ms) {
    if (ms == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _fmtFullDate(int? ms) {
    if (ms == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} $hh:$mm';
  }

  Color _statusColor(String status) {
    final s = status.toLowerCase().trim();
    if (s == 'done') return const Color(0xFF2E7D32);
    if (s == 'read') return p.accent;
    return const Color(0xFFC62828);
  }

  String _statusLabel(String status) {
    final s = status.toLowerCase().trim();
    if (s == 'done') return 'Done';
    if (s == 'read') return 'Read';
    return 'New';
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

  Future<void> _notifyAdmins({
    required String action,
    required String reminderId,
    required _TeacherReminder r,
  }) async {
    final key = '$action:$reminderId';
    if (_notifying.contains(key)) return;

    _notifying.add(key);
    try {
      final user = FirebaseAuth.instance.currentUser;
      final teacherLabel = (user?.email ?? user?.uid ?? 'Teacher').toString();

      final title = action == 'done' ? 'Reminder done ✅' : 'Reminder opened 👀';
      final message = action == 'done'
          ? '$teacherLabel completed: ${r.title}'
          : '$teacherLabel opened: ${r.title}';

      await PushClient.sendToTopic(
        topic: 'admins',
        title: title,
        message: message,
        data: {
          'type': 'reminder',
          'action': action,
          'reminderId': reminderId,
          'teacherUid': _uid ?? '',
          'title': r.title,
        },
      );
    } catch (e) {
      _snack('Admin notify failed: $e');
    } finally {
      _notifying.remove(key);
    }
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

      await _notifyAdmins(action: 'read', reminderId: reminderId, r: r);
    } catch (e) {
      _snack('Failed to mark read: $e');
    } finally {
      if (mounted) setState(() => _markingRead.remove(reminderId));
    }
  }

  Future<void> _markDone(String reminderId, _TeacherReminder r) async {
    if (_markingDone.contains(reminderId)) return;

    setState(() => _markingDone.add(reminderId));
    try {
      await _ref.child(reminderId).update({
        'status': 'done',
        'doneAt': ServerValue.timestamp,
      });

      _snack('Marked done ✅');
      await _notifyAdmins(action: 'done', reminderId: reminderId, r: r);
    } catch (e) {
      _snack('Failed to mark done: $e');
    } finally {
      if (mounted) setState(() => _markingDone.remove(reminderId));
    }
  }

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

  bool _isImageExt(String ext) {
    return <String>{'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(ext);
  }

  bool _isAudioExt(String ext) {
    return <String>{'mp3', 'wav', 'm4a', 'aac', 'ogg', 'opus'}.contains(ext);
  }

  Future<void> _showOpenLinkDialog(String url) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: p.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'Open link',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: SelectableText(
          url,
          style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Close',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
            ),
          ),
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

    try {
      final ok1 = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok1) return;
    } catch (_) {}

    try {
      final ok2 = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (ok2) return;
    } catch (_) {
      _snack('Could not open link. Showing it instead…');
      await _showOpenLinkDialog(normalized);
      return;
    }

    _snack('Could not open link. Showing it instead…');
    await _showOpenLinkDialog(normalized);
  }

  Future<void> _showImagePreview(
    BuildContext context,
    String url,
    String title,
  ) async {
    final normalized = _normalizeUrl(url);
    if (normalized.isEmpty) return;

    await showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: p.cardBg,
        insetPadding: const EdgeInsets.all(14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: p.border.withValues(alpha: 0.9)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title.isEmpty ? 'Image preview' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: p.primary),
                  ),
                ],
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                child: Image.network(
                  normalized,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Could not load image.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.text.withValues(alpha: 0.75),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => _openInBrowser(normalized),
                            icon: const Icon(Icons.open_in_new_rounded),
                            label: const Text('Open in browser'),
                            style: FilledButton.styleFrom(
                              backgroundColor: p.accent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          normalized,
                          style: TextStyle(
                            color: p.text.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: CircularProgressIndicator(color: p.accent),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _openInBrowser(normalized),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open in browser'),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: p.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: p.soft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.alarm_off_rounded,
                  color: p.primary,
                  size: 30,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'No reminders yet',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'When reminders are assigned to you, they will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.68),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopSummary(List<_ReminderRow> rows) {
    int newCount = 0;
    int readCount = 0;
    int doneCount = 0;

    for (final row in rows) {
      final s = row.r.status.toLowerCase().trim();
      if (s == 'done') {
        doneCount++;
      } else if (s == 'read') {
        readCount++;
      } else {
        newCount++;
      }
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.primary, p.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: p.primary.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reminder Center',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'My Reminders',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 22,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _SummaryMiniCard(label: 'New', value: '$newCount'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SummaryMiniCard(label: 'Read', value: '$readCount'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SummaryMiniCard(label: 'Done', value: '$doneCount'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentSection(
    BuildContext context,
    _TeacherReminder r,
    String normalizedUrl,
    String rawName,
    bool isImage,
    bool isAudio,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.attach_file_rounded, color: p.primary, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  rawName.isNotEmpty ? rawName : 'Attachment',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isImage)
            InkWell(
              onTap: () => _showImagePreview(context, normalizedUrl, rawName),
              borderRadius: BorderRadius.circular(14),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    normalizedUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      alignment: Alignment.center,
                      color: p.cardBg,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Image preview failed',
                            style: TextStyle(
                              color: p.text.withValues(alpha: 0.72),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: () => _openInBrowser(normalizedUrl),
                            icon: const Icon(Icons.open_in_new_rounded),
                            label: const Text('Open in browser'),
                            style: FilledButton.styleFrom(
                              backgroundColor: p.accent,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        alignment: Alignment.center,
                        color: p.cardBg,
                        child: CircularProgressIndicator(color: p.accent),
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
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Play'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.primary,
                      side: BorderSide(color: p.border),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _openInBrowser(normalizedUrl),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Open / Download'),
                    style: FilledButton.styleFrom(
                      backgroundColor: p.accent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openInBrowser(normalizedUrl),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open / Download'),
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          const SizedBox(height: 10),
          SelectableText(
            normalizedUrl,
            style: TextStyle(fontSize: 12, color: p.text.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_uid == null) {
      return Scaffold(
        backgroundColor: p.appBg,
        body: SafeArea(
          child: Center(
            child: Text(
              'Not logged in',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        surfaceTintColor: p.cardBg,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'My Reminders',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Track, open, and complete reminders',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.045,
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.76,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          StreamBuilder<DatabaseEvent>(
            stream: _stream,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    'Could not load reminders.',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
              }

              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return Center(
                  child: CircularProgressIndicator(color: p.accent),
                );
              }

              final data = snap.data?.snapshot.value;
              final rows = _parse(data);

              if (rows.isEmpty) {
                return _buildEmptyState();
              }

              rows.sort((a, b) {
                final ad = a.r.dueAtMs ?? (1 << 62);
                final bd = b.r.dueAtMs ?? (1 << 62);
                final c = ad.compareTo(bd);
                if (c != 0) return c;
                return (b.r.createdAtMs ?? 0).compareTo(a.r.createdAtMs ?? 0);
              });

              return Column(
                children: [
                  _buildTopSummary(rows),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final row = rows[i];
                        final r = row.r;
                        final isExpanded = _expanded.contains(row.id);

                        final rawUrl = (r.attachmentUrl ?? '').trim();
                        final rawName = (r.attachmentName ?? '').trim();
                        final normalizedUrl = _normalizeUrl(rawUrl);

                        final ext = _extFromNameOrUrl(
                          name: rawName,
                          url: normalizedUrl,
                        );
                        final hasAttachment = normalizedUrl.isNotEmpty;

                        final isImage = hasAttachment && _isImageExt(ext);
                        final isAudio = hasAttachment && _isAudioExt(ext);

                        final statusColor = _statusColor(r.status);
                        final statusLabel = _statusLabel(r.status);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: p.cardBg,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.9),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 12,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(22),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(22),
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
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 46,
                                          height: 46,
                                          decoration: BoxDecoration(
                                            color: p.soft,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Center(
                                            child: Container(
                                              width: 14,
                                              height: 14,
                                              decoration: BoxDecoration(
                                                color: statusColor,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      r.title.isEmpty
                                                          ? '(No title)'
                                                          : r.title,
                                                      maxLines: isExpanded
                                                          ? 3
                                                          : 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: p.primary,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                        fontSize: 15,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 10,
                                                          vertical: 6,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: statusColor
                                                          .withValues(alpha: 0.12),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                      border: Border.all(
                                                        color: statusColor
                                                            .withValues(alpha: 0.22),
                                                      ),
                                                    ),
                                                    child: Text(
                                                      statusLabel,
                                                      style: TextStyle(
                                                        color: statusColor,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              Wrap(
                                                spacing: 8,
                                                runSpacing: 8,
                                                children: [
                                                  _ReminderMetaChip(
                                                    palette: p,
                                                    icon: Icons.event_rounded,
                                                    text:
                                                        'Due: ${_fmtDate(r.dueAtMs)}',
                                                  ),
                                                  if (hasAttachment)
                                                    _ReminderMetaChip(
                                                      palette: p,
                                                      icon: isImage
                                                          ? Icons.image_rounded
                                                          : (isAudio
                                                                ? Icons
                                                                      .audiotrack_rounded
                                                                : Icons
                                                                      .attach_file_rounded),
                                                      text: rawName.isNotEmpty
                                                          ? rawName
                                                          : 'Attachment',
                                                    ),
                                                ],
                                              ),
                                              if (!isExpanded &&
                                                  r.description
                                                      .trim()
                                                      .isNotEmpty) ...[
                                                const SizedBox(height: 10),
                                                Text(
                                                  r.description.trim(),
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: p.text.withValues(alpha: 
                                                      0.72,
                                                    ),
                                                    fontWeight: FontWeight.w600,
                                                    height: 1.35,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Icon(
                                          isExpanded
                                              ? Icons.expand_less_rounded
                                              : Icons.expand_more_rounded,
                                          color: p.text.withValues(alpha: 0.45),
                                        ),
                                      ],
                                    ),
                                    if (isExpanded) ...[
                                      Divider(
                                        height: 22,
                                        color: p.border.withValues(alpha: 0.9),
                                      ),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          r.description.trim().isNotEmpty
                                              ? r.description.trim()
                                              : 'No description',
                                          style: TextStyle(
                                            color:
                                                r.description.trim().isNotEmpty
                                                ? p.text
                                                : p.text.withValues(alpha: 0.60),
                                            fontWeight: FontWeight.w600,
                                            height: 1.4,
                                          ),
                                        ),
                                      ),
                                      if (hasAttachment) ...[
                                        const SizedBox(height: 14),
                                        _buildAttachmentSection(
                                          context,
                                          r,
                                          normalizedUrl,
                                          rawName,
                                          isImage,
                                          isAudio,
                                        ),
                                      ],
                                      const SizedBox(height: 14),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: p.soft.withValues(alpha: 0.38),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Reminder details',
                                              style: TextStyle(
                                                color: p.primary,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 13,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              'Status: ${r.status.toUpperCase()}',
                                              style: TextStyle(
                                                color: p.text.withValues(alpha: 0.72),
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Created: ${_fmtFullDate(r.createdAtMs)}',
                                              style: TextStyle(
                                                color: p.text.withValues(alpha: 0.72),
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                            if (r.readAtMs != null) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                'Read: ${_fmtFullDate(r.readAtMs)}',
                                                style: TextStyle(
                                                  color: p.text.withValues(alpha: 
                                                    0.72,
                                                  ),
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                            if (r.doneAtMs != null) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                'Done: ${_fmtFullDate(r.doneAtMs)}',
                                                style: TextStyle(
                                                  color: p.text.withValues(alpha: 
                                                    0.72,
                                                  ),
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      SizedBox(
                                        width: double.infinity,
                                        child: FilledButton.icon(
                                          onPressed:
                                              (r.status.toLowerCase().trim() ==
                                                      'done' ||
                                                  _markingDone.contains(row.id))
                                              ? null
                                              : () => _markDone(row.id, r),
                                          icon: _markingDone.contains(row.id)
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                )
                                              : const Icon(
                                                  Icons.check_circle_rounded,
                                                ),
                                          label: Text(
                                            r.status.toLowerCase().trim() ==
                                                    'done'
                                                ? 'Done'
                                                : _markingDone.contains(row.id)
                                                ? 'Marking…'
                                                : 'Mark done',
                                          ),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: p.accent,
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 14,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                          ),
                                        ),
                                      ),
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
        ],
      ),
    );
  }
}

class _SummaryMiniCard extends StatelessWidget {
  const _SummaryMiniCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.80),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReminderMetaChip extends StatelessWidget {
  const _ReminderMetaChip({
    required this.palette,
    required this.icon,
    required this.text,
  });

  final AppPalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.soft.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: palette.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ),
        ],
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
  final String status;
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
