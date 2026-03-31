import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../shared/first_login_agreement.dart';
import '../shared/learner_tour_guide.dart';
import '../shared/app_tour_guide.dart' show AppTourHighlightShape;
import '../shared/course_join_rules.dart';

class LearnerHome extends StatefulWidget {
  const LearnerHome({super.key});

  @override
  State<LearnerHome> createState() => _LearnerHomeState();
}

class _LearnerHomeState extends State<LearnerHome> {
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
  final GlobalKey _drawerRestartTourKey = GlobalKey();
  final GlobalKey _drawerLogoutKey = GlobalKey();
  final GlobalKey _dashboardHomeworkCardKey = GlobalKey();
  final GlobalKey _dashboardBookingCardKey = GlobalKey();
  final GlobalKey _dashboardCoursesListKey = GlobalKey();

  bool _drawerTourAttempted = false;
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  Future<String>? _displayNameFuture;
  Future<String>? _profilePhotoFuture;

  static const List<LearnerTourHint> _quickStartHints = [
    LearnerTourHint(
      title: 'مرحبًا بك',
      line: 'هذه جولة تعريفية موجزة تساعدك على فهم آلية استخدام التطبيق.',
      highlightShape: AppTourHighlightShape.fullscreen,
    ),
    LearnerTourHint(
      title: 'الشاشة الرئيسية للمتعلم',
      line:
          'تبدأ الجولة من هذه الشاشة لمتابعة الدورات والحجوزات والواجبات والتذكيرات.',
      highlightShape: AppTourHighlightShape.fullscreen,
    ),
    LearnerTourHint(
      title: 'القائمة الجانبية',
      line: 'استخدم زر القائمة للانتقال المنظم بين جميع صفحات المتعلم.',
    ),
    LearnerTourHint(
      title: 'إعادة الجولة',
      line: 'يمكنك إعادة الجولة لاحقًا من القائمة الجانبية في أي وقت.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _displayNameFuture = _myDisplayName();
    _profilePhotoFuture = _myProfilePhoto();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FirstLoginAgreement.ensureAccepted(context, roleKey: 'learner');
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

  bool _hasTarget(GlobalKey key) => key.currentContext != null;

  List<LearnerTourHint> _homeScreenHints({bool onlyVisibleTargets = false}) {
    final hints = <LearnerTourHint>[
      const LearnerTourHint(
        title: 'الشاشة الرئيسية للمتعلم',
        line:
            'تمثل هذه الشاشة نقطة البداية لمتابعة الواجبات والحجوزات والتقدم الدراسي بصورة منظمة.',
        highlightShape: AppTourHighlightShape.fullscreen,
      ),
    ];

    if (!onlyVisibleTargets || _hasTarget(_menuIconKey)) {
      hints.add(
        LearnerTourHint(
          title: 'زر القائمة',
          line: 'يؤدي هذا الزر إلى فتح القائمة الجانبية للتنقل بين الصفحات.',
          targetKey: _menuIconKey,
          highlightShape: AppTourHighlightShape.roundedRectangle,
          showFinger: false,
        ),
      );
    }

    return hints;
  }

  List<LearnerTourHint> _homeDashboardHints({bool onlyVisibleTargets = false}) {
    final hints = <LearnerTourHint>[];

    if (!onlyVisibleTargets || _hasTarget(_dashboardHomeworkCardKey)) {
      hints.add(
        LearnerTourHint(
          title: 'بطاقة الواجبات',
          line: 'تُعرض في هذه البطاقة الواجبات غير المنجزة مع تفاصيلها.',
          targetKey: _dashboardHomeworkCardKey,
          highlightShape: AppTourHighlightShape.roundedRectangle,
        ),
      );
    }

    if (!onlyVisibleTargets || _hasTarget(_dashboardBookingCardKey)) {
      hints.add(
        LearnerTourHint(
          title: 'بطاقة الحجز',
          line: 'تفتح هذه البطاقة شاشة حجز الحصص المقبلة.',
          targetKey: _dashboardBookingCardKey,
          highlightShape: AppTourHighlightShape.roundedRectangle,
        ),
      );
    }

    if (!onlyVisibleTargets || _hasTarget(_dashboardCoursesListKey)) {
      hints.add(
        LearnerTourHint(
          title: 'قائمة الدورات',
          line: 'تُظهر هذه القائمة تقدمك في كل دورة وتتيح فتح تفاصيلها.',
          targetKey: _dashboardCoursesListKey,
          highlightShape: AppTourHighlightShape.roundedRectangle,
        ),
      );
    }

    return hints;
  }

  List<LearnerTourHint> _drawerMenuHints({bool onlyVisibleTargets = false}) {
    final hints = <LearnerTourHint>[];

    void addIfVisible(LearnerTourHint hint) {
      if (!onlyVisibleTargets ||
          hint.targetKey == null ||
          (hint.targetKey?.currentContext != null)) {
        hints.add(hint);
      }
    }

    addIfVisible(
      LearnerTourHint(
        title: 'دوراتي',
        line: 'من هذا الخيار يمكنك الوصول إلى جميع دوراتك بسهولة.',
        targetKey: _drawerCoursesKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'القصص',
        line: 'يحتوي هذا القسم على القصص للقراءة والاستماع والمشاهدة.',
        targetKey: _drawerStoriesKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'المعرض',
        line: 'من هنا يمكنك مشاهدة صورك وملفاتك في المعرض.',
        targetKey: _drawerGalleryKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'الألعاب',
        line: 'يخصص هذا القسم للتدريب التعليمي بطريقة تفاعلية.',
        targetKey: _drawerGamesKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'مدرب الدراسة',
        line: 'يساعدك هذا القسم في تنظيم الأهداف والخطة الأسبوعية.',
        targetKey: _drawerCoachKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'البريد',
        line: 'يتيح لك هذا القسم متابعة الرسائل والمحادثات مع المعلمين.',
        targetKey: _drawerMailKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'الملف الشخصي',
        line: 'من هذا القسم يمكنك مراجعة بياناتك الشخصية وصورتك.',
        targetKey: _drawerProfileKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'اللوائح',
        line: 'راجع من هنا لوائح الأكاديمية وسياساتها المعتمدة.',
        targetKey: _drawerRegulationsKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'إعدادات المظهر',
        line: 'يمكنك تعديل المظهر العام للتطبيق من هذا القسم.',
        targetKey: _drawerThemeKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'إعادة الجولة',
        line: 'استخدم هذا الخيار لإعادة عرض الإرشادات التعليمية.',
        targetKey: _drawerRestartTourKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );
    addIfVisible(
      LearnerTourHint(
        title: 'تسجيل الخروج',
        line: 'استخدم هذا الزر لتسجيل الخروج من الحساب بأمان.',
        targetKey: _drawerLogoutKey,
        highlightShape: AppTourHighlightShape.roundedRectangle,
      ),
    );

    return hints;
  }

  void _pushScreen(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _openStoriesScreen() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LearnerStoriesScreen()));
  }

  Future<void> _refreshShell() async {
    setState(() {
      _displayNameFuture = _myDisplayName();
      _profilePhotoFuture = _myProfilePhoto();
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _maybeStartDrawerTour() async {
    if (_drawerTourAttempted || !mounted) return;
    _drawerTourAttempted = true;

    final shouldShow = await LearnerTourGuide.shouldShow('learner_drawer_menu');
    if (!shouldShow || !mounted) return;

    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    _scaffoldKey.currentState?.openDrawer();

    await _waitForDrawerReady();
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;

    final hints = _drawerMenuHints(onlyVisibleTargets: true);
    if (hints.isEmpty) return;

    await LearnerTourGuide.maybeStart(
      context,
      screenId: 'learner_drawer_menu',
      hints: hints,
    );
  }

  Future<void> _waitForDrawerReady() async {
    for (var i = 0; i < 20; i++) {
      if (!mounted) return;
      final drawerOpen = _scaffoldKey.currentState?.isDrawerOpen ?? false;
      final hasFirstTarget = _drawerCoursesKey.currentContext != null;
      if (drawerOpen && hasFirstTarget) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
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

    try {
      await appThemeController.resetToDefault();
    } catch (_) {}

    await FirebaseAuth.instance.signOut();

    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
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

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final isWebDashboard = kIsWeb && MediaQuery.of(context).size.width >= 1100;

    LearnerTourGuide.schedule(
      context,
      screenId: 'learner_quick_start',
      hints: _quickStartHints,
      isQuickStart: true,
    );

    LearnerTourGuide.schedule(
      context,
      screenId: 'learner_home',
      hints: _homeScreenHints(onlyVisibleTargets: true),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeStartDrawerTour();
    });

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: p.appBg,
      drawer: _LearnerDrawer(
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
        restartTourTileKey: _drawerRestartTourKey,
        logoutButtonKey: _drawerLogoutKey,
        onOpenProfile: () => _pushScreen(const LearnerProfileScreen()),
        onOpenMail: () => _pushScreen(LearnerMailScreen()),
        onOpenCourses: () => _pushScreen(const LearnerCoursesScreen()),
        onOpenGallery: () => _pushScreen(const LearnerGalleryScreen()),
        onOpenStories: _openStoriesScreen,
        onOpenGames: () => _pushScreen(const LearnerGamesScreen()),
        onOpenStudyCoach: () => _pushScreen(const LearnerStudyCoachScreen()),
        onOpenRegulations: () => _pushScreen(const LearnerRegulationsScreen()),
        onOpenThemeSettings: _openThemeSheet,
        onRestartTour: () async {
          await LearnerTourGuide.resetAll();
          if (!mounted || !context.mounted) return;
          final homeHints = _homeScreenHints(onlyVisibleTargets: true);
          final dashboardHints = _homeDashboardHints(onlyVisibleTargets: true);
          await LearnerTourGuide.startNow(
            context,
            screenId: 'learner_quick_start',
            hints: _quickStartHints,
            isQuickStart: true,
          );
          if (!mounted || !context.mounted) return;
          if (homeHints.isNotEmpty) {
            await LearnerTourGuide.startNow(
              context,
              screenId: 'learner_home',
              hints: homeHints,
            );
          }
          if (!mounted || !context.mounted) return;
          if (dashboardHints.isNotEmpty) {
            await LearnerTourGuide.startNow(
              context,
              screenId: 'learner_home_dashboard',
              hints: dashboardHints,
            );
          }
          _drawerTourAttempted = false;
          if (!mounted || !context.mounted) return;
          await _maybeStartDrawerTour();
        },
        onLogout: () => _logout(context),
      ),

      appBar: AppBar(
        toolbarHeight: isWebDashboard ? 74 : kToolbarHeight,
        backgroundColor: p.cardBg,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: p.cardBg,
        leading: IconButton(
          icon: Icon(Icons.menu_rounded, key: _menuIconKey, color: p.primary),
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
          IconButton(
            icon: Icon(Icons.help_outline_rounded, color: p.primary),
            tooltip: 'Guide',
            onPressed: () async {
              final homeHints = _homeScreenHints(onlyVisibleTargets: true);
              await LearnerTourGuide.startNow(
                context,
                screenId: 'learner_home',
                hints: homeHints,
              );
              if (!mounted) return;
              _drawerTourAttempted = false;
              await _maybeStartDrawerTour();
            },
          ),
          IconButton(
            icon: Icon(Icons.logout_rounded, color: p.accent),
            onPressed: () => _logout(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshShell,
        child: WatermarkBackground(
          child: _LearnerDashboardLite(
            homeworkCardKey: _dashboardHomeworkCardKey,
            bookingCardKey: _dashboardBookingCardKey,
            coursesListKey: _dashboardCoursesListKey,
          ),
        ),
      ),
    );
  }
}

class _LearnerDashboardLite extends StatefulWidget {
  const _LearnerDashboardLite({
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
  Timer? _progressRefreshTimer;

  @override
  void initState() {
    super.initState();
    _progressFuture = _loadProgressItems();
    _progressRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted) return;
      setState(() {
        _progressFuture = _loadProgressItems();
      });
    });
  }

  @override
  void dispose() {
    _progressRefreshTimer?.cancel();
    super.dispose();
  }

  bool _hasTarget(GlobalKey key) => key.currentContext != null;

  List<LearnerTourHint> _dashboardHints({bool onlyVisibleTargets = false}) {
    final hints = <LearnerTourHint>[];

    if (!onlyVisibleTargets || _hasTarget(widget.homeworkCardKey)) {
      hints.add(
        LearnerTourHint(
          title: 'بطاقة الواجبات',
          line: 'تُعرض في هذه البطاقة الواجبات غير المنجزة مع تفاصيلها.',
          targetKey: widget.homeworkCardKey,
          highlightShape: AppTourHighlightShape.roundedRectangle,
        ),
      );
    }

    if (!onlyVisibleTargets || _hasTarget(widget.bookingCardKey)) {
      hints.add(
        LearnerTourHint(
          title: 'بطاقة الحجز',
          line: 'تفتح هذه البطاقة شاشة حجز الحصص المقبلة.',
          targetKey: widget.bookingCardKey,
          highlightShape: AppTourHighlightShape.roundedRectangle,
        ),
      );
    }

    if (!onlyVisibleTargets || _hasTarget(widget.coursesListKey)) {
      hints.add(
        LearnerTourHint(
          title: 'قائمة الدورات',
          line: 'تُظهر هذه القائمة تقدمك في كل دورة وتتيح فتح تفاصيلها.',
          targetKey: widget.coursesListKey,
          highlightShape: AppTourHighlightShape.roundedRectangle,
        ),
      );
    }

    return hints;
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

  Future<Map<String, String>> _loadLearnerHeaderData() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      return {'name': 'Learner', 'profilePhoto': ''};
    }

    try {
      final snap = await _db.child('users/$uid').get();
      final v = snap.value;

      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        final profilePhoto = (m['profile_photo'] ?? '').toString().trim();

        return {
          'name': full.isNotEmpty ? full : 'Learner',
          'profilePhoto': profilePhoto,
        };
      }
    } catch (_) {}

    return {'name': 'Learner', 'profilePhoto': ''};
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
    final isRecorded = variantKey == 'recorded';

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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LearnerCoursesScreen(initialCourseKey: courseKey),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    final p = palette;

    LearnerTourGuide.schedule(
      context,
      screenId: 'learner_home_dashboard',
      hints: _dashboardHints(onlyVisibleTargets: true),
    );

    if (uid.isEmpty) {
      return Center(
        child: Text(
          'Not logged in.',
          style: TextStyle(color: p.text, fontWeight: FontWeight.w800),
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
          const SizedBox(height: 8),

          _SectionTitle(palette: p, title: 'Homework • Reminders • Mail'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _LearnerHomeworkHomeCard(
                  compact: true,
                  targetKey: widget.homeworkCardKey,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(child: _RemindersHomeCard(compact: true)),
              const SizedBox(width: 8),
              const Expanded(child: _LearnerMailHomeCard(compact: true)),
            ],
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
                  _SectionTitle(palette: p, title: 'Booking'),
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
                    final textScale = MediaQuery.textScalerOf(context).scale(1);
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
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
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
                          onTap: () =>
                              _openCoursesScreen(courseKey: items[i].courseKey),
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

class _LearnerHeroCard extends StatelessWidget {
  const _LearnerHeroCard({
    required this.palette,
    required this.learnerName,
    required this.profilePhotoUrl,
    required this.onOpenCourses,
  });

  final _HomePalette palette;
  final String learnerName;
  final String profilePhotoUrl;
  final VoidCallback onOpenCourses;

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
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
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

          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome back',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.80),
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
      color: Colors.white.withValues(alpha: 0.12),
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
    switch (variantKey) {
      case 'recorded':
        return palette.accent;
      case 'flexible':
      case 'online':
        return palette.primary;
      case 'private':
      case 'live':
        return Color.alphaBlend(
          palette.accent.withValues(alpha: 0.35),
          palette.primary,
        );
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return Color.alphaBlend(
          palette.primary.withValues(alpha: 0.18),
          palette.accent,
        );
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
                      ? palette.primary.withValues(alpha: 0.28)
                      : palette.border.withValues(alpha: 0.85),
                ),
                boxShadow: [
                  BoxShadow(
                    color: hasProgress
                        ? palette.primary.withValues(alpha: 0.08)
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
    final track = palette.soft.withValues(alpha: 0.85);

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
              border: Border.all(color: palette.border.withValues(alpha: 0.8)),
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

  Future<_NextBooking?>? _nextBookingFuture;
  Future<_MeetInfo?>? _meetInfoFuture;
  String? _meetInfoKey;

  Timer? _ticker;
  Timer? _nextBookingRefreshTimer;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseScale;

  @override
  void initState() {
    super.initState();
    _nextBookingFuture = _findMyNextBookingAcrossCourses();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
    _nextBookingRefreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!mounted) return;
      setState(() {
        _nextBookingFuture = _findMyNextBookingAcrossCourses();
        _meetInfoFuture = null;
        _meetInfoKey = null;
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

  Future<_NextBooking?> _findMyNextBookingAcrossCourses() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return null;

    final courses = await _loadJoinableCourses();
    if (courses.isEmpty) return null;

    final now = DateTime.now();
    _NextBooking? best;

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

        final bestNow = best;
        if (bestNow == null || candidate.start.isBefore(bestNow.start)) {
          best = candidate;
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

          void considerCandidate(
            Map<dynamic, dynamic> slotLike,
            String teacherKey,
          ) {
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

            final bestNow = best;
            if (bestNow == null || candidate.start.isBefore(bestNow.start)) {
              best = candidate;
            }
          }

          // Flat legacy shape: /{day}/{time} => {learners:{...}, ...}
          if (sm['learners'] is Map) {
            considerCandidate(sm, '');
            continue;
          }

          // Nested shape: /{day}/{time}/{teacherId} => {learners:{...}, ...}
          for (final te in sm.entries) {
            final teacherKey = te.key.toString();
            final teacherNode = te.value;
            if (teacherNode is! Map) continue;
            considerCandidate(
              Map<dynamic, dynamic>.from(teacherNode),
              teacherKey,
            );
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

      final ref = _db.child(
        'booking_progress/$learnerUid/${next.courseId}/flexible_attendance/$bKey',
      );

      final existing = await ref.get();
      if (existing.exists && existing.value != null) return;

      final taughtItems = (sessionNo > 0)
          ? [
              {'type': 'syllabus', 'sessionNumber': sessionNo},
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
        FutureBuilder<_NextBooking?>(
          future: _nextBookingFuture,
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

            final currentMeetInfoKey =
                '${next.source}|${next.teacherId}|${next.courseId}|${next.classId}';
            if (_meetInfoKey != currentMeetInfoKey || _meetInfoFuture == null) {
              _meetInfoKey = currentMeetInfoKey;
              _meetInfoFuture = _loadMeetInfo(next: next);
            }

            return FutureBuilder<_MeetInfo?>(
              future: _meetInfoFuture,
              builder: (context, ms) {
                final meet = ms.data;
                final timeStr = '${_friendlyDate(next.start)} • ${next.time}';
                final teacherStr = next.teacherName;

                final now = DateTime.now();
                final openFrom = next.start;
                final safeDuration =
                    meet?.durationMinutes ?? next.durationMinutes;
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

                final canJoin = _canJoinNow(
                  next.start,
                  meet?.durationMinutes ?? 60,
                );

                final statusColor = _statusColor(
                  canJoin: canJoin,
                  beforeOpen: beforeOpen,
                  closesIn: closesIn,
                  p: p,
                );

                final urgency = _sessionUrgencyProgress(next.start);
                final urgentRed = _deepRedByUrgency(urgency);
                final upcomingColor = _upcomingCountdownColor(
                  urgency: urgency,
                  p: p,
                );
                final idleColor = beforeOpen ? upcomingColor : urgentRed;

                if (meet == null) {
                  _pulseController.stop();

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
                            Icon(
                              Icons.upcoming_rounded,
                              size: 18,
                              color: p.accent,
                            ),
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
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.85),
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
                            canJoin
                                ? Icons.video_call_rounded
                                : Icons.upcoming_rounded,
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
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: canJoin
                              ? statusColor.withValues(alpha: 0.12)
                              : idleColor.withValues(
                                  alpha: 0.06 + (urgency * 0.10),
                                ),
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
                                      FirebaseAuth.instance.currentUser?.uid ??
                                      '';

                                  await _openExternalUrl(context, meet.meetUrl);

                                  if (uid.isNotEmpty &&
                                      next.source == 'flexible') {
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
          },
        ),
      ],
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

Future<void> _openBookingCoursePicker(BuildContext context) async {
  final me = FirebaseAuth.instance.currentUser;
  final uid = me?.uid ?? '';
  if (uid.isEmpty) {
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
  final me = FirebaseAuth.instance.currentUser;
  final uid = me?.uid ?? '';
  if (uid.isEmpty) {
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
            child: Container(
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
              padding: EdgeInsets.all(compact ? 12 : 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: compact ? 40 : 46,
                        height: compact ? 40 : 46,
                        decoration: BoxDecoration(
                          color: p.soft,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: p.border.withValues(alpha: 0.85),
                          ),
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
                      color: p.text.withValues(alpha: 0.62),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
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
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            padding: EdgeInsets.all(compact ? 12 : 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: compact ? 40 : 46,
                      height: compact ? 40 : 46,
                      decoration: BoxDecoration(
                        color: p.soft,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.85),
                        ),
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
                SizedBox(height: compact ? 12 : 18),
                Text(
                  'Reminders',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: compact ? 14 : 16,
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
        int unread = 0;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          for (final vv in v.values) {
            if (vv is! Map) continue;
            final m = vv.map((k, x) => MapEntry(k.toString(), x));
            final dynamic n = m['unreadCount'];
            final count = (n is num) ? n.toInt() : int.tryParse('$n') ?? 0;
            unread += count;
          }
        }

        final subtitle = unread == 0 ? 'No unread ✅' : '$unread unread';

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LearnerMailScreen()),
            );
          },
          child: Container(
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
            padding: EdgeInsets.all(compact ? 12 : 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: compact ? 40 : 46,
                      height: compact ? 40 : 46,
                      decoration: BoxDecoration(
                        color: p.soft,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.85),
                        ),
                      ),
                      child: Icon(Icons.mail_rounded, color: p.primary),
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
                SizedBox(height: compact ? 12 : 18),
                Text(
                  'Mail',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: compact ? 14 : 16,
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
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const LearnerGalleryScreen()));
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

class _StudyCoachHomeCard extends StatelessWidget {
  const _StudyCoachHomeCard();

  @override
  Widget build(BuildContext context) {
    final p = _paletteFromTheme();

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const LearnerStudyCoachScreen()),
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
    required this.restartTourTileKey,
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
    required this.onRestartTour,
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
  final GlobalKey restartTourTileKey;
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
  final VoidCallback onRestartTour;
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
                    subtitle: 'Read, listen, and watch stories',
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
                    subtitle: 'Set goals, reminders, and track progress',
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
                    subtitle: 'Choose your app look',
                    onTap: () {
                      Navigator.of(context).pop();
                      onOpenThemeSettings();
                    },
                  ),
                  _DrawerTile(
                    targetKey: restartTourTileKey,
                    palette: palette,
                    icon: Icons.tour_rounded,
                    title: 'إعادة الجولة',
                    subtitle: 'إعادة عرض إرشادات التطبيق',
                    onTap: () {
                      Navigator.of(context).pop();
                      onRestartTour();
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
    this.subtitle = '',
    this.targetKey,
  });

  final _HomePalette palette;
  final IconData icon;
  final String title;
  final String subtitle;
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
