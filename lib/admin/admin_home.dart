// ✅ FULL REPLACEMENT: lib/admin/admin_home.dart
// Copy-paste بالكامل (replace your whole file)

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:async/async.dart'; // ✅ needed for StreamZip
import 'admin_contract_screen.dart';
import 'admin_wages_screen.dart';
import 'admin_payments.dart';
import 'admin_courses.dart';
import 'admin_learners.dart';
import 'admin_staff.dart';
import 'admin_classes.dart';
import 'admin_public_gallery_screen.dart';
import 'admin_public_preview.dart';
import 'admin_subscriptions.dart';
import '../shared/session_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'admin_booking.dart';
import 'admin_attendance_overview_screen.dart';
// ✅ timetable
import 'admin_timetable_screen.dart';

// ✅ call logs
import '../calls/call_logs_screen.dart';

class AdminHome extends StatelessWidget {
  const AdminHome({super.key});

  // ===== Brand colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  Future<void> _logout(BuildContext context) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    // ✅ stop "single device" listener (so it doesn't run after logout)
    await SessionManager.stopListening();

    // ✅ remove FCM token record (your existing behavior)
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

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    // Responsive columns
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width >= 900 ? 4 : (width >= 600 ? 3 : 2);

    // ✅ ADJUSTED: Increased ratio makes cards shorter (Width / Height)
    final cardRatio = width >= 600 ? 1.4 : 1.3;

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        automaticallyImplyLeading: false,

        // ✅ LEFT SIDE
        leading: IconButton(
          tooltip: 'Call Logs',
          icon: const Icon(Icons.history, color: primaryBlue),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CallLogsScreen()),
            );
          },
        ),

        // ✅ CENTER TITLE
        centerTitle: true,
        title: const Text(
          'Admin Dashboard',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),

        // ✅ RIGHT SIDE
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: actionOrange),
            onPressed: () => _logout(context),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.05,
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.75,
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
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: uiBorder.withOpacity(0.7)),
                    ),
                    child: Row(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const AdminPublicPreview()),
                            );
                          },
                          child: Container(
                            width: 52,
                            height: 52,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: primaryBlue.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: primaryBlue.withOpacity(0.12)),
                            ),
                            child: Image.asset(
                              'assets/images/ybs_logo.png',
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                              const Icon(Icons.school_rounded, color: primaryBlue),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Welcome',
                                style: TextStyle(
                                  color: primaryBlue,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                user?.email ?? 'Admin',
                                style: TextStyle(
                                  color: mainText.withOpacity(0.75),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Grid
                  Expanded(
                    child: GridView.count(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: cardRatio,
                      children: [
                        _DashCard(
                          title: 'Courses',
                          subtitle: 'Manage courses',
                          icon: Icons.menu_book_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminCoursesScreen()),
                          ),
                        ),

                        const _AdminOnlineBookingDashCard(),
                        _DashCard(
                          title: 'Classes',
                          subtitle: 'Manage classes',
                          icon: Icons.class_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminClassesScreen()),
                          ),
                        ),
                        _DashCard(
                          title: 'Attendance',
                          subtitle: 'Daily / Weekly stats',
                          icon: Icons.fact_check_rounded,
                          color: primaryBlue,
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
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminTimetableScreen()),
                          ),
                        ),
                        _DashCard(
                          title: 'Payments',
                          subtitle: 'All payments',
                          icon: Icons.payments_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminPaymentsScreen()),
                          ),
                        ),
                        const _SubscriptionsDashCard(),
                        _LearnersDashCard(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminLearnersScreen()),
                          ),
                        ),
                        _DashCard(
                          title: 'Staff',
                          subtitle: 'Teachers & staff',
                          icon: Icons.badge_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminStaffScreen()),
                          ),
                        ),
                        _DashCard(
                          title: 'Wages',
                          subtitle: 'Teacher payments',
                          icon: Icons.wallet_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminWagesScreen()),
                          ),
                        ),
                        _DashCard(
                          title: 'Settings',
                          subtitle: 'Force update config',
                          icon: Icons.settings_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminForceUpdateAllScreen()),
                          ),
                        ),
                        _DashCard(
                          title: 'Contract',
                          subtitle: 'Contracts & documents',
                          icon: Icons.description_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AdminContractScreen()),
                          ),
                        ),
                        _DashCard(
                          title: 'Public Gallery',
                          subtitle: 'Teaser media',
                          icon: Icons.photo_library_rounded,
                          color: primaryBlue,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AdminPublicGalleryScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Your Bridge School',
                      style: TextStyle(
                        color: mainText.withOpacity(0.55),
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

// ===================== SUBSCRIPTIONS CARD =====================
class _AdminOnlineBookingDashCard extends StatelessWidget {
  const _AdminOnlineBookingDashCard();

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
          color: AdminHome.primaryBlue,
          badgeCount: count,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminBookingScreen()),
          ),
        );
      },
    );
  }
}
class _SubscriptionsDashCard extends StatelessWidget {
  const _SubscriptionsDashCard();

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance.ref('subscriptions');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snap) {
        int count = 0;
        final v = snap.data?.snapshot.value;
        if (v is Map) count = v.length;

        final subtitle =
        count == 0 ? 'No new registrations' : '$count new application${count == 1 ? '' : 's'}';

        return _DashCard(
          title: 'Subscriptions',
          subtitle: subtitle,
          icon: Icons.how_to_reg_rounded,
          color: AdminHome.primaryBlue,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminSubscriptionsScreen()),
          ),
        );
      },
    );
  }
}

