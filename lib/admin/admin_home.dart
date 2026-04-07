import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../shared/human_error.dart';
import 'admin_contract_screen.dart';
import 'admin_wages_screen.dart';
import 'admin_payments.dart';
import 'admin_courses.dart';
import 'admin_learners.dart';
import 'admin_staff.dart';
import 'admin_file_manager.dart';
import 'admin_teacher_reminders_screen.dart';
import 'admin_classes.dart';
import 'admin_public_gallery_screen.dart';
import 'admin_public_preview.dart';
import 'admin_subscriptions.dart';
import 'admin_job_applications_screen.dart';
import 'admin_shared_files_screen.dart';
import '../shared/session_manager.dart';
import 'admin_booking.dart';
import 'admin_attendance_overview_screen.dart';
import 'admin_timetable_screen.dart';
import 'admin_teacher_availability_overview_screen.dart';
import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/admin_tour_guide.dart';
import '../shared/app_tour_guide.dart' show AppTourHighlightShape;
import '../shared/payment_status.dart';
import '../shared/screen_help_guide.dart';
import '../shared/admin_web_layout.dart';
import '../shared/web_page_frame.dart';
import '../services/website_mirror_backfill_service.dart';
import 'admin_certificates.dart';
import 'admin_admin_todos_screen.dart';
import 'admin_course_reviews_screen.dart';
import 'admin_priority_alerts_screen.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  // ===== Brand / UI colors =====
  static const primaryBlue = Color(0xFF0E7C86);
  static const deepBlue = Color(0xFF135C7A);
  static const actionOrange = Color(0xFFBF5D39);
  static const mainText = Color(0xFF213038);
  static const appBg = Color(0xFFF6F2E8);
  static const cardBg = Color(0xFFFFFCF5);
  static const uiBorder = Color(0xFFD8CFC1);
  static const softText = Color(0xFF5E6B70);

  // vivid accents for cards
  static const accentBlue = Color(0xFF3B82F6);
  static const accentTeal = Color(0xFF14B8A6);
  static const accentPurple = Color(0xFF8B5CF6);
  static const accentAmber = Color(0xFFF59E0B);
  static const accentSky = Color(0xFF38BDF8);
  static const accentRose = Color(0xFFEF4444);
  static const accentIndigo = Color(0xFF6366F1);
  static const accentSlate = Color(0xFF64748B);
  static const accentCyan = Color(0xFF06B6D4);
  static const accentGreen = Color(0xFF22C55E);

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  static const _prefsRoleKey = 'admin_home_role_mode_is_admin';
  int _lastBackPressMs = 0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _menuButtonKey = GlobalKey();
  final GlobalKey _cardsGridKey = GlobalKey();
  final GlobalKey _paymentsCardKey = GlobalKey();
  final GlobalKey _learnersCardKey = GlobalKey();
  final GlobalKey _sharedCardKey = GlobalKey();

  bool _isAdminMode = true;
  bool _loadingRole = true;
  bool _showSearch = false;
  String _homeSearch = '';

  @override
  void initState() {
    super.initState();
    _loadSavedRoleMode();
    unawaited(WebsiteMirrorBackfillService.runOnceForAdminLogin());
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
    if (!mounted) return;
    setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _logout(BuildContext context) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    // ✅ stop "single device" listener
    await SessionManager.stopListening();

    // ✅ remove FCM token record
    try {
      if (userId != null && userId.isNotEmpty) {
        await FirebaseDatabase.instance.ref('fcm_tokens/$userId').remove();
      }
    } catch (_) {}

    try {
      await appThemeController.resetToDefault();
    } catch (_) {}

    await FirebaseAuth.instance.signOut();

    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  Color get _screenBg =>
      _isAdminMode ? const Color(0xFFF2F6FF) : const Color(0xFFFFF6EE);

  String get _screenTitle =>
      _isAdminMode ? 'Admin Dashboard' : 'Reception Desk';

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.schedule(
      context,
      screenId: 'admin_home',
      hints: [
        const AdminTourHint(
          title: 'لوحة الإدارة',
          line:
              'تمثل هذه الشاشة مركز التحكم الرئيسي لإدارة الأقسام التشغيلية والأكاديمية في المنصة.',
          highlightShape: AppTourHighlightShape.fullscreen,
        ),
        AdminTourHint(
          title: 'زر القائمة',
          line:
              'استخدم هذا الزر لفتح القائمة الجانبية وتبديل وضع العرض بين الإدارة والاستقبال.',
          targetKey: _menuButtonKey,
          highlightShape: AppTourHighlightShape.circle,
        ),
        AdminTourHint(
          title: 'شبكة أدوات الإدارة',
          line:
              'تضم هذه الشبكة البطاقات الرئيسية للوصول السريع إلى الدورات والصفوف والمدفوعات وبقية الأقسام.',
          targetKey: _cardsGridKey,
        ),
        AdminTourHint(
          title: 'بطاقة المدفوعات',
          line:
              'توفر هذه البطاقة نقطة دخول مباشرة لإدارة السجلات المالية ومتابعة عمليات الدفع.',
          targetKey: _paymentsCardKey,
        ),
        AdminTourHint(
          title: 'بطاقة المتعلمين',
          line:
              'تتيح هذه البطاقة متابعة بيانات المتعلمين وحالة الالتزام المالي ومستوى التتبع الدراسي.',
          targetKey: _learnersCardKey,
        ),
        AdminTourHint(
          title: 'بطاقة الملفات المشتركة',
          line:
              'من هذه البطاقة يمكنك مراجعة الملفات المشتركة بين المعلمين وإدارتها على مستوى النظام.',
          targetKey: _sharedCardKey,
        ),
      ],
    );

    final user = FirebaseAuth.instance.currentUser;

    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width >= 1440
        ? 5
        : (width >= 1160 ? 4 : (width >= 760 ? 3 : 2));
    final double cardRatio;
    if (crossAxisCount >= 5) {
      cardRatio = _isAdminMode ? 1.24 : 1.30;
    } else if (crossAxisCount >= 4) {
      cardRatio = _isAdminMode ? 1.18 : 1.22;
    } else if (crossAxisCount == 3) {
      cardRatio = _isAdminMode ? 1.02 : 1.06;
    } else {
      cardRatio = width >= 420 ? 0.96 : 0.88;
    }
    final gridGap = width >= 1200 ? 14.0 : (width >= 900 ? 12.0 : 10.0);

    _HomeCardItem card(String title, String subtitle, Widget child) {
      return _HomeCardItem(title: title, subtitle: subtitle, child: child);
    }

    final allCards = <_HomeCardItem>[
      card(
        'Learners',
        'Students list',
        KeyedSubtree(
          key: _learnersCardKey,
          child: _LearnersDashCard(
            isReceptionistStyle: !_isAdminMode,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
            ),
          ),
        ),
      ),
      card(
        'Classes',
        'Manage classes',
        _ClassesDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminClassesScreen())),
        ),
      ),
      card(
        'Payments',
        'Financial records',
        KeyedSubtree(
          key: _paymentsCardKey,
          child: _PaymentsAttentionDashCard(
            isReceptionistStyle: !_isAdminMode,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
            ),
          ),
        ),
      ),
      card(
        'Schedule',
        'Weekly timetable',
        _DashCard(
          title: 'Schedule',
          subtitle: 'Weekly timetable',
          icon: Icons.calendar_view_week_rounded,
          color: AdminHome.accentTeal,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminTimetableScreen()),
          ),
        ),
      ),
      card(
        'Attendance',
        'Daily / Weekly stats',
        _DashCard(
          title: 'Attendance',
          subtitle: 'Daily / Weekly stats',
          icon: Icons.fact_check_rounded,
          color: AdminHome.accentIndigo,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminAttendanceOverviewScreen(),
            ),
          ),
        ),
      ),
      card(
        'Courses',
        'Manage courses',
        _DashCard(
          title: 'Courses',
          subtitle: 'Manage courses',
          icon: Icons.menu_book_rounded,
          color: AdminHome.primaryBlue,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminCoursesScreen())),
        ),
      ),
      card(
        'Course Reviews',
        'Moderate learner reviews',
        _CourseFeedbackDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminCourseReviewsScreen()),
          ),
        ),
      ),
      card(
        'Online Booking',
        'Online Booking management',
        _AdminOnlineBookingDashCard(isReceptionistStyle: !_isAdminMode),
      ),
      card(
        'Reminders',
        'Send & manage reminders',
        _RemindersDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminTeacherRemindersScreen(),
            ),
          ),
        ),
      ),
      card(
        'Priority Alerts',
        'Send one-time popup alerts',
        _DashCard(
          title: 'Priority Alerts',
          subtitle: 'Send one-time popup alerts',
          icon: Icons.campaign_rounded,
          color: AdminHome.actionOrange,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminPriorityAlertsScreen(),
            ),
          ),
        ),
      ),
      card(
        'Staff',
        'Teachers & staff',
        _StaffMailDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminStaffScreen())),
        ),
      ),
      card(
        'Wages',
        'Teacher payments',
        _DashCard(
          title: 'Wages',
          subtitle: 'Teacher payments',
          icon: Icons.wallet_rounded,
          color: AdminHome.accentRose,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminWagesScreen())),
        ),
      ),
      card(
        'Teacher Availability',
        'Coverage & staffing overview',
        _DashCard(
          title: 'Teacher Availability',
          subtitle: 'Coverage & staffing overview',
          icon: Icons.manage_accounts_rounded,
          color: AdminHome.accentCyan,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AdminTeacherAvailabilityOverviewScreen(),
            ),
          ),
        ),
      ),
      card(
        'Subscriptions',
        'Registration requests',
        _SubscriptionsDashCard(isReceptionistStyle: !_isAdminMode),
      ),
      card(
        'Certificates',
        'Issued certificates',
        _CertificatesDashCard(isReceptionistStyle: !_isAdminMode),
      ),
      card(
        'File Manager',
        'Courses & Games files',
        _DashCard(
          title: 'File Manager',
          subtitle: 'Courses & Games files',
          icon: Icons.folder_open,
          color: AdminHome.accentGreen,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminFileManager())),
        ),
      ),
      card(
        'Shared Files',
        'Teacher shared files',
        KeyedSubtree(
          key: _sharedCardKey,
          child: _AdminSharedFilesDashCard(isReceptionistStyle: !_isAdminMode),
        ),
      ),
      card(
        'Public Gallery',
        'Teaser media',
        _DashCard(
          title: 'Public Gallery',
          subtitle: 'Teaser media',
          icon: Icons.photo_library_rounded,
          color: AdminHome.accentSky,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminPublicGalleryScreen()),
          ),
        ),
      ),
      card(
        'Contract',
        'Contracts & documents',
        _DashCard(
          title: 'Contract',
          subtitle: 'Contracts & documents',
          icon: Icons.description_rounded,
          color: AdminHome.accentCyan,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminContractScreen()),
          ),
        ),
      ),
      card(
        'Settings',
        'Force update config',
        _DashCard(
          title: 'Settings',
          subtitle: 'Force update config',
          icon: Icons.settings_rounded,
          color: AdminHome.accentIndigo,
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminForceUpdateAllScreen(),
            ),
          ),
        ),
      ),
      card(
        'Job Applications',
        'Hiring pipeline',
        _JobApplicationsDashCard(isReceptionistStyle: !_isAdminMode),
      ),
    ];

    final receptionistCards = <_HomeCardItem>[
      card(
        'Learners',
        'Students overview',
        KeyedSubtree(
          key: _learnersCardKey,
          child: _LearnersDashCard(
            isReceptionistStyle: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
            ),
          ),
        ),
      ),
      card(
        'Classes',
        'Manage classes',
        _ClassesDashCard(
          isReceptionistStyle: true,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminClassesScreen())),
        ),
      ),
      card(
        'Payments',
        'Financial records',
        KeyedSubtree(
          key: _paymentsCardKey,
          child: _PaymentsAttentionDashCard(
            isReceptionistStyle: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
            ),
          ),
        ),
      ),
      card(
        'Schedule',
        'Weekly timetable',
        _DashCard(
          title: 'Schedule',
          subtitle: 'Weekly timetable',
          icon: Icons.calendar_view_week_rounded,
          color: AdminHome.accentTeal,
          isReceptionistStyle: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminTimetableScreen()),
          ),
        ),
      ),
      card(
        'Reminders',
        'Send reminders',
        _RemindersDashCard(
          isReceptionistStyle: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminTeacherRemindersScreen(),
            ),
          ),
        ),
      ),
      card(
        'Priority Alerts',
        'Popup messages',
        _DashCard(
          title: 'Priority Alerts',
          subtitle: 'Popup messages',
          icon: Icons.campaign_rounded,
          color: AdminHome.actionOrange,
          isReceptionistStyle: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AdminPriorityAlertsScreen(),
            ),
          ),
        ),
      ),
      card(
        'Staff',
        'Teachers & staff',
        _StaffMailDashCard(
          isReceptionistStyle: true,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminStaffScreen())),
        ),
      ),
      card(
        'Public Gallery',
        'Teaser media',
        _DashCard(
          title: 'Public Gallery',
          subtitle: 'Teaser media',
          icon: Icons.photo_library_rounded,
          color: AdminHome.accentSky,
          isReceptionistStyle: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminPublicGalleryScreen()),
          ),
        ),
      ),
    ];

    final q = _homeSearch.trim().toLowerCase();
    final selectedCards = _isAdminMode ? allCards : receptionistCards;
    final visibleCards = selectedCards
        .where(
          (c) =>
              q.isEmpty ||
              c.title.toLowerCase().contains(q) ||
              c.subtitle.toLowerCase().contains(q),
        )
        .map((c) => c.child)
        .toList();

    final dashboardPanel = webPageFrame(
      maxWidth: 1500,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: _showSearch ? 56 : 0,
              curve: Curves.easeOutCubic,
              child: _showSearch
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        onChanged: (v) => setState(() => _homeSearch = v),
                        decoration: InputDecoration(
                          hintText: 'Search dashboard tools...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 0,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            _AdminTodoHomeCard(
              isReceptionistStyle: !_isAdminMode,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AdminAdminTodosScreen(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: KeyedSubtree(
                key: _cardsGridKey,
                child: visibleCards.isEmpty
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
                        child: GridView.count(
                          physics: const AlwaysScrollableScrollPhysics(),
                          crossAxisCount: crossAxisCount,
                          mainAxisSpacing: gridGap,
                          crossAxisSpacing: gridGap,
                          childAspectRatio: cardRatio,
                          children: visibleCards,
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
          _DrawerTile(
            icon: Icons.school_rounded,
            title: 'Learners',
            subtitle: 'Open learner management',
            color: AdminHome.primaryBlue,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
            ),
          ),
          _DrawerTile(
            icon: Icons.payments_rounded,
            title: 'Payments',
            subtitle: 'Financial records',
            color: AdminHome.actionOrange,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
            ),
          ),
          _DrawerTile(
            icon: Icons.class_rounded,
            title: 'Classes',
            subtitle: 'Classes and attendance',
            color: AdminHome.accentIndigo,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminClassesScreen()),
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
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminPublicPreview()),
            );
          },
          onSelectAdmin: () async {
            Navigator.of(context).pop();
            await _setRoleMode(true);
          },
          onSelectReceptionist: () async {
            Navigator.of(context).pop();
            await _setRoleMode(false);
          },
          onLogout: () async {
            Navigator.of(context).pop();
            await _logout(context);
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
            IconButton(
              tooltip: _showSearch ? 'Close search' : 'Search tools',
              icon: Icon(
                _showSearch ? Icons.close_rounded : Icons.search_rounded,
              ),
              onPressed: () {
                setState(() {
                  if (_showSearch) {
                    _homeSearch = '';
                  }
                  _showSearch = !_showSearch;
                });
              },
            ),
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
                        ? const [Color(0xFFE7F0FF), Color(0xFFF2F6FF)]
                        : const [Color(0xFFFFE8D7), Color(0xFFFFF6EE)],
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
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;
}

