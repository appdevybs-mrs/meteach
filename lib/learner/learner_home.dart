import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import 'learner_mail_screen.dart';

import 'learner_courses_screen.dart';
import 'learner_profile_screen.dart';

// ✅ Call logs screen
import '../calls/call_logs_screen.dart';

class LearnerHome extends StatefulWidget {
  const LearnerHome({super.key});

  @override
  State<LearnerHome> createState() => _LearnerHomeState();
}

class _LearnerHomeState extends State<LearnerHome> {
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
            tooltip: 'Call Logs',
            icon: const Icon(Icons.history, color: UiK.primaryBlue),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CallLogsScreen()),
              );
            },
          ),
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
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.school_rounded), label: 'Courses'),
          BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.person_rounded), label: 'Profile'),
        ],
      ),
    );
  }
}

/// Simple home dashboard with cards
class _LearnerDashboardLite extends StatelessWidget {
  const _LearnerDashboardLite();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _HomeCardsGrid(),
          const SizedBox(height: 12),
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
                    'Use the cards above to access your tools. Courses stay in the Courses tab.',
                    style: UiK.subtleText(),
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

class _HomeCardsGrid extends StatelessWidget {
  const _HomeCardsGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.25,
      children: const [
        _MailHomeCard(),
        _HomeCard(
          icon: Icons.assignment_rounded,
          title: 'Homework',
          subtitle: 'Coming soon',
          routeType: _HomeCardRoute.homework,
        ),
        _HomeCard(
          icon: Icons.notifications_active_rounded,
          title: 'Reminders',
          subtitle: 'Coming soon',
          routeType: _HomeCardRoute.reminders,
        ),
        _HomeCard(
          icon: Icons.group_rounded,
          title: 'Friends',
          subtitle: 'Coming soon',
          routeType: _HomeCardRoute.friends,
        ),
      ],
    );
  }
}

/// ✅ Special card: Mail + unread badge sum
class _MailHomeCard extends StatelessWidget {
  const _MailHomeCard();

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser;
    final meUid = me?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('mail_index/$meUid');

    return StreamBuilder<DatabaseEvent>(
      stream: meUid.isEmpty ? const Stream.empty() : ref.onValue,
      builder: (context, snap) {
        int unreadTotal = 0;

        final v = snap.data?.snapshot.value;
        if (v is Map) {
          v.forEach((_, vv) {
            if (vv is! Map) return;
            final m = vv.map((k, v) => MapEntry(k.toString(), v));

            // ignore deleted threads for me
            final deletedAt = m['deletedAt'];
            if (deletedAt != null) return;

            final unread = _toInt(m['unreadCount']);
            unreadTotal += unread;
          });
        }

        return _HomeCard(
          icon: Icons.mail_rounded,
          title: 'Mail',
          subtitle: 'Read & reply',
          routeType: _HomeCardRoute.mail,
          badgeCount: unreadTotal,
        );
      },
    );
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

enum _HomeCardRoute { mail, homework, reminders, friends }

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.routeType,
    this.badgeCount = 0,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _HomeCardRoute routeType;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    Widget iconBox() {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: UiK.primaryBlue.withOpacity(0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            child: Icon(icon, color: UiK.primaryBlue),
          ),
          if (badgeCount > 0)
            Positioned(
              right: -8,
              top: -8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        if (routeType == _HomeCardRoute.mail) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LearnerMailScreen()),
          );
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$title is not ready yet.')),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            iconBox(),
            const Spacer(),
            Text(title, style: UiK.titleText(size: 16)),
            const SizedBox(height: 4),
            Text(subtitle, style: UiK.subtleText()),
          ],
        ),
      ),
    );
  }
}
