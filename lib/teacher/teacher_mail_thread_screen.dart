import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/route_state.dart';
import '../services/push_client.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

class TeacherMailThreadScreen extends StatefulWidget {
  const TeacherMailThreadScreen({
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
  State<TeacherMailThreadScreen> createState() => _TeacherMailThreadScreenState();
}

class _TeacherMailThreadScreenState extends State<TeacherMailThreadScreen> {
  // ---------------- Pro palette (matches learner style) ----------------
  static const Color _navy = Color(0xFF243B5A);
  static const Color _navyDark = Color(0xFF1C2F4A);
  static const Color _orange = Color(0xFFEC740A);

  static Color _mineBubbleBg(BuildContext context, {bool isReport = false}) =>
      isReport ? Colors.deepPurple.withOpacity(0.90) : _navy;

  static Color _mineText(BuildContext context) => Colors.white;

  static Color _theirsBubbleBg(BuildContext context, {bool isReport = false}) =>
      isReport ? Colors.deepPurple.withOpacity(0.14) : _orange.withOpacity(0.80);

  static Color _theirsText(BuildContext context) => _navyDark;

  static Color _datePillBg(BuildContext context) => Colors.white.withOpacity(0.85);

  static Color _datePillBorder(BuildContext context) => _navy.withOpacity(0.15);

  // Used only to fix relative/odd media URLs. Matches your upload endpoint domain.
  static const String _uploadOrigin = 'https://www.yourbridgeschool.com';

  /// Fixes:
  /// - URLs like "//domain/path" (adds https:)
  /// - relative URLs like "/uploads/a.jpg" or "uploads/a.jpg" (adds your origin)
  /// - http:// (prefers https:// to avoid Android cleartext issues)
  /// - spaces (encodes)
  static String _safeNetworkUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';

    s = s.replaceAll('\\', '/');

    if (s.startsWith('//')) s = 'https:$s';

    final u0 = Uri.tryParse(s);
    final hasScheme = u0 != null && u0.scheme.isNotEmpty;

    if (!hasScheme) {
      if (s.startsWith('/')) {
        s = '$_uploadOrigin$s';
      } else {
        s = '$_uploadOrigin/$s';
      }
    }

    if (s.startsWith('http://')) {
      s = 'https://${s.substring('http://'.length)}';
    }

    final u1 = Uri.tryParse(s);
    if (u1 == null) return Uri.encodeFull(s);
    return u1.toString();
  }

  // ------------------------------------------------

  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();

  // Search within thread (local only)
  final _searchC = TextEditingController();
  bool _searching = false;

  String _meDisplayName = 'Teacher';
  String _peerDisplayName = '';

  String get _meUid => FirebaseAuth.instance.currentUser!.uid;

  String get _peerNameShown {
    final p = _peerDisplayName.trim();
    if (p.isNotEmpty) return p;
    final w = widget.peerName.trim();
    if (w.isNotEmpty) return w;
    return 'User';
  }

  DatabaseReference get _threadRef => _db.ref('mail_threads/${widget.threadId}');
  DatabaseReference get _msgsRef => _db.ref('mail_messages/${widget.threadId}');
  DatabaseReference get _indexRef => _db.ref('mail_index');
  DatabaseReference get _stateRef => _db.ref('mail_state');

  late final Stream<DatabaseEvent> _msgStream;

  bool _sending = false;

  // attachments in composer (not message history)
  final List<Map<String, String>> _attachments = []; // {name,url}

  // ---- learner role + courseKey (current course only) ----
  bool _peerIsLearner = false;
  bool _loadedPeerRole = false;
  String? _threadCourseKey; // for current course report stats
  bool _loadedThreadMeta = false;

  // Camera
  final ImagePicker _picker = ImagePicker();

  // Audio playback (inline)
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;
  String? _playingUrl; // normalized
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _isPlaying = false;

  // Audio recording (WhatsApp-ish composer) — FIXED like learner
  final AudioRecorder _rec = AudioRecorder();

  bool _recStarting = false; // fixes “release before start finishes”
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

  // Gesture tracking
  Offset? _pressStartGlobal;

  // thresholds tuned to avoid accidental lock/cancel
  static const double _cancelDxThreshold = 110; // swipe left to cancel
  static const double _lockDyThreshold = 95; // slide up to lock
  static const double _lockDeadzoneDx = 45; // don’t lock if also dragging sideways

  bool get _composerBusy => _sending || _recStarting || _recRecording || _recUploading;

  @override
  void initState() {
    super.initState();
    RouteState.enterMailThread(widget.threadId);

    _msgStream = _msgsRef.orderByChild('createdAt').onValue.asBroadcastStream();

    _markRead();
    _loadNames();

    _loadPeerRole();
    _loadThreadMeta();

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
    _searchC.dispose();

    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _audio.dispose();

    _recTicker?.cancel();
    unawaited(_rec.dispose());

    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String> _fetchDisplayName(String uid) async {
    final snap = await _db.ref('users/$uid').get();
    if (!snap.exists || snap.value is! Map) return '';

    final m = Map<String, dynamic>.from(snap.value as Map);
    final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
    final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
    final full = ('$first $last').trim();
    if (full.isNotEmpty) return full;

    final email = (m['email'] ?? '').toString().trim();
    return email;
  }

  Future<void> _loadNames() async {
    try {
      final me = await _fetchDisplayName(_meUid);
      final peer = await _fetchDisplayName(widget.peerUid);

      if (!mounted) return;
      setState(() {
        if (me.isNotEmpty) _meDisplayName = me;
        if (peer.isNotEmpty) _peerDisplayName = peer;
      });
    } catch (_) {}
  }

  Future<void> _loadPeerRole() async {
    try {
      final snap = await _db.ref('users/${widget.peerUid}/role').get();
      final role = (snap.value ?? '').toString().trim().toLowerCase();
      if (!mounted) return;
      setState(() {
        _peerIsLearner = (role == 'learner');
        _loadedPeerRole = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _peerIsLearner = false;
        _loadedPeerRole = true;
      });
    }
  }

  Future<void> _loadThreadMeta() async {
    try {
      final tSnap = await _threadRef.get();
      String? ck;
      if (tSnap.exists && tSnap.value is Map) {
        final t = Map<String, dynamic>.from(tSnap.value as Map);
        final raw = (t['courseKey'] ?? '').toString().trim();
        if (raw.isNotEmpty) ck = raw;
      }
      if (!mounted) return;
      setState(() {
        _threadCourseKey = ck;
        _loadedThreadMeta = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _threadCourseKey = null;
        _loadedThreadMeta = true;
      });
    }
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

  // ---------------- Parsing ----------------

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

    // Newest first (works with ListView(reverse: true))
    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return out;
  }

  List<_MailMsg> _applyLocalSearch(List<_MailMsg> msgs) {
    final q = _searchC.text.trim().toLowerCase();
    if (q.isEmpty) return msgs;

    bool attMatch(_MailMsg m) {
      for (final a in m.attachments) {
        final name = (a['name'] ?? '').toLowerCase();
        final url = (a['url'] ?? '').toLowerCase();
        if (name.contains(q) || url.contains(q)) return true;
      }
      return false;
    }

    return msgs.where((m) => m.body.toLowerCase().contains(q) || attMatch(m)).toList();
  }

  // ---------------- Attachments ----------------

  Future<void> _pickAndUploadAttachment() async {
    try {
      final picked = await FilePicker.platform.pickFiles(withData: false);
      if (picked == null || picked.files.isEmpty) return;
      final f = picked.files.first;
      if (f.path == null) return;

      final file = File(f.path!);
      final url = await MailUploadClient.defaultClient().uploadFile(file: file);

      if (!mounted) return;
      setState(() => _attachments.add({'name': f.name, 'url': url}));
    } catch (e) {
      _snack('Upload failed: $e');
    }
  }

  Future<void> _takePhotoAndAttach() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (x == null) return;

      final file = File(x.path);
      final url = await MailUploadClient.defaultClient().uploadFile(file: file);

      final name = x.name.isNotEmpty ? x.name : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      if (!mounted) return;
      setState(() => _attachments.add({'name': name, 'url': url}));
    } catch (e) {
      _snack('Camera upload failed: $e');
    }
  }

