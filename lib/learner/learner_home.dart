// learner_home.dart
// ✅ FULL DROP-IN REPLACEMENT (SAFE)
//
// Keeps your working logic intact (Support calls, Mail/Homework/Reminders/CallLogs, Booking, Logout, etc).
//
// ✅ CHANGE YOU REQUESTED:
// - Removed the "second progress" section (the progress list under the home cards).
//   Home tab now shows ONLY the cards grid (Booking + next booked class + Mail/Homework/Reminders/CallLogs...).
//
// NOTE: Progress logic helpers are kept (safe) but the UI section is removed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared/session_manager.dart';
import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

import 'learner_regulations_screen.dart';
import 'learner_mail_screen.dart';
import 'learner_homework_screen.dart' as hw;
import 'learner_courses_screen.dart';
import 'learner_profile_screen.dart';
import 'learner_reminders_list_screen.dart';

import '../calls/call_logs_screen.dart';
import '../calls/audio_call_screen.dart';

import 'learner_booking_screen.dart';

class LearnerHome extends StatefulWidget {
  const LearnerHome({super.key});

  @override
  State<LearnerHome> createState() => _LearnerHomeState();
}

class _LearnerHomeState extends State<LearnerHome> {
  int _index = 0;

  static const _pages = <Widget>[
    LearnerCoursesScreen(),
    _LearnerDashboardLite(),
    LearnerProfileScreen(),
  ];

