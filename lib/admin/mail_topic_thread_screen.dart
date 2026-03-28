import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';
import '../services/backend_api.dart';
import '../services/route_state.dart'; // ✅ ADD THIS
import '../shared/human_error.dart';

import '../services/push_client.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_tour_guide.dart';
import '../shared/screen_help_guide.dart';

class MailUploadClient {
  MailUploadClient({
    required this.endpoint,
    required this.appId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String endpoint;
  final String appId;
  final http.Client _http;
  static const int maxUploadBytes = 250 * 1024 * 1024;

  factory MailUploadClient.defaultClient() {
    return MailUploadClient(
      endpoint: 'https://www.yourbridgeschool.com/app/secure/upload_secure.php',
      appId: 'dreamenglishacademy',
    );
  }

  Future<String> uploadFile({
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    final uri = await BackendApi.withAuthQuery(Uri.parse(endpoint));
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');
    final token = await BackendApi.authToken();

    final total = await file.length();
    if (total <= 0) {
      throw Exception('Could not read selected file bytes.');
    }
    if (total > maxUploadBytes) {
      throw Exception('File is too large. Maximum allowed size is 250 MB.');
    }
    var sent = 0;
    onProgress?.call(0);
    final tracked = file.openRead().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          if (total > 0) {
            onProgress?.call((sent / total).clamp(0.0, 1.0));
          }
          sink.add(chunk);
        },
      ),
    );

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
      ..files.add(
        http.MultipartFile(
          'file',
          tracked,
          total,
          filename: file.uri.pathSegments.last,
        ),
      );

    final streamed = await _http.send(req).timeout(const Duration(minutes: 10));
    final body = await streamed.stream.bytesToString().timeout(
      const Duration(minutes: 10),
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

    onProgress?.call(1);

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
  static const String _uploadOrigin = 'https://www.yourbridgeschool.com';

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
  bool _fileUploading = false;
  double _fileUploadProgress = 0;
  String _uploadingFileName = '';

  final List<Map<String, String>> _attachments = [];
  final Set<String> _selectedMessageIds = <String>{};
  List<_MailMsg> _visibleMessages = const <_MailMsg>[];

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

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
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(humanizeUiMessage(msg))),
    );
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
      final size = await file.length();
      if (size > MailUploadClient.maxUploadBytes) {
        _snack('This file is too large. Maximum allowed size is 250 MB.');
        return;
      }

      setState(() {
        _fileUploading = true;
        _fileUploadProgress = 0;
        _uploadingFileName = f.name;
      });