  Future<void> _openUrlExternal(String raw) async {
    final fixed = _safeNetworkUrl(raw);
    if (fixed.isEmpty) return;

    final u = Uri.tryParse(fixed);
    if (u == null) return;

    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // ---------------- Send ----------------

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
      await _sendRawMessage(
        body: bodyBackup,
        attachments: attachmentsBackup,
        updateThreadPreview: true,
        sendPush: true,
        messageType: null,
      );
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

  Map<String, dynamic> _asStringDynamicMap(dynamic cur) {
    if (cur is Map) {
      return cur.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  Future<void> _sendRawMessage({
    required String body,
    required List<Map<String, String>> attachments,
    required bool updateThreadPreview,
    required bool sendPush,
    required String? messageType,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgRef = _msgsRef.push();

    final preview = body.trim().isEmpty ? (attachments.isNotEmpty ? '📎 Attachment' : '') : body.trim();
    final preview80 = preview.length > 80 ? preview.substring(0, 80) : preview;

    final payload = <String, dynamic>{
      'fromUid': _meUid,
      'body': body,
      'toUids': {widget.peerUid: true},
      'ccUids': {},
      'bccUids': {},
      'attachments': attachments,
      'createdAt': now,
      'deletedFor': {},
      'reactions': {}, // enable reactions (same schema as learner)
    };

    if (messageType != null && messageType.trim().isNotEmpty) {
      payload['type'] = messageType.trim();
    }

    await msgRef.set(payload);

    if (updateThreadPreview) {
      await _threadRef.update({
        'updatedAt': now,
        'lastMessage': preview80,
      });

      await _indexRef.child(_meUid).child(widget.threadId).update({
        'subject': widget.subject,
        'updatedAt': now,
        'lastMessage': preview80,
        'unreadCount': 0,
        'peerUid': widget.peerUid,
        'peerName': widget.peerName,
        'deletedAt': null,
      });

      await _indexRef.child(widget.peerUid).child(widget.threadId).runTransaction((cur) {
        final m = _asStringDynamicMap(cur);

        final oldUnread = (m['unreadCount'] is num)
            ? (m['unreadCount'] as num).toInt()
            : int.tryParse((m['unreadCount'] ?? '').toString()) ?? 0;

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
    }

    if (sendPush) {
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
    }
  }

  // ---------------- Delete (for me) ----------------

  Future<void> _deleteMessageForMe(_MailMsg m) async {
    try {
      await _msgsRef.child(m.id).child('deletedFor').child(_meUid).set(true);
      _snack('Deleted for you ✅');
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  // ---------------- Reactions ----------------

  Future<void> _toggleReaction(_MailMsg m, String emoji) async {
    try {
      final path = _msgsRef.child(m.id).child('reactions').child(emoji).child(_meUid);
      final snap = await path.get();
      if (snap.exists && snap.value == true) {
        await path.remove();
      } else {
        await path.set(true);
      }
    } catch (e) {
      _snack('Reaction failed: $e');
    }
  }

  void _openMessageActions(_MailMsg m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) {
        const emojis = ['👍', '❤️', '😂', '😮', '😢', '👏'];
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('React', style: TextStyle(fontWeight: FontWeight.w900, color: _navy.withOpacity(0.9))),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: emojis.map((e) {
                  final selected = (m.reactions[e] ?? const <String>{}).contains(_meUid);
                  return InkWell(
                    onTap: () async {
                      Navigator.pop(context);
                      await _toggleReaction(m, e);
                    },
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: selected ? _orange.withOpacity(0.18) : Colors.grey.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: selected ? _orange.withOpacity(0.55) : Colors.grey.withOpacity(0.18)),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 18)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 18),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline_rounded, color: Colors.red.withOpacity(0.85)),
                title: const Text('Delete (for me)', style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.pop(context);
                  await _deleteMessageForMe(m);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReactionsRow(_MailMsg m, {required bool mine}) {
    if (m.reactions.isEmpty) return const SizedBox.shrink();

    final entries = <MapEntry<String, int>>[];
    m.reactions.forEach((emoji, uids) {
      final c = uids.length;
      if (c > 0) entries.add(MapEntry(emoji, c));
    });
    if (entries.isEmpty) return const SizedBox.shrink();

    entries.sort((a, b) => b.value.compareTo(a.value));
    final show = entries.take(4).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          children: show.map((e) {
            final selected = (m.reactions[e.key] ?? const <String>{}).contains(_meUid);
            final bg = selected ? Colors.white.withOpacity(0.22) : Colors.white.withOpacity(0.16);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: mine ? bg : Colors.black.withOpacity(0.05),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: mine ? Colors.white.withOpacity(0.22) : _navy.withOpacity(0.12)),
              ),
              child: Text(
                '${e.key} ${e.value}',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                  color: mine ? Colors.white : _navy.withOpacity(0.92),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ---------------- WhatsApp-style recording (FIXED) ----------------

  Future<void> _recStart(LongPressStartDetails d) async {
    if (_composerBusy) return;

    // Optimistic UI first (prevents “release before start finishes”)
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

      final tmp = await getTemporaryDirectory();
      final path = '${tmp.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _recPath = path;

      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      _recTicker?.cancel();
      _recTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        final start = _recStartedAt;
        if (start == null) return;
        setState(() => _recElapsed = DateTime.now().difference(start));
      });

      _recStarting = false;
      if (mounted) setState(() {});

      // If user released while still starting, finish now.
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
      _snack('Record failed: $e');
      _resetRecUi();
    }
  }

  void _recMove(LongPressMoveUpdateDetails d) {
    if (!_recRecording) return; // includes starting
    if (_recLocked) return;

    final start = _pressStartGlobal;
    if (start == null) return;

    final dx = d.globalPosition.dx - start.dx; // left is negative
    final dy = d.globalPosition.dy - start.dy; // up is negative

    final cancel = dx <= -_cancelDxThreshold;

    // lock must be a clear upward slide (not diagonal)
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

    // If still starting, defer decision until start finishes.
    if (_recStarting) {
      if (_recLocked) return;
      if (_recCancelling) {
        _recPendingCancel = true;
      } else {
        _recPendingStop = true;
      }
      return;
    }

    // Locked: ignore end (user stops manually)
    if (_recLocked) return;

    if (_recCancelling) {
      await _recCancel();
      return;
    }

    await _recStopAndSend();
  }

  Future<void> _recLongPressCancel() async {
    // Safety: if system cancels the gesture, don't leave recording running.
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
      if (p != null) {
        final f = File(p);
        if (await f.exists()) {
          await f.delete().catchError((_) {});
        }
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

      final path = await _rec.stop();
      if (path == null || path.trim().isEmpty) {
        await _recCancel();
        return;
      }

      final file = File(path);
      if (!await file.exists()) {
        await _recCancel();
        return;
      }

      final url = await MailUploadClient.defaultClient().uploadFile(file: file);
      final name = 'audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

      // cleanup local file (prevents storage leak)
      await file.delete().catchError((_) {});

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
      _snack('Audio send failed: $e');
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

  // ---------------- Inline media helpers ----------------

  static bool _looksLikeImage(String urlOrName) {
    final s = urlOrName.toLowerCase();
    return s.endsWith('.jpg') ||
        s.endsWith('.jpeg') ||
        s.endsWith('.png') ||
        s.endsWith('.webp') ||
        s.endsWith('.gif');
  }

  static bool _looksLikeAudio(String urlOrName) {
    final s = urlOrName.toLowerCase();
    return s.endsWith('.mp3') ||
        s.endsWith('.m4a') ||
        s.endsWith('.aac') ||
        s.endsWith('.wav') ||
        s.endsWith('.ogg');
  }

  Future<void> _showImageViewer(String rawUrl, {String? title}) async {
    final url = _safeNetworkUrl(rawUrl);
    if (url.isEmpty) return;
    if (!mounted) return;

    await showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.92),
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
                      errorBuilder: (_, __, ___) =>
                      const Text('Failed to load image', style: TextStyle(color: Colors.white)),
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
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                    if ((title ?? '').trim().isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          title!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
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
      _snack('Audio failed: $e');
    }
  }

  Future<void> _seekAudio(Duration to) async {
    try {
      await _audio.seek(to);
    } catch (_) {}
  }

  Widget _buildAttachmentWidget({
    required _MailMsg m,
    required Map<String, String> a,
    required bool mine,
  }) {
    final name = a['name'] ?? 'Attachment';
    final rawUrl = (a['url'] ?? '').trim();
    final url = _safeNetworkUrl(rawUrl);

    final isImg = _looksLikeImage(url) || _looksLikeImage(name);
    final isAud = _looksLikeAudio(url) || _looksLikeAudio(name);

    if (isImg && url.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          onTap: () => _showImageViewer(url, title: name),
          borderRadius: BorderRadius.circular(14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 240,
              height: 160,
              color: Colors.black.withOpacity(0.06),
              child: Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) {
                  return InkWell(
                    onTap: () => _openUrlExternal(url),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Image failed to load\nTap to open',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: mine ? Colors.white : _navy,
                        ),
                      ),
                    ),
                  );
                },
                loadingBuilder: (ctx, child, prog) {
                  if (prog == null) return child;
                  return const Center(child: CircularProgressIndicator());
                },
              ),
            ),
          ),
        ),
      );
    }

    if (isAud && url.isNotEmpty) {
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
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          width: 260,
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          decoration: BoxDecoration(
            color: mine ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.35),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: mine ? Colors.white.withOpacity(0.18) : _navy.withOpacity(0.10)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InkWell(
                    onTap: () => _toggleAudio(url),
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: mine ? Colors.white.withOpacity(0.18) : Colors.white.withOpacity(0.7),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        (active && _isPlaying) ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: mine ? Colors.white : _navy,
                        size: 26,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w900, color: mine ? Colors.white : _navy),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress(),
                minHeight: 6,
                backgroundColor: mine ? Colors.white.withOpacity(0.18) : _navy.withOpacity(0.10),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    active ? fmt(pos) : '00:00',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      color: mine ? Colors.white.withOpacity(0.85) : _navy.withOpacity(0.75),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    active && dur.inMilliseconds > 0 ? fmt(dur) : '--:--',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      color: mine ? Colors.white.withOpacity(0.85) : _navy.withOpacity(0.75),
                    ),
                  ),
                ],
              ),
              if (active && dur.inMilliseconds > 0)
                Slider(
                  value: pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble(),
                  min: 0,
                  max: dur.inMilliseconds.toDouble(),
                  onChanged: (v) => _seekAudio(Duration(milliseconds: v.toInt())),
                ),
            ],
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
          style: TextStyle(
            fontWeight: FontWeight.w800,
            decoration: TextDecoration.underline,
            color: mine ? Colors.white : _navy,
          ),
        ),
      ),
    );
  }

  // ---------------- UI helpers (date separators like learner) ----------------

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
            color: _datePillBg(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _datePillBorder(context)),
          ),
          child: Text(
            label,
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: _navy.withOpacity(0.85)),
          ),
        ),
      ),
    );
  }

  BorderRadius _bubbleRadius({required bool mine}) {
    const r = Radius.circular(18);
    const sharp = Radius.circular(6);
    return BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: mine ? r : sharp,
      bottomRight: mine ? sharp : r,
    );
  }

  static String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  // ---------- Homework evaluation + report card (UNCHANGED) ----------

  Future<void> _reviewHomeworkFromThread() async {
    try {
      final tSnap = await _threadRef.get();
      if (!tSnap.exists || tSnap.value is! Map) {
        _snack('Thread not found.');
        return;
      }

      final t = Map<String, dynamic>.from(tSnap.value as Map);
      if ((t['type'] ?? '').toString() != 'homework') {
        _snack('No Homework Found.');
        return;
      }

      final hwRefPath = (t['homeworkRef'] ?? '').toString().trim();
      if (hwRefPath.isEmpty) {
        _snack('homeworkRef missing.');
        return;
      }

      int score = 100;
      String note = '';
      String status = 'pass';
      bool needsRedo = false;

      try {
        final hwSnap = await _db.ref(hwRefPath).get();
        if (hwSnap.exists && hwSnap.value is Map) {
          final hw = Map<String, dynamic>.from(hwSnap.value as Map);

          final s = hw['reviewScore'];
          if (s is num) score = s.toInt();
          score = score.clamp(0, 100);

          note = (hw['reviewNote'] ?? '').toString();
          final st = (hw['reviewStatus'] ?? '').toString().trim();
          if (st == 'pass' || st == 'redo') status = st;

          final nr = hw['needsRedo'];
          if (nr is bool) needsRedo = nr;
        }
      } catch (_) {}

      final scoreC = TextEditingController(text: score.toString());
      final noteC = TextEditingController(text: note);

      int liveScore = score.clamp(0, 100);
      String liveGrade = _gradeFromScore(liveScore);

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) {
            void recalcGradeFromText() {
              int v = int.tryParse(scoreC.text.trim()) ?? 0;
              v = v.clamp(0, 100);
              setLocal(() {
                liveScore = v;
                liveGrade = _gradeFromScore(v);
              });
            }

            scoreC.removeListener(recalcGradeFromText);
            scoreC.addListener(recalcGradeFromText);

            return AlertDialog(
              title: const Text('Evaluate homework'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: scoreC,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Score (0-100)',
                        border: const OutlineInputBorder(),
                        helperText: 'Grade: $liveGrade',
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 170,
                      child: TextField(
                        controller: noteC,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          labelText: 'Comment',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    RadioListTile<String>(
                      value: 'pass',
                      groupValue: status,
                      onChanged: (v) => setLocal(() {
                        status = v ?? 'pass';
                        needsRedo = false;
                      }),
                      title: const Text('Pass ✅'),
                    ),
                    RadioListTile<String>(
                      value: 'redo',
                      groupValue: status,
                      onChanged: (v) => setLocal(() {
                        status = v ?? 'redo';
                        needsRedo = true;
                      }),
                      title: const Text('Redo / Do it again 🔁'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
              ],
            );
          },
        ),
      );

      if (ok != true) return;

      int parsedScore = int.tryParse(scoreC.text.trim()) ?? 0;
      parsedScore = parsedScore.clamp(0, 100);

      final grade = _gradeFromScore(parsedScore);
      final now = DateTime.now().millisecondsSinceEpoch;
      final noteText = noteC.text.trim();

      final finalNeedsRedo = (status == 'redo') ? true : false;

      await _db.ref(hwRefPath).update({
        'reviewedAt': now,
        'reviewStatus': status,
        'reviewScore': parsedScore,
        'reviewGrade': grade,
        'reviewNote': noteText,
        'needsRedo': finalNeedsRedo,
      });

      final evalText = [
        status == 'redo' ? '🔁 Homework: REDO (do it again)' : '✅ Homework: PASS',
        'Score: $parsedScore/100',
        'Grade: $grade',
        if (noteText.isNotEmpty) 'Comment: $noteText',
      ].join('\n');

      final msgRef = _msgsRef.push();
      await msgRef.set({
        'fromUid': _meUid,
        'body': evalText,
        'toUids': {widget.peerUid: true},
        'ccUids': {},
        'bccUids': {},
        'attachments': [],
        'createdAt': now,
        'deletedFor': {},
        'reactions': {},
      });

      final preview80 = evalText.length > 80 ? evalText.substring(0, 80) : evalText;

      await _threadRef.update({
        'updatedAt': now,
        'lastMessage': preview80,
      });

      await _indexRef.child(widget.peerUid).child(widget.threadId).runTransaction((cur) {
        final m = _asStringDynamicMap(cur);

        final oldUnread = (m['unreadCount'] is num)
            ? (m['unreadCount'] as num).toInt()
            : int.tryParse((m['unreadCount'] ?? '').toString()) ?? 0;

        m['subject'] = widget.subject;
        m['updatedAt'] = now;
        m['lastMessage'] = preview80;
        m['unreadCount'] = oldUnread + 1;
        m['peerUid'] = _meUid;
        m['peerName'] = _meDisplayName;
        m['deletedAt'] = null;

        return Transaction.success(m);
      });

      _snack('Saved + sent ✅');
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  // ---------- Report Card (Learner only) ----------
  Future<Map<String, dynamic>> _computeHomeworkStatsForCourse({
    required String learnerUid,
    required String courseKey,
  }) async {
    int doneCount = 0;
    int redoCount = 0;

    int reviewedCount = 0;
    int sumScore = 0;

    final gradeCounts = <String, int>{'A': 0, 'B': 0, 'C': 0, 'D': 0};

    final snap = await _db.ref('users/$learnerUid/courses/$courseKey/attendance').get();
    if (!snap.exists || snap.value is! Map) {
      return {'doneCount': 0, 'redoCount': 0, 'avgScore': 0, 'commonGrade': '—'};
    }

    final raw = Map<String, dynamic>.from(snap.value as Map);

    for (final entry in raw.entries) {
      if (entry.value is! Map) continue;
      final rec = Map<String, dynamic>.from(entry.value as Map);
      if (rec['homework'] is! Map) continue;

      final hw = Map<String, dynamic>.from(rec['homework'] as Map);

      final submittedAt = hw['submittedAt'];
      if (submittedAt != null) doneCount++;

      final needsRedo = hw['needsRedo'] == true;
      final status = (hw['reviewStatus'] ?? '').toString().trim().toLowerCase();
      if (needsRedo || status == 'redo') redoCount++;

      final reviewedAt = hw['reviewedAt'];
      if (reviewedAt != null) {
        final sc = hw['reviewScore'];
        if (sc is num) {
          reviewedCount++;
          sumScore += sc.toInt().clamp(0, 100);
        }

        final g = (hw['reviewGrade'] ?? '').toString().trim().toUpperCase();
        if (gradeCounts.containsKey(g)) {
          gradeCounts[g] = (gradeCounts[g] ?? 0) + 1;
        }
      }
    }

    final avgScore = reviewedCount == 0 ? 0 : (sumScore / reviewedCount).round();

    String commonGrade = '—';
    int best = 0;
    for (final e in gradeCounts.entries) {
      if (e.value > best) {
        best = e.value;
        commonGrade = (best == 0) ? '—' : e.key;
      }
    }

    return {
      'doneCount': doneCount,
      'redoCount': redoCount,
      'avgScore': avgScore,
      'commonGrade': commonGrade,
    };
  }

  int _clamp15(dynamic v) {
    int x = 3;
    if (v is num) x = v.toInt();
    x = x.clamp(1, 5);
    return x;
  }

  String _autoSummaryBalanced({
    required int behaviorAvg,
    required int progressAvg,
    required int homeworkDone,
    required int homeworkRedo,
    required int homeworkAvgScore,
  }) {
    String level5(int v) {
      if (v >= 4) return 'strong';
      if (v == 3) return 'steady';
      return 'developing';
    }

    final bLevel = level5(behaviorAvg);
    final pLevel = level5(progressAvg);

    final strengths = <String>[];
    final dev = <String>[];
    final rec = <String>[];

    if (behaviorAvg >= 4) {
      strengths.add('demonstrates positive classroom behavior and engagement');
    } else if (behaviorAvg == 3) {
      strengths.add('shows generally appropriate classroom behavior');
    } else {
      strengths.add('shows effort to follow classroom expectations');
    }

    if (progressAvg >= 4) {
      strengths.add('is making strong progress in language development');
    } else if (progressAvg == 3) {
      strengths.add('is making steady progress in language development');
    } else {
      strengths.add('is developing core language skills and confidence');
    }

    if (behaviorAvg <= 2) {
      dev.add('benefits from additional support with consistency, participation, and classroom routines');
    } else if (behaviorAvg == 3) {
      dev.add('can improve consistency in participation and classroom focus');
    } else {
      dev.add('should continue maintaining this positive classroom approach');
    }

    if (progressAvg <= 2) {
      dev.add('needs more practice to strengthen speaking and writing accuracy');
    } else if (progressAvg == 3) {
      dev.add('should continue building fluency and accuracy, especially in speaking and writing');
    } else {
      dev.add('should continue challenging themselves with more complex language use');
    }

    if (homeworkRedo > 0) {
      rec.add('reviewing feedback carefully and resubmitting improvements will accelerate progress');
    }
    if (homeworkDone == 0) {
      rec.add('more consistent homework completion is recommended');
    } else if (homeworkDone >= 6 && homeworkAvgScore >= 80) {
      rec.add('continuing regular practice at home will help maintain this good momentum');
    } else {
      rec.add('regular short practice at home (10–15 minutes) will support improvement');
    }

    return [
      'Strengths: The learner $bLevel in behavior and $pLevel in progress, and ${strengths.join(', ')}.',
      'Development: The learner ${dev.join(' ')}.',
      'Recommendation: ${rec.join(' ')}.',
    ].join('\n');
  }

  Future<Uint8List?> _renderWidgetToPng(GlobalKey key, {double pixelRatio = 2.5}) async {
    try {
      final ro = key.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;

      final ui.Image image = await ro.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      return byteData.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<String> _uploadPngBytes(Uint8List bytes) async {
    final dir = Directory.systemTemp;
    final file = File('${dir.path}/report_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes, flush: true);
    return MailUploadClient.defaultClient().uploadFile(file: file);
  }

  Future<void> _openReportCard() async {
    // (UNCHANGED BODY BELOW — kept intact)
    if (!_peerIsLearner) {
      _snack('Report Card is only for learners.');
      return;
    }
    if (_threadCourseKey == null || _threadCourseKey!.trim().isEmpty) {
      _snack('Course not found for this thread (courseKey missing).');
      return;
    }

    final courseKey = _threadCourseKey!.trim();

    final behaviorItems = <Map<String, dynamic>>[
      {'label': 'Respect / attitude', 'score': 3},
      {'label': 'Participation', 'score': 3},
      {'label': 'Punctuality', 'score': 3},
    ];

    final progressItems = <Map<String, dynamic>>[
      {'label': 'Speaking', 'score': 3},
      {'label': 'Listening', 'score': 3},
      {'label': 'Reading', 'score': 3},
      {'label': 'Writing', 'score': 3},
    ];

    Map<String, dynamic> autoStats = {
      'doneCount': 0,
      'redoCount': 0,
      'avgScore': 0,
      'commonGrade': '—',
    };

    bool loadingAuto = true;
    try {
      autoStats = await _computeHomeworkStatsForCourse(
        learnerUid: widget.peerUid,
        courseKey: courseKey,
      );
    } catch (_) {}
    loadingAuto = false;

    final doneC = TextEditingController(text: (autoStats['doneCount'] ?? 0).toString());
    final redoC = TextEditingController(text: (autoStats['redoCount'] ?? 0).toString());
    final avgScoreC = TextEditingController(text: (autoStats['avgScore'] ?? 0).toString());
    final commonGradeC = TextEditingController(text: (autoStats['commonGrade'] ?? '—').toString());

    final commentC = TextEditingController(text: '');

    final diagramKey = GlobalKey();

    bool sending = false;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: !sending,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget scorePicker({
            required int value,
            required ValueChanged<int> onChanged,
          }) {
            return DropdownButton<int>(
              value: value,
              isDense: true,
              items: const [1, 2, 3, 4, 5].map((n) => DropdownMenuItem<int>(value: n, child: Text('$n'))).toList(),
              onChanged: (v) {
                if (v == null) return;
                onChanged(v);
              },
            );
          }

          Widget itemRow(List<Map<String, dynamic>> list, int index) {
            final it = list[index];
            final labelC = TextEditingController(text: (it['label'] ?? '').toString());

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: labelC,
                      onChanged: (t) => it['label'] = t,
                      decoration: const InputDecoration(
                        labelText: 'Item',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  scorePicker(
                    value: _clamp15(it['score']),
                    onChanged: (v) => setLocal(() => it['score'] = v),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: () => setLocal(() {
                      if (list.length > 1) list.removeAt(index);
                    }),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            );
          }

          int avgList(List<Map<String, dynamic>> list) {
            if (list.isEmpty) return 0;
            int sum = 0;
            int n = 0;
            for (final it in list) {
              final s = _clamp15(it['score']);
              sum += s;
              n++;
            }
            return n == 0 ? 0 : (sum / n).round();
          }

          final behaviorAvg = avgList(behaviorItems);
          final progressAvg = avgList(progressItems);

          int parseInt(TextEditingController c, {int min = 0, int max = 9999}) {
            int v = int.tryParse(c.text.trim()) ?? 0;
            if (v < min) v = min;
            if (v > max) v = max;
            return v;
          }

          String parseGrade(TextEditingController c) {
            final g = c.text.trim().toUpperCase();
            if (g == 'A' || g == 'B' || g == 'C' || g == 'D') return g;
            if (g == '—' || g.isEmpty) return '—';
            return '—';
          }

          final finalDone = parseInt(doneC);
          final finalRedo = parseInt(redoC);
          final finalAvgScore = parseInt(avgScoreC, min: 0, max: 100);
          final finalCommonGrade = parseGrade(commonGradeC);

          final commentText = commentC.text.trim();

          final autoSummary = _autoSummaryBalanced(
            behaviorAvg: behaviorAvg,
            progressAvg: progressAvg,
            homeworkDone: finalDone,
            homeworkRedo: finalRedo,
            homeworkAvgScore: finalAvgScore,
          );

          final summaryLines = <String>[
            '📋 Report Card',
            'Course: $courseKey',
            'Learner: $_peerNameShown',
            'Behavior: $behaviorAvg/5 • Progress: $progressAvg/5',
            'Homework: done $finalDone • redo $finalRedo • avg $finalAvgScore/100 • common $finalCommonGrade',
            '',
            autoSummary,
            if (commentText.isNotEmpty) '\nTeacher comment: $commentText',
          ];

          return AlertDialog(
            title: const Text('Report Card'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loadingAuto)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: LinearProgressIndicator(),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Homework (auto + editable)',
                      style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: doneC,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Done count',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: redoC,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Redo count',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: avgScoreC,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Avg score (0-100)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: commonGradeC,
                          decoration: const InputDecoration(
                            labelText: 'Common grade (A/B/C/D)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Behavior (1–5)',
                          style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setLocal(() => behaviorItems.add({'label': 'New behavior item', 'score': 3})),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < behaviorItems.length; i++) itemRow(behaviorItems, i),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Behavior average: $behaviorAvg/5',
                      style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black.withOpacity(0.7)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Advancement / Progress (1–5)',
                          style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setLocal(() => progressItems.add({'label': 'New progress item', 'score': 3})),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (int i = 0; i < progressItems.length; i++) itemRow(progressItems, i),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Progress average: $progressAvg/5',
                      style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black.withOpacity(0.7)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Divider(),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Teacher comment (optional)',
                      style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 160,
                    child: TextField(
                      controller: commentC,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        labelText: 'Add a personal note…',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Divider(),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'PNG preview (watermarked)',
                      style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  RepaintBoundary(
                    key: diagramKey,
                    child: _ReportWatermarkBackground(
                      child: _ReportCardDiagramV2(
                        schoolTitle: 'REPORT CARD',
                        learnerName: _peerNameShown,
                        courseKey: courseKey,
                        createdAtMs: DateTime.now().millisecondsSinceEpoch,
                        teacherName: _meDisplayName,
                        behaviorItems: behaviorItems,
                        progressItems: progressItems,
                        behaviorAvg: behaviorAvg,
                        progressAvg: progressAvg,
                        homeworkDone: finalDone,
                        homeworkRedo: finalRedo,
                        homeworkAvgScore: finalAvgScore,
                        homeworkCommonGrade: finalCommonGrade,
                        autoSummary: autoSummary,
                        commentText: commentText,
                        reportId: 'PREVIEW',
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Message preview',
                      style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black.withOpacity(0.08)),
                    ),
                    child: Text(summaryLines.join('\n')),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: sending ? null : () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                icon: sending
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
                label: Text(sending ? 'Sending…' : 'Send report'),
                onPressed: sending
                    ? null
                    : () async {
                  setLocal(() => sending = true);

                  try {
                    final reportId = _db.ref('reports/${widget.peerUid}').push().key;
                    if (reportId == null) {
                      _snack('Failed to create report id.');
                      setLocal(() => sending = false);
                      return;
                    }

                    final now = DateTime.now().millisecondsSinceEpoch;

                    Map<String, dynamic> toItemMap(List<Map<String, dynamic>> list) {
                      String safeKey(String s) {
                        var k = s.trim();
                        k = k.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
                        k = k.replaceAll(RegExp(r'\s+'), ' ').trim();
                        if (k.isEmpty) k = 'item';
                        return k;
                      }

                      final out = <String, dynamic>{};
                      for (int i = 0; i < list.length; i++) {
                        final label = (list[i]['label'] ?? '').toString().trim();
                        if (label.isEmpty) continue;
                        final key = '${safeKey(label)}_$i';
                        out[key] = _clamp15(list[i]['score']);
                      }
                      return out;
                    }

                    final reportData = <String, dynamic>{
                      'reportId': reportId,
                      'createdAt': now,
                      'createdByUid': _meUid,
                      'createdByName': _meDisplayName,
                      'learnerUid': widget.peerUid,
                      'learnerName': _peerNameShown,
                      'threadId': widget.threadId,
                      'courseKey': courseKey,
                      'behavior': toItemMap(behaviorItems),
                      'progress': toItemMap(progressItems),
                      'homework': {
                        'auto': {
                          'doneCount': autoStats['doneCount'] ?? 0,
                          'redoCount': autoStats['redoCount'] ?? 0,
                          'avgScore': autoStats['avgScore'] ?? 0,
                          'commonGrade': (autoStats['commonGrade'] ?? '—').toString(),
                        },
                        'final': {
                          'doneCount': finalDone,
                          'redoCount': finalRedo,
                          'avgScore': finalAvgScore,
                          'commonGrade': finalCommonGrade,
                        },
                      },
                      'comment': commentText,
                      'autoSummary': autoSummary,
                      'diagramVersion': 2,
                    };

                    await _db.ref('reports/${widget.peerUid}/$reportId').set(reportData);
                    await _threadRef.child('reports').child(reportId).set(true);

                    final pngBytes = await _renderWidgetToPng(diagramKey, pixelRatio: 2.5);
                    if (pngBytes == null) {
                      _snack('Could not generate diagram image.');
                      setLocal(() => sending = false);
                      return;
                    }

                    final url = await _uploadPngBytes(pngBytes);
                    await _db.ref('reports/${widget.peerUid}/$reportId').update({'diagramUrl': url});

                    final msgBody = [
                      '📋 Report Card',
                      'Course: $courseKey',
                      'Learner: $_peerNameShown',
                      'Behavior: $behaviorAvg/5 • Progress: $progressAvg/5',
                      'Homework: done $finalDone • redo $finalRedo • avg $finalAvgScore/100 • common $finalCommonGrade',
                      '',
                      autoSummary,
                      if (commentText.isNotEmpty) '\nTeacher comment: $commentText',
                      '',
                      'Report ID: $reportId',
                    ].join('\n');

                    await _sendRawMessage(
                      body: msgBody,
                      attachments: [
                        {'name': 'ReportCard_${now}.png', 'url': url},
                      ],
                      updateThreadPreview: true,
                      sendPush: true,
                      messageType: 'report',
                    );

                    if (mounted) Navigator.pop(ctx, true);
                    _snack('Report sent ✅');
                  } catch (e, st) {
                    debugPrint('REPORT SEND FAILED: $e');
                    debugPrint('STACK TRACE:\n$st');
                    _snack('Failed: $e');
                    setLocal(() => sending = false);
                  }
                },
              ),
            ],
          );
        },
      ),
    );

    if (ok == true) {}
  }

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    final title = _peerNameShown.isEmpty ? 'Mail' : _peerNameShown;
    final subjectTrim = widget.subject.trim();

    final canReport = _peerIsLearner && (_threadCourseKey != null && _threadCourseKey!.trim().isNotEmpty);

    final showRecBar = _recStarting || _recRecording || _recLocked || _recUploading;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: _navy),
        title: _searching
            ? TextField(
          controller: _searchC,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search in this thread…',
            border: InputBorder.none,
            hintStyle: TextStyle(color: _navy.withOpacity(0.45), fontWeight: FontWeight.w700),
          ),
          style: const TextStyle(color: _navy, fontWeight: FontWeight.w900),
          onChanged: (_) => setState(() {}),
        )
            : GestureDetector(
          onLongPress: canReport ? _openReportCard : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900, color: _navy),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_loadedPeerRole && _peerIsLearner) ...[
                const SizedBox(width: 8),
                Icon(Icons.assignment_turned_in_rounded, size: 18, color: _navy.withOpacity(0.9)),
              ],
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded, color: _navy),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) _searchC.clear();
              });
            },
          ),
          IconButton(
            tooltip: 'Evaluate homework',
            icon: Icon(Icons.fact_check_rounded, color: _navy.withOpacity(0.95)),
            onPressed: _reviewHomeworkFromThread,
          ),
          if (_loadedPeerRole && _peerIsLearner)
            IconButton(
              tooltip: canReport ? 'Report card (long press title too)' : 'Report card unavailable (missing courseKey)',
              icon: Icon(Icons.analytics_rounded, color: canReport ? _navy.withOpacity(0.95) : _navy.withOpacity(0.35)),
              onPressed: canReport ? _openReportCard : null,
            ),
        ],
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
                        style: TextStyle(fontWeight: FontWeight.w900, color: _navy.withOpacity(0.92)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<DatabaseEvent>(
              stream: _msgStream,
              builder: (_, snap) {
                final msgsAll = _parseMessages(snap.data?.snapshot.value);
                final msgs = _applyLocalSearch(msgsAll);

                if (msgsAll.isEmpty) return const Center(child: Text('No mail yet.'));
                if (msgs.isEmpty) return const Center(child: Text('No results in this thread.'));

                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    final mine = m.fromUid == _meUid;

                    final thisDateLabel = _dateLabel(m.createdAtMs);
                    String? nextDateLabel;
                    if (i + 1 < msgs.length) nextDateLabel = _dateLabel(msgs[i + 1].createdAtMs);
                    final showDate = (i == msgs.length - 1) || (nextDateLabel != thisDateLabel);

                    final isReport = m.type == 'report';

                    final bubbleBg = mine
                        ? _mineBubbleBg(context, isReport: isReport)
                        : _theirsBubbleBg(context, isReport: isReport);

                    final textColor = mine ? _mineText(context) : _theirsText(context);

                    return Column(
                      children: [
                        if (showDate) _dateSeparator(thisDateLabel),
                        Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 340),
                            child: GestureDetector(
                              onLongPress: () => _openMessageActions(m),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: bubbleBg,
                                  borderRadius: _bubbleRadius(mine: mine),
                                  border: Border.all(
                                    color: isReport
                                        ? (mine ? Colors.white.withOpacity(0.25) : Colors.deepPurple.withOpacity(0.25))
                                        : (mine ? Colors.white.withOpacity(0.12) : _navy.withOpacity(0.08)),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      blurRadius: 10,
                                      offset: const Offset(0, 6),
                                      color: Colors.black.withOpacity(0.05),
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.fromLTRB(12, 10, 10, 9),
                                child: Column(
                                  crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    if (isReport && !mine) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.20),
                                          borderRadius: BorderRadius.circular(999),
                                          border: Border.all(color: Colors.white.withOpacity(0.22)),
                                        ),
                                        child: const Text(
                                          'REPORT',
                                          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Colors.white),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
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
                                    if (m.attachments.isNotEmpty) ...[
                                      if (m.body.trim().isNotEmpty) const SizedBox(height: 8),
                                      ...m.attachments.map((a) => _buildAttachmentWidget(m: m, a: a, mine: mine)),
                                    ],
                                    _buildReactionsRow(m, mine: mine),
                                    const SizedBox(height: 6),
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
                                              if (v == 'react') _openMessageActions(m);
                                              if (v == 'delete_for_me') await _deleteMessageForMe(m);
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(value: 'react', child: Text('React')),
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
                            onDeleted: _composerBusy ? null : () => setState(() => _attachments.remove(a)),
                          );
                        }).toList(),
                      ),
                    ),

                  // Recording bar (fixed + clearer states)
                  if (showRecBar)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.96),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: _navy.withOpacity(0.10)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.mic_rounded, color: _orange.withOpacity(0.95)),
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
                                      : (_recCancelling ? 'Release to cancel' : (_recStarting ? 'Starting…' : 'Recording…')),
                                  style: TextStyle(fontWeight: FontWeight.w900, color: _navy.withOpacity(0.9)),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _fmtRec(_recElapsed),
                                  style: TextStyle(fontWeight: FontWeight.w800, color: _navy.withOpacity(0.65)),
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
                              icon: Icon(Icons.close_rounded, color: Colors.red.withOpacity(0.85)),
                            ),
                            // Always allow manual stop/send => prevents “stuck recording”
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: _navy,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: _recStopAndSend,
                              child: const Text('Send'),
                            ),
                          ],
                        ],
                      ),
                    ),

                  Row(
                    children: [
                      // Camera
                      IconButton(
                        tooltip: 'Camera',
                        onPressed: _composerBusy ? null : _takePhotoAndAttach,
                        icon: Icon(Icons.photo_camera_rounded, color: _navy.withOpacity(0.9)),
                      ),

                      // Attach
                      IconButton(
                        tooltip: 'Attach',
                        onPressed: _composerBusy ? null : _pickAndUploadAttachment,
                        icon: Icon(Icons.attach_file, color: _navy.withOpacity(0.9)),
                      ),

                      Expanded(
                        child: TextField(
                          controller: _bodyC,
                          onChanged: (_) => setState(() {}),
                          minLines: 1,
                          maxLines: 4,
                          enabled: !_recRecording && !_recStarting && !_recUploading,
                          decoration: InputDecoration(
                            hintText: (_recRecording || _recStarting || _recUploading) ? 'Recording…' : 'Message…',
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

                      if (_bodyC.text.trim().isNotEmpty || _attachments.isNotEmpty)
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _navy,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          onPressed: _sending ? null : _send,
                          child: Text(_sending ? 'Sending…' : 'Send'),
                        )
                      else
                        GestureDetector(
                          onLongPressStart: _recStart,
                          onLongPressMoveUpdate: _recMove,
                          onLongPressEnd: _recEnd,
                          onLongPressCancel: _recLongPressCancel,
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: _navy,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Icon(
                              (_recRecording || _recStarting) ? Icons.mic_rounded : Icons.mic_none_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),

                  if ((_recRecording || _recStarting) && !_recLocked && !_recUploading)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded, size: 16, color: _navy.withOpacity(0.55)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Hold to record • Swipe left to cancel • Slide up to lock',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                color: _navy.withOpacity(0.55),
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
    );
  }

  String _gradeFromScore(int score) {
    final s = score.clamp(0, 100);
    if (s >= 90) return 'A';
    if (s >= 80) return 'B';
    if (s >= 70) return 'C';
    return 'D';
  }
}

/// Watermark background used INSIDE RepaintBoundary so it appears in the PNG.
/// - Center logo: very transparent
/// - Top-right logo: non-transparent
class _ReportWatermarkBackground extends StatelessWidget {
  const _ReportWatermarkBackground({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(color: Colors.white),

        // A) Transparent center watermark
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.05,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.75,
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),

        // B) Non-transparent top-right small logo
        Positioned(
          right: 10,
          top: 10,
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.95,
              child: SizedBox(
                width: 46,
                height: 46,
                child: Image.asset(
                  'assets/images/ybs_logo.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),

        child,
      ],
    );
  }
}

class _ReportCardDiagramV2 extends StatelessWidget {
  const _ReportCardDiagramV2({
    required this.schoolTitle,
    required this.learnerName,
    required this.courseKey,
    required this.createdAtMs,
    required this.teacherName,
    required this.behaviorItems,
    required this.progressItems,
    required this.behaviorAvg,
    required this.progressAvg,
    required this.homeworkDone,
    required this.homeworkRedo,
    required this.homeworkAvgScore,
    required this.homeworkCommonGrade,
    required this.autoSummary,
    required this.commentText,
    required this.reportId,
  });

  final String schoolTitle;
  final String learnerName;
  final String courseKey;
  final int createdAtMs;
  final String teacherName;

  final List<Map<String, dynamic>> behaviorItems;
  final List<Map<String, dynamic>> progressItems;

  final int behaviorAvg;
  final int progressAvg;

  final int homeworkDone;
  final int homeworkRedo;
  final int homeworkAvgScore;
  final String homeworkCommonGrade;

  final String autoSummary;
  final String commentText;
  final String reportId;

  String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  int _clamp15(dynamic v) {
    int x = 3;
    if (v is num) x = v.toInt();
    x = x.clamp(1, 5);
    return x;
  }

  String _dots(int value) {
    final v = value.clamp(1, 5);
    return List.generate(5, (i) => i < v ? '●' : '○').join();
  }

  List<Map<String, dynamic>> _capItems(List<Map<String, dynamic>> list, int max) {
    if (list.length <= max) return list;
    return list.take(max).toList();
  }

  Widget _sectionTitle(String t) {
    return Text(
      t,
      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
    );
  }

  Widget _kv(String k, String v) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$k: ', style: TextStyle(color: Colors.black.withOpacity(0.65), fontWeight: FontWeight.w800)),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w900)),
      ],
    );
  }

  Widget _itemLine(String label, int score) {
    final clean = label.trim().isEmpty ? 'Item' : label.trim();
    return Row(
      children: [
        Expanded(
          child: Text(
            clean,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
          ),
        ),
        const SizedBox(width: 10),
        Text(_dots(score), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const maxPerSection = 6;

    final bShown = _capItems(behaviorItems, maxPerSection);
    final pShown = _capItems(progressItems, maxPerSection);

    final bMore = behaviorItems.length - bShown.length;
    final pMore = progressItems.length - pShown.length;

    return Container(
      width: 360,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withOpacity(0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.black),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(schoolTitle.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 6),
            Text('Learner: $learnerName', style: const TextStyle(fontWeight: FontWeight.w900)),
            Text('Course: $courseKey', style: TextStyle(color: Colors.black.withOpacity(0.70), fontWeight: FontWeight.w800)),
            Text('Date: ${_fmtDate(createdAtMs)}',
                style: TextStyle(color: Colors.black.withOpacity(0.70), fontWeight: FontWeight.w800)),
            Text('Teacher: $teacherName',
                style: TextStyle(color: Colors.black.withOpacity(0.70), fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _kv('Behavior', '$behaviorAvg/5'),
                _kv('Progress', '$progressAvg/5'),
                _kv('HW Done', '$homeworkDone'),
                _kv('Redo', '$homeworkRedo'),
                _kv('Avg', '$homeworkAvgScore/100'),
                _kv('Grade', homeworkCommonGrade),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Behavior details'),
                      const SizedBox(height: 8),
                      for (final it in bShown)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _itemLine((it['label'] ?? '').toString(), _clamp15(it['score'])),
                        ),
                      if (bMore > 0)
                        Text(
                          '+$bMore more behavior item(s)',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black.withOpacity(0.55)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Progress details'),
                      const SizedBox(height: 8),
                      for (final it in pShown)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _itemLine((it['label'] ?? '').toString(), _clamp15(it['score'])),
                        ),
                      if (pMore > 0)
                        Text(
                          '+$pMore more progress item(s)',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black.withOpacity(0.55)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(),
            _sectionTitle('Auto summary'),
            const SizedBox(height: 6),
            Text(
              autoSummary,
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: Colors.black.withOpacity(0.85),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _sectionTitle('Teacher comment (optional)'),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black.withOpacity(0.10)),
              ),
              child: Text(
                commentText.trim().isEmpty ? '—' : commentText.trim(),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.25,
                  color: Colors.black.withOpacity(0.85),
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Report ID: $reportId',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.55)),
              ),
            ),
          ],
        ),
      ),
    );
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
    required this.type,
    required this.reactions,
  });

  final String id;
  final String fromUid;
  final String body;
  final List<Map<String, String>> attachments;
  final int createdAtMs;
  final Set<String> deletedFor;
  final String type; // '', 'report', ...

  // emoji -> set of uids
  final Map<String, Set<String>> reactions;

  factory _MailMsg.fromMap(String id, Map<String, dynamic> m) {
    int parseMs(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    // attachments can come as List OR Map (Firebase sometimes stores "lists" as maps)
    final atts = <Map<String, String>>[];
    final rawAtt = m['attachments'];
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

    final rx = <String, Set<String>>{};
    final rawRx = m['reactions'];
    if (rawRx is Map) {
      rawRx.forEach((emoji, users) {
        if (emoji == null) return;
        final set = <String>{};
        if (users is Map) {
          users.forEach((uid, ok) {
            if (uid == null) return;
            if (ok == true) set.add(uid.toString());
          });
        }
        if (set.isNotEmpty) rx[emoji.toString()] = set;
      });
    }

    return _MailMsg(
      id: id,
      fromUid: (m['fromUid'] ?? '').toString(),
      body: (m['body'] ?? '').toString(),
      attachments: atts,
      createdAtMs: parseMs(m['createdAt']),
      deletedFor: del,
      type: (m['type'] ?? '').toString().trim(),
      reactions: rx,
    );
  }
}

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