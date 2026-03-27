import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/backend_api.dart';
import '../services/push_client.dart';
import '../services/route_state.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_tour_guide.dart';
import '../shared/screen_help_guide.dart';

/// ----------------------------
/// Upload client (same as reminders)
/// ----------------------------
class MailUploadClient {
  MailUploadClient({
    required this.endpoint,
    required this.appId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String endpoint;
  final String appId;
  final http.Client _http;

  factory MailUploadClient.defaultClient() {
    return MailUploadClient(
      endpoint: 'https://www.yourbridgeschool.com/app/secure/upload_secure.php',
      appId: 'dreamenglishacademy',
    );
  }

  Future<String> uploadFile({required File file}) async {
    final uri = await BackendApi.withAuthQuery(Uri.parse(endpoint));
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');
    final token = await BackendApi.authToken();

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll({
        'X-Requested-With': 'XMLHttpRequest',
        'Authorization': 'Bearer $token',
        'X-Auth-Token': token,
        'X-Auth-Uid': user.uid,
      })
      ..fields['auth_token'] = token
      ..fields['auth_uid'] = user.uid
      ..fields['app_id'] = appId
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamed = await _http.send(req).timeout(const Duration(seconds: 90));
    final body = await streamed.stream.bytesToString().timeout(
      const Duration(seconds: 90),
    );

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

/// ----------------------------
/// Thread Screen: Admin <-> Teacher (Gmail-like thread)
/// ----------------------------
class AdminTeacherMailThreadScreen extends StatefulWidget {
  const AdminTeacherMailThreadScreen({
    super.key,
    required this.teacherUid,
    required this.teacher,
  });

  final String teacherUid;
  final dynamic teacher; // Staff instance OR Map from RTDB

  @override
  State<AdminTeacherMailThreadScreen> createState() =>
      _AdminTeacherMailThreadScreenState();
}

class _AdminTeacherMailThreadScreenState
    extends State<AdminTeacherMailThreadScreen> {
  final _db = FirebaseDatabase.instance;

  final _bodyC = TextEditingController();

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _meName =>
      (FirebaseAuth.instance.currentUser?.email ?? 'Admin').trim();

  late final String _threadId;

  DatabaseReference get _threadRef => _db.ref('mail_threads/$_threadId');
  DatabaseReference get _msgsRef => _db.ref('mail_messages/$_threadId');
  DatabaseReference get _indexRef => _db.ref('mail_index');
  DatabaseReference get _stateRef => _db.ref('mail_state');

  late final Stream<DatabaseEvent> _msgStream;

  String _subject = '';
  bool _sending = false;

  final List<Map<String, String>> _attachments = []; // {name,url}
  final Set<String> _selectedMessageIds = <String>{};
  List<_MailMsg> _visibleMessages = const <_MailMsg>[];

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  @override
  void initState() {
    super.initState();

    _threadId = _pairThreadId(_meUid, widget.teacherUid);
    RouteState.enterMailThread(_threadId);

    _msgStream = _msgsRef.orderByChild('createdAt').onValue.asBroadcastStream();

    _loadOrInitThread();
    _markRead(); // best effort
    _ensureIndexForMe(); // so it appears in inbox even if empty
  }

  @override
  void dispose() {
    RouteState.exitMailThread(_threadId);
    _bodyC.dispose();
    super.dispose();
  }

  /// teacher display name
  String _teacherDisplayName() {
    final t = widget.teacher;

    // If opened from AdminStaffScreen -> Staff model with .fullName
    try {
      final fullName = (t?.fullName ?? '').toString().trim();
      if (fullName.isNotEmpty) return fullName;
    } catch (_) {}

    // If opened from notification -> Map from /users/{uid}
    if (t is Map) {
      String read(dynamic key) => (t[key] ?? '').toString().trim();

      final first = read('first_name').isNotEmpty
          ? read('first_name')
          : read('firstName');
      final last = read('last_name').isNotEmpty
          ? read('last_name')
          : read('lastName');

      final full = ('$first $last').trim();
      if (full.isNotEmpty) return full;

      final email = read('email');
      if (email.isNotEmpty) return email;
    }

    return 'Teacher';
  }

  // stable thread id (same for both users)
  static String _pairThreadId(String a, String b) {
    final x = a.trim();
    final y = b.trim();
    if (x.compareTo(y) < 0) return '${x}_$y';
    return '${y}_$x';
  }

  void _snack(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(humanizeUiMessage(msg))),
    );
  }

  Future<String?> _getFcmToken(String uid) async {
    final snap = await FirebaseDatabase.instance
        .ref('fcm_tokens/$uid/token')
        .get();
    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<void> _loadOrInitThread() async {
    try {
      final snap = await _threadRef.get();
      final v = snap.value;

      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        setState(() => _subject = (m['subject'] ?? '').toString());
        return;
      }

      await _threadRef.set({
        'subject': '',
        'createdAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
        'lastMessage': '',
        'participants': {_meUid: true, widget.teacherUid: true},
      });
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback:
              'Could not open this mail thread right now. Please try again.',
        ),
      );
    }
  }

