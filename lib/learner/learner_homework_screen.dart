import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'learner_mail_thread_screen.dart';

import '../shared/human_error.dart';
import '../shared/learner_web_layout.dart';
import '../shared/offline_action_guard.dart';
import '../shared/responsive_layout.dart';
import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import '../services/audit_action_keys.dart';
import '../services/audit_log_service.dart';
import '../services/homework_cache_service.dart';
import '../services/mail_consistency_service.dart';
import '../services/push_dispatch_service.dart';

class LearnerHomeworkScreen extends StatefulWidget {
  final String courseKey; // course_1, course_2...
  final String courseTitle;

  const LearnerHomeworkScreen({
    super.key,
    required this.courseKey,
    required this.courseTitle,
  });

  @override
  State<LearnerHomeworkScreen> createState() => _LearnerHomeworkScreenState();
}

class _LearnerHomeworkScreenState extends State<LearnerHomeworkScreen> {
  static const usersNode = 'users';
  static const Set<String> _adminHomeworkReceiverUids = {
    '40Jo9GaY7yXyx5jlur0R4K7COuo1',
    'bx3V05SRysTn2PBYU7PQrcF1fyY2',
    'ewYMeMDCkXU4sRhemweN7IiTINy1',
  };

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  final Map<String, Future<_HomeworkReceiver>> _receiverByClassId = {};

  bool _busy = true;
  String? _error;

  String _uid = '';
  String _learnerUid = '';
  String _courseId = '';
  List<Map<String, dynamic>> _items = [];
  final Set<String> _expanded = <String>{};
  String _lang = 'ar';

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  Future<_HomeworkReceiver> _resolveHomeworkReceiver({
    required String classId,
    required String fallbackUid,
    required String fallbackName,
  }) async {
    final cleanClassId = classId.trim();
    final cleanFallbackUid = fallbackUid.trim();
    final cleanFallbackName = fallbackName.trim();

    if (cleanClassId.isEmpty) {
      return _HomeworkReceiver(uid: cleanFallbackUid, name: cleanFallbackName);
    }

    final cached = _receiverByClassId[cleanClassId];
    if (cached != null) {
      final receiver = await cached;
      if (receiver.uid.isNotEmpty &&
          !_adminHomeworkReceiverUids.contains(receiver.uid)) {
        return receiver;
      }
      return _HomeworkReceiver(uid: cleanFallbackUid, name: cleanFallbackName);
    }

    final future = () async {
      try {
        final snap = await _db.child('classes/$cleanClassId').get();
        if (!snap.exists || snap.value is! Map) {
          return const _HomeworkReceiver();
        }
        final classNode = (snap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final current = classNode['instructor_current'] is Map
            ? (classNode['instructor_current'] as Map).map(
                (k, v) => MapEntry(k.toString(), v),
              )
            : <String, dynamic>{};
        final uid = (current['uid'] ?? '').toString().trim();
        final name = (current['name'] ?? classNode['instructor'] ?? '')
            .toString()
            .trim();
        return _HomeworkReceiver(uid: uid, name: name);
      } catch (_) {
        return const _HomeworkReceiver();
      }
    }();

    _receiverByClassId[cleanClassId] = future;
    final receiver = await future;
    if (receiver.uid.isNotEmpty &&
        !_adminHomeworkReceiverUids.contains(receiver.uid)) {
      return receiver;
    }
    return _HomeworkReceiver(uid: cleanFallbackUid, name: cleanFallbackName);
  }

  Future<String> _resolveLearnerUidFromAuth(String authUid) async {
    final clean = authUid.trim();
    if (clean.isEmpty) return '';
    try {
      final snap = await _usersRef.child(clean).get();
      if (snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final canonical = (m['uid'] ?? '').toString().trim();
        if (canonical.isNotEmpty) return canonical;
      }
    } catch (_) {}
    return clean;
  }

  // ---- Helpers: shorten long text for subject/body (UI only) ----
  String _short(String s, int max) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    if (max <= 1) return '…';
    return '${t.substring(0, max - 1)}…';
  }

  String _hwSubject({required String date, required String taughtTitle}) {
    final d = date.trim();
    final lesson = _short(taughtTitle, 24); // keep subject short
    return '[HW] ${widget.courseTitle}'
        '${d.isEmpty ? '' : ' • $d'}'
        '${lesson.isEmpty ? '' : ' • $lesson'}';
  }

  DatabaseReference _hwRefByPath(String homeworkRefPath) {
    return _db.child(homeworkRefPath);
  }

  String _legacyHwRefPath(String sessionId) {
    return 'users/$_uid/courses/${widget.courseKey}/attendance/$sessionId/homework';
  }

  String _itemKey(String source, String sessionId) => '$source:$sessionId';