  static const _titles = <String>[
    'My Courses',
    'Learner Dashboard',
    'Profile',
  ];

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Future<void> _logout(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    // ✅ stop "single device" listener (so it doesn't run after logout)
    await SessionManager.stopListening();

    // (optional but recommended) remove session in RTDB
    if (uid != null && uid.isNotEmpty) {
      try {
        // intentionally empty (your original)
      } catch (_) {}
    }

    // ✅ 1) stop pushes on device
    try {
      await FirebaseMessaging.instance.deleteToken(); // VERY IMPORTANT
    } catch (_) {}

    // ✅ 2) remove token from RTDB so admin can't target it
    if (uid != null && uid.isNotEmpty) {
      try {
        await FirebaseDatabase.instance.ref('fcm_tokens/$uid').remove();
      } catch (_) {}
    }

    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  // -----------------------
  // Support FAB helpers
  // -----------------------

  String _norm(String s) => s.trim().toLowerCase();

  bool _isAdminRole(dynamic role) {
    final r = _norm((role ?? '').toString());
    return r == 'admin' || r == 'administrator';
  }

  bool _isTeacherRole(dynamic role) {
    final r = _norm((role ?? '').toString());
    return r == 'teacher' || r == 'teachers' || r == 'teacher(s)';
  }

  bool _isLearnerRole(dynamic role) {
    final r = _norm((role ?? '').toString());
    return r == 'learner' || r == 'student';
  }

  Future<String> _myDisplayName() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return 'Learner';

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
    return 'Learner';
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
        final full = ('$first $last').trim();
        final name = full.isEmpty ? 'Admin' : full;

        out.add(_UserPick(uid: uid.toString(), name: name, subtitle: 'Admin'));
      });

      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    } catch (_) {
      return out;
    }
  }

  Future<_ClassesAndPeers> _loadMyClassesAndPeers() async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) {
      return const _ClassesAndPeers(classIds: [], teacherUids: {}, classmateUids: {});
    }

    final classIds = <String>[];
    final teacherUids = <String, String>{}; // uid -> name
    final classmateUids = <String, String>{}; // uid -> name

    try {
      final snap = await _db.child('classes').get();
      final v = snap.value;
      if (v is! Map) {
        return _ClassesAndPeers(classIds: classIds, teacherUids: teacherUids, classmateUids: classmateUids);
      }

      final raw = Map<dynamic, dynamic>.from(v);

      raw.forEach((classId, classVal) {
        if (classVal is! Map) return;
        final c = classVal.map((k, vv) => MapEntry(k.toString(), vv));

        // learners map
        final learners = c['learners'];
        bool imInThisClass = false;

        if (learners is Map) {
          final lm = Map<dynamic, dynamic>.from(learners);
          if (lm.containsKey(me)) {
            imInThisClass = true;
          }

          // classmates
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

            // only add classmates if I'm in this class
            if (imInThisClass) {
              classmateUids.putIfAbsent(u, () => name);
            }
          });
        }

        if (!imInThisClass) return;

        classIds.add(classId.toString());

        // teacher (preferred)
        final cur = c['instructor_current'];
        if (cur is Map) {
          final cm = cur.map((kk, vv) => MapEntry(kk.toString(), vv));
          final tuid = (cm['uid'] ?? '').toString().trim();
          final tname = (cm['name'] ?? '').toString().trim();
          if (tuid.isNotEmpty) {
            teacherUids.putIfAbsent(tuid, () => tname.isNotEmpty ? tname : 'Teacher');
          }
        }
      });

      return _ClassesAndPeers(classIds: classIds, teacherUids: teacherUids, classmateUids: classmateUids);
    } catch (_) {
      return _ClassesAndPeers(classIds: classIds, teacherUids: teacherUids, classmateUids: classmateUids);
    }
  }

  Future<List<_UserPick>> _loadTeachersFromMyClasses() async {
    final peers = await _loadMyClassesAndPeers();
    if (peers.teacherUids.isEmpty) return [];

    // enrich from users node (get cleaner names if possible)
    final out = <_UserPick>[];
    final ids = peers.teacherUids.keys.toList();

    for (final uid in ids) {
      String name = peers.teacherUids[uid] ?? 'Teacher';
      const subtitle = 'Teacher';

      try {
        final snap = await _db.child('users/$uid').get();
        final v = snap.value;
        if (v is Map) {
          final m = v.map((k, vv) => MapEntry(k.toString(), vv));
          if (_isTeacherRole(m['role'])) {
            final first = (m['first_name'] ?? '').toString().trim();
            final last = (m['last_name'] ?? '').toString().trim();
            final full = ('$first $last').trim();
            if (full.isNotEmpty) name = full;
          }
        }
      } catch (_) {}

      out.add(_UserPick(uid: uid, name: name, subtitle: subtitle));
    }

    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  Future<List<_UserPick>> _loadClassmates() async {
    final peers = await _loadMyClassesAndPeers();
    if (peers.classmateUids.isEmpty) return [];

    final out = <_UserPick>[];

    // optionally enrich from users
    for (final entry in peers.classmateUids.entries) {
      final uid = entry.key;
      String name = entry.value;
      const subtitle = 'Learner';

      try {
        final snap = await _db.child('users/$uid').get();
        final v = snap.value;
        if (v is Map) {
          final m = v.map((k, vv) => MapEntry(k.toString(), vv));
          if (_isLearnerRole(m['role'])) {
            final first = (m['first_name'] ?? '').toString().trim();
            final last = (m['last_name'] ?? '').toString().trim();
            final full = ('$first $last').trim();
            if (full.isNotEmpty) name = full;
          }
        }
      } catch (_) {}

      out.add(_UserPick(uid: uid, name: name, subtitle: subtitle));
    }

    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
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
          startWithVideo: false,
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
      backgroundColor: UiK.appBg,
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
                            color: UiK.primaryBlue.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: UiK.uiBorder.withOpacity(0.9)),
                          ),
                          child: Icon(icon, color: UiK.primaryBlue),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: UiK.primaryBlue,
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
                          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
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
                                  border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: UiK.primaryBlue.withOpacity(0.08),
                                      child: Text(
                                        it.name.isNotEmpty ? it.name[0].toUpperCase() : '?',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: UiK.primaryBlue,
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
                                              color: UiK.primaryBlue,
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
                                        color: UiK.actionOrange.withOpacity(0.10),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(color: UiK.actionOrange.withOpacity(0.22)),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.call_rounded, size: 16, color: UiK.actionOrange),
                                          SizedBox(width: 6),
                                          Text(
                                            'Call',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w900,
                                              color: UiK.actionOrange,
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
      backgroundColor: UiK.appBg,
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
                    border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.support_agent_rounded, color: UiK.primaryBlue),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Support Call',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: UiK.primaryBlue,
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
                  icon: Icons.school_rounded,
                  title: 'Call Teacher',
                  subtitle: 'Teachers for your classes',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickAndCall(
                      title: 'Choose Teacher',
                      loader: _loadTeachersFromMyClasses,
                      icon: Icons.school_rounded,
                    );
                  },
                ),
                const SizedBox(height: 10),
                _SupportTile(
                  icon: Icons.groups_rounded,
                  title: 'Call Classmate',
                  subtitle: 'Learners in your class(es)',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickAndCall(
                      title: 'Choose Classmate',
                      loader: _loadClassmates,
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
    final safeIndex = _index.clamp(0, _pages.length - 1);

    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        centerTitle: true,
        leading: IconButton(
          tooltip: 'Regulations',
          icon: const Icon(Icons.policy_rounded, color: UiK.primaryBlue),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LearnerRegulationsScreen()),
            );
          },
        ),
        title: Text(
          _titles[safeIndex],
          style: const TextStyle(
            color: UiK.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Call Logs',
            icon: const Icon(Icons.history, color: UiK.primaryBlue),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CallLogsScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: UiK.actionOrange),
            onPressed: () => _logout(context),
          ),
        ],
      ),
      body: WatermarkBackground(child: _pages[safeIndex]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: UiK.actionOrange,
        foregroundColor: Colors.white,
        icon: const Text('🎧', style: TextStyle(fontSize: 18)),
        label: const Text(
          'Support',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        onPressed: _openSupportSheet,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: safeIndex,
        selectedItemColor: UiK.actionOrange,
        unselectedItemColor: UiK.primaryBlue.withOpacity(0.65),
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.school_rounded), label: 'Courses'),
          BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }
}

