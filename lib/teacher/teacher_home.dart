import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'teacher_profile.dart';
import 'teacher_classes.dart';
import 'teacher_payment.dart';
import 'teacher_mail.dart';
import 'teacher_reminder.dart';
import 'teacher_schedule.dart';
import '../shared/session_manager.dart';

// ✅ Call logs
import '../calls/call_logs_screen.dart';

// ✅ Call screen
import '../calls/audio_call_screen.dart';

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
  // ===== Brand colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  // RTDB nodes
  static const String usersNode = "users";
  static const String classesNode = "classes";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // Reminders: count not-done
  Stream<DatabaseEvent>? _remindersStream;

  // ✅ Mail: total unread (sum across threads)
  Stream<DatabaseEvent>? _mailIndexStream;

  // Classes summary (count classes + total learners)
  Future<_ClassesSummary>? _classesSummaryFuture;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid != null) {
      _remindersStream = _db.child('reminders/$uid').onValue.asBroadcastStream();
      _mailIndexStream = _db.child('mail_index/$uid').onValue.asBroadcastStream();
      _classesSummaryFuture = _loadClassesSummaryForHome(uid);
    }
  }

  // ✅ UPDATED: Now deletes FCM token before signing out
  Future<void> _logout(BuildContext context) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    // ✅ stop "single device" listener (so it doesn't run after logout)
    await SessionManager.stopListening();

    // ✅ (optional but recommended) remove session in RTDB
    if (userId != null && userId.isNotEmpty) {
      try {
        await FirebaseDatabase.instance.ref('sessions/$userId').remove();
      } catch (_) {}
    }

    // ✅ remove FCM token record (your existing behavior)
    try {
      if (userId != null && userId.isNotEmpty) {
        await FirebaseDatabase.instance.ref('fcm_tokens/$userId').remove();
      }
    } catch (e) {
      debugPrint("Error removing token: $e");
    }

    await FirebaseAuth.instance.signOut();

    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }


  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  bool _isAdminRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "admin" || r == "administrator";
  }

  int _learnersCount(Map<String, dynamic> classData) {
    final learners = classData['learners'];
    if (learners is Map) return learners.length;
    return 0;
  }

  Future<_ClassesSummary> _loadClassesSummaryForHome(String teacherUid) async {
    try {
      final usersRef = _db.child(usersNode);
      final classesRef = _db.child(classesNode);

      final userSnap = await usersRef.child(teacherUid).get();
      if (!userSnap.exists) return const _ClassesSummary(classesCount: 0, learnersCount: 0);

      final u = (userSnap.value is Map)
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};

      if (!_isTeacherRole(u['role'])) {
        return const _ClassesSummary(classesCount: 0, learnersCount: 0);
      }

      final teacherSerial = (u['serial'] ?? '').toString().trim();
      final fn = (u['first_name'] ?? '').toString().trim();
      final ln = (u['last_name'] ?? '').toString().trim();
      final teacherName = ('$fn $ln').trim();

      final classesSnap = await classesRef.get();
      if (!classesSnap.exists || classesSnap.value == null) {
        return const _ClassesSummary(classesCount: 0, learnersCount: 0);
      }

      final raw = (classesSnap.value is Map)
          ? Map<dynamic, dynamic>.from(classesSnap.value as Map)
          : <dynamic, dynamic>{};

      int classesCount = 0;
      int learnersTotal = 0;

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

        final matchesUid = curUid.isNotEmpty && curUid == teacherUid;

        final matchesName = teacherName.isNotEmpty &&
            _norm(legacyInstructorName.isNotEmpty ? legacyInstructorName : curName) ==
                _norm(teacherName);

        final legacySerial = (c['instructorserial'] ?? c['serial'] ?? '').toString().trim();
        final matchesSerial = teacherSerial.isNotEmpty && legacySerial == teacherSerial;

        if (matchesUid || matchesName || matchesSerial) {
          classesCount += 1;
          learnersTotal += _learnersCount(c);
        }
      });

      return _ClassesSummary(classesCount: classesCount, learnersCount: learnersTotal);
    } catch (_) {
      return const _ClassesSummary(classesCount: 0, learnersCount: 0);
    }
  }

  int _countNotDoneReminders(dynamic snapshotValue) {
    if (snapshotValue is! Map) return 0;
    int count = 0;

    snapshotValue.forEach((k, v) {
      if (v is Map) {
        final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
        final status = (m['status'] ?? 'new').toString().toLowerCase().trim();
        if (status != 'done') count += 1;
      }
    });

    return count;
  }

  int _countUnreadMail(dynamic snapshotValue) {
    if (snapshotValue is! Map) return 0;
    int total = 0;

    snapshotValue.forEach((k, v) {
      if (v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));

      // ignore deleted for me
      if (m['deletedAt'] != null) return;

      final unread = _toInt(m['unreadCount']);
      total += unread;
    });

    return total;
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Future<String> _myDisplayName() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return 'Teacher';

    try {
      final snap = await _db.child('users/$uid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        if (full.isNotEmpty) return full;
        final email = (m['email'] ?? '').toString().trim();
        if (email.isNotEmpty) return email.split('@').first;
      }
    } catch (_) {}
    return 'Teacher';
  }

  Future<List<_UserPick>> _loadAdmins() async {
    final out = <_UserPick>[];
    try {
      final snap = await _db.child('users').get();
      final v = snap.value;
      if (v is! Map) return out;

      final raw = Map<dynamic, dynamic>.from(v);
      raw.forEach((uid, val) {
        if (val is! Map) return;
        final m = val.map((k, vv) => MapEntry(k.toString(), vv));
        if (!_isAdminRole(m['role'])) return;

        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final name = ('$first $last').trim().isEmpty ? 'Admin' : ('$first $last').trim();

        out.add(_UserPick(uid: uid.toString(), name: name, subtitle: 'Admin'));
      });

      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    } catch (_) {
      return out;
    }
  }

  Future<List<_UserPick>> _loadLearnersInMyClasses() async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return [];

    final learners = <String, String>{};

    try {
      final classesSnap = await _db.child('classes').get();
      final v = classesSnap.value;
      if (v is! Map) return [];

      final raw = Map<dynamic, dynamic>.from(v);

      raw.forEach((classId, classVal) {
        if (classVal is! Map) return;
        final c = classVal.map((k, vv) => MapEntry(k.toString(), vv));

        bool isMine = false;
        final cur = c['instructor_current'];
        if (cur is Map) {
          final cm = cur.map((kk, vv) => MapEntry(kk.toString(), vv));
          final tuid = (cm['uid'] ?? '').toString().trim();
          if (tuid.isNotEmpty && tuid == me) isMine = true;
        }

        if (!isMine) return;

        final l = c['learners'];
        if (l is! Map) return;

        final lm = Map<dynamic, dynamic>.from(l);
        lm.forEach((uid, lv) {
          final u = uid.toString();
          if (u == me) return;

          String name = 'Learner';
          if (lv is Map) {
            final mm = lv.map((kk, vv) => MapEntry(kk.toString(), vv));
            final n = (mm['name'] ?? '').toString().trim();
            final serial = (mm['serial'] ?? '').toString().trim();
            name = n.isNotEmpty ? n : (serial.isNotEmpty ? serial : 'Learner');
          }
          learners.putIfAbsent(u, () => name);
        });
      });

      final out = <_UserPick>[];
      for (final entry in learners.entries) {
        final uid = entry.key;
        String name = entry.value;

        try {
          final snap = await _db.child('users/$uid').get();
          final vv = snap.value;
          if (vv is Map) {
            final m = vv.map((k, v) => MapEntry(k.toString(), v));
            final first = (m['first_name'] ?? '').toString().trim();
            final last = (m['last_name'] ?? '').toString().trim();
            final full = ('$first $last').trim();
            if (full.isNotEmpty) name = full;
          }
        } catch (_) {}

        out.add(_UserPick(uid: uid, name: name, subtitle: 'Learner'));
      }

      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> _startCallTo({
    required String peerUid,
    required String peerName,
  }) async {
    final myName = await _myDisplayName();
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AudioCallScreen(
          peerUid: peerUid,
          peerName: peerName,
          isCaller: true,
          callerName: myName,
        ),
      ),
    );
  }

  Future<void> _pickAndCall({
    required String title,
    required Future<List<_UserPick>> Function() loader,
    required IconData icon,
  }) async {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: appBg,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: FutureBuilder<List<_UserPick>>(
              future: loader(),
              builder: (context, snap) {
                final items = snap.data ?? const <_UserPick>[];

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: primaryBlue.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: uiBorder.withOpacity(0.9)),
                          ),
                          child: Icon(icon, color: primaryBlue),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: primaryBlue,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (snap.connectionState == ConnectionState.waiting)
                      const Padding(
                        padding: EdgeInsets.all(18),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (items.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: uiBorder.withOpacity(0.85)),
                        ),
                        child: const Text(
                          'No users found.',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.55,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, i) {
                            final it = items[i];
                            return InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () async {
                                Navigator.of(ctx).pop();
                                await _startCallTo(peerUid: it.uid, peerName: it.name);
                              },
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(color: uiBorder.withOpacity(0.85)),
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: primaryBlue.withOpacity(0.08),
                                      child: Text(
                                        it.name.isNotEmpty ? it.name[0].toUpperCase() : '?',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: primaryBlue,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            it.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: primaryBlue,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            it.subtitle,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: Colors.grey.shade600,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: actionOrange.withOpacity(0.10),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(color: actionOrange.withOpacity(0.22)),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.call_rounded, size: 16, color: actionOrange),
                                          SizedBox(width: 6),
                                          Text(
                                            'Call',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: actionOrange,
                                              fontSize: 12,
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
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSupportSheet() async {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: appBg,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: uiBorder.withOpacity(0.85)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.support_agent_rounded, color: primaryBlue),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Support Call',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: primaryBlue,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _SupportTile(
                  icon: Icons.admin_panel_settings_rounded,
                  title: 'Call Admin',
                  subtitle: 'Choose an admin to call',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickAndCall(
                      title: 'Choose Admin',
                      loader: _loadAdmins,
                      icon: Icons.admin_panel_settings_rounded,
                    );
                  },
                ),
                const SizedBox(height: 10),
                _SupportTile(
                  icon: Icons.groups_rounded,
                  title: 'Call Learner',
                  subtitle: 'Learners in your classes',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickAndCall(
                      title: 'Choose Learner',
                      loader: _loadLearnersInMyClasses,
                      icon: Icons.groups_rounded,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        centerTitle: true,
        title: const Text(
          'Teacher Dashboard',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Call Logs',
            icon: const Icon(Icons.history, color: primaryBlue),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CallLogsScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: actionOrange),
            onPressed: () => _logout(context),
          )
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.05,
                child: Center(
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    width: 280,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                Text(
                  'Welcome,',
                  style: TextStyle(
                    color: mainText.withOpacity(0.6),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  user?.email?.split('@')[0].toUpperCase() ?? 'TEACHER',
                  style: const TextStyle(
                    color: primaryBlue,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 32),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1.1,
                    children: [
                      _buildQuickCard(
                        context,
                        'Schedule',
                        Icons.calendar_today_rounded,
                        const TeacherSchedule(),
                      ),
                      FutureBuilder<_ClassesSummary>(
                        future: _classesSummaryFuture,
                        builder: (context, snap) {
                          final s = snap.data;
                          final subtitle = (s == null)
                              ? ''
                              : '${s.classesCount} classes • ${s.learnersCount} learners';
                          return _buildQuickCard(
                            context,
                            'My Classes',
                            Icons.school_rounded,
                            const TeacherClassesScreen(),
                            subtitle: subtitle,
                          );
                        },
                      ),
                      _buildQuickCard(
                        context,
                        'Profile',
                        Icons.person_rounded,
                        const TeacherProfileScreen(),
                      ),
                      StreamBuilder<DatabaseEvent>(
                        stream: _mailIndexStream,
                        builder: (context, snap) {
                          final unreadTotal = _countUnreadMail(snap.data?.snapshot.value);
                          return _buildQuickCard(
                            context,
                            'Mail',
                            Icons.email_rounded,
                            const TeacherMailScreen(),
                            badgeCount: unreadTotal,
                          );
                        },
                      ),
                      _buildQuickCard(
                        context,
                        'Payment',
                        Icons.payments_rounded,
                        const TeacherPaymentScreen(),
                      ),
                      StreamBuilder<DatabaseEvent>(
                        stream: _remindersStream,
                        builder: (context, snap) {
                          final notDone = _countNotDoneReminders(snap.data?.snapshot.value);
                          return _buildQuickCard(
                            context,
                            'Reminders',
                            Icons.alarm_rounded,
                            const TeacherReminderScreen(),
                            badgeCount: notDone,
                          );
                        },
                      ),
                      _buildQuickCard(
                        context,
                        'Call Logs',
                        Icons.history_rounded,
                        const CallLogsScreen(),
                        subtitle: 'History & duration',
                      ),
                    ],
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Text(
                      'Your Bridge School',
                      style: TextStyle(
                        color: mainText.withOpacity(0.4),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: actionOrange,
        foregroundColor: Colors.white,
        icon: const Text('🎧', style: TextStyle(fontSize: 18)),
        label: const Text(
          'Support',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        onPressed: _openSupportSheet,
      ),
    );
  }

  Widget _buildQuickCard(
      BuildContext context,
      String title,
      IconData icon,
      Widget destination, {
        int badgeCount = 0,
        String subtitle = '',
      }) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => destination),
      ),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: uiBorder.withOpacity(0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: appBg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 32, color: primaryBlue),
                ),
                if (badgeCount > 0)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Text(
                        badgeCount > 99 ? '99+' : badgeCount.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: mainText,
                fontSize: 15,
              ),
            ),
            if (subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: mainText.withOpacity(0.55),
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ClassesSummary {
  const _ClassesSummary({required this.classesCount, required this.learnersCount});
  final int classesCount;
  final int learnersCount;
}

class _UserPick {
  const _UserPick({required this.uid, required this.name, required this.subtitle});
  final String uid;
  final String name;
  final String subtitle;
}

class _SupportTile extends StatelessWidget {
  const _SupportTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFD1D9E0).withOpacity(0.85)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1A2B48).withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: const Color(0xFF1A2B48)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A2B48),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}