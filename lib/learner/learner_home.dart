import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:url_launcher/url_launcher.dart';
import 'learner_gallery_screen.dart';
import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/session_manager.dart';
import '../shared/watermark_background.dart';
import 'learner_stories_screen.dart';
import 'learner_study_coach_screen.dart';
import 'learner_regulations_screen.dart';
import 'learner_mail_screen.dart';
import 'learner_homework_screen.dart' as hw;
import 'learner_courses_screen.dart';
import 'learner_games_screen.dart';
import 'learner_profile_screen.dart';
import 'learner_reminders_list_screen.dart';
import 'learner_booking_screen.dart';
import '../shared/app_feedback.dart';
import '../shared/offline_action_guard.dart';
import '../shared/offline_notice_banner.dart';
import '../shared/first_login_agreement.dart';
import '../shared/learner_web_layout.dart';
import '../shared/responsive_layout.dart';
import '../shared/course_join_rules.dart';
import '../shared/payment_status.dart';
import '../shared/window_access_dialogs.dart';
import '../services/notification_counter_service.dart';
import '../services/window_access_service.dart';

class LearnerHome extends StatefulWidget {
  const LearnerHome({super.key});

  @override
  State<LearnerHome> createState() => _LearnerHomeState();
}

class _LearnerHomeState extends State<LearnerHome> {
  int _lastBackPressMs = 0;
  int _shellRefreshEpoch = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _menuIconKey = GlobalKey();
  final GlobalKey _drawerCoursesKey = GlobalKey();
  final GlobalKey _drawerGalleryKey = GlobalKey();
  final GlobalKey _drawerGamesKey = GlobalKey();
  final GlobalKey _drawerCoachKey = GlobalKey();
  final GlobalKey _drawerStoriesKey = GlobalKey();
  final GlobalKey _drawerProfileKey = GlobalKey();
  final GlobalKey _drawerMailKey = GlobalKey();
  final GlobalKey _drawerRegulationsKey = GlobalKey();
  final GlobalKey _drawerThemeKey = GlobalKey();
  final GlobalKey _drawerLogoutKey = GlobalKey();
  final GlobalKey _dashboardHomeworkCardKey = GlobalKey();
  final GlobalKey _dashboardBookingCardKey = GlobalKey();
  final GlobalKey _dashboardCoursesListKey = GlobalKey();