/// Home dashboard (cards only) ✅ progress section removed as requested
class _LearnerDashboardLite extends StatefulWidget {
  const _LearnerDashboardLite();

  @override
  State<_LearnerDashboardLite> createState() => _LearnerDashboardLiteState();
}

class _LearnerDashboardLiteState extends State<_LearnerDashboardLite> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // (kept for safety; unused now because progress UI removed)
  final Map<String, Future<_CourseMeta>> _metaFutures = {};

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  // (kept for safety; unused now because progress UI removed)
  Future<_CourseMeta> _loadCourseMeta({
    required String courseKey,
    required Map<String, dynamic> course,
  }) async {
    final cls = (course['class'] is Map) ? Map<String, dynamic>.from(course['class'] as Map) : <String, dynamic>{};
    final classId = (cls['class_id'] ?? '').toString().trim();
    final courseId = (cls['course_id'] ?? course['id'] ?? '').toString().trim();

    int? planned;
    final schedule = cls['schedule'];
    if (schedule is Map) {
      planned = _toInt((schedule as Map)['meetingsCount'] ?? (schedule as Map)['totalMeetings'] ?? (schedule as Map)['sessionsCount']);
      if (planned != null && planned <= 0) planned = null;
    }
    planned ??= _toInt(cls['meetingsCount'] ?? cls['totalMeetings'] ?? cls['sessionsCount']);
    if (planned != null && planned <= 0) planned = null;

    if ((planned == null || planned <= 0) && classId.isNotEmpty) {
      try {
        final snap = await _db.child('classes/$classId/schedule').get();
        if (snap.exists && snap.value is Map) {
          final m = Map<String, dynamic>.from(snap.value as Map);
          final n = _toInt(m['meetingsCount'] ?? m['totalMeetings'] ?? m['sessionsCount']);
          if (n > 0) planned = n;
        }
      } catch (_) {}
    }

    int totalLessons = 0;
    if (courseId.isNotEmpty) {
      try {
        final sSnap = await _db.child('syllabi/$courseId').get();
        if (sSnap.exists && sSnap.value is Map) {
          final s = Map<String, dynamic>.from(sSnap.value as Map);
          final units = s['units'];
          if (units is List) {
            for (final u in units) {
              if (u is! Map) continue;
              final unit = Map<String, dynamic>.from(u);
              final sessions = unit['sessions'];
              if (sessions is List) totalLessons += sessions.length;
            }
          }
        }
      } catch (_) {}
    }

    return _CourseMeta(
      courseKey: courseKey,
      classId: classId,
      courseId: courseId,
      plannedMeetings: planned,
      totalLessons: totalLessons,
    );
  }

  // (kept for safety; unused now because progress UI removed)
  Future<Set<String>> _coveredSessionIdsFromAttendance({
    required String learnerUid,
    required String courseId,
    required Map<String, dynamic> course,
  }) async {
    final covered = <String>{};

    final att = course['attendance'];
    if (att is Map) {
      final attMap = Map<String, dynamic>.from(att as Map);

      for (final entry in attMap.entries) {
        final rec = entry.value;
        if (rec is! Map) continue;
        final m = Map<String, dynamic>.from(rec);

        final taughtItems = m['taughtItems'];
        bool usedNew = false;

        if (taughtItems is List) {
          usedNew = true;
          for (final it in taughtItems) {
            if (it is! Map) continue;
            final item = Map<String, dynamic>.from(it);
            final type = (item['type'] ?? '').toString().trim().toLowerCase();
            if (type != 'syllabus') continue;

            final sid = (item['sessionId'] ?? '').toString().trim();
            if (sid.isNotEmpty) covered.add(sid);
          }
        }

        if (!usedNew) {
          final taught = m['taught'];
          if (taught is Map) {
            final tm = Map<String, dynamic>.from(taught as Map);
            final sid = (tm['sessionId'] ?? '').toString().trim();
            if (sid.isNotEmpty) covered.add(sid);
          }
        }
      }
    }

    // online (teacher-confirmed) read
    if (learnerUid.isNotEmpty && courseId.isNotEmpty) {
      try {
        final snap = await _db.child('booking_progress/$learnerUid/$courseId/online_attendance').get();
        if (snap.exists && snap.value is Map) {
          final m = Map<dynamic, dynamic>.from(snap.value as Map);

          for (final e in m.entries) {
            final rec = e.value;
            if (rec is! Map) continue;
            final r = Map<String, dynamic>.from(rec);

            if (r['autoMarkedByLearnerJoin'] == true) continue;

            final taughtItems = r['taughtItems'];
            if (taughtItems is List) {
              for (final it in taughtItems) {
                if (it is! Map) continue;
                final item = Map<String, dynamic>.from(it);

                final type = (item['type'] ?? '').toString().trim().toLowerCase();
                if (type != 'syllabus') continue;

                final sid = (item['sessionId'] ?? '').toString().trim();
                if (sid.isNotEmpty) {
                  covered.add(sid);
                  continue;
                }

                final sn = (item['sessionNumber'] ?? '').toString().trim();
                if (sn.isNotEmpty) covered.add('session_$sn');
              }
            }
          }
        }
      } catch (_) {}
    }

    return covered;
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    if (uid.isEmpty) {
      return const Center(child: Text('Not logged in.'));
    }

    // ✅ Home tab now only shows the cards grid (no progress list)
    return SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + (bottomPad > 0 ? bottomPad : 12)),
        children: const [
          _HomeCardsGrid(),
        ],
      ),
    );
  }
}

