import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/route_state.dart';
import '../services/push_client.dart';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
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
  final _db = FirebaseDatabase.instance;
  final _bodyC = TextEditingController();

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

  // ---- NEW: learner role + courseKey (current course only) ----
  bool _peerIsLearner = false;
  bool _loadedPeerRole = false;
  String? _threadCourseKey; // for current course report stats
  bool _loadedThreadMeta = false;

  @override
  void initState() {
    super.initState();
    RouteState.enterMailThread(widget.threadId);

    _msgStream = _msgsRef.orderByChild('createdAt').onValue.asBroadcastStream();

    _markRead();
    _loadNames();

    _loadPeerRole();
    _loadThreadMeta();
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

      if (!mounted) return;
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
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgRef = _msgsRef.push();

    final preview = body.trim().isEmpty ? (attachments.isNotEmpty ? '📎 Attachment' : '') : body.trim();
    final preview80 = preview.length > 80 ? preview.substring(0, 80) : preview;

    await msgRef.set({
      'fromUid': _meUid,
      'body': body,
      'toUids': {widget.peerUid: true},
      'ccUids': {},
      'bccUids': {},
      'attachments': attachments,
      'createdAt': now,
      'deletedFor': {},
    });

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

      // ✅ FIX: safe transaction even if existing value is String/num/null
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

  Future<void> _deleteMessageForMe(_MailMsg m) async {
    try {
      await _msgsRef.child(m.id).child('deletedFor').child(_meUid).set(true);
      _snack('Deleted for you ✅');
    } catch (e) {
      _snack('Delete failed: $e');
    }
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
      });

      final preview80 = evalText.length > 80 ? evalText.substring(0, 80) : evalText;

      await _threadRef.update({
        'updatedAt': now,
        'lastMessage': preview80,
      });

      // ✅ FIX: safe transaction here too
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

  // ---------- NEW: Report Card (Learner only) ----------
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
              items: const [1, 2, 3, 4, 5]
                  .map((n) => DropdownMenuItem<int>(value: n, child: Text('$n')))
                  .toList(),
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

          final summaryLines = <String>[
            '📋 Report Card',
            'Course: $courseKey',
            'Learner: $_peerNameShown',
            'Behavior: $behaviorAvg/5 • Progress: $progressAvg/5',
            'Homework: done $finalDone • redo $finalRedo • avg $finalAvgScore/100 • common $finalCommonGrade',
            if (commentText.isNotEmpty) 'Comment: $commentText',
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
                      'Teacher comment',
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
                        labelText: 'Write a qualitative report…',
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
                      'Diagram preview',
                      style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black.withOpacity(0.75)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  RepaintBoundary(
                    key: diagramKey,
                    child: _ReportCardDiagram(
                      learnerName: _peerNameShown,
                      courseKey: courseKey,
                      createdAtMs: DateTime.now().millisecondsSinceEpoch,
                      behaviorAvg: behaviorAvg,
                      progressAvg: progressAvg,
                      homeworkDone: finalDone,
                      homeworkRedo: finalRedo,
                      homeworkAvgScore: finalAvgScore,
                      homeworkCommonGrade: finalCommonGrade,
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
                      final out = <String, dynamic>{};
                      for (int i = 0; i < list.length; i++) {
                        final label = (list[i]['label'] ?? '').toString().trim();
                        if (label.isEmpty) continue;
                        // NOTE: these are stored as keys inside a MAP, not as paths.
                        out[label] = _clamp15(list[i]['score']);
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
                      'diagramVersion': 1,
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
                      if (commentText.isNotEmpty) 'Comment: $commentText',
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
                    );

                    if (mounted) Navigator.pop(ctx, true);
                    _snack('Report sent ✅');
                  } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    final title = _peerNameShown.isEmpty ? 'Mail' : 'Mail — $_peerNameShown';

    final canReport = _peerIsLearner && (_threadCourseKey != null && _threadCourseKey!.trim().isNotEmpty);

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: canReport ? _openReportCard : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(title)),
              if (_loadedPeerRole && _peerIsLearner) ...[
                const SizedBox(width: 8),
                Icon(Icons.assignment_turned_in_rounded, size: 18, color: Colors.white.withOpacity(0.9)),
              ],
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Evaluate homework',
            icon: const Icon(Icons.fact_check_rounded),
            onPressed: _reviewHomeworkFromThread,
          ),
          if (_loadedPeerRole && _peerIsLearner)
            IconButton(
              tooltip: canReport ? 'Report card (long press title too)' : 'Report card unavailable (missing courseKey)',
              icon: Icon(Icons.analytics_rounded, color: canReport ? null : Colors.white.withOpacity(0.45)),
              onPressed: canReport ? _openReportCard : null,
            ),
        ],
        bottom: (widget.subject.trim().isEmpty)
            ? null
            : PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Topic: ${widget.subject}', style: const TextStyle(fontWeight: FontWeight.w800)),
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
                final msgs = _parseMessages(snap.data?.snapshot.value);

                if (msgs.isEmpty) {
                  return const Center(child: Text('No mail yet.'));
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    final mine = m.fromUid == _meUid;

                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: Card(
                          elevation: 0,
                          color: mine ? Colors.blue.withOpacity(0.12) : Colors.black.withOpacity(0.05),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        mine ? _meDisplayName : _peerNameShown,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: Colors.black.withOpacity(0.6),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _fmt(m.createdAtMs),
                                      style: TextStyle(fontSize: 11, color: Colors.black.withOpacity(0.55)),
                                    ),
                                    const SizedBox(width: 6),
                                    SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: PopupMenuButton<String>(
                                        padding: EdgeInsets.zero,
                                        tooltip: 'Message actions',
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
                                            decoration: TextDecoration.underline,
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
    );
  }

  static String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  String _gradeFromScore(int score) {
    final s = score.clamp(0, 100);
    if (s >= 90) return 'A';
    if (s >= 80) return 'B';
    if (s >= 70) return 'C';
    return 'D';
  }
}