  bool _paymentDueToastChecked = false;
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Future<String>? _displayNameFuture;
  Future<String>? _profilePhotoFuture;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _displayNameFuture = _myDisplayName();
    _profilePhotoFuture = _myProfilePhoto();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FirstLoginAgreement.ensureAccepted(context, roleKey: 'learner');
      unawaited(_showPaymentDueToastOnLoginIfNeeded());
    });
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

  String _variantKeyOfCourse(Map<String, dynamic> course) {
    final raw = (course['variantKey'] ?? course['variant'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    switch (raw) {
      case 'in_class':
      case 'inclass':
      case 'in-class':
      case 'in class':
        return 'inclass';
      case 'online':
      case 'flexible':
        return 'flexible';
      case 'live':
      case 'private':
        return 'private';
      case 'recorded':
        return 'recorded';
      default:
        return raw;
    }
  }

  int _sessionsDoneForPaymentCourse({
    required Map<String, dynamic> course,
    required String variantKey,
  }) {
    final attendance = course['attendance'];
    switch (variantKey) {
      case 'inclass':
        return countHeldUniqueAttendanceDates(attendance);
      case 'private':
        return countPresentUniqueAttendanceDates(attendance);
      case 'flexible':
        final directOnline = countPresentOnlineAttendance(
          course['online_attendance'],
        );
        if (directOnline > 0) return directOnline;

        final bookingProgress = course['booking_progress'];
        if (bookingProgress is Map) {
          final bp = bookingProgress.map((k, v) => MapEntry(k.toString(), v));
          final nestedOnline = countPresentOnlineAttendance(
            bp['online_attendance'],
          );
          if (nestedOnline > 0) return nestedOnline;
        }

        return countPresentUniqueAttendanceDates(attendance);
      default:
        return countPresentUniqueAttendanceDates(attendance);
    }
  }

  bool _isCoursePaymentNeeded(Map<String, dynamic> course) {
    final variantKey = _variantKeyOfCourse(course);
    if (variantKey == 'recorded') return false;

    final summaryRaw = course['payment_summary'];
    final summary = summaryRaw is Map
        ? summaryRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final sessionsPaidTotalRaw = paymentAsInt(summary['sessionsPaidTotal']);
    final totalPaid = paymentAsInt(summary['totalPaid']);
    final lastAmount = paymentAsInt(summary['lastAmount']);
    final lastPaymentAt = paymentAsInt(summary['lastPaymentAt']);
    final hasPaymentHistory =
        totalPaid > 0 || lastAmount > 0 || lastPaymentAt > 0;

    final sessionsPaidTotal = sessionsPaidTotalRaw > 0
        ? sessionsPaidTotalRaw
        : (hasPaymentHistory &&
                  (variantKey == 'private' || variantKey == 'inclass')
              ? 8
              : 0);

    if (sessionsPaidTotal <= 0) return false;

    final sessionsDone = _sessionsDoneForPaymentCourse(
      course: course,
      variantKey: variantKey,
    );

    return isPaymentDueBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
    );
  }

  Future<void> _showPaymentDueToastOnLoginIfNeeded() async {
    if (_paymentDueToastChecked) return;
    _paymentDueToastChecked = true;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;

    try {
      final snap = await _db.child('users').child(uid).child('courses').get();
      if (!snap.exists || snap.value is! Map) return;

      final courses = (snap.value as Map).entries
          .map((e) => e.value)
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();

      final hasDue = courses.any(_isCoursePaymentNeeded);
      if (!hasDue || !mounted) return;

      AppToast.show(
        context,
        'تنبيه لطيف: يوجد دفع مستحق في إحدى دوراتك. يرجى التواصل مع Your Bridge School 💛\n'
        'Friendly reminder: a payment is due for one of your courses. Please contact Your Bridge School 💛',
        type: AppToastType.info,
        duration: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  void _pushScreen(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _openLearnerWindow(String windowKey, VoidCallback onAllowed) {
    unawaited(
      OfflineActionGuard.run(context, () {
        return WindowAccessService.instance.guardOpen(
          context: context,
          role: AppWindowRole.learner,
          windowKey: windowKey,
          onAllowed: onAllowed,
        );
      }),
    );
  }

  void _openProfileScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerProfile,
      () => _pushScreen(const LearnerProfileScreen()),
    );
  }

  void _openMailScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerMail,
      () => _pushScreen(LearnerMailScreen()),
    );
  }

  void _openCoursesWindow({String? courseKey}) {
    _openLearnerWindow(
      AppWindowKeys.learnerCourses,
      () => _pushScreen(LearnerCoursesScreen(initialCourseKey: courseKey)),
    );
  }

  void _openGalleryScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerGallery,
      () => _pushScreen(const LearnerGalleryScreen()),
    );
  }

  void _openGamesScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerGames,
      () => _pushScreen(const LearnerGamesScreen()),
    );
  }

  void _openStudyCoachScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerStudyCoach,
      () => _pushScreen(const LearnerStudyCoachScreen()),
    );
  }

  void _openBookingScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerBooking,
      () => _pushScreen(const LearnerBookingScreen()),
    );
  }

  void _openRemindersScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerReminders,
      () => _pushScreen(const LearnerRemindersListScreen()),
    );
  }

  void _openRegulationsScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerRegulations,
      () => _pushScreen(const LearnerRegulationsScreen()),
    );
  }

  void _openStoriesScreen() {
    _openLearnerWindow(
      AppWindowKeys.learnerStories,
      () => _pushScreen(const LearnerStoriesScreen()),
    );
  }

  Future<void> _refreshShell() async {
    if (!OfflineActionGuard.ensureOnline(context)) return;
    setState(() {
      _displayNameFuture = _myDisplayName();
      _profilePhotoFuture = _myProfilePhoto();
      _shellRefreshEpoch++;
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _logout(BuildContext context) async {
    await AppLoading.run(
      context,
      () async {
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

        try {
          await appThemeController.resetToDefault();
        } catch (_) {}

        await FirebaseAuth.instance.signOut();
      },
      message: 'Logging out...',
      isLogout: true,
    );
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

  Future<String> _myProfilePhoto() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return '';

    try {
      final snap = await _db.child('users/$uid').get();
      final v = snap.value;
      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        return (m['profile_photo'] ?? '').toString().trim();
      }
    } catch (_) {}

    return '';
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
                separatorBuilder: (_, _) => const SizedBox(height: 10),
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

  void _openThemeSettings() {
    _openLearnerWindow(AppWindowKeys.learnerThemeSettings, _openThemeSheet);
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final isWebDashboard = AppResponsive.isWebDesktop(context, minWidth: 1100);
    final webDesktop = isLearnerWebDesktop(context, minWidth: 1280);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastBackPressMs < 1800) {
          await SystemNavigator.pop();
          return;
        }
        _lastBackPressMs = now;
        AppToast.show(context, 'Press back again to close app');
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: p.appBg,
        drawer: webDesktop
            ? null
            : _LearnerDrawer(
                palette: p,
                displayNameFuture: _displayNameFuture,
                profilePhotoFuture: _profilePhotoFuture,
                coursesTileKey: _drawerCoursesKey,
                galleryTileKey: _drawerGalleryKey,
                gamesTileKey: _drawerGamesKey,
                coachTileKey: _drawerCoachKey,
                storiesTileKey: _drawerStoriesKey,
                profileTileKey: _drawerProfileKey,
                mailTileKey: _drawerMailKey,
                regulationsTileKey: _drawerRegulationsKey,
                themeTileKey: _drawerThemeKey,
                logoutButtonKey: _drawerLogoutKey,
                onOpenProfile: _openProfileScreen,
                onOpenMail: _openMailScreen,
                onOpenCourses: _openCoursesWindow,
                onOpenGallery: _openGalleryScreen,
                onOpenStories: _openStoriesScreen,
                onOpenGames: _openGamesScreen,
                onOpenStudyCoach: _openStudyCoachScreen,
                onOpenRegulations: _openRegulationsScreen,
                onOpenThemeSettings: _openThemeSettings,
                onLogout: () => _logout(context),
              ),

        appBar: AppBar(
          toolbarHeight: isWebDashboard ? 74 : kToolbarHeight,
          backgroundColor: p.cardBg,
          elevation: 0,
          centerTitle: false,
          surfaceTintColor: p.cardBg,
          leading: webDesktop
              ? null
              : IconButton(
                  icon: Icon(
                    Icons.menu_rounded,
                    key: _menuIconKey,
                    color: p.primary,
                  ),
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
                      fontSize: isWebDashboard ? 18 : 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name.isNotEmpty ? name : 'Learner',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                      fontSize: isWebDashboard ? 13 : 12,
                    ),
                  ),
                ],
              );
            },
          ),
          actions: [
            if (webDesktop)
              IconButton(
                tooltip: 'Theme',
                icon: Icon(Icons.palette_outlined, color: p.primary),
                onPressed: _openThemeSettings,
              ),
            IconButton(
              tooltip: 'Logout',
              icon: Icon(Icons.logout_rounded, color: p.accent),
              onPressed: () => _logout(context),
            ),
          ],
        ),
        body: learnerWebBodyFrame(
          context: context,
          maxWidth: 1760,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (webDesktop)
                _LearnerHomeWebRail(
                  palette: p,
                  onOpenCourses: _openCoursesWindow,
                  onOpenBooking: _openBookingScreen,
                  onOpenMail: _openMailScreen,
                  onOpenReminders: _openRemindersScreen,
                  onOpenHomework: _openCoursesWindow,
                  onOpenGallery: _openGalleryScreen,
                  onOpenStories: _openStoriesScreen,
                  onOpenGames: _openGamesScreen,
                  onOpenCoach: _openStudyCoachScreen,
                  onOpenProfile: _openProfileScreen,
                  onLogout: () => _logout(context),
                ),
              if (webDesktop) const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: [
                    const OfflineNoticeBanner(),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _refreshShell,
                        child: WatermarkBackground(
                          child: _LearnerDashboardLite(
                            key: ValueKey('learner_dash_$_shellRefreshEpoch'),
                            homeworkCardKey: _dashboardHomeworkCardKey,
                            bookingCardKey: _dashboardBookingCardKey,
                            coursesListKey: _dashboardCoursesListKey,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (webDesktop) const SizedBox(width: 14),
              if (webDesktop)
                _LearnerHomeWebAside(
                  palette: p,
                  onOpenCourses: _openCoursesWindow,
                  onOpenBooking: _openBookingScreen,
                  onOpenMail: _openMailScreen,
                  onOpenReminders: _openRemindersScreen,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LearnerDashboardLite extends StatefulWidget {
  const _LearnerDashboardLite({
    super.key,
    required this.homeworkCardKey,
    required this.bookingCardKey,
    required this.coursesListKey,
  });

  final GlobalKey homeworkCardKey;
  final GlobalKey bookingCardKey;
  final GlobalKey coursesListKey;

  @override
  State<_LearnerDashboardLite> createState() => _LearnerDashboardLiteState();
}

class _LearnerDashboardLiteState extends State<_LearnerDashboardLite> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  Future<List<_CourseProgressItem>>? _progressFuture;
  Future<_JoinFabPayload?>? _joinFabFuture;
  Timer? _progressRefreshTimer;
  Timer? _joinFabRefreshTimer;

  @override
  void initState() {
    super.initState();
    _progressFuture = _loadProgressItems();
    _joinFabFuture = _findJoinFabPayload();
    _progressRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted) return;
      setState(() {
        _progressFuture = _loadProgressItems();
      });
    });
    _joinFabRefreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) return;
      setState(() {
        _joinFabFuture = _findJoinFabPayload();
      });
    });
  }

  @override
  void dispose() {
    _progressRefreshTimer?.cancel();
    _joinFabRefreshTimer?.cancel();
    super.dispose();
  }

  String _joinTwo(int n) => n < 10 ? '0$n' : '$n';

  String _joinDateKey(DateTime d) =>
      '${d.year}-${_joinTwo(d.month)}-${_joinTwo(d.day)}';

  DateTime? _joinParseSlotStart(String dayKey, String hhmm) {
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

  int _joinWeekdayFromShort(String day) {
    switch (day.trim().toLowerCase()) {
      case 'mon':
      case 'monday':
        return DateTime.monday;
      case 'tue':
      case 'tues':
      case 'tuesday':
        return DateTime.tuesday;
      case 'wed':
      case 'wednesday':
        return DateTime.wednesday;
      case 'thu':
      case 'thur':
      case 'thurs':
      case 'thursday':
        return DateTime.thursday;
      case 'fri':
      case 'friday':
        return DateTime.friday;
      case 'sat':
      case 'saturday':
        return DateTime.saturday;
      case 'sun':
      case 'sunday':
        return DateTime.sunday;
      default:
        return 0;
    }
  }

  DateTime? _joinParseYmd(String ymd) {
    final p = ymd.trim().split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  String _joinReadFirstNonEmptyMap(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = (m[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  DateTime? _joinNextPrivateSessionStart({
    required Map<String, dynamic> schedule,
    required DateTime now,
  }) {
    final firstDate = _joinParseYmd(
      (schedule['first_session_date'] ?? '').toString(),
    );
    if (firstDate == null) return null;

    final sessions = schedule['sessions'];
    final sessionNodes = <Map<String, dynamic>>[];
    if (sessions is List) {
      for (final it in sessions) {
        if (it is! Map) continue;
        sessionNodes.add(it.map((k, v) => MapEntry(k.toString(), v)));
      }
    } else if (sessions is Map) {
      for (final it in sessions.values) {
        if (it is! Map) continue;
        sessionNodes.add(it.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    if (sessionNodes.isEmpty) return null;

    DateTime? best;
    final firstDay = DateTime(firstDate.year, firstDate.month, firstDate.day);

    for (int i = 0; i <= 7; i++) {
      final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      if (day.isBefore(firstDay)) continue;

      for (final s in sessionNodes) {
        final weekday = _joinWeekdayFromShort((s['day'] ?? '').toString());
        if (weekday <= 0 || weekday != day.weekday) continue;

        final startTime = (s['start_time'] ?? '').toString().trim();
        final hm = startTime.split(':');
        if (hm.length != 2) continue;
        final h = int.tryParse(hm[0]);
        final m = int.tryParse(hm[1]);
        if (h == null || m == null) continue;

        final start = DateTime(day.year, day.month, day.day, h, m);
        final duration = _toInt(s['duration_min']);
        final safeDuration = duration > 0 ? duration : 60;
        final end = start.add(Duration(minutes: safeDuration));
        if (end.isBefore(now)) continue;

        if (best == null || start.isBefore(best)) {
          best = start;
        }
      }
    }

    return best;
  }

  Future<List<Map<String, dynamic>>> _loadJoinFabCourses() async {
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

      final classMap = (m['class'] is Map)
          ? Map<String, dynamic>.from(m['class'] as Map)
          : <String, dynamic>{};

      final variantKey = resolveCourseDeliveryKey(m);
      final isFlexible = variantKey == 'flexible';
      final isPrivateOnline = isPrivateOnlineCourse(m);
      if (!isFlexible && !isPrivateOnline) continue;

      final classId = (classMap['class_id'] ?? '').toString().trim();
      temp.add({
        'courseId': courseId,
        'classId': classId,
        'variantKey': variantKey,
        'title': (m['title'] ?? m['course_title'] ?? 'Course').toString(),
      });
    }

    return temp;
  }

  String _joinBookingKey(String courseId, String dayKey, String hhmm) =>
      '$courseId|$dayKey|$hhmm';

  Future<Set<String>> _loadAttendedBookingKeys({
    required String uid,
    required String courseId,
  }) async {
    final out = <String>{};
    try {
      final snap = await _db
          .child('booking_progress/$uid/$courseId/online_attendance')
          .get();
      if (snap.exists && snap.value is Map) {
        final m = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final k in m.keys) {
          out.add(k.toString());
        }
      }
    } catch (_) {}
    return out;
  }

  Future<String> _loadFlexibleMeetUrl({
    required String teacherId,
    required String courseId,
  }) async {
    if (teacherId.trim().isEmpty || courseId.trim().isEmpty) return '';
    try {
      final snap = await _db
          .child('booking_availability/$teacherId/$courseId')
          .get();
      final v = snap.value;
      if (v is Map) {
        final m = Map<String, dynamic>.from(v);
        final meetUrl =
            (m['meetUrl'] ??
                    m['meet_url'] ??
                    m['googleMeetUrl'] ??
                    m['google_meet_url'] ??
                    '')
                .toString()
                .trim();
        if (meetUrl.isNotEmpty) return meetUrl;
      }

      final fallback = await _db
          .child('users/$teacherId/google_meet_url')
          .get();
      return (fallback.value ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  Future<String> _loadPrivateMeetUrl({required String teacherId}) async {
    if (teacherId.trim().isEmpty) return '';
    try {
      final snap = await _db.child('users/$teacherId/google_meet_url').get();
      return (snap.value ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  Future<_JoinFabPayload?> _findJoinFabPayload() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return null;

    final courses = await _loadJoinFabCourses();
    if (courses.isEmpty) return null;

    final now = DateTime.now();
    _JoinFabPayload? best;

    final attendedCache = <String, Set<String>>{};

    for (final c in courses) {
      final variantKey = (c['variantKey'] ?? '').toString();
      final cid = (c['courseId'] ?? '').toString().trim();
      if (cid.isEmpty) continue;

      if (variantKey == 'private') {
        final classId = (c['classId'] ?? '').toString().trim();
        if (classId.isEmpty) continue;

        Map<String, dynamic> classNode = <String, dynamic>{};
        try {
          final classSnap = await _db.child('classes/$classId').get();
          final cv = classSnap.value;
          if (cv is Map) {
            classNode = cv.map((k, v) => MapEntry(k.toString(), v));
          }
        } catch (_) {}

        final scheduleRaw = classNode['schedule'];
        if (scheduleRaw is! Map) continue;
        final schedule = scheduleRaw.map((k, v) => MapEntry(k.toString(), v));

        final nextStart = _joinNextPrivateSessionStart(
          schedule: schedule,
          now: now,
        );
        if (nextStart == null || !canJoinFromStart(nextStart)) continue;

        final teacherId =
            _joinReadFirstNonEmptyMap(classNode, [
              'teacherUid',
              'teacher_uid',
              'teacherId',
              'teacher_id',
              'instructorUid',
            ]).isNotEmpty
            ? _joinReadFirstNonEmptyMap(classNode, [
                'teacherUid',
                'teacher_uid',
                'teacherId',
                'teacher_id',
                'instructorUid',
              ])
            : ((classNode['instructor_current'] is Map)
                  ? _joinReadFirstNonEmptyMap(
                      Map<String, dynamic>.from(
                        classNode['instructor_current'] as Map,
                      ),
                      const ['uid'],
                    )
                  : '');
        if (teacherId.isEmpty) continue;

        final meetUrl = await _loadPrivateMeetUrl(teacherId: teacherId);
        if (meetUrl.isEmpty) continue;

        final payload = _JoinFabPayload(
          meetUrl: meetUrl,
          start: nextStart,
          source: 'private_online',
        );

        final bestNow = best;
        if (bestNow == null || payload.start.isBefore(bestNow.start)) {
          best = payload;
        }
        continue;
      }

      final dk = _joinDateKey(now);
      final snap = await _db.child('booking_reservations/$cid/$dk').get();
      final v = snap.value;
      if (v is! Map) continue;
      final m = Map<dynamic, dynamic>.from(v);

      final attended =
          attendedCache[cid] ??
          await _loadAttendedBookingKeys(uid: uid, courseId: cid);
      attendedCache[cid] = attended;

      for (final e in m.entries) {
        final hhmm = e.key.toString();
        final node = e.value;
        if (node is! Map) continue;

        final start = _joinParseSlotStart(dk, hhmm);
        if (start == null || !canJoinFromStart(start)) continue;

        final sm = Map<dynamic, dynamic>.from(node);

        Future<void> considerCandidate(
          Map<dynamic, dynamic> slotLike,
          String teacherKey,
        ) async {
          final learners = slotLike['learners'];
          if (learners is! Map) return;

          final lm = Map<dynamic, dynamic>.from(learners);
          if (!lm.containsKey(uid)) return;

          final bookingKey = _joinBookingKey(cid, dk, hhmm);
          if (attended.contains(bookingKey)) return;

          final teacherId = (slotLike['teacherId'] ?? teacherKey)
              .toString()
              .trim();
          if (teacherId.isEmpty) return;

          final meetUrl = await _loadFlexibleMeetUrl(
            teacherId: teacherId,
            courseId: cid,
          );
          if (meetUrl.isEmpty) return;

          final payload = _JoinFabPayload(
            meetUrl: meetUrl,
            start: start,
            source: 'flexible',
          );

          final bestNow = best;
          if (bestNow == null || payload.start.isBefore(bestNow.start)) {
            best = payload;
          }
        }

        if (sm['learners'] is Map) {
          await considerCandidate(sm, '');
          continue;
        }

        for (final te in sm.entries) {
          final teacherKey = te.key.toString();
          final teacherNode = te.value;
          if (teacherNode is! Map) continue;
          await considerCandidate(
            Map<dynamic, dynamic>.from(teacherNode),
            teacherKey,
          );
        }
      }
    }

    return best;
  }

  Future<void> _openJoinFabUrl(String url) async {
    var u = url.trim();
    if (u.isEmpty) return;

    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }

    final uri = Uri.tryParse(u);
    if (uri == null) {
      if (!mounted || !context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Invalid meeting link.')),
      );
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted && context.mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
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
    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};
    final studyMode =
        (course['studyMode'] ?? cls['study_mode'] ?? cls['studyMode'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

    if (variant == 'recorded') return 'Recorded course';
    if (variant == 'flexible' || variant == 'online') {
      return 'Flexible course (Flexible)';
    }
    if (variant == 'private' || variant == 'live') {
      if (studyMode == 'online') return 'Private course (Online)';
      if (studyMode == 'inclass' ||
          studyMode == 'in_class' ||
          studyMode == 'in-class' ||
          studyMode == 'in class') {
        return 'Private course (In-Class)';
      }
      return 'Private course (Private)';
    }
    if (variant == 'inclass' ||
        variant == 'in_class' ||
        variant == 'in-class' ||
        variant == 'in class') {
      return 'In-class course';
    }

    if (variant.isNotEmpty) {
      return '${variant[0].toUpperCase()}${variant.substring(1)} course';
    }

    final classType = (cls['type'] ?? cls['class_type'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    if (classType.isNotEmpty) {
      return '${classType[0].toUpperCase()}${classType.substring(1)} course';
    }

    return 'Course details';
  }

  String _courseDetailsLine(Map<String, dynamic> course) {
    final variant = (course['variantKey'] ?? course['variant'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    if (variant == 'recorded') {
      final recordedAccess = (course['recorded_access'] is Map)
          ? Map<String, dynamic>.from(course['recorded_access'] as Map)
          : <String, dynamic>{};

      int asInt(dynamic v) {
        if (v == null) return 0;
        if (v is int) return v;
        if (v is num) return v.toInt();
        return int.tryParse(v.toString()) ?? 0;
      }

      String formatDateMs(int ms) {
        if (ms <= 0) return '';
        final d = DateTime.fromMillisecondsSinceEpoch(ms);
        String two(int n) => n.toString().padLeft(2, '0');
        return '${d.year}-${two(d.month)}-${two(d.day)}';
      }

      final expiresAt = asInt(recordedAccess['expiresAt']);
      final durationMonths = asInt(recordedAccess['durationMonths']);
      final code = (course['course_code'] ?? '').toString().trim();

      final parts = <String>[];

      if (durationMonths > 0) {
        parts.add(
          '$durationMonths month${durationMonths == 1 ? '' : 's'} access',
        );
      }

      if (expiresAt > 0) {
        parts.add('Expires ${formatDateMs(expiresAt)}');
      }

      if (code.isNotEmpty) {
        parts.add('Code $code');
      }

      if (parts.isEmpty) return 'Tap to open recorded course';
      return parts.join(' • ');
    }

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    final teacherName =
        (cls['teacher_name'] ??
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
    final courseId = (cls['course_id'] ?? course['id'] ?? '').toString().trim();
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
          final modules = s['modules'];
          if (modules is List) {
            for (final m in modules) {
              if (m is! Map) continue;
              final module = Map<String, dynamic>.from(m);
              final units = module['units'];
              if (units is! List) continue;
              for (final u in units) {
                if (u is! Map) continue;
                final unit = Map<String, dynamic>.from(u);
                final lessons = unit['lessons'];
                if (lessons is List) {
                  totalLessons += lessons.length;
                }
              }
            }
          } else {
            final units = s['units'];

            if (units is List) {
              for (final u in units) {
                if (u is! Map) continue;
                final unit = Map<String, dynamic>.from(u);
                final sessions = unit['sessions'];
                if (sessions is List) {
                  totalLessons += sessions.length;
                }
              }
            } else if (units is Map) {
              final mapUnits = Map<dynamic, dynamic>.from(units);
              for (final entry in mapUnits.entries) {
                final unitVal = entry.value;
                if (unitVal is! Map) continue;
                final unit = Map<String, dynamic>.from(unitVal);
                final sessions = unit['sessions'];
                if (sessions is List) {
                  totalLessons += sessions.length;
                } else if (sessions is Map) {
                  totalLessons += Map<dynamic, dynamic>.from(sessions).length;
                }
              }
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

  String _weeklyScheduleLine(dynamic sessionsRaw) {
    final nodes = <Map<String, dynamic>>[];
    if (sessionsRaw is List) {
      for (final s in sessionsRaw) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    } else if (sessionsRaw is Map) {
      for (final s in sessionsRaw.values) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    if (nodes.isEmpty) return 'Schedule: not set';

    String normDay(String raw) {
      final d = raw.trim();
      if (d.length <= 3) return d;
      return d.substring(0, 3);
    }

    final parts = nodes
        .map((n) {
          final day = normDay((n['day'] ?? '').toString());
          final start = (n['start_time'] ?? '').toString().trim();
          if (day.isEmpty && start.isEmpty) return '';
          if (day.isEmpty) return start;
          if (start.isEmpty) return day;
          return '$day $start';
        })
        .where((e) => e.trim().isNotEmpty)
        .toList();

    if (parts.isEmpty) return 'Schedule: not set';
    return 'Schedule: ${parts.join(' • ')}';
  }

  ({DateTime start, int durationMinutes})? _nextOccurrenceFromSchedule(
    Map<String, dynamic> schedule,
  ) {
    final firstSessionDate = (schedule['first_session_date'] ?? '')
        .toString()
        .trim();
    final firstDate = DateTime.tryParse(firstSessionDate);
    if (firstDate == null) return null;

    final sessionsRaw = schedule['sessions'];
    final nodes = <Map<String, dynamic>>[];
    if (sessionsRaw is List) {
      for (final s in sessionsRaw) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    } else if (sessionsRaw is Map) {
      for (final s in sessionsRaw.values) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    if (nodes.isEmpty) return null;

    int weekday(String day) {
      switch (day.trim().toLowerCase()) {
        case 'mon':
        case 'monday':
          return DateTime.monday;
        case 'tue':
        case 'tues':
        case 'tuesday':
          return DateTime.tuesday;
        case 'wed':
        case 'wednesday':
          return DateTime.wednesday;
        case 'thu':
        case 'thur':
        case 'thurs':
        case 'thursday':
          return DateTime.thursday;
        case 'fri':
        case 'friday':
          return DateTime.friday;
        case 'sat':
        case 'saturday':
          return DateTime.saturday;
        case 'sun':
        case 'sunday':
          return DateTime.sunday;
      }
      return 0;
    }

    final now = DateTime.now();
    final firstDay = DateTime(firstDate.year, firstDate.month, firstDate.day);
    DateTime? bestStart;
    int bestDuration = 60;

    for (int i = 0; i <= 35; i++) {
      final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      if (day.isBefore(firstDay)) continue;

      for (final n in nodes) {
        final wd = weekday((n['day'] ?? '').toString());
        if (wd <= 0 || wd != day.weekday) continue;

        final startRaw = (n['start_time'] ?? '').toString().trim();
        final hm = startRaw.split(':');
        if (hm.length != 2) continue;
        final h = int.tryParse(hm[0]);
        final m = int.tryParse(hm[1]);
        if (h == null || m == null) continue;

        final start = DateTime(day.year, day.month, day.day, h, m);
        final duration = _toInt(n['duration_min']);
        final safeDuration = duration > 0 ? duration : 60;
        final end = start.add(Duration(minutes: safeDuration));
        if (end.isBefore(now)) continue;

        if (bestStart == null || start.isBefore(bestStart)) {
          bestStart = start;
          bestDuration = safeDuration;
        }
      }
    }

    if (bestStart == null) return null;
    return (start: bestStart, durationMinutes: bestDuration);
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
    final courseKey = (course['courseKey'] ?? '').toString().trim();

    final Map<int, String> sessionIdByNumber = {};

    if (variantKey == 'recorded') {
      if (courseId.isEmpty || courseKey.isEmpty || learnerUid.isEmpty) {
        return covered;
      }

      try {
        final syllabusSnap = await _db
            .child('syllabi/$courseId/recorded')
            .get();
        final Map<String, Map<String, dynamic>> sessionMetaById = {};

        List<Map<String, dynamic>> asListOfMaps(dynamic node) {
          final out = <Map<String, dynamic>>[];

          if (node is List) {
            for (final item in node) {
              if (item is Map) {
                out.add(Map<String, dynamic>.from(item));
              }
            }
            return out;
          }

          if (node is Map) {
            final map = Map<dynamic, dynamic>.from(node);
            for (final entry in map.entries) {
              if (entry.value is Map) {
                out.add(Map<String, dynamic>.from(entry.value as Map));
              }
            }
          }

          return out;
        }

        bool asBool(dynamic v) {
          if (v is bool) return v;
          final s = (v ?? '').toString().trim().toLowerCase();
          return s == 'true' || s == '1';
        }

        if (syllabusSnap.exists && syllabusSnap.value is Map) {
          final root = Map<String, dynamic>.from(syllabusSnap.value as Map);
          final rawModules = asListOfMaps(root['modules']);
          if (rawModules.isNotEmpty) {
            for (final module in rawModules) {
              final rawUnits = asListOfMaps(module['units']);
              for (final unit in rawUnits) {
                final rawLessons = asListOfMaps(unit['lessons']);
                for (final lesson in rawLessons) {
                  final sessionId = (lesson['id'] ?? '').toString().trim();
                  final videoUrl = (lesson['videoUrl'] ?? '').toString().trim();
                  final materialsUrl = (lesson['materialsUrl'] ?? '')
                      .toString()
                      .trim();
                  if (sessionId.isNotEmpty) {
                    sessionMetaById[sessionId] = {
                      'hasVideo': videoUrl.isNotEmpty,
                      'hasMaterials': materialsUrl.isNotEmpty,
                    };
                  }
                }
              }
            }
          } else {
            final rawUnits = asListOfMaps(root['units']);

            for (final unit in rawUnits) {
              final rawSessions = asListOfMaps(unit['sessions']);

              for (final session in rawSessions) {
                final sessionId = (session['id'] ?? '').toString().trim();
                final videoUrl = (session['videoUrl'] ?? '').toString().trim();
                final materialsUrl = (session['materialsUrl'] ?? '')
                    .toString()
                    .trim();

                if (sessionId.isNotEmpty) {
                  sessionMetaById[sessionId] = {
                    'hasVideo': videoUrl.isNotEmpty,
                    'hasMaterials': materialsUrl.isNotEmpty,
                  };
                }
              }
            }
          }
        }

        final progressSnap = await _db
            .child('users/$learnerUid/courses/$courseKey/recorded_progress')
            .get();

        if (progressSnap.exists && progressSnap.value is Map) {
          final rawProgress = Map<String, dynamic>.from(
            progressSnap.value as Map,
          );

          for (final entry in rawProgress.entries) {
            final sessionId = entry.key.toString().trim();
            final value = entry.value;
            if (sessionId.isEmpty || value is! Map) continue;

            final progress = Map<String, dynamic>.from(value);
            final meta =
                sessionMetaById[sessionId] ?? const <String, dynamic>{};

            final hasVideo = meta['hasVideo'] == true;
            final hasMaterials = meta['hasMaterials'] == true;

            final videoCompleted = asBool(progress['videoCompleted']);
            final materialsCompleted = asBool(progress['materialsCompleted']);

            bool isCompleted = false;

            if (hasVideo && hasMaterials) {
              isCompleted = videoCompleted || materialsCompleted;
            } else if (hasVideo) {
              isCompleted = videoCompleted;
            } else if (hasMaterials) {
              isCompleted = materialsCompleted;
            }

            if (isCompleted) {
              covered.add(sessionId);
            }
          }
        }
      } catch (_) {}

      return covered;
    }

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
            final type = (item['type'] ?? '').toString().trim().toLowerCase();
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
            .child('booking_progress/$learnerUid/$courseId/flexible_attendance')
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

                final type = (item['type'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
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
    if (learnerUid.isNotEmpty && courseId.isNotEmpty) {
      try {
        final snap = await _db
            .child('booking_progress/$learnerUid/$courseId/online_attendance')
            .get();

        if (snap.exists && snap.value is Map) {
          final m = Map<dynamic, dynamic>.from(snap.value as Map);

          for (final e in m.entries) {
            final rec = e.value;
            if (rec is! Map) continue;
            final r = Map<String, dynamic>.from(rec);

            // Only teacher-confirmed present records should count
            if (r['present'] != true) continue;

            final taughtItems = r['taughtItems'];
            if (taughtItems is List) {
              for (final it in taughtItems) {
                if (it is! Map) continue;
                final item = Map<String, dynamic>.from(it);

                final type = (item['type'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
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
        course['courseKey'] = key;
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
            : ((meta.plannedMeetings ?? 0) > 0
                  ? (meta.plannedMeetings ?? 0)
                  : 0);

        final completed = total > 0
            ? covered.length.clamp(0, total)
            : covered.length;

        final double progress = total > 0
            ? (completed / total).clamp(0.0, 1.0)
            : 0.0;

        final variantKey = resolveCourseDeliveryKey(course);
        final isPrivateOnline = isPrivateOnlineCourse(course);
        final isScheduledVariant =
            variantKey == 'private' || variantKey == 'inclass';

        String scheduleLine = variantKey == 'recorded'
            ? 'On-demand'
            : (variantKey == 'flexible'
                  ? 'Flexible booking'
                  : 'Schedule: not set');
        int nextStartMs = 0;
        int sessionDurationMinutes = 60;
        String meetUrl = '';
        Map<String, dynamic> classNode = <String, dynamic>{};
        final cls = (course['class'] is Map)
            ? Map<String, dynamic>.from(course['class'] as Map)
            : <String, dynamic>{};

        if (isScheduledVariant) {
          final classId = (cls['class_id'] ?? '').toString().trim();
          if (classId.isNotEmpty) {
            try {
              final cs = await _db.child('classes/$classId').get();
              if (cs.exists && cs.value is Map) {
                classNode = Map<String, dynamic>.from(cs.value as Map);
              }
            } catch (_) {}
          }

          final scheduleRaw = cls['schedule'] ?? classNode['schedule'];
          if (scheduleRaw is Map) {
            final schedule = scheduleRaw.map(
              (k, v) => MapEntry(k.toString(), v),
            );
            scheduleLine = _weeklyScheduleLine(schedule['sessions']);

            final next = _nextOccurrenceFromSchedule(schedule);
            if (next != null) {
              nextStartMs = next.start.millisecondsSinceEpoch;
              sessionDurationMinutes = next.durationMinutes;
            }
          }
        }

        if (isPrivateOnline) {
          String teacherUid =
              (classNode['teacherUid'] ??
                      classNode['teacher_uid'] ??
                      classNode['teacherId'] ??
                      classNode['teacher_id'] ??
                      cls['teacherUid'] ??
                      cls['teacherId'] ??
                      '')
                  .toString()
                  .trim();
          if (teacherUid.isEmpty && classNode['instructor_current'] is Map) {
            teacherUid =
                (Map<String, dynamic>.from(
                          classNode['instructor_current'] as Map,
                        )['uid'] ??
                        '')
                    .toString()
                    .trim();
          }

          if (teacherUid.isEmpty && classNode['attendance'] is Map) {
            final att = Map<dynamic, dynamic>.from(
              classNode['attendance'] as Map,
            );
            int bestTs = 0;
            String bestUid = '';
            for (final e in att.entries) {
              if (e.value is! Map) continue;
              final m = Map<String, dynamic>.from(e.value as Map);
              final uidVal =
                  (m['teacherUid'] ??
                          m['teacher_uid'] ??
                          m['teacherId'] ??
                          m['teacher_id'] ??
                          '')
                      .toString()
                      .trim();
              if (uidVal.isEmpty) continue;
              final ts = _toInt(m['updatedAt']);
              if (ts >= bestTs) {
                bestTs = ts;
                bestUid = uidVal;
              }
            }
            if (bestUid.isNotEmpty) teacherUid = bestUid;
          }

          if (teacherUid.isNotEmpty) {
            try {
              final ms = await _db
                  .child('users/$teacherUid/google_meet_url')
                  .get();
              meetUrl = (ms.value ?? '').toString().trim();
            } catch (_) {}
          }
        }

        out.add(
          _CourseProgressItem(
            courseKey: key,
            title: title.isEmpty ? 'Course' : title,
            code: code,
            variantKey: variantKey,
            classType: _courseTypeLabel(course),
            detailsLine: _courseDetailsLine(course),
            completed: completed,
            total: total,
            progress: progress,
            isPrivateOnline: isPrivateOnline,
            scheduleLine: scheduleLine,
            nextStartMs: nextStartMs,
            sessionDurationMinutes: sessionDurationMinutes,
            meetUrl: meetUrl,
          ),
        );
      }

      out.sort((a, b) {
        final aHasNext = a.nextStartMs > 0;
        final bHasNext = b.nextStartMs > 0;
        if (aHasNext != bHasNext) return aHasNext ? -1 : 1;

        if (aHasNext && bHasNext) {
          final byNext = a.nextStartMs.compareTo(b.nextStartMs);
          if (byNext != 0) return byNext;
        }

        final byProgress = b.progress.compareTo(a.progress);
        if (byProgress != 0) return byProgress;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
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

        final flexibleSyllabusSnap = await _db
            .child('syllabi/$courseId/flexible')
            .get();

        if (flexibleSyllabusSnap.exists) {
          return true;
        }
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  void _openCoursesScreen({String? courseKey}) {
    unawaited(
      WindowAccessService.instance.guardOpen(
        context: context,
        role: AppWindowRole.learner,
        windowKey: AppWindowKeys.learnerCourses,
        onAllowed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LearnerCoursesScreen(initialCourseKey: courseKey),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrowPhone = screenWidth < 420;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    final p = palette;

    if (uid.isEmpty) {
      return Center(
        child: Text(
          'Not logged in.',
          style: TextStyle(color: p.text, fontWeight: FontWeight.w800),
        ),
      );
    }

    return SafeArea(
      child: Stack(
        children: [
          ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              104 + (bottomPad > 0 ? bottomPad : 12),
            ),
            children: [
              const SizedBox(height: 8),

              _SectionTitle(palette: p, title: 'Homework • Reminders • Mail'),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final tiny = constraints.maxWidth < 350;
                  final gap = tiny ? 6.0 : 8.0;

                  return Row(
                    children: [
                      Expanded(
                        child: _LearnerHomeworkHomeCard(
                          compact: true,
                          targetKey: widget.homeworkCardKey,
                        ),
                      ),
                      SizedBox(width: gap),
                      const Expanded(child: _RemindersHomeCard(compact: true)),
                      SizedBox(width: gap),
                      const Expanded(
                        child: _LearnerMailHomeCard(compact: true),
                      ),
                    ],
                  );
                },
              ),
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
                      _SectionTitle(palette: p, title: 'Booking (حجز)'),
                      const SizedBox(height: 10),
                      KeyedSubtree(
                        key: widget.bookingCardKey,
                        child: const _BookingTopCard(),
                      ),
                      const SizedBox(height: 16),
                    ],
                  );
                },
              ),

              const SizedBox(height: 10),
              KeyedSubtree(
                key: widget.coursesListKey,
                child: FutureBuilder<List<_CourseProgressItem>>(
                  future: _progressFuture,
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

                    final hasJoinCards = items.any((e) => e.isPrivateOnline);

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final textScale = MediaQuery.textScalerOf(
                          context,
                        ).scale(1);
                        final useSingle =
                            constraints.maxWidth < 360 ||
                            (textScale > 1.15 && constraints.maxWidth < 900);
                        final crossAxisCount = useSingle
                            ? 1
                            : constraints.maxWidth >= 960
                            ? 3
                            : 2;

                        return GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: items.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: hasJoinCards
                                    ? (useSingle ? 0.92 : 0.86)
                                    : 1,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                              ),
                          itemBuilder: (context, i) {
                            return _ProgressCard(
                              palette: p,
                              item: items[i],
                              onTap: () => _openCoursesScreen(
                                courseKey: items[i].courseKey,
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          Positioned(
            left: isNarrowPhone ? 16 : null,
            right: isNarrowPhone ? 16 : 18,
            bottom: 14 + (bottomPad > 0 ? bottomPad : 0),
            child: FutureBuilder<_JoinFabPayload?>(
              future: _joinFabFuture,
              builder: (context, snap) {
                final payload = snap.data;
                if (payload == null) return const SizedBox.shrink();

                if (isNarrowPhone) {
                  return SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: () => _openJoinFabUrl(payload.meetUrl),
                      icon: const Icon(Icons.video_call_rounded),
                      label: const Text(
                        'Join Now',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: p.accent,
                        foregroundColor: Colors.white,
                        elevation: 8,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  );
                }

                return FloatingActionButton.extended(
                  heroTag: 'learner_home_join_fab',
                  onPressed: () => _openJoinFabUrl(payload.meetUrl),
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                  elevation: 8,
                  icon: const Icon(Icons.video_call_rounded),
                  label: const Text(
                    'Join Now',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                );
              },
            ),
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
  final String variantKey;
  final String classType;
  final String detailsLine;
  final int completed;
  final int total;
  final double progress;
  final bool isPrivateOnline;
  final String scheduleLine;
  final int nextStartMs;
  final int sessionDurationMinutes;
  final String meetUrl;

  const _CourseProgressItem({
    required this.courseKey,
    required this.title,
    required this.code,
    required this.variantKey,
    required this.classType,
    required this.detailsLine,
    required this.completed,
    required this.total,
    required this.progress,
    required this.isPrivateOnline,
    required this.scheduleLine,
    required this.nextStartMs,
    required this.sessionDurationMinutes,
    required this.meetUrl,
  });
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.palette, required this.title});

  final _HomePalette palette;
  final String title;

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
      ],
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({required this.palette, required this.text});

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
        border: Border.all(color: palette.border.withValues(alpha: 0.85)),
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
  const _EmptyCard({required this.palette, required this.text});

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
        border: Border.all(color: palette.border.withValues(alpha: 0.85)),
      ),
      child: Text(
        text,
        style: TextStyle(color: palette.text, fontWeight: FontWeight.w800),
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

  bool _canJoinNow(int startMs) {
    return canJoinFromStartMs(startMs);
  }

  Future<void> _openExternalUrl(BuildContext context, String url) async {
    var u = url.trim();
    if (u.isEmpty) return;

    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }

    final uri = Uri.tryParse(u);
    if (uri == null) {
      if (!context.mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Invalid meeting link.')),
      );
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
  }

  String _variantBadgeText(String variantKey) {
    switch (variantKey) {
      case 'recorded':
        return 'Recorded';
      case 'flexible':
      case 'online':
        return 'Flexible';
      case 'private':
      case 'live':
        return 'Private';
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return 'In-class';
      default:
        return 'Course';
    }
  }

  IconData _variantIcon(String variantKey) {
    switch (variantKey) {
      case 'recorded':
        return Icons.play_circle_fill_rounded;
      case 'flexible':
      case 'online':
        return Icons.wifi_rounded;
      case 'private':
      case 'live':
        return Icons.person_rounded;
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return Icons.groups_rounded;
      default:
        return Icons.menu_book_rounded;
    }
  }

  Color _variantAccentColor(String variantKey) {
    final key = variantKey.trim().toLowerCase();
    switch (key) {
      case 'recorded':
        return const Color(0xFF7C3AED);
      case 'flexible':
      case 'online':
        return const Color(0xFF2563EB);
      case 'private':
      case 'live':
        return const Color(0xFFF98D28);
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return const Color(0xFF1E8E3E);
      default:
        return palette.primary;
    }
  }

  String _schedulePreviewText(_CourseProgressItem item) {
    final line = item.scheduleLine.trim();
    if (line.isNotEmpty) return line;

    switch (item.variantKey) {
      case 'recorded':
        return 'Schedule: On-demand';
      case 'flexible':
      case 'online':
        return 'Schedule: Flexible booking';
      case 'private':
      case 'live':
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return 'Schedule: not set';
      default:
        return 'Schedule: -';
    }
  }

  @override
  Widget build(BuildContext context) {
    final percentText = (item.progress * 100).round();
    final variantAccent = _variantAccentColor(item.variantKey);
    final variantIcon = _variantIcon(item.variantKey);
    final variantBadge = _variantBadgeText(item.variantKey);
    final hasProgress = item.completed > 0;
    final completedAll = item.total > 0 && item.completed >= item.total;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final hasMeet = item.meetUrl.trim().isNotEmpty;

    return Material(
      color: palette.cardBg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = constraints.biggest.shortestSide;
            final compact = side < 180 || textScale > 1.15;
            final iconSize = compact ? 34.0 : 38.0;
            final ringSize = compact ? 64.0 : 84.0;

            return Container(
              padding: EdgeInsets.all(compact ? 10 : 12),
              decoration: BoxDecoration(
                color: completedAll
                    ? palette.primary.withValues(alpha: 0.08)
                    : (hasProgress
                          ? palette.primary.withValues(alpha: 0.04)
                          : palette.cardBg),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: hasProgress
                      ? variantAccent.withValues(alpha: 0.34)
                      : variantAccent.withValues(alpha: 0.20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: hasProgress
                        ? variantAccent.withValues(alpha: 0.10)
                        : Colors.black.withValues(alpha: 0.04),
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
                        width: iconSize,
                        height: iconSize,
                        decoration: BoxDecoration(
                          color: variantAccent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: variantAccent.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Icon(
                          variantIcon,
                          color: variantAccent,
                          size: compact ? 18 : 20,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: compact ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.primary,
                            fontWeight: FontWeight.w900,
                            fontSize: compact ? 12 : 14,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: variantAccent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: variantAccent.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Text(
                      variantBadge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: variantAccent,
                        fontWeight: FontWeight.w900,
                        fontSize: compact ? 9 : 10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Center(
                      child: _CourseProgressRing(
                        progress: item.total > 0 ? item.progress : 0,
                        label: '$percentText%',
                        palette: palette,
                        accent: variantAccent,
                        size: ringSize,
                      ),
                    ),
                  ),
                  Text(
                    item.classType,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text.withValues(alpha: 0.70),
                      fontWeight: FontWeight.w700,
                      fontSize: compact ? 10 : 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _schedulePreviewText(item),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text.withValues(alpha: 0.64),
                      fontWeight: FontWeight.w700,
                      fontSize: compact ? 9 : 10,
                    ),
                  ),
                  if (item.isPrivateOnline) ...[
                    const SizedBox(height: 8),
                    StreamBuilder<int>(
                      stream: Stream.periodic(
                        const Duration(seconds: 20),
                        (x) => x,
                      ),
                      initialData: 0,
                      builder: (context, _) {
                        final start = item.nextStartMs > 0
                            ? DateTime.fromMillisecondsSinceEpoch(
                                item.nextStartMs,
                              )
                            : null;
                        final canJoin = item.isPrivateOnline && hasMeet
                            ? _canJoinNow(item.nextStartMs)
                            : false;
                        final joinLabel = start == null
                            ? (hasMeet
                                  ? 'Join (schedule unavailable)'
                                  : 'Meet link not set')
                            : joinButtonLabelForWindow(
                                openFrom: joinOpensAt(start),
                                openUntil: joinClosesAt(start),
                                hasMeetLink: hasMeet,
                                actionLabel: 'Join',
                                closedLabel: 'Join window closed',
                              );
                        return SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: Size.fromHeight(compact ? 34 : 38),
                              backgroundColor: canJoin
                                  ? palette.accent
                                  : palette.text.withValues(alpha: 0.34),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: canJoin
                                ? () => _openExternalUrl(context, item.meetUrl)
                                : null,
                            child: Text(
                              joinLabel,
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: compact ? 11 : 12,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CourseProgressRing extends StatelessWidget {
  const _CourseProgressRing({
    required this.progress,
    required this.label,
    required this.palette,
    required this.accent,
    required this.size,
  });

  final double progress;
  final String label;
  final _HomePalette palette;
  final Color accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    final track = accent.withValues(alpha: 0.16);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _RingProgressPainter(
              progress: clamped,
              trackColor: track,
              progressColor: accent,
              glowColor: accent.withValues(alpha: 0.22),
            ),
          ),
          Container(
            width: size * 0.66,
            height: size * 0.66,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.cardBg,
              border: Border.all(color: accent.withValues(alpha: 0.38)),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w900,
                fontSize: size * 0.16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingProgressPainter extends CustomPainter {
  const _RingProgressPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    required this.glowColor,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;
  final Color glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.11;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final start = -math.pi / 2;
    final sweep = 2 * math.pi * progress;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final glowPaint = Paint()
      ..color = glowColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke + 4
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 0, 2 * math.pi, false, trackPaint);
    if (progress > 0) {
      canvas.drawArc(rect, start, sweep, false, glowPaint);
      canvas.drawArc(rect, start, sweep, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.glowColor != glowColor;
  }
}

class _BookingTopCard extends StatefulWidget {
  const _BookingTopCard();

  @override
  State<_BookingTopCard> createState() => _BookingTopCardState();
}

class _BookingTopCardState extends State<_BookingTopCard>
    with SingleTickerProviderStateMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Future<List<_NextBooking>>? _nextBookingFuture;
  final Map<String, Future<_MeetInfo?>> _meetInfoFutureByKey = {};

  Timer? _ticker;
  Timer? _nextBookingRefreshTimer;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;

  @override
  void initState() {
    super.initState();
    _nextBookingFuture = _findMyUpcomingBookingsAcrossCourses();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
    _nextBookingRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted) return;
      setState(() {
        _nextBookingFuture = _findMyUpcomingBookingsAcrossCourses();
        _meetInfoFutureByKey.clear();
      });
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );

    _pulseScale = Tween<double>(begin: 1.0, end: 1.035).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _nextBookingRefreshTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
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

  Future<List<Map<String, dynamic>>> _loadJoinableCourses() async {
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

      final classMap = (m['class'] is Map)
          ? Map<String, dynamic>.from(m['class'] as Map)
          : <String, dynamic>{};

      final variantKey = resolveCourseDeliveryKey(m);
      final studyMode = resolveCourseStudyMode(m);

      final isFlexible = variantKey == 'flexible';
      final isPrivateOnline = isPrivateOnlineCourse(m);
      if (!isFlexible && !isPrivateOnline) continue;

      final title = (m['title'] ?? m['course_title'] ?? 'Course').toString();

      int numVal(dynamic vv) =>
          (vv is num) ? vv.toInt() : int.tryParse(vv?.toString() ?? '') ?? 0;

      final assignedAt = numVal(m['assignedAt']);

      if (isFlexible) {
        final flexibleSyllabusSnap = await _db
            .child('syllabi/$courseId/flexible')
            .get();
        if (!flexibleSyllabusSnap.exists) continue;
      }

      final classId = (classMap['class_id'] ?? '').toString().trim();

      temp.add({
        'courseId': courseId,
        'courseKey': key,
        'classId': classId,
        'variantKey': variantKey,
        'studyMode': studyMode,
        'title': title,
        'assignedAt': assignedAt,
      });
    }

    temp.sort(
      (a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int),
    );
    return temp;
  }

  String _two(int n) => n < 10 ? '0$n' : '$n';

  String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  int _weekdayFromShort(String day) {
    switch (day.trim().toLowerCase()) {
      case 'mon':
      case 'monday':
        return DateTime.monday;
      case 'tue':
      case 'tues':
      case 'tuesday':
        return DateTime.tuesday;
      case 'wed':
      case 'wednesday':
        return DateTime.wednesday;
      case 'thu':
      case 'thur':
      case 'thurs':
      case 'thursday':
        return DateTime.thursday;
      case 'fri':
      case 'friday':
        return DateTime.friday;
      case 'sat':
      case 'saturday':
        return DateTime.saturday;
      case 'sun':
      case 'sunday':
        return DateTime.sunday;
      default:
        return 0;
    }
  }

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

  String _readFirstNonEmptyMap(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = (m[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  DateTime? _parseYmd(String ymd) {
    final p = ymd.trim().split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  DateTime? _nextPrivateSessionStart({
    required Map<String, dynamic> schedule,
    required DateTime now,
  }) {
    final firstDate = _parseYmd(
      (schedule['first_session_date'] ?? '').toString(),
    );
    if (firstDate == null) return null;

    final sessions = schedule['sessions'];
    final sessionNodes = <Map<String, dynamic>>[];
    if (sessions is List) {
      for (final it in sessions) {
        if (it is! Map) continue;
        sessionNodes.add(it.map((k, v) => MapEntry(k.toString(), v)));
      }
    } else if (sessions is Map) {
      for (final it in sessions.values) {
        if (it is! Map) continue;
        sessionNodes.add(it.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    if (sessionNodes.isEmpty) return null;

    DateTime? best;
    final firstDay = DateTime(firstDate.year, firstDate.month, firstDate.day);

    for (int i = 0; i <= 35; i++) {
      final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      if (day.isBefore(firstDay)) continue;

      for (final s in sessionNodes) {
        final weekday = _weekdayFromShort((s['day'] ?? '').toString());
        if (weekday <= 0 || weekday != day.weekday) continue;

        final startTime = (s['start_time'] ?? '').toString().trim();
        final hm = startTime.split(':');
        if (hm.length != 2) continue;
        final h = int.tryParse(hm[0]);
        final m = int.tryParse(hm[1]);
        if (h == null || m == null) continue;

        final start = DateTime(day.year, day.month, day.day, h, m);
        final duration = _toInt(s['duration_min'], fallback: 60);
        final end = start.add(Duration(minutes: duration > 0 ? duration : 60));
        if (end.isBefore(now)) continue;

        if (best == null || start.isBefore(best)) {
          best = start;
        }
      }
    }

    return best;
  }

  Future<List<_NextBooking>> _findMyUpcomingBookingsAcrossCourses() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return const <_NextBooking>[];

    final courses = await _loadJoinableCourses();
    if (courses.isEmpty) return const <_NextBooking>[];

    final now = DateTime.now();
    final all = <_NextBooking>[];
    final dedupeKeys = <String>{};

    final Map<String, Set<String>> attendedBookingKeysByCourse = {};

    Future<Set<String>> loadAttendedBookingKeys(String courseId) async {
      final cached = attendedBookingKeysByCourse[courseId];
      if (cached != null) return cached;

      final out = <String>{};
      try {
        final snap = await _db
            .child('booking_progress/$uid/$courseId/online_attendance')
            .get();
        if (snap.exists && snap.value is Map) {
          final m = Map<dynamic, dynamic>.from(snap.value as Map);
          for (final k in m.keys) {
            out.add(k.toString());
          }
        }
      } catch (_) {}

      attendedBookingKeysByCourse[courseId] = out;
      return out;
    }

    const daysAhead = 14;

    for (final c in courses) {
      final variantKey = (c['variantKey'] ?? '').toString();
      final cid = (c['courseId'] ?? '').toString().trim();
      if (cid.isEmpty) continue;

      if (variantKey == 'private') {
        final classId = (c['classId'] ?? '').toString().trim();
        if (classId.isEmpty) continue;

        Map<String, dynamic> classNode = <String, dynamic>{};
        try {
          final classSnap = await _db.child('classes/$classId').get();
          final cv = classSnap.value;
          if (cv is Map) {
            classNode = cv.map((k, v) => MapEntry(k.toString(), v));
          }
        } catch (_) {}

        final scheduleRaw = classNode['schedule'];
        if (scheduleRaw is! Map) continue;
        final schedule = scheduleRaw.map((k, v) => MapEntry(k.toString(), v));

        final nextStart = _nextPrivateSessionStart(
          schedule: schedule,
          now: now,
        );
        if (nextStart == null) continue;

        final sessions = schedule['sessions'];
        int durationMinutes = 60;
        if (sessions is List) {
          for (final it in sessions) {
            if (it is! Map) continue;
            final sm = it.map((k, v) => MapEntry(k.toString(), v));
            final weekday = _weekdayFromShort((sm['day'] ?? '').toString());
            final startTime = (sm['start_time'] ?? '').toString().trim();
            if (weekday != nextStart.weekday) continue;
            if (startTime !=
                '${_two(nextStart.hour)}:${_two(nextStart.minute)}') {
              continue;
            }
            final dur = _toInt(sm['duration_min'], fallback: 60);
            durationMinutes = dur > 0 ? dur : 60;
            break;
          }
        }

        final teacherId =
            _readFirstNonEmptyMap(classNode, [
              'teacherUid',
              'teacher_uid',
              'teacherId',
              'teacher_id',
              'instructorUid',
            ]).isNotEmpty
            ? _readFirstNonEmptyMap(classNode, [
                'teacherUid',
                'teacher_uid',
                'teacherId',
                'teacher_id',
                'instructorUid',
              ])
            : ((classNode['instructor_current'] is Map)
                  ? _readFirstNonEmptyMap(
                      Map<String, dynamic>.from(
                        classNode['instructor_current'] as Map,
                      ),
                      const ['uid'],
                    )
                  : '');

        final teacherName =
            _readFirstNonEmptyMap(classNode, [
              'teacherName',
              'teacher_name',
              'instructor',
            ]).isNotEmpty
            ? _readFirstNonEmptyMap(classNode, [
                'teacherName',
                'teacher_name',
                'instructor',
              ])
            : ((classNode['instructor_current'] is Map)
                  ? _readFirstNonEmptyMap(
                      Map<String, dynamic>.from(
                        classNode['instructor_current'] as Map,
                      ),
                      const ['name'],
                    )
                  : 'Teacher');

        final candidate = _NextBooking(
          source: 'private_online',
          courseId: cid,
          classId: classId,
          dayKey: _dateKey(nextStart),
          time: '${_two(nextStart.hour)}:${_two(nextStart.minute)}',
          start: nextStart,
          durationMinutes: durationMinutes,
          teacherId: teacherId,
          teacherName: teacherName.isEmpty ? 'Teacher' : teacherName,
        );

        final key =
            '${candidate.source}|${candidate.courseId}|${candidate.dayKey}|${candidate.time}|${candidate.teacherId}';
        if (dedupeKeys.add(key)) {
          all.add(candidate);
        }
        continue;
      }

      for (int i = 0; i < daysAhead; i++) {
        final day = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: i));
        final dk = _dateKey(day);

        final snap = await _db.child('booking_reservations/$cid/$dk').get();
        final v = snap.value;
        if (v is! Map) continue;

        final m = Map<dynamic, dynamic>.from(v);

        for (final e in m.entries) {
          final hhmm = e.key.toString();
          final node = e.value;
          if (node is! Map) continue;

          final start = _parseSlotStart(dk, hhmm);
          if (start == null) continue;
          final joinWindowEnds = start.add(const Duration(minutes: 10));
          if (joinWindowEnds.isBefore(now)) continue;

          final sm = Map<dynamic, dynamic>.from(node);

          Future<void> considerCandidate(
            Map<dynamic, dynamic> slotLike,
            String teacherKey,
          ) async {
            final learners = slotLike['learners'];
            if (learners is! Map) return;

            final lm = Map<dynamic, dynamic>.from(learners);
            if (!lm.containsKey(uid)) return;

            final teacherId = (slotLike['teacherId'] ?? teacherKey)
                .toString()
                .trim();
            final teacherName = (slotLike['teacherName'] ?? 'Teacher')
                .toString()
                .trim();

            final candidate = _NextBooking(
              source: 'flexible',
              courseId: cid,
              classId: '',
              dayKey: dk,
              time: hhmm,
              start: start,
              durationMinutes: 60,
              teacherId: teacherId,
              teacherName: teacherName.isEmpty ? 'Teacher' : teacherName,
            );

            final bookingKey = _bookingKey(cid, dk, hhmm);
            final attendedKeys = await loadAttendedBookingKeys(cid);
            if (attendedKeys.contains(bookingKey)) {
              return;
            }

            final key =
                '${candidate.source}|${candidate.courseId}|${candidate.dayKey}|${candidate.time}|${candidate.teacherId}';
            if (dedupeKeys.add(key)) {
              all.add(candidate);
            }
          }

          // Flat legacy shape: /{day}/{time} => {learners:{...}, ...}
          if (sm['learners'] is Map) {
            await considerCandidate(sm, '');
            continue;
          }

          // Nested shape: /{day}/{time}/{teacherId} => {learners:{...}, ...}
          for (final te in sm.entries) {
            final teacherKey = te.key.toString();
            final teacherNode = te.value;
            if (teacherNode is! Map) continue;
            await considerCandidate(
              Map<dynamic, dynamic>.from(teacherNode),
              teacherKey,
            );
          }
        }
      }
    }

    all.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      final bySource = a.source.compareTo(b.source);
      if (bySource != 0) return bySource;
      final byCourse = a.courseId.compareTo(b.courseId);
      if (byCourse != 0) return byCourse;
      final byTime = a.time.compareTo(b.time);
      if (byTime != 0) return byTime;
      return a.teacherId.compareTo(b.teacherId);
    });

    if (all.length <= 3) return all;
    return all.take(3).toList();
  }

  Future<_MeetInfo?> _meetInfoFutureFor(_NextBooking next) {
    final key =
        '${next.source}|${next.teacherId}|${next.courseId}|${next.classId}';
    return _meetInfoFutureByKey.putIfAbsent(
      key,
      () => _loadMeetInfo(next: next),
    );
  }

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  Future<_MeetInfo?> _loadMeetInfo({required _NextBooking next}) async {
    if (next.teacherId.isEmpty) return null;

    if (next.source == 'private_online') {
      try {
        final meetSnap = await _db
            .child('users/${next.teacherId}/google_meet_url')
            .get();
        final meetUrl = (meetSnap.value ?? '').toString().trim();
        if (meetUrl.isEmpty) return null;
        return _MeetInfo(
          meetUrl: meetUrl,
          durationMinutes: next.durationMinutes > 0 ? next.durationMinutes : 60,
        );
      } catch (_) {
        return null;
      }
    }

    if (next.courseId.isEmpty) return null;

    try {
      final snap = await _db
          .child('booking_availability/${next.teacherId}/${next.courseId}')
          .get();
      final v = snap.value;
      if (v is! Map) return null;

      final m = Map<String, dynamic>.from(v);

      final meetUrl =
          (m['meetUrl'] ??
                  m['meet_url'] ??
                  m['googleMeetUrl'] ??
                  m['google_meet_url'] ??
                  '')
              .toString()
              .trim();

      int dur = _toInt(m['durationMinutes'], fallback: 0);
      if (dur <= 0) dur = _toInt(m['durationMin'], fallback: 0);
      if (dur <= 0) dur = 60;

      if (meetUrl.isEmpty) {
        final userMeetSnap = await _db
            .child('users/${next.teacherId}/google_meet_url')
            .get();
        final fallback = (userMeetSnap.value ?? '').toString().trim();
        if (fallback.isEmpty) return null;
        return _MeetInfo(meetUrl: fallback, durationMinutes: dur);
      }

      return _MeetInfo(meetUrl: meetUrl, durationMinutes: dur);
    } catch (_) {
      return null;
    }
  }

  bool _canJoinNow(DateTime start, int durationMinutes) {
    return canJoinFromStart(start);
  }

  Duration _untilJoinOpens(DateTime start) {
    final openFrom = joinOpensAt(start);
    return openFrom.difference(DateTime.now());
  }

  Duration _untilJoinCloses(DateTime start, int durationMinutes) {
    final openUntil = joinClosesAt(start);
    return openUntil.difference(DateTime.now());
  }

  String _formatCountdown(Duration d) {
    int total = d.inSeconds;
    if (total < 0) total = 0;

    final days = total ~/ 86400;
    final hours = (total % 86400) ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;

    String two(int n) => n < 10 ? '0$n' : '$n';

    if (days > 0) {
      return '${days}d ${two(hours)}h ${two(minutes)}m';
    }
    if (hours > 0) {
      return '${hours}h ${two(minutes)}m ${two(seconds)}s';
    }
    return '${minutes}m ${two(seconds)}s';
  }

  double _joinWindowProgress(DateTime start, int durationMinutes) {
    final now = DateTime.now();
    final openFrom = joinOpensAt(start);
    final openUntil = joinClosesAt(start);

    final totalMs = openUntil.difference(openFrom).inMilliseconds;
    if (totalMs <= 0) return 0;

    final remainingMs = openUntil.difference(now).inMilliseconds;
    final value = remainingMs / totalMs;

    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }

  double _preJoinProgress(DateTime start) {
    final now = DateTime.now();
    final openFrom = joinOpensAt(start);

    final totalMs = openFrom.difference(now).inMilliseconds;
    final fullSpanMs = openFrom
        .difference(DateTime(now.year, now.month, now.day))
        .inMilliseconds;

    if (fullSpanMs <= 0) return 0;

    final value = 1 - (totalMs / fullSpanMs);
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }

  double _sessionUrgencyProgress(DateTime start) {
    final now = DateTime.now();
    final diff = start.difference(now);

    const totalWindow = Duration(hours: 24);
    final remainingMs = diff.inMilliseconds;
    final totalMs = totalWindow.inMilliseconds;

    if (remainingMs <= 0) return 1;
    if (remainingMs >= totalMs) return 0;

    final value = 1 - (remainingMs / totalMs);
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }

  Color _deepRedByUrgency(double urgency) {
    if (urgency >= 0.92) return const Color(0xFF7F0000);
    if (urgency >= 0.80) return const Color(0xFFB71C1C);
    if (urgency >= 0.60) return const Color(0xFFC62828);
    if (urgency >= 0.40) return const Color(0xFFD32F2F);
    if (urgency >= 0.20) return const Color(0xFFE53935);
    return const Color(0xFFEF5350);
  }

  Color _upcomingCountdownColor({
    required double urgency,
    required _HomePalette p,
  }) {
    final u = urgency.clamp(0.0, 1.0);

    if (u <= 0.55) {
      final t = u / 0.55;
      return Color.lerp(p.primary, p.accent, t) ?? p.accent;
    }

    final t = (u - 0.55) / 0.45;
    return Color.lerp(p.accent, const Color(0xFFD32F2F), t) ??
        const Color(0xFFD32F2F);
  }

  Color _statusColor({
    required bool canJoin,
    required bool beforeOpen,
    required Duration closesIn,
    required _HomePalette p,
  }) {
    if (canJoin) {
      if (closesIn.inSeconds <= 120) return const Color(0xFFB71C1C);
      if (closesIn.inSeconds <= 300) return const Color(0xFFC62828);
      return const Color(0xFFD32F2F);
    }

    if (beforeOpen) return const Color(0xFFD32F2F);
    return const Color(0xFFB71C1C);
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
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Invalid meeting link.')),
        );
      }
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      AppToast.fromSnackBar(
        context,
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

      final onlineRef = _db.child(
        'booking_progress/$learnerUid/${next.courseId}/online_attendance/$bKey',
      );
      final existing = await onlineRef.get();
      final existingMap = existing.exists && existing.value is Map
          ? Map<String, dynamic>.from(existing.value as Map)
          : <String, dynamic>{};
      if (onlineAttendanceRecordConsumesCredit(existingMap)) return;

      final taughtItems = (sessionNo > 0)
          ? [
              {'type': 'syllabus', 'sessionNumber': sessionNo},
            ]
          : <Map<String, dynamic>>[];

      final createdAt = existingMap['createdAt'];
      await onlineRef.set({
        ...existingMap,
        'bookingKey': bKey,
        'courseId': next.courseId,
        'dayKey': next.dayKey,
        'time': next.time,
        'startAt': next.start.millisecondsSinceEpoch,
        'sessionNo': sessionNo,
        'taughtItems': taughtItems,
        'countedCredit': true,
        'creditCountReason': 'learner_join',
        'createdAt': createdAt ?? ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });

      if (sessionNo > 0) {
        final curRef = _db.child(
          'booking_progress/$learnerUid/${next.courseId}/currentSession',
        );
        final curSnap = await curRef.get();
        final curVal = curSnap.value;

        int cur = 0;
        if (curVal is int) {
          cur = curVal;
        } else if (curVal is num) {
          cur = curVal.toInt();
        } else {
          cur = int.tryParse(curVal?.toString() ?? '') ?? 0;
        }

        if (cur <= 0) cur = 1;

        final nextSession = sessionNo + 1;
        if (cur < nextSession) {
          await curRef.set(nextSession);
        }
      }
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
                colors: [p.accent, p.accent.withValues(alpha: 0.88)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: p.accent.withValues(alpha: 0.22),
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
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
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
                        'Booking (حجز)',
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
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
        FutureBuilder<List<_NextBooking>>(
          future: _nextBookingFuture,
          builder: (context, snap) {
            final bookings = snap.data ?? const <_NextBooking>[];

            if (snap.connectionState == ConnectionState.waiting) {
              return _LoadingCard(
                palette: p,
                text: 'Checking your next class...',
              );
            }

            if (bookings.isEmpty) {
              return _EmptyCard(
                palette: p,
                text: 'No upcoming reserved class found right now.',
              );
            }

            return Column(
              children: [
                for (int i = 0; i < bookings.length; i++) ...[
                  _buildUpcomingBookingCard(next: bookings[i], p: p),
                  if (i < bookings.length - 1) const SizedBox(height: 10),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildUpcomingBookingCard({
    required _NextBooking next,
    required _HomePalette p,
  }) {
    return FutureBuilder<_MeetInfo?>(
      future: _meetInfoFutureFor(next),
      builder: (context, ms) {
        final meet = ms.data;
        final timeStr = '${_friendlyDate(next.start)} • ${next.time}';
        final teacherStr = next.teacherName;

        final now = DateTime.now();
        final openFrom = next.start;
        final safeDuration = meet?.durationMinutes ?? next.durationMinutes;
        final openUntil = next.start.add(
          Duration(minutes: safeDuration > 0 ? safeDuration : 60),
        );

        final beforeOpen = now.isBefore(openFrom);
        final afterClose = now.isAfter(openUntil);

        final opensIn = _untilJoinOpens(next.start);
        final closesIn = _untilJoinCloses(
          next.start,
          meet?.durationMinutes ?? next.durationMinutes,
        );

        final opensInText = _formatCountdown(opensIn);
        final closesInText = _formatCountdown(closesIn);

        final canJoin = _canJoinNow(next.start, meet?.durationMinutes ?? 60);

        final statusColor = _statusColor(
          canJoin: canJoin,
          beforeOpen: beforeOpen,
          closesIn: closesIn,
          p: p,
        );

        final urgency = _sessionUrgencyProgress(next.start);
        final urgentRed = _deepRedByUrgency(urgency);
        final upcomingColor = _upcomingCountdownColor(urgency: urgency, p: p);
        final idleColor = beforeOpen ? upcomingColor : urgentRed;

        if (meet == null) {
          if (_pulseController.isAnimating) {
            _pulseController.stop();
          }

          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: idleColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: idleColor.withValues(alpha: 0.95),
                width: 2.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: idleColor.withValues(alpha: 0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.upcoming_rounded, size: 18, color: p.accent),
                    const SizedBox(width: 8),
                    Text(
                      'Upcoming reserved class',
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
                    color: p.text.withValues(alpha: 0.70),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.soft.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: p.border.withValues(alpha: 0.85)),
                  ),
                  child: Text(
                    'Meet link not set for this course yet.',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: p.text,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        if (canJoin) {
          if (!_pulseController.isAnimating) {
            _pulseController.repeat(reverse: true);
          }
        } else {
          if (_pulseController.isAnimating) {
            _pulseController.stop();
            _pulseController.value = 0;
          }
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: canJoin
                ? statusColor.withValues(alpha: 0.16)
                : idleColor.withValues(alpha: 0.08 + (urgency * 0.14)),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: canJoin ? statusColor : idleColor,
              width: canJoin ? 2.8 : (1.8 + (urgency * 1.8)),
            ),
            boxShadow: [
              BoxShadow(
                color: (canJoin ? statusColor : idleColor).withValues(
                  alpha: 0.18 + (urgency * 0.20),
                ),
                blurRadius: 14 + (urgency * 10),
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
                    canJoin ? Icons.video_call_rounded : Icons.upcoming_rounded,
                    size: 18,
                    color: canJoin ? statusColor : idleColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    canJoin
                        ? 'Join available now'
                        : beforeOpen
                        ? 'Upcoming reserved class'
                        : 'Join window closed',
                    style: TextStyle(
                      color: canJoin ? statusColor : idleColor,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                timeStr,
                style: TextStyle(fontWeight: FontWeight.w900, color: p.primary),
              ),
              const SizedBox(height: 4),
              Text(
                'Teacher: $teacherStr',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: p.text.withValues(alpha: 0.70),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: canJoin
                      ? statusColor.withValues(alpha: 0.12)
                      : idleColor.withValues(alpha: 0.06 + (urgency * 0.10)),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: canJoin
                        ? statusColor.withValues(alpha: 0.45)
                        : idleColor.withValues(alpha: 0.60),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      canJoin
                          ? 'Join closes in $closesInText'
                          : beforeOpen
                          ? 'Join opens in $opensInText'
                          : 'This join window has ended',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: canJoin ? statusColor : idleColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: canJoin
                            ? _joinWindowProgress(
                                next.start,
                                meet.durationMinutes,
                              )
                            : beforeOpen
                            ? _preJoinProgress(next.start)
                            : 1,
                        backgroundColor: p.soft.withValues(alpha: 0.85),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          canJoin ? statusColor : idleColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      canJoin
                          ? 'Join is open now. It stays available until 10 minutes after start.'
                          : beforeOpen
                          ? 'Your session is booked. Join becomes available 5 minutes before start.'
                          : 'Wait for your next reserved class to appear here.',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: p.text.withValues(alpha: 0.64),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ScaleTransition(
                scale: canJoin
                    ? _pulseScale
                    : const AlwaysStoppedAnimation<double>(1.0),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: canJoin
                        ? statusColor
                        : p.accent.withValues(alpha: 0.55),
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

                          if (uid.isNotEmpty && next.source == 'flexible') {
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
                        ? 'Join Google Meet ($closesInText left)'
                        : beforeOpen
                        ? 'Join in $opensInText'
                        : afterClose
                        ? 'Join window closed'
                        : 'Join unavailable',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NextBooking {
  final String source;
  final String courseId;
  final String classId;
  final String dayKey;
  final String time;
  final DateTime start;
  final int durationMinutes;
  final String teacherId;
  final String teacherName;

  _NextBooking({
    required this.source,
    required this.courseId,
    required this.classId,
    required this.dayKey,
    required this.time,
    required this.start,
    required this.durationMinutes,
    required this.teacherId,
    required this.teacherName,
  });
}

class _MeetInfo {
  final String meetUrl;
  final int durationMinutes;

  _MeetInfo({required this.meetUrl, required this.durationMinutes});
}

class _JoinFabPayload {
  final String meetUrl;
  final DateTime start;
  final String source;

  _JoinFabPayload({
    required this.meetUrl,
    required this.start,
    required this.source,
  });
}

Future<void> _openBookingCoursePicker(BuildContext context) async {
  final bookingEnabled = await WindowAccessService.instance.isWindowEnabled(
    role: AppWindowRole.learner,
    windowKey: AppWindowKeys.learnerBooking,
  );
  if (!bookingEnabled) {
    if (context.mounted) {
      await showWindowMaintenanceDialog(context);
    }
    if (!context.mounted) return;
    return;
  }

  final me = FirebaseAuth.instance.currentUser;
  final uid = me?.uid ?? '';
  if (uid.isEmpty) {
    if (!context.mounted) return;
    AppToast.fromSnackBar(
      context,
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

        final flexibleSyllabusSnap = await db
            .child('syllabi/$courseId/flexible')
            .get();
        if (!flexibleSyllabusSnap.exists) continue;

        courses.add({
          'courseKey': courseId,
          'title': title,
          'code': code,
          'assignedAt': assignedAt,
        });
      }

      courses.sort(
        (a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int),
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(
        content: Text(
          toHumanError(e, fallback: 'Could not load your courses right now.'),
        ),
      ),
    );
    return;
  }

  if (!context.mounted) return;

  if (courses.isEmpty) {
    AppToast.fromSnackBar(
      context,
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
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                          border: Border.all(
                            color: p.border.withValues(alpha: 0.85),
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
                                  color: p.border.withValues(alpha: 0.85),
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
                                      color: p.text.withValues(alpha: 0.62),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded, color: p.primary),
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
  final homeworkEnabled = await WindowAccessService.instance.isWindowEnabled(
    role: AppWindowRole.learner,
    windowKey: AppWindowKeys.learnerHomework,
  );
  if (!homeworkEnabled) {
    if (context.mounted) {
      await showWindowMaintenanceDialog(context);
    }
    if (!context.mounted) return;
    return;
  }

  final me = FirebaseAuth.instance.currentUser;
  final uid = me?.uid ?? '';
  if (uid.isEmpty) {
    if (!context.mounted) return;
    AppToast.fromSnackBar(
      context,
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

      courses.sort(
        (a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int),
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(
        content: Text(
          toHumanError(e, fallback: 'Could not load your courses right now.'),
        ),
      ),
    );
    return;
  }

  if (!context.mounted) return;

  if (courses.isEmpty) {
    AppToast.fromSnackBar(
      context,
      const SnackBar(
        content: Text('All slots are full, please try again later'),
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
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                            color: p.border.withValues(alpha: 0.85),
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
                                  color: p.border.withValues(alpha: 0.85),
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
                                      color: p.text.withValues(alpha: 0.62),
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
                                      color: Colors.red.withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: Colors.red.withValues(
                                          alpha: 0.25,
                                        ),
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

class _LearnerHomeworkHomeCard extends StatelessWidget {
  const _LearnerHomeworkHomeCard({this.compact = false, this.targetKey});

  final bool compact;
  final GlobalKey? targetKey;

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

        return KeyedSubtree(
          key: targetKey,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () async {
              await _openHomeworkCoursePicker(
                context,
                courseKeysWithUndone: courseKeysWithUndone,
              );
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tiny = compact && constraints.maxWidth < 112;
                final iconBox = tiny ? 34.0 : (compact ? 40.0 : 46.0);
                final iconSize = tiny ? 18.0 : 22.0;
                final contentPadding = tiny ? 8.0 : (compact ? 12.0 : 14.0);

                return Container(
                  decoration: BoxDecoration(
                    color: p.cardBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: p.border.withValues(alpha: 0.85)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 12,
                        offset: const Offset(0, 7),
                      ),
                    ],
                  ),
                  padding: EdgeInsets.all(contentPadding),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: iconBox,
                            height: iconBox,
                            decoration: BoxDecoration(
                              color: p.soft,
                              borderRadius: BorderRadius.circular(
                                tiny ? 12 : 15,
                              ),
                              border: Border.all(
                                color: p.border.withValues(alpha: 0.85),
                              ),
                            ),
                            child: Icon(
                              Icons.assignment_rounded,
                              color: p.primary,
                              size: iconSize,
                            ),
                          ),
                          if (undoneTotal > 0)
                            Positioned(
                              right: tiny ? -6 : -8,
                              top: tiny ? -6 : -8,
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: tiny ? 6 : 8,
                                  vertical: tiny ? 2 : 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                                child: Text(
                                  undoneTotal > 99 ? '99+' : '$undoneTotal',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: tiny ? 9 : 11,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      SizedBox(height: tiny ? 10 : 18),
                      Text(
                        'Homework',
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: tiny ? 12 : 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.62),
                          fontWeight: FontWeight.w700,
                          fontSize: tiny ? 10 : 12,
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
}

class _RemindersHomeCard extends StatelessWidget {
  const _RemindersHomeCard({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final uid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('reminders/$uid');
    final p = _paletteFromTheme();

    return StreamBuilder<DatabaseEvent>(
      stream: uid.isEmpty ? const Stream.empty() : ref.onValue,
      builder: (context, snap) {
        final v = snap.data?.snapshot.value;
        final unread = NotificationCounterService.reminderCounts(v).newCount;

        final subtitle = unread == 0 ? 'All caught up ✅' : '$unread unread';

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            unawaited(
              WindowAccessService.instance.guardOpen(
                context: context,
                role: AppWindowRole.learner,
                windowKey: AppWindowKeys.learnerReminders,
                onAllowed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const LearnerRemindersListScreen(),
                    ),
                  );
                },
              ),
            );
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tiny = compact && constraints.maxWidth < 112;
              final iconBox = tiny ? 34.0 : (compact ? 40.0 : 46.0);
              final iconSize = tiny ? 18.0 : 22.0;
              final contentPadding = tiny ? 8.0 : (compact ? 12.0 : 14.0);

              return Container(
                decoration: BoxDecoration(
                  color: p.cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: p.border.withValues(alpha: 0.85)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                padding: EdgeInsets.all(contentPadding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: iconBox,
                          height: iconBox,
                          decoration: BoxDecoration(
                            color: p.soft,
                            borderRadius: BorderRadius.circular(tiny ? 12 : 15),
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.85),
                            ),
                          ),
                          child: Icon(
                            Icons.notifications_active_rounded,
                            color: p.primary,
                            size: iconSize,
                          ),
                        ),
                        if (unread > 0)
                          Positioned(
                            right: tiny ? -6 : -8,
                            top: tiny ? -6 : -8,
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: tiny ? 6 : 8,
                                vertical: tiny ? 2 : 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                              child: Text(
                                unread > 99 ? '99+' : '$unread',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: tiny ? 9 : 11,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: tiny ? 10 : (compact ? 12 : 18)),
                    Text(
                      'Reminders',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: tiny ? 12 : (compact ? 14 : 16),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.text.withValues(alpha: 0.62),
                        fontWeight: FontWeight.w700,
                        fontSize: tiny ? 10 : 12,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _LearnerMailHomeCard extends StatelessWidget {
  const _LearnerMailHomeCard({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('mail_index/$uid');
    final p = _paletteFromTheme();

    return StreamBuilder<DatabaseEvent>(
      stream: uid.isEmpty ? const Stream.empty() : ref.onValue,
      builder: (context, snap) {
        final v = snap.data?.snapshot.value;
        final unread = NotificationCounterService.mailUnread(v);

        final subtitle = unread == 0 ? 'No unread ✅' : '$unread unread';

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            unawaited(
              WindowAccessService.instance.guardOpen(
                context: context,
                role: AppWindowRole.learner,
                windowKey: AppWindowKeys.learnerMail,
                onAllowed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const LearnerMailScreen(),
                    ),
                  );
                },
              ),
            );
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tiny = compact && constraints.maxWidth < 112;
              final iconBox = tiny ? 34.0 : (compact ? 40.0 : 46.0);
              final iconSize = tiny ? 18.0 : 22.0;
              final contentPadding = tiny ? 8.0 : (compact ? 12.0 : 14.0);

              return Container(
                decoration: BoxDecoration(
                  color: p.cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: p.border.withValues(alpha: 0.85)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                padding: EdgeInsets.all(contentPadding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: iconBox,
                          height: iconBox,
                          decoration: BoxDecoration(
                            color: p.soft,
                            borderRadius: BorderRadius.circular(tiny ? 12 : 15),
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.85),
                            ),
                          ),
                          child: Icon(
                            Icons.mail_rounded,
                            color: p.primary,
                            size: iconSize,
                          ),
                        ),
                        if (unread > 0)
                          Positioned(
                            right: tiny ? -6 : -8,
                            top: tiny ? -6 : -8,
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: tiny ? 6 : 8,
                                vertical: tiny ? 2 : 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                              child: Text(
                                unread > 99 ? '99+' : '$unread',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: tiny ? 9 : 11,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: tiny ? 10 : (compact ? 12 : 18)),
                    Text(
                      'Mail',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: tiny ? 12 : (compact ? 14 : 16),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.text.withValues(alpha: 0.62),
                        fontWeight: FontWeight.w700,
                        fontSize: tiny ? 10 : 12,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ignore: unused_element
class _GalleryHomeCard extends StatelessWidget {
  const _GalleryHomeCard();

  @override
  Widget build(BuildContext context) {
    final p = _paletteFromTheme();

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        unawaited(
          WindowAccessService.instance.guardOpen(
            context: context,
            role: AppWindowRole.learner,
            windowKey: AppWindowKeys.learnerGallery,
            onAllowed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LearnerGalleryScreen()),
              );
            },
          ),
        );
      },
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withValues(alpha: 0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
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
                border: Border.all(color: p.border.withValues(alpha: 0.85)),
              ),
              child: Icon(Icons.photo_library_rounded, color: p.primary),
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
                      color: p.text.withValues(alpha: 0.62),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(Icons.chevron_right_rounded, color: p.primary),
            ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _StudyCoachHomeCard extends StatelessWidget {
  const _StudyCoachHomeCard();

  @override
  Widget build(BuildContext context) {
    final p = _paletteFromTheme();

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        unawaited(
          WindowAccessService.instance.guardOpen(
            context: context,
            role: AppWindowRole.learner,
            windowKey: AppWindowKeys.learnerStudyCoach,
            onAllowed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LearnerStudyCoachScreen(),
                ),
              );
            },
          ),
        );
      },
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withValues(alpha: 0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
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
                border: Border.all(color: p.border.withValues(alpha: 0.85)),
              ),
              child: Icon(Icons.psychology_alt_rounded, color: p.primary),
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
                      color: p.text.withValues(alpha: 0.62),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(Icons.chevron_right_rounded, color: p.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _LearnerHomeWebRail extends StatelessWidget {
  const _LearnerHomeWebRail({
    required this.palette,
    required this.onOpenCourses,
    required this.onOpenBooking,
    required this.onOpenMail,
    required this.onOpenReminders,
    required this.onOpenHomework,
    required this.onOpenGallery,
    required this.onOpenStories,
    required this.onOpenGames,
    required this.onOpenCoach,
    required this.onOpenProfile,
    required this.onLogout,
  });

  final _HomePalette palette;
  final VoidCallback onOpenCourses;
  final VoidCallback onOpenBooking;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenReminders;
  final VoidCallback onOpenHomework;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenStories;
  final VoidCallback onOpenGames;
  final VoidCallback onOpenCoach;
  final VoidCallback onOpenProfile;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 286,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 6, 0, 6),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.border.withValues(alpha: 0.9)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Learner Tools',
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                children: [
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.menu_book_rounded,
                    title: 'Courses',
                    onTap: onOpenCourses,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.event_available_rounded,
                    title: 'Booking',
                    onTap: onOpenBooking,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.mail_rounded,
                    title: 'Mail',
                    onTap: onOpenMail,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.notifications_active_rounded,
                    title: 'Reminders',
                    onTap: onOpenReminders,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.assignment_rounded,
                    title: 'Homework (from Courses)',
                    onTap: onOpenHomework,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.photo_library_rounded,
                    title: 'Gallery',
                    onTap: onOpenGallery,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.auto_stories_rounded,
                    title: 'Stories',
                    onTap: onOpenStories,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.games_rounded,
                    title: 'Games',
                    onTap: onOpenGames,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.psychology_alt_rounded,
                    title: 'Study Coach',
                    onTap: onOpenCoach,
                  ),
                  _DrawerTile(
                    palette: palette,
                    icon: Icons.person_rounded,
                    title: 'Profile',
                    onTap: onOpenProfile,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _DrawerTile(
              palette: palette,
              icon: Icons.logout_rounded,
              title: 'Logout',
              onTap: onLogout,
            ),
          ],
        ),
      ),
    );
  }
}

class _LearnerHomeWebAside extends StatelessWidget {
  const _LearnerHomeWebAside({
    required this.palette,
    required this.onOpenCourses,
    required this.onOpenBooking,
    required this.onOpenMail,
    required this.onOpenReminders,
  });

  final _HomePalette palette;
  final VoidCallback onOpenCourses;
  final VoidCallback onOpenBooking;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenReminders;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: Container(
        margin: const EdgeInsets.fromLTRB(0, 6, 8, 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.border.withValues(alpha: 0.9)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quick Access',
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            _DrawerTile(
              palette: palette,
              icon: Icons.menu_book_rounded,
              title: 'Open Courses',
              onTap: onOpenCourses,
            ),
            _DrawerTile(
              palette: palette,
              icon: Icons.event_available_rounded,
              title: 'Open Booking',
              onTap: onOpenBooking,
            ),
            _DrawerTile(
              palette: palette,
              icon: Icons.mail_rounded,
              title: 'Open Mail',
              onTap: onOpenMail,
            ),
            _DrawerTile(
              palette: palette,
              icon: Icons.notifications_active_rounded,
              title: 'Open Reminders',
              onTap: onOpenReminders,
            ),
            const Spacer(),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.soft.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'Desktop mode keeps tools pinned for faster navigation.',
                style: TextStyle(
                  color: palette.text.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
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
    required this.displayNameFuture,
    required this.profilePhotoFuture,
    required this.coursesTileKey,
    required this.galleryTileKey,
    required this.gamesTileKey,
    required this.coachTileKey,
    required this.storiesTileKey,
    required this.profileTileKey,
    required this.mailTileKey,
    required this.regulationsTileKey,
    required this.themeTileKey,
    required this.logoutButtonKey,
    required this.onOpenProfile,
    required this.onOpenMail,
    required this.onOpenCourses,
    required this.onOpenGallery,
    required this.onOpenStories,
    required this.onOpenGames,
    required this.onOpenStudyCoach,
    required this.onOpenRegulations,
    required this.onOpenThemeSettings,
    required this.onLogout,
  });

  final _HomePalette palette;
  final Future<String>? displayNameFuture;
  final Future<String>? profilePhotoFuture;
  final GlobalKey coursesTileKey;
  final GlobalKey galleryTileKey;
  final GlobalKey gamesTileKey;
  final GlobalKey coachTileKey;
  final GlobalKey storiesTileKey;
  final GlobalKey profileTileKey;
  final GlobalKey mailTileKey;
  final GlobalKey regulationsTileKey;
  final GlobalKey themeTileKey;
  final GlobalKey logoutButtonKey;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenMail;
  final VoidCallback onOpenCourses;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenStories;
  final VoidCallback onOpenGames;
  final VoidCallback onOpenStudyCoach;
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
              child: FutureBuilder<String>(
                future: profilePhotoFuture,
                builder: (context, photoSnap) {
                  final profilePhotoUrl = (photoSnap.data ?? '').trim();

                  return FutureBuilder<String>(
                    future: displayNameFuture,
                    builder: (context, nameSnap) {
                      final displayName = (nameSnap.data ?? 'Learner').trim();

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white24,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.35),
                                width: 2,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: profilePhotoUrl.isNotEmpty
                                ? Image.network(
                                    profilePhotoUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.person_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  )
                                : const Icon(
                                    Icons.person_rounded,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            displayName.isNotEmpty ? displayName : 'Learner',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Learner Menu',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: [
                  _DrawerTile(
                    targetKey: coursesTileKey,
                    palette: palette,
                    icon: Icons.menu_book_rounded,
                    title: 'My Courses',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenCourses();
                    },
                  ),
                  _DrawerTile(
                    targetKey: storiesTileKey,
                    palette: palette,
                    icon: Icons.auto_stories_rounded,
                    title: 'Stories',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenStories();
                    },
                  ),
                  _DrawerTile(
                    targetKey: galleryTileKey,
                    palette: palette,
                    icon: Icons.photo_library_rounded,
                    title: 'Gallery',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenGallery();
                    },
                  ),
                  _DrawerTile(
                    targetKey: gamesTileKey,
                    palette: palette,
                    icon: Icons.sports_esports_rounded,
                    title: 'Games',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenGames();
                    },
                  ),
                  _DrawerTile(
                    targetKey: coachTileKey,
                    palette: palette,
                    icon: Icons.psychology_alt_rounded,
                    title: 'Study Coach',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenStudyCoach();
                    },
                  ),

                  _DrawerTile(
                    targetKey: mailTileKey,
                    palette: palette,
                    icon: Icons.mail_rounded,
                    title: 'Mail',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenMail();
                    },
                  ),

                  _DrawerTile(
                    targetKey: profileTileKey,
                    palette: palette,
                    icon: Icons.person_rounded,
                    title: 'Profile',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenProfile();
                    },
                  ),
                  _DrawerTile(
                    targetKey: regulationsTileKey,
                    palette: palette,
                    icon: Icons.policy_rounded,
                    title: 'Regulations',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenRegulations();
                    },
                  ),
                  _DrawerTile(
                    targetKey: themeTileKey,
                    palette: palette,
                    icon: Icons.palette_rounded,
                    title: 'Theme Settings',
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
                  key: logoutButtonKey,
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
    this.targetKey,
  });

  final _HomePalette palette;
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final GlobalKey? targetKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: KeyedSubtree(
        key: targetKey,
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
                border: Border.all(
                  color: palette.border.withValues(alpha: 0.85),
                ),
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
              color: selected
                  ? preview1
                  : palette.border.withValues(alpha: 0.9),
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
                        color: palette.text.withValues(alpha: 0.62),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
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