class _CourseMeta {
  final String courseKey;
  final String classId;
  final String courseId;
  final int? plannedMeetings;
  final int totalLessons;

  _CourseMeta({
    required this.courseKey,
    required this.classId,
    required this.courseId,
    required this.plannedMeetings,
    required this.totalLessons,
  });
}

class _HomeCardsGrid extends StatelessWidget {
  const _HomeCardsGrid();

  @override
  Widget build(BuildContext context) {
    // ✅ Booking top, full width; rest is grid under it.
    return Column(
      children: [
        const _BookingTopOrangeCard(),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.25,
          children: const [
            _MailHomeCard(),
            _LearnerHomeworkHomeCard(),
            _RemindersHomeCard(),
            _CallLogsHomeCard(),
            _HomeCard(
              icon: Icons.group_rounded,
              title: 'Activities',
              subtitle: 'Coming soon',
              routeType: _HomeCardRoute.friends,
            ),
            _HomeCard(
              icon: Icons.info_outline_rounded,
              title: 'Info',
              subtitle: 'Coming soon',
              routeType: _HomeCardRoute.friends,
            ),
          ],
        ),
      ],
    );
  }
}

/// ✅ Full width orange booking card on top
/// ✅ Shows "Next booked class" + Join Meet (external) when allowed time window.
class _BookingTopOrangeCard extends StatefulWidget {
  const _BookingTopOrangeCard();

  @override
  State<_BookingTopOrangeCard> createState() => _BookingTopOrangeCardState();
}