  String _formatOnlineWhen(Map<String, dynamic> rec) {
    final startAt = rec['startAt'];
    final ts = startAt is num ? startAt.toInt() : int.tryParse('$startAt') ?? 0;
    if (ts > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(ts);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    final dayKey = (rec['dayKey'] ?? '').toString().trim();
    final time = (rec['time'] ?? '').toString().trim();
    if (dayKey.isEmpty && time.isEmpty) return '';
    return [dayKey, time].where((s) => s.isNotEmpty).join(' ');
  }

  Future<void> _markSeen(String homeworkRefPath) async {
    try {
      await _hwRefByPath(homeworkRefPath).update({'seenAt': _nowMs()});
    } catch (_) {}
  }

  Future<String> _myDisplayName() async {
    try {
      final snap = await _usersRef.child(_uid).get();
      if (!snap.exists || snap.value is! Map) return 'Learner';

      final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
      final fn = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final ln = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final email = (m['email'] ?? '').toString().trim();

      final full = ('$fn $ln').trim();
      return full.isNotEmpty ? full : (email.isNotEmpty ? email : 'Learner');
    } catch (_) {
      return 'Learner';
    }
  }

  Future<void> _createHomeworkMailAndOpen({
    required String sessionId,
    required String homeworkRefPath,
    required String teacherUid,
    required String teacherName,
    required String date,
    required String dueDate,
    required String taughtTitle,
    required String homeworkText,
  }) async {
    if (teacherUid.trim().isEmpty) return;

    final now = _nowMs();

    // ✅ Deterministic thread per session (prevents duplicates/spam)
    // If learner undoes then marks done again, it continues same thread.
    final threadId = '${_uid}_${teacherUid}_$sessionId';

    final subject = _hwSubject(date: date, taughtTitle: taughtTitle);

    final body = [
      'Homework',
      if (date.trim().isNotEmpty) 'Date: ${date.trim()}',
      if (taughtTitle.trim().isNotEmpty) 'Session: ${taughtTitle.trim()}',
    ].join('\n');

    // Push message id
    final msgKey = _db.child('mail_messages').child(threadId).push().key;
    if (msgKey == null) return;
    // Save the auto-created message key so we can delete it on Undo (if not reviewed)
    final hwMsgKeyPath = '$homeworkRefPath/autoMailMsgKey';
    // Multi-location update (thread + message + my index)
    final learnerName = await _myDisplayName();
    final learnerRole = await MailConsistencyService.resolveUserRole(
      FirebaseDatabase.instance,
      _uid,
      seedRole: 'learner',
    );
    final teacherRole = await MailConsistencyService.resolveUserRole(
      FirebaseDatabase.instance,
      teacherUid,
      seedRole: 'teacher',
    );

    final Map<String, dynamic> updates = {
      // thread meta
      'mail_threads/$threadId/subject': subject,
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/createdAt': now,
      'mail_threads/$threadId/lastMessage': body.length > 60
          ? body.substring(0, 60)
          : body,
      'mail_threads/$threadId/participants/$_uid': true,
      'mail_threads/$threadId/participants/$teacherUid': true,
      // link auto-created message to homework for future Undo-delete
      hwMsgKeyPath: msgKey,
      // ✅ Homework linkage (for full cycle)
      'mail_threads/$threadId/type': 'homework',
      'mail_threads/$threadId/courseKey': widget.courseKey,
      'mail_threads/$threadId/sessionId': sessionId,
      'mail_threads/$threadId/learnerUid': _uid,
      'mail_threads/$threadId/teacherUid': teacherUid,
      'mail_threads/$threadId/homeworkRef': homeworkRefPath,

      // message itself
      'mail_messages/$threadId/$msgKey/body': body,
      'mail_messages/$threadId/$msgKey/createdAt': now,
      'mail_messages/$threadId/$msgKey/fromUid': _uid,
      'mail_messages/$threadId/$msgKey/toUids/$teacherUid': true,

      // my index
      // my index
      'mail_index/$_uid/$threadId/peerUid': teacherUid,
      'mail_index/$_uid/$threadId/peerName': teacherName.isEmpty
          ? 'Teacher'
          : teacherName,
      'mail_index/$_uid/$threadId/subject': subject,
      'mail_index/$_uid/$threadId/lastMessage': body.length > 60
          ? body.substring(0, 60)
          : body,
      'mail_index/$_uid/$threadId/unreadCount': 0,
      'mail_index/$_uid/$threadId/updatedAt': now,
      'mail_index/$_uid/$threadId/type': 'homework',
      'mail_index/$_uid/$threadId/peerRole': teacherRole,
      'mail_index/$_uid/$threadId/homeworkRef': homeworkRefPath,

      // my read state (optional but consistent)
      'mail_state/$_uid/$threadId/lastReadAt': now,
      'mail_state/$_uid/$threadId/lastDeliveredAt': now,
      'mail_state/$teacherUid/$threadId/lastDeliveredAt': now,
      'mail_index/$teacherUid/$threadId/peerUid': _uid,
      'mail_index/$teacherUid/$threadId/peerName': learnerName.isEmpty
          ? 'Learner'
          : learnerName,
      'mail_index/$teacherUid/$threadId/subject': subject,
      'mail_index/$teacherUid/$threadId/lastMessage': body.length > 60
          ? body.substring(0, 60)
          : body,
      'mail_index/$teacherUid/$threadId/updatedAt': now,
      'mail_index/$teacherUid/$threadId/type': 'homework',
      'mail_index/$teacherUid/$threadId/peerRole': learnerRole,
      'mail_index/$teacherUid/$threadId/homeworkRef': homeworkRefPath,
      'mail_index/$teacherUid/$threadId/deletedAt': null,
      'mail_index/$teacherUid/$threadId/unreadCount': ServerValue.increment(1),
    };

    await _db.update(updates);

    await MailConsistencyService.verifyMailWriteOnce(
      db: FirebaseDatabase.instance,
      threadId: threadId,
      senderUid: _uid,
      receiverUid: teacherUid,
      senderName: learnerName.isEmpty ? 'Learner' : learnerName,
      receiverName: teacherName.isEmpty ? 'Teacher' : teacherName,
      senderRole: learnerRole,
      receiverRole: teacherRole,
      subject: subject,
      lastMessage: body.length > 60 ? body.substring(0, 60) : body,
      now: now,
      type: 'homework',
    );

    await AuditLogService.logSuccess(
      actionKey: AuditActionKeys.learnerHomeworkSubmit,
      domain: AuditDomain.homework,
      summary: 'Learner submitted homework for session $sessionId',
      actor: AuditActor(uid: _uid, role: 'learner'),
      target: AuditTarget(
        type: 'teacher',
        uid: teacherUid,
        id: threadId,
        name: teacherName,
      ),
      keywords: [widget.courseKey, sessionId, threadId],
      context: {
        'courseKey': widget.courseKey,
        'sessionId': sessionId,
        'threadId': threadId,
      },
      meta: {
        'hasHomeworkText': homeworkText.trim().isNotEmpty,
        'hasDueDate': dueDate.trim().isNotEmpty,
      },
    );

    try {
      await PushDispatchService.dispatchMailToUser(
        targetUid: teacherUid,
        threadId: threadId,
        peerUid: _uid,
        title: subject,
        preview: body.length > 80 ? body.substring(0, 80) : body,
        nowMs: now,
        context: const PushDispatchContext(
          screen: 'learner/learner_homework',
          action: 'homework_submit_push',
        ),
      );
    } catch (_) {}

    if (!mounted) return;

    await OfflineActionGuard.runExclusive(
      context,
      'learner.homework.open_mail.$sessionId',
      () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LearnerMailThreadScreen(
              threadId: threadId,
              peerUid: teacherUid,
              peerName: teacherName.isEmpty ? 'Teacher' : teacherName,
              subject: subject,
            ),
          ),
        );
      },
    );

    // ✅ refresh list so submittedAt appears
    if (mounted) await _load();
  }

  Future<void> _deleteAutoHomeworkMessageIfAllowed({
    required String sessionId,
    required String homeworkRefPath,
    required String teacherUid,
  }) async {
    try {
      if (teacherUid.trim().isEmpty) return;

      // Read latest homework state (do NOT rely only on UI state)
      final hwSnap = await _hwRefByPath(homeworkRefPath).get();
      if (!hwSnap.exists || hwSnap.value == null) return;

      final hw = Map<String, dynamic>.from(hwSnap.value as Map);

      // Only allow delete if teacher has NOT reviewed
      final reviewedAt = hw['reviewedAt'];
      if (reviewedAt != null) return;

      final msgKey = (hw['autoMailMsgKey'] ?? '').toString().trim();
      if (msgKey.isEmpty) return;

      final threadId = '${_uid}_${teacherUid}_$sessionId';
      final now = _nowMs();

      // Delete only the auto-created message (both sides share same mail_messages path)
      // Also clear the saved key so we don't try to delete twice.
      final Map<String, dynamic> updates = {
        'mail_messages/$threadId/$msgKey': null,
        '$homeworkRefPath/autoMailMsgKey': null,

        // Optional: reduce clutter in lists by clearing previews (safe UI-only)
        'mail_threads/$threadId/lastMessage': '',
        'mail_threads/$threadId/updatedAt': now,
        'mail_index/$_uid/$threadId/lastMessage': '',
        'mail_index/$_uid/$threadId/updatedAt': now,
        'mail_index/$teacherUid/$threadId/lastMessage': '',
        'mail_index/$teacherUid/$threadId/updatedAt': now,
      };

      await _db.update(updates);
    } catch (_) {}
  }

  Future<void> _toggleDone(
    String sessionId, {
    required String homeworkRefPath,
    required bool currentlyDone,
  }) async {
    try {
      if (currentlyDone) {
        // undo
        await _hwRefByPath(homeworkRefPath).child('doneAt').remove();
        await AuditLogService.logSuccess(
          actionKey: AuditActionKeys.learnerHomeworkUndoSubmit,
          domain: AuditDomain.homework,
          summary: 'Learner unmarked homework done for session $sessionId',
          actor: AuditActor(uid: _uid, role: 'learner'),
          target: AuditTarget(
            type: 'course',
            id: widget.courseKey,
            name: widget.courseTitle,
          ),
          keywords: [widget.courseKey, sessionId],
        );
      } else {
        await _hwRefByPath(homeworkRefPath).update({'doneAt': _nowMs()});
        await AuditLogService.logSuccess(
          actionKey: AuditActionKeys.learnerHomeworkDone,
          domain: AuditDomain.homework,
          summary: 'Learner marked homework done for session $sessionId',
          actor: AuditActor(uid: _uid, role: 'learner'),
          target: AuditTarget(
            type: 'course',
            id: widget.courseKey,
            name: widget.courseTitle,
          ),
          keywords: [widget.courseKey, sessionId],
        );
      }
    } catch (e) {
      await AuditLogService.logFailure(
        actionKey: currentlyDone
            ? AuditActionKeys.learnerHomeworkUndoSubmit
            : AuditActionKeys.learnerHomeworkDone,
        domain: AuditDomain.homework,
        summary: 'Learner homework state update failed',
        actor: AuditActor(uid: _uid, role: 'learner'),
        target: AuditTarget(type: 'course', id: widget.courseKey),
        keywords: [widget.courseKey, sessionId],
        errorMessage: e.toString(),
      );
    }
  }

  // ---- Bilingual helpers ----
  String _confirmTitle() {
    switch (_lang) {
      case 'ar':
        return 'إرسال الواجب؟';
      default:
        return 'Send homework email?';
    }
  }

  List<String> _confirmBullets() {
    switch (_lang) {
      case 'ar':
        return [
          'بعد النقر على "نعم، أرسل"، تأكد من رفع ملف الواجب (صورة أو صوت أو فيديو).',
          'سيتلقى المدرس إشعارًا وسيقوم بمراجعة تسليمك.',
        ];
      default:
        return [
          'After clicking "Yes, Send", make sure to upload the homework file (picture, audio, or video).',
          'The teacher will receive a notification and review your submission.',
        ];
    }
  }

  String _btnNotYet() {
    switch (_lang) {
      case 'ar':
        return 'ليس الآن';
      default:
        return 'Not yet';
    }
  }

  String _btnYesSend() {
    switch (_lang) {
      case 'ar':
        return 'نعم، أرسل';
      default:
        return 'Yes, send';
    }
  }

  Future<bool> _confirmFirstSubmit() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          Widget langChip(String label, String code) {
            final selected = _lang == code;
            return GestureDetector(
              onTap: () {
                setState(() => _lang = code);
                setDialogState(() {});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: selected ? UiK.primaryBlue : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: UiK.primaryBlue.withValues(alpha: 0.6),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : UiK.primaryBlue,
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: Text(_confirmTitle()),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    langChip('English', 'en'),
                    const SizedBox(width: 8),
                    langChip('العربية', 'ar'),
                  ],
                ),
                const SizedBox(height: 16),
                for (final bullet in _confirmBullets())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '• ',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        Expanded(child: Text(bullet)),
                      ],
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(_btnNotYet()),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(_btnYesSend()),
              ),
            ],
          );
        },
      ),
    );
    return result ?? false;
  }

  @override
  void initState() {
    super.initState();
    _restoreFromCache();
    _load();
  }

  void _restoreFromCache() {
    final cacheKey = 'learner_${widget.courseKey}_items';
    final cached = HomeworkCacheService.instance.retrieve<List<Map<String, dynamic>>>(cacheKey);
    if (cached != null) {
      _items = cached;
      _busy = false;
    }
  }

  void _storeInCache() {
    final cacheKey = 'learner_${widget.courseKey}_items';
    HomeworkCacheService.instance.store(cacheKey, _items);
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _items = [];
      _uid = '';
      _learnerUid = '';
      _courseId = '';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;
      _learnerUid = await _resolveLearnerUidFromAuth(_uid);

      _usersRef
          .child('$_uid/courses/${widget.courseKey}/attendance')
          .keepSynced(true);

      final courseSnap = await _usersRef
          .child(_uid)
          .child('courses')
          .child(widget.courseKey)
          .child('id')
          .get();
      _courseId = (courseSnap.value ?? '').toString().trim();

      final List<Map<String, dynamic>> list = [];

      Future<void> addItemsFromMap({
        required Map<String, dynamic> raw,
        required String source,
      }) async {
        for (final entry in raw.entries) {
          if (entry.value is! Map) continue;
          final rec = Map<String, dynamic>.from(entry.value as Map);

          Map<String, dynamic> hw = <String, dynamic>{};
          if (rec['homework'] is Map) {
            hw = Map<String, dynamic>.from(rec['homework'] as Map);
          }

          if (hw.isEmpty) {
            final legacyText = (rec['homeworkLastBody'] ?? '')
                .toString()
                .trim();
            final legacySubject = (rec['homeworkSubject'] ?? '')
                .toString()
                .trim();
            if (legacyText.isNotEmpty || legacySubject.isNotEmpty) {
              hw = {
                'text': legacyText.isNotEmpty ? legacyText : legacySubject,
                'dueDate': '',
                'doneAt': rec['doneAt'],
                'submittedAt': rec['submittedAt'],
                'reviewedAt': rec['reviewedAt'],
                'autoMailMsgKey': rec['autoMailMsgKey'] ?? '',
                'reviewStatus': rec['reviewStatus'] ?? '',
                'reviewScore': rec['reviewScore'],
                'reviewGrade': rec['reviewGrade'] ?? '',
                'reviewNote': rec['reviewNote'] ?? '',
                'needsRedo': rec['needsRedo'] ?? false,
              };
            }
          }

          final text = (hw['text'] ?? hw['homeworkText'] ?? '')
              .toString()
              .trim();
          final due = (hw['dueDate'] ?? '').toString().trim();
          if (text.isEmpty && due.isEmpty) continue;

          final sessionId = entry.key.toString();
          final itemKey = _itemKey(source, sessionId);
          final homeworkRefPath = source == 'online'
              ? 'booking_progress/$_learnerUid/$_courseId/online_attendance/$sessionId/homework'
              : _legacyHwRefPath(sessionId);

          final taughtTitle = source == 'online'
              ? 'Online session ${(rec['sessionNo'] ?? '').toString().trim()}'
              : ((rec['taught'] is Map)
                    ? (Map<String, dynamic>.from(
                                rec['taught'] as Map,
                              )['title'] ??
                              '')
                          .toString()
                    : '');

          final date = source == 'online'
              ? _formatOnlineWhen(rec)
              : (rec['date'] ?? '').toString();

          final seenAt = hw['seenAt'];
          final doneAt = hw['doneAt'];
          final submittedAt = hw['submittedAt'];
          final reviewedAt = hw['reviewedAt'];
          final autoMailMsgKey = (hw['autoMailMsgKey'] ?? '').toString().trim();
          final reviewStatus = (hw['reviewStatus'] ?? '').toString().trim();
          final reviewScore = hw['reviewScore'];
          final reviewGrade = (hw['reviewGrade'] ?? '').toString().trim();
          final reviewNote = (hw['reviewNote'] ?? '').toString();
          final needsRedo = hw['needsRedo'] == true;

          final classId = (rec['class_id'] ?? '').toString().trim();
          final receiver = await _resolveHomeworkReceiver(
            classId: classId,
            fallbackUid: (rec['teacherUid'] ?? '').toString(),
            fallbackName: (rec['teacherName'] ?? '').toString(),
          );

          list.add({
            'itemKey': itemKey,
            'source': source,
            'homeworkRefPath': homeworkRefPath,
            'classId': classId,
            'sessionId': sessionId,
            'date': date,
            'taughtTitle': taughtTitle,
            'text': text,
            'dueDate': due,
            'seenAt': seenAt,
            'doneAt': doneAt,
            'submittedAt': submittedAt,
            'autoMailMsgKey': autoMailMsgKey,
            'reviewedAt': reviewedAt,
            'reviewStatus': reviewStatus,
            'reviewScore': reviewScore,
            'reviewGrade': reviewGrade,
            'reviewNote': reviewNote,
            'needsRedo': needsRedo,
            'teacherUid': receiver.uid,
            'teacherName': receiver.name,
          });
        }
      }

      final inClassSnap = await _usersRef
          .child(_uid)
          .child('courses')
          .child(widget.courseKey)
          .child('attendance')
          .get();
      if (inClassSnap.exists && inClassSnap.value is Map) {
        await addItemsFromMap(
          raw: Map<String, dynamic>.from(inClassSnap.value as Map),
          source: 'in_class',
        );
      }

      if (_courseId.isNotEmpty) {
        final onlineSnap = await _db
            .child('booking_progress/$_learnerUid/$_courseId/online_attendance')
            .get();
        if (onlineSnap.exists && onlineSnap.value is Map) {
          await addItemsFromMap(
            raw: Map<String, dynamic>.from(onlineSnap.value as Map),
            source: 'online',
          );
        }
      }

      list.sort(
        (a, b) => (b['date'] ?? '').toString().compareTo(
          (a['date'] ?? '').toString(),
        ),
      );

      setState(() {
        _items = list;
        _busy = false;
      });
      _storeInCache();
    } catch (e) {
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Widget _statusBadge({
    required String text,
    required Color bg,
    required Color fg,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: fg,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- New: compact stats ----------
  Map<String, dynamic> _calcStats(List<Map<String, dynamic>> items) {
    int total = items.length;
    int done = 0;
    int left = 0;
    int reviewed = 0;
    int redo = 0;

    final Map<String, int> gradeCount = {'A': 0, 'B': 0, 'C': 0, 'D': 0};

    for (final it in items) {
      final doneAt = it['doneAt'];
      final isDone = doneAt != null;
      if (isDone) done++;

      final submittedAt = it['submittedAt'];
      final reviewedAt = it['reviewedAt'];
      final reviewStatus = (it['reviewStatus'] ?? '').toString().trim();
      final needsRedo = it['needsRedo'] == true;

      if (reviewedAt != null) reviewed++;
      if (reviewStatus == 'redo' || needsRedo) redo++;

      final g = (it['reviewGrade'] ?? '').toString().trim().toUpperCase();
      if (gradeCount.containsKey(g)) {
        gradeCount[g] = (gradeCount[g] ?? 0) + 1;
      }

      // "Left" = not submitted yet (simple & clear)
      if (submittedAt == null) left++;
    }

    String commonGrade = '—';
    int best = 0;
    for (final e in gradeCount.entries) {
      if (e.value > best) {
        best = e.value;
        commonGrade = e.value == 0 ? '—' : e.key;
      }
    }

    return {
      'total': total,
      'done': done,
      'left': left,
      'reviewed': reviewed,
      'redo': redo,
      'commonGrade': commonGrade,
    };
  }

  // ---------- New: coloring helpers ----------
  Color _gradeTint(String grade) {
    final g = grade.trim().toUpperCase();
    if (g == 'A') return Colors.green.withValues(alpha: 0.08);
    if (g == 'B') return Colors.blue.withValues(alpha: 0.08);
    if (g == 'C') return Colors.orange.withValues(alpha: 0.10);
    if (g == 'D') return Colors.red.withValues(alpha: 0.08);
    return Colors.white;
  }

  Color _gradeAccent(String grade) {
    final g = grade.trim().toUpperCase();
    if (g == 'A') return Colors.green;
    if (g == 'B') return Colors.blue;
    if (g == 'C') return Colors.orange;
    if (g == 'D') return Colors.red;
    return UiK.primaryBlue;
  }

  Widget _statsCard() {
    final s = _calcStats(_items);

    Widget chip(String label, String value, IconData icon) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: UiK.primaryBlue.withValues(alpha: 0.85),
            ),
            const SizedBox(width: 8),
            Text(
              '$label: ',
              style: TextStyle(
                color: UiK.mainText.withValues(alpha: 0.75),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12,
                color: UiK.mainText,
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_rounded, color: UiK.primaryBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your homework overview',
                    style: UiK.titleText(size: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                chip(
                  'Done',
                  '${s['done']}/${s['total']}',
                  Icons.check_circle_rounded,
                ),
                chip('Left', '${s['left']}', Icons.pending_actions_rounded),
                chip('Reviewed', '${s['reviewed']}', Icons.fact_check_rounded),
                chip('Redo', '${s['redo']}', Icons.refresh_rounded),
                chip(
                  'Common grade',
                  '${s['commonGrade']}',
                  Icons.grade_rounded,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1180,
    );

    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: Text(
          '${widget.courseTitle} - Homework',
          style: const TextStyle(
            color: UiK.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1380,
        child: WatermarkBackground(
          child: _busy
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _items.isEmpty
              ? const Center(
                  child: Text(
                    'No homework yet.',
                    style: TextStyle(
                      color: UiK.mainText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                )
              : (desktopWorkspace
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 340,
                            child: ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                _statsCard(),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: UiK.uiBorder.withValues(
                                        alpha: 0.9,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    'Keep your homework summary visible while reviewing assignments and opening feedback chats.',
                                    style: UiK.subtleText().copyWith(
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: _buildHomeworkTimeline(
                              includeStatsHeader: false,
                              padding: const EdgeInsets.fromLTRB(0, 0, 16, 0),
                            ),
                          ),
                        ],
                      )
                    : _buildHomeworkTimeline(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewPadding.bottom + 20,
                      ),
                    )),
        ),
      ),
    );
  }

  Widget _buildHomeworkTimeline({
    bool includeStatsHeader = true,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) {
    return ListView.builder(
      padding: padding,
      itemCount: _items.length + (includeStatsHeader ? 1 : 0),
      itemBuilder: (_, idx) {
        if (includeStatsHeader && idx == 0) return _statsCard();

        final it = _items[idx - (includeStatsHeader ? 1 : 0)];

        final date = (it['date'] ?? '').toString();
        final due = (it['dueDate'] ?? '').toString();
        final text = (it['text'] ?? '').toString();
        final taughtTitle = (it['taughtTitle'] ?? '').toString();
        final sessionId = (it['sessionId'] ?? '').toString();
        final itemKey = (it['itemKey'] ?? sessionId).toString();
        final homeworkRefPath = (it['homeworkRefPath'] ?? '').toString().trim();
        final isExpanded = _expanded.contains(itemKey);
        final seenAt = it['seenAt'];
        final doneAt = it['doneAt'];
        final isSeen = seenAt != null;
        final isDone = doneAt != null;
        final submittedAt = it['submittedAt'];
        final reviewedAt = it['reviewedAt'];
        final autoMailMsgKey = (it['autoMailMsgKey'] ?? '').toString().trim();
        final reviewStatus = (it['reviewStatus'] ?? '').toString().trim();
        final needsRedo = it['needsRedo'] == true;
        final reviewScore = it['reviewScore'];
        final reviewGrade = (it['reviewGrade'] ?? '').toString().trim();
        final reviewNote = (it['reviewNote'] ?? '').toString();
        final bool isRedo = (reviewStatus == 'redo') || needsRedo;
        final bool isReviewed = reviewedAt != null;

        final Color cardBg = isRedo
            ? Colors.red.withValues(alpha: 0.06)
            : (isReviewed && reviewGrade.isNotEmpty
                  ? _gradeTint(reviewGrade)
                  : Colors.white);

        final Color accent = isRedo
            ? Colors.red
            : (isReviewed && reviewGrade.isNotEmpty
                  ? _gradeAccent(reviewGrade)
                  : UiK.primaryBlue);

        Widget buildTopBadges() {
          if (isReviewed) {
            if (isRedo) {
              return _statusBadge(
                text: 'Redo',
                bg: Colors.red.withValues(alpha: 0.10),
                fg: Colors.red,
                icon: Icons.refresh_rounded,
              );
            }
            return _statusBadge(
              text: 'Passed',
              bg: Colors.green.withValues(alpha: 0.10),
              fg: Colors.green,
              icon: Icons.check_circle_rounded,
            );
          }

          if (submittedAt != null) {
            return _statusBadge(
              text: 'Submitted',
              bg: Colors.amber.withValues(alpha: 0.15),
              fg: Colors.orange,
              icon: Icons.upload_file_rounded,
            );
          }

          return _statusBadge(
            text: 'Not submitted',
            bg: Colors.red.withValues(alpha: 0.08),
            fg: Colors.red,
            icon: Icons.error_outline_rounded,
          );
        }

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () async {
            final willExpand = !_expanded.contains(itemKey);
            setState(() {
              if (willExpand) {
                _expanded.add(itemKey);
              } else {
                _expanded.remove(itemKey);
              }
            });
            if (willExpand && !isSeen) {
              await _markSeen(homeworkRefPath);
              if (mounted) {
                setState(() {
                  it['seenAt'] = _nowMs();
                });
              }
            }
          },
          child: Card(
            elevation: 0,
            color: cardBg,
            shape: UiK.cardShape(),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: accent.withValues(alpha: 0.22)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  date.isEmpty ? 'Session' : date,
                                  style: UiK.titleText(size: 15),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                isExpanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 20,
                                color: UiK.primaryBlue.withValues(alpha: 0.7),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        buildTopBadges(),
                        const SizedBox(width: 8),
                        if (isDone)
                          Icon(
                            Icons.check_circle_rounded,
                            size: 18,
                            color: UiK.primaryBlue.withValues(alpha: 0.85),
                          )
                        else if (isSeen)
                          Icon(
                            Icons.visibility_rounded,
                            size: 18,
                            color: UiK.actionOrange.withValues(alpha: 0.85),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (!isExpanded) ...[
                      Text(
                        (due.isNotEmpty
                            ? 'Due: $due'
                            : (taughtTitle.isNotEmpty
                                  ? taughtTitle
                                  : 'Homework')),
                        style: UiK.subtleText(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (isReviewed && reviewGrade.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.grade_rounded, size: 18, color: accent),
                            const SizedBox(width: 6),
                            Text(
                              'Grade: ${reviewGrade.toUpperCase()}',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: accent,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ] else ...[
                      if (isReviewed) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.grade_rounded, size: 18, color: accent),
                            const SizedBox(width: 6),
                            Text(
                              reviewGrade.isNotEmpty
                                  ? 'Grade: ${reviewGrade.toUpperCase()}'
                                  : 'Grade: —',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: accent,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Icon(Icons.score_rounded, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              'Score: ${(reviewScore ?? 0).toString()}/100',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                        if (isRedo) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Teacher asked you to redo this homework.',
                            style: TextStyle(
                              color: Colors.red.withValues(alpha: 0.85),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                        if (reviewNote.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Teacher note:',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: UiK.mainText.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(reviewNote, style: UiK.subtleText()),
                        ],
                      ],
                      if (taughtTitle.isNotEmpty) ...[
                        if (!isReviewed) const SizedBox(height: 6),
                        Text('Lesson: $taughtTitle', style: UiK.subtleText()),
                      ],
                      if (due.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('Due: $due', style: UiK.subtleText()),
                      ],
                      if (text.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: UiK.uiBorder.withValues(alpha: 0.85),
                            ),
                            color: Colors.white.withValues(alpha: 0.65),
                          ),
                          child: Text(text, style: UiK.subtleText()),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (!(isDone && isReviewed))
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: Icon(
                                  isDone
                                      ? Icons.undo_rounded
                                      : Icons.check_circle_rounded,
                                ),
                                label: Text(isDone ? 'Undo' : 'Mark done/Send'),
                                style: OutlinedButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: () async {
                                  final teacherUid = (it['teacherUid'] ?? '')
                                      .toString()
                                      .trim();
                                  final teacherName = (it['teacherName'] ?? '')
                                      .toString();
                                  final homeworkRefPath =
                                      (it['homeworkRefPath'] ?? '')
                                          .toString()
                                          .trim();
                                  if (isDone) {
                                    if (!isReviewed) {
                                      await _deleteAutoHomeworkMessageIfAllowed(
                                        sessionId: sessionId,
                                        homeworkRefPath: homeworkRefPath,
                                        teacherUid: teacherUid,
                                      );
                                      if (mounted) {
                                        setState(() {
                                          it['autoMailMsgKey'] = '';
                                        });
                                      }
                                    }
                                    await _toggleDone(
                                      sessionId,
                                      homeworkRefPath: homeworkRefPath,
                                      currentlyDone: true,
                                    );
                                    if (mounted) {
                                      setState(() => it['doneAt'] = null);
                                    }
                                    return;
                                  }
                                  final isFirstSend =
                                      submittedAt == null &&
                                      autoMailMsgKey.isEmpty;
                                  if (isFirstSend) {
                                    final ok = await _confirmFirstSubmit();
                                    if (!ok) return;
                                  }
                                  final now = _nowMs();
                                  await _hwRefByPath(homeworkRefPath).update({
                                    'doneAt': now,
                                    'submittedAt': now,
                                    'seenAt': it['seenAt'] ?? now,
                                  });
                                  if (mounted) {
                                    setState(() {
                                      it['doneAt'] = now;
                                      it['submittedAt'] = now;
                                      it['seenAt'] ??= now;
                                    });
                                  }
                                  await _createHomeworkMailAndOpen(
                                    sessionId: sessionId,
                                    teacherUid: teacherUid,
                                    teacherName: teacherName,
                                    date: date,
                                    dueDate: due,
                                    taughtTitle: taughtTitle,
                                    homeworkText: text,
                                    homeworkRefPath: homeworkRefPath,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 10),
                      if (submittedAt != null && autoMailMsgKey.isNotEmpty) ...[
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.mail_outline_rounded),
                                label: const Text('Open HW chat'),
                                style: OutlinedButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: () async {
                                  final teacherUid = (it['teacherUid'] ?? '')
                                      .toString()
                                      .trim();
                                  if (teacherUid.isEmpty) return;
                                  final threadId =
                                      '${_uid}_${teacherUid}_$sessionId';
                                  final subject =
                                      '[HW] ${widget.courseTitle} • $date${taughtTitle.isEmpty ? '' : ' • $taughtTitle'}';
                                  await OfflineActionGuard.runExclusive(
                                    context,
                                    'learner.homework.open_mail.$sessionId',
                                    () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              LearnerMailThreadScreen(
                                                threadId: threadId,
                                                peerUid: teacherUid,
                                                peerName:
                                                    ((it['teacherName'] ?? '')
                                                        .toString()
                                                        .trim()
                                                        .isEmpty)
                                                    ? 'Teacher'
                                                    : (it['teacherName'] ?? '')
                                                          .toString()
                                                          .trim(),
                                                subject: subject,
                                              ),
                                        ),
                                      );
                                    },
                                  );
                                  if (mounted) await _load();
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HomeworkReceiver {
  const _HomeworkReceiver({this.uid = '', this.name = ''});

  final String uid;
  final String name;
}
