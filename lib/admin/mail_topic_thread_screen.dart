import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../services/backend_api.dart';
import '../services/mail_consistency_service.dart';
import '../services/internal_mail_service.dart';
import '../services/push_dispatch_service.dart';
import '../services/route_state.dart'; // ✅ ADD THIS
import 'admin_mail_person_list_navigation.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';
import '../shared/profile_avatar.dart';
import '../shared/chat_sender_identity.dart';
import '../shared/media_download.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

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

  Future<String> uploadBytes({
    required Uint8List bytes,
    required String filename,
    void Function(double progress)? onProgress,
  }) async {
    final uri = await BackendApi.withAuthQuery(Uri.parse(endpoint));
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');
    final token = await BackendApi.authToken();

    final total = bytes.length;
    if (total <= 0) {
      throw Exception('Could not read selected file bytes.');
    }
    if (total > maxUploadBytes) {
      throw Exception('File is too large. Maximum allowed size is 250 MB.');
    }
    onProgress?.call(0);
    var sent = 0;
    final stream = Stream<List<int>>.value(bytes).transform(
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
        http.MultipartFile('file', stream, total, filename: filename),
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
  static const int _messageWindowSize = 300;
  static final String _uploadOrigin = BackendApi.mediaBaseUrl;

  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();
  final ScrollController _messagesScrollC = ScrollController();

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
  int _peerLastDeliveredAtMs = 0;
  bool _fileUploading = false;
  double _fileUploadProgress = 0;
  String _uploadingFileName = '';
  final Map<String, ChatSenderIdentity> _senderByUid =
      <String, ChatSenderIdentity>{};
  final Set<String> _senderLoadInFlight = <String>{};

  final List<Map<String, String>> _attachments = [];
  final Set<String> _selectedMessageIds = <String>{};
  List<_MailMsg> _visibleMessages = const <_MailMsg>[];
  final Set<String> _readReceiptWriteInFlight = <String>{};
  StreamSubscription<DatabaseEvent>? _peerStateSub;

  final ImagePicker _picker = ImagePicker();

  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;
  String? _playingUrl;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _isPlaying = false;

  final AudioRecorder _rec = AudioRecorder();

  bool _recStarting = false;
  bool _recRecording = false;
  bool _recUploading = false;

  bool _recLocked = false;
  bool _recCancelling = false;

  bool _recPendingStop = false;
  bool _recPendingCancel = false;

  DateTime? _recStartedAt;
  Timer? _recTicker;
  Duration _recElapsed = Duration.zero;
  String? _recPath;

  Offset? _pressStartGlobal;

  static const double _cancelDxThreshold = 110;
  static const double _lockDyThreshold = 95;
  static const double _lockDeadzoneDx = 45;

  bool _autoFollowLatest = true;
  int _lastMessageCount = 0;
  int _lastNewestMessageAt = 0;

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  bool get _hasPendingUploads => _fileUploading;

  bool get _composerBusy =>
      _sending ||
      _recStarting ||
      _recRecording ||
      _recUploading ||
      _fileUploading;

  bool get _disableTextInput => _recStarting || _recRecording || _recUploading;
  bool get _disableAttachActions => _composerBusy || _hasPendingUploads;
  bool get _disableSendAction =>
      _sending ||
      _recStarting ||
      _recRecording ||
      _recUploading ||
      _fileUploading;
  bool get _disableMicAction => _composerBusy || _hasPendingUploads;

  @override
  void initState() {
    super.initState();
    RouteState.enterMailThread(widget.threadId);
    _messagesScrollC.addListener(_handleMessagesScroll);

    _msgStream = _msgsRef
        .orderByChild('createdAt')
        .limitToLast(_messageWindowSize)
        .onValue
        .asBroadcastStream();
    _loadSubject();
    _markRead();
    _listenPeerState();
    unawaited(_warmSenderIdentities());

    _posSub = _audio.onPositionChanged.listen((d) {
      if (!mounted) return;
      setState(() => _pos = d);
    });

    _durSub = _audio.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() => _dur = d);
    });

    _stateSub = _audio.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _isPlaying = (s == PlayerState.playing));
    });

    _completeSub = _audio.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _pos = _dur;
      });
    });
  }

  @override
  void dispose() {
    RouteState.exitMailThread(widget.threadId);
    _bodyC.dispose();
    _messagesScrollC
      ..removeListener(_handleMessagesScroll)
      ..dispose();
    _peerStateSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _audio.dispose();

    _recTicker?.cancel();
    unawaited(_rec.dispose());

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
    if (cleanUid == widget.peerUid.trim()) {
      final peer = widget.peerName.trim();
      if (peer.isNotEmpty) return peer;
    }
    return 'User';
  }

  Future<void> _warmSenderIdentities([
    Iterable<String> hintedUids = const [],
  ]) async {
    final uids = <String>{
      _meUid.trim(),
      widget.peerUid.trim(),
      ...hintedUids.map((e) => e.trim()),
    }..removeWhere((e) => e.isEmpty);
    if (uids.isEmpty) return;

    try {
      final tSnap = await _threadRef.child('participants').get();
      if (tSnap.exists && tSnap.value is Map) {
        final p = (tSnap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        for (final entry in p.entries) {
          if (entry.value == true) uids.add(entry.key.trim());
        }
      }
    } catch (_) {}

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

  Future<void> _openManageGroupMembers() async {
    final tSnap = await _threadRef.get();
    if (!tSnap.exists || tSnap.value is! Map) {
      _snack('Thread not found.');
      return;
    }
    final t = (tSnap.value as Map).map((k, v) => MapEntry(k.toString(), v));
    if (t['isGroup'] != true) {
      _snack('This is not a group thread.');
      return;
    }
    final groupName = (t['groupName'] ?? _subject).toString();
    final creatorUid = (t['createdByUid'] ?? '').toString().trim();
    final participants = await InternalMailService.loadThreadParticipants(
      widget.threadId,
    );
    final usersSnap = await _db.ref('users').get();
    final usersRaw = usersSnap.value;
    final users = <Map<String, String>>[];
    String resolveDisplayName(Map<dynamic, dynamic> m, String uid) {
      return resolveDisplayNameFromUserMap(m, uid);
    }

    if (usersRaw is Map) {
      usersRaw.forEach((uid, vv) {
        if (uid == null || vv is! Map) return;
        final id = uid.toString().trim();
        if (id.isEmpty || id == _meUid) return;
        final m = vv.map((k, v) => MapEntry(k.toString(), v));
        final name = resolveDisplayName(m, id);
        users.add({'uid': id, 'name': name});
      });
    }
    final selected = <String>{};
    var working = false;
    var addQuery = '';
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                16 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Manage members • $groupName',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: participants.map((uid) {
                      final isCreator =
                          creatorUid.isNotEmpty && creatorUid == uid;
                      final u = users.firstWhere(
                        (e) => e['uid'] == uid,
                        orElse: () => {'uid': uid, 'name': uid},
                      );
                      return InputChip(
                        avatar: isCreator
                            ? const Icon(Icons.shield_rounded, size: 16)
                            : null,
                        label: Text(
                          isCreator
                              ? '${u['name'] ?? uid} (Creator)'
                              : (u['name'] ?? uid),
                        ),
                        onDeleted: working
                            ? null
                            : () async {
                                if (isCreator) {
                                  _snack('Group creator cannot be removed.');
                                  return;
                                }
                                final shouldRemove =
                                    await showDialog<bool>(
                                      context: ctx,
                                      builder: (dialogCtx) => AlertDialog(
                                        title: const Text('Remove member?'),
                                        content: Text(
                                          'Remove ${u['name'] ?? uid} from this group?',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dialogCtx, false),
                                            child: const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(dialogCtx, true),
                                            child: const Text('Remove'),
                                          ),
                                        ],
                                      ),
                                    ) ??
                                    false;
                                if (!shouldRemove) return;
                                setLocal(() => working = true);
                                try {
                                  await InternalMailService.removeGroupMember(
                                    threadId: widget.threadId,
                                    memberUid: uid,
                                  );
                                  if (!mounted || !ctx.mounted) return;
                                  Navigator.pop(ctx);
                                  _snack('Member removed.');
                                } catch (e) {
                                  _snack('Failed to remove member: $e');
                                } finally {
                                  if (mounted) setLocal(() => working = false);
                                }
                              },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Add members',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    onChanged: (v) =>
                        setLocal(() => addQuery = v.trim().toLowerCase()),
                    decoration: const InputDecoration(
                      hintText: 'Search by member name',
                      prefixIcon: Icon(Icons.search_rounded, size: 20),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView(
                      shrinkWrap: true,
                      children: users
                          .where((u) {
                            if (participants.contains(u['uid'])) return false;
                            if (addQuery.isEmpty) return true;
                            final name = (u['name'] ?? '')
                                .toString()
                                .toLowerCase();
                            final uid = (u['uid'] ?? '')
                                .toString()
                                .toLowerCase();
                            return name.contains(addQuery) ||
                                uid.contains(addQuery);
                          })
                          .map((u) {
                            final uid = u['uid'] ?? '';
                            return CheckboxListTile(
                              value: selected.contains(uid),
                              title: Text(u['name'] ?? uid),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              onChanged: working
                                  ? null
                                  : (v) => setLocal(() {
                                      if (v == true) {
                                        selected.add(uid);
                                      } else {
                                        selected.remove(uid);
                                      }
                                    }),
                            );
                          })
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: working || selected.isEmpty
                          ? null
                          : () async {
                              setLocal(() => working = true);
                              try {
                                await InternalMailService.addGroupMembers(
                                  threadId: widget.threadId,
                                  memberUids: selected,
                                );
                                if (!mounted || !ctx.mounted) return;
                                Navigator.pop(ctx);
                                _snack('Members added.');
                              } catch (e) {
                                _snack('Failed to add members: $e');
                              } finally {
                                if (mounted) setLocal(() => working = false);
                              }
                            },
                      child: Text(
                        working ? 'Saving...' : 'Add selected members',
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _markRead() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await _stateRef.child(_meUid).child(widget.threadId).update({
        'lastDeliveredAt': now,
        'lastReadAt': now,
      });
      await _indexRef.child(_meUid).child(widget.threadId).update({
        'unreadCount': 0,
      });
    } catch (_) {}
  }

  Future<void> _deleteGroupForEveryone() async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete group for everyone?'),
            content: const Text(
              'All members will be removed and this group chat will be archived for everyone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete group'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      await InternalMailService.archiveGroupThreadForEveryone(
        threadId: widget.threadId,
        actorUid: _meUid,
        actorRole: 'admin',
      );
      if (!mounted) return;
      _snack('Group deleted and archived.');
      Navigator.of(context).pop();
    } catch (e) {
      _snack('Failed to delete group: $e');
    }
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _listenPeerState() {
    final peerUid = widget.peerUid.trim();
    if (peerUid.isEmpty) return;
    _peerStateSub = _stateRef
        .child(peerUid)
        .child(widget.threadId)
        .onValue
        .listen((event) {
          final v = event.snapshot.value;
          if (v is! Map) {
            if (!mounted) return;
            setState(() {
              _peerLastDeliveredAtMs = 0;
            });
            return;
          }
          final m = v.map((k, vv) => MapEntry(k.toString(), vv));
          if (!mounted) return;
          setState(() {
            _peerLastDeliveredAtMs = _asInt(m['lastDeliveredAt']);
          });
        });
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
                final existing = _asInt(cur);
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

  int _messageReceiptLevel(_MailMsg m) {
    if (m.fromUid != _meUid) return 0;
    final peerSeenAt = m.readBy[widget.peerUid] ?? 0;
    if (peerSeenAt > 0) return 2;
    if (_peerLastDeliveredAtMs >= m.createdAtMs && _peerLastDeliveredAtMs > 0) {
      return 1;
    }
    return 0;
  }

  String _receiptLabel(_MailMsg m) {
    if (m.fromUid != _meUid) return '';
    final peerSeenAt = m.readBy[widget.peerUid] ?? 0;
    if (peerSeenAt > 0) {
      return 'Seen ${_fmtReceiptAt(peerSeenAt)}';
    }
    if (_peerLastDeliveredAtMs >= m.createdAtMs && _peerLastDeliveredAtMs > 0) {
      return 'Delivered ${_fmtReceiptAt(_peerLastDeliveredAtMs)}';
    }
    return '';
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: Colors.black.withValues(alpha: 0.72),
            ),
          ),
        ),
      ),
    );
  }

  bool _isSameSenderNearby(List<_MailMsg> msgs, int index) {
    if (index == 0) return false;
    final current = msgs[index];
    final prev = msgs[index - 1];
    if (current.fromUid != prev.fromUid) return false;
    final diff = (current.createdAtMs - prev.createdAtMs).abs();
    return diff <= const Duration(minutes: 10).inMilliseconds;
  }

  bool _isLatestSeenOutgoing(List<_MailMsg> msgs, int index) {
    final m = msgs[index];
    if (m.fromUid != _meUid) return false;
    if (_messageReceiptLevel(m) != 2) return false;
    for (var i = index + 1; i < msgs.length; i++) {
      final newer = msgs[i];
      if (newer.fromUid == _meUid && _messageReceiptLevel(newer) == 2) {
        return false;
      }
    }
    return true;
  }

  Widget _buildSenderAvatar({required String uid, required bool mine}) {
    final senderName = _displayNameForUid(uid);
    final senderPhoto = _senderByUid[uid.trim()]?.photoUrl ?? '';
    final accent = senderAccentColor(uid);
    return ProfileAvatar(
      name: senderName,
      photoUrl: senderPhoto,
      radius: 12,
      fallbackBg: mine
          ? const Color(0xFFBBDEFB)
          : accent.withValues(alpha: 0.16),
      fallbackFg: mine ? const Color(0xFF0D3B66) : accent,
      borderColor: accent.withValues(alpha: 0.30),
    );
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
      final picked = await FilePicker.platform.pickFiles(withData: kIsWeb);
      if (picked == null || picked.files.isEmpty) {
        _snack('Upload was cancelled.');
        return;
      }
      final f = picked.files.first;
      final client = MailUploadClient.defaultClient();

      setState(() {
        _fileUploading = true;
        _fileUploadProgress = 0;
        _uploadingFileName = f.name;
      });

      String url;
      if (kIsWeb) {
        final bytes = f.bytes;
        if (bytes == null) throw Exception('Could not read file bytes.');
        if (bytes.length > MailUploadClient.maxUploadBytes) {
          throw Exception(
            'This file is too large. Maximum allowed size is 250 MB.',
          );
        }
        url = await client.uploadBytes(bytes: bytes, filename: f.name);
      } else {
        final path = f.path;
        if (path == null || path.isEmpty) {
          throw Exception('Could not read file path.');
        }
        final file = File(path);
        final size = await file.length();
        if (size > MailUploadClient.maxUploadBytes) {
          throw Exception(
            'This file is too large. Maximum allowed size is 250 MB.',
          );
        }
        url = await client.uploadFile(
          file: file,
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _fileUploadProgress = p.clamp(0.0, 1.0));
          },
        );
      }

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

  Future<void> _takePhotoAndAttach() async {
    if (_disableAttachActions) return;

    try {
      final x = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (x == null) {
        _snack('Upload was cancelled.');
        return;
      }

      final client = MailUploadClient.defaultClient();
      final name = x.name.isNotEmpty
          ? x.name
          : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';

      String url;
      if (kIsWeb) {
        final bytes = await x.readAsBytes();
        if (bytes.isEmpty) {
          _snack(
            'The selected image appears to be unreadable. Please choose another image.',
          );
          return;
        }
        url = await client.uploadBytes(bytes: bytes, filename: name);
      } else {
        url = await client.uploadFile(file: File(x.path));
      }

      if (!mounted) return;
      setState(() => _attachments.add({'name': name, 'url': url}));
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

  static bool _looksLikeAudio(String urlOrName) {
    final s = urlOrName.toLowerCase();
    final clean = s.split('?').first.split('#').first;
    return clean.endsWith('.mp3') ||
        clean.endsWith('.m4a') ||
        clean.endsWith('.aac') ||
        clean.endsWith('.wav') ||
        clean.endsWith('.ogg');
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

  Future<void> _toggleAudio(String rawUrl) async {
    final url = _safeNetworkUrl(rawUrl);
    if (url.isEmpty) return;

    try {
      if (_playingUrl != null && _playingUrl != url) {
        await _audio.stop();
        _pos = Duration.zero;
        _dur = Duration.zero;
      }

      if (_playingUrl == url && _isPlaying) {
        await _audio.pause();
        return;
      }

      _playingUrl = url;
      await _audio.play(UrlSource(url));
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback:
              'Audio playback is not available right now. Please try again.',
        ),
      );
    }
  }

  Future<void> _seekAudio(Duration to) async {
    try {
      await _audio.seek(to);
    } catch (_) {}
  }

  Future<void> _recStart(LongPressStartDetails d) async {
    if (_disableMicAction) return;

    _pressStartGlobal = d.globalPosition;
    _recStarting = true;
    _recRecording = true;
    _recUploading = false;
    _recCancelling = false;
    _recLocked = false;
    _recPendingStop = false;
    _recPendingCancel = false;
    _recElapsed = Duration.zero;
    _recStartedAt = DateTime.now();
    _recPath = null;

    if (mounted) setState(() {});

    try {
      final ok = await _rec.hasPermission();
      if (!ok) {
        _snack('Microphone permission denied.');
        _resetRecUi();
        return;
      }

      if (kIsWeb) {
        final webPath = 'rec_${DateTime.now().millisecondsSinceEpoch}.webm';
        _recPath = webPath;

        try {
          await _rec.start(
            const RecordConfig(
              encoder: AudioEncoder.opus,
              bitRate: 64000,
              sampleRate: 48000,
            ),
            path: webPath,
          );
        } catch (_) {
          final wavPath = 'rec_${DateTime.now().millisecondsSinceEpoch}.wav';
          _recPath = wavPath;

          await _rec.start(
            const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 44100),
            path: wavPath,
          );
        }
      } else {
        final tmp = await getTemporaryDirectory();
        final path =
            '${tmp.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
        _recPath = path;

        await _rec.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
          ),
          path: path,
        );
      }

      _recTicker?.cancel();
      _recTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        final start = _recStartedAt;
        if (start == null) return;
        setState(() => _recElapsed = DateTime.now().difference(start));
      });

      _recStarting = false;
      if (mounted) setState(() {});

      if (_recPendingCancel) {
        _recPendingCancel = false;
        await _recCancel();
        return;
      }
      if (_recPendingStop && !_recLocked) {
        _recPendingStop = false;
        await _recStopAndSend();
        return;
      }
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback: 'The audio recording could not start. Please try again.',
        ),
      );
      _resetRecUi();
    }
  }

  void _recMove(LongPressMoveUpdateDetails d) {
    if (!_recRecording) return;
    if (_recLocked) return;

    final start = _pressStartGlobal;
    if (start == null) return;

    final dx = d.globalPosition.dx - start.dx;
    final dy = d.globalPosition.dy - start.dy;

    final cancel = dx <= -_cancelDxThreshold;
    final lock = (dy <= -_lockDyThreshold) && (dx.abs() <= _lockDeadzoneDx);

    if (cancel != _recCancelling || lock != _recLocked) {
      setState(() {
        _recCancelling = cancel;
        _recLocked = lock;
      });
    }
  }

  Future<void> _recEnd(LongPressEndDetails d) async {
    if (!_recRecording) return;

    if (_recStarting) {
      if (_recLocked) return;
      if (_recCancelling) {
        _recPendingCancel = true;
      } else {
        _recPendingStop = true;
      }
      return;
    }

    if (_recLocked) return;

    if (_recCancelling) {
      await _recCancel();
      return;
    }

    await _recStopAndSend();
  }

  Future<void> _recLongPressCancel() async {
    if (!_recRecording) return;
    await _recCancel();
  }

  void _resetRecUi() {
    _recTicker?.cancel();
    _recTicker = null;

    _recStarting = false;
    _recRecording = false;
    _recUploading = false;

    _recLocked = false;
    _recCancelling = false;

    _recPendingStop = false;
    _recPendingCancel = false;

    _recStartedAt = null;
    _recElapsed = Duration.zero;
    _recPath = null;

    if (mounted) setState(() {});
  }

  Future<void> _recCancel() async {
    try {
      _recTicker?.cancel();
      _recTicker = null;

      await _rec.stop();

      final p = _recPath;
      if (p != null && p.trim().isNotEmpty) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
    } catch (_) {}

    _resetRecUi();
  }

  Future<void> _recStopAndSend() async {
    if (_recUploading) return;

    setState(() {
      _recUploading = true;
      _recCancelling = false;
      _recLocked = false;
    });

    try {
      _recTicker?.cancel();
      _recTicker = null;

      final pathOrUrl = await _rec.stop();
      if (pathOrUrl == null || pathOrUrl.trim().isEmpty) {
        await _recCancel();
        return;
      }

      final client = MailUploadClient.defaultClient();

      final ext = (kIsWeb && (_recPath ?? '').toLowerCase().endsWith('.wav'))
          ? 'wav'
          : (kIsWeb ? 'webm' : 'm4a');

      final name = 'audio_${DateTime.now().millisecondsSinceEpoch}.$ext';

      String url;

      if (kIsWeb) {
        final resp = await http.get(Uri.parse(pathOrUrl));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception(
            'Could not read recorded audio (HTTP ${resp.statusCode})',
          );
        }
        url = await client.uploadBytes(bytes: resp.bodyBytes, filename: name);
      } else {
        final file = File(pathOrUrl);
        url = await client.uploadFile(file: file);
      }

      if (!mounted) return;

      setState(() {
        _recStarting = false;
        _recRecording = false;
        _recUploading = false;
        _recStartedAt = null;
        _recElapsed = Duration.zero;
        _recPath = null;
        _attachments.add({'name': name, 'url': url});
      });

      await _send();
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback: 'The audio message could not be sent. Please try again.',
        ),
      );
      await _recCancel();
    } finally {
      if (mounted) {
        setState(() {
          _recUploading = false;
          _recStarting = false;
          _recRecording = false;
          _recLocked = false;
          _recCancelling = false;
          _recPendingStop = false;
          _recPendingCancel = false;
        });
      }
    }
  }

  String _fmtRec(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final mm = two(d.inMinutes.remainder(60));
    final ss = two(d.inSeconds.remainder(60));
    return '$mm:$ss';
  }

  Widget _buildCompactAudioBubble({
    required String name,
    required String url,
    required bool mine,
  }) {
    final active = (_playingUrl == url);
    final dur = active ? _dur : Duration.zero;
    final pos = active ? _pos : Duration.zero;

    double progress() {
      final msDur = dur.inMilliseconds;
      if (msDur <= 0) return 0.0;
      final v = pos.inMilliseconds / msDur;
      if (v.isNaN || v.isInfinite) return 0.0;
      return v.clamp(0.0, 1.0);
    }

    String fmt(Duration d) {
      String two(int n) => n.toString().padLeft(2, '0');
      final mm = two(d.inMinutes.remainder(60));
      final ss = two(d.inSeconds.remainder(60));
      return '$mm:$ss';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: mine
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.34),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: mine
                  ? Colors.white.withValues(alpha: 0.12)
                  : const Color(0xFF243B5A).withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => _toggleAudio(url),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: mine
                        ? Colors.white.withValues(alpha: 0.16)
                        : Colors.white.withValues(alpha: 0.78),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    (active && _isPlaying)
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: mine ? Colors.white : const Color(0xFF243B5A),
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                        color: mine ? Colors.white : const Color(0xFF243B5A),
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress(),
                        minHeight: 4,
                        backgroundColor: mine
                            ? Colors.white.withValues(alpha: 0.18)
                            : const Color(0xFF243B5A).withValues(alpha: 0.10),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Text(
                          active ? fmt(pos) : '00:00',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                            color: mine
                                ? Colors.white.withValues(alpha: 0.82)
                                : const Color(
                                    0xFF243B5A,
                                  ).withValues(alpha: 0.70),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          active && dur.inMilliseconds > 0 ? fmt(dur) : '--:--',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                            color: mine
                                ? Colors.white.withValues(alpha: 0.82)
                                : const Color(
                                    0xFF243B5A,
                                  ).withValues(alpha: 0.70),
                          ),
                        ),
                      ],
                    ),
                    if (active && dur.inMilliseconds > 0) ...[
                      const SizedBox(height: 2),
                      SizedBox(
                        height: 24,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                          ),
                          child: Slider(
                            value: pos.inMilliseconds
                                .clamp(0, dur.inMilliseconds)
                                .toDouble(),
                            min: 0,
                            max: dur.inMilliseconds.toDouble(),
                            onChanged: (v) =>
                                _seekAudio(Duration(milliseconds: v.toInt())),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
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
    final isAud = _looksLikeAudio(name) || _looksLikeAudio(url);

    Widget withDownloadAction(Widget child) {
      if (url.isEmpty) return child;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextButton.icon(
              onPressed: () => MediaDownload.downloadUrl(
                context,
                url: url,
                suggestedName: name,
                askFolder: false,
              ),
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('Download'),
              style: TextButton.styleFrom(
                visualDensity: const VisualDensity(
                  horizontal: -2,
                  vertical: -2,
                ),
                foregroundColor: mine ? Colors.white : Colors.black87,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      );
    }

    if (isImg && url.isNotEmpty) {
      return withDownloadAction(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: InkWell(
            onTap: () => _showImageViewer(url, title: name),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 220,
                  maxHeight: 150,
                ),
                child: Image.network(url, fit: BoxFit.cover),
              ),
            ),
          ),
        ),
      );
    }

    if (isVid && url.isNotEmpty) {
      return withDownloadAction(
        Padding(
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
        ),
      );
    }

    if (isAud && url.isNotEmpty) {
      return withDownloadAction(
        _buildCompactAudioBubble(name: name, url: url, mine: mine),
      );
    }

    return withDownloadAction(
      Padding(
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

  Widget _buildRecordingBar() {
    final showRecBar =
        _recStarting || _recRecording || _recLocked || _recUploading;
    if (!showRecBar) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          const Icon(Icons.mic_rounded, color: Color(0xFFEC740A)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _recUploading
                      ? 'Uploading audio…'
                      : _recLocked
                      ? 'Recording (locked)'
                      : (_recCancelling
                            ? 'Release to cancel'
                            : (_recStarting ? 'Starting…' : 'Recording…')),
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF243B5A).withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtRec(_recElapsed),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF243B5A).withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
          if (_recUploading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (!_recUploading) ...[
            IconButton(
              tooltip: 'Cancel',
              onPressed: _recCancel,
              icon: Icon(
                Icons.close_rounded,
                color: Colors.red.withValues(alpha: 0.85),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF243B5A),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _recStopAndSend,
              child: const Text('Send'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDisabledMicButton() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFF9AA6B8),
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Icon(Icons.mic_off_rounded, color: Colors.white),
    );
  }

  Widget _buildActiveMicButton() {
    return GestureDetector(
      onLongPressStart: _recStart,
      onLongPressMoveUpdate: _recMove,
      onLongPressEnd: _recEnd,
      onLongPressCancel: _recLongPressCancel,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFF7C3AED),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Icon(
          (_recRecording || _recStarting)
              ? Icons.mic_rounded
              : Icons.mic_none_rounded,
          color: Colors.white,
        ),
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
    _forceScrollToLatest();

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final tSnap = await _db.ref('mail_threads/${widget.threadId}').get();
      final tMap = tSnap.value is Map
          ? (tSnap.value as Map).map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final isGroup = tMap['isGroup'] == true;
      final msgRef = _msgsRef.push();
      final msgKey = msgRef.key!;

      final preview = bodyBackup.isEmpty ? '📎 Attachment' : bodyBackup;
      final preview80 = preview.length > 80
          ? preview.substring(0, 80)
          : preview;

      if (isGroup) {
        await InternalMailService.sendGroupMessage(
          threadId: widget.threadId,
          senderUid: _meUid,
          body: bodyBackup,
          attachments: attachmentsBackup,
        );
        unawaited(_markRead());
        _forceScrollToLatest();
        final peerLabel = widget.peerName.trim().isEmpty
            ? 'learner'
            : widget.peerName.trim();
        _snack('Mail sent to $peerLabel ✅');
        unawaited(() async {
          try {
            await PushDispatchService.dispatchMailToGroup(
              threadId: widget.threadId,
              senderUid: _meUid,
              senderName: _meName,
              title: (tMap['groupName'] ?? _subject).toString(),
              preview: preview80,
              nowMs: now,
              context: const PushDispatchContext(
                screen: 'admin/mail_topic_thread',
                action: 'mail_push_group',
              ),
            );
          } catch (_) {}
        }());
        return;
      }

      final myRole = await MailConsistencyService.resolveUserRole(
        _db,
        _meUid,
        seedRole: 'admin',
      );
      final peerRole = await MailConsistencyService.resolveUserRole(
        _db,
        widget.peerUid,
      );

      final root = _db.ref();
      final updates = <String, dynamic>{
        'mail_messages/${widget.threadId}/$msgKey': {
          'fromUid': _meUid,
          'body': bodyBackup,
          'toUids': {widget.peerUid: true},
          'ccUids': {},
          'bccUids': {},
          'attachments': attachmentsBackup,
          'createdAt': now,
          'deletedFor': {},
        },
        'mail_threads/${widget.threadId}/updatedAt': now,
        'mail_threads/${widget.threadId}/lastMessage': preview80,
        'mail_threads/${widget.threadId}/participants/$_meUid': true,
        'mail_threads/${widget.threadId}/participants/${widget.peerUid}': true,
        'mail_index/$_meUid/${widget.threadId}/subject': _subject,
        'mail_index/$_meUid/${widget.threadId}/type': 'mail',
        'mail_index/$_meUid/${widget.threadId}/updatedAt': now,
        'mail_index/$_meUid/${widget.threadId}/lastMessage': preview80,
        'mail_index/$_meUid/${widget.threadId}/unreadCount': 0,
        'mail_index/$_meUid/${widget.threadId}/peerUid': widget.peerUid,
        'mail_index/$_meUid/${widget.threadId}/peerName': widget.peerName,
        'mail_index/$_meUid/${widget.threadId}/peerRole': peerRole,
        'mail_index/$_meUid/${widget.threadId}/deletedAt': null,
        'mail_index/${widget.peerUid}/${widget.threadId}/subject': _subject,
        'mail_index/${widget.peerUid}/${widget.threadId}/type': 'mail',
        'mail_index/${widget.peerUid}/${widget.threadId}/updatedAt': now,
        'mail_index/${widget.peerUid}/${widget.threadId}/lastMessage':
            preview80,
        'mail_index/${widget.peerUid}/${widget.threadId}/peerUid': _meUid,
        'mail_index/${widget.peerUid}/${widget.threadId}/peerName': _meName,
        'mail_index/${widget.peerUid}/${widget.threadId}/peerRole': myRole,
        'mail_index/${widget.peerUid}/${widget.threadId}/deletedAt': null,
        'mail_index/${widget.peerUid}/${widget.threadId}/unreadCount':
            ServerValue.increment(1),
        'mail_state/$_meUid/${widget.threadId}/lastReadAt': now,
        'mail_state/$_meUid/${widget.threadId}/lastDeliveredAt': now,
        'mail_state/${widget.peerUid}/${widget.threadId}/lastDeliveredAt': now,
      };

      await root.update(updates);

      await MailConsistencyService.verifyMailWriteOnce(
        db: _db,
        threadId: widget.threadId,
        senderUid: _meUid,
        receiverUid: widget.peerUid,
        senderName: _meName,
        receiverName: widget.peerName,
        senderRole: myRole,
        receiverRole: peerRole,
        subject: _subject,
        lastMessage: preview80,
        now: now,
        type: 'mail',
      );

      await _indexRef.child(_meUid).child(widget.threadId).update({
        'subject': _subject,
        'updatedAt': now,
        'lastMessage': preview80,
        'unreadCount': 0,
        'peerUid': widget.peerUid,
        'peerName': widget.peerName,
        'peerRole': peerRole,
        'deletedAt': null,
      });

      // ✅ 4) mark read for me (don’t block UI if slow)
      unawaited(_markRead());
      _forceScrollToLatest();

      // ✅ 5) push notify (don’t block UI)
      unawaited(() async {
        try {
          await PushDispatchService.dispatchMailToUser(
            targetUid: widget.peerUid,
            threadId: widget.threadId,
            peerUid: _meUid,
            title: _subject,
            preview: preview80,
            nowMs: now,
            context: const PushDispatchContext(
              screen: 'admin/mail_topic_thread',
              action: 'mail_push',
            ),
          );
        } catch (_) {}
      }());
      final peerLabel = widget.peerName.trim().isEmpty
          ? 'learner'
          : widget.peerName.trim();
      _snack('Mail sent to $peerLabel ✅');
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
    final peerTitle = widget.peerName.trim().isEmpty
        ? 'User'
        : widget.peerName.trim();
    final title = _selectionMode
        ? '${_selectedMessageIds.length} selected'
        : peerTitle;

    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text(title)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    baseTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.70),
                    ),
                  ),
                ],
              ),
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
            tooltip: 'Open filtered list',
            icon: const Icon(Icons.manage_search_rounded),
            onPressed: () => openAdminFilteredPeopleList(
              context,
              peerUid: widget.peerUid,
              peerName: widget.peerName,
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'delete_topic') await _deleteThreadForMe();
              if (v == 'manage_members') await _openManageGroupMembers();
              if (v == 'delete_group_everyone') {
                await _deleteGroupForEveryone();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'manage_members',
                child: Text('Manage members'),
              ),
              PopupMenuItem(
                value: 'delete_group_everyone',
                child: Text('Delete group (everyone)'),
              ),
              PopupMenuItem(
                value: 'delete_topic',
                child: Text('Delete topic (for me)'),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF2FB),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFF1F4E79).withValues(alpha: 0.22),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.menu_book_rounded,
                          size: 18,
                          color: Color(0xFF1F4E79),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: peerTitle),
                                const TextSpan(text: ' • '),
                                TextSpan(text: _subject),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1A3958),
                            ),
                          ),
                        ),
                      ],
                    ),
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
                      return const Center(child: Text('No messages yet.'));
                    }

                    return ListView.builder(
                      controller: _messagesScrollC,
                      padding: const EdgeInsets.all(12),
                      itemCount: msgs.length,
                      itemBuilder: (_, i) {
                        final m = msgs[i];
                        final mine = m.fromUid == _meUid;
                        final scheme = Theme.of(context).colorScheme;
                        final receiptLevel = mine ? _messageReceiptLevel(m) : 0;
                        final receiptLabel = mine ? _receiptLabel(m) : '';
                        final grouped = _isSameSenderNearby(msgs, i);
                        final showSeenStatusLine = _isLatestSeenOutgoing(
                          msgs,
                          i,
                        );
                        final thisDateLabel = _dateLabel(m.createdAtMs);
                        final prevDateLabel = i > 0
                            ? _dateLabel(msgs[i - 1].createdAtMs)
                            : null;
                        final showDate =
                            i == 0 || prevDateLabel != thisDateLabel;
                        const seenBlue = Color(0xFF34B7F1);

                        return Column(
                          children: [
                            if (showDate) _dateSeparator(thisDateLabel),
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: grouped ? 4 : 10,
                              ),
                              child: GestureDetector(
                                onLongPress: () => _toggleMessageSelection(m),
                                onTap: _selectionMode
                                    ? () => _toggleMessageSelection(m)
                                    : null,
                                child: Align(
                                  alignment: mine
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (!mine && !grouped) ...[
                                        _buildSenderAvatar(
                                          uid: m.fromUid,
                                          mine: false,
                                        ),
                                        const SizedBox(width: 6),
                                      ],
                                      Column(
                                        crossAxisAlignment: mine
                                            ? CrossAxisAlignment.end
                                            : CrossAxisAlignment.start,
                                        children: [
                                          ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth: _messageMaxWidth(),
                                            ),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                border:
                                                    _selectedMessageIds
                                                        .contains(m.id)
                                                    ? Border.all(
                                                        color: Colors.orange,
                                                        width: 1.5,
                                                      )
                                                    : null,
                                              ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                      12,
                                                      10,
                                                      12,
                                                      10,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: mine
                                                      ? const Color(0xFF1F4E79)
                                                      : Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                  border: Border.all(
                                                    color: Colors.black
                                                        .withValues(
                                                          alpha: 0.08,
                                                        ),
                                                  ),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    if (m.body
                                                        .trim()
                                                        .isNotEmpty)
                                                      MarkdownBody(
                                                        data: m.body,
                                                        selectable: true,
                                                        styleSheet:
                                                            MarkdownStyleSheet(
                                                              p: TextStyle(
                                                                color: mine
                                                                    ? Colors
                                                                          .white
                                                                    : Colors
                                                                          .black87,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                height: 1.28,
                                                              ),
                                                              strong: TextStyle(
                                                                color: mine
                                                                    ? Colors
                                                                          .white
                                                                    : Colors
                                                                          .black87,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w900,
                                                              ),
                                                            ),
                                                      ),
                                                    if (m
                                                        .attachments
                                                        .isNotEmpty) ...[
                                                      if (m.body
                                                          .trim()
                                                          .isNotEmpty)
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                      ...m.attachments.map(
                                                        (a) =>
                                                            _buildAttachmentWidget(
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
                                          const SizedBox(height: 2),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                _fmtTime(m.createdAtMs),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                              ),
                                              if (mine) ...[
                                                const SizedBox(width: 4),
                                                Icon(
                                                  receiptLevel == 2
                                                      ? Icons.done_all_rounded
                                                      : (receiptLevel == 1
                                                            ? Icons
                                                                  .done_all_rounded
                                                            : Icons
                                                                  .done_rounded),
                                                  size: 15,
                                                  color: receiptLevel == 2
                                                      ? seenBlue
                                                      : scheme.onSurfaceVariant,
                                                ),
                                              ],
                                              PopupMenuButton<String>(
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
                                            ],
                                          ),
                                          if (mine &&
                                              showSeenStatusLine &&
                                              receiptLabel.startsWith('Seen '))
                                            Text(
                                              receiptLabel,
                                              style: const TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w700,
                                                color: seenBlue,
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

              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Column(
                    children: [
                      _buildFileUploadingBar(),
                      _buildRecordingBar(),
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
                              tooltip: 'Camera',
                              style: IconButton.styleFrom(
                                backgroundColor: const Color(0xFFEC740A),
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _disableAttachActions
                                  ? null
                                  : _takePhotoAndAttach,
                              icon: const Icon(Icons.photo_camera_rounded),
                            ),
                            IconButton(
                              tooltip: 'Attach',
                              style: IconButton.styleFrom(
                                backgroundColor: const Color(0xFF1F4E79),
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _disableAttachActions
                                  ? null
                                  : _pickAndUploadAttachment,
                              icon: const Icon(Icons.attach_file),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _bodyC,
                                onChanged: (_) => setState(() {}),
                                minLines: 1,
                                maxLines: 4,
                                enabled: !_disableTextInput,
                                decoration: const InputDecoration(
                                  hintText: 'Write… (Ctrl/Cmd+Enter to send)',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (_bodyC.text.trim().isNotEmpty ||
                                _attachments.isNotEmpty)
                              FilledButton(
                                onPressed: _disableSendAction ? null : _send,
                                child: Text(
                                  _sending
                                      ? 'Sending…'
                                      : (_fileUploading
                                            ? 'Uploading…'
                                            : 'Send'),
                                ),
                              )
                            else
                              (_disableMicAction
                                  ? _buildDisabledMicButton()
                                  : _buildActiveMicButton()),
                          ],
                        ),
                      ),
                      if ((_recRecording || _recStarting) &&
                          !_recLocked &&
                          !_recUploading)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: Colors.black.withValues(alpha: 0.55),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Hold to record • Swipe left to cancel • Slide up to lock',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                    color: Colors.black.withValues(alpha: 0.55),
                                  ),
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

  static String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  static String _fmtReceiptAt(int ms) {
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hhmm = '${two(d.hour)}:${two(d.minute)}';
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    if (sameDay) return hhmm;
    final month = months[(d.month - 1).clamp(0, 11)];
    return '$month ${d.day}, $hhmm';
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