class _BookingTopOrangeCardState extends State<_BookingTopOrangeCard> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Future<List<Map<String, dynamic>>> _loadBookableCourses() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return [];

    final snap = await _db.child('users/$uid/courses').get();
    final v = snap.value;
    if (v is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(v);

    final temp = <Map<String, dynamic>>[];

    for (final e in raw.entries) {
      final key = e.key.toString();
      final val = e.value;
      if (val is! Map) continue;

      final m = Map<String, dynamic>.from(val as Map);

      final realCourseId = (m['id'] ?? m['courseId'] ?? '').toString().trim();
      final courseKeyForBooking = realCourseId.isNotEmpty ? realCourseId : key;

      final title = (m['title'] ?? m['course_title'] ?? 'Course').toString();
      int numVal(dynamic vv) => (vv is num) ? vv.toInt() : int.tryParse(vv?.toString() ?? '') ?? 0;
      final assignedAt = numVal(m['assignedAt']);

      temp.add({
        'courseId': courseKeyForBooking,
        'title': title,
        'assignedAt': assignedAt,
      });
    }

    temp.sort((a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int));

    final allowed = <Map<String, dynamic>>[];
    for (final c in temp) {
      final cid = (c['courseId'] ?? '').toString().trim();
      if (cid.isEmpty) continue;

      final enabledSnap = await _db.child('booking_config/courses/$cid/enabled').get();
      final ev = enabledSnap.value;
      final enabled = (ev == true) || (ev?.toString() == 'true');
      if (enabled) allowed.add(c);
    }

    return allowed;
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';
  String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  DateTime? _parseSlotStart(String dayKey, String hhmm) {
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

  String _friendlyDate(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final wd = days[d.weekday - 1];
    final mo = months[d.month - 1];
    return '$wd, ${_two(d.day)} $mo';
  }

  Future<_NextBooking?> _findMyNextBookingAcrossCourses() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return null;

    final courses = await _loadBookableCourses();
    if (courses.isEmpty) return null;

    final now = DateTime.now();
    _NextBooking? best;

    const daysAhead = 14;

    for (final c in courses) {
      final cid = (c['courseId'] ?? '').toString().trim();
      if (cid.isEmpty) continue;

      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
        final dk = _dateKey(day);

        final snap = await _db.child('booking_reservations/$cid/$dk').get();
        final v = snap.value;
        if (v is! Map) continue;

        final m = Map<dynamic, dynamic>.from(v);

        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final node = e.value;
          if (node is! Map) continue;

          final sm = Map<dynamic, dynamic>.from(node);
          final learners = sm['learners'];
          if (learners is! Map) continue;

          final lm = Map<dynamic, dynamic>.from(learners);
          if (!lm.containsKey(uid)) continue;

          final start = _parseSlotStart(dk, hhmm);
          if (start == null) continue;
          if (!start.isAfter(now)) continue;

          final teacherId = (sm['teacherId'] ?? '').toString().trim();
          final teacherName = (sm['teacherName'] ?? 'Teacher').toString().trim();

          final candidate = _NextBooking(
            courseId: cid,
            dayKey: dk,
            time: hhmm,
            start: start,
            teacherId: teacherId,
            teacherName: teacherName.isEmpty ? 'Teacher' : teacherName,
          );

          if (best == null || candidate.start.isBefore(best.start)) {
            best = candidate;
          }
        }
      }
    }

    return best;
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  Future<_MeetInfo?> _loadMeetInfo({
    required String teacherId,
    required String courseId,
  }) async {
    if (teacherId.isEmpty || courseId.isEmpty) return null;

    try {
      final snap = await _db.child('booking_availability/$teacherId/$courseId').get();
      final v = snap.value;
      if (v is! Map) return null;

      final m = Map<String, dynamic>.from(v as Map);

      final meetUrl = (m['meetUrl'] ??
          m['meet_url'] ??
          m['googleMeetUrl'] ??
          m['google_meet_url'] ??
          '')
          .toString()
          .trim();

      int dur = _toInt(m['durationMinutes'], fallback: 0);
      if (dur <= 0) dur = _toInt(m['durationMin'], fallback: 0);
      if (dur <= 0) dur = 60;

      if (meetUrl.isEmpty) return null;

      return _MeetInfo(meetUrl: meetUrl, durationMinutes: dur);
    } catch (_) {
      return null;
    }
  }

  bool _canJoinNow(DateTime start, int durationMinutes) {
    final now = DateTime.now();
    final openFrom = start.subtract(const Duration(minutes: 10));
    final dur = durationMinutes <= 0 ? 60 : durationMinutes;
    final openUntil = start.add(Duration(minutes: dur)).add(const Duration(minutes: 15));
    return now.isAfter(openFrom) && now.isBefore(openUntil);
  }

  Future<void> _openExternalUrl(BuildContext context, String url) async {
    final u = url.trim();
    if (u.isEmpty) return;

    final uri = Uri.tryParse(u);
    if (uri == null) return;

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
  }

  String _bookingKey(String courseId, String dayKey, String hhmm) => '$courseId|$dayKey|$hhmm';

  Future<void> _autoMarkPresentAndTaught({
    required String learnerUid,
    required _NextBooking next,
  }) async {
    if (learnerUid.isEmpty) return;

    try {
      final slotSnap = await _db.child('booking_reservations/${next.courseId}/${next.dayKey}/${next.time}').get();
      if (!slotSnap.exists || slotSnap.value is! Map) return;
      final slot = Map<String, dynamic>.from(slotSnap.value as Map);

      final int sessionNo = _toInt(slot['sessionNo']);
      final String bKey = _bookingKey(next.courseId, next.dayKey, next.time);

      final ref = _db.child('booking_progress/$learnerUid/${next.courseId}/online_attendance/$bKey');

      final existing = await ref.get();
      if (existing.exists && existing.value != null) return;

      final taughtItems = (sessionNo > 0)
          ? [
        {
          'type': 'syllabus',
          'sessionNumber': sessionNo,
        }
      ]
          : <Map<String, dynamic>>[];

      await ref.set({
        'bookingKey': bKey,
        'courseId': next.courseId,
        'dayKey': next.dayKey,
        'time': next.time,
        'startAt': next.start.millisecondsSinceEpoch,
        'present': true,
        'sessionNo': sessionNo,
        'taughtItems': taughtItems,
        'autoMarkedByLearnerJoin': true,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {
      // keep silent (never block join)
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget bookingCard() {
      return InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          await _openBookingCoursePicker(context);
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: UiK.actionOrange,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: UiK.actionOrange.withOpacity(0.25)),
            boxShadow: [
              BoxShadow(
                color: UiK.actionOrange.withOpacity(0.22),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.25)),
                ),
                child: const Icon(Icons.calendar_month_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Booking',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Book your next class',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Open',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: UiK.primaryBlue,
                        fontSize: 12,
                      ),
                    ),
                    SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded, color: UiK.primaryBlue, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        bookingCard(),
        const SizedBox(height: 12),

        FutureBuilder<_NextBooking?>(
          future: _findMyNextBookingAcrossCourses(),
          builder: (context, snap) {
            final next = snap.data;
            if (snap.connectionState == ConnectionState.waiting) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                ),
                child: const Row(
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Checking your next class...', style: TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
              );
            }

            if (next == null) {
              return const SizedBox.shrink();
            }

            return FutureBuilder<_MeetInfo?>(
              future: _loadMeetInfo(teacherId: next.teacherId, courseId: next.courseId),
              builder: (context, ms) {
                final meet = ms.data;
                final canJoin = (meet != null) && _canJoinNow(next.start, meet.durationMinutes);

                final timeStr = '${_friendlyDate(next.start)} • ${next.time}';
                final teacherStr = next.teacherName;

                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.upcoming_rounded, size: 18, color: UiK.actionOrange),
                          SizedBox(width: 8),
                          Text(
                            'Next booked class',
                            style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(timeStr, style: const TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue)),
                      const SizedBox(height: 4),
                      Text(
                        'Teacher: $teacherStr',
                        style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 12),
                      if (meet == null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: UiK.primaryBlue.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                          ),
                          child: const Text(
                            'Meet link not set for this course yet.',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ] else ...[
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: UiK.actionOrange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            minimumSize: const Size(double.infinity, 48),
                          ),
                          onPressed: canJoin
                              ? () async {
                            final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                            if (uid.isNotEmpty) {
                              await _autoMarkPresentAndTaught(learnerUid: uid, next: next);
                            }
                            await _openExternalUrl(context, meet.meetUrl);
                          }
                              : null,
                          child: Text(
                            canJoin ? 'Join Google Meet' : 'Join available near session time',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Join opens 10 min before start, and stays open until ${(meet.durationMinutes <= 0 ? 60 : meet.durationMinutes) + 15} min after start.',
                          style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade600, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _NextBooking {
  final String courseId;
  final String dayKey;
  final String time;
  final DateTime start;
  final String teacherId;
  final String teacherName;

  _NextBooking({
    required this.courseId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.teacherId,
    required this.teacherName,
  });
}

class _MeetInfo {
  final String meetUrl;
  final int durationMinutes;

  _MeetInfo({required this.meetUrl, required this.durationMinutes});
}

Future<void> _openBookingCoursePicker(BuildContext context) async {
  final me = FirebaseAuth.instance.currentUser;
  final uid = me?.uid ?? '';
  if (uid.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not logged in.')),
    );
    return;
  }

  final db = FirebaseDatabase.instance.ref();

  List<Map<String, dynamic>> courses = [];
  try {
    final snap = await db.child('users/$uid/courses').get();
    final v = snap.value;

    if (v is Map) {
      final raw = Map<dynamic, dynamic>.from(v);

      courses = raw.entries.map((e) {
        final key = e.key.toString();
        final m = (e.value is Map) ? Map<String, dynamic>.from(e.value as Map) : <String, dynamic>{};

        final realCourseId = (m['id'] ?? m['courseId'] ?? '').toString().trim();

        final title = (m['title'] ?? m['course_title'] ?? 'Course').toString();
        final code = (m['course_code'] ?? '').toString();

        int numVal(dynamic vv) => (vv is num) ? vv.toInt() : int.tryParse(vv?.toString() ?? '') ?? 0;
        final assignedAt = numVal(m['assignedAt']);

        return {
          'courseKey': realCourseId.isNotEmpty ? realCourseId : key,
          'title': title,
          'code': code,
          'assignedAt': assignedAt,
        };
      }).toList();

      courses.sort((a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int));

      final allowed = <Map<String, dynamic>>[];
      for (final c in courses) {
        final cid = (c['courseKey'] ?? '').toString().trim();
        if (cid.isEmpty) continue;

        final enabledSnap = await db.child('booking_config/courses/$cid/enabled').get();
        final ev = enabledSnap.value;
        final enabled = (ev == true) || (ev?.toString() == 'true');

        if (enabled) allowed.add(c);
      }
      courses = allowed;
    }
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to load courses: $e')),
    );
    return;
  }

  if (!context.mounted) return;

  if (courses.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No bookable courses. Admin has not enabled booking yet.')),
    );
    return;
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: UiK.appBg,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose course to book',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: UiK.primaryBlue),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.60,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: courses.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final c = courses[i];
                    final courseKey = (c['courseKey'] ?? '').toString();
                    final title = (c['title'] ?? 'Course').toString();
                    final code = (c['code'] ?? '').toString();

                    return InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => LearnerBookingScreen(courseId: courseKey),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: UiK.primaryBlue.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                              ),
                              child: const Icon(Icons.calendar_month_rounded, color: UiK.primaryBlue),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    code.isEmpty ? '—' : 'Code: $code',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.grey.shade600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded, color: UiK.primaryBlue),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _openHomeworkCoursePicker(
    BuildContext context, {
      Set<String> courseKeysWithUndone = const {},
    }) async {
  final me = FirebaseAuth.instance.currentUser;
  final uid = me?.uid ?? '';
  if (uid.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not logged in.')),
    );
    return;
  }

  final db = FirebaseDatabase.instance.ref();

  List<Map<String, dynamic>> courses = [];
  try {
    final snap = await db.child('users/$uid/courses').get();
    final v = snap.value;

    if (v is Map) {
      final raw = Map<dynamic, dynamic>.from(v);

      courses = raw.entries.map((e) {
        final key = e.key.toString();
        final m = (e.value is Map) ? Map<String, dynamic>.from(e.value as Map) : <String, dynamic>{};
        final title = (m['title'] ?? m['course_title'] ?? 'Course').toString();
        final code = (m['course_code'] ?? '').toString();

        int numVal(dynamic vv) => (vv is num) ? vv.toInt() : int.tryParse(vv?.toString() ?? '') ?? 0;
        final assignedAt = numVal(m['assignedAt']);

        return {
          'courseKey': key,
          'title': title,
          'code': code,
          'assignedAt': assignedAt,
        };
      }).toList();

      courses.sort((a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int));

      final allowed = <Map<String, dynamic>>[];
      for (final c in courses) {
        final cid = (c['courseKey'] ?? '').toString().trim();
        if (cid.isEmpty) continue;

        final curSnap = await db.child('booking_curriculum/$cid').get();
        if (curSnap.exists && curSnap.value != null) {
          allowed.add(c);
        }
      }

      courses = allowed;
    }
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to load courses: $e')),
    );
    return;
  }

  if (!context.mounted) return;

  if (courses.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No bookable courses. Admin has not enabled booking yet.')),
    );
    return;
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: UiK.appBg,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose course',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: UiK.primaryBlue),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.60,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: courses.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final c = courses[i];
                    final courseKey = (c['courseKey'] ?? '').toString();
                    final title = (c['title'] ?? 'Course').toString();
                    final code = (c['code'] ?? '').toString();

                    return InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => hw.LearnerHomeworkScreen(
                              courseKey: courseKey,
                              courseTitle: title,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: UiK.primaryBlue.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                              ),
                              child: const Icon(Icons.school_rounded, color: UiK.primaryBlue),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    code.isEmpty ? '—' : 'Code: $code',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.grey.shade600,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (courseKeysWithUndone.contains(courseKey))
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.10),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: Colors.red.withOpacity(0.25)),
                                    ),
                                    child: const Text(
                                      'HW',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: Colors.red,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                const Icon(Icons.chevron_right_rounded, color: UiK.primaryBlue),
                              ],
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
        ),
      );
    },
  );
}

