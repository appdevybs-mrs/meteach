import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/app_theme.dart';
import '../calls/audio_call_screen.dart';
import '../calls/call_logs_screen.dart';
import '../shared/session_manager.dart';
import 'teacher_classes.dart';
import 'teacher_mail.dart';
import 'teacher_online_booking.dart';
import 'teacher_profile.dart';
import 'teacher_regulations_screen.dart';
import 'teacher_reminder.dart';
import 'teacher_schedule.dart';
import 'teacher_syllabi_screen.dart';
import 'teacher_wages_screen.dart';

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
  static const String usersNode = "users";
  static const String classesNode = "classes";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  Stream<DatabaseEvent>? _remindersStream;
  Stream<DatabaseEvent>? _mailIndexStream;

  Future<_ClassesSummary>? _classesSummaryFuture;
  Future<int>? _upcomingOnlineCountFuture;
  Future<String>? _displayNameFuture;


  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid != null) {
      _remindersStream = _db.child('reminders/$uid').onValue.asBroadcastStream();
      _mailIndexStream = _db.child('mail_index/$uid').onValue.asBroadcastStream();
      _classesSummaryFuture = _loadClassesSummaryForHome(uid);
      _upcomingOnlineCountFuture = _loadUpcomingOnlineCountForHome(uid);
      _displayNameFuture = _myDisplayName();
    }
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  _HomePalette get palette => _toHomePalette(appThemeController.palette);

  Future<void> _refreshHome() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() {
      _displayNameFuture = _myDisplayName();
      _classesSummaryFuture = _loadClassesSummaryForHome(uid);
      _upcomingOnlineCountFuture = _loadUpcomingOnlineCountForHome(uid);
    });

    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _logout(BuildContext context) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    await SessionManager.stopListening();

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
      if (!userSnap.exists) {
        return const _ClassesSummary(classesCount: 0, learnersCount: 0);
      }

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
            _norm(
              legacyInstructorName.isNotEmpty
                  ? legacyInstructorName
                  : curName,
            ) ==
                _norm(teacherName);

        final legacySerial =
        (c['instructorserial'] ?? c['serial'] ?? '').toString().trim();
        final matchesSerial =
            teacherSerial.isNotEmpty && legacySerial == teacherSerial;

        if (matchesUid || matchesName || matchesSerial) {
          classesCount += 1;
          learnersTotal += _learnersCount(c);
        }
      });

      return _ClassesSummary(
        classesCount: classesCount,
        learnersCount: learnersTotal,
      );
    } catch (_) {
      return const _ClassesSummary(classesCount: 0, learnersCount: 0);
    }
  }

  DateTime? _parseBookingSlotStart(String dayKey, String hhmm) {
    try {
      final dp = dayKey.split('-');
      if (dp.length != 3) return null;

      final y = int.tryParse(dp[0]);
      final m = int.tryParse(dp[1]);
      final d = int.tryParse(dp[2]);
      if (y == null || m == null || d == null) return null;

      final tp = hhmm.split(':');
      if (tp.length != 2) return null;

      final hh = int.tryParse(tp[0]);
      final mm = int.tryParse(tp[1]);
      if (hh == null || mm == null) return null;

      return DateTime(y, m, d, hh, mm);
    } catch (_) {
      return null;
    }
  }

  Future<int> _loadUpcomingOnlineCountForHome(String teacherUid) async {
    try {
      final snap = await _db.child('booking_reservations').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return 0;

      final now = DateTime.now();
      int count = 0;

      final byCourse = Map<dynamic, dynamic>.from(snap.value as Map);

      for (final courseEntry in byCourse.entries) {
        final courseNode = courseEntry.value;
        if (courseNode is! Map) continue;

        final byDate = Map<dynamic, dynamic>.from(courseNode);

        for (final dateEntry in byDate.entries) {
          final dayKey = dateEntry.key.toString();
          final dateNode = dateEntry.value;
          if (dateNode is! Map) continue;

          final byTime = Map<dynamic, dynamic>.from(dateNode);

          for (final timeEntry in byTime.entries) {
            final hhmm = timeEntry.key.toString();
            final slotNode = timeEntry.value;
            if (slotNode is! Map) continue;

            final slot = slotNode.map((k, v) => MapEntry(k.toString(), v));

            final teacherId =
            (slot['teacherId'] ??
                slot['teacherUid'] ??
                slot['teacher_id'] ??
                '')
                .toString()
                .trim();

            if (teacherId != teacherUid) continue;

            final dt = _parseBookingSlotStart(dayKey, hhmm);
            if (dt == null) continue;

            if (dt.isAfter(now)) {
              count += 1;
            }
          }
        }
      }

      return count;
    } catch (_) {
      return 0;
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
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final emailPrefix = email.isNotEmpty ? email.split('@').first : '';

    if (uid == null) {
      return emailPrefix.isNotEmpty ? emailPrefix : 'Teacher';
    }

    try {
      final snap = await _db.child('users/$uid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        if (full.isNotEmpty) return full;

        final dbEmail = (m['email'] ?? '').toString().trim();
        if (dbEmail.isNotEmpty) return dbEmail.split('@').first;
      }
    } catch (_) {}

    return emailPrefix.isNotEmpty ? emailPrefix : 'Teacher';
  }

  Future<List<_UserPick>> _loadOtherTeachers() async {
    final out = <_UserPick>[];
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    try {
      final snap = await _db.child('users').get();
      final v = snap.value;
      if (v is! Map) return out;

      final raw = Map<dynamic, dynamic>.from(v);

      raw.forEach((uid, val) {
        if (val is! Map) return;

        final m = val.map((k, vv) => MapEntry(k.toString(), vv));

        if (!_isTeacherRole(m['role'])) return;

        final teacherUid = uid.toString().trim();
        if (myUid != null && teacherUid == myUid) return;

        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final fullName = ('$first $last').trim();

        final serial = (m['serial'] ?? '').toString().trim();
        final email = (m['email'] ?? '').toString().trim();

        final name = fullName.isNotEmpty
            ? fullName
            : (serial.isNotEmpty
            ? serial
            : (email.isNotEmpty ? email.split('@').first : 'Teacher'));

        out.add(
          _UserPick(
            uid: teacherUid,
            name: name,
            subtitle: 'Teacher',
          ),
        );
      });

      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    } catch (_) {
      return out;
    }
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
        final fullName = ('$first $last').trim();

        out.add(
          _UserPick(
            uid: uid.toString(),
            name: fullName.isEmpty ? 'Admin' : fullName,
            subtitle: 'Admin',
          ),
        );
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
    final p = palette;
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: p.appBg,
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

                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: p.primary.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: p.border.withOpacity(0.9)),
                            ),
                            child: Icon(icon, color: p.primary),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              title,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: p.primary,
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
                            border: Border.all(color: p.border.withOpacity(0.85)),
                          ),
                          child: Text(
                            'No users found.',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: p.text,
                            ),
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
                                  await _startCallTo(
                                    peerUid: it.uid,
                                    peerName: it.name,
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: p.border.withOpacity(0.85)),
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        backgroundColor: p.primary.withOpacity(0.08),
                                        child: Text(
                                          it.name.isNotEmpty
                                              ? it.name[0].toUpperCase()
                                              : '?',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: p.primary,
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
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: p.primary,
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
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: p.accent.withOpacity(0.10),
                                          borderRadius: BorderRadius.circular(999),
                                          border: Border.all(
                                            color: p.accent.withOpacity(0.22),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.call_rounded,
                                              size: 16,
                                              color: p.accent,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              'Call',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: p.accent,
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
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _openSupportSheet() async {
    final p = palette;
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: p.appBg,
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
                    border: Border.all(color: p.border.withOpacity(0.85)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.support_agent_rounded, color: p.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Support Call',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: p.primary,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _SupportTile(
                  palette: p,
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
                  palette: p,
                  icon: Icons.person_rounded,
                  title: 'Call Teacher',
                  subtitle: 'Choose another teacher to call',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickAndCall(
                      title: 'Choose Teacher',
                      loader: _loadOtherTeachers,
                      icon: Icons.person_rounded,
                    );
                  },
                ),
                const SizedBox(height: 10),
                _SupportTile(
                  palette: p,
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

  void _openThemeSheet() {
    final p = palette;

    Future<void> pickTheme(AppThemeMode mode) async {
      await appThemeController.setTheme(mode);
      if (!mounted) return;
      setState(() {});
      Navigator.of(context).pop();
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: p.appBg,
      showDragHandle: true,

      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Choose Theme',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _ThemeChoiceTile(
                      title: 'Navy Classic',
                      subtitle: 'Clean professional blue',
                      selected: appThemeController.mode == AppThemeMode.navy,
                      preview1: const Color(0xFF1A2B48),
                      preview2: const Color(0xFFF98D28),
                      onTap: () => pickTheme(AppThemeMode.navy),
                    ),
                    const SizedBox(height: 10),
                    _ThemeChoiceTile(
                      title: 'Rose Soft',
                      subtitle: 'Light pink girly look',
                      selected: appThemeController.mode == AppThemeMode.rose,
                      preview1: const Color(0xFFB83B78),
                      preview2: const Color(0xFFFF8FB1),
                      onTap: () => pickTheme(AppThemeMode.rose),
                    ),
                    const SizedBox(height: 10),
                    _ThemeChoiceTile(
                      title: 'Emerald Fresh',
                      subtitle: 'Modern green style',
                      selected: appThemeController.mode == AppThemeMode.emerald,
                      preview1: const Color(0xFF0F766E),
                      preview2: const Color(0xFF22C55E),
                      onTap: () => pickTheme(AppThemeMode.emerald),
                    ),
                    const SizedBox(height: 10),
                    _ThemeChoiceTile(
                      title: 'Lavender Glow',
                      subtitle: 'Purple soft feminine look',
                      selected: appThemeController.mode == AppThemeMode.lavender,
                      preview1: const Color(0xFF6D4CC9),
                      preview2: const Color(0xFFA78BFA),
                      onTap: () => pickTheme(AppThemeMode.lavender),
                    ),
                    const SizedBox(height: 10),
                    _ThemeChoiceTile(
                      title: 'Sunset Warm',
                      subtitle: 'Orange warm elegant look',
                      selected: appThemeController.mode == AppThemeMode.sunset,
                      preview1: const Color(0xFF9A3412),
                      preview2: const Color(0xFFF97316),
                      onTap: () => pickTheme(AppThemeMode.sunset),
                    ),
                    const SizedBox(height: 10),
                    _ThemeChoiceTile(
                      title: 'Charcoal Cool',
                      subtitle: 'Dark grey with cyan accent',
                      selected: appThemeController.mode == AppThemeMode.charcoal,
                      preview1: const Color(0xFF1F2937),
                      preview2: const Color(0xFF06B6D4),
                      onTap: () => pickTheme(AppThemeMode.charcoal),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
  void _pushScreen(Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: p.appBg,
      drawer: _TeacherDrawer(
        palette: p,
        onOpenProfile: () => _pushScreen(const TeacherProfileScreen()),
        onOpenSchedule: () => _pushScreen(const TeacherSchedule()),
        onOpenClasses: () => _pushScreen(const TeacherClassesScreen()),
        onOpenOnlineBooking: () => _pushScreen(const TeacherOnlineBookingScreen()),
        onOpenMail: () => _pushScreen(const TeacherMailScreen()),
        onOpenReminders: () => _pushScreen(const TeacherReminderScreen()),
        onOpenWages: () => _pushScreen(const TeacherWagesScreen()),
        onOpenRegulations: () => _pushScreen(const TeacherRegulationsScreen()),
        onOpenSyllabi: () => _pushScreen(TeacherSyllabiScreen()),
        onOpenCallLogs: () => _pushScreen(const CallLogsScreen()),
        onOpenThemeSettings: _openThemeSheet,
        onLogout: () => _logout(context),
      ),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.white,
        leading: IconButton(
          icon: Icon(Icons.menu_rounded, color: p.primary),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: FutureBuilder<String>(
          future: _displayNameFuture,
          builder: (context, snap) {
            final name = (snap.data ?? '').trim();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Teacher Dashboard',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  name.isNotEmpty ? name : 'Teacher',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text.withOpacity(0.72),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Theme',
            icon: Icon(Icons.palette_rounded, color: p.accent),
            onPressed: _openThemeSheet,
          ),
          IconButton(
            tooltip: 'Call Logs',
            icon: Icon(Icons.history_rounded, color: p.primary),
            onPressed: () => _pushScreen(const CallLogsScreen()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        icon: const Text('🎧', style: TextStyle(fontSize: 18)),
        label: const Text(
          'Support',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        onPressed: _openSupportSheet,
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
          RefreshIndicator(
            onRefresh: _refreshHome,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
              children: [
                FutureBuilder<String>(
                  future: _displayNameFuture,
                  builder: (context, snap) {
                    final name = (snap.data ?? 'Teacher').trim();
                    return _HeroSummaryCard(
                      palette: p,
                      teacherName: name.isEmpty ? 'Teacher' : name,
                      onOpenProfile: () => _pushScreen(const TeacherProfileScreen()),
                      onOpenSchedule: () => _pushScreen(const TeacherSchedule()),
                    );
                  },
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: StreamBuilder<DatabaseEvent>(
                        stream: _mailIndexStream,
                        builder: (context, snap) {
                          final unread = _countUnreadMail(
                            snap.data?.snapshot.value,
                          );
                          return _MiniStatCard(
                            palette: p,
                            label: 'Inbox',
                            value: unread == 0 ? 'Clear' : '$unread unread',
                            icon: Icons.email_rounded,
                            badgeCount: unread,
                            badgeColor: Colors.red,
                            onTap: () => _pushScreen(const TeacherMailScreen()),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StreamBuilder<DatabaseEvent>(
                        stream: _remindersStream,
                        builder: (context, snap) {
                          final pending = _countNotDoneReminders(
                            snap.data?.snapshot.value,
                          );
                          return _MiniStatCard(
                            palette: p,
                            label: 'Reminders',
                            value: pending == 0 ? 'None' : '$pending pending',
                            icon: Icons.alarm_rounded,
                            badgeCount: pending,
                            badgeColor: p.accent,
                            onTap: () => _pushScreen(const TeacherReminderScreen()),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                FutureBuilder<_ClassesSummary>(
                  future: _classesSummaryFuture,
                  builder: (context, classSnap) {
                    final s = classSnap.data ??
                        const _ClassesSummary(classesCount: 0, learnersCount: 0);

                    return FutureBuilder<int>(
                      future: _upcomingOnlineCountFuture,
                      builder: (context, onlineSnap) {
                        final upcoming = onlineSnap.data ?? 0;

                        return _OverviewPanel(
                          palette: p,
                          classesCount: s.classesCount,
                          learnersCount: s.learnersCount,
                          upcomingOnlineCount: upcoming,
                          onOpenClasses: () =>
                              _pushScreen(const TeacherClassesScreen()),
                          onOpenOnline: () => _pushScreen(
                            const TeacherOnlineBookingScreen(),
                          ),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 14),
                Text(
                  'Quick Actions',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 10),
                _QuickActionTile(
                  palette: p,
                  icon: Icons.calendar_today_rounded,
                  title: 'Schedule',
                  subtitle: 'Check your teaching calendar',
                  onTap: () => _pushScreen(const TeacherSchedule()),
                ),
                const SizedBox(height: 10),
                _QuickActionTile(
                  palette: p,
                  icon: Icons.school_rounded,
                  title: 'My Classes',
                  subtitle: 'Open your classes and learners',
                  onTap: () => _pushScreen(const TeacherClassesScreen()),
                ),
                const SizedBox(height: 10),
                _QuickActionTile(
                  palette: p,
                  icon: Icons.event_available_rounded,
                  title: 'Online Availability',
                  subtitle: 'Manage booking slots and sessions',
                  onTap: () =>
                      _pushScreen(const TeacherOnlineBookingScreen()),
                ),
                const SizedBox(height: 10),
                _QuickActionTile(
                  palette: p,
                  icon: Icons.wallet_rounded,
                  title: 'Wages',
                  subtitle: 'Check salary and payment details',
                  onTap: () => _pushScreen(const TeacherWagesScreen()),
                ),
                const SizedBox(height: 10),
                _QuickActionTile(
                  palette: p,
                  icon: Icons.menu_book_rounded,
                  title: 'Syllabi',
                  subtitle: 'Open teaching content quickly',
                  onTap: () => _pushScreen(TeacherSyllabiScreen()),
                ),
                const SizedBox(height: 18),
                Center(
                  child: Text(
                    'Your Bridge School',
                    style: TextStyle(
                      color: p.text.withOpacity(0.4),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
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

  _HomePalette _toHomePalette(AppPalette p) {
    return _HomePalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

}



class _HomePalette {
  const _HomePalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}

class _ClassesSummary {
  const _ClassesSummary({
    required this.classesCount,
    required this.learnersCount,
  });

  final int classesCount;
  final int learnersCount;
}

class _UserPick {
  const _UserPick({
    required this.uid,
    required this.name,
    required this.subtitle,
  });

  final String uid;
  final String name;
  final String subtitle;
}

class _TeacherDrawer extends StatelessWidget {
  const _TeacherDrawer({
    required this.palette,
    required this.onOpenProfile,
    required this.onOpenSchedule,
    required this.onOpenClasses,
    required this.onOpenOnlineBooking,
    required this.onOpenMail,
    required this.onOpenReminders,
    required this.onOpenWages,
    required this.onOpenRegulations,
    required this.onOpenSyllabi,
    required this.onOpenCallLogs,
    required this.onOpenThemeSettings,
    required this.onLogout,
  });

  final _HomePalette palette;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenSchedule;
  final VoidCallback onOpenClasses;
  final VoidCallback onOpenOnlineBooking;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenReminders;
  final VoidCallback onOpenWages;
  final VoidCallback onOpenRegulations;
  final VoidCallback onOpenSyllabi;
  final VoidCallback onOpenCallLogs;
  final VoidCallback onOpenThemeSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: palette.appBg,
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(14),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: palette.primary,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.white24,
                    child: Icon(Icons.school_rounded, color: Colors.white, size: 28),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Teacher Menu',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Compact dashboard navigation',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: [
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.person_rounded,
                    title: 'Profile',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenProfile();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.calendar_today_rounded,
                    title: 'Schedule',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenSchedule();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.school_rounded,
                    title: 'My Classes',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenClasses();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.event_available_rounded,
                    title: 'Online Availability',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenOnlineBooking();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.email_rounded,
                    title: 'Mail',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenMail();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.alarm_rounded,
                    title: 'Reminders',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenReminders();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.wallet_rounded,
                    title: 'Wages',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenWages();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.policy_rounded,
                    title: 'Regulations',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenRegulations();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.menu_book_rounded,
                    title: 'Syllabi',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenSyllabi();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.history_rounded,
                    title: 'Call Logs',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenCallLogs();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.palette_rounded,
                    title: 'Theme Settings',
                    subtitle: 'Manly / girly looks',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenThemeSettings();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onLogout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text(
                    'Logout',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.palette,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle = '',
  });

  final _HomePalette palette;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: palette.border.withOpacity(0.85)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: palette.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: palette.primary,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (subtitle.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: palette.text.withOpacity(0.55),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: palette.text.withOpacity(0.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroSummaryCard extends StatelessWidget {
  const _HeroSummaryCard({
    required this.palette,
    required this.teacherName,
    required this.onOpenProfile,
    required this.onOpenSchedule,
  });

  final _HomePalette palette;
  final String teacherName;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenSchedule;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.primary,
            palette.primary.withOpacity(0.88),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withOpacity(0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Welcome back',
            style: TextStyle(
              color: Colors.white.withOpacity(0.80),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            teacherName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 24,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Everything important is now on one compact screen.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.86),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _HeroActionButton(
                  label: 'Profile',
                  icon: Icons.person_rounded,
                  fillColor: Colors.white,
                  textColor: palette.primary,
                  onTap: onOpenProfile,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _HeroActionButton(
                  label: 'Schedule',
                  icon: Icons.calendar_today_rounded,
                  fillColor: Colors.white12,
                  textColor: Colors.white,
                  onTap: onOpenSchedule,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroActionButton extends StatelessWidget {
  const _HeroActionButton({
    required this.label,
    required this.icon,
    required this.fillColor,
    required this.textColor,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color fillColor;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fillColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewPanel extends StatelessWidget {
  const _OverviewPanel({
    required this.palette,
    required this.classesCount,
    required this.learnersCount,
    required this.upcomingOnlineCount,
    required this.onOpenClasses,
    required this.onOpenOnline,
  });

  final _HomePalette palette;
  final int classesCount;
  final int learnersCount;
  final int upcomingOnlineCount;
  final VoidCallback onOpenClasses;
  final VoidCallback onOpenOnline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.border.withOpacity(0.75)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Overview',
            style: TextStyle(
              color: palette.primary,
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: (MediaQuery.of(context).size.width - 58) / 3,
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Classes',
                  value: '$classesCount',
                  icon: Icons.school_rounded,
                ),
              ),
              SizedBox(
                width: (MediaQuery.of(context).size.width - 58) / 3,
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Learners',
                  value: '$learnersCount',
                  icon: Icons.groups_rounded,
                ),
              ),
              SizedBox(
                width: (MediaQuery.of(context).size.width - 58) / 3,
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Online',
                  value: '$upcomingOnlineCount',
                  icon: Icons.videocam_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _SoftActionButton(
                  palette: palette,
                  icon: Icons.school_rounded,
                  title: 'Open Classes',
                  onTap: onOpenClasses,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SoftActionButton(
                  palette: palette,
                  icon: Icons.event_available_rounded,
                  title: 'Open Online',
                  onTap: onOpenOnline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverviewStatBox extends StatelessWidget {
  const _OverviewStatBox({
    required this.palette,
    required this.label,
    required this.value,
    required this.icon,
  });

  final _HomePalette palette;
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: palette.soft.withOpacity(0.7),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Icon(icon, color: palette.primary, size: 22),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: palette.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: palette.text.withOpacity(0.65),
              fontWeight: FontWeight.w800,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}


class _SoftActionButton extends StatelessWidget {
  const _SoftActionButton({
    required this.palette,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final _HomePalette palette;
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.soft,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: palette.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.primary,
                    fontWeight: FontWeight.w900,
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
class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({
    required this.palette,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final _HomePalette palette;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.cardBg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.border.withOpacity(0.8)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: palette.soft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: palette.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: palette.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: palette.text.withOpacity(0.60),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: palette.text.withOpacity(0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SupportTile extends StatelessWidget {
  const _SupportTile({
    required this.palette,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final _HomePalette palette;
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
          border: Border.all(color: palette.border.withOpacity(0.85)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: palette.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: palette.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: palette.primary,
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

class _MiniStatCard extends StatelessWidget {
  const _MiniStatCard({
    required this.palette,
    required this.label,
    required this.value,
    required this.icon,
    this.onTap,
    this.badgeCount = 0,
    this.badgeColor,
  });

  final _HomePalette palette;
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  final int badgeCount;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border.withOpacity(0.65)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: palette.soft,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: palette.primary),
              ),
              if (badgeCount > 0)
                Positioned(
                  right: -8,
                  top: -8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor ?? Colors.red,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Text(
                      badgeCount > 99 ? '99+' : badgeCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.primary.withOpacity(0.7),
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          if (onTap != null)
            const Icon(Icons.chevron_right_rounded, color: Colors.grey),
        ],
      ),
    );

    if (onTap == null) return content;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: content,
    );
  }
}

class _ThemeChoiceTile extends StatelessWidget {
  const _ThemeChoiceTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.preview1,
    required this.preview2,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final Color preview1;
  final Color preview2;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? preview1 : const Color(0xFFD1D9E0),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(backgroundColor: preview1, radius: 12),
              const SizedBox(width: 8),
              CircleAvatar(backgroundColor: preview2, radius: 12),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF222222),
                      ),
                    ),
                    const SizedBox(height: 3),
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
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                color: selected ? preview1 : Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}






