import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../services/route_state.dart';
import '../services/push_client.dart';
import '../utils/io_delete.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../services/backend_api.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';

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
  State<TeacherMailThreadScreen> createState() =>
      _TeacherMailThreadScreenState();
}

class _TeacherMailThreadScreenState extends State<TeacherMailThreadScreen> {
  static const int _messageWindowSize = 300;
  // ---------------- Pro palette (matches learner style) ----------------
  static const Color _navy = Color(0xFF243B5A);
  static const Color _navyDark = Color(0xFF1C2F4A);
  static const Color _orange = Color(0xFFEC740A);

  static Color _mineBubbleBg(BuildContext context, {bool isReport = false}) =>
      isReport ? Colors.deepPurple.withValues(alpha: 0.90) : _navy;

  static Color _mineText(BuildContext context) => Colors.white;

  static Color _theirsBubbleBg(BuildContext context, {bool isReport = false}) =>
      isReport
      ? Colors.deepPurple.withValues(alpha: 0.14)
      : _orange.withValues(alpha: 0.80);

  static Color _theirsText(BuildContext context) => _navyDark;

  static Color _datePillBg(BuildContext context) =>
      Colors.white.withValues(alpha: 0.85);

  static Color _datePillBorder(BuildContext context) =>
      _navy.withValues(alpha: 0.15);

  static const String _uploadOrigin = 'https://www.yourbridgeschool.com';

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

  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();

  final _searchC = TextEditingController();
  bool _searching = false;

