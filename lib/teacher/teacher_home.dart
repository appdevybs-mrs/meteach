import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'teacher_profile.dart';
import 'teacher_classes.dart';
import 'teacher_payment.dart';
import 'teacher_mail.dart';
import 'teacher_reminder.dart';
import 'teacher_schedule.dart';

class TeacherHomeScreen extends StatelessWidget {
  const TeacherHomeScreen({super.key});

  // ===== Brand colors =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: appBg,
      // AppBar kept for the Logout action and Title
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        centerTitle: true,
        title: const Text(
          'Teacher Dashboard',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: actionOrange),
            onPressed: () => _logout(context),
          )
        ],
      ),

      body: Stack(
        children: [
          // Subtle Watermark Logo
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.05,
                child: Center(
                  child: Image.asset(
                      'assets/images/ybs_logo.png',
                      width: 280,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()
                  ),
                ),
              ),
            ),
          ),

          // Main Grid Content
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                Text(
                  'Welcome,',
                  style: TextStyle(color: mainText.withOpacity(0.6), fontSize: 16, fontWeight: FontWeight.w600),
                ),
                Text(
                  user?.email?.split('@')[0].toUpperCase() ?? 'TEACHER',
                  style: const TextStyle(
                    color: primaryBlue,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 32),

                // --- GRID VIEW START ---
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1.1, // Adjusts the height/width ratio of cards
                    children: [
                      _buildQuickCard(context, 'Schedule', Icons.calendar_today_rounded, const AdminScheduleScreen()),
                      _buildQuickCard(context, 'My Classes', Icons.school_rounded, const TeacherClassesScreen()),
                      _buildQuickCard(context, 'Profile', Icons.person_rounded, const TeacherProfileScreen()),
                      _buildQuickCard(context, 'Mail', Icons.email_rounded, const TeacherMailScreen()),
                      _buildQuickCard(context, 'Payment', Icons.payments_rounded, const TeacherPaymentScreen()),
                      _buildQuickCard(context, 'Reminders', Icons.alarm_rounded, const TeacherReminderScreen()),
                    ],
                  ),
                ),

                // Branding footer
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Text(
                      'Dream English Academy',
                      style: TextStyle(
                        color: mainText.withOpacity(0.4),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
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

  // Professional Grid Card UI
  Widget _buildQuickCard(BuildContext context, String title, IconData icon, Widget destination) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => destination),
      ),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: uiBorder.withOpacity(0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: appBg,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: primaryBlue),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: mainText,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}