  Future<void> _ensureIndexForMe() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final teacherName = _teacherDisplayName();

      await _indexRef.child(_meUid).child(_threadId).update({
        'subject': _subject,
        'updatedAt': now,
        'lastMessage': '',
        'unreadCount': 0,
        'peerUid': widget.teacherUid,
        'peerName': teacherName.isEmpty ? 'Teacher' : teacherName,
        'deletedAt': null,
      });
    } catch (_) {}
  }

  Future<void> _markRead() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _stateRef.child(_meUid).child(_threadId).update({
        'lastReadAt': now,
      });
      await _indexRef.child(_meUid).child(_threadId).update({'unreadCount': 0});
    } catch (_) {}
  }

  List<_MailMsg> _parseMessages(dynamic data) {
    if (data is! Map) return [];
    final out = <_MailMsg>[];

    data.forEach((k, v) {
      if (k == null || v == null) return;
      if (v is! Map) return;

      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      final msg = _MailMsg.fromMap(k.toString(), m);

      // hide messages deleted "for me"
      if (msg.deletedFor.contains(_meUid)) return;

      out.add(msg);
    });

    out.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return out;
  }

  Future<void> _pickAndUploadAttachment() async {
    try {
      final picked = await FilePicker.platform.pickFiles(withData: false);
      if (picked == null || picked.files.isEmpty) {
        _snack('Upload was cancelled.');
        return;
      }
      final f = picked.files.first;
      if (f.path == null) {
        _snack(
          'The app does not have permission to access this file or action.',
        );
        return;
      }

      final file = File(f.path!);
      final url = await MailUploadClient.defaultClient().uploadFile(file: file);

      setState(() {
        _attachments.add({'name': f.name, 'url': url});
      });
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback:
              'Something unexpected happened while sending the file. Please try again.',
        ),
      );
    }
  }

  Future<void> _setSubjectIfNeeded() async {
    if (_subject.trim().isNotEmpty) return;

    final s = await showDialog<String?>(
      context: context,
      builder: (_) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('Thread topic'),
          content: TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'Subject / Topic'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, c.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (s == null) return;
    if (s.trim().isEmpty) return;

    try {
      await _threadRef.update({'subject': s.trim()});
      setState(() => _subject = s.trim());

      await _indexRef.child(_meUid).child(_threadId).update({
        'subject': s.trim(),
      });
      await _indexRef.child(widget.teacherUid).child(_threadId).update({
        'subject': s.trim(),
      });
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback: 'Could not update the thread subject. Please try again.',
        ),
      );
    }
  }

  /// ✅ Fast send: clear input instantly + restore on failure
  Future<void> _send() async {
    if (_sending) return;

    final body = _bodyC.text.trim();
    if (body.isEmpty && _attachments.isEmpty) {
      _snack('Write something or attach a file.');
      return;
    }

    // backup so we can restore if something fails
    final bodyBackup = body;
    final attachmentsBackup = List<Map<String, String>>.from(_attachments);

    // ✅ clear immediately (feels instant)
    _bodyC.clear();
    setState(() {
      _sending = true;
      _attachments.clear();
    });

    try {
      await _setSubjectIfNeeded();

      final now = DateTime.now().millisecondsSinceEpoch;
      final msgRef = _msgsRef.push();

      final preview = bodyBackup.isEmpty ? '📎 Attachment' : bodyBackup;
      final preview80 = preview.length > 80
          ? preview.substring(0, 80)
          : preview;

      await msgRef.set({
        'fromUid': _meUid,
        'body': bodyBackup,
        'toUids': {widget.teacherUid: true},
        'ccUids': {},
        'bccUids': {},
        'attachments': attachmentsBackup,
        'createdAt': now,
        'deletedFor': {},
      });

      await _threadRef.update({'updatedAt': now, 'lastMessage': preview80});

      final teacherName = _teacherDisplayName();

      // For me
      await _indexRef.child(_meUid).child(_threadId).update({
        'subject': _subject,
        'updatedAt': now,
        'lastMessage': preview80,
        'unreadCount': 0,
        'peerUid': widget.teacherUid,
        'peerName': teacherName.isEmpty ? 'Teacher' : teacherName,
        'deletedAt': null,
      });

      // For teacher: unread + 1 (transaction avoids race)
      await _indexRef.child(widget.teacherUid).child(_threadId).runTransaction((
        cur,
      ) {
        final m = (cur as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        final oldUnread = (m['unreadCount'] is num)
            ? (m['unreadCount'] as num).toInt()
            : 0;

        m['subject'] = _subject;
        m['updatedAt'] = now;
        m['lastMessage'] = preview80;
        m['unreadCount'] = oldUnread + 1;
        m['peerUid'] = _meUid;
        m['peerName'] = _meName;
        m['deletedAt'] = null;

        return Transaction.success(m);
      });

      unawaited(_markRead());

      // notify teacher (do not block UI)
      unawaited(() async {
        try {
          final token = await _getFcmToken(widget.teacherUid);
          if (token != null) {
            await PushClient.sendToToken(
              token: token,
              title: _subject.trim().isEmpty ? 'New mail' : _subject.trim(),
              message: preview80.isEmpty ? 'You received new mail' : preview80,
              data: {
                'type': 'mail',
                'route': 'mail_thread',
                'threadId': _threadId,
                'peerUid': _meUid,
              },
            );
          }
        } catch (_) {}
      }());
    } catch (e) {
      // ✅ restore user input if failed
      _bodyC.text = bodyBackup;
      setState(() {
        _attachments
          ..clear()
          ..addAll(attachmentsBackup);
      });
      _snack(
        toHumanError(
          e,
          fallback:
              'Your message could not be sent right now. Please check your internet and try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteThreadForMe() async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete conversation?'),
            content: const Text(
              'This will delete the conversation only for you.\nThe other user will still see it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (!ok) return;

    try {
      final now = DateTime.now().millisecondsSinceEpoch;

      await _indexRef.child(_meUid).child(_threadId).update({'deletedAt': now});

      await _stateRef.child(_meUid).child(_threadId).remove();

      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback: 'Could not delete this thread. Please try again.',
        ),
      );
    }
  }

  Future<void> _deleteMessageForMe(_MailMsg m) async {
    try {
      await _msgsRef.child(m.id).child('deletedFor').child(_meUid).set(true);
      _snack('Deleted for you ✅');
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback: 'Could not delete this message. Please try again.',
        ),
      );
    }
  }

  void _toggleMessageSelection(_MailMsg m) {
    setState(() {
      if (_selectedMessageIds.contains(m.id)) {
        _selectedMessageIds.remove(m.id);
      } else {
        _selectedMessageIds.add(m.id);
      }
    });
  }

  Future<void> _deleteSelectedMessages(List<_MailMsg> visibleMsgs) async {
    if (_selectedMessageIds.isEmpty) return;
    final targets = visibleMsgs
        .where((m) => _selectedMessageIds.contains(m.id))
        .toList();
    if (targets.isEmpty) return;

    try {
      for (final m in targets) {
        await _msgsRef.child(m.id).child('deletedFor').child(_meUid).set(true);
      }
      if (!mounted) return;
      setState(() => _selectedMessageIds.clear());
      _snack('Deleted ${targets.length} message(s) ✅');
    } catch (e) {
      _snack(toHumanError(e, fallback: 'Could not delete selected messages.'));
    }
  }

  Future<void> _copySelectedMessages(List<_MailMsg> visibleMsgs) async {
    if (_selectedMessageIds.isEmpty) return;
    final targets =
        visibleMsgs.where((m) => _selectedMessageIds.contains(m.id)).toList()
          ..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    if (targets.isEmpty) return;

    final text = targets
        .map((m) {
          final body = m.body.trim().isEmpty ? '(Attachment)' : m.body.trim();
          final sender = m.fromUid == _meUid ? 'Me' : 'Teacher';
          return '[${_fmt(m.createdAtMs)}] $sender: $body';
        })
        .join('\n');

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack('Copied ${targets.length} message(s) to clipboard.');
  }

  Future<void> _openUrlExternal(String raw) async {
    final url = raw.trim();
    if (url.isEmpty) return;
    final u = Uri.tryParse(url.startsWith('//') ? 'https:$url' : url);
    if (u == null) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final teacherName = _teacherDisplayName();
    final title = _selectionMode
        ? '${_selectedMessageIds.length} selected'
        : (teacherName.isEmpty ? 'Mail' : 'Mail — $teacherName');

    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_teacher_mail_thread',
      title: 'محادثة البريد',
      line: 'هنا تقرأ الرسائل مع المعلم وترسل ردودا او مرفقات.',
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_selectionMode)
            IconButton(
              tooltip: 'Copy selected',
              icon: const Icon(Icons.copy_all_rounded),
              onPressed: () => _copySelectedMessages(_visibleMessages),
            ),
          if (_selectionMode)
            IconButton(
              tooltip: 'Delete selected',
              icon: const Icon(Icons.delete_sweep_rounded, color: Colors.red),
              onPressed: () => _deleteSelectedMessages(_visibleMessages),
            ),
          if (_selectionMode)
            IconButton(
              tooltip: 'Clear selection',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => setState(() => _selectedMessageIds.clear()),
            ),
          IconButton(
            tooltip: 'Help / Instructions',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => ScreenHelpGuide.show(
              context,
              role: GuideRole.admin,
              screenId: 'admin_teacher_mail_thread',
              screenTitle: 'Mail Thread',
            ),
          ),
          IconButton(
            tooltip: 'Set subject',
            onPressed: _setSubjectIfNeeded,
            icon: const Icon(Icons.subject),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'delete_thread') {
                await _deleteThreadForMe();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete_thread',
                child: Text('Delete (for me)'),
              ),
            ],
          ),
        ],
      ),
      body: SelectionArea(
        child: Column(
          children: [
            if (_subject.trim().isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                color: Colors.black.withValues(alpha: 0.04),
                child: Text(
                  'Topic: $_subject',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _msgStream,
                builder: (_, snap) {
                  final msgs = _parseMessages(snap.data?.snapshot.value);
                  _visibleMessages = msgs;
                  if (msgs.isEmpty) {
                    return const Center(child: Text('No mail yet.'));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: msgs.length,
                    itemBuilder: (_, i) {
                      final m = msgs[i];
                      final mine = m.fromUid == _meUid;

                      return GestureDetector(
                        onLongPress: () => _toggleMessageSelection(m),
                        onTap: _selectionMode
                            ? () => _toggleMessageSelection(m)
                            : null,
                        child: Align(
                          alignment: mine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 340),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: _selectedMessageIds.contains(m.id)
                                    ? Border.all(
                                        color: Colors.orange,
                                        width: 1.5,
                                      )
                                    : null,
                              ),
                              child: Card(
                                elevation: 0,
                                color: mine
                                    ? Colors.blue.withValues(alpha: 0.12)
                                    : Colors.black.withValues(alpha: 0.05),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: mine
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              mine ? 'Me' : 'Teacher',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                color: Colors.black.withValues(
                                                  alpha: 0.6,
                                                ),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _fmt(m.createdAtMs),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.black.withValues(
                                                alpha: 0.55,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          if (!_selectionMode)
                                            SizedBox(
                                              width: 32,
                                              height: 32,
                                              child: PopupMenuButton<String>(
                                                padding: EdgeInsets.zero,
                                                tooltip: 'Message actions',
                                                onSelected: (v) async {
                                                  if (v == 'delete_for_me') {
                                                    await _deleteMessageForMe(
                                                      m,
                                                    );
                                                  }
                                                },
                                                itemBuilder: (_) => const [
                                                  PopupMenuItem(
                                                    value: 'delete_for_me',
                                                    child: Text(
                                                      'Delete (for me)',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                      if (m.body.trim().isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        SelectableText(m.body),
                                      ],
                                      if (m.attachments.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        ...m.attachments.map((a) {
                                          final name =
                                              a['name'] ?? 'Attachment';
                                          final url = a['url'] ?? '';
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 6,
                                            ),
                                            child: InkWell(
                                              onTap: () =>
                                                  _openUrlExternal(url),
                                              child: Text(
                                                '📎 $name',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  decoration:
                                                      TextDecoration.underline,
                                                ),
                                              ),
                                            ),
                                          );
                                        }),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // composer
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  children: [
                    if (_attachments.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _attachments.map((a) {
                            return Chip(
                              label: Text(a['name'] ?? 'file'),
                              onDeleted: () {
                                setState(() => _attachments.remove(a));
                              },
                            );
                          }).toList(),
                        ),
                      ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Attach',
                          onPressed: _sending ? null : _pickAndUploadAttachment,
                          icon: const Icon(Icons.attach_file),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _bodyC,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'Write mail…',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _sending ? null : _send,
                          child: Text(_sending ? 'Sending…' : 'Send'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

class _MailMsg {
  _MailMsg({
    required this.id,
    required this.fromUid,
    required this.body,
    required this.attachments,
    required this.createdAtMs,
    required this.deletedFor,
  });

  final String id;
  final String fromUid;
  final String body;
  final List<Map<String, String>> attachments;
  final int createdAtMs;
  final Set<String> deletedFor;

  factory _MailMsg.fromMap(String id, Map<String, dynamic> m) {
    int parseMs(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    final rawAtt = m['attachments'];
    final atts = <Map<String, String>>[];
    if (rawAtt is List) {
      for (final item in rawAtt) {
        if (item is Map) {
          final mm = item.map((k, v) => MapEntry(k.toString(), v.toString()));
          atts.add(mm);
        }
      }
    }

    final del = <String>{};
    final rawDel = m['deletedFor'];
    if (rawDel is Map) {
      rawDel.forEach((k, v) {
        if (k == null) return;
        if (v == true) del.add(k.toString());
      });
    }

    return _MailMsg(
      id: id,
      fromUid: (m['fromUid'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      attachments: atts,
      createdAtMs: parseMs(m['createdAt']),
      deletedFor: del,
    );
  }
}
