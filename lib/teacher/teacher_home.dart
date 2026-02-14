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

// ✅ Call logs
import '../calls/call_logs_screen.dart';

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

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
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

                      // ✅ Mail card with unread badge (sum)
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
                      'Dream English Academy',
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
