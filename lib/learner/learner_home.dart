import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'learner_homework_screen.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import 'learner_mail_screen.dart';

import 'learner_courses_screen.dart';
import 'learner_profile_screen.dart';

// ✅ Call logs screen
import '../calls/call_logs_screen.dart';

// ✅ Call screen
import '../calls/audio_call_screen.dart';

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
        final name = ('$first $last').trim().isEmpty ? 'Admin' : ('$first $last').trim();

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
    if (me == null) return const _ClassesAndPeers(classIds: [], teacherUids: {}, classmateUids: {});

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

        // legacy teacher name only -> cannot call without uid (we ignore it)
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
      String subtitle = 'Teacher';

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
      String subtitle = 'Learner';

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

/// Simple home dashboard with cards
class _LearnerDashboardLite extends StatelessWidget {
  const _LearnerDashboardLite();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _HomeCardsGrid(),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: Colors.white,
            shape: UiK.cardShape(),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Learner Dashboard', style: UiK.titleText(size: 18)),
                  const SizedBox(height: 10),
                  Text(
                    'Use the cards above to access your tools. Courses stay in the Courses tab.',
                    style: UiK.subtleText(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeCardsGrid extends StatelessWidget {
  const _HomeCardsGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.25,
      children: const [
        _MailHomeCard(),
        _LearnerHomeworkHomeCard(),

        _HomeCard(
          icon: Icons.notifications_active_rounded,
          title: 'Reminders',
          subtitle: 'Coming soon',
          routeType: _HomeCardRoute.reminders,
        ),
        _HomeCard(
          icon: Icons.group_rounded,
          title: 'Friends',
          subtitle: 'Coming soon',
          routeType: _HomeCardRoute.friends,
        ),
      ],
    );
  }
}

Future<void> _openHomeworkCoursePicker(BuildContext context) async {
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
      const SnackBar(content: Text('No courses found.')),
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
                            builder: (_) => LearnerHomeworkScreen(
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


/// ✅ Special card: Mail + unread badge sum
class _MailHomeCard extends StatelessWidget {
  const _MailHomeCard();

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

            // ignore deleted threads for me
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

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

enum _HomeCardRoute { mail, homework, reminders, friends }

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.routeType,
    this.badgeCount = 0,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _HomeCardRoute routeType;
  final int badgeCount;

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

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () async {
        if (routeType == _HomeCardRoute.mail) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LearnerMailScreen()),
          );
          return;
        }

        if (routeType == _HomeCardRoute.homework) {
          await _openHomeworkCoursePicker(context);
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$title is not ready yet.')),
        );
      },

      child: Container(
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
      ),
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

              final hw = session['homework'];
              if (hw is! Map) continue;

              final hwMap = Map<dynamic, dynamic>.from(hw);

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
        final subtitle = coursesCount == 0
            ? 'All done ✅'
            : '$coursesCount course${coursesCount == 1 ? '' : 's'} • $undoneTotal pending';

        return _HomeCard(
          icon: Icons.assignment_rounded,
          title: 'Homework',
          subtitle: subtitle,
          routeType: _HomeCardRoute.homework,
          badgeCount: undoneTotal,
        );

      },
    );
  }
}

