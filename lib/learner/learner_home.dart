import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

import 'learner_courses_screen.dart';
import 'learner_profile_screen.dart';

class LearnerHome extends StatefulWidget {
  const LearnerHome({super.key});

  @override
  State<LearnerHome> createState() => _LearnerHomeState();
}

class _LearnerHomeState extends State<LearnerHome> {
  // ✅ Courses is the first tab now
  int _index = 0;

  static const _pages = <Widget>[
    LearnerCoursesScreen(),
    _LearnerDashboardLite(),
    LearnerProfileScreen(),
  ];

  static const _titles = <String>[
    'My Courses',
    'Learner Dashboard',
    'Profile',
  ];

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final safeIndex = _index.clamp(0, _pages.length - 1);

    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        centerTitle: true,
        title: Text(
          _titles[safeIndex],
          style: const TextStyle(
            color: UiK.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout, color: UiK.actionOrange),
            onPressed: () => _logout(context),
          ),
        ],
      ),
      body: WatermarkBackground(child: _pages[safeIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: safeIndex,
        selectedItemColor: UiK.actionOrange,
        unselectedItemColor: UiK.primaryBlue.withOpacity(0.65),
        onTap: (i) => setState(() => _index = i),
        // ✅ Items order changed: Courses first
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.school_rounded), label: 'Courses'),
          BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }
}

/// Simple home: tells learner to use Courses.
/// (We keep it minimal & fast; Courses screen shows real progress per course.)
class _LearnerDashboardLite extends StatelessWidget {
  const _LearnerDashboardLite();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: Colors.white,
            shape: UiK.cardShape(),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Learner Dashboard', style: UiK.titleText(size: 18)),
                  const SizedBox(height: 10),
                  Text(
                    'Go to Courses to see your classes, attendance, and progress.',
                    style: UiK.subtleText(),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                      color: UiK.primaryBlue.withOpacity(0.04),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lightbulb_rounded, color: UiK.actionOrange),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Attendance is saved per course inside your profile.\n'
                                'Progress is calculated from the syllabus sessions that were taught.',
                            style: UiK.subtleText(),
                          ),
                        ),
                      ],
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
