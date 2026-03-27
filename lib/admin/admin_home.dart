import 'dart:async';

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
import '../shared/admin_tour_guide.dart';
import '../shared/app_tour_guide.dart' show AppTourHighlightShape;
import '../services/website_mirror_backfill_service.dart';
import 'admin_certificates.dart';

class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  // ===== Brand / UI colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const deepBlue = Color(0xFF223554);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF243042);
  static const appBg = Color(0xFFF6F8FC);
  static const cardBg = Colors.white;
  static const uiBorder = Color(0xFFE3EAF2);
  static const softText = Color(0xFF6E7B8C);

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

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _menuButtonKey = GlobalKey();
  final GlobalKey _cardsGridKey = GlobalKey();
  final GlobalKey _paymentsCardKey = GlobalKey();
  final GlobalKey _learnersCardKey = GlobalKey();
  final GlobalKey _sharedCardKey = GlobalKey();

  bool _isAdminMode = true;
  bool _loadingRole = true;

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
    final crossAxisCount = width >= 1100 ? 4 : (width >= 700 ? 3 : 2);
    final double cardRatio;
    if (crossAxisCount >= 4) {
      cardRatio = _isAdminMode ? 1.18 : 1.22;
    } else if (crossAxisCount == 3) {
      cardRatio = _isAdminMode ? 1.02 : 1.06;
    } else {
      cardRatio = width >= 420 ? 0.96 : 0.88;
    }
    final gridGap = width >= 900 ? 12.0 : 10.0;

    final allCards = <Widget>[
      KeyedSubtree(
        key: _learnersCardKey,
        child: _LearnersDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
          ),
        ),
      ),
      _DashCard(
        title: 'Classes',
        subtitle: 'Manage classes',
        icon: Icons.class_rounded,
        color: AdminHome.actionOrange,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AdminClassesScreen())),
      ),
      KeyedSubtree(
        key: _paymentsCardKey,
        child: _PaymentsAttentionDashCard(
          isReceptionistStyle: !_isAdminMode,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
          ),
        ),
      ),
      _DashCard(
        title: 'Schedule',
        subtitle: 'Weekly timetable',
        icon: Icons.calendar_view_week_rounded,
        color: AdminHome.accentTeal,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AdminTimetableScreen())),
      ),
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
      _AdminOnlineBookingDashCard(isReceptionistStyle: !_isAdminMode),
      _DashCard(
        title: 'Reminders',
        subtitle: 'Send & manage reminders',
        icon: Icons.notifications_active_rounded,
        color: AdminHome.accentPurple,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AdminTeacherRemindersScreen(),
          ),
        ),
      ),
      _DashCard(
        title: 'Staff',
        subtitle: 'Teachers & staff',
        icon: Icons.badge_rounded,
        color: AdminHome.accentAmber,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AdminStaffScreen())),
      ),
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
      _SubscriptionsDashCard(isReceptionistStyle: !_isAdminMode),
      _CertificatesDashCard(isReceptionistStyle: !_isAdminMode),
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
      KeyedSubtree(
        key: _sharedCardKey,
        child: _AdminSharedFilesDashCard(isReceptionistStyle: !_isAdminMode),
      ),
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
      _DashCard(
        title: 'Contract',
        subtitle: 'Contracts & documents',
        icon: Icons.description_rounded,
        color: AdminHome.accentCyan,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AdminContractScreen())),
      ),
      _DashCard(
        title: 'Settings',
        subtitle: 'Force update config',
        icon: Icons.settings_rounded,
        color: AdminHome.accentIndigo,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminForceUpdateAllScreen()),
        ),
      ),
      _JobApplicationsDashCard(isReceptionistStyle: !_isAdminMode),
    ];

    final receptionistCards = <Widget>[
      KeyedSubtree(
        key: _learnersCardKey,
        child: _LearnersDashCard(
          isReceptionistStyle: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
          ),
        ),
      ),
      _DashCard(
        title: 'Classes',
        subtitle: 'Manage classes',
        icon: Icons.class_rounded,
        color: AdminHome.actionOrange,
        isReceptionistStyle: true,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AdminClassesScreen())),
      ),
      KeyedSubtree(
        key: _paymentsCardKey,
        child: _PaymentsAttentionDashCard(
          isReceptionistStyle: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
          ),
        ),
      ),
      _DashCard(
        title: 'Schedule',
        subtitle: 'Weekly timetable',
        icon: Icons.calendar_view_week_rounded,
        color: AdminHome.accentTeal,
        isReceptionistStyle: true,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AdminTimetableScreen())),
      ),
      _DashCard(
        title: 'Reminders',
        subtitle: 'Send reminders',
        icon: Icons.notifications_active_rounded,
        color: AdminHome.accentPurple,
        isReceptionistStyle: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AdminTeacherRemindersScreen(),
          ),
        ),
      ),
      _DashCard(
        title: 'Staff',
        subtitle: 'Teachers & staff',
        icon: Icons.badge_rounded,
        color: AdminHome.accentAmber,
        isReceptionistStyle: true,
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AdminStaffScreen())),
      ),
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
    ];

    final visibleCards = _isAdminMode ? allCards : receptionistCards;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _screenBg,
      drawer: _AdminHomeDrawer(
        userEmail: user?.email ?? 'Admin',
        isAdminMode: _isAdminMode,
        loadingRole: _loadingRole,
        onOpenMain: () {
          Navigator.of(context).pop();
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminPublicPreview()));
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Grid
                  Expanded(
                    child: KeyedSubtree(
                      key: _cardsGridKey,
                      child: GridView.count(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: gridGap,
                        crossAxisSpacing: gridGap,
                        childAspectRatio: cardRatio,
                        children: visibleCards,
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
          ),
        ],
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

  int _countUpcomingBookings(dynamic rootValue) {
    if (rootValue is! Map) return 0;

    final now = DateTime.now();
    int count = 0;

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

          if (dt.isAfter(now)) {
            count += 1;
          }
        }
      }
    }

    return count;
  }

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('booking_reservations');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        final count = _countUpcomingBookings(snap.data?.snapshot.value);

        final subtitle = count == 0
            ? 'Online Booking management'
            : '$count upcoming booking${count == 1 ? '' : 's'}';

        return _DashCard(
          title: 'Online Booking',
          subtitle: subtitle,
          icon: Icons.event_available_rounded,
          color: AdminHome.accentGreen,
          badgeCount: count,
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
        int newCount = 0;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          total = v.length;
          v.forEach((_, raw) {
            if (raw is! Map) return;
            final m = raw.map((k, val) => MapEntry(k.toString(), val));
            final status = (m['status'] ?? '').toString().trim().toLowerCase();
            if (status.isEmpty || status == 'new') {
              newCount += 1;
            }
          });
        }

        final subtitle = total == 0
            ? 'No applications yet'
            : '$newCount new • $total total';

        return _DashCard(
          title: 'Job Applications',
          subtitle: subtitle,
          icon: Icons.work_history_rounded,
          color: AdminHome.accentSlate,
          badgeCount: newCount,
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

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('certificates');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int count = 0;
        final v = snap.data?.snapshot.value;
        if (v is Map) count = v.length;

        final subtitle = count == 0
            ? 'No certificates yet'
            : '$count certificate${count == 1 ? '' : 's'}';

        return _DashCard(
          title: 'Certificates',
          subtitle: subtitle,
          icon: Icons.workspace_premium_rounded,
          color: AdminHome.accentIndigo,
          badgeCount: count,
          isReceptionistStyle: isReceptionistStyle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminCertificatesScreen()),
          ),
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
  static int asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static int countUniqueAttendanceDates(dynamic attendance) {
    if (attendance is! Map) return 0;
    final dates = <String>{};
    attendance.forEach((_, v) {
      if (v is! Map) return;
      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final d = (m['date'] ?? '').toString().trim();
      if (d.isNotEmpty) dates.add(d);
    });
    return dates.length;
  }

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

    final rb = remindBeforeSession > 0 ? remindBeforeSession : 1;
    final currentSession = sessionsDone + 1;

    if (currentSession > sessionsPaidTotal) return _PayFlag.black;

    var dueAt = sessionsPaidTotal - rb;
    if (dueAt < 1) dueAt = 1;

    final warnAt = dueAt - 1;
    if (currentSession >= dueAt) return _PayFlag.red;
    if (warnAt >= 1 && currentSession == warnAt) return _PayFlag.yellow;
    return _PayFlag.ok;
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
    final sessionsDone = countUniqueAttendanceDates(attendance);
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
      if (sessionsPaidTotal > 0 && sessionsDone >= sessionsPaidTotal) {
        return _PayFlag.red;
      }
      if (expiresAt > 0 && isNearExpiryMs(expiresAt)) return _PayFlag.yellow;
      if (sessionsPaidTotal > 0) {
        final left = sessionsPaidTotal - sessionsDone;
        if (left <= 1) return _PayFlag.yellow;
      }
      return _PayFlag.ok;
    }

    return paymentFlag(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsDone: sessionsDone,
      remindBeforeSession: remindBeforeSession > 0 ? remindBeforeSession : 1,
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