/// ✅ Special card: Mail + unread badge sum
class _MailHomeCard extends StatelessWidget {
  const _MailHomeCard();

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final meUid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('mail_index/$meUid');

    return StreamBuilder<DatabaseEvent>(
      stream: meUid.isEmpty ? const Stream.empty() : ref.onValue,
      builder: (context, snap) {
        int unreadTotal = 0;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          v.forEach((_, vv) {
            if (vv is! Map) return;
            final m = vv.map((k, v) => MapEntry(k.toString(), v));

            final deletedAt = m['deletedAt'];
            if (deletedAt != null) return;

            final unread = _toInt(m['unreadCount']);
            unreadTotal += unread;
          });
        }

        return _HomeCard(
          icon: Icons.mail_rounded,
          title: 'Mail',
          subtitle: 'Read & reply',
          routeType: _HomeCardRoute.mail,
          badgeCount: unreadTotal,
        );
      },
    );
  }
}

/// ✅ NEW route type for Call Logs
enum _HomeCardRoute { mail, homework, reminders, callLogs, friends }

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.routeType,
    this.badgeCount = 0,
    this.disableTap = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _HomeCardRoute routeType;
  final int badgeCount;
  final bool disableTap;

  @override
  Widget build(BuildContext context) {
    Widget iconBox() {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: UiK.primaryBlue.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            child: Icon(icon, color: UiK.primaryBlue),
          ),
          if (badgeCount > 0)
            Positioned(
              right: -8,
              top: -8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    final cardBody = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          iconBox(),
          const Spacer(),
          Text(title, style: UiK.titleText(size: 16)),
          const SizedBox(height: 4),
          Text(subtitle, style: UiK.subtleText()),
        ],
      ),
    );

    if (disableTap) return cardBody;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () async {
        if (routeType == _HomeCardRoute.mail) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => LearnerMailScreen()),
          );
          return;
        }

        if (routeType == _HomeCardRoute.callLogs) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CallLogsScreen()),
          );
          return;
        }

        if (routeType == _HomeCardRoute.homework) {
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$title is not ready yet.')),
        );
      },
      child: cardBody,
    );
  }
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
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: UiK.primaryBlue.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
              ),
              child: Icon(icon, color: UiK.primaryBlue),
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
                      color: UiK.primaryBlue,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
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
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right_rounded, color: UiK.primaryBlue),
          ],
        ),
      ),
    );
  }
}

