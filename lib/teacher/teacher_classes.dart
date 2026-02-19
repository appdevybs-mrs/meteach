// teacher_classes_screen.dart
// ✅ Drop-in replacement for your TeacherClassesScreen
// Adds:
// - "Progress" button per class
// - Progress bar in class card (class taught sessions vs syllabus total)
// - Uses classes/<classId>/attendance taught.sessionId + syllabi/<course_id>
// - Keeps your existing Take/History/Stats flow intact

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'package:fluttertoast/fluttertoast.dart';

import 'take_attendance_screen.dart';
import 'attendance_history_screen.dart';
import 'attendance_stats_screen.dart';

import '../calls/audio_call_screen.dart';
import '../services/push_client.dart';
import 'teacher_mail_thread_screen.dart';

// ✅ NEW
import 'teacher_class_progress_screen.dart';

class TeacherClassesScreen extends StatefulWidget {
  const TeacherClassesScreen({super.key});

  @override
  State<TeacherClassesScreen> createState() => _TeacherClassesScreenState();
}

class _TeacherClassesScreenState extends State<TeacherClassesScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  static const String usersNode = "users";
  static const String classesNode = "classes";
  static const String syllabiNode = "syllabi";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  bool _busy = true;
  String? _error;

  String _teacherUid = '';
  String _teacherSerial = '';
  String _teacherName = '';

  List<Map<String, dynamic>> _myClasses = [];

  // ✅ Cache progress per class so cards don't constantly re-fetch
  final Map<String, _ClassProg> _classProgCache = {};

  @override
  void initState() {
    super.initState();
    _loadMyClasses();
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  Future<void> _loadMyClasses() async {
    setState(() {
      _busy = true;
      _error = null;
      _myClasses = [];
      _teacherUid = '';
      _teacherSerial = '';
      _teacherName = '';
      _classProgCache.clear();
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');

      _teacherUid = user.uid;

      final userSnap = await _usersRef.child(_teacherUid).get();
      if (!userSnap.exists) throw Exception('Teacher user record not found in /users/<uid>.');

      final u = (userSnap.value is Map)
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};

      _teacherSerial = (u['serial'] ?? '').toString().trim();
      final fn = (u['first_name'] ?? '').toString().trim();
      final ln = (u['last_name'] ?? '').toString().trim();
      _teacherName = ('$fn $ln').trim();

      if (!_isTeacherRole(u['role'])) {
        throw Exception('Your account role is not "teacher". Found: "${u['role']}"');
      }

      final classesSnap = await _classesRef.get();
      if (!classesSnap.exists || classesSnap.value == null) {
        setState(() {
          _myClasses = [];
          _busy = false;
        });
        return;
      }

      final raw = (classesSnap.value is Map)
          ? Map<dynamic, dynamic>.from(classesSnap.value as Map)
          : <dynamic, dynamic>{};

      final List<Map<String, dynamic>> mine = [];

      raw.forEach((key, value) {
        final c = (value is Map)
            ? Map<String, dynamic>.from(value as Map)
            : <String, dynamic>{};

        String curUid = '';
        String curName = '';

        final cur = c['instructor_current'];
        if (cur is Map) {
          final curMap = Map<String, dynamic>.from(cur);
          curUid = (curMap['uid'] ?? '').toString().trim();
          curName = (curMap['name'] ?? '').toString().trim();
        }

        final legacyInstructorName = (c['instructor'] ?? '').toString().trim();

        final matchesUid = curUid.isNotEmpty && curUid == _teacherUid;

        final matchesName = _teacherName.isNotEmpty &&
            _norm(legacyInstructorName.isNotEmpty ? legacyInstructorName : curName) ==
                _norm(_teacherName);

        final legacySerial = (c['instructorserial'] ?? c['serial'] ?? '').toString().trim();
        final matchesSerial = _teacherSerial.isNotEmpty && legacySerial == _teacherSerial;

        if (matchesUid || matchesName || matchesSerial) {
          mine.add({
            'id': key.toString(), // ✅ add classId for navigation
            ...c.map((k, v) => MapEntry(k.toString(), v)),
          });
        }
      });

      mine.sort((a, b) {
        int numVal(dynamic v) {
          if (v is num) return v.toInt();
          return int.tryParse(v?.toString() ?? '') ?? 0;
        }

        final aU = numVal(a['updated_at'] ?? a['updatedAt'] ?? 0);
        final bU = numVal(b['updated_at'] ?? b['updatedAt'] ?? 0);
        if (aU != bU) return bU.compareTo(aU);

        final aC = numVal(a['created_at'] ?? a['createdAt'] ?? 0);
        final bC = numVal(b['created_at'] ?? b['createdAt'] ?? 0);
        return bC.compareTo(aC);
      });

      setState(() {
        _myClasses = mine;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  int _learnersCount(Map<String, dynamic> classData) {
    final learners = classData['learners'];
    if (learners is Map) return learners.length;
    return 0;
  }

  // NEW: only what we need for the collapsed card
  String _firstSessionDate(Map<String, dynamic> classData) {
    final schedule = classData['schedule'];
    if (schedule is Map) {
      final firstDate = (schedule['first_session_date'] ?? '').toString().trim();
      return firstDate.isEmpty ? '-' : firstDate;
    }
    return '-';
  }

  Future<Map<String, dynamic>> _loadLearner(String uid) async {
    final snap = await _usersRef.child(uid).get();
    if (!snap.exists) return {'uid': uid};

    final data = (snap.value is Map)
        ? Map<String, dynamic>.from(snap.value as Map)
        : <String, dynamic>{};

    return {
      'uid': uid,
      'first_name': (data['first_name'] ?? '').toString(),
      'last_name': (data['last_name'] ?? '').toString(),
      'email': (data['email'] ?? '').toString(),
      'phone1': (data['phone1'] ?? '').toString(),
      'status': (data['status'] ?? '').toString(),
      'serial': (data['serial'] ?? '').toString(),
    };
  }

  // ----------------------------
  // Teacher -> Learner quick actions (your existing logic)
  // ----------------------------

  void _toast(String msg) {
    if (!mounted) return;

    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
  }

  Future<String?> _getLearnerFcmToken(String learnerUid) async {
    final snap = FirebaseDatabase.instance.ref('fcm_tokens/$learnerUid/token');
    final got = await snap.get();
    final token = got.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<void> _sendLearnerReminderWithPush({
    required String learnerUid,
    required String title,
    required String message,
    required String kind, // 'homework' | 'custom'
  }) async {
    final teacher = FirebaseAuth.instance.currentUser;

    // 1) ALWAYS write reminder in RTDB
    final reminderRef = FirebaseDatabase.instance
        .ref('reminders/$learnerUid')
        .push();

    try {
      await reminderRef.set({
        'kind': kind,
        'title': title,
        'description': message,
        'attachment_name': '',
        'attachment_url': '',
        'createdAt': ServerValue.timestamp,
        'createdByUid': teacher?.uid ?? '',
        'teacher': {
          'name': _teacherName.isEmpty ? 'Teacher' : _teacherName,
          'email': teacher?.email ?? '',
        },
        'status': 'queued',
        'readAt': null,
        'doneAt': null,
        'push': {
          'attemptedAt': null,
          'sentAt': null,
          'error': null,
        }
      });
    } catch (e) {
      _toast('RTDB write failed: $e');
      return;
    }

    // 2) Push
    final token = await _getLearnerFcmToken(learnerUid);

    await reminderRef.child('push/attemptedAt').set(ServerValue.timestamp);

    if (token == null || token.isEmpty) {
      await reminderRef.update({'status': 'push_skipped_no_token'});
      _toast('Reminder saved ✅ (learner offline)');
      return;
    }

    try {
      await PushClient.sendToToken(
        token: token,
        title: title,
        message: message,
        data: {
          'type': 'reminder',
          'route': 'learner',
          'learnerUid': learnerUid,
          'kind': kind,
          'reminderId': reminderRef.key,
        },
      );

      await reminderRef.update({
        'status': 'push_sent',
        'push/sentAt': ServerValue.timestamp,
        'push/error': null,
      });

      _toast('Reminder saved & push sent ✅');
    } catch (e) {
      await reminderRef.update({
        'status': 'push_error',
        'push/error': e.toString(),
      });
      _toast('Reminder saved but push failed');
    }
  }

  Future<void> _askAndSendCustomReminder({
    required String learnerUid,
  }) async {
    final c = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reminder'),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Type your reminder…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    ) ??
        false;

    if (!ok) return;

    final text = c.text.trim();
    if (text.isEmpty) {
      _toast('Nothing to send.');
      return;
    }

    await _sendLearnerReminderWithPush(
      learnerUid: learnerUid,
      title: 'Reminder',
      message: text,
      kind: 'custom',
    );
  }

  Future<void> _openOrCreateMailThread({
    required String learnerUid,
    required String learnerName,
  }) async {
    final meUid = FirebaseAuth.instance.currentUser!.uid;
    final a = meUid.compareTo(learnerUid) < 0 ? meUid : learnerUid;
    final b = meUid.compareTo(learnerUid) < 0 ? learnerUid : meUid;

    final threadId = 't_${a}_$b';

    final threadRef = FirebaseDatabase.instance.ref('mail_threads/$threadId');
    final indexRef = FirebaseDatabase.instance.ref('mail_index');

    const subject = 'Mail';

    final tSnap = await threadRef.get();
    final now = DateTime.now().millisecondsSinceEpoch;

    if (!tSnap.exists) {
      await threadRef.set({
        'subject': subject,
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': '',
      });
    }

    await indexRef.child(meUid).child(threadId).update({
      'subject': subject,
      'updatedAt': now,
      'lastMessage': '',
      'unreadCount': 0,
      'peerUid': learnerUid,
      'peerName': learnerName,
      'deletedAt': null,
    });

    await indexRef.child(learnerUid).child(threadId).update({
      'subject': subject,
      'updatedAt': now,
      'lastMessage': '',
      'unreadCount': 0,
      'peerUid': meUid,
      'peerName': _teacherName.isEmpty ? 'Teacher' : _teacherName,
      'deletedAt': null,
    });

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: RouteSettings(name: '/mail/thread/$threadId'),
        builder: (_) => TeacherMailThreadScreen(
          threadId: threadId,
          peerUid: learnerUid,
          peerName: learnerName.isEmpty ? 'Learner' : learnerName,
          subject: subject,
        ),
      ),
    );
  }

  Future<void> _callLearnerInApp({
    required String learnerUid,
    required String learnerName,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Call learner?'),
        content: Text('Call ${learnerName.isEmpty ? 'this learner' : learnerName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Call'),
          ),
        ],
      ),
    ) ??
        false;

    if (!ok) return;
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AudioCallScreen(
          peerUid: learnerUid,
          peerName: learnerName.isEmpty ? 'Learner' : learnerName,
          isCaller: true,
          callerName: _teacherName.isEmpty ? 'Teacher' : _teacherName,
          startWithVideo: false,
        ),
      ),
    );
  }

  Future<void> _showLearnerQuickActionsSheet({
    required String learnerUid,
    required String learnerName,
  }) async {
    if (!mounted) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),

            ListTile(
              leading: const Icon(Icons.menu_book_rounded),
              title: const Text('Reminder: homework'),
              onTap: () => Navigator.pop(ctx, 'homework'),
            ),

            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: const Text('Reminder: type your message'),
              onTap: () => Navigator.pop(ctx, 'custom'),
            ),

            ListTile(
              leading: const Icon(Icons.mail_rounded),
              title: const Text('Send a mail'),
              onTap: () => Navigator.pop(ctx, 'mail'),
            ),

            ListTile(
              leading: const Icon(Icons.call_rounded),
              title: const Text('Call (in-app)'),
              onTap: () => Navigator.pop(ctx, 'call'),
            ),

            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (picked == null) return;

    if (picked == 'homework') {
      await _sendLearnerReminderWithPush(
        learnerUid: learnerUid,
        title: 'Homework Reminder',
        message: 'Please don’t forget your homework for the next session.',
        kind: 'homework',
      );
      return;
    }

    if (picked == 'custom') {
      await _askAndSendCustomReminder(learnerUid: learnerUid);
      return;
    }

    if (picked == 'mail') {
      await _openOrCreateMailThread(
        learnerUid: learnerUid,
        learnerName: learnerName,
      );
      return;
    }

    if (picked == 'call') {
      await _callLearnerInApp(
        learnerUid: learnerUid,
        learnerName: learnerName,
      );
      return;
    }
  }

  // ----------------------------
  // ✅ Class progress (class attendance taught.sessionId vs syllabi sessions)
  // ----------------------------

  Future<_ClassProg> _loadClassProgress(String classId, Map<String, dynamic> classData) async {
    // cache hit
    if (_classProgCache.containsKey(classId)) return _classProgCache[classId]!;

    // total sessions from syllabi/<course_id>
    final courseId = (classData['course_id'] ?? '').toString().trim();
    int totalSessions = 0;

    if (courseId.isNotEmpty) {
      final sSnap = await _syllabiRef.child(courseId).get();
      if (sSnap.exists && sSnap.value is Map) {
        final s = Map<String, dynamic>.from(sSnap.value as Map);
        final units = s['units'];
        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final sessions = unit['sessions'];
            if (sessions is List) totalSessions += sessions.length;
          }
        }
      }
    }

    // covered sessions from classes/<classId>/attendance/*/taught/sessionId
    final att = classData['attendance'];
    final Set<String> covered = {};
    int held = 0;

    if (att is Map) {
      final m = Map<String, dynamic>.from(att);
      held = m.length;

      for (final entry in m.entries) {
        final rec = entry.value;
        if (rec is! Map) continue;
        final r = Map<String, dynamic>.from(rec);
        final taught = r['taught'];
        if (taught is Map) {
          final tm = Map<String, dynamic>.from(taught);
          final sid = (tm['sessionId'] ?? '').toString().trim();
          if (sid.isNotEmpty) covered.add(sid);
        }
      }
    }

    final coveredCount = covered.length;
    final pct = totalSessions <= 0 ? 0 : ((coveredCount / totalSessions) * 100).round().clamp(0, 100);

    final prog = _ClassProg(
      percent: pct,
      coveredCount: coveredCount,
      totalSessions: totalSessions,
      sessionsHeld: held,
    );

    _classProgCache[classId] = prog;
    return prog;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'My Classes',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: actionOrange),
            onPressed: _busy ? null : _loadMyClasses,
          ),
        ],
      ),
      body: Stack(
        children: [
          Container(color: appBg),
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
          if (_busy)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  elevation: 0,
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: uiBorder.withOpacity(0.8)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Teacher',
                          style: TextStyle(
                            color: primaryBlue,
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _teacherName.isEmpty ? '-' : _teacherName,
                          style: const TextStyle(
                            color: mainText,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                if (_myClasses.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No classes found for you yet.',
                          style: TextStyle(color: mainText, fontWeight: FontWeight.w800)),
                    ),
                  )
                else
                  ..._myClasses.map((c) => _classCard(c)).toList(),
              ],
            ),
        ],
      ),
    );
  }

  Widget _classCard(Map<String, dynamic> c) {
    final classId = (c['id'] ?? c['class_id'] ?? '').toString().trim();
    final title = (c['course_title'] ?? 'Class').toString();
    final duration = (c['course_duration'] ?? '').toString();
    final learnersCount = _learnersCount(c);

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        collapsedIconColor: primaryBlue,
        iconColor: primaryBlue,
        title: Text(title, style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Duration: ${duration.isEmpty ? '-' : duration}',
                style: TextStyle(color: mainText.withOpacity(0.8), fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'First session: ${_firstSessionDate(c)}',
                style: TextStyle(color: mainText.withOpacity(0.8), fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Learners: $learnersCount',
                style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700),
              ),

              // ✅ NEW: class progress bar (loads safely)
              const SizedBox(height: 10),
              FutureBuilder<_ClassProg>(
                future: (classId.isEmpty) ? Future.value(_ClassProg.zero()) : _loadClassProgress(classId, c),
                builder: (context, snap) {
                  final p = snap.data ?? _ClassProg.zero();
                  final pct = p.percent.clamp(0, 100);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.insights_rounded, size: 16, color: actionOrange),
                          const SizedBox(width: 8),
                          Text(
                            'Progress: $pct%  •  ${p.coveredCount}/${p.totalSessions <= 0 ? '-' : p.totalSessions} covered',
                            style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: p.totalSessions <= 0 ? 0 : (p.coveredCount / p.totalSessions).clamp(0, 1),
                          minHeight: 8,
                          backgroundColor: primaryBlue.withOpacity(0.10),
                          valueColor: const AlwaysStoppedAnimation(actionOrange),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        children: [
          const SizedBox(height: 8),

          // Buttons row 1: Take / History / Stats
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.fact_check_rounded),
                  label: const Text("Take"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: actionOrange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => TakeAttendanceScreen(classData: c)));
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.history_rounded, color: primaryBlue),
                  label: const Text("History", style: TextStyle(color: primaryBlue)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: uiBorder.withOpacity(0.9)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceHistoryScreen(classData: c)));
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.bar_chart_rounded, color: primaryBlue),
                  label: const Text("Stats", style: TextStyle(color: primaryBlue)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: uiBorder.withOpacity(0.9)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceStatsScreen(classData: c)));
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // ✅ NEW: Progress button (full width, clean)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.insights_rounded, color: primaryBlue),
              label: const Text("Progress", style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: uiBorder.withOpacity(0.9)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: classId.isEmpty
                  ? null
                  : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TeacherClassProgressScreen(
                      classId: classId,
                      classData: c,
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 14),

          Row(
            children: [
              const Icon(Icons.people_alt_rounded, color: primaryBlue, size: 18),
              const SizedBox(width: 8),
              Text('Learners ($learnersCount)', style: const TextStyle(color: mainText, fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 10),

          _learnersList(c),
        ],
      ),
    );
  }

  Widget _learnersList(Map<String, dynamic> c) {
    final learners = c['learners'];
    if (learners is! Map || learners.isEmpty) {
      return Text('No learners in this class yet.',
          style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700));
    }

    final m = Map<String, dynamic>.from(learners);
    final uids = m.keys.map((e) => e.toString()).toList();

    return Column(children: uids.map((uid) => _learnerTile(uid)).toList());
  }

  Widget _learnerTile(String uid) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _loadLearner(uid),
      builder: (context, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final data = snap.data ?? {'uid': uid};

        final fn = (data['first_name'] ?? '').toString().trim();
        final ln = (data['last_name'] ?? '').toString().trim();
        final name = ('$fn $ln').trim();
        final serial = (data['serial'] ?? '').toString().trim();
        final email = (data['email'] ?? '').toString().trim();
        final phone = (data['phone1'] ?? '').toString().trim();

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: uiBorder.withOpacity(0.85)),
          ),
          child: ListTile(
            dense: true,
            leading: GestureDetector(
              onLongPress: () async {
                if (loading) return;

                await _showLearnerQuickActionsSheet(
                  learnerUid: uid,
                  learnerName: name.isEmpty ? 'Learner' : name,
                );
              },
              child: CircleAvatar(
                backgroundColor: primaryBlue.withOpacity(0.08),
                child: const Icon(Icons.person_rounded, color: primaryBlue),
              ),
            ),
            title: Text(
              loading ? 'Loading...' : (name.isEmpty ? 'Learner: $uid' : name),
              style: const TextStyle(color: mainText, fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              [
                if (serial.isNotEmpty) 'Serial: $serial',
                if (email.isNotEmpty) email,
                if (phone.isNotEmpty) phone,
                if (serial.isEmpty && email.isEmpty && phone.isEmpty) 'UID: $uid',
              ].join(' • '),
              style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700),
            ),
          ),
        );
      },
    );
  }
}

class _ClassProg {
  final int percent;
  final int coveredCount;
  final int totalSessions;
  final int sessionsHeld;

  const _ClassProg({
    required this.percent,
    required this.coveredCount,
    required this.totalSessions,
    required this.sessionsHeld,
  });

  factory _ClassProg.zero() => const _ClassProg(
    percent: 0,
    coveredCount: 0,
    totalSessions: 0,
    sessionsHeld: 0,
  );
}