class _ReportCardDiagram extends StatelessWidget {
  const _ReportCardDiagram({
    required this.learnerName,
    required this.courseKey,
    required this.createdAtMs,
    required this.behaviorAvg,
    required this.progressAvg,
    required this.homeworkDone,
    required this.homeworkRedo,
    required this.homeworkAvgScore,
    required this.homeworkCommonGrade,
  });

  final String learnerName;
  final String courseKey;
  final int createdAtMs;

  final int behaviorAvg;
  final int progressAvg;

  final int homeworkDone;
  final int homeworkRedo;
  final int homeworkAvgScore;
  final String homeworkCommonGrade;

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Widget _bar({required String label, required int value, required Color color}) {
    final v = value.clamp(0, 5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 10,
            color: Colors.black.withOpacity(0.08),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: v / 5.0,
              child: Container(color: color),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text('$v / 5', style: TextStyle(color: Colors.black.withOpacity(0.65), fontWeight: FontWeight.w700)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
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
            const Text('REPORT CARD', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 6),
            Text('Learner: $learnerName', style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('Course: $courseKey', style: TextStyle(color: Colors.black.withOpacity(0.70), fontWeight: FontWeight.w700)),
            Text('Date: ${_fmt(createdAtMs)}', style: TextStyle(color: Colors.black.withOpacity(0.70), fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _bar(label: 'Behavior', value: behaviorAvg, color: Colors.green),
            const SizedBox(height: 10),
            _bar(label: 'Progress', value: progressAvg, color: Colors.blue),
            const SizedBox(height: 12),
            const Divider(),
            const Text('Homework summary', style: TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip('Done', '$homeworkDone'),
                _chip('Redo', '$homeworkRedo'),
                _chip('Avg score', '$homeworkAvgScore/100'),
                _chip('Common grade', homeworkCommonGrade),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget _chip(String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k: ', style: TextStyle(color: Colors.black.withOpacity(0.65), fontWeight: FontWeight.w800)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w900)),
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