class _UserPick {
  const _UserPick({required this.uid, required this.name, required this.subtitle});
  final String uid;
  final String name;
  final String subtitle;
}

class _ClassesAndPeers {
  const _ClassesAndPeers({
    required this.classIds,
    required this.teacherUids,
    required this.classmateUids,
  });

  final List<String> classIds;
  final Map<String, String> teacherUids;
  final Map<String, String> classmateUids;
}

/// ✅ Homework card with undone badge
class _LearnerHomeworkHomeCard extends StatelessWidget {
  const _LearnerHomeworkHomeCard();

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final meUid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('users/$meUid/courses');

    return StreamBuilder<DatabaseEvent>(
      stream: meUid.isEmpty ? const Stream.empty() : ref.onValue,
      builder: (context, snap) {
        int undoneTotal = 0;
        final Set<String> courseKeysWithUndone = {};

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          final courses = Map<dynamic, dynamic>.from(v);

          for (final entry in courses.entries) {
            final courseKey = entry.key.toString();

            final courseVal = entry.value;
            if (courseVal is! Map) continue;
            final course = Map<dynamic, dynamic>.from(courseVal);

            final attendance = course['attendance'];
            if (attendance is! Map) continue;

            final attMap = Map<dynamic, dynamic>.from(attendance);

            bool thisCourseHasUndone = false;

            for (final sessionVal in attMap.values) {
              if (sessionVal is! Map) continue;
              final session = Map<dynamic, dynamic>.from(sessionVal);

              final hwMapAny = session['homework'];
              if (hwMapAny is! Map) continue;
              final hwMap = Map<dynamic, dynamic>.from(hwMapAny);

              final text = (hwMap['text'] ?? '').toString().trim();
              final due = (hwMap['dueDate'] ?? '').toString().trim();
              if (text.isEmpty && due.isEmpty) continue;

              final doneAt = hwMap['doneAt'];
              final isDone = doneAt != null;

              if (!isDone) {
                undoneTotal += 1;
                thisCourseHasUndone = true;
              }
            }

            if (thisCourseHasUndone) {
              courseKeysWithUndone.add(courseKey);
            }
          }
        }

        final coursesCount = courseKeysWithUndone.length;
        final subtitle = coursesCount == 0 ? 'All done ✅' : '$coursesCount course${coursesCount == 1 ? '' : 's'} • $undoneTotal pending';

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () async {
            await _openHomeworkCoursePicker(
              context,
              courseKeysWithUndone: courseKeysWithUndone,
            );
          },
          child: _HomeCard(
            disableTap: true,
            icon: Icons.assignment_rounded,
            title: 'Homework',
            subtitle: subtitle,
            routeType: _HomeCardRoute.homework,
            badgeCount: undoneTotal,
          ),
        );
      },
    );
  }
}

