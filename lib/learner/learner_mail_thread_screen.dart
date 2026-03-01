import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/push_client.dart';
import '../services/route_state.dart';
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
  // ---------------- Logo palette ----------------
  static const Color _navy = Color(0xFF243B5A);
  static const Color _navyDark = Color(0xFF1C2F4A);
  static const Color _orange = Color(0xFFEC740A);

  static Color _mineBubbleBg(BuildContext context) => _navy;
  static Color _mineText(BuildContext context) => Colors.white;

  static Color _theirsBubbleBg(BuildContext context) => _orange.withOpacity(0.80);
  static Color _theirsText(BuildContext context) => _navyDark;

  static Color _datePillBg(BuildContext context) => Colors.white.withOpacity(0.85);
  static Color _datePillBorder(BuildContext context) => _navy.withOpacity(0.15);

  // ------------------------------------------------

  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();

  // Search within thread (local only)
  final _searchC = TextEditingController();
  bool _searching = false;

  String _meDisplayName = 'Learner';
  String _peerDisplayName = '';
  String get _peerNameShown {
    final p = _peerDisplayName.trim();
    if (p.isNotEmpty) return p;
    return widget.peerName.trim();
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

  // Camera
  final ImagePicker _picker = ImagePicker();

  // Audio playback (chat)
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  String? _playingUrl;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _isPlaying = false;

  // Audio recording (composer)
  final AudioRecorder _rec = AudioRecorder();
  bool _recRecording = false;
  bool _recLocked = false;
  bool _recCancelling = false;
  DateTime? _recStartedAt;
  Timer? _recTicker;
  Duration _recElapsed = Duration.zero;
  String? _recPath;

  // Gesture tracking (WhatsApp-ish)
  Offset? _pressStartGlobal;
  static const double _cancelDxThreshold = 90; // swipe left to cancel
  static const double _lockDyThreshold = 70; // slide up to lock

  @override
  void initState() {
    super.initState();
    RouteState.enterMailThread(widget.threadId);
    _msgStream = _msgsRef.orderByChild('createdAt').onValue.asBroadcastStream();
    _markRead();
    _loadNames();

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
  }

  @override
  void dispose() {
    RouteState.exitMailThread(widget.threadId);
    _bodyC.dispose();
    _searchC.dispose();

    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
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
    final first = (m['first_name'] ?? '').toString().trim();
    final last = (m['last_name'] ?? '').toString().trim();
    return ('$first $last').trim();
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

  Future<void> _markHomeworkSubmittedIfNeeded() async {
    try {
      final tSnap = await _db.ref('mail_threads/${widget.threadId}').get();
      if (!tSnap.exists || tSnap.value is! Map) return;

      final m = Map<String, dynamic>.from(tSnap.value as Map);
      if ((m['type'] ?? '').toString() != 'homework') return;

      final hwPath = (m['homeworkRef'] ?? '').toString().trim();
      if (hwPath.isEmpty) return;

      await _db.ref(hwPath).update({'submittedAt': ServerValue.timestamp});
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

    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs)); // newest first
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

  // ---------------- Attachments (file + camera) ----------------

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

  Future<void> _takePhotoAndAttach() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
      if (x == null) return;

      final file = File(x.path);
      final url = await MailUploadClient.defaultClient().uploadFile(file: file);

      final name = x.name.isNotEmpty ? x.name : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      setState(() => _attachments.add({'name': name, 'url': url}));
    } catch (e) {
      _snack('Camera upload failed: $e');
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

  // ---------------- Delete (for me) ----------------

  Future<void> _deleteMessageForMe(_MailMsg m) async {
    try {
      await _msgsRef.child(m.id).child('deletedFor').child(_meUid).set(true);
      _snack('Deleted for you ✅');
    } catch (e) {
      _snack('Delete failed: $e');
    }
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
        'reactions': {}, // optional
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

      // Peer unread +1
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

  // ---------------- WhatsApp-style recording ----------------

  Future<void> _recStart(LongPressStartDetails d) async {
    if (_sending) return;

    try {
      final ok = await _rec.hasPermission();
      if (!ok) {
        _snack('Microphone permission denied.');
        return;
      }

      _pressStartGlobal = d.globalPosition;
      _recCancelling = false;
      _recLocked = false;
      _recElapsed = Duration.zero;
      _recStartedAt = DateTime.now();

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

      setState(() => _recRecording = true);
    } catch (e) {
      _snack('Record failed: $e');
    }
  }

  void _recMove(LongPressMoveUpdateDetails d) {
    if (!_recRecording || _recLocked) return;
    final start = _pressStartGlobal;
    if (start == null) return;

    final dx = d.globalPosition.dx - start.dx; // left is negative
    final dy = d.globalPosition.dy - start.dy; // up is negative

    final cancel = dx <= -_cancelDxThreshold;
    final lock = dy <= -_lockDyThreshold;

    if (cancel != _recCancelling || lock != _recLocked) {
      setState(() {
        _recCancelling = cancel;
        _recLocked = lock;
      });
    }
  }

  Future<void> _recEnd(LongPressEndDetails d) async {
    if (!_recRecording) return;

    // if locked: ignore end (user will stop manually)
    if (_recLocked) return;

    if (_recCancelling) {
      await _recCancel();
      return;
    }

    await _recStopAndSend();
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

    if (!mounted) return;
    setState(() {
      _recRecording = false;
      _recLocked = false;
      _recCancelling = false;
      _recStartedAt = null;
      _recElapsed = Duration.zero;
      _recPath = null;
    });
  }

  Future<void> _recStopAndSend() async {
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

      // Upload then attach + send as a message (empty body allowed)
      final url = await MailUploadClient.defaultClient().uploadFile(file: file);
      final name = 'audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

      if (!mounted) return;
      setState(() {
        _recRecording = false;
        _recLocked = false;
        _recCancelling = false;
        _recStartedAt = null;
        _recElapsed = Duration.zero;
        _recPath = null;
        _attachments.add({'name': name, 'url': url});
      });

      // send immediately
      await _send();
    } catch (e) {
      _snack('Audio send failed: $e');
      await _recCancel();
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
    return s.endsWith('.jpg') || s.endsWith('.jpeg') || s.endsWith('.png') || s.endsWith('.webp') || s.endsWith('.gif');
  }

  static bool _looksLikeAudio(String urlOrName) {
    final s = urlOrName.toLowerCase();
    return s.endsWith('.mp3') || s.endsWith('.m4a') || s.endsWith('.aac') || s.endsWith('.wav') || s.endsWith('.ogg');
  }

  Future<void> _showImageViewer(String url, {String? title}) async {
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
                      errorBuilder: (_, __, ___) => const Text('Failed to load image', style: TextStyle(color: Colors.white)),
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

  Future<void> _toggleAudio(String url) async {
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

  // ---------------- UI helpers ----------------

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

  Widget _buildAttachmentWidget({
    required _MailMsg m,
    required Map<String, String> a,
    required bool mine,
  }) {
    final name = a['name'] ?? 'Attachment';
    final url = (a['url'] ?? '').trim();
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
                errorBuilder: (_, __, ___) => Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Image failed to load', style: TextStyle(fontWeight: FontWeight.w800, color: mine ? Colors.white : _navy)),
                ),
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
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: mine ? Colors.white.withOpacity(0.85) : _navy.withOpacity(0.75)),
                  ),
                  const Spacer(),
                  Text(
                    active && dur.inMilliseconds > 0 ? fmt(dur) : '--:--',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: mine ? Colors.white.withOpacity(0.85) : _navy.withOpacity(0.75)),
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

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    final title = _peerNameShown.isEmpty ? 'Mail' : _peerNameShown;
    final subjectTrim = widget.subject.trim();

    final showRecBar = _recRecording || _recLocked;

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
            : Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: _navy)),
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
      body: WatermarkBackground(
        child: Column(
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

                      final bubbleBg = mine ? _mineBubbleBg(context) : _theirsBubbleBg(context);
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
                                    border: Border.all(color: mine ? Colors.white.withOpacity(0.12) : _navy.withOpacity(0.08)),
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
                                              icon: Icon(Icons.more_vert_rounded, size: 18, color: mine ? Colors.white.withOpacity(0.85) : _navy.withOpacity(0.65)),
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
                              onDeleted: () => setState(() => _attachments.remove(a)),
                            );
                          }).toList(),
                        ),
                      ),

                    // Recording bar (WhatsApp-ish)
                    if (showRecBar)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.95),
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
                                    _recLocked ? 'Recording (locked)' : (_recCancelling ? 'Release to cancel' : 'Recording…'),
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
                            if (_recLocked) ...[
                              IconButton(
                                tooltip: 'Cancel',
                                onPressed: _recCancel,
                                icon: Icon(Icons.close_rounded, color: Colors.red.withOpacity(0.85)),
                              ),
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
                          onPressed: (_sending || _recRecording) ? null : _takePhotoAndAttach,
                          icon: Icon(Icons.photo_camera_rounded, color: _navy.withOpacity(0.9)),
                        ),

                        // Attach files
                        IconButton(
                          tooltip: 'Attach',
                          onPressed: (_sending || _recRecording) ? null : _pickAndUploadAttachment,
                          icon: Icon(Icons.attach_file, color: _navy.withOpacity(0.9)),
                        ),

                        Expanded(
                          child: TextField(
                            controller: _bodyC,
                            onChanged: (_) => setState(() {}),
                            minLines: 1,
                            maxLines: 4,
                            enabled: !_recRecording, // disable typing while recording (like WhatsApp)
                            decoration: InputDecoration(
                              hintText: _recRecording ? 'Recording…' : 'Message…',
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

                        // If text/attachments exist → Send button. Otherwise → Mic button (WhatsApp feel)
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
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: _navy,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(
                                _recRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),

                    // Help hint (only while recording and not locked)
                    if (_recRecording && !_recLocked)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded, size: 16, color: _navy.withOpacity(0.55)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Hold to record • Swipe left to cancel • Slide up to lock',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: _navy.withOpacity(0.55)),
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
    required this.reactions,
  });

  final String id;
  final String fromUid;
  final String body;
  final List<Map<String, String>> attachments;
  final int createdAtMs;
  final Set<String> deletedFor;

  // emoji -> set of uids
  final Map<String, Set<String>> reactions;

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
      reactions: rx,
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