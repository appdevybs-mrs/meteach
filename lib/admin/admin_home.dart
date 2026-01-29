import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'admin_courses.dart';

class AdminHome extends StatelessWidget {
  const AdminHome({super.key});

  // ===== Brand colors (same as main.dart) =====
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

      // ✅ Transparent watermark logo background
      body: Stack(
        children: [
          // Base background
          Container(color: appBg),

          // Watermark logo
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.05, // subtle
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

          // ✅ Screen content (EMPTY as requested)
          const SizedBox.expand(),
        ],
      ),

      // ✅ Drawer (hamburger) with Courses only
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Column(
            children: [
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
                            'Admin Panel',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            user?.email ?? 'Admin',
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

              ListTile(
                leading: const Icon(Icons.menu_book_rounded, color: primaryBlue),
                title: const Text(
                  'Courses',
                  style: TextStyle(
                    color: mainText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AdminCoursesScreen()),
                  );
                },
              ),

              const Spacer(),

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

      // ✅ AppBar
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Admin Dashboard',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        iconTheme: const IconThemeData(color: primaryBlue),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: actionOrange), // ✅ logout icon
            onPressed: () => _logout(context),
          )
        ],
      ),
    );
  }
}