      final url = await MailUploadClient.defaultClient().uploadFile(
        file: file,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _fileUploadProgress = p.clamp(0.0, 1.0));
        },
      );

      setState(() {
        _attachments.add({'name': f.name, 'url': url});
        _fileUploading = false;
        _fileUploadProgress = 0;
        _uploadingFileName = '';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _fileUploading = false;
          _fileUploadProgress = 0;
          _uploadingFileName = '';
        });
      }
      _snack(
        toHumanError(
          e,
          fallback:
              'Something unexpected happened while sending the file. Please try again.',
        ),
      );
    }
  }

  Future<void> _openUrlExternal(String raw) async {
    final url = _safeNetworkUrl(raw);
    if (url.isEmpty) return;
    final u = Uri.tryParse(url);
    if (u == null) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  static String _safeNetworkUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';

    s = s.replaceAll('\\', '/');
    if (s.startsWith('//')) s = 'https:$s';

    final u0 = Uri.tryParse(s);
    final hasScheme = u0 != null && u0.scheme.isNotEmpty;
    if (!hasScheme) {
      s = s.startsWith('/') ? '$_uploadOrigin$s' : '$_uploadOrigin/$s';
    }
    if (s.startsWith('http://')) {
      s = 'https://${s.substring('http://'.length)}';
    }
    return Uri.tryParse(s)?.toString() ?? Uri.encodeFull(s);
  }

  static bool _looksLikeImage(String urlOrName) {
    final s = urlOrName.toLowerCase();
    return s.endsWith('.jpg') ||
        s.endsWith('.jpeg') ||
        s.endsWith('.png') ||
        s.endsWith('.webp') ||
        s.endsWith('.gif');
  }

  static bool _looksLikeVideo(String urlOrName) {
    final s = urlOrName.toLowerCase();
    return s.endsWith('.mp4') ||
        s.endsWith('.m4v') ||
        s.endsWith('.mov') ||
        s.endsWith('.webm') ||
        s.endsWith('.mkv') ||
        s.endsWith('.avi');
  }

  Future<void> _showVideoViewer(String rawUrl, {String? title}) async {
    final url = _safeNetworkUrl(rawUrl);
    if (url.isEmpty || !mounted) return;

    await showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(10),
        child: _MailVideoViewer(url: url, title: title),
      ),
    );
  }

  Widget _buildAttachmentWidget({
    required Map<String, String> a,
    required bool mine,
  }) {
    final name = a['name'] ?? 'Attachment';
    final url = _safeNetworkUrl((a['url'] ?? '').trim());
    final isImg = _looksLikeImage(name) || _looksLikeImage(url);
    final isVid = _looksLikeVideo(name) || _looksLikeVideo(url);

    if (isImg && url.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: () => _openUrlExternal(url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220, maxHeight: 150),
              child: Image.network(url, fit: BoxFit.cover),
            ),
          ),
        ),
      );
    }

    if (isVid && url.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: () => _showVideoViewer(url, title: name),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 220,
            height: 130,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: mine
                  ? Colors.blue.withValues(alpha: 0.22)
                  : Colors.black.withValues(alpha: 0.15),
            ),
            child: Stack(
              children: [
                const Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 8,
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => _openUrlExternal(url),
        child: Text(
          '📎 $name',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Widget _buildFileUploadingBar() {
    if (!_fileUploading) return const SizedBox.shrink();
    final pct = (_fileUploadProgress * 100).clamp(0, 100).toStringAsFixed(0);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.upload_file_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Uploading ${_uploadingFileName.isEmpty ? 'attachment' : _uploadingFileName}…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '$pct%',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _fileUploadProgress),
        ],
      ),
    );
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
      _snack(
        toHumanError(
          e,
          fallback: 'Could not delete this topic. Please try again.',
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
          final sender = m.fromUid == _meUid ? 'Me' : widget.peerName;
          return '[${_fmt(m.createdAtMs)}] $sender: $body';
        })
        .join('\n');

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack('Copied ${targets.length} message(s) to clipboard.');
  }

  Future<void> _send() async {
    if (_sending || _fileUploading) return;

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

  @override
  Widget build(BuildContext context) {
    final baseTitle = _subject.trim().isEmpty ? 'Topic' : _subject.trim();
    final title = _selectionMode
        ? '${_selectedMessageIds.length} selected'
        : baseTitle;

    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_mail_topic_thread',
      title: 'محادثة الموضوع',
      line: 'استخدم هذه الشاشة لمتابعة الرسائل داخل موضوع بريد محدد.',
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
            onPressed: () => ScreenHelpGuide.show(
              context,
              role: GuideRole.admin,
              screenId: 'admin_mail_topic_thread',
              screenTitle: title,
            ),
            icon: const Icon(Icons.help_outline_rounded),
          ),
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
      body: SelectionArea(
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _msgStream,
                builder: (_, snap) {
                  final msgs = _parseMessages(snap.data?.snapshot.value);
                  _visibleMessages = msgs;
                  if (msgs.isEmpty) {
                    return const Center(child: Text('No messages yet.'));
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
                                          Text(
                                            mine ? 'Me' : widget.peerName,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: Colors.black.withValues(
                                                alpha: 0.6,
                                              ),
                                              fontSize: 12,
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
                                            PopupMenuButton<String>(
                                              tooltip: 'Message actions',
                                              onSelected: (v) async {
                                                if (v == 'delete_for_me') {
                                                  await _deleteMessageForMe(m);
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
                                        ],
                                      ),
                                      if (m.body.trim().isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        SelectableText(m.body),
                                      ],
                                      if (m.attachments.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        ...m.attachments.map(
                                          (a) => _buildAttachmentWidget(
                                            a: a,
                                            mine: mine,
                                          ),
                                        ),
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

            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  children: [
                    _buildFileUploadingBar(),
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
                          onPressed: (_sending || _fileUploading)
                              ? null
                              : _pickAndUploadAttachment,
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
                          onPressed: (_sending || _fileUploading)
                              ? null
                              : _send,
                          child: Text(
                            _sending
                                ? 'Sending…'
                                : (_fileUploading ? 'Uploading…' : 'Send'),
                          ),
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
          atts.add(item.map((k, v) => MapEntry(k.toString(), v.toString())));
        }
      }
    } else if (rawAtt is Map) {
      for (final item in rawAtt.values) {
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

class _MailVideoViewer extends StatefulWidget {
  const _MailVideoViewer({required this.url, this.title});

  final String url;
  final String? title;

  @override
  State<_MailVideoViewer> createState() => _MailVideoViewerState();
}

class _MailVideoViewerState extends State<_MailVideoViewer> {
  late final VideoPlayerController _controller;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _initFuture = _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
              Expanded(
                child: Text(
                  (widget.title ?? 'Video').trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FutureBuilder<void>(
            future: _initFuture,
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (!_controller.value.isInitialized) {
                return const SizedBox(
                  height: 220,
                  child: Center(
                    child: Text(
                      'Failed to load video',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                );
              }
              return AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              );
            },
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _controller,
            builder: (_, v, _) {
              final isReady = v.isInitialized;
              return Row(
                children: [
                  IconButton(
                    onPressed: !isReady
                        ? null
                        : () {
                            if (v.isPlaying) {
                              _controller.pause();
                            } else {
                              _controller.play();
                            }
                          },
                    icon: Icon(
                      v.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                    ),
                  ),
                  Expanded(
                    child: VideoProgressIndicator(
                      _controller,
                      allowScrubbing: isReady,
                      colors: const VideoProgressColors(
                        playedColor: Color(0xFFEC740A),
                        bufferedColor: Colors.white38,
                        backgroundColor: Colors.white24,
                      ),
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
