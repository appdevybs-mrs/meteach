import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'teacher_public_gallery_screen.dart';
import 'teacher_online_circle_screen.dart';
import '../shared/app_theme.dart';
import '../shared/app_tour_guide.dart' show AppTourHighlightShape;
import '../shared/first_login_agreement.dart';
import '../shared/session_manager.dart';
import '../shared/teacher_tour_guide.dart';
import 'TeacherStoriesScreen.dart';
import 'teacher_classes.dart';
import 'teacher_games_screen.dart';
import 'teacher_mail.dart';
import 'teacher_online_booking.dart';
import 'teacher_profile.dart';
import 'teacher_regulations_screen.dart';
import 'teacher_reminder.dart';
import 'teacher_schedule.dart';
import 'teacher_shared_files_screen.dart';
import 'teacher_syllabi_screen.dart';
import 'teacher_wages_screen.dart';

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
  static const String usersNode = 'users';
  static const String classesNode = 'classes';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _menuButtonKey = GlobalKey();
  final GlobalKey _guideButtonKey = GlobalKey();
  final GlobalKey _heroCardKey = GlobalKey();
  final GlobalKey _inboxCardKey = GlobalKey();
  final GlobalKey _remindersCardKey = GlobalKey();
  final GlobalKey _overviewPanelKey = GlobalKey();
  final GlobalKey _classesCardKey = GlobalKey();
  final GlobalKey _nextClassCardKey = GlobalKey();

  Stream<DatabaseEvent>? _remindersStream;
  Stream<DatabaseEvent>? _mailIndexStream;

  Future<_ClassesSummary>? _classesSummaryFuture;
  Future<int>? _upcomingOnlineCountFuture;
  Future<String>? _displayNameFuture;
  Future<_HomeUpcomingClass?>? _nextUpcomingClassFuture;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FirstLoginAgreement.ensureAccepted(context, roleKey: 'teacher');
    });

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _remindersStream = _db
          .child('reminders/$uid')
          .onValue
          .asBroadcastStream();
      _mailIndexStream = _db
          .child('mail_index/$uid')
          .onValue
          .asBroadcastStream();
      _classesSummaryFuture = _loadClassesSummaryForHome(uid);
      _upcomingOnlineCountFuture = _loadUpcomingOnlineCountForHome(uid);
      _displayNameFuture = _myDisplayName();
      _nextUpcomingClassFuture = _loadNextUpcomingClassForHome(uid);
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
      _nextUpcomingClassFuture = _loadNextUpcomingClassForHome(uid);
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
    } catch (_) {}

    await FirebaseAuth.instance.signOut();

    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? '').toString().trim().toLowerCase();
    return r == 'teacher' || r == 'teachers' || r == 'teacher(s)';
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
            ? Map<String, dynamic>.from(value)
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

        final matchesName =
            teacherName.isNotEmpty &&
            _norm(
                  legacyInstructorName.isNotEmpty
                      ? legacyInstructorName
                      : curName,
                ) ==
                _norm(teacherName);

        final legacySerial = (c['instructorserial'] ?? c['serial'] ?? '')
            .toString()
            .trim();
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

  Future<_HomeUpcomingClass?> _loadNextUpcomingClassForHome(
    String teacherUid,
  ) async {
    try {
      final snap = await _db.child(classesNode).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        return null;
      }

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      final now = DateTime.now();
      final allUpcoming = <_HomeUpcomingClass>[];

      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map) continue;

        final c = Map<String, dynamic>.from(value);

        final instructorCurrent = c['instructor_current'];
        if (instructorCurrent is! Map) continue;

        final currentMap = Map<String, dynamic>.from(instructorCurrent);
        final currentUid = (currentMap['uid'] ?? '').toString().trim();
        if (currentUid != teacherUid) continue;

        final occurrences = _generateOccurrencesForHome(c);

        for (final occ in occurrences) {
          if (occ.start.isAfter(now)) {
            allUpcoming.add(occ);
          }
        }
      }

      if (allUpcoming.isEmpty) return null;

      allUpcoming.sort((a, b) => a.start.compareTo(b.start));
      return allUpcoming.first;
    } catch (_) {
      return null;
    }
  }

  List<_HomeUpcomingClass> _generateOccurrencesForHome(
    Map<String, dynamic> cls,
  ) {
    if (cls['status']?.toString() != 'active') return [];

    final schedule = (cls['schedule'] is Map)
        ? Map<String, dynamic>.from(cls['schedule'] as Map)
        : null;
    if (schedule == null) return [];

    final firstDateRaw = schedule['first_session_date']?.toString() ?? '';
    final firstDate = DateTime.tryParse(firstDateRaw);
    if (firstDate == null) return [];

    final sessionsRaw = schedule['sessions'];
    if (sessionsRaw is! List) return [];

    final pattern = sessionsRaw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (pattern.isEmpty) return [];

    final countLimitRaw = schedule['sessions_count']?.toString() ?? '';
    int countLimit = int.tryParse(countLimitRaw) ?? 0;
    if (countLimit <= 0) countLimit = 200;

    final classId = (cls['class_id'] ?? cls['id'] ?? '').toString().trim();
    final courseCode = (cls['course_code'] ?? '').toString().trim();
    final courseTitle = (cls['course_title'] ?? '').toString().trim();

    final List<_HomeUpcomingClass> occ = [];

    DateTime cursor = DateTime(firstDate.year, firstDate.month, firstDate.day);

    for (int week = 0; week < 52; week++) {
      for (final s in pattern) {
        if (occ.length >= countLimit) break;

        final dayShort = (s['day'] ?? 'Mon').toString();
        final targetWeekday = _weekdayFromShortForHome(dayShort);

        int diff = targetWeekday - cursor.weekday;
        if (diff < 0) diff += 7;
        final sDate = cursor.add(Duration(days: diff));

        final startTimeStr = (s['start_time'] ?? '00:00').toString();
        final parts = startTimeStr.split(':');

        final hh = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
        final mm = parts.length >= 2 ? int.tryParse(parts[1]) : null;

        final startHour = (hh != null && hh >= 0 && hh <= 23) ? hh : 0;
        final startMin = (mm != null && mm >= 0 && mm <= 59) ? mm : 0;

        final start = DateTime(
          sDate.year,
          sDate.month,
          sDate.day,
          startHour,
          startMin,
        );

        if (start.isBefore(firstDate)) continue;

        final durRaw = (s['duration_min'] ?? '60').toString();
        final dur = int.tryParse(durRaw);
        final durationMin = (dur != null && dur > 0) ? dur : 60;

        occ.add(
          _HomeUpcomingClass(
            classId: classId,
            courseCode: courseCode,
            courseTitle: courseTitle,
            start: start,
            end: start.add(Duration(minutes: durationMin)),
          ),
        );
      }

      cursor = cursor.add(const Duration(days: 7));
      if (occ.length >= countLimit) break;
    }

    occ.sort((a, b) => a.start.compareTo(b.start));
    return occ;
  }

  int _weekdayFromShortForHome(String day) {
    const days = {
      'Mon': 1,
      'Tue': 2,
      'Wed': 3,
      'Thu': 4,
      'Fri': 5,
      'Sat': 6,
      'Sun': 7,
    };
    return days[day] ?? 1;
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

  int _toInt(dynamic v) {
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
                    ...AppThemeMode.values.map((mode) {
                      final previewPalette = appThemeController.paletteForMode(
                        mode,
                      );

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ThemeChoiceTile(
                          title: appThemeController.themeTitle(mode),
                          subtitle: appThemeController.themeSubtitle(mode),
                          selected: appThemeController.mode == mode,
                          preview1: previewPalette.primary,
                          preview2: previewPalette.accent,
                          onTap: () => pickTheme(mode),
                        ),
                      );
                    }),
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
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_home',
      hints: [
        const TeacherTourHint(
          title: 'Teacher dashboard',
          line:
              'This screen is your operational center for classes, mail, reminders, and daily actions.',
          highlightShape: AppTourHighlightShape.fullscreen,
        ),
        TeacherTourHint(
          title: 'Open menu',
          line:
              'Use this button to open all teacher tools and navigation links.',
          targetKey: _menuButtonKey,
          highlightShape: AppTourHighlightShape.circle,
        ),
        TeacherTourHint(
          title: 'Guide',
          line: 'Tap here anytime to restart the guided tour for this screen.',
          targetKey: _guideButtonKey,
          highlightShape: AppTourHighlightShape.circle,
        ),
        TeacherTourHint(
          title: 'Teacher summary',
          line:
              'This card shows your profile shortcut and quick access to your teaching schedule.',
          targetKey: _heroCardKey,
        ),
        TeacherTourHint(
          title: 'Inbox status',
          line:
              'This indicator shows unread mail and opens the teacher mailbox directly.',
          targetKey: _inboxCardKey,
        ),
        TeacherTourHint(
          title: 'Reminders status',
          line:
              'This card shows pending reminders and opens your reminders management screen.',
          targetKey: _remindersCardKey,
        ),
        TeacherTourHint(
          title: 'Overview panel',
          line:
              'This section summarizes classes, learners, and upcoming online sessions.',
          targetKey: _overviewPanelKey,
        ),
        TeacherTourHint(
          title: 'Classes shortcut',
          line: 'Use this card to open your classes list quickly.',
          targetKey: _classesCardKey,
        ),
        TeacherTourHint(
          title: 'Next class',
          line:
              'This card highlights your next scheduled class and opens the schedule details.',
          targetKey: _nextClassCardKey,
        ),
      ],
    );

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: p.appBg,
      drawer: _TeacherDrawer(
        palette: p,
        onOpenProfile: () => _pushScreen(const TeacherProfileScreen()),
        onOpenSchedule: () => _pushScreen(const TeacherSchedule()),
        onOpenClasses: () => _pushScreen(const TeacherClassesScreen()),
        onOpenGames: () => _pushScreen(const TeacherGamesScreen()),
        onOpenStories: () => _pushScreen(TeacherStoriesScreen()),
        onOpenOnlineBooking: () =>
            _pushScreen(const TeacherOnlineBookingScreen()),

        onOpenOnlineCircle: () => _pushScreen(TeacherOnlineCircleScreen()),
        onOpenMail: () => _pushScreen(const TeacherMailScreen()),
        onOpenReminders: () => _pushScreen(const TeacherReminderScreen()),
        onOpenGallery: () => _pushScreen(const TeacherPublicGalleryScreen()),
        onOpenWages: () => _pushScreen(const TeacherWagesScreen()),
        onOpenRegulations: () => _pushScreen(const TeacherRegulationsScreen()),
        onOpenSyllabi: () => _pushScreen(TeacherSyllabiScreen()),
        onOpenShared: () => _pushScreen(const TeacherSharedFilesScreen()),

        onOpenThemeSettings: _openThemeSheet,
        onRestartTour: () async {
          await TeacherTourGuide.resetAll();
          if (!context.mounted) return;
          await TeacherTourGuide.startNow(
            context,
            screenId: 'teacher_home',
            hints: const [
              TeacherTourHint(
                title: 'Teacher dashboard',
                line:
                    'This is your main hub for classes, reminders, and quick actions.',
              ),
              TeacherTourHint(
                title: 'Open menu',
                line:
                    'Use the menu button to open all teacher tools and screens.',
              ),
            ],
          );
        },
        onLogout: () => _logout(context),
      ),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.white,
        leading: IconButton(
          key: _menuButtonKey,
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
                    color: p.text.withValues(alpha: 0.72),
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
            key: _guideButtonKey,
            tooltip: 'Guide',
            icon: Icon(Icons.help_outline_rounded, color: p.primary),
            onPressed: () {
              TeacherTourGuide.startNow(
                context,
                screenId: 'teacher_home',
                hints: [
                  const TeacherTourHint(
                    title: 'Teacher dashboard',
                    line:
                        'This screen is your operational center for classes, mail, reminders, and daily actions.',
                    highlightShape: AppTourHighlightShape.fullscreen,
                  ),
                  TeacherTourHint(
                    title: 'Open menu',
                    line:
                        'Use this button to open all teacher tools and navigation links.',
                    targetKey: _menuButtonKey,
                    highlightShape: AppTourHighlightShape.circle,
                  ),
                  TeacherTourHint(
                    title: 'Guide',
                    line:
                        'Tap here anytime to restart the guided tour for this screen.',
                    targetKey: _guideButtonKey,
                    highlightShape: AppTourHighlightShape.circle,
                  ),
                  TeacherTourHint(
                    title: 'Teacher summary',
                    line:
                        'This card shows your profile shortcut and quick access to your teaching schedule.',
                    targetKey: _heroCardKey,
                  ),
                  TeacherTourHint(
                    title: 'Inbox status',
                    line:
                        'This indicator shows unread mail and opens the teacher mailbox directly.',
                    targetKey: _inboxCardKey,
                  ),
                  TeacherTourHint(
                    title: 'Reminders status',
                    line:
                        'This card shows pending reminders and opens your reminders management screen.',
                    targetKey: _remindersCardKey,
                  ),
                  TeacherTourHint(
                    title: 'Overview panel',
                    line:
                        'This section summarizes classes, learners, and upcoming online sessions.',
                    targetKey: _overviewPanelKey,
                  ),
                  TeacherTourHint(
                    title: 'Classes shortcut',
                    line: 'Use this card to open your classes list quickly.',
                    targetKey: _classesCardKey,
                  ),
                  TeacherTourHint(
                    title: 'Next class',
                    line:
                        'This card highlights your next scheduled class and opens the schedule details.',
                    targetKey: _nextClassCardKey,
                  ),
                ],
              );
            },
          ),
          IconButton(
            tooltip: 'Theme',
            icon: Icon(Icons.palette_rounded, color: p.accent),
            onPressed: _openThemeSheet,
          ),
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
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
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
                    return KeyedSubtree(
                      key: _heroCardKey,
                      child: _HeroSummaryCard(
                        palette: p,
                        teacherName: name.isEmpty ? 'Teacher' : name,
                        onOpenProfile: () =>
                            _pushScreen(const TeacherProfileScreen()),
                        onOpenSchedule: () =>
                            _pushScreen(const TeacherSchedule()),
                      ),
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
                          return KeyedSubtree(
                            key: _inboxCardKey,
                            child: _MiniStatCard(
                              palette: p,
                              label: 'Inbox',
                              value: unread == 0 ? 'Clear' : '$unread unread',
                              icon: Icons.email_rounded,
                              badgeCount: unread,
                              badgeColor: Colors.red,
                              onTap: () =>
                                  _pushScreen(const TeacherMailScreen()),
                            ),
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
                          return KeyedSubtree(
                            key: _remindersCardKey,
                            child: _MiniStatCard(
                              palette: p,
                              label: 'Reminders',
                              value: pending == 0 ? 'None' : '$pending pending',
                              icon: Icons.alarm_rounded,
                              badgeCount: pending,
                              badgeColor: p.accent,
                              onTap: () =>
                                  _pushScreen(const TeacherReminderScreen()),
                            ),
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
                    final s =
                        classSnap.data ??
                        const _ClassesSummary(
                          classesCount: 0,
                          learnersCount: 0,
                        );

                    return FutureBuilder<int>(
                      future: _upcomingOnlineCountFuture,
                      builder: (context, onlineSnap) {
                        final upcoming = onlineSnap.data ?? 0;

                        return KeyedSubtree(
                          key: _overviewPanelKey,
                          child: _OverviewPanel(
                            palette: p,
                            classesCount: s.classesCount,
                            learnersCount: s.learnersCount,
                            upcomingOnlineCount: upcoming,
                          ),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 14),
                KeyedSubtree(
                  key: _classesCardKey,
                  child: _SingleDashboardActionCard(
                    palette: p,
                    icon: Icons.school_rounded,
                    title: 'My Classes',
                    subtitle: 'Open your classes',
                    onTap: () => _pushScreen(const TeacherClassesScreen()),
                  ),
                ),
                const SizedBox(height: 12),
                FutureBuilder<_HomeUpcomingClass?>(
                  future: _nextUpcomingClassFuture,
                  builder: (context, snap) {
                    return KeyedSubtree(
                      key: _nextClassCardKey,
                      child: _NextComingClassCard(
                        palette: p,
                        upcomingClass: snap.data,
                        onTap: () => _pushScreen(const TeacherSchedule()),
                      ),
                    );
                  },
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

class _HomeUpcomingClass {
  const _HomeUpcomingClass({
    required this.classId,
    required this.courseCode,
    required this.courseTitle,
    required this.start,
    required this.end,
  });

  final String classId;
  final String courseCode;
  final String courseTitle;
  final DateTime start;
  final DateTime end;
}

class _TeacherDrawer extends StatelessWidget {
  const _TeacherDrawer({
    required this.palette,
    required this.onOpenProfile,
    required this.onOpenSchedule,
    required this.onOpenClasses,
    required this.onOpenGallery,
    required this.onOpenOnlineBooking,
    required this.onOpenOnlineCircle,
    required this.onOpenMail,
    required this.onOpenReminders,
    required this.onOpenWages,
    required this.onOpenRegulations,
    required this.onOpenSyllabi,
    required this.onOpenThemeSettings,
    required this.onRestartTour,
    required this.onOpenShared,
    required this.onLogout,
    required this.onOpenGames,
    required this.onOpenStories,
  });

  final _HomePalette palette;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenSchedule;
  final VoidCallback onOpenClasses;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenOnlineBooking;
  final VoidCallback onOpenOnlineCircle;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenReminders;
  final VoidCallback onOpenWages;
  final VoidCallback onOpenRegulations;
  final VoidCallback onOpenSyllabi;
  final VoidCallback onOpenThemeSettings;
  final VoidCallback onRestartTour;
  final VoidCallback onOpenShared;
  final VoidCallback onOpenGames;
  final VoidCallback onOpenStories;
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
                    icon: Icons.collections_rounded,
                    title: 'Gallery',
                    subtitle: 'My learners and teachers',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenGallery();
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
                    icon: Icons.menu_book_rounded,
                    title: 'Stories',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenStories();
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
                    icon: Icons.video_call_rounded,
                    title: 'Online Circle',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenOnlineCircle();
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
                    icon: Icons.folder_shared_rounded,
                    title: 'Shared',
                    subtitle: 'Shared files between teachers',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenShared();
                    },
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.tour_rounded,
                    title: 'Restart Guide',
                    subtitle: 'Show onboarding steps again',
                    onTap: () {
                      Navigator.of(context).pop();
                      onRestartTour();
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
              border: Border.all(color: palette.border.withValues(alpha: 0.85)),
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
                            color: palette.text.withValues(alpha: 0.55),
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
                  color: palette.text.withValues(alpha: 0.45),
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
          colors: [palette.primary, palette.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Peace Be Upon You',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.80),
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
                style: TextStyle(color: textColor, fontWeight: FontWeight.w900),
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
  });

  final _HomePalette palette;
  final int classesCount;
  final int learnersCount;
  final int upcomingOnlineCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.border.withValues(alpha: 0.75)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
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
          Row(
            children: [
              Expanded(
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Classes',
                  value: '$classesCount',
                  icon: Icons.school_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Learners',
                  value: '$learnersCount',
                  icon: Icons.groups_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _OverviewStatBox(
                  palette: palette,
                  label: 'Online',
                  value: '$upcomingOnlineCount',
                  icon: Icons.videocam_rounded,
                  badgeCount: upcomingOnlineCount,
                  badgeColor: Colors.red,
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
    this.badgeCount = 0,
    this.badgeColor,
  });

  final _HomePalette palette;
  final String label;
  final String value;
  final IconData icon;
  final int badgeCount;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: palette.soft.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            children: [
              Icon(icon, color: palette.primary, size: 20),
              const SizedBox(height: 7),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          if (badgeCount > 0)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
    );
  }
}

class _SingleDashboardActionCard extends StatelessWidget {
  const _SingleDashboardActionCard({
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
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.border.withValues(alpha: 0.8)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: palette.soft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: palette.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text.withValues(alpha: 0.60),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: palette.text.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NextComingClassCard extends StatelessWidget {
  const _NextComingClassCard({
    required this.palette,
    required this.upcomingClass,
    required this.onTap,
  });

  final _HomePalette palette;
  final _HomeUpcomingClass? upcomingClass;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = upcomingClass;

    return Material(
      color: palette.cardBg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.border.withValues(alpha: 0.8)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: c == null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Next Coming Class',
                      style: TextStyle(
                        color: palette.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No upcoming classes found.',
                      style: TextStyle(
                        color: palette.text.withValues(alpha: 0.70),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Next Coming Class',
                      style: TextStyle(
                        color: palette.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: palette.soft,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.access_time_rounded,
                            color: palette.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.courseTitle.isNotEmpty
                                    ? c.courseTitle
                                    : 'Untitled Class',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.primary,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                c.courseCode.isNotEmpty
                                    ? c.courseCode
                                    : 'No course code',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.text.withValues(alpha: 0.65),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _InfoChip(
                          palette: palette,
                          icon: Icons.calendar_today_rounded,
                          text: DateFormat('EEE, MMM d').format(c.start),
                        ),
                        _InfoChip(
                          palette: palette,
                          icon: Icons.schedule_rounded,
                          text:
                              '${DateFormat('hh:mm a').format(c.start)} - ${DateFormat('hh:mm a').format(c.end)}',
                        ),
                        _InfoChip(
                          palette: palette,
                          icon: Icons.badge_rounded,
                          text: 'ID: ${c.classId}',
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

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.palette,
    required this.icon,
    required this.text,
  });

  final _HomePalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: palette.soft.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: palette.primary),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: palette.primary,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
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
        border: Border.all(color: palette.border.withValues(alpha: 0.65)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
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
                    color: palette.primary.withValues(alpha: 0.7),
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
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: selected ? preview1 : Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