// ===================== PAY FLAG (TOP LEVEL) =====================

enum _PayFlag { ok, yellow, red, black, noCourse }
// ===================== LEARNERS CARD (FIXED: uses CLASSES attendance like AdminLearnersScreen) =====================

class _LearnersDashCard extends StatelessWidget {
  final VoidCallback onTap;
  const _LearnersDashCard({required this.onTap});

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
    // no payment at all => BLACK
    if (sessionsPaidTotal <= 0) return _PayFlag.black;

    final rb = remindBeforeSession > 0 ? remindBeforeSession : 1;

    // next session to attend
    final currentSession = sessionsDone + 1;

    // exceeded paid => BLACK
    if (currentSession > sessionsPaidTotal) return _PayFlag.black;

    // dueAt example: paid=8, rb=1 => dueAt=7
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
      stream: StreamZip([usersRef.onValue]),      builder: (context, snap) {
        int totalLearners = 0;
        int blackCount = 0;
        int redCount = 0;
        int yellowCount = 0;
        int okCount = 0;
        int blueCount = 0;

        if (!snap.hasData || snap.data!.isEmpty) {
          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: _learnersCardUi(
              total: 0,
              black: 0,
              red: 0,
              yellow: 0,
              ok: 0,
              blue: 0,
              loading: true,
            ),
          );
        }

        final usersVal = snap.data![0].snapshot.value;


        if (usersVal is Map) {
          usersVal.forEach((uid, userVal) {
            if (uid == null || userVal == null) return;
            if (userVal is! Map) return;

            final userMap = userVal.map((k, vv) => MapEntry(k.toString(), vv));

            // learners only
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
              if (worst == _PayFlag.black) return; // strongest
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
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: _learnersCardUi(
            total: totalLearners,
            black: blackCount,
            red: redCount,
            yellow: yellowCount,
            ok: okCount,
            blue: blueCount,
            loading: false,
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
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD1D9E0).withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 4),
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
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AdminHome.primaryBlue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AdminHome.primaryBlue.withOpacity(0.12)),
              ),
              child: loading
                  ? const Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Icon(
                Icons.people_alt_rounded,
                color: AdminHome.primaryBlue,
                size: 18,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Learners',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 14,
                color: Color(0xFF1A2B48),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Students list',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 6),

            // ✅ One-line stats (color accurate)
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
                  TextSpan(text: '🟠 ', style: TextStyle(color: AdminHome.actionOrange)),
                  TextSpan(text: '$yellow   ', style: TextStyle(color: AdminHome.actionOrange)),
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
  const _DashCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    const uiBorder = Color(0xFFD1D9E0);

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: uiBorder.withOpacity(0.8)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: color.withOpacity(0.12)),
                    ),
                    child: Icon(icon, color: color, size: 20),
                  ),
                  if (badgeCount > 0)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
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
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  color: Color(0xFF1A2B48),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===================== FORCE UPDATE SCREEN (YOUR ORIGINAL, UNCHANGED) =====================

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
    // android
    aMinVersionC.dispose();
    aMinBuildC.dispose();
    aMessageC.dispose();
    aStoreUrlC.dispose();
    aStoreWebUrlC.dispose();

    // ios
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