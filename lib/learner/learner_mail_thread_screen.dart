import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../services/backend_api.dart';
import '../services/push_client.dart';
import '../services/route_state.dart';
import '../shared/human_error.dart';
import '../shared/learner_web_layout.dart';
import '../shared/watermark_background.dart';
import '../shared/app_feedback.dart';
import '../shared/learner_tour_guide.dart';

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
  State<LearnerMailThreadScreen> createState() =>
      _LearnerMailThreadScreenState();
}

class _LearnerMailThreadScreenState extends State<LearnerMailThreadScreen> {
  static const int _messageWindowSize = 300;
  // ---------------- Logo palette ----------------
  static const Color _navy = Color(0xFF243B5A);
  static const Color _navyDark = Color(0xFF1C2F4A);
  static const Color _orange = Color(0xFFEC740A);

  static Color _mineBubbleBg(
    BuildContext context, {
    bool isReport = false,
    bool isHwEval = false,
  }) {
    if (isReport) return Colors.deepPurple.withValues(alpha: 0.90);
    if (isHwEval) return Colors.teal.withValues(alpha: 0.90);
    return _navy;
  }

  static Color _theirsBubbleBg(
    BuildContext context, {
    bool isReport = false,
    bool isHwEval = false,
  }) {
    if (isReport) return Colors.deepPurple.withValues(alpha: 0.14);
    if (isHwEval) return Colors.teal.withValues(alpha: 0.18);
    return _orange.withValues(alpha: 0.80);
  }

  static Color _datePillBg(BuildContext context) =>
      Colors.white.withValues(alpha: 0.88);
  static Color _datePillBorder(BuildContext context) =>
      _navy.withValues(alpha: 0.15);
  static Color _mineText(BuildContext context) => Colors.white;
  static Color _theirsText(BuildContext context) => _navyDark;

  static const String _uploadOrigin = 'https://www.yourbridgeschool.com';

  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();

  final _searchC = TextEditingController();
  bool _searching = false;

  String _meDisplayName = 'Learner';
  String _peerDisplayName = '';
  bool _isHomeworkThread = false;

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  String get _peerNameShown {
    final p = _peerDisplayName.trim();
    if (p.isNotEmpty) return p;
    return widget.peerName.trim();
  }

  DatabaseReference get _threadRef =>
      _db.ref('mail_threads/${widget.threadId}');
  DatabaseReference get _msgsRef => _db.ref('mail_messages/${widget.threadId}');
  DatabaseReference get _indexRef => _db.ref('mail_index');
  DatabaseReference get _stateRef => _db.ref('mail_state');

  late final Stream<DatabaseEvent> _msgStream;

  bool _sending = false;
  final List<Map<String, String>> _attachments = [];
  final Set<String> _selectedMessageIds = <String>{};

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
  List<_MailMsg> _visibleMessages = const <_MailMsg>[];

  bool _recStarting = false;
  bool _recRecording = false;
  bool _recUploading = false;
  bool _fileUploading = false;
  double _fileUploadProgress = 0;
  String _uploadingFileName = '';

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

  bool get _composerBusy =>
      _sending ||
      _recStarting ||
      _recRecording ||
      _recUploading ||
      _fileUploading;
  bool get _disableTextInput => _recStarting || _recRecording || _recUploading;
  bool get _disableAttachActions => _composerBusy;
  bool get _disableSendAction =>
      _sending ||
      _recStarting ||
      _recRecording ||
      _recUploading ||
      _fileUploading;
  bool get _disableMicAction => _composerBusy;
  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    RouteState.enterMailThread(widget.threadId);