/// ✅ Reminders card with unread badge
class _RemindersHomeCard extends StatelessWidget {
  const _RemindersHomeCard();

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final uid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('reminders/$uid');

    return StreamBuilder<DatabaseEvent>(
      stream: uid.isEmpty ? const Stream.empty() : ref.onValue,
      builder: (context, snap) {
        int unread = 0;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          v.forEach((_, vv) {
            if (vv is! Map) return;
            final m = vv.map((k, v) => MapEntry(k.toString(), v));
            final readAt = m['readAt'];
            if (readAt == null) unread += 1;
          });
        }

        final subtitle = unread == 0 ? 'All caught up ✅' : '$unread unread';

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LearnerRemindersListScreen()),
            );
          },
          child: _HomeCard(
            disableTap: true,
            icon: Icons.notifications_active_rounded,
            title: 'Reminders',
            subtitle: subtitle,
            routeType: _HomeCardRoute.reminders,
            badgeCount: unread,
          ),
        );
      },
    );
  }
}

/// ✅ Call logs card with “attention needed” badge
class _CallLogsHomeCard extends StatelessWidget {
  const _CallLogsHomeCard();

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  bool _needsAttention(Map<String, dynamic> m) {
    final status = (m['status'] ?? '').toString().trim().toLowerCase();
    final dur = m.containsKey('durationSec') ? _toInt(m['durationSec']) : 0;

    if (status == 'missed') return true;
    if (status == 'ringing') return true;
    if (status == 'ended' && dur <= 0) return true;

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final uid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('call_logs/$uid');

    return StreamBuilder<DatabaseEvent>(
      stream: uid.isEmpty ? const Stream.empty() : ref.onValue,
      builder: (context, snap) {
        int attention = 0;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          v.forEach((_, vv) {
            if (vv is! Map) return;
            final m = vv.map((k, v) => MapEntry(k.toString(), v));
            final mm = m.map((k, v) => MapEntry(k.toString(), v));
            if (_needsAttention(mm)) attention += 1;
          });
        }

        final subtitle = attention == 0 ? 'All good ✅' : '$attention need attention';

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CallLogsScreen()),
            );
          },
          child: _HomeCard(
            disableTap: true,
            icon: Icons.history_rounded,
            title: 'Call Logs',
            subtitle: subtitle,
            routeType: _HomeCardRoute.callLogs,
            badgeCount: attention,
          ),
        );
      },
    );
  }
}