import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/push_client.dart';
import '../services/route_state.dart';

// ✅ Background watermark (already used in your app)
import '../shared/watermark_background.dart';

class LearnerMailThreadScreen extends StatefulWidget {
  const LearnerMailThreadScreen({
    super.key,
    required this.threadId,
    required this.peerUid,
    required this.peerName,
    required this.subject,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String subject;

  @override
  State<LearnerMailThreadScreen> createState() => _LearnerMailThreadScreenState();
}

class _LearnerMailThreadScreenState extends State<LearnerMailThreadScreen> {
  // ---------------- Logo palette (approx from your YBS logo) ----------------
  static const Color _navy = Color(0xFF243B5A);
  static const Color _navyDark = Color(0xFF1C2F4A);
  static const Color _orange = Color(0xFFEC740A);

  static Color _mineBubbleBg(BuildContext context) => _navy;
  static Color _mineText(BuildContext context) => Colors.white;

  static Color _theirsBubbleBg(BuildContext context) => _orange.withOpacity(0.80);
  static Color _theirsText(BuildContext context) => _navyDark;

  static Color _datePillBg(BuildContext context) => Colors.white.withOpacity(0.85);
  static Color _datePillBorder(BuildContext context) => _navy.withOpacity(0.15);

  // ------------------------------------------------------------------------

  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();

  String _meDisplayName = 'Learner';
  String _peerDisplayName = '';
  String get _peerNameShown {
    final p = _peerDisplayName.trim();
    if (p.isNotEmpty) return p;
    return widget.peerName.trim();
  }

  Future<String> _fetchDisplayName(String uid) async {
    // TODO: change "users" to your actual users node name if different
    final snap = await _db.ref('users/$uid').get();
    if (!snap.exists || snap.value is! Map) return '';

    final m = Map<String, dynamic>.from(snap.value as Map);
    final first = (m['first_name'] ?? '').toString().trim();
    final last = (m['last_name'] ?? '').toString().trim();

    final full = ('$first $last').trim();
    return full;
  }

  Future<void> _loadNames() async {
    try {
      final me = await _fetchDisplayName(_meUid);
      final peer = await _fetchDisplayName(widget.peerUid);

      if (!mounted) return;
      setState(() {
        _meDisplayName = me.isNotEmpty ? me : _meDisplayName;
        _peerDisplayName = peer.isNotEmpty ? peer : widget.peerName;
      });
    } catch (_) {}
  }

  String get _meUid => FirebaseAuth.instance.currentUser!.uid;
  String get _meName => (FirebaseAuth.instance.currentUser?.email ?? 'Learner').trim();

  DatabaseReference get _threadRef => _db.ref('mail_threads/${widget.threadId}');
  DatabaseReference get _msgsRef => _db.ref('mail_messages/${widget.threadId}');
  DatabaseReference get _indexRef => _db.ref('mail_index');
  DatabaseReference get _stateRef => _db.ref('mail_state');

  late final Stream<DatabaseEvent> _msgStream;

  bool _sending = false;
  final List<Map<String, String>> _attachments = []; // {name,url}

  @override
  void initState() {
    super.initState();
    RouteState.enterMailThread(widget.threadId);

    _msgStream = _msgsRef.orderByChild('createdAt').onValue.asBroadcastStream();
    _markRead();
    _loadNames();
  }

  Future<void> _markHomeworkSubmittedIfNeeded() async {
    try {
      final tSnap = await _db.ref('mail_threads/${widget.threadId}').get();
      if (!tSnap.exists || tSnap.value is! Map) return;

      final m = Map<String, dynamic>.from(tSnap.value as Map);
      if ((m['type'] ?? '').toString() != 'homework') return;

      final hwPath = (m['homeworkRef'] ?? '').toString().trim();
      if (hwPath.isEmpty) return;

      await _db.ref(hwPath).update({
        'submittedAt': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    RouteState.exitMailThread(widget.threadId);
    _bodyC.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
      await _stateRef.child(_meUid).child(widget.threadId).update({'lastReadAt': now});
      await _indexRef.child(_meUid).child(widget.threadId).update({'unreadCount': 0});
    } catch (_) {}
  }

  // ✅ WhatsApp-like: We will display from bottom.
  // reverse: true requires msgs to be sorted DESC (newest first).
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

    // DESC: newest first (so with reverse:true, newest appears at bottom)
    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
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
      final preview80 = preview.length > 80 ? preview.substring(0, 80) : preview;

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

      await _threadRef.update({'updatedAt': now, 'lastMessage': preview80});
      await _markHomeworkSubmittedIfNeeded();

      // Me
      await _indexRef.child(_meUid).child(widget.threadId).update({
        'subject': widget.subject,
        'updatedAt': now,
        'lastMessage': preview80,
        'unreadCount': 0,
        'peerUid': widget.peerUid,
        'peerName': _peerNameShown,
        'deletedAt': null,
      });

      // Peer unread +1 (transaction)
      await _indexRef.child(widget.peerUid).child(widget.threadId).runTransaction((cur) {
        final m = (cur as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        final oldUnread = (m['unreadCount'] is num) ? (m['unreadCount'] as num).toInt() : 0;

        m['subject'] = widget.subject;
        m['updatedAt'] = now;
        m['lastMessage'] = preview80;
        m['unreadCount'] = oldUnread + 1;
        m['peerUid'] = _meUid;
        m['peerName'] = _meDisplayName;
        m['deletedAt'] = null;

        return Transaction.success(m);
      });

      unawaited(_markRead());

      // Push (non-blocking)
      unawaited(() async {
        try {
          final token = await _getFcmToken(widget.peerUid);
          if (token != null) {
            await PushClient.sendToToken(
              token: token,
              title: widget.subject.isEmpty ? 'New mail' : widget.subject,
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

  // ----------------------- WhatsApp-ish UI helpers -----------------------

  static String _dayKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _dateLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thatDay = DateTime(d.year, d.month, d.day);
    final diffDays = thatDay.difference(today).inDays;

    if (diffDays == 0) return 'Today';
    if (diffDays == -1) return 'Yesterday';
    return _dayKey(d);
  }

  Widget _dateSeparator(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: _datePillBg(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _datePillBorder(context)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: _navy.withOpacity(0.85),
            ),
          ),
        ),
      ),
    );
  }

  BorderRadius _bubbleRadius({required bool mine}) {
    // WhatsApp-like: different corners
    const r = Radius.circular(18);
    const sharp = Radius.circular(6);
    return BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: mine ? r : sharp,
      bottomRight: mine ? sharp : r,
    );
  }

  // ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = _peerNameShown.isEmpty ? 'Mail' : _peerNameShown;

    final subjectTrim = widget.subject.trim();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: _navy),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: _navy,
          ),
        ),
        bottom: (subjectTrim.isEmpty)
            ? null
            : PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: _orange.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _orange.withOpacity(0.35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.topic_rounded, size: 18, color: _navy.withOpacity(0.9)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        subjectTrim,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: _navy.withOpacity(0.92),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: WatermarkBackground(
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _msgStream,
                builder: (_, snap) {
                  final msgs = _parseMessages(snap.data?.snapshot.value);
                  if (msgs.isEmpty) {
                    return const Center(child: Text('No mail yet.'));
                  }

                  return ListView.builder(
                    reverse: true, // ✅ WhatsApp-like (start from bottom)
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: msgs.length,
                    itemBuilder: (_, i) {
                      final m = msgs[i];
                      final mine = m.fromUid == _meUid;

                      // Date separator when day changes between this and the next visible message
                      // (remember: msgs are DESC by time)
                      final thisDateLabel = _dateLabel(m.createdAtMs);
                      String? nextDateLabel;
                      if (i + 1 < msgs.length) {
                        nextDateLabel = _dateLabel(msgs[i + 1].createdAtMs);
                      }
                      final showDate = (i == msgs.length - 1) || (nextDateLabel != thisDateLabel);

                      final bubbleBg = mine ? _mineBubbleBg(context) : _theirsBubbleBg(context);
                      final textColor = mine ? _mineText(context) : _theirsText(context);

                      return Column(
                        children: [
                          if (showDate) _dateSeparator(thisDateLabel),

                          Align(
                            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 340),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: bubbleBg,
                                  borderRadius: _bubbleRadius(mine: mine),
                                  border: Border.all(
                                    color: mine ? Colors.white.withOpacity(0.12) : _navy.withOpacity(0.08),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      blurRadius: 10,
                                      spreadRadius: 0,
                                      offset: const Offset(0, 6),
                                      color: Colors.black.withOpacity(0.05),
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.fromLTRB(12, 10, 10, 9),
                                child: Column(
                                  crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    // Body
                                    if (m.body.trim().isNotEmpty)
                                      Text(
                                        m.body,
                                        style: TextStyle(
                                          color: textColor,
                                          fontSize: 15,
                                          height: 1.35,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),

                                    // Attachments
                                    if (m.attachments.isNotEmpty) ...[
                                      if (m.body.trim().isNotEmpty) const SizedBox(height: 8),
                                      ...m.attachments.map((a) {
                                        final name = a['name'] ?? 'Attachment';
                                        final url = a['url'] ?? '';
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 6),
                                          child: InkWell(
                                            onTap: () => _openUrlExternal(url),
                                            child: Text(
                                              '📎 $name',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                decoration: TextDecoration.underline,
                                                color: mine ? Colors.white : _navy,
                                              ),
                                            ),
                                          ),
                                        );
                                      }),
                                    ],

                                    const SizedBox(height: 6),

                                    // Bottom row: time + menu
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _fmtTime(m.createdAtMs),
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            color: mine ? Colors.white.withOpacity(0.75) : _navy.withOpacity(0.55),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        SizedBox(
                                          width: 28,
                                          height: 28,
                                          child: PopupMenuButton<String>(
                                            padding: EdgeInsets.zero,
                                            tooltip: 'Message actions',
                                            icon: Icon(
                                              Icons.more_vert_rounded,
                                              size: 18,
                                              color: mine ? Colors.white.withOpacity(0.85) : _navy.withOpacity(0.65),
                                            ),
                                            onSelected: (v) async {
                                              if (v == 'delete_for_me') await _deleteMessageForMe(m);
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(value: 'delete_for_me', child: Text('Delete (for me)')),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),

            // Composer
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
                              onDeleted: () => setState(() => _attachments.remove(a)),
                            );
                          }).toList(),
                        ),
                      ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Attach',
                          onPressed: _sending ? null : _pickAndUploadAttachment,
                          icon: Icon(Icons.attach_file, color: _navy.withOpacity(0.9)),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _bodyC,
                            minLines: 1,
                            maxLines: 4,
                            decoration: InputDecoration(
                              hintText: 'Message…',
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.92),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(color: _navy.withOpacity(0.15)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(color: _navy.withOpacity(0.12)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide(color: _orange.withOpacity(0.65), width: 1.2),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _navy,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
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

  static String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
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

/// Upload client (same endpoint you already use)
class MailUploadClient {
  MailUploadClient({
    required this.endpoint,
    required this.appId,
    required this.key,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String endpoint;
  final String appId;
  final String key;
  final http.Client _http;

  factory MailUploadClient.defaultClient() {
    return MailUploadClient(
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
    if (decoded == null) throw Exception('Upload failed: invalid JSON\n$body');

    final ok = decoded['success'] == true;
    final url = (decoded['url'] ?? '').toString();
    if (!ok || url.trim().isEmpty) throw Exception('Upload failed: $decoded');

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