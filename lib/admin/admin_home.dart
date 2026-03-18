import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:async/async.dart'; // ✅ needed for StreamZip
import 'package:shared_preferences/shared_preferences.dart';
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
import '../shared/session_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'admin_booking.dart';
import 'admin_attendance_overview_screen.dart';
import 'admin_timetable_screen.dart';
import '../calls/call_logs_screen.dart';

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

  bool _isAdminMode = true;
  bool _loadingRole = true;

  @override
  void initState() {
    super.initState();
    _loadSavedRoleMode();
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
    } catch (e) {
      debugPrint('Error saving role mode: $e');
    }
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
    } catch (e) {
      debugPrint("Error removing token: $e");
    }

    await FirebaseAuth.instance.signOut();

    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  Color get _screenBg => _isAdminMode ? AdminHome.appBg : const Color(0xFFFBFCFE);

  Color get _headerTint => _isAdminMode
      ? const Color(0xFFEAF2FF)
      : const Color(0xFFFFF7F1);

  Color get _roleAccent =>
      _isAdminMode ? AdminHome.primaryBlue : AdminHome.actionOrange;

  String get _roleLabel => _isAdminMode ? 'Admin' : 'Receptionist';

  String get _screenTitle =>
      _isAdminMode ? 'Admin Dashboard' : 'Reception Desk';

  String get _roleDescription => _isAdminMode
      ? 'Full access to all management tools'
      : 'Daily front desk tools only';

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width >= 1100 ? 4 : (width >= 700 ? 3 : 2);
    final cardRatio = _isAdminMode
        ? (width >= 700 ? 1.22 : 1.10)
        : (width >= 700 ? 1.28 : 1.16);

    final allCards = <Widget>[
      _DashCard(
        title: 'Courses',
        subtitle: 'Manage courses',
        icon: Icons.menu_book_rounded,
        color: AdminHome.primaryBlue,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminCoursesScreen()),
        ),
      ),
      _AdminOnlineBookingDashCard(isReceptionistStyle: !_isAdminMode),
      _DashCard(
        title: 'Classes',
        subtitle: 'Manage classes',
        icon: Icons.class_rounded,
        color: AdminHome.actionOrange,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminClassesScreen()),
        ),
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
        title: 'Schedule',
        subtitle: 'Weekly timetable',
        icon: Icons.calendar_view_week_rounded,
        color: AdminHome.accentTeal,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminTimetableScreen()),
        ),
      ),
      _DashCard(
        title: 'Payments',
        subtitle: 'All payments',
        icon: Icons.payments_rounded,
        color: AdminHome.accentBlue,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
        ),
      ),
      _SubscriptionsDashCard(isReceptionistStyle: !_isAdminMode),
      _LearnersDashCard(
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
        ),
      ),
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
        color: AdminHome.accentSlate,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminStaffScreen()),
        ),
      ),
      _DashCard(
        title: 'Wages',
        subtitle: 'Teacher payments',
        icon: Icons.wallet_rounded,
        color: AdminHome.accentRose,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminWagesScreen()),
        ),
      ),
      _DashCard(
        title: 'Settings',
        subtitle: 'Force update config',
        icon: Icons.settings_rounded,
        color: AdminHome.accentSlate,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminForceUpdateAllScreen()),
        ),
      ),
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
      _DashCard(
        title: 'File Manager',
        subtitle: 'Courses & Games files',
        icon: Icons.folder_open,
        color: AdminHome.accentGreen,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminFileManager()),
        ),
      ),
      _DashCard(
        title: 'Public Gallery',
        subtitle: 'Teaser media',
        icon: Icons.photo_library_rounded,
        color: AdminHome.accentSky,
        isReceptionistStyle: !_isAdminMode,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AdminPublicGalleryScreen(),
          ),
        ),
      ),
    ];

    final receptionistCards = <Widget>[
      _AdminOnlineBookingDashCard(isReceptionistStyle: true),
      _DashCard(
        title: 'Classes',
        subtitle: 'Manage classes',
        icon: Icons.class_rounded,
        color: AdminHome.actionOrange,
        isReceptionistStyle: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminClassesScreen()),
        ),
      ),
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
      _DashCard(
        title: 'Payments',
        subtitle: 'All payments',
        icon: Icons.payments_rounded,
        color: AdminHome.accentBlue,
        isReceptionistStyle: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
        ),
      ),
      _SubscriptionsDashCard(isReceptionistStyle: true),
      _LearnersDashCard(
        isReceptionistStyle: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
        ),
      ),
      _DashCard(
        title: 'Public Gallery',
        subtitle: 'Teaser media',
        icon: Icons.photo_library_rounded,
        color: AdminHome.accentSky,
        isReceptionistStyle: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AdminPublicGalleryScreen(),
          ),
        ),
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
    ];

    final visibleCards = _isAdminMode ? allCards : receptionistCards;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: _screenBg,
      drawer: _AdminHomeDrawer(
        userEmail: user?.email ?? 'Admin',
        isAdminMode: _isAdminMode,
        loadingRole: _loadingRole,
        onSelectAdmin: () async {
          Navigator.of(context).pop();
          await _setRoleMode(true);
        },
        onSelectReceptionist: () async {
          Navigator.of(context).pop();
          await _setRoleMode(false);
        },
        onOpenCallLogs: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CallLogsScreen()),
          );
        },
        onOpenPublicPreview: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminPublicPreview()),
          );
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
            child: IgnorePointer(
              child: Opacity(
                opacity: _isAdminMode ? 0.035 : 0.028,
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.72,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
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
                  // Compact header card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isAdminMode
                            ? AdminHome.uiBorder
                            : const Color(0xFFFFE7D1),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(
                            _isAdminMode ? 0.04 : 0.03,
                          ),
                          blurRadius: _isAdminMode ? 16 : 12,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const AdminPublicPreview(),
                              ),
                            );
                          },
                          child: Container(
                            width: 50,
                            height: 50,
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: _headerTint,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _isAdminMode
                                    ? AdminHome.uiBorder
                                    : const Color(0xFFFFE7D1),
                              ),
                            ),
                            child: Image.asset(
                              'assets/images/ybs_logo.png',
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.school_rounded,
                                color: _roleAccent,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _isAdminMode
                                    ? 'Welcome back'
                                    : 'Welcome to reception',
                                style: const TextStyle(
                                  color: AdminHome.primaryBlue,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                user?.email ?? 'Admin',
                                style: const TextStyle(
                                  color: AdminHome.softText,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11.5,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _headerTint,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      _roleLabel,
                                      style: TextStyle(
                                        color: _roleAccent,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _roleDescription,
                                    style: const TextStyle(
                                      color: AdminHome.softText,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Grid
                  Expanded(
                    child: GridView.count(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: cardRatio,
                      children: visibleCards,
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
  final VoidCallback onSelectAdmin;
  final VoidCallback onSelectReceptionist;
  final VoidCallback onOpenCallLogs;
  final VoidCallback onOpenPublicPreview;
  final VoidCallback onLogout;

  const _AdminHomeDrawer({
    required this.userEmail,
    required this.isAdminMode,
    required this.loadingRole,
    required this.onSelectAdmin,
    required this.onSelectReceptionist,
    required this.onOpenCallLogs,
    required this.onOpenPublicPreview,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor =
    isAdminMode ? AdminHome.primaryBlue : AdminHome.actionOrange;

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
                    icon: Icons.history_rounded,
                    title: 'Call Logs',
                    subtitle: 'Open recent calls history',
                    color: AdminHome.accentIndigo,
                    onTap: onOpenCallLogs,
                  ),
                  _DrawerTile(
                    icon: Icons.public_rounded,
                    title: 'Public Preview',
                    subtitle: 'Open public website preview',
                    color: AdminHome.accentSky,
                    onTap: onOpenPublicPreview,
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
        ? selectedColor.withOpacity(0.10)
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
          color: color.withOpacity(0.10),
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

  const _AdminOnlineBookingDashCard({
    this.isReceptionistStyle = false,
  });

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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminBookingScreen()),
          ),
        );
      },
    );
  }
}

class _SubscriptionsDashCard extends StatelessWidget {
  final bool isReceptionistStyle;

  const _SubscriptionsDashCard({
    this.isReceptionistStyle = false,
  });

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

// ===================== PAY FLAG =====================

enum _PayFlag { ok, yellow, red, black, noCourse }

// ===================== LEARNERS CARD =====================

class _LearnersDashCard extends StatelessWidget {
  final VoidCallback onTap;
  final bool isReceptionistStyle;

  const _LearnersDashCard({
    required this.onTap,
    this.isReceptionistStyle = false,
  });

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static int _countUniqueAttendanceDates(dynamic attendance) {
    if (attendance is! Map) return 0;

    final Set<String> dates = {};
    attendance.forEach((_, v) {
      if (v is! Map) return;
      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final d = (m['date'] ?? '').toString().trim();
      if (d.isNotEmpty) dates.add(d);
    });

    return dates.length;
  }

  static int _rank(_PayFlag f) {
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

  static _PayFlag _paymentFlag({
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

    if (currentSession == dueAt) return _PayFlag.red;
    if (warnAt >= 1 && currentSession == warnAt) return _PayFlag.yellow;

    return _PayFlag.ok;
  }

  static String _classIdOf(Map<String, dynamic> courseMap) {
    final cls = courseMap['class'];
    if (cls is Map) {
      final m = cls.map((k, v) => MapEntry(k.toString(), v));
      final id = (m['class_id'] ?? '').toString().trim();
      if (id.isNotEmpty) return id;
    }
    final direct = (courseMap['class_id'] ?? '').toString().trim();
    return direct;
  }

  @override
  Widget build(BuildContext context) {
    final usersRef = FirebaseDatabase.instance.ref('users');

    return StreamBuilder<List<DatabaseEvent>>(
      stream: StreamZip([usersRef.onValue]),
      builder: (context, snap) {
        int totalLearners = 0;
        int blackCount = 0;
        int redCount = 0;
        int yellowCount = 0;
        int okCount = 0;
        int blueCount = 0;

        if (!snap.hasData || snap.data!.isEmpty) {
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: _learnersCardUi(
              total: 0,
              black: 0,
              red: 0,
              yellow: 0,
              ok: 0,
              blue: 0,
              loading: true,
              isReceptionistStyle: isReceptionistStyle,
            ),
          );
        }

        final usersVal = snap.data![0].snapshot.value;

        if (usersVal is Map) {
          usersVal.forEach((uid, userVal) {
            if (uid == null || userVal == null) return;
            if (userVal is! Map) return;

            final userMap = userVal.map((k, vv) => MapEntry(k.toString(), vv));

            final role = (userMap['role'] ?? '').toString().toLowerCase().trim();
            if (role != 'learner') return;

            totalLearners++;

            final courses = userMap['courses'];
            if (courses is! Map || courses.isEmpty) {
              blueCount++;
              return;
            }

            _PayFlag worst = _PayFlag.ok;

            courses.forEach((courseKey, courseVal) {
              if (courseKey == null || courseVal == null) return;
              if (courseVal is! Map) return;

              final courseMap = courseVal.map((k, vv) => MapEntry(k.toString(), vv));

              final sum = courseMap['payment_summary'];
              final sumMap = sum is Map
                  ? sum.map((k, vv) => MapEntry(k.toString(), vv))
                  : <String, dynamic>{};

              final sessionsPaidTotal = _asInt(sumMap['sessionsPaidTotal']);
              final remind = _asInt(sumMap['remindBeforeSession']);
              final remindBefore = remind > 0 ? remind : 1;

              final attendance = courseMap['attendance'];
              final sessionsDone = _countUniqueAttendanceDates(attendance);

              final flag = _paymentFlag(
                sessionsPaidTotal: sessionsPaidTotal,
                sessionsDone: sessionsDone,
                remindBeforeSession: remindBefore,
              );

              if (_rank(flag) > _rank(worst)) worst = flag;
              if (worst == _PayFlag.black) return;
            });

            switch (worst) {
              case _PayFlag.black:
                blackCount++;
                break;
              case _PayFlag.red:
                redCount++;
                break;
              case _PayFlag.yellow:
                yellowCount++;
                break;
              case _PayFlag.ok:
              default:
                okCount++;
                break;
            }
          });
        }

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: _learnersCardUi(
            total: totalLearners,
            black: blackCount,
            red: redCount,
            yellow: yellowCount,
            ok: okCount,
            blue: blueCount,
            loading: false,
            isReceptionistStyle: isReceptionistStyle,
          ),
        );
      },
    );
  }

  Widget _learnersCardUi({
    required int total,
    required int black,
    required int red,
    required int yellow,
    required int ok,
    required int blue,
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
            color: Colors.black.withOpacity(boxShadowOpacity),
            blurRadius: isReceptionistStyle ? 10 : 14,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
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
            RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10),
                children: [
                  TextSpan(text: '👥 $total   ', style: TextStyle(color: Colors.grey.shade700)),
                  const TextSpan(text: '🔵 ', style: TextStyle(color: Colors.blue)),
                  TextSpan(text: '$blue   ', style: const TextStyle(color: Colors.blue)),
                  const TextSpan(text: '🖤 ', style: TextStyle(color: Colors.black)),
                  TextSpan(text: '$black   ', style: const TextStyle(color: Colors.black)),
                  const TextSpan(text: '🔴 ', style: TextStyle(color: Colors.red)),
                  TextSpan(text: '$red   ', style: const TextStyle(color: Colors.red)),
                  TextSpan(
                    text: '🟠 ',
                    style: TextStyle(color: AdminHome.actionOrange),
                  ),
                  TextSpan(
                    text: '$yellow   ',
                    style: TextStyle(color: AdminHome.actionOrange),
                  ),
                  const TextSpan(text: '✅ ', style: TextStyle(color: Colors.green)),
                  TextSpan(text: '$ok', style: const TextStyle(color: Colors.green)),
                ],
              ),
            ),
          ],
        ),
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
          color: AdminHome.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(shadowOpacity),
              blurRadius: isReceptionistStyle ? 10 : 14,
              offset: const Offset(0, 6),
            )
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
                          ? _softBg(color).withOpacity(0.82)
                          : _softBg(color),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: color, size: 21),
                  ),
                  const Spacer(),
                  if (badgeCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
  State<AdminForceUpdateAllScreen> createState() => _AdminForceUpdateAllScreenState();
}

