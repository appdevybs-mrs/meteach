import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../shared/human_error.dart';
import '../services/backend_api.dart';
import '../services/public_data_export_service.dart';
import 'admin_contract_screen.dart';
import 'admin_wages_screen.dart';
import 'admin_payments.dart';
import 'admin_courses.dart';
import 'admin_learners.dart';
import 'admin_mail_inbox_screen.dart';
import 'admin_staff.dart';
import 'admin_file_manager.dart';
import 'admin_instructions_screen.dart';
import 'admin_teacher_reminders_screen.dart';
import 'admin_classes.dart';
import 'admin_public_gallery_screen.dart';
import 'gallery_screen.dart';
import 'admin_public_preview.dart';
import 'admin_subscriptions.dart';
import 'admin_job_applications_screen.dart';
import 'admin_shared_files_screen.dart';
import '../shared/session_manager.dart';
import 'admin_booking.dart';
import 'admin_teacher_session_count_screen.dart';
import 'admin_attendance_overview_screen.dart';
import 'admin_timetable_screen.dart';
import 'admin_teacher_availability_overview_screen.dart';
import '../shared/app_feedback.dart';
import '../shared/offline_action_guard.dart';
import '../shared/offline_notice_banner.dart';
import '../shared/app_theme.dart';
import '../shared/icon_theme.dart';
import '../shared/payment_status.dart';
import '../shared/admin_web_layout.dart';
import '../shared/web_page_frame.dart';
import '../services/website_mirror_backfill_service.dart';
import '../services/notification_counter_service.dart';
import '../services/fcm_service.dart';
import '../services/reminder_consistency_service.dart';
import 'admin_certificates.dart';
import 'admin_admin_todos_screen.dart';
import 'admin_course_reviews_screen.dart';
import 'admin_priority_alerts_screen.dart';
import 'admin_notification_audit_screen.dart';
import 'admin_activity_center_screen.dart';
import 'admin_vocab_words_lists_screen.dart';
import 'admin_window_access_screen.dart';
import 'admin_finance_screen.dart';
import '../services/window_access_service.dart';
import 'admin_payment_summary_sync_service.dart';
import 'admin_diary_screen.dart';
import 'admin_international_teachers_screen.dart';
import 'admin_graduates_map_screen.dart';
import 'admin_splash_screen.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  // ===== Brand / UI colors =====
  static const primaryBlue = Color(0xFF0E7C86);
  static const deepBlue = Color(0xFF135C7A);
  static const actionOrange = Color(0xFFBF5D39);
  static const mainText = Color(0xFF213038);
  static const appBg = Color(0xFFFAFCFF);
  static const cardBg = Color(0xFFFFFCF5);
  static const uiBorder = Color(0xFFD8CFC1);
  static const softText = Color(0xFF5E6B70);

  // vivid accents for cards
  static const accentBlue = Color(0xFF2563EB);
  static const accentTeal = Color(0xFF0D9488);
  static const accentPurple = Color(0xFF7C3AED);
  static const accentAmber = Color(0xFFD97706);
  static const accentSky = Color(0xFF0284C7);
  static const accentRose = Color(0xFFDC2626);
  static const accentIndigo = Color(0xFF4F46E5);
  static const accentSlate = Color(0xFF475569);
  static const accentCyan = Color(0xFF0891B2);
  static const accentGreen = Color(0xFF16A34A);

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  static const _prefsRoleKey = 'admin_home_role_mode_is_admin';
  static const _adminModePassword = '0808';
  int _lastBackPressMs = 0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _menuButtonKey = GlobalKey();
  final GlobalKey _cardsGridKey = GlobalKey();
  final GlobalKey _paymentsCardKey = GlobalKey();
  final GlobalKey _learnersCardKey = GlobalKey();
  final GlobalKey _sharedCardKey = GlobalKey();
  late final DatabaseReference _receptionistWindowAccessRef;
  StreamSubscription<DatabaseEvent>? _receptionistWindowAccessSub;

  bool _isAdminMode = true;
  bool _loadingRole = true;
  bool _loadingReceptionistWindows = true;
  String _homeSearch = '';
  int _learnerPaymentRefreshTick = 0;
  final TextEditingController _homeSearchController = TextEditingController();
  Map<String, bool> _receptionistWindowEnabled = const <String, bool>{};

  bool _allToolsExpanded = false;
  List<String> _pinnedCardTitles = [];
  static const _defaultPinnedCards = [
    'Learners',
    'Classes',
    'Payments',
    'Courses',
    'Online Booking',
    'Priority Alerts',
    'Admin Mail',
    'Subscriptions',
  ];
  static const _pinnedPrefKey = 'pinned_cards_';

  @override
  void initState() {
    super.initState();
    _receptionistWindowAccessRef = FirebaseDatabase.instance.ref(
      'appConfig/window_access/${AppWindowRole.admin}',
    );
    _homeSearchController.text = _homeSearch;
    _loadSavedRoleMode();
    unawaited(_loadPinnedCards());
    unawaited(_loadReceptionistWindowAccess());
    _listenToReceptionistWindowAccess();
    unawaited(WebsiteMirrorBackfillService.runOnceForAdminLogin());
    unawaited(AdminPaymentSummarySyncService.runForAdminLogin());
  }

  @override
  void dispose() {
    _receptionistWindowAccessSub?.cancel();
    _homeSearchController.dispose();
    super.dispose();
  }

  void _listenToReceptionistWindowAccess() {
    _receptionistWindowAccessSub?.cancel();
    _receptionistWindowAccessSub = _receptionistWindowAccessRef.onValue.listen((
      _,
    ) {
      unawaited(_loadReceptionistWindowAccess());
    });
  }

  Future<void> _loadSavedRoleMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefsRoleKey);

      if (!mounted) return;
      setState(() {
        _isAdminMode = saved ?? true; // default = Admin
        _loadingRole = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isAdminMode = true;
        _loadingRole = false;
      });
    }
  }

  Future<void> _loadPinnedCards() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_pinnedPrefKey$uid');
      if (raw != null) {
        final decoded = json.decode(raw) as List<dynamic>;
        _pinnedCardTitles = decoded.cast<String>();
      } else {
        _pinnedCardTitles = List.from(_defaultPinnedCards);
      }
    } catch (_) {
      _pinnedCardTitles = List.from(_defaultPinnedCards);
    }
  }

  Future<void> _savePinnedCards() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_pinnedPrefKey$uid',
        json.encode(_pinnedCardTitles),
      );
    } catch (_) {}
  }

  void _togglePin(String title) {
    setState(() {
      if (_pinnedCardTitles.contains(title)) {
        _pinnedCardTitles.remove(title);
      } else {
        _pinnedCardTitles.add(title);
      }
    });
    unawaited(_savePinnedCards());
  }

  Future<void> _setRoleMode(bool isAdmin) async {
    setState(() {
      _isAdminMode = isAdmin;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsRoleKey, isAdmin);
    } catch (_) {}
  }

  Future<void> _refreshHome() async {
    if (!OfflineActionGuard.ensureOnline(context)) return;
    await _loadReceptionistWindowAccess();
    if (!mounted) return;
    setState(() {
      _learnerPaymentRefreshTick++;
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _loadReceptionistWindowAccess() async {
    try {
      final states = await WindowAccessService.instance.loadStatesForRole(
        AppWindowRole.admin,
      );
      if (!mounted) return;
      setState(() {
        _receptionistWindowEnabled = {
          for (final state in states) state.definition.key: state.enabled,
        };
        _loadingReceptionistWindows = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _receptionistWindowEnabled = const <String, bool>{};
        _loadingReceptionistWindows = false;
      });
    }
  }

  Future<bool?> _promptForAdminPassword() async {
    final password = await showDialog<String?>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => const _AdminPasswordDialog(),
    );
    if (password == null) return null;
    return password.trim() == _adminModePassword;
  }

  Future<void> _handleSelectAdmin() async {
    Navigator.of(context).pop();

    // Let the drawer route fully settle before pushing the password dialog.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;

    if (!_isAdminMode) {
      final unlocked = await _promptForAdminPassword();
      if (!mounted) return;
      if (unlocked == null) return;
      if (!unlocked) {
        AppToast.show(context, 'Wrong password.', type: AppToastType.error);
        return;
      }
    }

    await _setRoleMode(true);
  }

  void _openAdminWindow(String windowKey, VoidCallback onAllowed) {
    if (!OfflineActionGuard.ensureOnline(context)) return;

    if (_isAdminMode) {
      onAllowed();
      return;
    }

    unawaited(
      WindowAccessService.instance.guardOpen(
        context: context,
        role: AppWindowRole.admin,
        windowKey: windowKey,
        onAllowed: onAllowed,
      ),
    );
  }

  Future<void> _exportPublicData(BuildContext context) async {
    if (!OfflineActionGuard.ensureOnline(context)) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Export Public Data'),
        content: const Text(
          'This will sync courses and teacher profiles to the public website nodes.\n\nContinue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Export'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    try {
      final counts = await PublicDataExportService.exportAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exported ${counts['courses']} courses, '
            '${counts['teachers']} teachers '
            '(${counts['writes']} writes)',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _logout(BuildContext context) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    await AppLoading.run(
      context,
      () async {
        await SessionManager.stopListening();
        await FCMService.clearDeviceOnLogout(userId);
      },
      message: 'Logging out...',
      isLogout: true,
    );

    await FirebaseAuth.instance.signOut();

    unawaited(() async {
      try {
        await appThemeController.resetToDefault();
      } catch (_) {}
    }());
  }

  Color get _screenBg =>
      _isAdminMode ? const Color(0xFFFAFCFF) : const Color(0xFFFFFFFF);

  String get _screenTitle =>
      _isAdminMode ? 'Admin Dashboard' : 'Reception Desk';

  bool _isWindowVisibleForCurrentMode(String windowKey) {
    if (_isAdminMode) return true;
    if (_loadingReceptionistWindows) return false;
    return _receptionistWindowEnabled[windowKey] ?? true;
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    final width = MediaQuery.of(context).size.width;
    final isMobileDashboard = width < 760;
    final crossAxisCount = width >= 1440
        ? 5
        : (width >= 1160 ? 4 : (width >= 760 ? 3 : 2));
    final double cardRatio;
    if (crossAxisCount >= 5) {
      cardRatio = _isAdminMode ? 1.48 : 1.54;
    } else if (crossAxisCount >= 4) {
      cardRatio = _isAdminMode ? 1.40 : 1.46;
    } else if (crossAxisCount == 3) {
      cardRatio = _isAdminMode ? 1.20 : 1.26;
    } else {
      cardRatio = width >= 420 ? 1.14 : 1.04;
    }
    final gridGap = width >= 1200
        ? 14.0
        : (width >= 900 ? 12.0 : (isMobileDashboard ? 8.0 : 10.0));

    _HomeCardItem card(
      String title, {
      required Widget child,
      String? windowKey,
      bool adminOnly = false,
    }) {
      final isPinned = _pinnedCardTitles.contains(title);
      return _HomeCardItem(
        title: title,
        child: Stack(
          children: [
            child,
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _togglePin(title),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: isPinned
                          ? Colors.blue.withValues(alpha: 0.9)
                          : Colors.black.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.push_pin_rounded,
                      size: 14,
                      color: isPinned ? Colors.white : Colors.black54,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        windowKey: windowKey,
        adminOnly: adminOnly,
      );
    }

    final allCards = <_HomeCardItem>[
      card(
        'Learners',
        windowKey: AppWindowKeys.adminLearners,
        child: KeyedSubtree(
          key: _learnersCardKey,
          child: _LearnersDashCard(
            refreshTick: _learnerPaymentRefreshTick,
            isReceptionistStyle: !_isAdminMode,
            onTap: () => _openAdminWindow(
              AppWindowKeys.adminLearners,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
              ),
            ),
          ),
        ),
      ),
      card(
        'Classes',
        windowKey: AppWindowKeys.adminClasses,
        child: _ClassesDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminClasses,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminClassesScreen()),
            ),
          ),
        ),
      ),
      card(
        'Payments',
        windowKey: AppWindowKeys.adminPayments,
        child: KeyedSubtree(
          key: _paymentsCardKey,
          child: _PaymentsAttentionDashCard(
            isReceptionistStyle: !_isAdminMode,
            onTap: () => _openAdminWindow(
              AppWindowKeys.adminPayments,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
              ),
            ),
          ),
        ),
      ),
      card(
        'Finance',
        windowKey: AppWindowKeys.adminFinance,
        child: _DashCard(
          title: 'Finance',
          icon: AdminIcons.finance,
          color: AdminHome.accentAmber,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminFinance,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminFinanceScreen()),
            ),
          ),
        ),
      ),
      card(
        'Schedule',
        windowKey: AppWindowKeys.adminSchedule,
        child: _DashCard(
          title: 'Schedule',
          icon: Icons.calendar_view_week_rounded,
          color: AdminHome.accentTeal,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminSchedule,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminTimetableScreen()),
            ),
          ),
        ),
      ),
      card(
        'Attendance',
        windowKey: AppWindowKeys.adminAttendance,
        child: _DashCard(
          title: 'Attendance',
          icon: AdminIcons.attendance,
          color: AdminHome.accentIndigo,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminAttendance,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminAttendanceOverviewScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Courses',
        windowKey: AppWindowKeys.adminCourses,
        child: _DashCard(
          title: 'Courses',
          icon: Icons.menu_book_rounded,
          color: AdminHome.primaryBlue,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminCourses,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminCoursesScreen()),
            ),
          ),
        ),
      ),
      card(
        'Study Coach',
        windowKey: AppWindowKeys.adminVocabLists,
        child: _DashCard(
          title: 'Study Coach',
          icon: AdminIcons.studyCoach,
          color: AdminHome.accentCyan,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminVocabLists,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminVocabWordsListsScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Course Reviews',
        windowKey: AppWindowKeys.adminCourseReviews,
        child: _CourseFeedbackDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminCourseReviews,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminCourseReviewsScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Online Booking',
        windowKey: AppWindowKeys.adminOnlineBooking,
        child: _AdminOnlineBookingDashCard(isReceptionistStyle: !_isAdminMode),
      ),
      card(
        'Teacher Sessions',
        windowKey: AppWindowKeys.adminTeacherSessionCount,
        child: _DashCard(
          title: 'Teacher Sessions',
          icon: Icons.person_search_rounded,
          color: AdminHome.accentGreen,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminTeacherSessionCount,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminTeacherSessionCountScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Reminders',
        windowKey: AppWindowKeys.adminReminders,
        child: _RemindersDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminReminders,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminTeacherRemindersScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Priority Alerts',
        windowKey: AppWindowKeys.adminPriorityAlerts,
        child: _PriorityAlertsDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminPriorityAlerts,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminPriorityAlertsScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Activity Center',
        windowKey: AppWindowKeys.adminActivityCenter,
        child: _DashCard(
          title: 'Activity Center',
          icon: AdminIcons.activityCenter,
          color: AdminHome.accentIndigo,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminActivityCenter,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminActivityCenterScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Notification Audit',
        windowKey: AppWindowKeys.adminNotificationAudit,
        child: _DashCard(
          title: 'Notification Audit',
          icon: AdminIcons.notificationAudit,
          color: AdminHome.accentSky,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminNotificationAudit,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminNotificationAuditScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Staff',
        windowKey: AppWindowKeys.adminStaff,
        child: _StaffMailDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminStaff,
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AdminStaffScreen())),
          ),
        ),
      ),
      card(
        'International Teachers',
        child: _DashCard(
          title: 'International Teachers',
          icon: Icons.language_rounded,
          color: AdminHome.accentCyan,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminInternationalTeachersScreen(),
            ),
          ),
        ),
      ),
      card(
        'Admin Mail',
        windowKey: AppWindowKeys.adminMail,
        child: _AdminMailDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminMail,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminMailInboxScreen()),
            ),
          ),
        ),
      ),
      card(
        'Wages',
        windowKey: AppWindowKeys.adminWages,
        child: _WagesDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminWages,
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AdminWagesScreen())),
          ),
        ),
      ),
      card(
        'Teacher Availability',
        windowKey: AppWindowKeys.adminTeacherAvailability,
        child: _TeacherAvailabilityDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminTeacherAvailability,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AdminTeacherAvailabilityOverviewScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Subscriptions',
        windowKey: AppWindowKeys.adminSubscriptions,
        child: _SubscriptionsDashCard(isReceptionistStyle: !_isAdminMode),
      ),
      card(
        'Certificates',
        windowKey: AppWindowKeys.adminCertificates,
        child: _CertificatesDashCard(isReceptionistStyle: !_isAdminMode),
      ),
      card(
        'File Manager',
        windowKey: AppWindowKeys.adminFileManager,
        child: _DashCard(
          title: 'File Manager',
          icon: AdminIcons.fileManager,
          color: AdminHome.accentGreen,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminFileManager,
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AdminFileManager())),
          ),
        ),
      ),
      card(
        'Instructions',
        windowKey: AppWindowKeys.adminInstructions,
        child: _DashCard(
          title: 'Instructions',
          icon: AdminIcons.instructions,
          color: AdminHome.accentPurple,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminInstructions,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminInstructionsScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Shared Files',
        windowKey: AppWindowKeys.adminSharedFiles,
        child: KeyedSubtree(
          key: _sharedCardKey,
          child: _AdminSharedFilesDashCard(isReceptionistStyle: !_isAdminMode),
        ),
      ),
      card(
        'Public Gallery',
        windowKey: AppWindowKeys.adminPublicGallery,
        child: _PublicGalleryDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminPublicGallery,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminPublicGalleryScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Export Public Data',
        windowKey: AppWindowKeys.adminPublicDataExport,
        child: _DashCard(
          title: 'Export Public Data',
          icon: Icons.sync_rounded,
          color: AdminHome.accentAmber,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _exportPublicData(context),
        ),
      ),
      card(
        'Gallery',
        windowKey: AppWindowKeys.adminGallery,
        child: _DashGalleryCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminGallery,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminGalleryScreen()),
            ),
          ),
        ),
      ),
      card(
        'Splash Screen',
        windowKey: AppWindowKeys.adminSplashScreen,
        child: _DashCard(
          title: 'Splash Screen',
          icon: Icons.tv_rounded,
          color: AdminHome.accentAmber,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminSplashScreen,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminSplashScreen()),
            ),
          ),
        ),
      ),
      card(
        'Graduates Map',
        windowKey: AppWindowKeys.adminGraduatesMap,
        child: _DashCard(
          title: 'Graduates Map',
          icon: Icons.public_rounded,
          color: AdminHome.accentSky,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminGraduatesMap,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminGraduatesMapScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Contract',
        windowKey: AppWindowKeys.adminContract,
        child: _ContractDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminContract,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminContractScreen()),
            ),
          ),
        ),
      ),
      card(
        'Settings',
        windowKey: AppWindowKeys.adminSettings,
        child: _SettingsDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminSettings,
            () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminForceUpdateAllScreen(),
              ),
            ),
          ),
        ),
      ),
      card(
        'Window Access',
        adminOnly: true,
        child: _DashCard(
          title: 'Window Access',
          icon: AdminIcons.windowAccess,
          color: AdminHome.accentSlate,
          isReceptionistStyle: !_isAdminMode,
          onTap: () {
            unawaited(
              OfflineActionGuard.run(context, () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminWindowAccessScreen(),
                  ),
                );
              }),
            );
          },
        ),
      ),
      card(
        'Job Applications',
        windowKey: AppWindowKeys.adminJobApplications,
        child: _JobApplicationsDashCard(isReceptionistStyle: !_isAdminMode),
      ),
      card(
        'Diary',
        windowKey: AppWindowKeys.adminDiary,
        child: _DashCard(
          title: 'Diary',
          icon: AdminIcons.diary,
          color: AdminHome.accentRose,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminDiary,
            () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AdminDiaryScreen())),
          ),
        ),
      ),
    ];

    final q = _homeSearch.trim().toLowerCase();
    bool filterCard(_HomeCardItem c) {
      final matchesSearch = q.isEmpty || c.title.toLowerCase().contains(q);
      if (!matchesSearch) return false;
      if (_isAdminMode) return true;
      if (c.adminOnly) return false;
      if (_loadingReceptionistWindows) return false;
      final windowKey = c.windowKey;
      if (windowKey == null || windowKey.isEmpty) return true;
      return _receptionistWindowEnabled[windowKey] ?? true;
    }

    final filteredCards = allCards.where(filterCard).toList();

    List<_HomeCardItem> pinnedItems = [];
    List<_HomeCardItem> otherItems = [];
    for (final c in filteredCards) {
      if (_pinnedCardTitles.contains(c.title)) {
        pinnedItems.add(c);
      } else {
        otherItems.add(c);
      }
    }
    pinnedItems.sort((a, b) {
      final ai = _pinnedCardTitles.indexOf(a.title);
      final bi = _pinnedCardTitles.indexOf(b.title);
      return ai.compareTo(bi);
    });
    otherItems.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );

    // auto-expand all tools when search is active
    if (q.isNotEmpty && otherItems.isNotEmpty) {
      _allToolsExpanded = true;
    }

    final dashboardPanel = webPageFrame(
      context: context,
      maxWidth: 1500,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const OfflineNoticeBanner(),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _homeSearchController,
                onChanged: (v) => setState(() => _homeSearch = v),
                decoration: InputDecoration(
                  hintText: 'Search dashboard tools...',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _homeSearch.trim().isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _homeSearchController.clear();
                            setState(() => _homeSearch = '');
                          },
                        ),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
              ),
            ),
            _AdminTodoHomeCard(
              isReceptionistStyle: !_isAdminMode,
              onTap: () {
                unawaited(
                  OfflineActionGuard.run(context, () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AdminAdminTodosScreen(),
                      ),
                    );
                  }),
                );
              },
            ),
            const SizedBox(height: 10),
            Expanded(
              child: KeyedSubtree(
                key: _cardsGridKey,
                child: !_isAdminMode && _loadingReceptionistWindows
                    ? const Center(child: CircularProgressIndicator())
                    : filteredCards.isEmpty
                    ? Center(
                        child: Text(
                          'No tools matched "$q"',
                          style: const TextStyle(
                            color: AdminHome.softText,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _refreshHome,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            if (pinnedItems.isNotEmpty) ...[
                              _SectionHeader(
                                title: 'Pinned',
                                count: pinnedItems.length,
                                total: filteredCards.length,
                                icon: Icons.push_pin_rounded,
                              ),
                              GridView.count(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                crossAxisCount: crossAxisCount,
                                mainAxisSpacing: gridGap,
                                crossAxisSpacing: gridGap,
                                childAspectRatio: cardRatio,
                                children: pinnedItems
                                    .map((c) => c.child)
                                    .toList(),
                              ),
                              const SizedBox(height: 14),
                            ],
                            _SectionHeader(
                              title: 'All Tools',
                              count: otherItems.length,
                              total: filteredCards.length,
                              icon: _allToolsExpanded
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              onTap: () => setState(
                                () => _allToolsExpanded = !_allToolsExpanded,
                              ),
                            ),
                            if (_allToolsExpanded && otherItems.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: GridView.count(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  crossAxisCount: crossAxisCount,
                                  mainAxisSpacing: gridGap,
                                  crossAxisSpacing: gridGap,
                                  childAspectRatio: cardRatio,
                                  children: otherItems
                                      .map((c) => c.child)
                                      .toList(),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _isAdminMode
                    ? 'Your Bridge School • Admin View'
                    : 'Your Bridge School • Receptionist View',
                style: const TextStyle(
                  color: AdminHome.softText,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final webDesktop = isWebDesktop(context);

    final webRailTiles = <Widget>[
      if (_isWindowVisibleForCurrentMode(AppWindowKeys.adminLearners))
        _DrawerTile(
          icon: Icons.school_rounded,
          title: 'Learners',
          subtitle: 'Open learner management',
          color: AdminHome.primaryBlue,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminLearners,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
            ),
          ),
        ),
      if (_isWindowVisibleForCurrentMode(AppWindowKeys.adminPayments))
        _DrawerTile(
          icon: AdminIcons.navPayments,
          title: 'Payments',
          subtitle: 'Financial records',
          color: AdminHome.actionOrange,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminPayments,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
            ),
          ),
        ),
      if (_isWindowVisibleForCurrentMode(AppWindowKeys.adminClasses))
        _DrawerTile(
          icon: Icons.class_rounded,
          title: 'Classes',
          subtitle: 'Classes and attendance',
          color: AdminHome.accentIndigo,
          onTap: () => _openAdminWindow(
            AppWindowKeys.adminClasses,
            () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminClassesScreen()),
            ),
          ),
        ),
    ];

    final webRail = Container(
      width: 250,
      margin: const EdgeInsets.fromLTRB(12, 10, 0, 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AdminHome.uiBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quick Navigation',
            style: TextStyle(
              color: AdminHome.primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),
          ...webRailTiles,
          if (!_isAdminMode && _loadingReceptionistWindows)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          const Spacer(),
          _DrawerTile(
            icon: Icons.logout_rounded,
            title: 'Logout',
            subtitle: 'Sign out from this account',
            color: _isAdminMode
                ? AdminHome.primaryBlue
                : AdminHome.actionOrange,
            onTap: () => _logout(context),
          ),
        ],
      ),
    );

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
        backgroundColor: _screenBg,
        drawer: _AdminHomeDrawer(
          userEmail: user?.email ?? 'Admin',
          isAdminMode: _isAdminMode,
          loadingRole: _loadingRole,
          onOpenMain: () {
            Navigator.of(context).pop();
            unawaited(
              OfflineActionGuard.run(context, () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminPublicPreview()),
                );
              }),
            );
          },
          onSelectAdmin: _handleSelectAdmin,
          onSelectReceptionist: () async {
            Navigator.of(context).pop();
            await _setRoleMode(false);
          },
          onLogout: () async {
            Navigator.of(context).pop();
            await WidgetsBinding.instance.endOfFrame;
            if (!context.mounted) return;
            await _logout(context);
          },
          onOpenLearners: () {
            Navigator.of(context).pop();
            _openAdminWindow(
              AppWindowKeys.adminLearners,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
              ),
            );
          },
          onOpenPayments: () {
            Navigator.of(context).pop();
            _openAdminWindow(
              AppWindowKeys.adminPayments,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
              ),
            );
          },
          onOpenClasses: () {
            Navigator.of(context).pop();
            _openAdminWindow(
              AppWindowKeys.adminClasses,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminClassesScreen()),
              ),
            );
          },
          onOpenStaff: () {
            Navigator.of(context).pop();
            _openAdminWindow(
              AppWindowKeys.adminStaff,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminStaffScreen()),
              ),
            );
          },
          onOpenMail: () {
            Navigator.of(context).pop();
            _openAdminWindow(
              AppWindowKeys.adminMail,
              () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AdminMailInboxScreen()),
              ),
            );
          },
        ),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          automaticallyImplyLeading: false,
          leading: Padding(
            padding: const EdgeInsets.only(left: 10, top: 8, bottom: 8),
            child: Material(
              key: _menuButtonKey,
              color: _isAdminMode
                  ? const Color(0xFFF1F5F9)
                  : const Color(0xFFFFF5EB),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
                child: const Center(
                  child: Icon(Icons.menu_rounded, color: AdminHome.primaryBlue),
                ),
              ),
            ),
          ),
          centerTitle: true,
          title: Text(
            _screenTitle,
            style: const TextStyle(
              color: AdminHome.primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
          actions: [
            const SizedBox.shrink(),
            Padding(
              padding: const EdgeInsets.only(right: 10, top: 8, bottom: 8),
              child: Material(
                color: _isAdminMode
                    ? const Color(0xFFFFF1E5)
                    : const Color(0xFFEAF8FF),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => _logout(context),
                  child: SizedBox(
                    width: 44,
                    child: Center(
                      child: Icon(
                        Icons.logout,
                        color: _isAdminMode
                            ? AdminHome.actionOrange
                            : AdminHome.accentSky,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: _isAdminMode
                        ? const [Color(0xFFFFFFFF), Color(0xFFF6FAFF)]
                        : const [Color(0xFFFFFFFF), Color(0xFFF8FBFF)],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: _isAdminMode ? 0.035 : 0.028,
                  child: Center(
                    child: FractionallySizedBox(
                      widthFactor: 0.72,
                      child: Image.asset(
                        'assets/images/ybs_logo.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: webDesktop
                  ? Row(
                      children: [
                        webRail,
                        Expanded(child: dashboardPanel),
                      ],
                    )
                  : dashboardPanel,
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeCardItem {
  const _HomeCardItem({
    required this.title,
    required this.child,
    this.windowKey,
    this.adminOnly = false,
  });

  final String title;
  final Widget child;
  final String? windowKey;
  final bool adminOnly;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.total,
    this.icon,
    this.onTap,
  });

  final String title;
  final int count;
  final int total;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: AdminHome.primaryBlue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Icon(
                  icon ?? Icons.grid_view_rounded,
                  size: 12,
                  color: AdminHome.primaryBlue,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 11,
                  color: AdminHome.primaryBlue,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AdminHome.primaryBlue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count / $total',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                    color: AdminHome.primaryBlue,
                  ),
                ),
              ),
              const Spacer(),
              if (onTap != null)
                Icon(
                  icon != null && icon != Icons.push_pin_rounded
                      ? icon
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: AdminHome.softText,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminPasswordDialog extends StatefulWidget {
  const _AdminPasswordDialog();

  @override
  State<_AdminPasswordDialog> createState() => _AdminPasswordDialogState();
}

class _AdminPasswordDialogState extends State<_AdminPasswordDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(_controller.text.trim());
  }

  Future<void> _cancel() async {
    FocusScope.of(context).unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Admin password'),
      content: TextField(
        controller: _controller,
        obscureText: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Enter password'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }
}

class _AdminTodoHomeCard extends StatelessWidget {
  const _AdminTodoHomeCard({
    required this.onTap,
    required this.isReceptionistStyle,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  // ignore: unused_element
  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final ref = FirebaseDatabase.instance.ref('admin_todos/$uid');

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isReceptionistStyle
                ? const Color(0xFFFFDDBE)
                : AdminHome.uiBorder,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.035),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: StreamBuilder<DatabaseEvent>(
          stream: uid.isEmpty ? null : ref.onValue,
          builder: (context, snap) {
            int newCount = 0;
            int seenCount = 0;
            int doneCount = 0;
            int overdueCount = 0;
            String nextTitle = '';
            int nextDue = 1 << 62;

            final now = DateTime.now().millisecondsSinceEpoch;
            final val = snap.data?.snapshot.value;
            if (val is Map) {
              val.forEach((_, raw) {
                if (raw is! Map) return;
                final m = raw.map((k, v) => MapEntry(k.toString(), v));
                final status = ReminderConsistencyService.normalizeStatus(
                  m['status'],
                );
                final dueAt = _toInt(m['dueAt']);
                final isOverdue = status != 'done' && dueAt > 0 && dueAt < now;

                if (status == 'done') {
                  doneCount++;
                } else if (status == 'read') {
                  seenCount++;
                } else {
                  newCount++;
                }
                if (isOverdue) overdueCount++;

                if (status != 'done') {
                  final title = (m['title'] ?? '').toString().trim();
                  if (title.isNotEmpty && dueAt > 0 && dueAt < nextDue) {
                    nextDue = dueAt;
                    nextTitle = title;
                  } else if (title.isNotEmpty && nextTitle.isEmpty) {
                    nextTitle = title;
                  }
                }
              });
            }

            Widget chip(String label, String value, Color fg, Color bg) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: fg.withValues(alpha: 0.18)),
                ),
                child: Text(
                  '$label $value',
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              );
            }

            return Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF2FF),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    AdminIcons.adminTodo,
                    color: AdminHome.primaryBlue,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Admin TODO Inbox',
                        style: TextStyle(
                          color: AdminHome.primaryBlue,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Tasks from other admins',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.55),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      if (nextTitle.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Next: $nextTitle',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.66),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          chip(
                            'New',
                            '$newCount',
                            const Color(0xFFEF6C00),
                            const Color(0xFFFFF2E7),
                          ),
                          chip(
                            'Seen',
                            '$seenCount',
                            const Color(0xFF1565C0),
                            const Color(0xFFEAF2FF),
                          ),
                          chip(
                            'Done',
                            '$doneCount',
                            const Color(0xFF2E7D32),
                            const Color(0xFFEAF8EF),
                          ),
                          chip(
                            'Overdue',
                            '$overdueCount',
                            const Color(0xFFB71C1C),
                            const Color(0xFFFFECEB),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AdminHome.primaryBlue,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AdminHomeDrawer extends StatelessWidget {
  final String userEmail;
  final bool isAdminMode;
  final bool loadingRole;
  final VoidCallback onOpenMain;
  final VoidCallback onSelectAdmin;
  final VoidCallback onSelectReceptionist;
  final VoidCallback onLogout;
  final VoidCallback onOpenLearners;
  final VoidCallback onOpenPayments;
  final VoidCallback onOpenClasses;
  final VoidCallback onOpenStaff;
  final VoidCallback onOpenMail;

  const _AdminHomeDrawer({
    required this.userEmail,
    required this.isAdminMode,
    required this.loadingRole,
    required this.onOpenMain,
    required this.onSelectAdmin,
    required this.onSelectReceptionist,
    required this.onLogout,
    required this.onOpenLearners,
    required this.onOpenPayments,
    required this.onOpenClasses,
    required this.onOpenStaff,
    required this.onOpenMail,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = isAdminMode
        ? AdminHome.primaryBlue
        : AdminHome.actionOrange;

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isAdminMode
                      ? const Color(0xFFF7FAFD)
                      : const Color(0xFFFFFAF5),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isAdminMode
                        ? AdminHome.uiBorder
                        : const Color(0xFFFFE7D1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Dashboard Role',
                      style: TextStyle(
                        color: AdminHome.primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      userEmail,
                      style: const TextStyle(
                        color: AdminHome.softText,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (loadingRole)
                      const SizedBox(
                        height: 42,
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: _RoleSelectButton(
                              title: 'Admin',
                              subtitle: 'All tools',
                              isSelected: isAdminMode,
                              selectedColor: AdminHome.primaryBlue,
                              onTap: onSelectAdmin,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _RoleSelectButton(
                              title: 'Receptionist',
                              subtitle: 'Front desk',
                              isSelected: !isAdminMode,
                              selectedColor: AdminHome.actionOrange,
                              onTap: onSelectReceptionist,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10),
                children: [
                  _DrawerTile(
                    icon: Icons.home_rounded,
                    title: 'Main Screen',
                    subtitle: 'Open public courses & prices',
                    color: isAdminMode
                        ? AdminHome.primaryBlue
                        : AdminHome.actionOrange,
                    onTap: onOpenMain,
                  ),
                  const Divider(height: 1),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text(
                      'QUICK ACCESS',
                      style: TextStyle(
                        color: AdminHome.softText,
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  _DrawerTile(
                    icon: Icons.school_rounded,
                    title: 'Learners',
                    subtitle: 'Open learner management',
                    color: AdminHome.primaryBlue,
                    onTap: onOpenLearners,
                  ),
                  _DrawerTile(
                    icon: AdminIcons.navPayments,
                    title: 'Payments',
                    subtitle: 'Financial records',
                    color: AdminHome.actionOrange,
                    onTap: onOpenPayments,
                  ),
                  _DrawerTile(
                    icon: Icons.class_rounded,
                    title: 'Classes',
                    subtitle: 'Classes and attendance',
                    color: AdminHome.accentIndigo,
                    onTap: onOpenClasses,
                  ),
                  _DrawerTile(
                    icon: Icons.group_rounded,
                    title: 'Staff',
                    subtitle: 'Teacher management',
                    color: AdminHome.accentTeal,
                    onTap: onOpenStaff,
                  ),
                  _DrawerTile(
                    icon: Icons.mail_rounded,
                    title: 'Admin Mail',
                    subtitle: 'Internal messages',
                    color: AdminHome.accentCyan,
                    onTap: onOpenMail,
                  ),
                  const Divider(height: 1),
                  _DrawerTile(
                    icon: Icons.logout_rounded,
                    title: 'Logout',
                    subtitle: 'Sign out from this account',
                    color: activeColor,
                    onTap: onLogout,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleSelectButton extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isSelected;
  final Color selectedColor;
  final VoidCallback onTap;

  const _RoleSelectButton({
    required this.title,
    required this.subtitle,
    required this.isSelected,
    required this.selectedColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isSelected
        ? selectedColor.withValues(alpha: 0.10)
        : const Color(0xFFF8FAFC);

    final border = isSelected ? selectedColor : AdminHome.uiBorder;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Column(
          children: [
            Text(
              title,
              style: TextStyle(
                color: isSelected ? selectedColor : AdminHome.mainText,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(
                color: AdminHome.softText,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _DrawerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: AdminHome.primaryBlue,
          fontWeight: FontWeight.w900,
          fontSize: 14,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AdminHome.softText,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

// ===================== ONLINE BOOKING CARD =====================

class _AdminOnlineBookingDashCard extends StatelessWidget {
  final bool isReceptionistStyle;

  const _AdminOnlineBookingDashCard({this.isReceptionistStyle = false});

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

  ({int today, int week, int upcoming}) _bookingStats(dynamic rootValue) {
    if (rootValue is! Map) return (today: 0, week: 0, upcoming: 0);

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));
    final weekStart = todayStart.subtract(Duration(days: now.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 7));

    int today = 0;
    int week = 0;
    int upcoming = 0;

    void markSlot(DateTime dt) {
      upcoming += 1;
      if (!dt.isBefore(todayStart) && dt.isBefore(todayEnd)) today += 1;
      if (!dt.isBefore(weekStart) && dt.isBefore(weekEnd)) week += 1;
    }

    final byCourse = Map<dynamic, dynamic>.from(rootValue);

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

          final dt = _parseSlotStart(dayKey, hhmm);
          if (dt == null) continue;

          if (!dt.isAfter(now)) continue;

          final slotMap = Map<dynamic, dynamic>.from(slotNode);

          // Flat shape: /{day}/{time} => {learners:{...}, ...}
          final learnersRaw = slotMap['learners'];
          if (learnersRaw is Map && learnersRaw.isNotEmpty) {
            markSlot(dt);
          }

          // Nested shape: /{day}/{time}/{teacherId} => {learners:{...}, ...}
          for (final teacherEntry in slotMap.entries) {
            final teacherSlot = teacherEntry.value;
            if (teacherSlot is! Map) continue;
            final tm = Map<dynamic, dynamic>.from(teacherSlot);
            final tLearners = tm['learners'];
            if (tLearners is Map && tLearners.isNotEmpty) {
              markSlot(dt);
            }
          }
        }
      }
    }

    return (today: today, week: week, upcoming: upcoming);
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('booking_reservations');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        final stats = _bookingStats(snap.data?.snapshot.value);

        return _DashCard(
          title: 'Online Booking',
          statusLabels: [
            _StatusLabelData(
              label: 'Today',
              count: stats.today,
              color: AdminHome.accentGreen,
            ),
            _StatusLabelData(
              label: 'Week',
              count: stats.week,
              color: AdminHome.accentBlue,
            ),
            _StatusLabelData(
              label: 'Upcoming',
              count: stats.upcoming,
              color: AdminHome.accentAmber,
            ),
          ],
          icon: AdminIcons.onlineBooking,
          color: AdminHome.accentGreen,
          badgeCount: stats.upcoming,
          isReceptionistStyle: isReceptionistStyle,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminBookingScreen())),
        );
      },
    );
  }
}

class _SubscriptionsDashCard extends StatelessWidget {
  final bool isReceptionistStyle;

  const _SubscriptionsDashCard({this.isReceptionistStyle = false});

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('subscriptions');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int count = 0;
        final v = snap.data?.snapshot.value;
        if (v is Map) count = v.length;

        return _DashCard(
          title: 'Subscriptions',
          statusLabels: [
            _StatusLabelData(
              label: 'New',
              count: count,
              color: AdminHome.accentAmber,
            ),
          ],
          icon: AdminIcons.subscriptions,
          color: AdminHome.accentAmber,
          badgeCount: count,
          isReceptionistStyle: isReceptionistStyle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminSubscriptionsScreen()),
          ),
        );
      },
    );
  }
}

class _JobApplicationsDashCard extends StatelessWidget {
  final bool isReceptionistStyle;

  const _JobApplicationsDashCard({this.isReceptionistStyle = false});

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('job_applications');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int total = 0;
        int uncalledCount = 0;
        int followUp = 0;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          total = v.length;
          v.forEach((_, raw) {
            if (raw is! Map) return;
            final m = raw.map((k, val) => MapEntry(k.toString(), val));
            final stage = (m['stage'] ?? '').toString().trim().toLowerCase();
            final status = (m['status'] ?? '').toString().trim().toLowerCase();
            final effective = stage.isEmpty
                ? (status.isEmpty ? 'new' : status)
                : stage;
            if (effective == 'new') {
              uncalledCount += 1;
            } else if (effective == 'called_no_answer' ||
                effective == 'callback_requested') {
              followUp += 1;
            }
          });
        }

        return _DashCard(
          title: 'Job Applications',
          statusLabels: [
            _StatusLabelData(
              label: 'New',
              count: uncalledCount,
              color: AdminHome.accentRose,
            ),
            _StatusLabelData(
              label: 'Follow-up',
              count: followUp,
              color: AdminHome.accentAmber,
            ),
            _StatusLabelData(
              label: 'Total',
              count: total,
              color: AdminHome.accentSlate,
            ),
          ],
          icon: AdminIcons.jobApplications,
          color: AdminHome.accentSlate,
          badgeCount: uncalledCount,
          isReceptionistStyle: isReceptionistStyle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminJobApplicationsScreen(),
            ),
          ),
        );
      },
    );
  }
}

class _ClassesDashCard extends StatelessWidget {
  const _ClassesDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('classes');
    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int open = 0;
        int closed = 0;
        final learnerUids = <String>{};

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          v.forEach((_, raw) {
            if (raw is! Map) return;
            final m = raw.map((k, val) => MapEntry(k.toString(), val));
            final status = (m['status'] ?? 'active')
                .toString()
                .trim()
                .toLowerCase();
            if (status == 'active' || status == 'open') {
              open += 1;
            } else {
              closed += 1;
            }

            final learners = m['learners'];
            if (learners is Map) {
              learners.forEach((uid, _) {
                final id = uid?.toString().trim() ?? '';
                if (id.isNotEmpty) learnerUids.add(id);
              });
            }
          });
        }

        return _DashCard(
          title: 'Classes',
          statusLabels: [
            _StatusLabelData(
              label: 'Open',
              count: open,
              color: AdminHome.accentGreen,
            ),
            _StatusLabelData(
              label: 'Closed',
              count: closed,
              color: AdminHome.accentSlate,
            ),
            _StatusLabelData(
              label: 'Learners',
              count: learnerUids.length,
              color: AdminHome.accentBlue,
            ),
          ],
          icon: Icons.class_rounded,
          color: AdminHome.actionOrange,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _AdminSharedFilesDashCard extends StatelessWidget {
  final bool isReceptionistStyle;

  const _AdminSharedFilesDashCard({this.isReceptionistStyle = false});

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('shared_files');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int count = 0;
        final v = snap.data?.snapshot.value;
        if (v is Map) count = v.length;

        return _DashCard(
          title: 'Shared Files',
          statusLabels: [
            _StatusLabelData(
              label: 'Shared',
              count: count,
              color: AdminHome.accentTeal,
            ),
          ],
          icon: AdminIcons.sharedFiles,
          color: AdminHome.accentTeal,
          badgeCount: count,
          isReceptionistStyle: isReceptionistStyle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminSharedFilesScreen()),
          ),
        );
      },
    );
  }
}

class _CertificatesDashCard extends StatefulWidget {
  final bool isReceptionistStyle;

  const _CertificatesDashCard({this.isReceptionistStyle = false});

  @override
  State<_CertificatesDashCard> createState() => _CertificatesDashCardState();
}

class _CertificatesDashCardState extends State<_CertificatesDashCard> {
  int _adminCount = 0;
  int _recordedCount = 0;
  final DatabaseReference _adminRef = FirebaseDatabase.instance.ref(
    'admin_certificates',
  );
  final DatabaseReference _usersRef = FirebaseDatabase.instance.ref('users');
  late final List<StreamSubscription<DatabaseEvent>> _subscriptions;

  @override
  void initState() {
    super.initState();
    _subscriptions = [
      _adminRef.onValue.listen((event) {
        if (!mounted) return;
        final count = (event.snapshot.value is Map)
            ? (event.snapshot.value as Map).length
            : 0;
        setState(() => _adminCount = count);
      }),
      _usersRef.onValue.listen((event) {
        if (!mounted) return;
        final val = event.snapshot.value;
        int rCount = 0;
        if (val is Map) {
          val.forEach((_, userRaw) {
            if (userRaw is! Map) return;
            final user = Map<dynamic, dynamic>.from(userRaw);
            final recorded = user['recorded_certificates'];
            if (recorded is Map) {
              rCount += recorded.length;
            }
          });
        }
        setState(() => _recordedCount = rCount);
      }),
    ];
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _adminCount + _recordedCount;

    return _DashCard(
      title: 'Certificates',
      statusLabels: [
        _StatusLabelData(
          label: 'Total',
          count: totalCount,
          color: AdminHome.accentIndigo,
        ),
        _StatusLabelData(
          label: 'Recorded',
          count: _recordedCount,
          color: AdminHome.accentGreen,
        ),
      ],
      icon: Icons.workspace_premium_rounded,
      color: AdminHome.accentIndigo,
      badgeCount: totalCount,
      isReceptionistStyle: widget.isReceptionistStyle,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AdminCertificatesScreen()),
      ),
    );
  }
}

class _WagesDashCard extends StatelessWidget {
  const _WagesDashCard({required this.onTap, this.isReceptionistStyle = false});

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  bool _isPaid(Map<String, dynamic> m) {
    final status = (m['status'] ?? '').toString().trim().toLowerCase();
    if (status == 'paid') return true;
    final paid = m['isPaid'] ?? m['paid'];
    if (paid is bool) return paid;
    final s = (paid ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('payments');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int pending = 0;
        int paidThisMonth = 0;
        final now = DateTime.now();

        final root = snap.data?.snapshot.value;
        if (root is Map) {
          root.forEach((_, raw) {
            if (raw is! Map) return;
            final m = raw.map((k, v) => MapEntry(k.toString(), v));
            final paid = _isPaid(m);
            if (!paid) {
              pending += 1;
              return;
            }
            final paidAt = _toInt(m['paidAt']);
            if (paidAt <= 0) return;
            final d = DateTime.fromMillisecondsSinceEpoch(paidAt);
            if (d.year == now.year && d.month == now.month) {
              paidThisMonth += 1;
            }
          });
        }

        return _DashCard(
          title: 'Wages',
          statusLabels: [
            _StatusLabelData(
              label: 'Pending',
              count: pending,
              color: AdminHome.accentRose,
            ),
            _StatusLabelData(
              label: 'Paid',
              count: paidThisMonth,
              color: AdminHome.accentGreen,
            ),
          ],
          icon: AdminIcons.wages,
          color: AdminHome.accentRose,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _ContractDashCard extends StatelessWidget {
  const _ContractDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('contract');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int teacherCount = 0;
        int learnerCount = 0;
        final root = snap.data?.snapshot.value;

        if (root is Map) {
          final map = root.map((k, v) => MapEntry(k.toString(), v));
          final t = map['teacher'];
          final l = map['learner'];
          if (t is Map) teacherCount = t.length;
          if (l is Map) learnerCount = l.length;
        }

        return _DashCard(
          title: 'Contract',
          statusLabels: [
            _StatusLabelData(
              label: 'Teacher',
              count: teacherCount,
              color: AdminHome.accentCyan,
            ),
            _StatusLabelData(
              label: 'Learner',
              count: learnerCount,
              color: AdminHome.accentGreen,
            ),
          ],
          icon: AdminIcons.contract,
          color: AdminHome.accentCyan,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _SettingsDashCard extends StatelessWidget {
  const _SettingsDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  String _normalizeKey(String raw) {
    return raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  dynamic _valueByAliases(Map source, List<String> aliases) {
    final normalized = <String, dynamic>{};
    source.forEach((k, v) {
      normalized[_normalizeKey(k.toString())] = v;
    });

    for (final alias in aliases) {
      final key = _normalizeKey(alias);
      if (normalized.containsKey(key)) {
        return normalized[key];
      }
    }
    return null;
  }

  String? _cleanBuild(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw.toString();
    if (raw is num) return raw.toInt().toString();
    final s = raw.toString().trim();
    if (s.isEmpty) return null;
    final parsed = int.tryParse(s);
    if (parsed != null) return parsed.toString();
    return s;
  }

  String _b(dynamic root, String platform) {
    if (root is! Map) return 'n/a';

    final p = _valueByAliases(root, [platform]);
    if (p is Map) {
      final raw = _valueByAliases(p, [
        'minBuild',
        'min_build',
        'minbuild',
        'build',
      ]);
      final cleaned = _cleanBuild(raw);
      if (cleaned != null) return cleaned;
    }

    final flat = _valueByAliases(root, [
      '${platform}MinBuild',
      '${platform}_min_build',
      '${platform}_build',
      '${platform}build',
    ]);
    return _cleanBuild(flat) ?? 'n/a';
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('appConfig/forceUpdate');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        final root = snap.data?.snapshot.value;
        final a = _b(root, 'android');
        final i = _b(root, 'ios');

        return _DashCard(
          title: 'Settings',
          statusLabels: [
            _StatusLabelData(
              label: 'Android',
              count: int.tryParse(a) ?? 0,
              color: AdminHome.accentGreen,
            ),
            _StatusLabelData(
              label: 'iOS',
              count: int.tryParse(i) ?? 0,
              color: AdminHome.accentBlue,
            ),
          ],
          icon: Icons.settings_rounded,
          color: AdminHome.accentIndigo,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _PriorityAlertsDashCard extends StatelessWidget {
  const _PriorityAlertsDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('flash_messages');
    final now = DateTime.now();

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        final root = snap.data?.snapshot.value;
        final counts = NotificationCounterService.flashAlertCounts(root, now);
        final unseen = counts.unseen;
        final today = counts.today;

        return _DashCard(
          title: 'Priority Alerts',
          statusLabels: [
            _StatusLabelData(
              label: 'Unseen',
              count: unseen,
              color: AdminHome.accentRose,
            ),
            _StatusLabelData(
              label: 'Today',
              count: today,
              color: AdminHome.accentAmber,
            ),
          ],
          icon: AdminIcons.priorityAlerts,
          color: AdminHome.actionOrange,
          badgeCount: unseen,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _PublicGalleryDashCard extends StatelessWidget {
  const _PublicGalleryDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('public_gallery_teasers');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int count = 0;
        final root = snap.data?.snapshot.value;
        if (root is Map) count = root.length;

        return _DashCard(
          title: 'Public Gallery',
          statusLabels: [
            _StatusLabelData(
              label: 'Teasers',
              count: count,
              color: AdminHome.accentPurple,
            ),
          ],
          icon: AdminIcons.publicGallery,
          color: AdminHome.accentPurple,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _DashGalleryCard extends StatelessWidget {
  const _DashGalleryCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final publicRef = FirebaseDatabase.instance.ref('public_gallery_teasers');
    final learnerRef = FirebaseDatabase.instance.ref('learner_gallery');

    return StreamBuilder<DatabaseEvent>(
      stream: publicRef.onValue,
      builder: (context, publicSnap) {
        int publicCount = 0;
        final publicVal = publicSnap.data?.snapshot.value;
        if (publicVal is Map) publicCount = publicVal.length;

        return StreamBuilder<DatabaseEvent>(
          stream: learnerRef.onValue,
          builder: (context, learnerSnap) {
            int learnerItems = 0;
            final learnerVal = learnerSnap.data?.snapshot.value;
            if (learnerVal is Map) {
              for (final v in learnerVal.values) {
                if (v is Map) learnerItems += v.length;
              }
            }

            return _DashCard(
              title: 'Gallery',
              statusLabels: [
                _StatusLabelData(
                  label: 'All Media',
                  count: publicCount + learnerItems,
                  color: AdminHome.accentSky,
                ),
              ],
              icon: Icons.photo_library_rounded,
              color: AdminHome.accentSky,
              isReceptionistStyle: isReceptionistStyle,
              onTap: onTap,
            );
          },
        );
      },
    );
  }
}

class _TeacherAvailabilityDashCard extends StatelessWidget {
  const _TeacherAvailabilityDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  bool _toBool(dynamic v) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  int _slotCount(dynamic availability) {
    if (availability is! Map) return 0;
    var c = 0;
    availability.forEach((_, rawDay) {
      if (rawDay is Map) {
        c += rawDay.length;
      } else if (rawDay is List) {
        c += rawDay.length;
      }
    });
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('booking_availability');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int online = 0;
        int slots = 0;

        final root = snap.data?.snapshot.value;
        if (root is Map) {
          root.forEach((_, teacherNode) {
            if (teacherNode is! Map) return;
            final m = teacherNode.map((k, v) => MapEntry(k.toString(), v));
            final settings = m['settings'];
            if (settings is Map) {
              final sm = settings.map((k, v) => MapEntry(k.toString(), v));
              if (_toBool(sm['teacherOnlineEnabled'])) online += 1;
            }
            slots += _slotCount(m['availability']);
          });
        }

        return _DashCard(
          title: 'Teacher Availability',
          statusLabels: [
            _StatusLabelData(
              label: 'Online',
              count: online,
              color: AdminHome.accentGreen,
            ),
            _StatusLabelData(
              label: 'Slots',
              count: slots,
              color: AdminHome.accentBlue,
            ),
          ],
          icon: AdminIcons.teacherAvailability,
          color: AdminHome.accentCyan,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}
// ===================== PAY FLAG =====================

enum _PayFlag { ok, yellow, red, black, exempt, noCourse, exam }

class _PayLegend {
  static const String noCourseLabel = 'No course';
  static const String blackLabel = 'Overdue';
  static const String redLabel = 'Due now';
  static const String yellowLabel = 'Warning';
  static const String okLabel = 'OK';
  static const String examLabel = 'Exam';

  static const Color noCourseColor = Colors.blue;
  static const Color blackColor = Colors.black;
  static const Color redColor = Colors.red;
  static const Color yellowColor = AdminHome.actionOrange;
  static const Color okColor = AdminHome.primaryBlue;
  static const Color examColor = Colors.purple;
}

class _PaymentAttentionSummary {
  const _PaymentAttentionSummary({
    required this.totalLearners,
    required this.noCourse,
    required this.black,
    required this.red,
    required this.yellow,
    required this.ok,
    this.exam = 0,
  });

  final int totalLearners;
  final int noCourse;
  final int black;
  final int red;
  final int yellow;
  final int ok;
  final int exam;

  int get attention => black + red;
  int get tracked => black + red + yellow + ok + exam;

  static _PaymentAttentionSummary fromUsers(dynamic usersVal) {
    int totalLearners = 0;
    int noCourse = 0;
    int black = 0;
    int red = 0;
    int yellow = 0;
    int ok = 0;
    int exam = 0;

    if (usersVal is Map) {
      usersVal.forEach((uid, userVal) {
        if (uid == null || userVal == null || userVal is! Map) return;
        final userMap = userVal.map((k, vv) => MapEntry(k.toString(), vv));

        final role = (userMap['role'] ?? '').toString().trim().toLowerCase();
        if (role != 'learner' && role != 'learners' && role != 'learner(s)') {
          return;
        }

        totalLearners++;

        final isExam =
            userMap['examMode'] == true ||
            userMap['examMode']?.toString() == 'true';
        if (isExam) {
          exam++;
          return;
        }

        final courses = userMap['courses'];
        if (courses is! Map || courses.isEmpty) {
          noCourse++;
          return;
        }

        bool hasAtLeastOneCourse = false;
        _PayFlag worst = _PayFlag.ok;

        courses.forEach((_, courseVal) {
          if (courseVal is! Map) return;
          hasAtLeastOneCourse = true;
          final courseMap = courseVal.map(
            (k, vv) => MapEntry(k.toString(), vv),
          );
          final flag = _PaymentAttentionLogic.variantPaymentFlag(courseMap);
          if (_PaymentAttentionLogic.rank(flag) >
              _PaymentAttentionLogic.rank(worst)) {
            worst = flag;
          }
        });

        if (!hasAtLeastOneCourse) {
          noCourse++;
          return;
        }

        switch (worst) {
          case _PayFlag.black:
            black++;
            break;
          case _PayFlag.exempt:
            ok++;
            break;
          case _PayFlag.red:
            red++;
            break;
          case _PayFlag.yellow:
            yellow++;
            break;
          case _PayFlag.ok:
            ok++;
            break;
          case _PayFlag.noCourse:
            noCourse++;
            break;
          case _PayFlag.exam:
            exam++;
            break;
        }
      });
    }

    return _PaymentAttentionSummary(
      totalLearners: totalLearners,
      noCourse: noCourse,
      black: black,
      red: red,
      yellow: yellow,
      ok: ok,
      exam: exam,
    );
  }
}

class _PaymentAttentionDetails {
  const _PaymentAttentionDetails({
    required this.summary,
    required this.noCourseLearners,
    required this.overdueLearners,
    required this.dueNowLearners,
    required this.warningLearners,
    required this.okLearners,
    this.examLearners = const <String>[],
  });

  final _PaymentAttentionSummary summary;
  final List<String> noCourseLearners;
  final List<String> overdueLearners;
  final List<String> dueNowLearners;
  final List<String> warningLearners;
  final List<String> okLearners;
  final List<String> examLearners;

  static _PaymentAttentionDetails fromUsers(dynamic usersVal) {
    final noCourse = <String>[];
    final overdue = <String>[];
    final dueNow = <String>[];
    final warning = <String>[];
    final ok = <String>[];
    final exam = <String>[];

    if (usersVal is Map) {
      usersVal.forEach((uid, userVal) {
        if (uid == null || userVal == null || userVal is! Map) return;
        final userMap = userVal.map((k, vv) => MapEntry(k.toString(), vv));

        final role = (userMap['role'] ?? '').toString().trim().toLowerCase();
        if (role != 'learner' && role != 'learners' && role != 'learner(s)') {
          return;
        }

        final fn = (userMap['first_name'] ?? userMap['firstName'] ?? '')
            .toString()
            .trim();
        final ln = (userMap['last_name'] ?? userMap['lastName'] ?? '')
            .toString()
            .trim();
        final email = (userMap['email'] ?? '').toString().trim();
        final displayName = ('$fn $ln').trim().isNotEmpty
            ? ('$fn $ln').trim()
            : (email.isNotEmpty ? email : uid.toString());

        final isExam =
            userMap['examMode'] == true ||
            userMap['examMode']?.toString() == 'true';
        if (isExam) {
          exam.add(displayName);
          return;
        }

        final courses = userMap['courses'];
        if (courses is! Map || courses.isEmpty) {
          noCourse.add(displayName);
          return;
        }

        bool hasAtLeastOneCourse = false;
        _PayFlag worst = _PayFlag.ok;

        courses.forEach((_, courseVal) {
          if (courseVal is! Map) return;
          hasAtLeastOneCourse = true;
          final courseMap = courseVal.map(
            (k, vv) => MapEntry(k.toString(), vv),
          );
          final flag = _PaymentAttentionLogic.variantPaymentFlag(courseMap);
          if (_PaymentAttentionLogic.rank(flag) >
              _PaymentAttentionLogic.rank(worst)) {
            worst = flag;
          }
        });

        if (!hasAtLeastOneCourse) {
          noCourse.add(displayName);
          return;
        }

        switch (worst) {
          case _PayFlag.black:
            overdue.add(displayName);
            break;
          case _PayFlag.exempt:
            ok.add(displayName);
            break;
          case _PayFlag.red:
            dueNow.add(displayName);
            break;
          case _PayFlag.yellow:
            warning.add(displayName);
            break;
          case _PayFlag.ok:
            ok.add(displayName);
            break;
          case _PayFlag.noCourse:
            noCourse.add(displayName);
            break;
          case _PayFlag.exam:
            exam.add(displayName);
            break;
        }
      });
    }

    int sortCaseInsensitive(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    noCourse.sort(sortCaseInsensitive);
    overdue.sort(sortCaseInsensitive);
    dueNow.sort(sortCaseInsensitive);
    warning.sort(sortCaseInsensitive);
    ok.sort(sortCaseInsensitive);
    exam.sort(sortCaseInsensitive);

    return _PaymentAttentionDetails(
      summary: _PaymentAttentionSummary.fromUsers(usersVal),
      noCourseLearners: noCourse,
      overdueLearners: overdue,
      dueNowLearners: dueNow,
      warningLearners: warning,
      okLearners: ok,
      examLearners: exam,
    );
  }
}

class _PaymentAttentionLogic {
  static int asInt(dynamic v) => paymentAsInt(v);

  static String normalizeVariantKey(String raw) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'inclass':
      case 'in-class':
      case 'in class':
      case 'in_class':
      case 'class':
        return 'inclass';
      case 'private':
      case 'live':
      case 'vip':
        return 'private';
      case 'flexible':
      case 'online':
        return 'flexible';
      case 'recorded':
      case 'record':
        return 'recorded';
      default:
        return v.isEmpty ? 'inclass' : v;
    }
  }

  static bool isExpiredMs(int expiresAt) {
    if (expiresAt <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch >= expiresAt;
  }

  static bool isNearExpiryMs(int expiresAt, {int days = 7}) {
    if (expiresAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = expiresAt - now;
    if (diff < 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  static int rank(_PayFlag f) {
    switch (f) {
      case _PayFlag.black:
        return 4;
      case _PayFlag.red:
        return 3;
      case _PayFlag.yellow:
        return 2;
      case _PayFlag.exempt:
        return 1;
      case _PayFlag.ok:
        return 1;
      case _PayFlag.noCourse:
        return 0;
      case _PayFlag.exam:
        return 0;
    }
  }

  static _PayFlag paymentFlag({
    required int sessionsPaidTotal,
    required int sessionsDone,
    required int remindBeforeSession,
  }) {
    if (sessionsPaidTotal <= 0) return _PayFlag.black;

    if (isPaymentDueBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
    )) {
      return _PayFlag.red;
    }

    if (isPaymentWarningBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
      remindBeforeSession: remindBeforeSession,
    )) {
      return _PayFlag.yellow;
    }

    return _PayFlag.ok;
  }

  static int _flexibleSessionsConsumed(Map<String, dynamic> courseMap) {
    final directOnline = countPresentOnlineAttendance(
      courseMap['online_attendance'],
    );
    if (directOnline > 0) return directOnline;

    final bookingProgress = courseMap['booking_progress'];
    if (bookingProgress is Map) {
      final bp = bookingProgress.map((k, v) => MapEntry(k.toString(), v));
      final nestedOnline = countPresentOnlineAttendance(
        bp['online_attendance'],
      );
      if (nestedOnline > 0) return nestedOnline;
    }

    return countPresentUniqueAttendanceDates(courseMap['attendance']);
  }

  static _PayFlag variantPaymentFlag(Map<String, dynamic> courseMap) {
    if (courseIsFreeBilling(courseMap)) return _PayFlag.exempt;

    final variantKey = normalizeVariantKey(
      (courseMap['variantKey'] ?? courseMap['variant'] ?? 'inclass').toString(),
    );

    final paymentSummary = courseMap['payment_summary'];
    final summaryMap = paymentSummary is Map
        ? paymentSummary.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final attendance = courseMap['attendance'];
    final classInfo = courseMap['class'];
    final classMap = classInfo is Map
        ? classInfo.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final classId = (classMap['class_id'] ?? courseMap['class_id'] ?? '')
        .toString()
        .trim();
    final sessionsDone = switch (variantKey) {
      'inclass' => countHeldAttendanceRecords(attendance),
      'private' => countPrivateConsumedAttendanceRecords(
        attendance,
        classId: classId,
      ),
      'flexible' => _flexibleSessionsConsumed(courseMap),
      _ => countPresentUniqueAttendanceDates(attendance),
    };
    final sessionsPaidTotal = asInt(summaryMap['sessionsPaidTotal']);
    final remindBeforeSession = asInt(summaryMap['remindBeforeSession']);

    if (variantKey == 'recorded') {
      final access = courseMap['recorded_access'];
      final accessMap = access is Map
          ? access.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final accessExpiresAt = asInt(accessMap['expiresAt']);
      final summaryExpiresAt = asInt(summaryMap['expiresAt']);
      final effectiveExpiresAt = accessExpiresAt > 0
          ? accessExpiresAt
          : summaryExpiresAt;

      if (effectiveExpiresAt <= 0) return _PayFlag.black;
      if (isExpiredMs(effectiveExpiresAt)) return _PayFlag.red;
      if (isNearExpiryMs(effectiveExpiresAt)) return _PayFlag.yellow;
      return _PayFlag.ok;
    }

    if (variantKey == 'flexible') {
      final access = courseMap['flexible_access'];
      final accessMap = access is Map
          ? access.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final expiresAt = asInt(accessMap['expiresAt']);

      if (sessionsPaidTotal <= 0 && expiresAt <= 0) return _PayFlag.black;
      if (expiresAt > 0 && isExpiredMs(expiresAt)) return _PayFlag.red;
      if (isPaymentDueBySessions(
        sessionsPaidTotal: sessionsPaidTotal,
        sessionsPresent: sessionsDone,
      )) {
        return _PayFlag.red;
      }
      if (expiresAt > 0 && isNearExpiryMs(expiresAt)) return _PayFlag.yellow;
      if (isPaymentWarningBySessions(
        sessionsPaidTotal: sessionsPaidTotal,
        sessionsPresent: sessionsDone,
        remindBeforeSession: 1,
      )) {
        return _PayFlag.yellow;
      }
      return _PayFlag.ok;
    }

    return paymentFlag(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsDone: sessionsDone,
      remindBeforeSession: normalizeReminderForSessions(
        sessionsPaidTotal: sessionsPaidTotal,
        remindBeforeSession: remindBeforeSession,
      ),
    );
  }
}

class _PaymentsAttentionDashCard extends StatelessWidget {
  final VoidCallback onTap;
  final bool isReceptionistStyle;

  const _PaymentsAttentionDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  void _showLearnersSheet(
    BuildContext context, {
    required String title,
    required Color color,
    required String ruleExplanation,
    required List<String> names,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewPadding.bottom;
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 28,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                if (ruleExplanation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 14),
                    child: Text(
                      ruleExplanation,
                      style: TextStyle(
                        color: color.withValues(alpha: 0.65),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                if (names.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No learners in this category.',
                      style: TextStyle(
                        color: AdminHome.softText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: names.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        leading: Icon(Icons.person_rounded, color: color),
                        title: Text(
                          names[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
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
    final usersRef = FirebaseDatabase.instance.ref('users');

    return StreamBuilder<DatabaseEvent>(
      stream: usersRef.onValue,
      builder: (context, snap) {
        if (!snap.hasData) {
          return _buildCardUi(
            context,
            details: const _PaymentAttentionDetails(
              summary: _PaymentAttentionSummary(
                totalLearners: 0,
                noCourse: 0,
                black: 0,
                red: 0,
                yellow: 0,
                ok: 0,
              ),
              noCourseLearners: <String>[],
              overdueLearners: <String>[],
              dueNowLearners: <String>[],
              warningLearners: <String>[],
              okLearners: <String>[],
            ),
            loading: true,
          );
        }

        final details = _PaymentAttentionDetails.fromUsers(
          snap.data?.snapshot.value,
        );

        return _buildCardUi(context, details: details, loading: false);
      },
    );
  }

  Widget _buildCardUi(
    BuildContext context, {
    required _PaymentAttentionDetails details,
    required bool loading,
  }) {
    final isMobileCard = MediaQuery.of(context).size.width < 760;
    final summary = details.summary;
    final accent = isReceptionistStyle
        ? AdminHome.actionOrange
        : AdminHome.accentBlue;
    final borderColor = accent.withValues(alpha: 0.28);
    final boxShadowOpacity = isReceptionistStyle ? 0.045 : 0.06;
    final iconSize = isMobileCard ? 38.0 : 42.0;

    return InkWell(
      borderRadius: BorderRadius.circular(isMobileCard ? 18 : 20),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isReceptionistStyle
              ? const Color(0xFFFFF5ED)
              : const Color(0xFFDCE8FF),
          borderRadius: BorderRadius.circular(isMobileCard ? 18 : 20),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: boxShadowOpacity),
              blurRadius: isReceptionistStyle ? 10 : 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isMobileCard ? 10 : 12,
            vertical: isMobileCard ? 9 : 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: iconSize,
                    height: iconSize,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(
                        isMobileCard ? 12 : 14,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: loading
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            AdminIcons.navPayments,
                            color: Colors.white,
                            size: 22,
                          ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text(
                        'Payments',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14.5,
                          height: 1.08,
                          color: AdminHome.mainText,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: isMobileCard ? 9 : 11),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 78),
                  child: Wrap(
                    spacing: isMobileCard ? 5 : 6,
                    runSpacing: isMobileCard ? 4 : 4,
                    children: [
                      _StatusLabel(
                        label: 'Learners',
                        count: summary.totalLearners,
                        color: Colors.blueGrey,
                        isMobile: isMobileCard,
                      ),
                      _StatusLabel(
                        label: _PayLegend.blackLabel,
                        count: summary.black,
                        color: _PayLegend.blackColor,
                        isMobile: isMobileCard,
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.blackLabel,
                          color: _PayLegend.blackColor,
                          ruleExplanation:
                              'No active payment package or sessions are past due.',
                          names: details.overdueLearners,
                        ),
                      ),
                      _StatusLabel(
                        label: _PayLegend.redLabel,
                        count: summary.red,
                        color: _PayLegend.redColor,
                        isMobile: isMobileCard,
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.redLabel,
                          color: _PayLegend.redColor,
                          ruleExplanation:
                              'All paid sessions have been consumed. Payment is required.',
                          names: details.dueNowLearners,
                        ),
                      ),
                      _StatusLabel(
                        label: _PayLegend.yellowLabel,
                        count: summary.yellow,
                        color: _PayLegend.yellowColor,
                        isMobile: isMobileCard,
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.yellowLabel,
                          color: _PayLegend.yellowColor,
                          ruleExplanation:
                              'Sessions are running low. Payment will be due soon.',
                          names: details.warningLearners,
                        ),
                      ),
                      _StatusLabel(
                        label: _PayLegend.noCourseLabel,
                        count: summary.noCourse,
                        color: _PayLegend.noCourseColor,
                        isMobile: isMobileCard,
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.noCourseLabel,
                          color: _PayLegend.noCourseColor,
                          ruleExplanation: 'Not enrolled in any course.',
                          names: details.noCourseLearners,
                        ),
                      ),
                      _StatusLabel(
                        label: _PayLegend.examLabel,
                        count: summary.exam,
                        color: _PayLegend.examColor,
                        isMobile: isMobileCard,
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.examLabel,
                          color: _PayLegend.examColor,
                          ruleExplanation: 'Currently in exam mode.',
                          names: details.examLearners,
                        ),
                      ),
                    ],
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

class _LearnersDashCard extends StatefulWidget {
  final VoidCallback onTap;
  final bool isReceptionistStyle;
  final int refreshTick;

  const _LearnersDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
    this.refreshTick = 0,
  });

  @override
  State<_LearnersDashCard> createState() => _LearnersDashCardState();
}

class _LearnersDashCardState extends State<_LearnersDashCard> {
  _PaymentAttentionDetails? _manualDetails;
  bool _manualLoading = false;

  @override
  void didUpdateWidget(covariant _LearnersDashCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      unawaited(_recomputeFromLearnerCardLogic());
    }
  }

  void _showLearnersSheet(
    BuildContext context, {
    required String title,
    required Color color,
    required String ruleExplanation,
    required List<String> names,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewPadding.bottom;
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 4,
                      height: 28,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                if (ruleExplanation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 14),
                    child: Text(
                      ruleExplanation,
                      style: TextStyle(
                        color: color.withValues(alpha: 0.65),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                if (names.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No learners in this category.',
                      style: TextStyle(
                        color: AdminHome.softText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: names.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        leading: Icon(Icons.person_rounded, color: color),
                        title: Text(
                          names[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String _normalizeVariantKey(String raw) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'inclass':
      case 'in-class':
      case 'in class':
      case 'in_class':
      case 'class':
        return 'inclass';
      case 'private':
      case 'live':
      case 'vip':
        return 'private';
      case 'flexible':
      case 'online':
        return 'flexible';
      case 'recorded':
      case 'record':
        return 'recorded';
      default:
        return v.isEmpty ? 'inclass' : v;
    }
  }

  static bool _isExpiredMs(int expiresAt) {
    if (expiresAt <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch >= expiresAt;
  }

  static bool _isNearExpiryMs(int expiresAt, {int days = 10}) {
    if (expiresAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = expiresAt - now;
    if (diff < 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  static int _rank(_PayFlag f) {
    switch (f) {
      case _PayFlag.black:
        return 4;
      case _PayFlag.red:
        return 3;
      case _PayFlag.yellow:
        return 2;
      case _PayFlag.exempt:
        return 1;
      case _PayFlag.ok:
      case _PayFlag.noCourse:
        return 0;
      case _PayFlag.exam:
        return 0;
    }
  }

  static int _flexibleSessionsConsumed(Map<String, dynamic> courseMap) {
    final directOnline = countConsumedOnlineAttendance(
      courseMap['online_attendance'],
    );
    if (directOnline > 0) return directOnline;
    final bookingProgress = courseMap['booking_progress'];
    if (bookingProgress is Map) {
      final bp = bookingProgress.map((k, v) => MapEntry(k.toString(), v));
      final nestedOnline = countConsumedOnlineAttendance(
        bp['online_attendance'],
      );
      if (nestedOnline > 0) return nestedOnline;
    }
    return countHeldUniqueAttendanceDates(courseMap['attendance']);
  }

  static _PayFlag _learnerStyleVariantPaymentFlag(
    Map<String, dynamic> courseMap,
  ) {
    if (courseIsFreeBilling(courseMap)) return _PayFlag.exempt;

    final variantKey = _normalizeVariantKey(
      (courseMap['variantKey'] ?? courseMap['variant'] ?? 'inclass').toString(),
    );
    final paymentSummary = courseMap['payment_summary'];
    final summaryMap = paymentSummary is Map
        ? paymentSummary.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final attendance = courseMap['attendance'];
    final classInfo = courseMap['class'];
    final classMap = classInfo is Map
        ? classInfo.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final classId = (classMap['class_id'] ?? courseMap['class_id'] ?? '')
        .toString()
        .trim();
    final sessionsDone = switch (variantKey) {
      'inclass' => countHeldAttendanceRecords(attendance),
      'private' => countPrivateConsumedAttendanceRecords(
        attendance,
        classId: classId,
      ),
      'flexible' => _flexibleSessionsConsumed(courseMap),
      _ => countPresentUniqueAttendanceDates(attendance),
    };

    final sessionsPaidTotal = _asInt(summaryMap['sessionsPaidTotal']);
    final totalPaid = _asInt(summaryMap['totalPaid']);
    final lastAmount = _asInt(summaryMap['lastAmount']);
    final lastPaymentAt = _asInt(summaryMap['lastPaymentAt']);
    final hasPaymentHistory =
        totalPaid > 0 || lastAmount > 0 || lastPaymentAt > 0;
    final effectiveSessionsPaidTotal = sessionsPaidTotal > 0
        ? sessionsPaidTotal
        : (hasPaymentHistory &&
                  (variantKey == 'private' || variantKey == 'inclass')
              ? 8
              : 0);
    final remindBeforeSession = _asInt(summaryMap['remindBeforeSession']);

    if (variantKey == 'recorded') {
      final access = courseMap['recorded_access'];
      final accessMap = access is Map
          ? access.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final accessExpiresAt = _asInt(accessMap['expiresAt']);
      final summaryExpiresAt = _asInt(summaryMap['expiresAt']);
      final effectiveExpiresAt = accessExpiresAt > 0
          ? accessExpiresAt
          : summaryExpiresAt;
      if (effectiveExpiresAt <= 0) return _PayFlag.black;
      if (_isExpiredMs(effectiveExpiresAt)) return _PayFlag.red;
      if (_isNearExpiryMs(effectiveExpiresAt)) return _PayFlag.yellow;
      return _PayFlag.ok;
    }

    if (variantKey == 'flexible') {
      final access = courseMap['flexible_access'];
      final accessMap = access is Map
          ? access.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final expiresAt = _asInt(accessMap['expiresAt']);
      if (effectiveSessionsPaidTotal <= 0 && expiresAt <= 0) {
        return _PayFlag.black;
      }
      if (expiresAt > 0 && _isExpiredMs(expiresAt)) return _PayFlag.red;
      if (isPaymentDueBySessions(
        sessionsPaidTotal: effectiveSessionsPaidTotal,
        sessionsPresent: sessionsDone,
      )) {
        return _PayFlag.red;
      }
      if (expiresAt > 0 && _isNearExpiryMs(expiresAt, days: 10)) {
        return _PayFlag.yellow;
      }
      if (isPaymentWarningBySessions(
        sessionsPaidTotal: effectiveSessionsPaidTotal,
        sessionsPresent: sessionsDone,
        remindBeforeSession: normalizeReminderForSessions(
          sessionsPaidTotal: effectiveSessionsPaidTotal,
          remindBeforeSession: remindBeforeSession > 0
              ? remindBeforeSession
              : 2,
        ),
      )) {
        return _PayFlag.yellow;
      }
      return _PayFlag.ok;
    }

    if (effectiveSessionsPaidTotal <= 0) return _PayFlag.black;
    if (isPaymentDueBySessions(
      sessionsPaidTotal: effectiveSessionsPaidTotal,
      sessionsPresent: sessionsDone,
    )) {
      return _PayFlag.red;
    }
    if (isPaymentWarningBySessions(
      sessionsPaidTotal: effectiveSessionsPaidTotal,
      sessionsPresent: sessionsDone,
      remindBeforeSession: normalizeReminderForSessions(
        sessionsPaidTotal: effectiveSessionsPaidTotal,
        remindBeforeSession: remindBeforeSession,
      ),
    )) {
      return _PayFlag.yellow;
    }
    return _PayFlag.ok;
  }

  Future<void> _recomputeFromLearnerCardLogic() async {
    if (_manualLoading) return;
    setState(() => _manualLoading = true);
    final usersSnap = await FirebaseDatabase.instance.ref('users').get();
    final usersVal = usersSnap.value;

    final noCourse = <String>[];
    final overdue = <String>[];
    final dueNow = <String>[];
    final warning = <String>[];
    final ok = <String>[];
    final exam = <String>[];

    if (usersVal is Map) {
      for (final entry in usersVal.entries) {
        final uid = '${entry.key}'.trim();
        final userVal = entry.value;
        if (uid.isEmpty || userVal is! Map) continue;
        final userMap = userVal.map((k, v) => MapEntry(k.toString(), v));
        final role = (userMap['role'] ?? '').toString().trim().toLowerCase();
        if (role != 'learner' && role != 'learners' && role != 'learner(s)') {
          continue;
        }

        final fn = (userMap['first_name'] ?? userMap['firstName'] ?? '')
            .toString()
            .trim();
        final ln = (userMap['last_name'] ?? userMap['lastName'] ?? '')
            .toString()
            .trim();
        final email = (userMap['email'] ?? '').toString().trim();
        final displayName = ('$fn $ln').trim().isNotEmpty
            ? ('$fn $ln').trim()
            : (email.isNotEmpty ? email : uid);

        final isExam =
            userMap['examMode'] == true ||
            userMap['examMode']?.toString() == 'true';
        if (isExam) {
          exam.add(displayName);
          continue;
        }

        try {
          final coursesSnap = await FirebaseDatabase.instance
              .ref('users/$uid/courses')
              .get();
          final coursesVal = coursesSnap.value;
          if (coursesVal is! Map || coursesVal.isEmpty) {
            noCourse.add(displayName);
            continue;
          }

          var hasAtLeastOneCourse = false;
          _PayFlag best = _PayFlag.ok;
          coursesVal.forEach((_, courseVal) {
            if (courseVal is! Map) return;
            hasAtLeastOneCourse = true;
            final courseMap = courseVal
                .map((k, vv) => MapEntry(k.toString(), vv))
                .cast<String, dynamic>();
            final flag = _learnerStyleVariantPaymentFlag(courseMap);
            if (_rank(flag) > _rank(best)) best = flag;
          });

          if (!hasAtLeastOneCourse) {
            noCourse.add(displayName);
            continue;
          }

          switch (best) {
            case _PayFlag.black:
              overdue.add(displayName);
              break;
            case _PayFlag.exempt:
              ok.add(displayName);
              break;
            case _PayFlag.red:
              dueNow.add(displayName);
              break;
            case _PayFlag.yellow:
              warning.add(displayName);
              break;
            case _PayFlag.ok:
              ok.add(displayName);
              break;
            case _PayFlag.noCourse:
              noCourse.add(displayName);
              break;
            case _PayFlag.exam:
              exam.add(displayName);
              break;
          }
        } catch (_) {
          continue;
        }
      }
    }

    int sortCaseInsensitive(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    noCourse.sort(sortCaseInsensitive);
    overdue.sort(sortCaseInsensitive);
    dueNow.sort(sortCaseInsensitive);
    warning.sort(sortCaseInsensitive);
    ok.sort(sortCaseInsensitive);
    exam.sort(sortCaseInsensitive);

    if (!mounted) return;
    setState(() {
      _manualDetails = _PaymentAttentionDetails(
        summary: _PaymentAttentionSummary(
          totalLearners:
              noCourse.length +
              overdue.length +
              dueNow.length +
              warning.length +
              ok.length +
              exam.length,
          noCourse: noCourse.length,
          black: overdue.length,
          red: dueNow.length,
          yellow: warning.length,
          ok: ok.length,
          exam: exam.length,
        ),
        noCourseLearners: noCourse,
        overdueLearners: overdue,
        dueNowLearners: dueNow,
        warningLearners: warning,
        okLearners: ok,
        examLearners: exam,
      );
      _manualLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final usersRef = FirebaseDatabase.instance.ref('users');

    return StreamBuilder<DatabaseEvent>(
      stream: usersRef.onValue,
      builder: (context, snap) {
        final streamDetails = _PaymentAttentionDetails.fromUsers(
          snap.data?.snapshot.value,
        );
        final details = _manualDetails ?? streamDetails;
        final summary = details.summary;

        if (!snap.hasData) {
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: widget.onTap,
            child: _learnersCardUi(
              context: context,
              total: 0,
              black: 0,
              red: 0,
              yellow: 0,
              ok: 0,
              blue: 0,
              exam: 0,
              noCourseNames: const <String>[],
              blackNames: const <String>[],
              redNames: const <String>[],
              yellowNames: const <String>[],
              okNames: const <String>[],
              examNames: const <String>[],
              loading: true,
              isReceptionistStyle: widget.isReceptionistStyle,
            ),
          );
        }

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: widget.onTap,
          child: _learnersCardUi(
            context: context,
            total: summary.totalLearners,
            black: summary.black,
            red: summary.red,
            yellow: summary.yellow,
            ok: summary.ok,
            blue: summary.noCourse,
            exam: summary.exam,
            noCourseNames: details.noCourseLearners,
            blackNames: details.overdueLearners,
            redNames: details.dueNowLearners,
            yellowNames: details.warningLearners,
            okNames: details.okLearners,
            examNames: details.examLearners,
            loading: _manualLoading,
            isReceptionistStyle: widget.isReceptionistStyle,
          ),
        );
      },
    );
  }

  Widget _learnersCardUi({
    required BuildContext context,
    required int total,
    required int black,
    required int red,
    required int yellow,
    required int ok,
    required int blue,
    required int exam,
    required List<String> noCourseNames,
    required List<String> blackNames,
    required List<String> redNames,
    required List<String> yellowNames,
    required List<String> okNames,
    required List<String> examNames,
    required bool loading,
    required bool isReceptionistStyle,
  }) {
    final isMobileCard = MediaQuery.of(context).size.width < 760;
    final accent = isReceptionistStyle
        ? AdminHome.actionOrange
        : AdminHome.accentPurple;
    final borderColor = accent.withValues(alpha: 0.28);
    final boxShadowOpacity = isReceptionistStyle ? 0.045 : 0.06;
    final iconSize = isMobileCard ? 38.0 : 42.0;

    return Container(
      decoration: BoxDecoration(
        color: isReceptionistStyle
            ? const Color(0xFFFFF5ED)
            : const Color(0xFFE9DDFF),
        borderRadius: BorderRadius.circular(isMobileCard ? 18 : 20),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: boxShadowOpacity),
            blurRadius: isReceptionistStyle ? 10 : 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isMobileCard ? 10 : 12,
          vertical: isMobileCard ? 9 : 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(isMobileCard ? 12 : 14),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.25),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: loading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.school_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'Learners',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14.5,
                        height: 1.08,
                        color: AdminHome.mainText,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: isMobileCard ? 9 : 11),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 78),
                child: Wrap(
                  spacing: isMobileCard ? 5 : 6,
                  runSpacing: isMobileCard ? 4 : 4,
                  children: [
                    _StatusLabel(
                      label: 'Learners',
                      count: total,
                      color: Colors.blueGrey,
                      isMobile: isMobileCard,
                    ),
                    _StatusLabel(
                      label: _PayLegend.noCourseLabel,
                      count: blue,
                      color: _PayLegend.noCourseColor,
                      isMobile: isMobileCard,
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.noCourseLabel,
                        color: _PayLegend.noCourseColor,
                        ruleExplanation: 'Not enrolled in any course.',
                        names: noCourseNames,
                      ),
                    ),
                    _StatusLabel(
                      label: _PayLegend.blackLabel,
                      count: black,
                      color: _PayLegend.blackColor,
                      isMobile: isMobileCard,
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.blackLabel,
                        color: _PayLegend.blackColor,
                        ruleExplanation:
                            'No active payment package or sessions are past due.',
                        names: blackNames,
                      ),
                    ),
                    _StatusLabel(
                      label: _PayLegend.redLabel,
                      count: red,
                      color: _PayLegend.redColor,
                      isMobile: isMobileCard,
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.redLabel,
                        color: _PayLegend.redColor,
                        ruleExplanation:
                            'All paid sessions have been consumed. Payment is required.',
                        names: redNames,
                      ),
                    ),
                    _StatusLabel(
                      label: _PayLegend.yellowLabel,
                      count: yellow,
                      color: _PayLegend.yellowColor,
                      isMobile: isMobileCard,
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.yellowLabel,
                        color: _PayLegend.yellowColor,
                        ruleExplanation:
                            'Sessions are running low. Payment will be due soon.',
                        names: yellowNames,
                      ),
                    ),
                    _StatusLabel(
                      label: _PayLegend.okLabel,
                      count: ok,
                      color: _PayLegend.okColor,
                      isMobile: isMobileCard,
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.okLabel,
                        color: _PayLegend.okColor,
                        ruleExplanation: 'Payment is up to date.',
                        names: okNames,
                      ),
                    ),
                    _StatusLabel(
                      label: _PayLegend.examLabel,
                      count: exam,
                      color: _PayLegend.examColor,
                      isMobile: isMobileCard,
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.examLabel,
                        color: _PayLegend.examColor,
                        ruleExplanation: 'Currently in exam mode.',
                        names: examNames,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemindersDashCard extends StatelessWidget {
  const _RemindersDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('reminders');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int done = 0;
        int seen = 0;
        int undone = 0;

        final root = snap.data?.snapshot.value;
        if (root is Map) {
          root.forEach((_, teacherNode) {
            if (teacherNode is! Map) return;
            final remindersMap = Map<dynamic, dynamic>.from(teacherNode);
            remindersMap.forEach((_, reminderVal) {
              if (reminderVal is! Map) return;
              final m = reminderVal.map((k, v) => MapEntry(k.toString(), v));
              final status = ReminderConsistencyService.normalizeStatus(
                m['status'],
              );
              if (status == 'done') {
                done += 1;
              } else if (status == 'read') {
                seen += 1;
              } else {
                undone += 1;
              }
            });
          });
        }

        return _DashCard(
          title: 'Reminders',
          statusLabels: [
            _StatusLabelData(
              label: 'Undone',
              count: undone,
              color: AdminHome.accentRose,
            ),
            _StatusLabelData(
              label: 'Seen',
              count: seen,
              color: AdminHome.accentBlue,
            ),
            _StatusLabelData(
              label: 'Done',
              count: done,
              color: AdminHome.accentGreen,
            ),
          ],
          icon: Icons.notifications_active_rounded,
          color: AdminHome.accentPurple,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _StaffMailDashCard extends StatelessWidget {
  const _StaffMailDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final meUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (meUid.isEmpty) {
      return _DashCard(
        title: 'Staff',
        icon: AdminIcons.staff,
        color: AdminHome.accentAmber,
        isReceptionistStyle: isReceptionistStyle,
        onTap: onTap,
      );
    }

    final ref = FirebaseDatabase.instance.ref('mail_index/$meUid');
    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int threads = 0;
        int unread = 0;

        final root = snap.data?.snapshot.value;
        if (root is Map) {
          threads = root.length;
          unread = NotificationCounterService.mailUnread(
            root,
            excludeHomework: true,
          );
        }

        return _DashCard(
          title: 'Staff',
          statusLabels: [
            _StatusLabelData(
              label: 'Unread',
              count: unread,
              color: AdminHome.accentRose,
            ),
            _StatusLabelData(
              label: 'Threads',
              count: threads,
              color: AdminHome.accentBlue,
            ),
          ],
          icon: AdminIcons.staff,
          color: AdminHome.accentAmber,
          badgeCount: unread,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _AdminMailDashCard extends StatelessWidget {
  const _AdminMailDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  @override
  Widget build(BuildContext context) {
    final meUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (meUid.isEmpty) {
      return _DashCard(
        title: 'Admin Mail',
        icon: AdminIcons.adminMail,
        color: AdminHome.accentSky,
        isReceptionistStyle: isReceptionistStyle,
        onTap: onTap,
      );
    }

    final ref = FirebaseDatabase.instance.ref('mail_index/$meUid');
    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int threads = 0;
        int unread = 0;

        final root = snap.data?.snapshot.value;
        if (root is Map) {
          threads = root.length;
          unread = NotificationCounterService.mailUnread(
            root,
            excludeHomework: false,
          );
        }

        return _DashCard(
          title: 'Admin Mail',
          statusLabels: [
            _StatusLabelData(
              label: 'Unread',
              count: unread,
              color: AdminHome.accentRose,
            ),
            _StatusLabelData(
              label: 'Threads',
              count: threads,
              color: AdminHome.accentBlue,
            ),
          ],
          icon: AdminIcons.adminMail,
          color: AdminHome.accentSky,
          badgeCount: unread,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

class _StatusLabelData {
  final String label;
  final int count;
  final Color color;

  const _StatusLabelData({
    required this.label,
    required this.count,
    required this.color,
  });
}

class _StatusLabel extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final bool isMobile;
  final VoidCallback? onTap;

  const _StatusLabel({
    required this.label,
    required this.count,
    required this.color,
    required this.isMobile,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 6 : 8,
        vertical: isMobile ? 3.5 : 4.5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: isMobile ? 9.5 : 10,
          height: 1,
        ),
      ),
    );

    if (onTap == null) return chip;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: chip,
      ),
    );
  }
}

// ===================== GENERIC DASH CARD =====================

class _DashCard extends StatelessWidget {
  final String title;
  final List<_StatusLabelData> statusLabels;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final int badgeCount;
  final bool isReceptionistStyle;

  const _DashCard({
    required this.title,
    this.statusLabels = const [],
    required this.icon,
    required this.color,
    required this.onTap,
    this.badgeCount = 0,
    this.isReceptionistStyle = false,
  });

  Color _softBg(Color color) {
    if (color == AdminHome.actionOrange) return const Color(0xFFFFE3CC);
    if (color == AdminHome.accentBlue) return const Color(0xFFDCE8FF);
    if (color == AdminHome.accentTeal) return const Color(0xFFD8F7F0);
    if (color == AdminHome.accentPurple) return const Color(0xFFE9DDFF);
    if (color == AdminHome.accentAmber) return const Color(0xFFFFEAB0);
    if (color == AdminHome.accentSky) return const Color(0xFFD8F1FF);
    if (color == AdminHome.accentRose) return const Color(0xFFFFD7D6);
    if (color == AdminHome.accentIndigo) return const Color(0xFFE2E5FF);
    if (color == AdminHome.accentSlate) return const Color(0xFFE2E8F0);
    if (color == AdminHome.accentCyan) return const Color(0xFFD5F7FE);
    if (color == AdminHome.accentGreen) return const Color(0xFFD9F8E6);
    return const Color(0xFFDCE8FF);
  }

  @override
  Widget build(BuildContext context) {
    final isMobileCard = MediaQuery.of(context).size.width < 760;
    final borderColor = isReceptionistStyle
        ? AdminHome.actionOrange.withValues(alpha: 0.35)
        : color.withValues(alpha: 0.24);
    final shadowOpacity = isReceptionistStyle ? 0.045 : 0.06;
    final cardBg = isReceptionistStyle
        ? const Color(0xFFFFF5ED)
        : _softBg(color);
    final iconSize = isMobileCard ? 38.0 : 42.0;

    return InkWell(
      borderRadius: BorderRadius.circular(isMobileCard ? 18 : 20),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(isMobileCard ? 18 : 20),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: shadowOpacity),
              blurRadius: isReceptionistStyle ? 10 : 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(isMobileCard ? 10 : 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: iconSize,
                    height: iconSize,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(
                        isMobileCard ? 12 : 14,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      icon,
                      color: Colors.white,
                      size: isMobileCard ? 20 : 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: isMobileCard ? 1 : 2),
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: isMobileCard ? 13 : 14.5,
                          height: 1.08,
                          color: AdminHome.mainText,
                        ),
                      ),
                    ),
                  ),
                  if (badgeCount > 0)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badgeCount > 99 ? '99+' : badgeCount.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 9.5,
                        ),
                      ),
                    ),
                ],
              ),
              if (statusLabels.isNotEmpty) ...[
                SizedBox(height: isMobileCard ? 9 : 11),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 78),
                    child: Wrap(
                      spacing: isMobileCard ? 5 : 6,
                      runSpacing: isMobileCard ? 4 : 4,
                      children: statusLabels
                          .map(
                            (sl) => _StatusLabel(
                              label: sl.label,
                              count: sl.count,
                              color: sl.color,
                              isMobile: isMobileCard,
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CourseFeedbackDashCard extends StatelessWidget {
  const _CourseFeedbackDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Future<int> _reportedCount() async {
    final db = FirebaseDatabase.instance.ref();
    final results = await Future.wait([
      db.child('course_reviews').get(),
      db.child('lesson_comments').get(),
    ]);

    var count = 0;

    final reviewsSnap = results[0];
    if (reviewsSnap.exists && reviewsSnap.value is Map) {
      final byCourse = Map<dynamic, dynamic>.from(reviewsSnap.value as Map);
      for (final c in byCourse.values) {
        if (c is! Map) continue;
        final revs = Map<dynamic, dynamic>.from(c);
        for (final v in revs.values) {
          if (v is! Map) continue;
          final m = v.map((k, v) => MapEntry('$k', v));
          final status = (m['status'] ?? '').toString();
          final reports = _asInt(m['reportCount']);
          if (status != 'removed' && reports > 0) count += reports;
        }
      }
    }

    final commentsSnap = results[1];
    if (commentsSnap.exists && commentsSnap.value is Map) {
      final byCourse = Map<dynamic, dynamic>.from(commentsSnap.value as Map);
      for (final c in byCourse.values) {
        if (c is! Map) continue;
        final lessons = Map<dynamic, dynamic>.from(c);
        for (final l in lessons.values) {
          if (l is! Map) continue;
          final cm = Map<dynamic, dynamic>.from(l);
          for (final v in cm.values) {
            if (v is! Map) continue;
            final m = v.map((k, v) => MapEntry('$k', v));
            final status = (m['status'] ?? '').toString();
            final reports = _asInt(m['reportCount']);
            if (status != 'removed' && reports > 0) count += reports;
          }
        }
      }
    }

    return count;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: _reportedCount(),
      builder: (context, snap) {
        final reported = snap.data ?? 0;
        return _DashCard(
          title: 'Course Reviews',
          statusLabels: [
            _StatusLabelData(
              label: 'Reported',
              count: reported,
              color: AdminHome.accentRose,
            ),
          ],
          icon: AdminIcons.courseReviews,
          color: AdminHome.accentAmber,
          badgeCount: reported,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

// ===================== FORCE UPDATE SCREEN (YOUR ORIGINAL, UNCHANGED LOGIC) =====================

class AdminForceUpdateAllScreen extends StatefulWidget {
  const AdminForceUpdateAllScreen({super.key});

  @override
  State<AdminForceUpdateAllScreen> createState() =>
      _AdminForceUpdateAllScreenState();
}

class _AdminForceUpdateAllScreenState extends State<AdminForceUpdateAllScreen>
    with SingleTickerProviderStateMixin {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const softText = Color(0xFF5E6B70);

  // ANDROID controllers
  final aMinVersionC = TextEditingController();
  final aMinBuildC = TextEditingController();
  final aMessageC = TextEditingController();
  final aStoreUrlC = TextEditingController();
  final aStoreWebUrlC = TextEditingController();

  // IOS controllers
  final iMinVersionC = TextEditingController();
  final iMinBuildC = TextEditingController();
  final iMessageC = TextEditingController();
  final iStoreUrlC = TextEditingController();
  final iStoreWebUrlC = TextEditingController();

  // COMPANY controllers
  final cFullNameC = TextEditingController();
  final cPhoneC = TextEditingController();
  final cEmailC = TextEditingController();
  final cAccreditationC = TextEditingController();
  final cAddressC = TextEditingController();
  final cAcademicDirectorC = TextEditingController();

  // AVATAR state
  List<String> _avatarUrls = [];
  int _uploadingAvatarTotal = 0;
  int _uploadingAvatarDone = 0;

  bool loading = true;
  bool saving = false;

  late final TabController _tabController;
  int _activeTab = 0;

  DatabaseReference get _forceUpdateRoot =>
      FirebaseDatabase.instance.ref('appConfig/forceUpdate');
  DatabaseReference get _companyRoot =>
      FirebaseDatabase.instance.ref('appConfig/Company info');
  DatabaseReference get _companyAltRoot =>
      FirebaseDatabase.instance.ref('appConfig/companyInfo');
  DatabaseReference get _avatarRoot =>
      FirebaseDatabase.instance.ref('appConfig/avatarPresets');

  String _normalizeKey(String raw) {
    return raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  dynamic _valueByAliases(Map<String, dynamic> m, List<String> aliases) {
    final normalized = <String, dynamic>{};
    m.forEach((k, v) {
      normalized[_normalizeKey(k)] = v;
    });

    for (final alias in aliases) {
      final key = _normalizeKey(alias);
      if (normalized.containsKey(key)) {
        return normalized[key];
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging && mounted) {
          setState(() => _activeTab = _tabController.index);
        }
      });

    _loadAll();
  }

  @override
  void dispose() {
    aMinVersionC.dispose();
    aMinBuildC.dispose();
    aMessageC.dispose();
    aStoreUrlC.dispose();
    aStoreWebUrlC.dispose();

    iMinVersionC.dispose();
    iMinBuildC.dispose();
    iMessageC.dispose();
    iStoreUrlC.dispose();
    iStoreWebUrlC.dispose();

    cFullNameC.dispose();
    cPhoneC.dispose();
    cEmailC.dispose();
    cAccreditationC.dispose();
    cAddressC.dispose();
    cAcademicDirectorC.dispose();

    _tabController.dispose();

    super.dispose();
  }

  void _fillControllersFromMap({
    required Map<String, dynamic> m,
    required TextEditingController minVersionC,
    required TextEditingController minBuildC,
    required TextEditingController messageC,
    required TextEditingController storeUrlC,
    required TextEditingController storeWebUrlC,
  }) {
    minVersionC.text =
        (_valueByAliases(m, [
                  'minVersion',
                  'min_version',
                  'minversion',
                  'version',
                  'min',
                ]) ??
                '')
            .toString();
    minBuildC.text =
        (_valueByAliases(m, ['minBuild', 'min_build', 'minbuild', 'build']) ??
                '')
            .toString();
    messageC.text = (_valueByAliases(m, ['message', 'msg']) ?? '').toString();
    storeUrlC.text =
        (_valueByAliases(m, ['storeUrl', 'store_url', 'store']) ?? '')
            .toString();
    storeWebUrlC.text =
        (_valueByAliases(m, [
                  'storeWebUrl',
                  'store_web_url',
                  'webUrl',
                  'web_url',
                ]) ??
                '')
            .toString();
  }

  Map<String, dynamic> _controllersToMap({
    required TextEditingController minVersionC,
    required TextEditingController minBuildC,
    required TextEditingController messageC,
    required TextEditingController storeUrlC,
    required TextEditingController storeWebUrlC,
  }) {
    return {
      'minVersion': minVersionC.text.trim(),
      'minBuild': int.tryParse(minBuildC.text.trim()) ?? 0,
      'message': messageC.text.trim(),
      'storeUrl': storeUrlC.text.trim(),
      'storeWebUrl': storeWebUrlC.text.trim(),
    };
  }

  void _fillCompanyControllers(Map<String, dynamic> m) {
    cFullNameC.text = (m['companyFullName'] ?? m['company full name'] ?? '')
        .toString();
    cPhoneC.text = (m['companyPhone'] ?? m['company phone'] ?? '').toString();
    cEmailC.text = (m['companyEmail'] ?? m['company email'] ?? '').toString();
    cAccreditationC.text =
        (m['companyAccreditationNumber'] ??
                m['company accreditation number'] ??
                '')
            .toString();
    cAddressC.text = (m['companyAddress'] ?? m['company address'] ?? '')
        .toString();
    cAcademicDirectorC.text =
        (m['academicDirectorName'] ??
                m['academic director name'] ??
                m['directorName'] ??
                '')
            .toString();
  }

  Map<String, dynamic> _companyControllersToMap() {
    return {
      'companyFullName': cFullNameC.text.trim(),
      'companyPhone': cPhoneC.text.trim(),
      'companyEmail': cEmailC.text.trim(),
      'companyAccreditationNumber': cAccreditationC.text.trim(),
      'companyAddress': cAddressC.text.trim(),
      'academicDirectorName': cAcademicDirectorC.text.trim(),
    };
  }

  Future<void> _loadAll() async {
    setState(() => loading = true);
    try {
      final snap = await _forceUpdateRoot.get();
      final v = snap.value;

      Map<String, dynamic> android = {};
      Map<String, dynamic> ios = {};

      if (v is Map) {
        final rootMap = v.map((k, val) => MapEntry(k.toString(), val));

        final av = rootMap['android'];
        if (av is Map) {
          android = av.map((k, val) => MapEntry(k.toString(), val));
        }

        final iv = rootMap['ios'];
        if (iv is Map) {
          ios = iv.map((k, val) => MapEntry(k.toString(), val));
        }
      }

      _fillControllersFromMap(
        m: android,
        minVersionC: aMinVersionC,
        minBuildC: aMinBuildC,
        messageC: aMessageC,
        storeUrlC: aStoreUrlC,
        storeWebUrlC: aStoreWebUrlC,
      );

      _fillControllersFromMap(
        m: ios,
        minVersionC: iMinVersionC,
        minBuildC: iMinBuildC,
        messageC: iMessageC,
        storeUrlC: iStoreUrlC,
        storeWebUrlC: iStoreWebUrlC,
      );

      Map<String, dynamic> company = {};
      final companySnap = await _companyRoot.get();
      if (companySnap.value is Map) {
        company = (companySnap.value as Map).map(
          (k, val) => MapEntry(k.toString(), val),
        );
      } else {
        final altSnap = await _companyAltRoot.get();
        if (altSnap.value is Map) {
          company = (altSnap.value as Map).map(
            (k, val) => MapEntry(k.toString(), val),
          );
        }
      }

      _fillCompanyControllers(company);

      final avatarSnap = await _avatarRoot.get();
      if (avatarSnap.value is List) {
        _avatarUrls = (avatarSnap.value as List)
            .map((e) => e.toString())
            .toList();
      } else {
        _avatarUrls = [];
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not load app configuration.'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _saveAll() async {
    setState(() => saving = true);

    try {
      final android = _controllersToMap(
        minVersionC: aMinVersionC,
        minBuildC: aMinBuildC,
        messageC: aMessageC,
        storeUrlC: aStoreUrlC,
        storeWebUrlC: aStoreWebUrlC,
      );

      final ios = _controllersToMap(
        minVersionC: iMinVersionC,
        minBuildC: iMinBuildC,
        messageC: iMessageC,
        storeUrlC: iStoreUrlC,
        storeWebUrlC: iStoreWebUrlC,
      );

      await _forceUpdateRoot.update({
        'allowAdminBypass': true,
        'android': android,
        'ios': ios,
      });

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Saved all ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not save force-update settings.'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }

  Future<void> _saveCompany() async {
    setState(() => saving = true);
    try {
      await _companyRoot.set(_companyControllersToMap());

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Company info saved ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not save company information.'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String msg) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(msg),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        )) ??
        false;
  }

  Future<void> _deleteAndroid() async {
    final ok = await _confirm(
      context,
      'Delete Android config?',
      'This removes appConfig/forceUpdate/android.',
    );
    if (!ok) return;
    await _forceUpdateRoot.child('android').remove();
    await _loadAll();
  }

  Future<void> _deleteIos() async {
    final ok = await _confirm(
      context,
      'Delete iOS config?',
      'This removes appConfig/forceUpdate/ios.',
    );
    if (!ok) return;
    await _forceUpdateRoot.child('ios').remove();
    await _loadAll();
  }

  Future<void> _deleteAll() async {
    final ok = await _confirm(
      context,
      'Delete ALL forceUpdate?',
      'This removes appConfig/forceUpdate بالكامل.',
    );
    if (!ok) return;
    await _forceUpdateRoot.remove();
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _deleteCompany() async {
    final ok = await _confirm(
      context,
      'Delete Company info?',
      'This removes appConfig/Company info.',
    );
    if (!ok) return;
    await _companyRoot.remove();
    await _loadAll();
  }

  Future<void> _autosaveAvatars() async {
    try {
      await _avatarRoot.set(_avatarUrls);
    } catch (_) {}
  }

  Future<void> _uploadAvatar() async {
    if (_uploadingAvatarTotal > 0) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _uploadingAvatarTotal = result.files.length;
      _uploadingAvatarDone = 0;
    });

    int successCount = 0;
    int failCount = 0;
    void _doneOne() {
      if (mounted) setState(() => _uploadingAvatarDone++);
    }

    for (int i = 0; i < result.files.length; i++) {
      if (!mounted) break;
      final file = result.files[i];
      try {
        final uploadUri = await BackendApi.withAuthQuery(
          BackendApi.uri('upload_secure.php'),
        );
        final request = http.MultipartRequest('POST', uploadUri)
          ..headers['X-Requested-With'] = 'XMLHttpRequest'
          ..fields['app_id'] = 'avatar_presets_${user.uid}';
        await BackendApi.applyAuthToMultipart(request);

        if (kIsWeb) {
          final bytes = file.bytes;
          if (bytes == null || bytes.isEmpty) {
            failCount++;
            _doneOne();
            continue;
          }
          request.files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: file.name),
          );
        } else {
          final path = file.path;
          if (path == null || path.trim().isEmpty) {
            failCount++;
            _doneOne();
            continue;
          }
          request.files.add(
            await http.MultipartFile.fromPath(
              'file',
              path,
              filename: file.name,
            ),
          );
        }

        final streamed = await request.send();
        final body = await streamed.stream.bytesToString();
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          failCount++;
          _doneOne();
          continue;
        }
        final decoded = jsonDecode(body);
        if (decoded is! Map || decoded['success'] != true) {
          failCount++;
          _doneOne();
          continue;
        }
        final url = (decoded['url'] ?? '').toString().trim();
        if (url.isEmpty) {
          failCount++;
          _doneOne();
          continue;
        }

        successCount++;
        if (mounted) {
          setState(() {
            _avatarUrls = [..._avatarUrls, url];
            _uploadingAvatarDone++;
          });
          await _autosaveAvatars();
        }
      } catch (_) {
        failCount++;
        if (mounted) setState(() => _uploadingAvatarDone++);
      }
    }

    if (!mounted) return;
    setState(() {
      _uploadingAvatarTotal = 0;
      _uploadingAvatarDone = 0;
    });

    final msg = failCount == 0
        ? '$successCount avatar${successCount == 1 ? '' : 's'} uploaded ✅'
        : '$successCount uploaded, $failCount failed';
    if (mounted) {
      AppToast.fromSnackBar(context, SnackBar(content: Text(msg)));
    }
  }

  Future<void> _deleteAvatarFromServer(String url) async {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      const knownRoots = [
        'courses',
        'games',
        'stories',
        'shared_files',
        'certificates',
      ];
      final rootIdx = segments.indexWhere((s) => knownRoots.contains(s));
      if (rootIdx < 0) return;
      final root = segments[rootIdx];
      final path = segments.sublist(rootIdx + 1).join('/');

      final deleteUri = await BackendApi.withAuthQuery(
        BackendApi.uri('delete_file_secure.php'),
      );
      final request = http.MultipartRequest('POST', deleteUri)
        ..fields['root'] = root
        ..fields['path'] = path;
      await BackendApi.applyAuthToMultipart(request);
      await request.send();
    } catch (_) {}
  }

  Future<void> _removeAvatar(int index) async {
    if (index < 0 || index >= _avatarUrls.length) return;
    final url = _avatarUrls[index];
    final ok = await _confirm(
      context,
      'Remove avatar?',
      'Delete this avatar image permanently?',
    );
    if (!ok) return;
    await _deleteAvatarFromServer(url);
    if (!mounted) return;
    setState(() {
      _avatarUrls = [..._avatarUrls]..removeAt(index);
    });
    await _autosaveAvatars();
  }

  void _moveAvatarUp(int index) {
    if (index <= 0 || index >= _avatarUrls.length) return;
    setState(() {
      final list = [..._avatarUrls];
      final temp = list[index];
      list[index] = list[index - 1];
      list[index - 1] = temp;
      _avatarUrls = list;
    });
    _autosaveAvatars();
  }

  void _moveAvatarDown(int index) {
    if (index < 0 || index >= _avatarUrls.length - 1) return;
    setState(() {
      final list = [..._avatarUrls];
      final temp = list[index];
      list[index] = list[index + 1];
      list[index + 1] = temp;
      _avatarUrls = list;
    });
    _autosaveAvatars();
  }

  void _showAvatarViewer(int initialIndex) {
    if (_avatarUrls.isEmpty) return;
    final pageController = PageController(initialPage: initialIndex);
    int currentPage = initialIndex;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close viewer',
      barrierColor: Colors.black,
      pageBuilder: (ctx, anim1, anim2) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                backgroundColor: Colors.black87,
                iconTheme: const IconThemeData(color: Colors.white),
                title: Text(
                  '${currentPage + 1} / ${_avatarUrls.length}',
                  style: const TextStyle(color: Colors.white),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              body: GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                child: PageView.builder(
                  controller: pageController,
                  itemCount: _avatarUrls.length,
                  onPageChanged: (page) {
                    setDialogState(() => currentPage = page);
                    _precacheAdjacentAvatars(page);
                  },
                  itemBuilder: (ctx, index) {
                    final url = _avatarUrls[index];
                    return InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 4.0,
                      child: Center(
                        child: Image.network(
                          url,
                          fit: BoxFit.contain,
                          loadingBuilder: (_, child, progress) {
                            if (progress == null) return child;
                            return Center(
                              child: CircularProgressIndicator(
                                value: progress.expectedTotalBytes != null
                                    ? progress.cumulativeBytesLoaded /
                                          progress.expectedTotalBytes!
                                    : null,
                                color: Colors.white,
                              ),
                            );
                          },
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                            size: 64,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _precacheAdjacentAvatars(int index) {
    if (_avatarUrls.isEmpty) return;
    for (final offset in [-1, 1]) {
      final idx = index + offset;
      if (idx >= 0 && idx < _avatarUrls.length) {
        unawaited(
          precacheImage(
            NetworkImage(_avatarUrls[idx]),
            context,
            onError: (_, _) {},
          ),
        );
      }
    }
  }

  Widget _section({
    required String title,
    required TextEditingController minVersionC,
    required TextEditingController minBuildC,
    required TextEditingController messageC,
    required TextEditingController storeUrlC,
    required TextEditingController storeWebUrlC,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: primaryBlue,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: minVersionC,
            decoration: const InputDecoration(
              labelText: 'minVersion (example: 2.0.0)',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: minBuildC,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'minBuild (example: 76)',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: messageC,
            decoration: const InputDecoration(labelText: 'message'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: storeUrlC,
            decoration: const InputDecoration(labelText: 'storeUrl'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: storeWebUrlC,
            decoration: const InputDecoration(labelText: 'storeWebUrl'),
          ),
        ],
      ),
    );
  }

  Widget _companySection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Company info',
            style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: cFullNameC,
            decoration: const InputDecoration(labelText: 'Company full name'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: cPhoneC,
            decoration: const InputDecoration(labelText: 'Company phone'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: cEmailC,
            decoration: const InputDecoration(labelText: 'Company email'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: cAccreditationC,
            decoration: const InputDecoration(
              labelText: 'Company accreditation number',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: cAddressC,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Company address'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: cAcademicDirectorC,
            decoration: const InputDecoration(
              labelText: 'Academic director name',
              hintText: "Used on certificates",
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForceUpdateTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _section(
          title: 'Android',
          minVersionC: aMinVersionC,
          minBuildC: aMinBuildC,
          messageC: aMessageC,
          storeUrlC: aStoreUrlC,
          storeWebUrlC: aStoreWebUrlC,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _deleteAndroid,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete Android'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _section(
          title: 'iOS',
          minVersionC: iMinVersionC,
          minBuildC: iMinBuildC,
          messageC: iMessageC,
          storeUrlC: iStoreUrlC,
          storeWebUrlC: iStoreWebUrlC,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _deleteIos,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete iOS'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: appBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: uiBorder),
          ),
          child: const Text(
            'Tip:\n- To force update, increase minBuild.\n- Example: users 75 -> set minBuild 76.\n- If you want to block by version, increase minVersion.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _buildCompanyTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _companySection(),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: appBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: uiBorder),
          ),
          child: const Text(
            'This data is shown when tapping the app logo on Home.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarsTab() {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: uiBorder),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Avatar Presets',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: primaryBlue,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_avatarUrls.length} avatar${_avatarUrls.length == 1 ? '' : 's'} uploaded',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: softText,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                if (_avatarUrls.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: appBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: uiBorder.withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'No avatars yet. Upload one to get started.',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: softText,
                        ),
                      ),
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 0.85,
                        ),
                    itemCount: _avatarUrls.length,
                    itemBuilder: (ctx, index) {
                      final url = _avatarUrls[index];
                      return GestureDetector(
                        onTap: () => _showAvatarViewer(index),
                        onLongPress: () => _removeAvatar(index),
                        child: Stack(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: appBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: uiBorder.withValues(alpha: 0.6),
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Image.network(
                                      url,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        color: appBg,
                                        child: const Icon(
                                          Icons.broken_image_outlined,
                                          size: 28,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Column(
                                children: [
                                  InkWell(
                                    onTap: index > 0
                                        ? () => _moveAvatarUp(index)
                                        : null,
                                    child: Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: index > 0
                                            ? primaryBlue.withValues(alpha: 0.8)
                                            : Colors.grey.withValues(
                                                alpha: 0.3,
                                              ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Icon(
                                        Icons.keyboard_arrow_up_rounded,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  InkWell(
                                    onTap: index < _avatarUrls.length - 1
                                        ? () => _moveAvatarDown(index)
                                        : null,
                                    child: Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: index < _avatarUrls.length - 1
                                            ? primaryBlue.withValues(alpha: 0.8)
                                            : Colors.grey.withValues(
                                                alpha: 0.3,
                                              ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned(
                              bottom: 4,
                              left: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _uploadingAvatarTotal > 0 ? null : _uploadAvatar,
                    icon: _uploadingAvatarTotal > 0
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(
                      _uploadingAvatarTotal > 0
                          ? 'Uploading $_uploadingAvatarDone/$_uploadingAvatarTotal...'
                          : 'Upload Avatar Images',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryBlue,
                      side: BorderSide(color: uiBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
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
          'App Config',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: primaryBlue,
          unselectedLabelColor: primaryBlue.withValues(alpha: 0.55),
          indicatorColor: actionOrange,
          tabs: const [
            Tab(text: 'Force Update'),
            Tab(text: 'Company Info'),
            Tab(text: 'Avatars'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: loading || saving ? null : _loadAll,
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 6),
        ],
      ),
      bottomNavigationBar: _activeTab == 2
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: saving
                            ? null
                            : (_activeTab == 0 ? _deleteAll : _deleteCompany),
                        icon: const Icon(Icons.delete_forever_rounded),
                        label: Text(
                          _activeTab == 0 ? 'Delete ALL' : 'Delete Company',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: actionOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: saving
                            ? null
                            : (_activeTab == 0 ? _saveAll : _saveCompany),
                        icon: saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.save_rounded),
                        label: Text(
                          saving
                              ? 'Saving…'
                              : (_activeTab == 0 ? 'Save ALL' : 'Save Company'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildForceUpdateTab(),
                _buildCompanyTab(),
                _buildAvatarsTab(),
              ],
            ),
    );
  }
}
