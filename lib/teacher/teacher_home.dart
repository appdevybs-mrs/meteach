import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'teacher_profile.dart';
import 'teacher_classes.dart';
import 'teacher_payment.dart';
import 'teacher_mail.dart';
import 'teacher_reminder.dart';

class TeacherHomeScreen extends StatelessWidget {
  const TeacherHomeScreen({super.key});

  // ===== Brand colors (same as AdminHome) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;

    // ✅ Clear ALL screens and go back to the app root
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: appBg,

      // ✅ Transparent watermark logo background (same style)
      body: Stack(
        children: [
          Container(color: appBg),
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

          // ✅ Empty content for now
          const SizedBox.expand(),
        ],
      ),

      // ✅ Drawer / Burger menu
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                decoration: BoxDecoration(
                  color: primaryBlue,
                  border: Border(
                    bottom: BorderSide(color: uiBorder.withOpacity(0.7)),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.18)),
                      ),
                      child: Image.asset(
                        'assets/images/ybs_logo.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.school_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Teacher Panel',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            user?.email ?? 'Teacher',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontWeight: FontWeight.w600,
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

              const SizedBox(height: 6),

              // Menu items
              ListTile(
                leading: const Icon(Icons.person_rounded, color: primaryBlue),
                title: const Text(
                  'Profile',
                  style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TeacherProfileScreen()),
                  );
                },
              ),

              ListTile(
                leading: const Icon(Icons.class_rounded, color: primaryBlue),
                title: const Text(
                  'Classes',
                  style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TeacherClassesScreen()),
                  );
                },
              ),

              ListTile(
                leading: const Icon(Icons.payments_rounded, color: primaryBlue),
                title: const Text(
                  'Payment',
                  style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TeacherPaymentScreen()),
                  );
                },
              ),

              ListTile(
                leading: const Icon(Icons.mail_rounded, color: primaryBlue),
                title: const Text(
                  'Mail',
                  style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TeacherMailScreen()),
                  );
                },
              ),

              ListTile(
                leading: const Icon(Icons.alarm_rounded, color: primaryBlue),
                title: const Text(
                  'Reminder',
                  style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TeacherReminderScreen()),
                  );
                },
              ),

              const Spacer(),

              // Logout button in drawer
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: actionOrange),
                title: const Text(
                  'Log out',
                  style: TextStyle(color: mainText, fontWeight: FontWeight.w900),
                ),
                onTap: () => _logout(context),
              ),

              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'Dream English Academy',
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

      // ✅ AppBar (same style)
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Teacher Dashboard',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        iconTheme: const IconThemeData(color: primaryBlue),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: actionOrange),
            onPressed: () => _logout(context),
          )
        ],
      ),
    );
  }
}
