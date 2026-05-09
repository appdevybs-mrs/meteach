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
import 'package:video_player/video_player.dart';

import '../services/backend_api.dart';
import '../services/mail_consistency_service.dart';
import '../services/push_dispatch_service.dart';
import '../services/route_state.dart';
import 'admin_mail_person_list_navigation.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';
import '../shared/chat_sender_identity.dart';

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
  static const int maxUploadBytes = 250 * 1024 * 1024;

  factory MailUploadClient.defaultClient() {
    return MailUploadClient(
      endpoint: BackendApi.uri('upload_secure.php').toString(),
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
  static const Color _personNameColor = Color(0xFFE65100);

  static const int _messageWindowSize = 300;
  static final String _uploadOrigin = BackendApi.mediaBaseUrl;

  final _db = FirebaseDatabase.instance;

  final _bodyC = TextEditingController();
  final ScrollController _messagesScrollC = ScrollController();

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
  bool _fileUploading = false;
  double _fileUploadProgress = 0;
  String _uploadingFileName = '';

  final List<Map<String, String>> _attachments = []; // {name,url}
  final Set<String> _selectedMessageIds = <String>{};
  List<_MailMsg> _visibleMessages = const <_MailMsg>[];
  final Set<String> _readReceiptWriteInFlight = <String>{};
  final Map<String, ChatSenderIdentity> _senderByUid =
      <String, ChatSenderIdentity>{};
  final Set<String> _senderLoadInFlight = <String>{};
  bool _autoFollowLatest = true;
  int _lastMessageCount = 0;
  int _lastNewestMessageAt = 0;

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _messagesScrollC.addListener(_handleMessagesScroll);

    _threadId = _pairThreadId(_meUid, widget.teacherUid);
    RouteState.enterMailThread(_threadId);

    _msgStream = _msgsRef
        .orderByChild('createdAt')
        .limitToLast(_messageWindowSize)
        .onValue
        .asBroadcastStream();

    _loadOrInitThread();
    _markRead(); // best effort
    _ensureIndexForMe(); // so it appears in inbox even if empty
    unawaited(_warmSenderIdentities());
  }

  @override
  void dispose() {
    RouteState.exitMailThread(_threadId);
    _bodyC.dispose();
    _messagesScrollC
      ..removeListener(_handleMessagesScroll)
      ..dispose();
    super.dispose();
  }

  void _handleMessagesScroll() {
    if (!_messagesScrollC.hasClients) return;
    final pos = _messagesScrollC.position;
    final distanceToBottom = pos.maxScrollExtent - pos.pixels;
    _autoFollowLatest = distanceToBottom <= 120;
  }

  void _scrollToLatest({required bool animated}) {
    if (!_messagesScrollC.hasClients) return;
    final target = _messagesScrollC.position.maxScrollExtent;
    if (animated) {
      _messagesScrollC.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _messagesScrollC.jumpTo(target);
    }
  }

  void _scheduleScrollToLatest({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToLatest(animated: animated);
    });
  }

  void _onMessagesChanged(List<_MailMsg> msgs) {
    final count = msgs.length;
    final newestAt = count == 0 ? 0 : msgs.last.createdAtMs;
    final isChanged =
        count != _lastMessageCount || newestAt != _lastNewestMessageAt;
    final hasNewerContent =
        count > _lastMessageCount || newestAt > _lastNewestMessageAt;

    _lastMessageCount = count;
    _lastNewestMessageAt = newestAt;

    if (!isChanged) return;
    if (hasNewerContent && _autoFollowLatest) {
      _scheduleScrollToLatest(animated: true);
    }
  }

  void _forceScrollToLatest() {
    _autoFollowLatest = true;
    _scheduleScrollToLatest(animated: true);
  }

  double _messageMaxWidth() {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1300) return 560;
    if (width >= 900) return 500;
    if (width >= 600) return 440;
    return width * 0.84;
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

  String _displayNameForUid(String uid) {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return 'User';
    if (cleanUid == _meUid.trim()) return 'Me';
    final known = _senderByUid[cleanUid]?.displayName.trim() ?? '';
    if (known.isNotEmpty) return known;
    if (cleanUid == widget.teacherUid.trim()) return _teacherDisplayName();
    return 'User';
  }

  Future<void> _warmSenderIdentities([
    Iterable<String> hintedUids = const [],
  ]) async {
    final uids = <String>{
      _meUid.trim(),
      widget.teacherUid.trim(),
      ...hintedUids.map((e) => e.trim()),
    }..removeWhere((e) => e.isEmpty);
    if (uids.isEmpty) return;

    var changed = false;
    for (final uid in uids) {
      if (_senderByUid.containsKey(uid) || _senderLoadInFlight.contains(uid)) {
        continue;
      }
      _senderLoadInFlight.add(uid);
      try {
        final snap = await _db.ref('users/$uid').get();
        if (snap.exists && snap.value is Map) {
          final raw = snap.value as Map;
          _senderByUid[uid] = ChatSenderIdentity(
            uid: uid,
            displayName: resolveDisplayNameFromUserMap(raw, uid),
            photoUrl: resolvePhotoUrlFromUserMap(raw),
          );
          changed = true;
        }
      } catch (_) {
      } finally {
        _senderLoadInFlight.remove(uid);
      }
    }
    if (changed && mounted) setState(() {});
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
        'peerRole': 'teacher',
        'deletedAt': null,
      });
    } catch (_) {}
  }

  Future<void> _markRead() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _stateRef.child(_meUid).child(_threadId).update({
        'lastDeliveredAt': now,
        'lastReadAt': now,
      });
      await _indexRef.child(_meUid).child(_threadId).update({'unreadCount': 0});
    } catch (_) {}
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _markMessagesSeen(List<_MailMsg> msgs) async {
    if (_meUid.isEmpty) return;

    final targets = msgs
        .where(
          (m) =>
              m.fromUid != _meUid &&
              !m.deletedFor.contains(_meUid) &&
              (m.readBy[_meUid] ?? 0) <= 0 &&
              !_readReceiptWriteInFlight.contains(m.id),
        )
        .toList(growable: false);
    if (targets.isEmpty) return;

    for (final m in targets) {
      _readReceiptWriteInFlight.add(m.id);
    }

    var wroteAny = false;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final m in targets) {
        try {
          final tx = await _msgsRef
              .child(m.id)
              .child('readBy')
              .child(_meUid)
              .runTransaction((cur) {
                final existing = _toInt(cur);
                if (existing > 0) return Transaction.abort();
                return Transaction.success(now);
              });
          if (tx.committed == true) wroteAny = true;
        } catch (_) {}
      }
    } finally {
      for (final m in targets) {
        _readReceiptWriteInFlight.remove(m.id);
      }
    }

    if (wroteAny) {
      unawaited(_markRead());
    }
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
    if (_sending || _fileUploading) return;

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
    _forceScrollToLatest();

    try {
      await _setSubjectIfNeeded();

      final now = DateTime.now().millisecondsSinceEpoch;
      final msgRef = _msgsRef.push();
      final msgKey = msgRef.key!;

      final preview = bodyBackup.isEmpty ? '📎 Attachment' : bodyBackup;
      final preview80 = preview.length > 80
          ? preview.substring(0, 80)
          : preview;

      final myRole = await MailConsistencyService.resolveUserRole(
        _db,
        _meUid,
        seedRole: 'admin',
      );
      final peerRole = await MailConsistencyService.resolveUserRole(
        _db,
        widget.teacherUid,
        seedRole: 'teacher',
      );

      final root = _db.ref();
      final updates = <String, dynamic>{
        'mail_messages/$_threadId/$msgKey': {
          'fromUid': _meUid,
          'body': bodyBackup,
          'toUids': {widget.teacherUid: true},
          'ccUids': {},
          'bccUids': {},
          'attachments': attachmentsBackup,
          'createdAt': now,
          'deletedFor': {},
        },
        'mail_threads/$_threadId/updatedAt': now,
        'mail_threads/$_threadId/lastMessage': preview80,
        'mail_threads/$_threadId/participants/$_meUid': true,
        'mail_threads/$_threadId/participants/${widget.teacherUid}': true,
        'mail_index/$_meUid/$_threadId/subject': _subject,
        'mail_index/$_meUid/$_threadId/type': 'mail',
        'mail_index/$_meUid/$_threadId/updatedAt': now,
        'mail_index/$_meUid/$_threadId/lastMessage': preview80,
        'mail_index/$_meUid/$_threadId/unreadCount': 0,
        'mail_index/$_meUid/$_threadId/peerUid': widget.teacherUid,
        'mail_index/$_meUid/$_threadId/peerName': _teacherDisplayName(),
        'mail_index/$_meUid/$_threadId/peerRole': peerRole,
        'mail_index/$_meUid/$_threadId/deletedAt': null,
        'mail_index/${widget.teacherUid}/$_threadId/subject': _subject,
        'mail_index/${widget.teacherUid}/$_threadId/type': 'mail',
        'mail_index/${widget.teacherUid}/$_threadId/updatedAt': now,
        'mail_index/${widget.teacherUid}/$_threadId/lastMessage': preview80,
        'mail_index/${widget.teacherUid}/$_threadId/peerUid': _meUid,
        'mail_index/${widget.teacherUid}/$_threadId/peerName': _meName,
        'mail_index/${widget.teacherUid}/$_threadId/peerRole': myRole,
        'mail_index/${widget.teacherUid}/$_threadId/deletedAt': null,
        'mail_index/${widget.teacherUid}/$_threadId/unreadCount':
            ServerValue.increment(1),
        'mail_state/$_meUid/$_threadId/lastReadAt': now,
        'mail_state/$_meUid/$_threadId/lastDeliveredAt': now,
        'mail_state/${widget.teacherUid}/$_threadId/lastDeliveredAt': now,
      };

      await root.update(updates);

      await MailConsistencyService.verifyMailWriteOnce(
        db: _db,
        threadId: _threadId,
        senderUid: _meUid,
        receiverUid: widget.teacherUid,
        senderName: _meName,
        receiverName: _teacherDisplayName(),
        senderRole: myRole,
        receiverRole: peerRole,
        subject: _subject,
        lastMessage: preview80,
        now: now,
        type: 'mail',
      );

      final teacherName = _teacherDisplayName();

      // For me
      await _indexRef.child(_meUid).child(_threadId).update({
        'subject': _subject,
        'updatedAt': now,
        'lastMessage': preview80,
        'unreadCount': 0,
        'peerUid': widget.teacherUid,
        'peerName': teacherName.isEmpty ? 'Teacher' : teacherName,
        'peerRole': peerRole,
        'deletedAt': null,
      });

      unawaited(_markRead());
      _forceScrollToLatest();

      // notify teacher (do not block UI)
      unawaited(() async {
        try {
          await PushDispatchService.dispatchMailToUser(
            targetUid: widget.teacherUid,
            threadId: _threadId,
            peerUid: _meUid,
            title: _subject,
            preview: preview80,
            nowMs: now,
            context: const PushDispatchContext(
              screen: 'admin/admin_teacher_mail_thread',
              action: 'mail_push',
            ),
          );
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
          final sender = _displayNameForUid(m.fromUid);
          return '[${_fmt(m.createdAtMs)}] $sender: $body';
        })
        .join('\n');

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack('Copied ${targets.length} message(s) to clipboard.');
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
    final clean = s.split('?').first.split('#').first;
    return clean.endsWith('.jpg') ||
        clean.endsWith('.jpeg') ||
        clean.endsWith('.png') ||
        clean.endsWith('.webp') ||
        clean.endsWith('.gif');
  }

  static bool _looksLikeVideo(String urlOrName) {
    final s = urlOrName.toLowerCase();
    final clean = s.split('?').first.split('#').first;
    return clean.endsWith('.mp4') ||
        clean.endsWith('.m4v') ||
        clean.endsWith('.mov') ||
        clean.endsWith('.webm') ||
        clean.endsWith('.mkv') ||
        clean.endsWith('.avi');
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

  Future<void> _showImageViewer(String rawUrl, {String? title}) async {
    final url = _safeNetworkUrl(rawUrl);
    if (url.isEmpty) return;
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (_) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(10),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.6,
                  maxScale: 4.0,
                  child: Center(
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Text(
                        'Failed to load image',
                        style: TextStyle(color: Colors.white),
                      ),
                      loadingBuilder: (ctx, child, prog) {
                        if (prog == null) return child;
                        return const Center(child: CircularProgressIndicator());
                      },
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 10,
                left: 10,
                right: 10,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                      ),
                    ),
                    if ((title ?? '').trim().isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          title!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
          onTap: () => _showImageViewer(url, title: name),
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

  @override
  Widget build(BuildContext context) {
    final teacherName = _teacherDisplayName();
    final title = _selectionMode
        ? '${_selectedMessageIds.length} selected'
        : (teacherName.isEmpty ? 'Mail' : 'Mail — $teacherName');

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
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Open staff list',
            onPressed: () => openAdminFilteredPeopleList(
              context,
              peerUid: widget.teacherUid,
              peerName: teacherName,
              seedRole: 'teacher',
            ),
            icon: const Icon(Icons.manage_search_rounded),
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
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1500,
        child: SelectionArea(
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
                    unawaited(
                      _warmSenderIdentities(msgs.map((m) => m.fromUid)),
                    );
                    unawaited(_markMessagesSeen(msgs));
                    _onMessagesChanged(msgs);
                    _visibleMessages = msgs;
                    if (msgs.isEmpty) {
                      return const Center(child: Text('No mail yet.'));
                    }

                    return ListView.builder(
                      controller: _messagesScrollC,
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
                              constraints: BoxConstraints(
                                maxWidth: _messageMaxWidth(),
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: _selectedMessageIds.contains(m.id)
                                      ? Border.all(
                                          color: Colors.orange,
                                          width: 1.5,
                                        )
                                      : null,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    10,
                                    12,
                                    10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: mine
                                        ? const Color(0xFFE3F2FD)
                                        : senderAccentColor(
                                            m.fromUid,
                                          ).withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: Colors.black.withValues(
                                        alpha: 0.08,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Flexible(
                                            child: Wrap(
                                              spacing: 8,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Text(
                                                  _displayNameForUid(m.fromUid),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    color: mine
                                                        ? _personNameColor
                                                        : senderAccentColor(
                                                            m.fromUid,
                                                          ),
                                                    fontSize: 12,
                                                  ),
                                                ),
                                                Text(
                                                  _fmt(m.createdAtMs),
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.55,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (!_selectionMode) ...[
                                            const SizedBox(width: 2),
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
                                onDeleted: () {
                                  setState(() => _attachments.remove(a));
                                },
                              );
                            }).toList(),
                          ),
                        ),
                      CallbackShortcuts(
                        bindings: {
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            control: true,
                          ): _send,
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            meta: true,
                          ): _send,
                        },
                        child: Row(
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
                                  hintText:
                                      'Write mail… (Ctrl/Cmd+Enter to send)',
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
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
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
    required this.readBy,
  });

  final String id;
  final String fromUid;
  final String body;
  final List<Map<String, String>> attachments;
  final int createdAtMs;
  final Set<String> deletedFor;
  final Map<String, int> readBy;

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
    } else if (rawAtt is Map) {
      for (final item in rawAtt.values) {
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

    final readBy = <String, int>{};
    final rawReadBy = m['readBy'];
    if (rawReadBy is Map) {
      rawReadBy.forEach((uid, ts) {
        if (uid == null) return;
        final ms = parseMs(ts);
        if (ms > 0) readBy[uid.toString()] = ms;
      });
    }

    return _MailMsg(
      id: id,
      fromUid: (m['fromUid'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      attachments: atts,
      createdAtMs: parseMs(m['createdAt']),
      deletedFor: del,
      readBy: readBy,
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