class _AdminForceUpdateAllScreenState extends State<AdminForceUpdateAllScreen> {
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

  bool loading = true;
  bool saving = false;

  DatabaseReference get _root => FirebaseDatabase.instance.ref('appConfig/forceUpdate');

  @override
  void initState() {
    super.initState();
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

  Future<void> _loadAll() async {
    setState(() => loading = true);
    try {
      final snap = await _root.get();
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Load failed: $e')),
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

      await _root.update({
        'allowAdminBypass': true,
        'android': android,
        'ios': ios,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved all ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
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
    final ok = await _confirm(context, 'Delete Android config?', 'This removes appConfig/forceUpdate/android.');
    if (!ok) return;
    await _root.child('android').remove();
    await _loadAll();
  }

  Future<void> _deleteIos() async {
    final ok = await _confirm(context, 'Delete iOS config?', 'This removes appConfig/forceUpdate/ios.');
    if (!ok) return;
    await _root.child('ios').remove();
    await _loadAll();
  }

  Future<void> _deleteAll() async {
    final ok = await _confirm(context, 'Delete ALL forceUpdate?', 'This removes appConfig/forceUpdate بالكامل.');
    if (!ok) return;
    await _root.remove();
    if (!mounted) return;
    Navigator.pop(context);
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
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
          const SizedBox(height: 10),
          TextField(
            controller: minVersionC,
            decoration: const InputDecoration(labelText: 'minVersion (example: 2.0.0)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: minBuildC,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'minBuild (example: 76)'),
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
          'Force Update (All)',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: saving ? null : _deleteAll,
                  icon: const Icon(Icons.delete_forever_rounded),
                  label: const Text('Delete ALL'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: actionOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: saving ? null : _saveAll,
                  icon: saving
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                      : const Icon(Icons.save_rounded),
                  label: Text(saving ? 'Saving…' : 'Save ALL'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
              'Tip:\n- To force update, increase minBuild.\n- Example: users 75 → set minBuild 76.\n- If you want to block by version, increase minVersion.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}