    _msgStream = _msgsRef
        .orderByChild('createdAt')
        .limitToLast(_messageWindowSize)
        .onValue
        .asBroadcastStream();
    _markRead();
    _loadNames();
    _loadThreadType();

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
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(humanizeUiMessage(msg))),
    );
  }

  Map<String, dynamic> _asStringDynamicMap(dynamic cur) {
    if (cur is Map) {
      return cur.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
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
        if (peer.isNotEmpty) {
          _peerDisplayName = peer;
        } else {
          _peerDisplayName = widget.peerName;
        }
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
      await _stateRef.child(_meUid).child(widget.threadId).update({
        'lastReadAt': now,
      });
      await _indexRef.child(_meUid).child(widget.threadId).runTransaction((
        cur,
      ) {
        final map = _asStringDynamicMap(cur);
        map['lastReadAt'] = now;
        final updatedAt = _asInt(map['updatedAt']);
        if (updatedAt <= now) {
          map['unreadCount'] = 0;
        }
        return Transaction.success(map);
      });
    } catch (_) {}
  }

  bool _subjectLooksHomework(String subject) {
    return subject.trim().toLowerCase().startsWith('[hw]');
  }

  Future<void> _loadThreadType() async {
    try {
      final snap = await _threadRef.get();
      bool isHomework = _subjectLooksHomework(widget.subject);
      if (snap.exists && snap.value is Map) {
        final m = Map<String, dynamic>.from(snap.value as Map);
        final type = (m['type'] ?? '').toString().trim().toLowerCase();
        if (type == 'homework') {
          isHomework = true;
        }
      }
      if (!mounted) return;
      setState(() => _isHomeworkThread = isHomework);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isHomeworkThread = _subjectLooksHomework(widget.subject));
    }
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

    return msgs
        .where((m) => m.body.toLowerCase().contains(q) || attMatch(m))
        .toList();
  }

  Future<void> _pickAndUploadAttachment() async {
    if (_disableAttachActions) return;

    try {
      final picked = await FilePicker.platform.pickFiles(
        withData: kIsWeb,
        withReadStream: !kIsWeb,
      );
      if (picked == null || picked.files.isEmpty) {
        _snack('Upload was cancelled.');
        return;
      }

      final f = picked.files.first;
      final name = (f.name.isNotEmpty)
          ? f.name
          : 'file_${DateTime.now().millisecondsSinceEpoch}';

      if (f.size > MailUploadClient.maxUploadBytes) {
        _snack('This file is too large. Maximum allowed size is 250 MB.');
        return;
      }

      final client = MailUploadClient.defaultClient();
      if (mounted) {
        setState(() {
          _fileUploading = true;
          _fileUploadProgress = 0;
          _uploadingFileName = name;
        });
      }

      String url;
      if (kIsWeb) {
        final bytes = f.bytes;
        if (bytes == null || bytes.isEmpty) {
          _snack(
            'This file appears to be unreadable or corrupted. Please choose the file again.',
          );
          return;
        }
        url = await client.uploadBytes(
          bytes: bytes,
          filename: name,
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _fileUploadProgress = p.clamp(0.0, 1.0));
          },
        );
      } else {
        final stream = f.readStream;
        if (stream != null && f.size > 0) {
          url = await client.uploadStream(
            stream: stream,
            length: f.size,
            filename: name,
            onProgress: (p) {
              if (!mounted) return;
              setState(() => _fileUploadProgress = p.clamp(0.0, 1.0));
            },
          );
        } else {
          final path = f.path;
          if (path == null || path.trim().isEmpty) {
            _snack(
              'The app does not have permission to access this file or action.',
            );
            return;
          }
          url = await client.uploadPath(path: path, filename: name);
        }
      }

      if (!mounted) return;
      setState(() {
        _attachments.add({'name': name, 'url': url});
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
        url = await client.uploadPath(path: x.path, filename: name);
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
    final fixed = _safeNetworkUrl(raw);
    if (fixed.isEmpty) return;

    final u = Uri.tryParse(fixed);
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
          final sender = m.fromUid == _meUid ? _meDisplayName : _peerNameShown;
          return '[${_fmtTime(m.createdAtMs)}] $sender: $body';
        })
        .join('\n');

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack('Copied ${targets.length} message(s) to clipboard.');
  }

  Future<void> _send() async {
    if (_disableSendAction) return;

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
      final msgKey = msgRef.key!;

      final preview = bodyBackup.isEmpty ? '📎 Attachment' : bodyBackup;
      final preview80 = preview.length > 80
          ? preview.substring(0, 80)
          : preview;

      final payload = <String, dynamic>{
        'fromUid': _meUid,
        'body': bodyBackup,
        'toUids': {widget.peerUid: true},
        'ccUids': {},
        'bccUids': {},
        'attachments': attachmentsBackup,
        'createdAt': now,
        'deletedFor': {},
        'reactions': {},
      };

      final root = _db.ref();
      final threadPath = 'mail_threads/${widget.threadId}';
      final senderIndexPath = 'mail_index/$_meUid/${widget.threadId}';
      final teacherIndexPath =
          'mail_index/${widget.peerUid}/${widget.threadId}';

      final updates = <String, dynamic>{
        'mail_messages/${widget.threadId}/$msgKey': payload,
        '$threadPath/subject': widget.subject,
        '$threadPath/updatedAt': now,
        '$threadPath/lastMessage': preview80,
        '$threadPath/participants/$_meUid': true,
        '$threadPath/participants/${widget.peerUid}': true,
        '$threadPath/type': 'homework',
        '$senderIndexPath/subject': widget.subject,
        '$senderIndexPath/updatedAt': now,
        '$senderIndexPath/lastMessage': preview80,
        '$senderIndexPath/unreadCount': 0,
        '$senderIndexPath/peerUid': widget.peerUid,
        '$senderIndexPath/peerName': _peerNameShown,
        '$senderIndexPath/deletedAt': null,
        '$senderIndexPath/type': 'homework',
        '$teacherIndexPath/subject': widget.subject,
        '$teacherIndexPath/updatedAt': now,
        '$teacherIndexPath/lastMessage': preview80,
        '$teacherIndexPath/peerUid': _meUid,
        '$teacherIndexPath/peerName': _meDisplayName,
        '$teacherIndexPath/deletedAt': null,
        '$teacherIndexPath/type': 'homework',
        '$teacherIndexPath/unreadCount': ServerValue.increment(1),
        'mail_state/$_meUid/${widget.threadId}/lastReadAt': now,
      };

      await root.update(updates);
      await _markHomeworkSubmittedIfNeeded();

      unawaited(_markRead());

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
        url = await client.uploadPath(path: pathOrUrl, filename: name);
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

  Future<void> _toggleReaction(_MailMsg m, String emoji) async {
    try {
      final path = _msgsRef
          .child(m.id)
          .child('reactions')
          .child(emoji)
          .child(_meUid);
      final snap = await path.get();
      if (snap.exists && snap.value == true) {
        await path.remove();
      } else {
        await path.set(true);
      }
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback: 'Could not update your reaction. Please try again.',
        ),
      );
    }
  }

  void _openReactionsPicker(_MailMsg m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        const emojis = ['👍', '❤️', '😂', '😮', '😢', '👏'];
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'React',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: _navy.withValues(alpha: 0.9),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: emojis.map((e) {
                  final selected = (m.reactions[e] ?? const <String>{})
                      .contains(_meUid);
                  return InkWell(
                    onTap: () async {
                      Navigator.pop(context);
                      await _toggleReaction(m, e);
                    },
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? _orange.withValues(alpha: 0.18)
                            : Colors.grey.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: selected
                              ? _orange.withValues(alpha: 0.55)
                              : Colors.grey.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 18)),
                    ),
                  );
                }).toList(),
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

    const maxVisible = 4;
    final show = entries.take(maxVisible).toList();
    final hiddenCount = entries.length - show.length;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: mine ? WrapAlignment.end : WrapAlignment.start,
        children: [
          ...show.map((e) {
            final selected = (m.reactions[e.key] ?? const <String>{}).contains(
              _meUid,
            );
            final bg = selected
                ? _orange.withValues(alpha: 0.12)
                : Colors.grey.withValues(alpha: 0.10);

            return InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => _toggleReaction(m, e.key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: selected
                        ? _orange.withValues(alpha: 0.38)
                        : _navy.withValues(alpha: 0.10),
                  ),
                ),
                child: Text(
                  '${e.key} ${e.value}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    color: _navy.withValues(alpha: 0.92),
                  ),
                ),
              ),
            );
          }),
          if (hiddenCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '+$hiddenCount',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
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
            color: _datePillBg(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _datePillBorder(context)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: _navy.withValues(alpha: 0.85),
            ),
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

  double _messageMaxWidth(_MailMsg m) {
    final hasImage = m.attachments.any((a) {
      final name = (a['name'] ?? '').toString();
      final url = (a['url'] ?? '').toString();
      return _looksLikeImage(name) || _looksLikeImage(url);
    });

    final hasAudio = m.attachments.any((a) {
      final name = (a['name'] ?? '').toString();
      final url = (a['url'] ?? '').toString();
      return _looksLikeAudio(name) || _looksLikeAudio(url);
    });

    final hasVideo = m.attachments.any((a) {
      final name = (a['name'] ?? '').toString();
      final url = (a['url'] ?? '').toString();
      return _looksLikeVideo(name) || _looksLikeVideo(url);
    });

    if (hasImage) return 230;
    if (hasVideo) return 240;
    if (hasAudio) return 240;
    if (m.attachments.isNotEmpty && m.body.trim().isEmpty) return 240;
    return 290;
  }

  Widget _buildCompactVideoBubble({
    required String name,
    required String url,
    required bool mine,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => _showVideoViewer(url, title: name),
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Container(
            height: 140,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: mine
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.40),
              border: Border.all(
                color: mine
                    ? Colors.white.withValues(alpha: 0.15)
                    : _navy.withValues(alpha: 0.10),
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.18),
                    ),
                  ),
                ),
                Center(
                  child: Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.40),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
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
                  : _navy.withValues(alpha: 0.08),
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
                    color: mine ? Colors.white : _navy,
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
                        color: mine ? Colors.white : _navy,
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
                            : _navy.withValues(alpha: 0.10),
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
                                : _navy.withValues(alpha: 0.70),
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
                                : _navy.withValues(alpha: 0.70),
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

  Widget _buildCompactFileBubble({
    required String name,
    required String url,
    required bool mine,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => _openUrlExternal(url),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 230),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: mine
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.30),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: mine
                  ? Colors.white.withValues(alpha: 0.12)
                  : _navy.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file_rounded,
                size: 18,
                color: mine ? Colors.white : _navy,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: mine ? Colors.white : _navy,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.open_in_new_rounded,
                size: 16,
                color: mine
                    ? Colors.white.withValues(alpha: 0.90)
                    : _navy.withValues(alpha: 0.82),
              ),
            ],
          ),
        ),
      ),
    );
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
    final isVid = _looksLikeVideo(url) || _looksLikeVideo(name);
    final isAud = _looksLikeAudio(url) || _looksLikeAudio(name);

    if (isImg && url.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: InkWell(
          onTap: () => _showImageViewer(url, title: name),
          borderRadius: BorderRadius.circular(14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220, maxHeight: 160),
              child: Container(
                color: Colors.black.withValues(alpha: 0.06),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) {
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
                    return const SizedBox(
                      width: 220,
                      height: 140,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (isAud && url.isNotEmpty) {
      return _buildCompactAudioBubble(name: name, url: url, mine: mine);
    }

    if (isVid && url.isNotEmpty) {
      return _buildCompactVideoBubble(name: name, url: url, mine: mine);
    }

    return _buildCompactFileBubble(name: name, url: url, mine: mine);
  }

  Widget _buildMessageBubble(_MailMsg m, {required bool mine}) {
    final isReport = m.type == 'report';
    final isHwEval = m.type == 'homework_eval';

    final bubbleBg = mine
        ? _mineBubbleBg(context, isReport: isReport, isHwEval: isHwEval)
        : _theirsBubbleBg(context, isReport: isReport, isHwEval: isHwEval);

    final textColor = mine ? _mineText(context) : _theirsText(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: bubbleBg,
        borderRadius: _bubbleRadius(mine: mine),
        border: Border.all(
          color: isReport
              ? (mine
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.deepPurple.withValues(alpha: 0.20))
              : isHwEval
              ? (mine
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.teal.withValues(alpha: 0.22))
              : (mine
                    ? Colors.white.withValues(alpha: 0.08)
                    : _navy.withValues(alpha: 0.06)),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 6,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.04),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (isReport && !mine) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
              ),
              child: const Text(
                'REPORT',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (isHwEval && !mine) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.20),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
              ),
              child: const Text(
                'HOMEWORK REVIEW',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (m.body.trim().isNotEmpty)
            SelectableText(
              m.body,
              style: TextStyle(
                color: textColor,
                fontSize: 15,
                height: 1.30,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (m.attachments.isNotEmpty) ...[
            if (m.body.trim().isNotEmpty) const SizedBox(height: 8),
            ...m.attachments.map(
              (a) => _buildAttachmentWidget(m: m, a: a, mine: mine),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMessageMeta(_MailMsg m, {required bool mine}) {
    return Padding(
      padding: EdgeInsets.only(top: 4, left: mine ? 0 : 6, right: mine ? 6 : 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _fmtTime(m.createdAtMs),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: _navy.withValues(alpha: 0.50),
            ),
          ),
          const SizedBox(width: 2),
          PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 130),
            tooltip: 'Message actions',
            icon: Icon(
              Icons.more_horiz_rounded,
              size: 18,
              color: _navy.withValues(alpha: 0.50),
            ),
            onSelected: (v) async {
              if (v == 'react') _openReactionsPicker(m);
              if (v == 'delete_for_me') await _deleteMessageForMe(m);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'react', child: Text('React')),
              PopupMenuItem(
                value: 'delete_for_me',
                child: Text('Delete (for me)'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _isSameSenderNearby(List<_MailMsg> msgs, int index) {
    if (index == 0) return false;
    final current = msgs[index];
    final prev = msgs[index - 1];
    if (current.fromUid != prev.fromUid) return false;

    final diff = (prev.createdAtMs - current.createdAtMs).abs();
    return diff <= const Duration(minutes: 10).inMilliseconds;
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
        border: Border.all(color: _navy.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Icon(Icons.mic_rounded, color: _orange.withValues(alpha: 0.95)),
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
                    color: _navy.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtRec(_recElapsed),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _navy.withValues(alpha: 0.65),
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
                backgroundColor: _navy,
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

  Widget _buildFileUploadingBar() {
    if (!_fileUploading) return const SizedBox.shrink();
    final pct = (_fileUploadProgress * 100).clamp(0, 100).toStringAsFixed(0);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _navy.withValues(alpha: 0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.upload_file_rounded, color: _orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Uploading ${_uploadingFileName.isEmpty ? 'attachment' : _uploadingFileName}…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _navy.withValues(alpha: 0.90),
                  ),
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _navy.withValues(alpha: 0.80),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(value: _fileUploadProgress),
          ),
        ],
      ),
    );
  }

  Widget _buildDisabledMicButton() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: _navy.withValues(alpha: 0.35),
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
          color: _navy,
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

  @override
  Widget build(BuildContext context) {
    LearnerTourGuide.schedule(
      context,
      screenId: 'learner_mail_thread',
      hints: const [
        LearnerTourHint(
          title: 'المحادثة',
          line: 'يمكنك هنا متابعة الرسائل كاملة داخل الموضوع ذاته.',
        ),
        LearnerTourHint(
          title: 'الإرسال',
          line:
              'اكتب رسالتك ثم اضغط إرسال، ويمكنك أيضًا إرسال ملف صوتي أو مرفق.',
        ),
      ],
    );

    final title = _selectionMode
        ? '${_selectedMessageIds.length} selected'
        : (_peerNameShown.isEmpty ? 'Mail' : _peerNameShown);
    final subjectTrim = widget.subject.trim();
    final chipText = _isHomeworkThread
        ? (subjectTrim.isEmpty
              ? 'Homework chat'
              : 'Homework chat • $subjectTrim')
        : subjectTrim;

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
                  hintStyle: TextStyle(
                    color: _navy.withValues(alpha: 0.45),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: const TextStyle(
                  color: _navy,
                  fontWeight: FontWeight.w900,
                ),
                onChanged: (_) => setState(() {}),
              )
            : Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _navy,
                ),
              ),
        actions: [
          if (_selectionMode)
            IconButton(
              tooltip: 'Copy selected',
              icon: const Icon(Icons.copy_all_rounded, color: _navy),
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
              icon: const Icon(Icons.close_rounded, color: _navy),
              onPressed: () => setState(() => _selectedMessageIds.clear()),
            ),
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            icon: Icon(
              _searching ? Icons.close_rounded : Icons.search_rounded,
              color: _navy,
            ),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) _searchC.clear();
              });
            },
          ),
        ],
        bottom: (chipText.isEmpty)
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(46),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: _isHomeworkThread
                            ? Colors.teal.withValues(alpha: 0.13)
                            : _orange.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _isHomeworkThread
                              ? Colors.teal.withValues(alpha: 0.32)
                              : _orange.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _isHomeworkThread
                                ? Icons.assignment_rounded
                                : Icons.topic_rounded,
                            size: 18,
                            color: _isHomeworkThread
                                ? Colors.teal.withValues(alpha: 0.95)
                                : _navy.withValues(alpha: 0.9),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              chipText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: _isHomeworkThread
                                    ? Colors.teal.withValues(alpha: 0.95)
                                    : _navy.withValues(alpha: 0.92),
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
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1480,
        child: WatermarkBackground(
          child: Column(
            children: [
              Expanded(
                child: StreamBuilder<DatabaseEvent>(
                  stream: _msgStream,
                  builder: (_, snap) {
                    if (snap.hasError) {
                      return const Center(
                        child: Text(
                          'Could not load messages. Check your internet.',
                        ),
                      );
                    }
                    if (snap.connectionState == ConnectionState.waiting &&
                        !snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final msgsAll = _parseMessages(snap.data?.snapshot.value);
                    final msgs = _applyLocalSearch(msgsAll);
                    _visibleMessages = msgs;

                    if (msgsAll.isEmpty)
                      return const Center(child: Text('No mail yet.'));
                    if (msgs.isEmpty)
                      return const Center(
                        child: Text('No results in this thread.'),
                      );

                    return ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      itemCount: msgs.length,
                      itemBuilder: (_, i) {
                        final m = msgs[i];
                        final mine = m.fromUid == _meUid;

                        final thisDateLabel = _dateLabel(m.createdAtMs);
                        String? nextDateLabel;
                        if (i + 1 < msgs.length) {
                          nextDateLabel = _dateLabel(msgs[i + 1].createdAtMs);
                        }
                        final showDate =
                            (i == msgs.length - 1) ||
                            (nextDateLabel != thisDateLabel);

                        final grouped = _isSameSenderNearby(msgs, i);

                        return Column(
                          children: [
                            if (showDate) _dateSeparator(thisDateLabel),
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: grouped ? 4 : 10,
                              ),
                              child: Align(
                                alignment: mine
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: GestureDetector(
                                  onLongPress: () => _toggleMessageSelection(m),
                                  onTap: _selectionMode
                                      ? () => _toggleMessageSelection(m)
                                      : null,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: mine
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border:
                                              _selectedMessageIds.contains(m.id)
                                              ? Border.all(
                                                  color: _orange,
                                                  width: 1.5,
                                                )
                                              : null,
                                        ),
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth: _messageMaxWidth(m),
                                          ),
                                          child: _buildMessageBubble(
                                            m,
                                            mine: mine,
                                          ),
                                        ),
                                      ),
                                      if (m.reactions.isNotEmpty)
                                        _buildReactionsRow(m, mine: mine),
                                      _buildMessageMeta(m, mine: mine),
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
                      if (_attachments.isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _attachments.map((a) {
                              return Chip(
                                label: Text(a['name'] ?? 'file'),
                                onDeleted: _composerBusy
                                    ? null
                                    : () => setState(
                                        () => _attachments.remove(a),
                                      ),
                              );
                            }).toList(),
                          ),
                        ),

                      _buildRecordingBar(),
                      _buildFileUploadingBar(),

                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Camera',
                            onPressed: _disableAttachActions
                                ? null
                                : _takePhotoAndAttach,
                            icon: Icon(
                              Icons.photo_camera_rounded,
                              color: _navy.withValues(alpha: 0.9),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Attach',
                            onPressed: _disableAttachActions
                                ? null
                                : _pickAndUploadAttachment,
                            icon: Icon(
                              Icons.attach_file,
                              color: _navy.withValues(alpha: 0.9),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _bodyC,
                              onChanged: (_) => setState(() {}),
                              minLines: 1,
                              maxLines: 4,
                              enabled: !_disableTextInput,
                              decoration: InputDecoration(
                                hintText:
                                    (_recRecording ||
                                        _recStarting ||
                                        _recUploading)
                                    ? 'Recording…'
                                    : 'Message…',
                                filled: true,
                                fillColor: Colors.white.withValues(alpha: 0.92),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide(
                                    color: _navy.withValues(alpha: 0.15),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide(
                                    color: _navy.withValues(alpha: 0.12),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: BorderSide(
                                    color: _orange.withValues(alpha: 0.65),
                                    width: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_bodyC.text.trim().isNotEmpty ||
                              _attachments.isNotEmpty)
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: _navy,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              onPressed: _disableSendAction ? null : _send,
                              child: Text(
                                _sending
                                    ? 'Sending…'
                                    : (_fileUploading ? 'Uploading…' : 'Send'),
                              ),
                            )
                          else
                            (_disableMicAction
                                ? _buildDisabledMicButton()
                                : _buildActiveMicButton()),
                        ],
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
                                color: _navy.withValues(alpha: 0.55),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Hold to record • Swipe left to cancel • Slide up to lock',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                    color: _navy.withValues(alpha: 0.55),
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
  final String type;
  final Map<String, Set<String>> reactions;

  factory _MailMsg.fromMap(String id, Map<String, dynamic> m) {
    int parseMs(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

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

  Future<String> uploadBytes({
    required List<int> bytes,
    required String filename,
    void Function(double progress)? onProgress,
  }) async {
    if (bytes.isEmpty) throw Exception('Could not read selected file bytes.');
    if (bytes.length > maxUploadBytes) {
      throw Exception('File is too large. Maximum allowed size is 250 MB.');
    }
    return uploadStream(
      stream: _chunkBytes(bytes),
      length: bytes.length,
      filename: filename,
      onProgress: onProgress,
    );
  }

  Future<String> uploadStream({
    required Stream<List<int>> stream,
    required int length,
    required String filename,
    void Function(double progress)? onProgress,
  }) async {
    if (length <= 0) {
      throw Exception('Could not read selected file bytes.');
    }
    if (length > maxUploadBytes) {
      throw Exception('File is too large. Maximum allowed size is 250 MB.');
    }

    final uri = await BackendApi.withAuthQuery(Uri.parse(endpoint));
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');
    final token = await BackendApi.authToken();

    var sent = 0;
    onProgress?.call(0);
    final tracked = stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          if (length > 0) {
            onProgress?.call((sent / length).clamp(0.0, 1.0));
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
        http.MultipartFile('file', tracked, length, filename: filename),
      );

    final streamed = await _http.send(req).timeout(const Duration(minutes: 10));
    final body = await streamed.stream.bytesToString().timeout(
      const Duration(minutes: 10),
    );

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('Upload failed: HTTP ${streamed.statusCode}\n$body');
    }

    final decoded = _tryDecodeJson(body);
    if (decoded == null) throw Exception('Upload failed: invalid JSON\n$body');

    final ok = decoded['success'] == true;
    final url = (decoded['url'] ?? '').toString();
    if (!ok || url.trim().isEmpty) throw Exception('Upload failed: $decoded');

    onProgress?.call(1);

    return url;
  }

  Future<String> uploadPath({
    required String path,
    required String filename,
  }) async {
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
      ..files.add(
        await http.MultipartFile.fromPath('file', path, filename: filename),
      );

    if (req.files.isEmpty || req.files.first.length > maxUploadBytes) {
      throw Exception('File is too large. Maximum allowed size is 250 MB.');
    }

    final streamed = await _http.send(req).timeout(const Duration(minutes: 10));
    final body = await streamed.stream.bytesToString().timeout(
      const Duration(minutes: 10),
    );

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

  static Stream<List<int>> _chunkBytes(
    List<int> bytes, {
    int size = 64 * 1024,
  }) async* {
    for (var i = 0; i < bytes.length; i += size) {
      final end = (i + size < bytes.length) ? i + size : bytes.length;
      yield bytes.sublist(i, end);
    }
  }
}
