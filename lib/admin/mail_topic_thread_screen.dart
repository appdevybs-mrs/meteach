import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import '../services/backend_api.dart';
import '../services/route_state.dart'; // ✅ ADD THIS
import '../shared/human_error.dart';

import '../services/push_client.dart';
import '../shared/app_feedback.dart';

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

class MailTopicThreadScreen extends StatefulWidget {
  const MailTopicThreadScreen({
    super.key,
    required this.threadId,
    required this.peerUid,
    required this.peerName,
  });

  final String threadId;
  final String peerUid;
  final String peerName;

  @override
  State<MailTopicThreadScreen> createState() => _MailTopicThreadScreenState();
}

class _MailTopicThreadScreenState extends State<MailTopicThreadScreen> {
  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get _meName =>
      (FirebaseAuth.instance.currentUser?.email ?? 'Admin').trim();

  DatabaseReference get _threadRef =>
      _db.ref('mail_threads/${widget.threadId}');
  DatabaseReference get _msgsRef => _db.ref('mail_messages/${widget.threadId}');
  DatabaseReference get _indexRef => _db.ref('mail_index');
  DatabaseReference get _stateRef => _db.ref('mail_state');

  late final Stream<DatabaseEvent> _msgStream;

  String _subject = '';
  bool _sending = false;

  final List<Map<String, String>> _attachments = [];

  @override
  void initState() {
    super.initState();
    RouteState.enterMailThread(widget.threadId);

    _msgStream = _msgsRef.orderByChild('createdAt').onValue.asBroadcastStream();
    _loadSubject();
    _markRead();
  }

  @override
  void dispose() {
    RouteState.exitMailThread(widget.threadId);
    _bodyC.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    AppToast.fromSnackBar(context,  SnackBar(content: Text(humanizeUiMessage(msg))));
  }

  Future<void> _loadSubject() async {
    try {
      final snap = await _threadRef.get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        setState(() => _subject = (m['subject'] ?? '').toString().trim());
      }
    } catch (_) {}
  }

  Future<String?> _getFcmToken(String uid) async {
    final snap = await _db.ref('fcm_tokens/$uid/token').get();
    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<void> _markRead() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _stateRef.child(_meUid).child(widget.threadId).update({
        'lastReadAt': now,
      });
      await _indexRef.child(_meUid).child(widget.threadId).update({
        'unreadCount': 0,
      });
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

      if (msg.deletedFor.contains(_meUid)) return;
      out.add(msg);
    });

    out.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return out;
  }

  Future<void> _pickAndUploadAttachment() async {
    try {
      final picked = await FilePicker.platform.pickFiles(withData: false);
      if (picked == null || picked.files.isEmpty) return;
      final f = picked.files.first;
      if (f.path == null) return;

      final file = File(f.path!);
      final url = await MailUploadClient.defaultClient().uploadFile(file: file);

      setState(() => _attachments.add({'name': f.name, 'url': url}));
    } catch (e) {
      _snack('Upload failed: $e');
    }
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

  Future<void> _deleteThreadForMe() async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete topic?'),
            content: const Text(
              'This deletes only for you.\nThe other user still sees it.',
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
      await _indexRef.child(_meUid).child(widget.threadId).update({
        'deletedAt': now,
      });
      await _stateRef.child(_meUid).child(widget.threadId).remove();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _deleteMessageForMe(_MailMsg m) async {
    try {
      await _msgsRef.child(m.id).child('deletedFor').child(_meUid).set(true);
      _snack('Deleted for you ✅');
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _send() async {
    if (_sending) return;

    final body = _bodyC.text.trim();
    if (body.isEmpty && _attachments.isEmpty) {
      _snack('Write something or attach a file.');
      return;
    }

    // ✅ Optimistic clear (instant UX)
    final bodyBackup = body;
    final attachmentsBackup = List<Map<String, String>>.from(_attachments);

    _bodyC.clear();
    setState(() {
      _sending = true;
      _attachments.clear();
    });

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final msgRef = _msgsRef.push();

      final preview = bodyBackup.isEmpty ? '📎 Attachment' : bodyBackup;
      final preview80 = preview.length > 80
          ? preview.substring(0, 80)
          : preview;

      // ✅ 1) write message
      await msgRef.set({
        'fromUid': _meUid,
        'body': bodyBackup,
        'toUids': {widget.peerUid: true},
        'ccUids': {},
        'bccUids': {},
        'attachments': attachmentsBackup,
        'createdAt': now,
        'deletedFor': {},
      });

      // ✅ 2) update thread meta
      await _threadRef.update({'updatedAt': now, 'lastMessage': preview80});

      // ✅ 3) update BOTH indexes (no unreadCount read needed)
      await _indexRef.child(_meUid).child(widget.threadId).update({
        'subject': _subject,
        'updatedAt': now,
        'lastMessage': preview80,
        'unreadCount': 0,
        'peerUid': widget.peerUid,
        'peerName': widget.peerName,
        'deletedAt': null,
      });

      // ✅ Increment peer unread using transaction (fast + safe)
      await _indexRef
          .child(widget.peerUid)
          .child(widget.threadId)
          .runTransaction((cur) {
            final m =
                (cur as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
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

      // ✅ 4) mark read for me (don’t block UI if slow)
      unawaited(_markRead());

      // ✅ 5) push notify (don’t block UI)
      unawaited(() async {
        try {
          final token = await _getFcmToken(widget.peerUid);
          if (token != null) {
            await PushClient.sendToToken(
              token: token,
              title: _subject.isEmpty ? 'New mail' : _subject,
              message: preview80.isEmpty ? 'You received new mail' : preview80,
              data: {
                'type': 'mail',
                'route': 'mail_thread',
                'threadId': widget.threadId,
                'peerUid': _meUid,
              },
            );
          }
        } catch (_) {}
      }());
    } catch (e) {
      // ✅ restore input on failure
      _bodyC.text = bodyBackup;
      setState(() {
        _attachments
          ..clear()
          ..addAll(attachmentsBackup);
      });
      _snack('Send failed: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _subject.trim().isEmpty ? 'Topic' : _subject.trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'delete_topic') await _deleteThreadForMe();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete_topic',
                child: Text('Delete topic (for me)'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<DatabaseEvent>(
              stream: _msgStream,
              builder: (_, snap) {
                final msgs = _parseMessages(snap.data?.snapshot.value);
                if (msgs.isEmpty)
                  return const Center(child: Text('No messages yet.'));

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    final mine = m.fromUid == _meUid;

                    return Align(
                      alignment: mine
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
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
                                    Text(
                                      mine ? 'Me' : widget.peerName,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: Colors.black.withValues(alpha: 0.6),
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _fmt(m.createdAtMs),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.black.withValues(alpha: 0.55),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    PopupMenuButton<String>(
                                      tooltip: 'Message actions',
                                      onSelected: (v) async {
                                        if (v == 'delete_for_me')
                                          await _deleteMessageForMe(m);
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'delete_for_me',
                                          child: Text('Delete (for me)'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                if (m.body.trim().isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(m.body),
                                ],
                                if (m.attachments.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  ...m.attachments.map((a) {
                                    final name = a['name'] ?? 'Attachment';
                                    final url = a['url'] ?? '';
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: InkWell(
                                        onTap: () => _openUrlExternal(url),
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
                    );
                  },
                );
              },
            ),
          ),

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
                            onDeleted: () =>
                                setState(() => _attachments.remove(a)),
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
                            hintText: 'Write…',
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
          atts.add(item.map((k, v) => MapEntry(k.toString(), v.toString())));
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