  String _meDisplayName = 'Teacher';
  String _peerDisplayName = '';

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  String get _peerNameShown {
    final p = _peerDisplayName.trim();
    if (p.isNotEmpty) return p;
    final w = widget.peerName.trim();
    if (w.isNotEmpty) return w;
    return 'User';
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
  List<_MailMsg> _visibleMessages = const <_MailMsg>[];
  final List<_ComposerUploadItem> _uploadingItems = [];

  bool _peerIsLearner = false;
  bool _loadedPeerRole = false;
  String? _threadCourseKey;
  bool _loadedThreadMeta = false;
  String? _threadCourseTitle;
  Map<String, String> _learnerCourseTitles = {};
  bool _loadingLearnerCourses = false;
  bool _loadedLearnerCourses = false;

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

  bool get _hasPendingUploads => _uploadingItems.isNotEmpty;

  bool get _composerBusy =>
      _sending || _recStarting || _recRecording || _recUploading;

  bool get _disableTextInput => _recStarting || _recRecording || _recUploading;
  bool get _disableAttachActions => _composerBusy || _hasPendingUploads;
  bool get _disableSendAction =>
      _sending ||
      _recStarting ||
      _recRecording ||
      _recUploading ||
      _hasPendingUploads;
  bool get _disableMicAction => _composerBusy || _hasPendingUploads;
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
    _loadPeerRole();
    _loadThreadMeta();
    _loadLearnerCoursesTitles();

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

  String _nameFromUserMap(Map<String, dynamic> m) {
    final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
    final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
    final full = ('$first $last').trim();
    if (full.isNotEmpty) return full;

    final fallback =
        (m['learnerName'] ?? m['peerName'] ?? m['name'] ?? m['email'] ?? '')
            .toString()
            .trim();
    return fallback;
  }

  Future<void> _loadNames() async {
    try {
      final me = await _fetchDisplayName(_meUid);
      String peer = await _fetchDisplayName(widget.peerUid);

      if (peer.trim().isEmpty) {
        final idxSnap = await _indexRef
            .child(_meUid)
            .child(widget.threadId)
            .get();
        if (idxSnap.exists && idxSnap.value is Map) {
          final m = Map<String, dynamic>.from(idxSnap.value as Map);
          peer = _nameFromUserMap(m);
        }
      }

      if (peer.trim().isEmpty) {
        final tSnap = await _threadRef.get();
        if (tSnap.exists && tSnap.value is Map) {
          final m = Map<String, dynamic>.from(tSnap.value as Map);
          peer = _nameFromUserMap(m);
        }
      }

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
      Map<String, dynamic> t = {};
      String? ck;

      if (tSnap.exists && tSnap.value is Map) {
        t = Map<String, dynamic>.from(tSnap.value as Map);

        String pickKey(Map<String, dynamic> t) {
          final candidates = [
            'courseKey',
            'coureKey',
            'courekey',
            'course_key',
            'courseId',
            'course_id',
            'course',
          ];

          for (final k in candidates) {
            final v = (t[k] ?? '').toString().trim();
            if (v.isNotEmpty) return v;
          }

          if (t['meta'] is Map) {
            final meta = Map<String, dynamic>.from(t['meta'] as Map);
            for (final k in candidates) {
              final v = (meta[k] ?? '').toString().trim();
              if (v.isNotEmpty) return v;
            }
          }

          return '';
        }

        final raw = pickKey(t);
        if (raw.isNotEmpty) ck = _normalizeCourseKey(raw);
      }

      if (ck == null || ck.trim().isEmpty) {
        final hwRefPath = (t['homeworkRef'] ?? '').toString().trim();

        if (hwRefPath.isNotEmpty) {
          try {
            final hwSnap = await _db.ref(hwRefPath).get();
            if (hwSnap.exists && hwSnap.value is Map) {
              final hw = Map<String, dynamic>.from(hwSnap.value as Map);

              final hwCk =
                  (hw['courseKey'] ??
                          hw['course_id'] ??
                          hw['courseId'] ??
                          hw['course_key'] ??
                          '')
                      .toString()
                      .trim();

              if (hwCk.isNotEmpty) ck = _normalizeCourseKey(hwCk);
            }

            if (ck == null || ck.trim().isEmpty) {
              final m = RegExp(r'/courses/([^/]+)/').firstMatch(hwRefPath);
              if (m != null) ck = m.group(1);
            }
          } catch (_) {}
        }
      }

      String? title;

      if (ck != null && ck.trim().isNotEmpty) {
        final key = ck.trim();

        final c1 = await _db.ref('courses/$key/title').get();
        title = (c1.value ?? '').toString().trim();

        if (title.isEmpty) {
          final cName = await _db.ref('courses/$key/name').get();
          title = (cName.value ?? '').toString().trim();
        }

        if (title.isEmpty) {
          final fixed = key.replaceAll('coure_', 'course_');
          if (fixed != key) {
            final c2 = await _db.ref('courses/$fixed/title').get();
            final t2 = (c2.value ?? '').toString().trim();
            if (t2.isNotEmpty) {
              ck = fixed;
              title = t2;
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _threadCourseKey = ck;
        _threadCourseTitle = (title != null && title.isNotEmpty) ? title : null;
        _loadedThreadMeta = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _threadCourseKey = null;
        _threadCourseTitle = null;
        _loadedThreadMeta = true;
      });
    }
  }

  Future<void> _loadLearnerCoursesTitles() async {
    if (_loadingLearnerCourses || _loadedLearnerCourses) return;

    setState(() {
      _loadingLearnerCourses = true;
    });

    try {
      final snap = await _db.ref('users/${widget.peerUid}/courses').get();

      final Map<String, String> out = {};

      if (snap.exists && snap.value is Map) {
        final coursesMap = Map<String, dynamic>.from(snap.value as Map);

        for (final entry in coursesMap.entries) {
          final ck = entry.key.toString().trim();
          if (ck.isEmpty) continue;

          String title = '';

          if (entry.value is Map) {
            final m = Map<String, dynamic>.from(entry.value as Map);
            title = (m['title'] ?? m['name'] ?? m['course_title'] ?? '')
                .toString()
                .trim();
          }

          if (title.isEmpty) {
            final t1 = await _db.ref('courses/$ck/title').get();
            title = (t1.value ?? '').toString().trim();

            if (title.isEmpty) {
              final t2 = await _db.ref('courses/$ck/name').get();
              title = (t2.value ?? '').toString().trim();
            }
          }

          if (title.isNotEmpty) out[ck] = title;
        }
      }

      if (!mounted) return;

      setState(() {
        _learnerCourseTitles = out;
        _loadedLearnerCourses = true;
        _loadingLearnerCourses = false;

        final ck = _threadCourseKey?.trim() ?? '';
        if ((_threadCourseTitle == null ||
                _threadCourseTitle!.trim().isEmpty) &&
            ck.isNotEmpty) {
          final t = out[ck];
          if (t != null && t.trim().isNotEmpty) _threadCourseTitle = t.trim();
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingLearnerCourses = false;
        _loadedLearnerCourses = true;
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

  String _newUploadId() => DateTime.now().microsecondsSinceEpoch.toString();

  void _addUploadPlaceholder(String id, String name) {
    if (!mounted) return;
    setState(() {
      _uploadingItems.add(_ComposerUploadItem(id: id, name: name, progress: 0));
    });
  }

  void _setUploadProgress(String id, double progress) {
    if (!mounted) return;
    final p = progress.clamp(0.0, 1.0);
    setState(() {
      final i = _uploadingItems.indexWhere((e) => e.id == id);
      if (i < 0) return;
      final item = _uploadingItems[i];
      _uploadingItems[i] = item.copyWith(progress: p);
    });
  }

  void _finishUploadPlaceholder(String id) {
    if (!mounted) return;
    setState(() {
      _uploadingItems.removeWhere((e) => e.id == id);
    });
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

      final uploadId = _newUploadId();

      _addUploadPlaceholder(uploadId, name);

      final client = MailUploadClient.defaultClient();

      String url;
      if (kIsWeb) {
        final bytes = f.bytes;
        if (bytes == null || bytes.isEmpty) {
          _finishUploadPlaceholder(uploadId);
          _snack(
            'This file appears to be unreadable or corrupted. Please choose the file again.',
          );
          return;
        }
        url = await client.uploadBytes(
          bytes: bytes,
          filename: name,
          onProgress: (p) => _setUploadProgress(uploadId, p),
        );
      } else {
        final stream = f.readStream;
        if (stream != null && f.size > 0) {
          url = await client.uploadStream(
            stream: stream,
            length: f.size,
            filename: name,
            onProgress: (p) => _setUploadProgress(uploadId, p),
          );
        } else {
          final path = f.path;
          if (path == null || path.trim().isEmpty) {
            _finishUploadPlaceholder(uploadId);
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
        _uploadingItems.removeWhere((e) => e.id == uploadId);
        _attachments.add({'name': name, 'url': url});
      });
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback:
              'Something unexpected happened while sending the file. Please try again.',
        ),
      );
      if (mounted) {
        setState(() {
          _uploadingItems.clear();
        });
      }
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
      final uploadId = _newUploadId();

      _addUploadPlaceholder(uploadId, name);

      String url;
      if (kIsWeb) {
        final bytes = await x.readAsBytes();
        if (bytes.isEmpty) {
          _finishUploadPlaceholder(uploadId);
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
      setState(() {
        _uploadingItems.removeWhere((e) => e.id == uploadId);
        _attachments.add({'name': name, 'url': url});
      });
    } catch (e) {
      _snack(
        toHumanError(
          e,
          fallback:
              'Something unexpected happened while sending the file. Please try again.',
        ),
      );
      if (mounted) {
        setState(() {
          _uploadingItems.clear();
        });
      }
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

  Future<void> _sendRawMessage({
    required String body,
    required List<Map<String, String>> attachments,
    required bool updateThreadPreview,
    required bool sendPush,
    required String? messageType,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgRef = _msgsRef.push();
    final msgKey = msgRef.key!;

    final preview = body.trim().isEmpty
        ? (attachments.isNotEmpty ? '📎 Attachment' : '')
        : body.trim();
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
      'reactions': {},
    };

    if (messageType != null && messageType.trim().isNotEmpty) {
      payload['type'] = messageType.trim();
    }

    final root = _db.ref();
    final updates = <String, dynamic>{
      'mail_messages/${widget.threadId}/$msgKey': payload,
    };

    if (updateThreadPreview) {
      final threadPath = 'mail_threads/${widget.threadId}';
      updates['$threadPath/subject'] = widget.subject;
      updates['$threadPath/updatedAt'] = now;
      updates['$threadPath/lastMessage'] = preview80;
      updates['$threadPath/participants/$_meUid'] = true;
      updates['$threadPath/participants/${widget.peerUid}'] = true;

      final senderIndexPath = 'mail_index/$_meUid/${widget.threadId}';
      updates['$senderIndexPath/subject'] = widget.subject;
      updates['$senderIndexPath/updatedAt'] = now;
      updates['$senderIndexPath/lastMessage'] = preview80;
      updates['$senderIndexPath/unreadCount'] = 0;
      updates['$senderIndexPath/peerUid'] = widget.peerUid;
      updates['$senderIndexPath/peerName'] = _peerNameShown;
      updates['$senderIndexPath/deletedAt'] = null;

      final peerIndexPath = 'mail_index/${widget.peerUid}/${widget.threadId}';
      updates['$peerIndexPath/subject'] = widget.subject;
      updates['$peerIndexPath/updatedAt'] = now;
      updates['$peerIndexPath/lastMessage'] = preview80;
      updates['$peerIndexPath/peerUid'] = _meUid;
      updates['$peerIndexPath/peerName'] = _meDisplayName;
      updates['$peerIndexPath/deletedAt'] = null;
      updates['$peerIndexPath/unreadCount'] = ServerValue.increment(1);

      updates['mail_state/$_meUid/${widget.threadId}/lastReadAt'] = now;
    }

    await root.update(updates);

    if (updateThreadPreview) {
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

  void _openMessageActions(_MailMsg m) {
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
              const SizedBox(height: 18),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red.withValues(alpha: 0.85),
                ),
                title: const Text(
                  'Delete (for me)',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
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

  void _openQuickReactions(_MailMsg m) {
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
        await deleteFileIfExists(p);
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

  String _normalizeCourseKey(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';

    s = s.replaceFirst(RegExp(r'^\s*course\s*:\s*', caseSensitive: false), '');
    s = s.replaceFirst(RegExp(r'^coure_', caseSensitive: false), 'course_');

    final m = RegExp(
      r'^(course_)(0+)(\d+)$',
      caseSensitive: false,
    ).firstMatch(s);
    if (m != null) {
      final prefix = m.group(1)!;
      final num = int.tryParse(m.group(3)!) ?? 0;
      if (num > 0) return '$prefix$num';
    }

    return s;
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

  Widget _buildMessageBubble(_MailMsg m, {required bool mine}) {
    final isReport = m.type == 'report';

    final bubbleBg = mine
        ? _mineBubbleBg(context, isReport: isReport)
        : _theirsBubbleBg(context, isReport: isReport);

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
              if (v == 'react') _openMessageActions(m);
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

      if (!mounted) return;

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

            return Dialog(
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              backgroundColor: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 560),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                      decoration: BoxDecoration(
                        color: _navy,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(28),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.fact_check_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Homework Review',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _peerNameShown,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: _orange.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _orange.withValues(alpha: 0.28),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Text(
                                    '${liveScore.clamp(0, 100)} / 100',
                                    style: const TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.w900,
                                      color: _navy,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _navy.withValues(alpha: 0.10),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Text(
                                          'Grade $liveGrade',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: _navy,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          color: status == 'redo'
                                              ? Colors.red.withValues(
                                                  alpha: 0.12,
                                                )
                                              : Colors.green.withValues(
                                                  alpha: 0.12,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: status == 'redo'
                                                ? Colors.red.withValues(
                                                    alpha: 0.25,
                                                  )
                                                : Colors.green.withValues(
                                                    alpha: 0.25,
                                                  ),
                                          ),
                                        ),
                                        child: Text(
                                          status == 'redo'
                                              ? 'Redo required'
                                              : 'Pass',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: status == 'redo'
                                                ? Colors.red.shade700
                                                : Colors.green.shade700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            TextField(
                              controller: scoreC,
                              onChanged: (_) => recalcGradeFromText(),
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: 'Score (0-100)',
                                hintText: 'Enter score',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(
                                    color: _orange.withValues(alpha: 0.75),
                                    width: 1.4,
                                  ),
                                ),
                                prefixIcon: const Icon(Icons.percent_rounded),
                              ),
                            ),

                            const SizedBox(height: 16),

                            Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(18),
                                    onTap: () => setLocal(() {
                                      status = 'pass';
                                      needsRedo = false;
                                    }),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 160,
                                      ),
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: status == 'pass'
                                            ? Colors.green.withValues(
                                                alpha: 0.12,
                                              )
                                            : Colors.grey.withValues(
                                                alpha: 0.06,
                                              ),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: status == 'pass'
                                              ? Colors.green.withValues(
                                                  alpha: 0.45,
                                                )
                                              : Colors.black.withValues(
                                                  alpha: 0.08,
                                                ),
                                          width: status == 'pass' ? 1.4 : 1,
                                        ),
                                      ),
                                      child: Column(
                                        children: [
                                          Icon(
                                            Icons.check_circle_rounded,
                                            color: status == 'pass'
                                                ? Colors.green.shade700
                                                : Colors.black.withValues(
                                                    alpha: 0.45,
                                                  ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'Pass',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: status == 'pass'
                                                  ? Colors.green.shade700
                                                  : Colors.black.withValues(
                                                      alpha: 0.72,
                                                    ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Homework accepted',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.black.withValues(
                                                alpha: 0.55,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(18),
                                    onTap: () => setLocal(() {
                                      status = 'redo';
                                      needsRedo = true;
                                    }),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 160,
                                      ),
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: status == 'redo'
                                            ? Colors.red.withValues(alpha: 0.10)
                                            : Colors.grey.withValues(
                                                alpha: 0.06,
                                              ),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: status == 'redo'
                                              ? Colors.red.withValues(
                                                  alpha: 0.40,
                                                )
                                              : Colors.black.withValues(
                                                  alpha: 0.08,
                                                ),
                                          width: status == 'redo' ? 1.4 : 1,
                                        ),
                                      ),
                                      child: Column(
                                        children: [
                                          Icon(
                                            Icons.refresh_rounded,
                                            color: status == 'redo'
                                                ? Colors.red.shade700
                                                : Colors.black.withValues(
                                                    alpha: 0.45,
                                                  ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'Redo',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: status == 'redo'
                                                  ? Colors.red.shade700
                                                  : Colors.black.withValues(
                                                      alpha: 0.72,
                                                    ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Student should try again',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.black.withValues(
                                                alpha: 0.55,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 18),

                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Quick feedback',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: Colors.black.withValues(alpha: 0.78),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    [
                                      'Great effort.',
                                      'Well done.',
                                      'Nice improvement.',
                                      'Please check spelling.',
                                      'Please review grammar.',
                                      'Complete all parts next time.',
                                      'Please redo carefully.',
                                    ].map((text) {
                                      return ActionChip(
                                        label: Text(text),
                                        onPressed: () {
                                          final current = noteC.text.trim();
                                          final next = current.isEmpty
                                              ? text
                                              : '$current $text';
                                          noteC.text = next;
                                          noteC.selection =
                                              TextSelection.fromPosition(
                                                TextPosition(
                                                  offset: noteC.text.length,
                                                ),
                                              );
                                          setLocal(() {});
                                        },
                                        backgroundColor: _navy.withValues(
                                          alpha: 0.06,
                                        ),
                                        side: BorderSide(
                                          color: _navy.withValues(alpha: 0.10),
                                        ),
                                        labelStyle: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: _navy.withValues(alpha: 0.88),
                                        ),
                                      );
                                    }).toList(),
                              ),
                            ),

                            const SizedBox(height: 16),

                            SizedBox(
                              height: 150,
                              child: TextField(
                                controller: noteC,
                                expands: true,
                                maxLines: null,
                                minLines: null,
                                textAlignVertical: TextAlignVertical.top,
                                decoration: InputDecoration(
                                  labelText: 'Personal feedback',
                                  hintText:
                                      'Example: Great effort. Please review verb forms in exercise 2.',
                                  alignLabelWithHint: true,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    borderSide: BorderSide(
                                      color: _orange.withValues(alpha: 0.75),
                                      width: 1.4,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 18),

                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Student preview',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: Colors.black.withValues(alpha: 0.78),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.04),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.black.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    status == 'redo'
                                        ? '🔁 Homework: REDO (do it again)'
                                        : '✅ Homework: PASS',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: status == 'redo'
                                          ? Colors.red.shade700
                                          : Colors.green.shade700,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Score: ${liveScore.clamp(0, 100)}/100',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: _navy,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Grade: $liveGrade',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: _navy,
                                    ),
                                  ),
                                  if (noteC.text.trim().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      'Comment: ${noteC.text.trim()}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black.withValues(
                                          alpha: 0.72,
                                        ),
                                        height: 1.3,
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
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(28),
                        ),
                        border: Border(
                          top: BorderSide(
                            color: Colors.black.withValues(alpha: 0.06),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(52),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                side: BorderSide(
                                  color: _navy.withValues(alpha: 0.18),
                                ),
                              ),
                              child: const Text(
                                'Cancel',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              style: FilledButton.styleFrom(
                                backgroundColor: _navy,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(52),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Text(
                                'Save',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );

      if (ok != true) {
        scoreC.dispose();
        noteC.dispose();
        return;
      }

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
        status == 'redo'
            ? '🔁 Homework: REDO (do it again)'
            : '✅ Homework: PASS',
        'Score: $parsedScore/100',
        'Grade: $grade',
        if (noteText.isNotEmpty) 'Comment: $noteText',
      ].join('\n');

      await _sendRawMessage(
        body: evalText,
        attachments: const [],
        updateThreadPreview: true,
        sendPush: false,
        messageType: 'homework_eval',
      );

      _snack('Saved + sent ✅');
      scoreC.dispose();
      noteC.dispose();
    } catch (e) {
      _snack(toHumanError(e));
    }
  }

  Future<Map<String, dynamic>> _computeHomeworkStatsForCourse({
    required String learnerUid,
    required String courseKey,
  }) async {
    int doneCount = 0;
    int redoCount = 0;
    int reviewedCount = 0;
    int sumScore = 0;

    final gradeCounts = <String, int>{'A': 0, 'B': 0, 'C': 0, 'D': 0};

    final snap = await _db
        .ref('users/$learnerUid/courses/$courseKey/attendance')
        .get();
    if (!snap.exists || snap.value is! Map) {
      return {
        'doneCount': 0,
        'redoCount': 0,
        'avgScore': 0,
        'commonGrade': '—',
      };
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

    final avgScore = reviewedCount == 0
        ? 0
        : (sumScore / reviewedCount).round();

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
      dev.add(
        'benefits from additional support with consistency, participation, and classroom routines',
      );
    } else if (behaviorAvg == 3) {
      dev.add('can improve consistency in participation and classroom focus');
    } else {
      dev.add('should continue maintaining this positive classroom approach');
    }

    if (progressAvg <= 2) {
      dev.add(
        'needs more practice to strengthen speaking and writing accuracy',
      );
    } else if (progressAvg == 3) {
      dev.add(
        'should continue building fluency and accuracy, especially in speaking and writing',
      );
    } else {
      dev.add(
        'should continue challenging themselves with more complex language use',
      );
    }

    if (homeworkRedo > 0) {
      rec.add(
        'reviewing feedback carefully and resubmitting improvements will accelerate progress',
      );
    }
    if (homeworkDone == 0) {
      rec.add('more consistent homework completion is recommended');
    } else if (homeworkDone >= 6 && homeworkAvgScore >= 80) {
      rec.add(
        'continuing regular practice at home will help maintain this good momentum',
      );
    } else {
      rec.add(
        'regular short practice at home (10–15 minutes) will support improvement',
      );
    }

    return [
      'Strengths: The learner $bLevel in behavior and $pLevel in progress, and ${strengths.join(', ')}.',
      'Development: The learner ${dev.join(' ')}.',
      'Recommendation: ${rec.join(' ')}.',
    ].join('\n');
  }

  Future<Uint8List?> _renderWidgetToPng(
    GlobalKey key, {
    double pixelRatio = 2.5,
  }) async {
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
    final client = MailUploadClient.defaultClient();
    final name = 'report_${DateTime.now().millisecondsSinceEpoch}.png';
    return client.uploadBytes(bytes: bytes, filename: name);
  }

  Future<String?> _pickCourseForReport() async {
    if (!_loadedLearnerCourses) {
      await _loadLearnerCoursesTitles();
    }

    final entries = _learnerCourseTitles.entries.toList();

    if (entries.isEmpty) {
      return null;
    }

    if (entries.length == 1) {
      return entries.first.key;
    }

    if (!mounted) return null;

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select course'),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final e = entries[i];
              final courseKey = e.key.trim();
              final courseTitle = e.value.trim().isNotEmpty
                  ? e.value.trim()
                  : courseKey;

              return ListTile(
                title: Text(courseTitle),
                subtitle: courseTitle == courseKey ? null : Text(courseKey),
                onTap: () => Navigator.pop(ctx, courseKey),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReportCard() async {
    if (!_peerIsLearner) {
      _snack('Report Card is only for learners.');
      return;
    }

    String? courseKey = _threadCourseKey?.trim();

    if (courseKey == null || courseKey.isEmpty) {
      courseKey = await _pickCourseForReport();

      if (courseKey == null || courseKey.trim().isEmpty) {
        _snack('No course found for this learner.');
        return;
      }

      try {
        await _threadRef.update({'courseKey': courseKey});
        if (mounted) {
          setState(() {
            _threadCourseKey = courseKey;
            final pickedTitle = (_learnerCourseTitles[courseKey] ?? '').trim();
            if (pickedTitle.isNotEmpty) _threadCourseTitle = pickedTitle;
          });
        }
      } catch (_) {}
    }

    courseKey = courseKey.trim();

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

    final doneC = TextEditingController(
      text: (autoStats['doneCount'] ?? 0).toString(),
    );
    final redoC = TextEditingController(
      text: (autoStats['redoCount'] ?? 0).toString(),
    );
    final avgScoreC = TextEditingController(
      text: (autoStats['avgScore'] ?? 0).toString(),
    );
    final commonGradeC = TextEditingController(
      text: (autoStats['commonGrade'] ?? '—').toString(),
    );
    final commentC = TextEditingController(text: '');

    final diagramKey = GlobalKey();

    bool sending = false;

    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget scorePicker({
            required int value,
            required ValueChanged<int> onChanged,
          }) {
            return DropdownButton<int>(
              value: value,
              isDense: true,
              items: const [1, 2, 3, 4, 5]
                  .map(
                    (n) => DropdownMenuItem<int>(value: n, child: Text('$n')),
                  )
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                onChanged(v);
              },
            );
          }

          Widget itemRow(List<Map<String, dynamic>> list, int index) {
            final it = list[index];
            final labelC = TextEditingController(
              text: (it['label'] ?? '').toString(),
            );

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

          final fromThread = (_threadCourseTitle ?? '').trim();
          final fromLearner = (_learnerCourseTitles[courseKey] ?? '').trim();

          final courseLabel = fromThread.isNotEmpty
              ? fromThread
              : (fromLearner.isNotEmpty ? fromLearner : courseKey);

          final summaryLines = <String>[
            '📋 Report Card',
            'Course: $courseLabel',
            'Learner: $_peerNameShown',
            'Behavior: $behaviorAvg/5 • Progress: $progressAvg/5',
            'Homework: done $finalDone • redo $finalRedo • avg $finalAvgScore/100 • common $finalCommonGrade',
            '',
            autoSummary,
            if (commentText.isNotEmpty) '\nTeacher comment: $commentText',
          ];

          return PopScope(
            canPop: !sending,
            child: AlertDialog(
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
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.black.withValues(alpha: 0.75),
                        ),
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
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Colors.black.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => setLocal(
                            () => behaviorItems.add({
                              'label': 'New behavior item',
                              'score': 3,
                            }),
                          ),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (int i = 0; i < behaviorItems.length; i++)
                      itemRow(behaviorItems, i),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Behavior average: $behaviorAvg/5',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Colors.black.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Divider(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Advancement / Progress (1–5)',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Colors.black.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => setLocal(
                            () => progressItems.add({
                              'label': 'New progress item',
                              'score': 3,
                            }),
                          ),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (int i = 0; i < progressItems.length; i++)
                      itemRow(progressItems, i),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Progress average: $progressAvg/5',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Colors.black.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Divider(),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Teacher comment (optional)',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.black.withValues(alpha: 0.75),
                        ),
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
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.black.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    RepaintBoundary(
                      key: diagramKey,
                      child: _ReportWatermarkBackground(
                        child: _ReportCardDiagramV2(
                          schoolTitle: 'Your Bridge School Academy',
                          learnerName: _peerNameShown,
                          courseKey: courseKey!,
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
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.black.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.08),
                        ),
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
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                  label: Text(sending ? 'Sending…' : 'Send report'),
                  onPressed: sending
                      ? null
                      : () async {
                          setLocal(() => sending = true);

                          try {
                            final reportId = _db
                                .ref('reports/${widget.peerUid}')
                                .push()
                                .key;
                            if (reportId == null) {
                              _snack(
                                'The report could not be prepared correctly. Please try again.',
                              );
                              setLocal(() => sending = false);
                              return;
                            }

                            final now = DateTime.now().millisecondsSinceEpoch;

                            Map<String, dynamic> toItemMap(
                              List<Map<String, dynamic>> list,
                            ) {
                              String safeKey(String s) {
                                var k = s.trim();
                                k = k.replaceAll(RegExp(r'[.#$\[\]/]'), '_');
                                k = k.replaceAll(RegExp(r'\s+'), ' ').trim();
                                if (k.isEmpty) k = 'item';
                                return k;
                              }

                              final out = <String, dynamic>{};
                              for (int i = 0; i < list.length; i++) {
                                final label = (list[i]['label'] ?? '')
                                    .toString()
                                    .trim();
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
                              'courseTitle': courseLabel,
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
                                  'commonGrade':
                                      (autoStats['commonGrade'] ?? '—')
                                          .toString(),
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

                            await _db
                                .ref('reports/${widget.peerUid}/$reportId')
                                .set(reportData);
                            await _threadRef
                                .child('reports')
                                .child(reportId)
                                .set(true);

                            final pngBytes = await _renderWidgetToPng(
                              diagramKey,
                              pixelRatio: 2.5,
                            );
                            if (pngBytes == null) {
                              _snack('Could not generate diagram image.');
                              setLocal(() => sending = false);
                              return;
                            }

                            final url = await _uploadPngBytes(pngBytes);
                            await _db
                                .ref('reports/${widget.peerUid}/$reportId')
                                .update({'diagramUrl': url});

                            final msgBody = [
                              '📋 Report Card',
                              'Course: $courseLabel',
                              'Learner: $_peerNameShown',
                              'Behavior: $behaviorAvg/5 • Progress: $progressAvg/5',
                              'Homework: done $finalDone • redo $finalRedo • avg $finalAvgScore/100 • common $finalCommonGrade',
                              '',
                              autoSummary,
                              if (commentText.isNotEmpty)
                                '\nTeacher comment: $commentText',
                              '',
                              'Report ID: $reportId',
                            ].join('\n');

                            await _sendRawMessage(
                              body: msgBody,
                              attachments: [
                                {'name': 'ReportCard_$now.png', 'url': url},
                              ],
                              updateThreadPreview: true,
                              sendPush: true,
                              messageType: 'report',
                            );

                            if (!ctx.mounted) return;
                            Navigator.pop(ctx, true);
                            if (!mounted) return;
                            _snack('Report sent ✅');
                          } catch (e, _) {
                            _snack(
                              toHumanError(
                                e,
                                fallback:
                                    'The report could not be sent right now. Please check your internet and try again.',
                              ),
                            );
                            setLocal(() => sending = false);
                          }
                        },
                ),
              ],
            ),
          );
        },
      ),
    );

    if (ok == true) {}
  }

  Widget _buildComposerUploads() {
    if (_uploadingItems.isEmpty) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _uploadingItems.map((u) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _navy.withValues(alpha: 0.10)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    'Uploading ${u.name}… ${(u.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: _navy.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 72,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: u.progress <= 0 ? null : u.progress,
                      minHeight: 6,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
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
    final title = _selectionMode
        ? '${_selectedMessageIds.length} selected'
        : (_peerNameShown.isEmpty ? 'Mail' : _peerNameShown);
    final subjectTrim = widget.subject.trim();
    final canReport = _peerIsLearner;

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_mail_thread',
      hints: const [
        TeacherTourHint(
          title: 'Conversation thread',
          line: 'Read messages, search the thread, and open shared files here.',
        ),
        TeacherTourHint(
          title: 'Send message',
          line:
              'Use the composer area at the bottom to send text, audio, or attachments.',
        ),
      ],
    );

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
            : GestureDetector(
                onLongPress: canReport ? _openReportCard : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: _navy,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
        actions: [
          const SizedBox.shrink(),
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
            tooltip: 'Evaluate homework',
            icon: Icon(
              Icons.assignment_turned_in_rounded,
              color: Colors.deepOrange.withValues(alpha: 0.95),
            ),
            onPressed: _reviewHomeworkFromThread,
          ),
          if (_loadedPeerRole && _peerIsLearner)
            IconButton(
              tooltip: 'Report card',
              icon: Icon(
                Icons.assessment_rounded,
                color: canReport
                    ? Colors.teal.withValues(alpha: 0.95)
                    : Colors.teal.withValues(alpha: 0.35),
              ),
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: _orange.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _orange.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.topic_rounded,
                            size: 18,
                            color: _navy.withValues(alpha: 0.9),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              subjectTrim,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: _navy.withValues(alpha: 0.92),
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
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<DatabaseEvent>(
              stream: _msgStream,
              builder: (_, snap) {
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
                    if (i + 1 < msgs.length)
                      nextDateLabel = _dateLabel(msgs[i + 1].createdAtMs);
                    final showDate =
                        (i == msgs.length - 1) ||
                        (nextDateLabel != thisDateLabel);

                    final grouped = _isSameSenderNearby(msgs, i);

                    return Column(
                      children: [
                        if (showDate) _dateSeparator(thisDateLabel),
                        Padding(
                          padding: EdgeInsets.only(bottom: grouped ? 4 : 10),
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
                                      borderRadius: BorderRadius.circular(14),
                                      border: _selectedMessageIds.contains(m.id)
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
                                      child: _buildMessageBubble(m, mine: mine),
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
                                : () => setState(() => _attachments.remove(a)),
                          );
                        }).toList(),
                      ),
                    ),

                  if (_uploadingItems.isNotEmpty) ...[
                    _buildComposerUploads(),
                    const SizedBox(height: 8),
                  ],

                  _buildRecordingBar(),

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
                            hintText: _hasPendingUploads
                                ? 'Wait for upload to finish…'
                                : ((_recRecording ||
                                          _recStarting ||
                                          _recUploading)
                                      ? 'Recording…'
                                      : 'Message…'),
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
                                : (_hasPendingUploads ? 'Uploading…' : 'Send'),
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

class _ComposerUploadItem {
  const _ComposerUploadItem({
    required this.id,
    required this.name,
    required this.progress,
  });

  final String id;
  final String name;
  final double progress;

  _ComposerUploadItem copyWith({double? progress}) {
    return _ComposerUploadItem(
      id: id,
      name: name,
      progress: progress ?? this.progress,
    );
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
              opacity: 0.035,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.75,
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
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
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

  List<Map<String, dynamic>> _capItems(
    List<Map<String, dynamic>> list,
    int max,
  ) {
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
        Text(
          '$k: ',
          style: TextStyle(
            color: Colors.black.withValues(alpha: 0.65),
            fontWeight: FontWeight.w800,
          ),
        ),
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
        Text(
          _dots(score),
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const maxPerSection = 6;
    final courseLabel = courseKey;
    final bShown = _capItems(behaviorItems, maxPerSection);
    final pShown = _capItems(progressItems, maxPerSection);

    final bMore = behaviorItems.length - bShown.length;
    final pMore = progressItems.length - pShown.length;

    return Container(
      width: 360,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFDFE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.black),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.school_rounded),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        schoolTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                          color: Color(0xFF334155),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Learner Progress Report',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Learner: $learnerName',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),

            // (we will pass the title into "courseKey" when calling this widget)
            Text(
              'Course: $courseLabel',
              style: TextStyle(
                color: const Color(0xFF475569),
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'Date: ${_fmtDate(createdAtMs)}',
              style: TextStyle(
                color: const Color(0xFF475569),
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              'Teacher: $teacherName',
              style: TextStyle(
                color: const Color(0xFF475569),
                fontWeight: FontWeight.w800,
              ),
            ),
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
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Behavior Indicators'),
                      const SizedBox(height: 8),
                      for (final it in bShown)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _itemLine(
                            (it['label'] ?? '').toString(),
                            _clamp15(it['score']),
                          ),
                        ),
                      if (bMore > 0)
                        Text(
                          '+$bMore more behavior item(s)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.black.withValues(alpha: 0.55),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle('Progress Indicators'),
                      const SizedBox(height: 8),
                      for (final it in pShown)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _itemLine(
                            (it['label'] ?? '').toString(),
                            _clamp15(it['score']),
                          ),
                        ),
                      if (pMore > 0)
                        Text(
                          '+$pMore more progress item(s)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.black.withValues(alpha: 0.55),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            _sectionTitle('Auto Summary'),
            const SizedBox(height: 6),
            Text(
              autoSummary,
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                color: Colors.black.withValues(alpha: 0.85),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _sectionTitle('Teacher Notes'),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black.withValues(alpha: 0.10)),
              ),
              child: Text(
                commentText.trim().isEmpty ? '—' : commentText.trim(),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.25,
                  color: Colors.black.withValues(alpha: 0.85),
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
                'Reference: $reportId',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: Colors.black.withValues(alpha: 0.55),
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

  /// Mobile/Desktop only (non-web)
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