class _AdminTodoHomeCard extends StatelessWidget {
  const _AdminTodoHomeCard({
    required this.onTap,
    required this.isReceptionistStyle,
  });

  final VoidCallback onTap;
  final bool isReceptionistStyle;

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
                final status = (m['status'] ?? 'new')
                    .toString()
                    .trim()
                    .toLowerCase();
                final dueAt = _toInt(m['dueAt']);
                final isOverdue = status != 'done' && dueAt > 0 && dueAt < now;

                if (status == 'done') {
                  doneCount++;
                } else if (status == 'seen' || status == 'read') {
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
                    Icons.task_alt_rounded,
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

  const _AdminHomeDrawer({
    required this.userEmail,
    required this.isAdminMode,
    required this.loadingRole,
    required this.onOpenMain,
    required this.onSelectAdmin,
    required this.onSelectReceptionist,
    required this.onLogout,
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

    bool countedSlot = false;

    void markSlot(DateTime dt) {
      if (countedSlot) return;
      countedSlot = true;
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

          countedSlot = false;

          final slotMap = Map<dynamic, dynamic>.from(slotNode);

          // Flat shape: /{day}/{time} => {learners:{...}, ...}
          final learnersRaw = slotMap['learners'];
          if (learnersRaw is Map && learnersRaw.isNotEmpty) {
            markSlot(dt);
            continue;
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

        final subtitle = stats.upcoming == 0
            ? 'Online Booking management'
            : 'Today ${stats.today} • Week ${stats.week} • Upcoming ${stats.upcoming}';

        return _DashCard(
          title: 'Online Booking',
          subtitle: subtitle,
          icon: Icons.event_available_rounded,
          color: AdminHome.accentGreen,
          badgeCount: 0,
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

        final subtitle = count == 0
            ? 'No new registrations'
            : '$count new application${count == 1 ? '' : 's'}';

        return _DashCard(
          title: 'Subscriptions',
          subtitle: subtitle,
          icon: Icons.how_to_reg_rounded,
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

        final subtitle = total == 0
            ? 'No applications yet'
            : 'Uncalled $uncalledCount • Follow-up $followUp • Total $total';

        return _DashCard(
          title: 'Job Applications',
          subtitle: subtitle,
          icon: Icons.work_history_rounded,
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
        int total = 0;
        int open = 0;
        int closed = 0;
        final learnerUids = <String>{};

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          total = v.length;
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

        final subtitle = total == 0
            ? 'Manage classes'
            : 'Open $open • Closed $closed • Learners ${learnerUids.length}';

        return _DashCard(
          title: 'Classes',
          subtitle: subtitle,
          icon: Icons.class_rounded,
          color: AdminHome.actionOrange,
          badgeCount: 0,
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

        final subtitle = count == 0
            ? 'No shared files'
            : '$count shared file${count == 1 ? '' : 's'}';

        return _DashCard(
          title: 'Shared Files',
          subtitle: subtitle,
          icon: Icons.folder_shared_rounded,
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

class _CertificatesDashCard extends StatelessWidget {
  final bool isReceptionistStyle;

  const _CertificatesDashCard({this.isReceptionistStyle = false});

  int _countRecordedAchievements(dynamic usersValue) {
    if (usersValue is! Map) return 0;
    int count = 0;
    usersValue.forEach((_, userRaw) {
      if (userRaw is! Map) return;
      final user = Map<dynamic, dynamic>.from(userRaw);
      final recorded = user['recorded_certificates'];
      if (recorded is Map) {
        count += recorded.length;
      }
    });
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final manualRef = FirebaseDatabase.instance.ref('certificates');
    final usersRef = FirebaseDatabase.instance.ref('users');

    return StreamBuilder<DatabaseEvent>(
      stream: manualRef.onValue,
      builder: (context, manualSnap) {
        final manualVal = manualSnap.data?.snapshot.value;
        final manualCount = manualVal is Map ? manualVal.length : 0;

        return StreamBuilder<DatabaseEvent>(
          stream: usersRef.onValue,
          builder: (context, usersSnap) {
            final recordedCount = _countRecordedAchievements(
              usersSnap.data?.snapshot.value,
            );
            final totalCount = manualCount + recordedCount;

            final subtitle = totalCount == 0
                ? 'No certificates yet'
                : '$totalCount total • $recordedCount recorded achievement${recordedCount == 1 ? '' : 's'}';

            return _DashCard(
              title: 'Certificates',
              subtitle: subtitle,
              icon: Icons.workspace_premium_rounded,
              color: AdminHome.accentIndigo,
              badgeCount: totalCount,
              isReceptionistStyle: isReceptionistStyle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AdminCertificatesScreen(),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ===================== PAY FLAG =====================

enum _PayFlag { ok, yellow, red, black, noCourse }

class _PayLegend {
  static const String noCourseLabel = 'No course';
  static const String blackLabel = 'Overdue';
  static const String redLabel = 'Due now';
  static const String yellowLabel = 'Warning';
  static const String okLabel = 'OK';

  static const Color noCourseColor = Colors.blue;
  static const Color blackColor = Colors.black;
  static const Color redColor = Colors.red;
  static const Color yellowColor = AdminHome.actionOrange;
  static const Color okColor = AdminHome.primaryBlue;
}

class _PaymentAttentionSummary {
  const _PaymentAttentionSummary({
    required this.totalLearners,
    required this.noCourse,
    required this.black,
    required this.red,
    required this.yellow,
    required this.ok,
  });

  final int totalLearners;
  final int noCourse;
  final int black;
  final int red;
  final int yellow;
  final int ok;

  int get attention => black + red;
  int get tracked => black + red + yellow + ok;

  static _PaymentAttentionSummary fromUsers(dynamic usersVal) {
    int totalLearners = 0;
    int noCourse = 0;
    int black = 0;
    int red = 0;
    int yellow = 0;
    int ok = 0;

    if (usersVal is Map) {
      usersVal.forEach((uid, userVal) {
        if (uid == null || userVal == null || userVal is! Map) return;
        final userMap = userVal.map((k, vv) => MapEntry(k.toString(), vv));

        final role = (userMap['role'] ?? '').toString().trim().toLowerCase();
        if (role != 'learner' && role != 'learners' && role != 'learner(s)') {
          return;
        }

        totalLearners++;

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
  });

  final _PaymentAttentionSummary summary;
  final List<String> noCourseLearners;
  final List<String> overdueLearners;
  final List<String> dueNowLearners;
  final List<String> warningLearners;
  final List<String> okLearners;

  static _PaymentAttentionDetails fromUsers(dynamic usersVal) {
    final noCourse = <String>[];
    final overdue = <String>[];
    final dueNow = <String>[];
    final warning = <String>[];
    final ok = <String>[];

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

    return _PaymentAttentionDetails(
      summary: _PaymentAttentionSummary.fromUsers(usersVal),
      noCourseLearners: noCourse,
      overdueLearners: overdue,
      dueNowLearners: dueNow,
      warningLearners: warning,
      okLearners: ok,
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
      case _PayFlag.ok:
        return 1;
      case _PayFlag.noCourse:
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
    final variantKey = normalizeVariantKey(
      (courseMap['variantKey'] ?? courseMap['variant'] ?? 'inclass').toString(),
    );

    final paymentSummary = courseMap['payment_summary'];
    final summaryMap = paymentSummary is Map
        ? paymentSummary.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final attendance = courseMap['attendance'];
    final sessionsDone = switch (variantKey) {
      'inclass' => countHeldUniqueAttendanceDates(attendance),
      'private' => countPresentUniqueAttendanceDates(attendance),
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
      final expiresAt = asInt(accessMap['expiresAt']);
      if (expiresAt <= 0) return _PayFlag.black;
      if (isExpiredMs(expiresAt)) return _PayFlag.red;
      if (isNearExpiryMs(expiresAt)) return _PayFlag.yellow;
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
                Text(
                  title,
                  style: const TextStyle(
                    color: AdminHome.primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
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
                        leading: const Icon(
                          Icons.person_rounded,
                          color: AdminHome.primaryBlue,
                        ),
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

  Widget _buildCardUi(
    BuildContext context, {
    required _PaymentAttentionDetails details,
    required bool loading,
  }) {
    final summary = details.summary;
    final borderColor = isReceptionistStyle
        ? const Color(0xFFFFEAD8)
        : AdminHome.uiBorder;

    final boxShadowOpacity = isReceptionistStyle ? 0.025 : 0.04;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AdminHome.cardBg,
          borderRadius: BorderRadius.circular(20),
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isReceptionistStyle
                      ? const Color(0xFFFFF2E8)
                      : const Color(0xFFEAF2FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.payments_rounded,
                        color: isReceptionistStyle
                            ? AdminHome.actionOrange
                            : AdminHome.accentBlue,
                        size: 20,
                      ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Payments',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  color: AdminHome.primaryBlue,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Payment attention overview',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: AdminHome.softText,
                ),
              ),
              const SizedBox(height: 7),
              Flexible(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _MiniStatChip(
                        label: 'Learners ${summary.totalLearners}',
                        color: Colors.blueGrey,
                        background: const Color(0xFFF2F5F8),
                      ),
                      _MiniStatChip(
                        label: '${_PayLegend.blackLabel} ${summary.black}',
                        color: _PayLegend.blackColor,
                        background: const Color(0xFFF1F3F5),
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.blackLabel,
                          names: details.overdueLearners,
                        ),
                      ),
                      _MiniStatChip(
                        label: '${_PayLegend.redLabel} ${summary.red}',
                        color: _PayLegend.redColor,
                        background: const Color(0xFFFFEEEE),
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.redLabel,
                          names: details.dueNowLearners,
                        ),
                      ),
                      _MiniStatChip(
                        label: '${_PayLegend.yellowLabel} ${summary.yellow}',
                        color: _PayLegend.yellowColor,
                        background: const Color(0xFFFFF4E4),
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.yellowLabel,
                          names: details.warningLearners,
                        ),
                      ),
                      _MiniStatChip(
                        label:
                            '${_PayLegend.noCourseLabel} ${summary.noCourse}',
                        color: _PayLegend.noCourseColor,
                        background: const Color(0xFFEFF5FF),
                        onTap: () => _showLearnersSheet(
                          context,
                          title: _PayLegend.noCourseLabel,
                          names: details.noCourseLearners,
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
}

// ===================== LEARNERS CARD =====================

class _LearnersDashCard extends StatelessWidget {
  final VoidCallback onTap;
  final bool isReceptionistStyle;

  const _LearnersDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  void _showLearnersSheet(
    BuildContext context, {
    required String title,
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
                Text(
                  title,
                  style: const TextStyle(
                    color: AdminHome.primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
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
                        leading: const Icon(
                          Icons.person_rounded,
                          color: AdminHome.primaryBlue,
                        ),
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
        final details = _PaymentAttentionDetails.fromUsers(
          snap.data?.snapshot.value,
        );
        final summary = details.summary;

        if (!snap.hasData) {
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: _learnersCardUi(
              context: context,
              total: 0,
              black: 0,
              red: 0,
              yellow: 0,
              ok: 0,
              blue: 0,
              noCourseNames: const <String>[],
              blackNames: const <String>[],
              redNames: const <String>[],
              yellowNames: const <String>[],
              okNames: const <String>[],
              loading: true,
              isReceptionistStyle: isReceptionistStyle,
            ),
          );
        }

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: _learnersCardUi(
            context: context,
            total: summary.totalLearners,
            black: summary.black,
            red: summary.red,
            yellow: summary.yellow,
            ok: summary.ok,
            blue: summary.noCourse,
            noCourseNames: details.noCourseLearners,
            blackNames: details.overdueLearners,
            redNames: details.dueNowLearners,
            yellowNames: details.warningLearners,
            okNames: details.okLearners,
            loading: false,
            isReceptionistStyle: isReceptionistStyle,
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
    required List<String> noCourseNames,
    required List<String> blackNames,
    required List<String> redNames,
    required List<String> yellowNames,
    required List<String> okNames,
    required bool loading,
    required bool isReceptionistStyle,
  }) {
    final borderColor = isReceptionistStyle
        ? const Color(0xFFFFEAD8)
        : AdminHome.uiBorder;

    final boxShadowOpacity = isReceptionistStyle ? 0.025 : 0.04;

    return Container(
      decoration: BoxDecoration(
        color: AdminHome.cardBg,
        borderRadius: BorderRadius.circular(20),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isReceptionistStyle
                    ? const Color(0xFFFFF2E8)
                    : const Color(0xFFF1EAFE),
                borderRadius: BorderRadius.circular(14),
              ),
              child: loading
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.people_alt_rounded,
                      color: isReceptionistStyle
                          ? AdminHome.actionOrange
                          : AdminHome.accentPurple,
                      size: 20,
                    ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Learners',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 14,
                color: AdminHome.primaryBlue,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              isReceptionistStyle ? 'Students overview' : 'Students list',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: AdminHome.softText,
              ),
            ),
            const SizedBox(height: 7),
            Flexible(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _MiniStatChip(
                      label: 'Learners $total',
                      color: Colors.blueGrey,
                      background: const Color(0xFFF2F5F8),
                    ),
                    _MiniStatChip(
                      label: '${_PayLegend.noCourseLabel} $blue',
                      color: _PayLegend.noCourseColor,
                      background: const Color(0xFFEFF5FF),
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.noCourseLabel,
                        names: noCourseNames,
                      ),
                    ),
                    _MiniStatChip(
                      label: '${_PayLegend.blackLabel} $black',
                      color: _PayLegend.blackColor,
                      background: const Color(0xFFF1F3F5),
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.blackLabel,
                        names: blackNames,
                      ),
                    ),
                    _MiniStatChip(
                      label: '${_PayLegend.redLabel} $red',
                      color: _PayLegend.redColor,
                      background: const Color(0xFFFFEEEE),
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.redLabel,
                        names: redNames,
                      ),
                    ),
                    _MiniStatChip(
                      label: '${_PayLegend.yellowLabel} $yellow',
                      color: _PayLegend.yellowColor,
                      background: const Color(0xFFFFF4E4),
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.yellowLabel,
                        names: yellowNames,
                      ),
                    ),
                    _MiniStatChip(
                      label: '${_PayLegend.okLabel} $ok',
                      color: _PayLegend.okColor,
                      background: const Color(0xFFEAF2FF),
                      onTap: () => _showLearnersSheet(
                        context,
                        title: _PayLegend.okLabel,
                        names: okNames,
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

class _MiniStatChip extends StatelessWidget {
  const _MiniStatChip({
    required this.label,
    required this.color,
    required this.background,
    this.onTap,
  });

  final String label;
  final Color color;
  final Color background;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 10,
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
              final status = (m['status'] ?? 'new')
                  .toString()
                  .trim()
                  .toLowerCase();
              if (status == 'done') {
                done += 1;
              } else if (status == 'read' || status == 'seen') {
                seen += 1;
              } else {
                undone += 1;
              }
            });
          });
        }

        final total = done + seen + undone;
        final subtitle = total == 0
            ? 'Send & manage reminders'
            : 'Done $done • Seen $seen • Undone $undone';

        return _DashCard(
          title: 'Reminders',
          subtitle: subtitle,
          icon: Icons.notifications_active_rounded,
          color: AdminHome.accentPurple,
          badgeCount: 0,
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

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final meUid = FirebaseAuth.instance.currentUser?.uid?.trim() ?? '';
    if (meUid.isEmpty) {
      return _DashCard(
        title: 'Staff',
        subtitle: 'Teachers & staff',
        icon: Icons.badge_rounded,
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
          root.forEach((_, threadVal) {
            if (threadVal is! Map) return;
            final m = threadVal.map((k, v) => MapEntry(k.toString(), v));
            unread += _toInt(m['unreadCount']);
          });
        }

        final subtitle = threads == 0
            ? 'Teachers & staff'
            : 'Unread $unread • Threads $threads';

        return _DashCard(
          title: 'Staff',
          subtitle: subtitle,
          icon: Icons.badge_rounded,
          color: AdminHome.accentAmber,
          badgeCount: unread,
          isReceptionistStyle: isReceptionistStyle,
          onTap: onTap,
        );
      },
    );
  }
}

// ===================== GENERIC DASH CARD =====================

class _DashCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final int badgeCount;
  final bool isReceptionistStyle;

  const _DashCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.badgeCount = 0,
    this.isReceptionistStyle = false,
  });

  Color _softBg(Color color) {
    if (color == AdminHome.actionOrange) return const Color(0xFFFFF1E5);
    if (color == AdminHome.accentBlue) return const Color(0xFFEAF2FF);
    if (color == AdminHome.accentTeal) return const Color(0xFFE8FBF7);
    if (color == AdminHome.accentPurple) return const Color(0xFFF1EAFE);
    if (color == AdminHome.accentAmber) return const Color(0xFFFFF6DB);
    if (color == AdminHome.accentSky) return const Color(0xFFEAF8FF);
    if (color == AdminHome.accentRose) return const Color(0xFFFFECEB);
    if (color == AdminHome.accentIndigo) return const Color(0xFFEEF0FF);
    if (color == AdminHome.accentSlate) return const Color(0xFFF1F5F9);
    if (color == AdminHome.accentCyan) return const Color(0xFFE9FBFE);
    if (color == AdminHome.accentGreen) return const Color(0xFFEAFBF1);
    return const Color(0xFFEAF2FF);
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = isReceptionistStyle
        ? const Color(0xFFFFEAD8)
        : AdminHome.uiBorder;

    final shadowOpacity = isReceptionistStyle ? 0.025 : 0.04;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _softBg(
                color,
              ).withValues(alpha: isReceptionistStyle ? 0.22 : 0.26),
              AdminHome.cardBg,
              AdminHome.cardBg,
            ],
            stops: const [0.0, 0.22, 1.0],
          ),
          borderRadius: BorderRadius.circular(20),
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: isReceptionistStyle
                          ? _softBg(color).withValues(alpha: 0.82)
                          : _softBg(color),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: color, size: 21),
                  ),
                  const Spacer(),
                  if (badgeCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
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
                          fontSize: 10,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  color: AdminHome.primaryBlue,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: AdminHome.softText,
                  height: 1.2,
                ),
              ),
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
          subtitle: reported > 0
              ? '$reported reported feedback items'
              : 'Moderate learner reviews',
          icon: Icons.reviews_rounded,
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

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 2, vsync: this)
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
    minVersionC.text = (m['minVersion'] ?? '').toString();
    minBuildC.text = (m['minBuild'] ?? '').toString();
    messageC.text = (m['message'] ?? '').toString();
    storeUrlC.text = (m['storeUrl'] ?? '').toString();
    storeWebUrlC.text = (m['storeWebUrl'] ?? '').toString();
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
  }

  Map<String, dynamic> _companyControllersToMap() {
    return {
      'companyFullName': cFullNameC.text.trim(),
      'companyPhone': cPhoneC.text.trim(),
      'companyEmail': cEmailC.text.trim(),
      'companyAccreditationNumber': cAccreditationC.text.trim(),
      'companyAddress': cAddressC.text.trim(),
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
      if (!mounted) return;
      setState(() => loading = false);
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
      if (!mounted) return;
      setState(() => saving = false);
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
      if (!mounted) return;
      setState(() => saving = false);
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

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_force_update_all',
      title: 'اعدادات التطبيق',
      line: 'هنا تضبط رقم النسخة الاجبارية ورسائل التحديث للتطبيق.',
    );

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
      bottomNavigationBar: SafeArea(
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
              children: [_buildForceUpdateTab(), _buildCompanyTab()],
            ),
    );
  }
}
