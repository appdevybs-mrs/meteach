import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:url_launcher/url_launcher.dart';
import 'learner_gallery_screen.dart';
import '../shared/app_theme.dart';
import '../shared/session_manager.dart';
import '../shared/watermark_background.dart';

import 'learner_study_coach_screen.dart';
import 'learner_regulations_screen.dart';
import 'learner_mail_screen.dart';
import 'learner_homework_screen.dart' as hw;
import 'learner_courses_screen.dart';
import 'learner_games_screen.dart';
import 'learner_profile_screen.dart';
import 'learner_reminders_list_screen.dart';
import 'learner_booking_screen.dart';

import '../calls/audio_call_screen.dart';

class LearnerHome extends StatefulWidget {
  const LearnerHome({super.key});

  @override
  State<LearnerHome> createState() => _LearnerHomeState();
}

class _LearnerHomeState extends State<LearnerHome> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Future<String>? _displayNameFuture;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _displayNameFuture = _myDisplayName();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  _HomePalette get palette => _toHomePalette(appThemeController.palette);

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

  void _pushScreen(Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  Future<void> _refreshShell() async {
    setState(() {
      _displayNameFuture = _myDisplayName();
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _logout(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    await SessionManager.stopListening();

    if (uid != null && uid.isNotEmpty) {
      try {
        // intentionally empty (your original)
      } catch (_) {}
    }

    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}

    if (uid != null && uid.isNotEmpty) {
      try {
        await FirebaseDatabase.instance.ref('fcm_tokens/$uid').remove();
      } catch (_) {}
    }

    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

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
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    final emailPrefix = email.isNotEmpty ? email.split('@').first : '';

    if (uid == null) {
      return emailPrefix.isNotEmpty ? emailPrefix : 'Learner';
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

    return emailPrefix.isNotEmpty ? emailPrefix : 'Learner';
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
      return const _ClassesAndPeers(
        classIds: [],
        teacherUids: {},
        classmateUids: {},
      );
    }

    final classIds = <String>[];
    final teacherUids = <String, String>{};
    final classmateUids = <String, String>{};

    try {
      final snap = await _db.child('classes').get();
      final v = snap.value;
      if (v is! Map) {
        return _ClassesAndPeers(
          classIds: classIds,
          teacherUids: teacherUids,
          classmateUids: classmateUids,
        );
      }

      final raw = Map<dynamic, dynamic>.from(v);

      raw.forEach((classId, classVal) {
        if (classVal is! Map) return;
        final c = classVal.map((k, vv) => MapEntry(k.toString(), vv));

        final learners = c['learners'];
        bool imInThisClass = false;

        if (learners is Map) {
          final lm = Map<dynamic, dynamic>.from(learners);
          if (lm.containsKey(me)) {
            imInThisClass = true;
          }

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

            if (imInThisClass) {
              classmateUids.putIfAbsent(u, () => name);
            }
          });
        }

        if (!imInThisClass) return;

        classIds.add(classId.toString());

        final cur = c['instructor_current'];
        if (cur is Map) {
          final cm = cur.map((kk, vv) => MapEntry(kk.toString(), vv));
          final tuid = (cm['uid'] ?? '').toString().trim();
          final tname = (cm['name'] ?? '').toString().trim();
          if (tuid.isNotEmpty) {
            teacherUids.putIfAbsent(
              tuid,
                  () => tname.isNotEmpty ? tname : 'Teacher',
            );
          }
        }
      });

      return _ClassesAndPeers(
        classIds: classIds,
        teacherUids: teacherUids,
        classmateUids: classmateUids,
      );
    } catch (_) {
      return _ClassesAndPeers(
        classIds: classIds,
        teacherUids: teacherUids,
        classmateUids: classmateUids,
      );
    }
  }

  Future<List<_UserPick>> _loadTeachersFromMyClasses() async {
    final peers = await _loadMyClassesAndPeers();
    if (peers.teacherUids.isEmpty) return [];

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
                              border: Border.all(
                                color: p.border.withOpacity(0.9),
                              ),
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
                            color: p.cardBg,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: p.border.withOpacity(0.85),
                            ),
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
                            maxHeight:
                            MediaQuery.of(context).size.height * 0.55,
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: items.length,
                            separatorBuilder: (_, __) =>
                            const SizedBox(height: 10),
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
                                    color: p.cardBg,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: p.border.withOpacity(0.85),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        backgroundColor:
                                        p.primary.withOpacity(0.08),
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
                                          crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                                color: p.text.withOpacity(0.62),
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
                                          borderRadius:
                                          BorderRadius.circular(999),
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
                    color: p.cardBg,
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
                  palette: p,
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

  void _openThemeSheet() {
    final p = palette;

    Future<void> pickTheme(AppThemeMode mode) async {
      await appThemeController.setTheme(mode);
      if (!mounted) return;
      setState(() {});
      Navigator.of(context).pop();
    }

    final allModes = AppThemeMode.values;

    showModalBottomSheet(
      context: context,
      backgroundColor: p.appBg,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.80,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: allModes.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final mode = allModes[i];
                  final preview = appThemeController.paletteForMode(mode);

                  return _ThemeChoiceTile(
                    palette: p,
                    title: appThemeController.themeTitle(mode),
                    subtitle: appThemeController.themeSubtitle(mode),
                    selected: appThemeController.mode == mode,
                    preview1: preview.primary,
                    preview2: preview.accent,
                    onTap: () => pickTheme(mode),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: p.appBg,
      drawer: _LearnerDrawer(
        palette: p,
        onOpenProfile: () => _pushScreen(const LearnerProfileScreen()),
        onOpenMail: () => _pushScreen(LearnerMailScreen()),
        onOpenCourses: () => _pushScreen(const LearnerCoursesScreen()),
        onOpenGames: () => _pushScreen(const LearnerGamesScreen()),
        onOpenRegulations: () =>
            _pushScreen(const LearnerRegulationsScreen()),
        onOpenThemeSettings: _openThemeSheet,
        onLogout: () => _logout(context),
      ),
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: p.cardBg,
        leading: IconButton(
          tooltip: 'Menu',
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
                  'Welcome back',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  name.isNotEmpty ? name : 'Learner',
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
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshShell,
        child: WatermarkBackground(
          child: _LearnerDashboardLite(),
        ),
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
    );
  }
}

class _LearnerDashboardLite extends StatefulWidget {
  const _LearnerDashboardLite();

  @override
  State<_LearnerDashboardLite> createState() => _LearnerDashboardLiteState();
}

class _LearnerDashboardLiteState extends State<_LearnerDashboardLite> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  _HomePalette get palette => _toHomePalette(appThemeController.palette);

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

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _courseTypeLabel(Map<String, dynamic> course) {
    final variant = (course['variantKey'] ?? course['variant'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    if (variant == 'online') return 'Online class';
    if (variant == 'offline') return 'Offline class';
    if (variant.isNotEmpty) {
      return '${variant[0].toUpperCase()}${variant.substring(1)} class';
    }

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    final classType = (cls['type'] ?? cls['class_type'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    if (classType.isNotEmpty) {
      return '${classType[0].toUpperCase()}${classType.substring(1)} class';
    }

    return 'Course details';
  }

  String _courseDetailsLine(Map<String, dynamic> course) {
    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    final teacherName = (cls['teacher_name'] ??
        cls['instructor_name'] ??
        cls['teacher'] ??
        cls['instructor'] ??
        '')
        .toString()
        .trim();

    final classId = (cls['class_id'] ?? '').toString().trim();
    final code = (course['course_code'] ?? '').toString().trim();

    final parts = <String>[];

    if (teacherName.isNotEmpty) parts.add(teacherName);
    if (classId.isNotEmpty) parts.add('Class $classId');
    if (code.isNotEmpty) parts.add('Code $code');

    if (parts.isEmpty) return 'Tap to open course details';
    return parts.join(' • ');
  }

  Future<_CourseMeta> _loadCourseMeta({
    required String courseKey,
    required Map<String, dynamic> course,
  }) async {
    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    final classId = (cls['class_id'] ?? '').toString().trim();
    final courseId =
    (cls['course_id'] ?? course['id'] ?? '').toString().trim();
    final variantKey = (course['variantKey'] ?? course['variant'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    int? planned;
    final schedule = cls['schedule'];
    if (schedule is Map) {
      planned = _toInt(
        schedule['meetingsCount'] ??
            schedule['totalMeetings'] ??
            schedule['sessionsCount'],
      );
      if (planned <= 0) planned = 0;
    }

    if ((planned == null || planned <= 0)) {
      planned = _toInt(
        cls['meetingsCount'] ?? cls['totalMeetings'] ?? cls['sessionsCount'],
      );
    }

    if ((planned <= 0) && classId.isNotEmpty) {
      try {
        final snap = await _db.child('classes/$classId/schedule').get();
        if (snap.exists && snap.value is Map) {
          final m = Map<String, dynamic>.from(snap.value as Map);
          final n = _toInt(
            m['meetingsCount'] ?? m['totalMeetings'] ?? m['sessionsCount'],
          );
          if (n > 0) planned = n;
        }
      } catch (_) {}
    }

    int totalLessons = 0;
    if (courseId.isNotEmpty) {
      try {
        DatabaseReference syllabusRef = _db.child('syllabi/$courseId');
        if (variantKey.isNotEmpty) {
          syllabusRef = syllabusRef.child(variantKey);
        }

        final sSnap = await syllabusRef.get();
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

  Future<Set<String>> _coveredSessionIdsFromAttendance({
    required String learnerUid,
    required String courseId,
    required Map<String, dynamic> course,
  }) async {
    final covered = <String>{};
    final variantKey = (course['variantKey'] ?? course['variant'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    final Map<int, String> sessionIdByNumber = {};

    if (courseId.isNotEmpty) {
      try {
        DatabaseReference syllabusRef = _db.child('syllabi/$courseId');
        if (variantKey.isNotEmpty) {
          syllabusRef = syllabusRef.child(variantKey);
        }

        final sSnap = await syllabusRef.get();
        if (sSnap.exists && sSnap.value is Map) {
          final s = Map<String, dynamic>.from(sSnap.value as Map);
          final units = s['units'];

          if (units is List) {
            for (final u in units) {
              if (u is! Map) continue;
              final unit = Map<String, dynamic>.from(u);
              final sessions = unit['sessions'];

              if (sessions is List) {
                for (final ss in sessions) {
                  if (ss is! Map) continue;
                  final sess = Map<String, dynamic>.from(ss);

                  final sn = _toInt(sess['sessionNumber']);
                  final sid = (sess['id'] ?? '').toString().trim();

                  if (sn > 0 && sid.isNotEmpty) {
                    sessionIdByNumber[sn] = sid;
                  }
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    final att = course['attendance'];
    if (att is Map) {
      final attMap = Map<String, dynamic>.from(att);

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
            final type =
            (item['type'] ?? '').toString().trim().toLowerCase();
            if (type != 'syllabus') continue;

            final sid = (item['sessionId'] ?? '').toString().trim();
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(item['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }

        if (!usedNew) {
          final taught = m['taught'];
          if (taught is Map) {
            final tm = Map<String, dynamic>.from(taught);
            final sid = (tm['sessionId'] ?? '').toString().trim();
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(tm['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }
      }
    }

    if (learnerUid.isNotEmpty && courseId.isNotEmpty) {
      try {
        final snap = await _db
            .child(
          'booking_progress/$learnerUid/$courseId/flexible_attendance',
        )
            .get();

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

                final type =
                (item['type'] ?? '').toString().trim().toLowerCase();
                if (type != 'syllabus') continue;

                final sid = (item['sessionId'] ?? '').toString().trim();
                if (sid.isNotEmpty) {
                  covered.add(sid);
                  continue;
                }

                final sn = _toInt(item['sessionNumber']);
                if (sn > 0) {
                  final mapped = sessionIdByNumber[sn];
                  if (mapped != null && mapped.isNotEmpty) {
                    covered.add(mapped);
                  }
                }
              }
            } else {
              final sn = _toInt(r['sessionNo']);
              if (sn > 0) {
                final mapped = sessionIdByNumber[sn];
                if (mapped != null && mapped.isNotEmpty) {
                  covered.add(mapped);
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    return covered;
  }

  Future<List<_CourseProgressItem>> _loadProgressItems() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return [];

    try {
      final snap = await _db.child('users/$uid/courses').get();
      final v = snap.value;
      if (v is! Map) return [];

      final raw = Map<dynamic, dynamic>.from(v);
      final out = <_CourseProgressItem>[];

      for (final e in raw.entries) {
        final key = e.key.toString();
        if (e.value is! Map) continue;

        final course = Map<String, dynamic>.from(e.value as Map);
        final title = (course['title'] ?? course['course_title'] ?? 'Course')
            .toString()
            .trim();
        final code = (course['course_code'] ?? '').toString().trim();

        final meta = await _loadCourseMeta(courseKey: key, course: course);
        final covered = await _coveredSessionIdsFromAttendance(
          learnerUid: uid,
          courseId: meta.courseId,
          course: course,
        );

        final total = meta.totalLessons > 0
            ? meta.totalLessons
            : ((meta.plannedMeetings ?? 0) > 0 ? (meta.plannedMeetings ?? 0) : 0);

        final completed = total > 0
            ? covered.length.clamp(0, total)
            : covered.length;

        final double progress =
        total > 0 ? (completed / total).clamp(0.0, 1.0) : 0.0;

        out.add(
          _CourseProgressItem(
            courseKey: key,
            title: title.isEmpty ? 'Course' : title,
            code: code,
            classType: _courseTypeLabel(course),
            detailsLine: _courseDetailsLine(course),
            completed: completed,
            total: total,
            progress: progress,
          ),
        );
      }

      out.sort((a, b) => b.progress.compareTo(a.progress));
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<bool> _hasFlexibleBookableCourse() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return false;

    try {
      final snap = await _db.child('users/$uid/courses').get();
      final v = snap.value;
      if (v is! Map) return false;

      final raw = Map<dynamic, dynamic>.from(v);

      for (final e in raw.entries) {
        final key = e.key.toString();
        final val = e.value;
        if (val is! Map) continue;

        final m = Map<String, dynamic>.from(val);

        final realCourseId = (m['id'] ?? m['courseId'] ?? '').toString().trim();
        final courseId = realCourseId.isNotEmpty ? realCourseId : key;

        final variantKey = (m['variantKey'] ?? m['variant'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        if (variantKey != 'flexible') continue;

        final flexibleSyllabusSnap =
        await _db.child('syllabi/$courseId/flexible').get();

        if (flexibleSyllabusSnap.exists) {
          return true;
        }
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  void _openCoursesScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LearnerCoursesScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    final p = palette;

    if (uid.isEmpty) {
      return Center(
        child: Text(
          'Not logged in.',
          style: TextStyle(
            color: p.text,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return SafeArea(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + (bottomPad > 0 ? bottomPad : 12),
        ),
        children: [
          FutureBuilder<String>(
            future: _db
                .child('users/$uid')
                .get()
                .then((snap) {
              final v = snap.value;
              if (v is Map) {
                final m = v.map((k, vv) => MapEntry(k.toString(), vv));
                final first = (m['first_name'] ?? '').toString().trim();
                final last = (m['last_name'] ?? '').toString().trim();
                final full = ('$first $last').trim();
                if (full.isNotEmpty) return full;
              }
              return 'Learner';
            })
                .catchError((_) => 'Learner'),
            builder: (context, snap) {
              final name = (snap.data ?? 'Learner').trim();
              return _LearnerHeroCard(
                palette: p,
                learnerName: name.isEmpty ? 'Learner' : name,
                onOpenCourses: _openCoursesScreen,
              );
            },
          ),
          const SizedBox(height: 16),
          FutureBuilder<bool>(
            future: _hasFlexibleBookableCourse(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const SizedBox.shrink();
              }

              final hasFlexible = snap.data ?? false;
              if (!hasFlexible) {
                return const SizedBox.shrink();
              }

              return Column(
                children: [
                  _SectionTitle(
                    palette: p,
                    title: 'Booking',
                  ),
                  const SizedBox(height: 10),
                  const _BookingTopCard(),
                  const SizedBox(height: 16),
                ],
              );
            },
          ),

          const SizedBox(height: 10),
          _StudyCoachHomeCard(),
          const SizedBox(height: 10),
          FutureBuilder<List<_CourseProgressItem>>(
            future: _loadProgressItems(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return _LoadingCard(
                  palette: p,
                  text: 'Loading your progress...',
                );
              }

              final items = snap.data ?? const <_CourseProgressItem>[];
              if (items.isEmpty) {
                return _EmptyCard(
                  palette: p,
                  text: 'No course progress found yet.',
                );
              }

              return Column(
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    _ProgressCard(
                      palette: p,
                      item: items[i],
                      onTap: _openCoursesScreen,
                    ),
                    if (i != items.length - 1) const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),

          _SectionTitle(
            palette: p,
            title: 'Homework & Reminders',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _LearnerHomeworkHomeCard()),
              const SizedBox(width: 12),
              Expanded(child: _RemindersHomeCard()),
            ],
          ),

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

class _CourseProgressItem {
  final String courseKey;
  final String title;
  final String code;
  final String classType;
  final String detailsLine;
  final int completed;
  final int total;
  final double progress;

  const _CourseProgressItem({
    required this.courseKey,
    required this.title,
    required this.code,
    required this.classType,
    required this.detailsLine,
    required this.completed,
    required this.total,
    required this.progress,
  });
}

class _LearnerHeroCard extends StatelessWidget {
  const _LearnerHeroCard({
    required this.palette,
    required this.learnerName,
    required this.onOpenCourses,
  });

  final _HomePalette palette;
  final String learnerName;
  final VoidCallback onOpenCourses;

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
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: const Icon(
              Icons.school_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
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
                const SizedBox(height: 4),
                Text(
                  learnerName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 24,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _HeroMiniButton(
                      label: 'My Courses',
                      icon: Icons.menu_book_rounded,
                      onTap: onOpenCourses,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroMiniButton extends StatelessWidget {
  const _HeroMiniButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.12),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 17),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.palette,
    required this.title,
    this.actionLabel = '',
    this.onActionTap,
  });

  final _HomePalette palette;
  final String title;
  final String actionLabel;
  final VoidCallback? onActionTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: palette.primary,
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
        ),
        if (actionLabel.trim().isNotEmpty && onActionTap != null)
          TextButton(
            onPressed: onActionTap,
            child: Text(
              actionLabel,
              style: TextStyle(
                color: palette.accent,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
      ],
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({
    required this.palette,
    required this.text,
  });

  final _HomePalette palette;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border.withOpacity(0.85)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.palette,
    required this.text,
  });

  final _HomePalette palette;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border.withOpacity(0.85)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: palette.text,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.palette,
    required this.item,
    required this.onTap,
  });

  final _HomePalette palette;
  final _CourseProgressItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final percentText = (item.progress * 100).round();

    return Material(
      color: palette.cardBg,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: palette.border.withOpacity(0.85)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 12,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: palette.soft,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(Icons.menu_book_rounded, color: palette.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.primary,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.code.isEmpty
                              ? item.classType
                              : '${item.classType} • Code: ${item.code}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text.withOpacity(0.60),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: palette.soft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$percentText%',
                      style: TextStyle(
                        color: palette.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                item.detailsLine,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text.withOpacity(0.70),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 10,
                  value: item.total > 0 ? item.progress : 0,
                  backgroundColor: palette.soft.withOpacity(0.8),
                  valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.total > 0
                          ? '${item.completed} of ${item.total} completed'
                          : '${item.completed} completed',
                      style: TextStyle(
                        color: palette.text.withOpacity(0.68),
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: palette.accent.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: palette.accent.withOpacity(0.25),
                      ),
                    ),
                    child: Text(
                      'Open Course',
                      style: TextStyle(
                        color: palette.accent,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookingTopCard extends StatefulWidget {
  const _BookingTopCard();

  @override
  State<_BookingTopCard> createState() => _BookingTopCardState();
}

class _BookingTopCardState extends State<_BookingTopCard> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  _HomePalette get palette => _toHomePalette(appThemeController.palette);

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

      final m = Map<String, dynamic>.from(val);

      final realCourseId = (m['id'] ?? m['courseId'] ?? '').toString().trim();
      final courseId = realCourseId.isNotEmpty ? realCourseId : key;

      final variantKey = (m['variantKey'] ?? m['variant'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (variantKey != 'flexible') continue;

      final title = (m['title'] ?? m['course_title'] ?? 'Course').toString();

      int numVal(dynamic vv) =>
          (vv is num) ? vv.toInt() : int.tryParse(vv?.toString() ?? '') ?? 0;

      final assignedAt = numVal(m['assignedAt']);

      final flexibleSyllabusSnap =
      await _db.child('syllabi/$courseId/flexible').get();
      if (!flexibleSyllabusSnap.exists) continue;

      temp.add({
        'courseId': courseId,
        'title': title,
        'assignedAt': assignedAt,
      });
    }

    temp.sort((a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int));
    return temp;
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
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
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
          final joinWindowEnds = start.add(const Duration(minutes: 10));
          if (joinWindowEnds.isBefore(now)) continue;

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
      final snap =
      await _db.child('booking_availability/$teacherId/$courseId').get();
      final v = snap.value;
      if (v is! Map) return null;

      final m = Map<String, dynamic>.from(v);

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
    final openFrom = start.subtract(const Duration(minutes: 5));
    final openUntil = start.add(const Duration(minutes: 10));
    return now.isAfter(openFrom) && now.isBefore(openUntil);
  }

  Future<void> _openExternalUrl(BuildContext context, String url) async {
    var u = url.trim();
    if (u.isEmpty) return;

    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }

    final uri = Uri.tryParse(u);
    if (uri == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid meeting link.')),
        );
      }
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
  }

  String _bookingKey(String courseId, String dayKey, String hhmm) =>
      '$courseId|$dayKey|$hhmm';

  Future<void> _autoMarkPresentAndTaught({
    required String learnerUid,
    required _NextBooking next,
  }) async {
    if (learnerUid.isEmpty) return;

    try {
      final slotSnap = await _db
          .child(
        'booking_reservations/${next.courseId}/${next.dayKey}/${next.time}',
      )
          .get();
      if (!slotSnap.exists || slotSnap.value is! Map) return;
      final slot = Map<String, dynamic>.from(slotSnap.value as Map);

      final int sessionNo = _toInt(slot['sessionNo']);
      final String bKey = _bookingKey(next.courseId, next.dayKey, next.time);

      final ref = _db.child(
        'booking_progress/$learnerUid/${next.courseId}/flexible_attendance/$bKey',
      );

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
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () async {
            await _openBookingCoursePicker(context);
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  p.accent,
                  p.accent.withOpacity(0.88),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: p.accent.withOpacity(0.22),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.25)),
                  ),
                  child: const Icon(
                    Icons.calendar_month_rounded,
                    color: Colors.white,
                  ),
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
                          fontSize: 17,
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
                  padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: p.cardBg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Open',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: p.primary,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        FutureBuilder<_NextBooking?>(
          future: _findMyNextBookingAcrossCourses(),
          builder: (context, snap) {
            final next = snap.data;
            if (snap.connectionState == ConnectionState.waiting) {
              return _LoadingCard(
                palette: p,
                text: 'Checking your next class...',
              );
            }

            if (next == null) {
              return _EmptyCard(
                palette: p,
                text: 'No upcoming reserved class found right now.',
              );
            }

            return FutureBuilder<_MeetInfo?>(
              future: _loadMeetInfo(
                teacherId: next.teacherId,
                courseId: next.courseId,
              ),
              builder: (context, ms) {
                final meet = ms.data;
                final canJoin =
                    (meet != null) &&
                        _canJoinNow(next.start, meet.durationMinutes);

                final timeStr = '${_friendlyDate(next.start)} • ${next.time}';
                final teacherStr = next.teacherName;

                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: p.cardBg,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: p.border.withOpacity(0.85)),
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
                      Row(
                        children: [
                          Icon(
                            Icons.upcoming_rounded,
                            size: 18,
                            color: p.accent,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Next reserved class',
                            style: TextStyle(
                              color: p.text,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Teacher: $teacherStr',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: p.text.withOpacity(0.70),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (meet == null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: p.soft.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: p.border.withOpacity(0.85),
                            ),
                          ),
                          child: Text(
                            'Meet link not set for this course yet.',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: p.text,
                            ),
                          ),
                        ),
                      ] else ...[
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: p.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            minimumSize: const Size(double.infinity, 48),
                          ),
                          onPressed: canJoin
                              ? () async {
                            final uid =
                                FirebaseAuth.instance.currentUser?.uid ?? '';

                            await _openExternalUrl(context, meet.meetUrl);

                            if (uid.isNotEmpty) {
                              unawaited(
                                _autoMarkPresentAndTaught(
                                  learnerUid: uid,
                                  next: next,
                                ),
                              );
                            }
                          }
                              : null,
                          child: Text(
                            canJoin
                                ? 'Join Google Meet'
                                : 'Join available near session time',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Join opens 5 min before start and stays available until 10 min after start.',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: p.text.withOpacity(0.60),
                            fontSize: 12,
                          ),
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
  final p = _paletteFromTheme();

  List<Map<String, dynamic>> courses = [];

  try {
    final snap = await db.child('users/$uid/courses').get();
    final v = snap.value;

    if (v is Map) {
      final raw = Map<dynamic, dynamic>.from(v);

      for (final e in raw.entries) {
        final key = e.key.toString();
        final val = e.value;
        if (val is! Map) continue;

        final m = Map<String, dynamic>.from(val);

        final realCourseId = (m['id'] ?? m['courseId'] ?? '').toString().trim();
        final courseId = realCourseId.isNotEmpty ? realCourseId : key;

        final variantKey = (m['variantKey'] ?? m['variant'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        if (variantKey != 'flexible') continue;

        final title = (m['title'] ?? m['course_title'] ?? 'Course').toString();
        final code = (m['course_code'] ?? '').toString();

        int numVal(dynamic vv) =>
            (vv is num) ? vv.toInt() : int.tryParse(vv?.toString() ?? '') ?? 0;

        final assignedAt = numVal(m['assignedAt']);

        final flexibleSyllabusSnap =
        await db.child('syllabi/$courseId/flexible').get();
        if (!flexibleSyllabusSnap.exists) continue;

        courses.add({
          'courseKey': courseId,
          'title': title,
          'code': code,
          'assignedAt': assignedAt,
        });
      }

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
      const SnackBar(
        content: Text('No Seats available. Please try again later.'),
      ),
    );
    return;
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: p.appBg,
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
              Text(
                'Choose course to book',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: p.primary,
                ),
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
                            builder: (_) =>
                                LearnerBookingScreen(courseId: courseKey),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: p.cardBg,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: p.border.withOpacity(0.85)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: p.soft,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: p.border.withOpacity(0.85),
                                ),
                              ),
                              child: Icon(
                                Icons.calendar_month_rounded,
                                color: p.primary,
                              ),
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
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: p.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    code.isEmpty ? '—' : 'Code: $code',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: p.text.withOpacity(0.62),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: p.primary,
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
  final p = _paletteFromTheme();

  List<Map<String, dynamic>> courses = [];
  try {
    final snap = await db.child('users/$uid/courses').get();
    final v = snap.value;

    if (v is Map) {
      final raw = Map<dynamic, dynamic>.from(v);

      courses = raw.entries.map((e) {
        final key = e.key.toString();
        final m = (e.value is Map)
            ? Map<String, dynamic>.from(e.value as Map)
            : <String, dynamic>{};
        final title = (m['title'] ?? m['course_title'] ?? 'Course').toString();
        final code = (m['course_code'] ?? '').toString();

        int numVal(dynamic vv) =>
            (vv is num) ? vv.toInt() : int.tryParse(vv?.toString() ?? '') ?? 0;
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
      const SnackBar(content: Text('All slots are full, please try again later')),
    );
    return;
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: p.appBg,
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
              Text(
                'Choose course',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: p.primary,
                ),
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
                          color: p.cardBg,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: p.border.withOpacity(0.85),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: p.soft,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: p.border.withOpacity(0.85),
                                ),
                              ),
                              child: Icon(
                                Icons.school_rounded,
                                color: p.primary,
                              ),
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
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: p.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    code.isEmpty ? '—' : 'Code: $code',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: p.text.withOpacity(0.62),
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
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.10),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: Colors.red.withOpacity(0.25),
                                      ),
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
                                Icon(
                                  Icons.chevron_right_rounded,
                                  color: p.primary,
                                ),
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
          color: palette.cardBg,
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
                      color: palette.text.withOpacity(0.62),
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
    );
  }
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

class _LearnerHomeworkHomeCard extends StatelessWidget {
  const _LearnerHomeworkHomeCard();

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final meUid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('users/$meUid/courses');
    final p = _paletteFromTheme();

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
        final subtitle = coursesCount == 0
            ? 'All done ✅'
            : '$coursesCount course${coursesCount == 1 ? '' : 's'} • $undoneTotal pending';

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () async {
            await _openHomeworkCoursePicker(
              context,
              courseKeysWithUndone: courseKeysWithUndone,
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: p.border.withOpacity(0.85)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: p.soft,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: p.border.withOpacity(0.85)),
                      ),
                      child: Icon(Icons.assignment_rounded, color: p.primary),
                    ),
                    if (undoneTotal > 0)
                      Positioned(
                        right: -8,
                        top: -8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: Text(
                            undoneTotal > 99 ? '99+' : '$undoneTotal',
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
                const SizedBox(height: 18),
                Text(
                  'Homework',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: p.text.withOpacity(0.62),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RemindersHomeCard extends StatelessWidget {
  const _RemindersHomeCard();

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final uid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('reminders/$uid');
    final p = _paletteFromTheme();

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
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const LearnerRemindersListScreen(),
              ),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: p.border.withOpacity(0.85)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: p.soft,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: p.border.withOpacity(0.85)),
                      ),
                      child: Icon(
                        Icons.notifications_active_rounded,
                        color: p.primary,
                      ),
                    ),
                    if (unread > 0)
                      Positioned(
                        right: -8,
                        top: -8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
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
                const SizedBox(height: 18),
                Text(
                  'Reminders',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: p.text.withOpacity(0.62),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GalleryHomeCard extends StatelessWidget {
  const _GalleryHomeCard();

  @override
  Widget build(BuildContext context) {
    final p = _paletteFromTheme();

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const LearnerGalleryScreen(),
          ),
        );
      },
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withOpacity(0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: p.border.withOpacity(0.85)),
              ),
              child: Icon(
                Icons.photo_library_rounded,
                color: p.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gallery',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Open your photos and videos',
                    style: TextStyle(
                      color: p.text.withOpacity(0.62),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(
                Icons.chevron_right_rounded,
                color: p.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class _StudyCoachHomeCard extends StatelessWidget {
  const _StudyCoachHomeCard();

  @override
  Widget build(BuildContext context) {
    final p = _paletteFromTheme();

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const LearnerStudyCoachScreen(),
          ),
        );
      },
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withOpacity(0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: p.border.withOpacity(0.85)),
              ),
              child: Icon(
                Icons.psychology_alt_rounded,
                color: p.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Study Coach',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Set goals, reminders, and track progress',
                    style: TextStyle(
                      color: p.text.withOpacity(0.62),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(
                Icons.chevron_right_rounded,
                color: p.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LearnerDrawer extends StatelessWidget {
  const _LearnerDrawer({
    required this.palette,
    required this.onOpenProfile,
    required this.onOpenMail,
    required this.onOpenCourses,
    required this.onOpenGames,
    required this.onOpenRegulations,
    required this.onOpenThemeSettings,
    required this.onLogout,
  });

  final _HomePalette palette;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenCourses;
  final VoidCallback onOpenGames;
  final VoidCallback onOpenRegulations;
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
                    child: Icon(
                      Icons.school_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Learner Menu',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
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
                    icon: Icons.menu_book_rounded,
                    title: 'My Courses',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenCourses();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.sports_esports_rounded,
                    title: 'Games',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenGames();
                    },
                  ),
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
                    icon: Icons.mail_rounded,
                    title: 'Mail',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenMail();
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
                    icon: Icons.palette_rounded,
                    title: 'Theme Settings',
                    subtitle: 'Choose your app look',
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
        color: palette.cardBg,
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

class _ThemeChoiceTile extends StatelessWidget {
  const _ThemeChoiceTile({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.preview1,
    required this.preview2,
    required this.onTap,
  });

  final _HomePalette palette;
  final String title;
  final String subtitle;
  final bool selected;
  final Color preview1;
  final Color preview2;
  final VoidCallback onTap;

  final Color _fallbackBorder = const Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: palette.cardBg,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? preview1 : palette.border.withOpacity(0.9),
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
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: palette.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: palette.text.withOpacity(0.62),
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
                color: selected ? preview1 : _fallbackBorder,
              ),
            ],
          ),
        ),
      ),
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

_HomePalette _paletteFromTheme() {
  final p = appThemeController.palette;
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