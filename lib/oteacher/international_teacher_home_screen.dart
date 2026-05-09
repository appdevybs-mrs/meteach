import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/topic_service.dart';
import '../shared/app_theme.dart';
import '../shared/material_webview_screen.dart';
import '../learner/learner_games_screen.dart';
import '../learner/learner_stories_screen.dart';
import 'international_teacher_profile_screen.dart';

class InternationalTeacherHomeScreen extends StatefulWidget {
  const InternationalTeacherHomeScreen({super.key});

  @override
  State<InternationalTeacherHomeScreen> createState() =>
      _InternationalTeacherHomeScreenState();
}

class _InternationalTeacherHomeScreenState
    extends State<InternationalTeacherHomeScreen> {
  final _db = FirebaseDatabase.instance.ref();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _loading = true;
  String _name = 'International Teacher';
  String _photo = '';
  Map<String, dynamic> _subscription = <String, dynamic>{};
  List<Map<String, String>> _courses = <Map<String, String>>[];
  List<Map<String, dynamic>> _subscriptionHistory = <Map<String, dynamic>>[];

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _load() async {
    final uid = _uid;
    if (uid.isEmpty) return;
    setState(() => _loading = true);
    try {
      final snaps = await Future.wait([
        _db.child('users/$uid').get(),
        _db.child('international_teacher_assignments/$uid/courses').get(),
        _db.child('international_teacher_subscription/$uid').get(),
        _db.child('international_teacher_subscriptions/$uid').get(),
      ]);

      final userMap = _asMap(snaps[0].value);
      final first = (userMap['first_name'] ?? '').toString().trim();
      final last = (userMap['last_name'] ?? '').toString().trim();
      _name = [first, last].where((e) => e.isNotEmpty).join(' ').trim();
      if (_name.isEmpty) _name = 'International Teacher';
      _photo = (userMap['profile_photo'] ?? '').toString().trim();

      _subscription = _asMap(snaps[2].value);
      _subscriptionHistory = _asListMapWithId(snaps[3].value);

      final assigned = <String>[];
      final rawCourses = snaps[1].value;
      if (rawCourses is Map) {
        rawCourses.forEach((k, v) {
          if (v == true) assigned.add(k.toString());
        });
      }

      final loadedCourses = <Map<String, String>>[];
      for (final cid in assigned) {
        final cSnap = await _db.child('courses/$cid').get();
        final cMap = _asMap(cSnap.value);
        if (cMap.isEmpty) continue;
        loadedCourses.add({
          'id': cid,
          'title': (cMap['title'] ?? '').toString(),
          'code': (cMap['course_code'] ?? '').toString(),
          'thumbnail': (cMap['thumbnail'] ?? '').toString().trim(),
        });
      }
      loadedCourses.sort(
        (a, b) => (a['title'] ?? '').toLowerCase().compareTo(
          (b['title'] ?? '').toLowerCase(),
        ),
      );
      _courses = loadedCourses;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isExpired {
    final raw = (_subscription['expiresOn'] ?? '').toString().trim();
    if (raw.isEmpty) return false;
    final dt = DateTime.tryParse(raw);
    if (dt == null) return false;
    final today = DateTime.now();
    final nowDate = DateTime(today.year, today.month, today.day);
    final expDate = DateTime(dt.year, dt.month, dt.day);
    return expDate.isBefore(nowDate);
  }

  Future<void> _logout() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Logging out...',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
    try {
      final uid = _uid;
      if (uid.isNotEmpty) {
        await TopicService.clearForUser(uid);
      }
      await FirebaseAuth.instance.signOut();
    } finally {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<void> _openThemePicker() async {
    final modes = AppThemeMode.values;
    final p = appThemeController.palette;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Opacity(
                    opacity: 0.05,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      width: 240,
                    ),
                  ),
                ),
              ),
            ),
            ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              children: [
                const ListTile(
                  title: Text(
                    'Theme settings',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text('Choose your app look'),
                ),
                for (final m in modes)
                  ListTile(
                    leading: SizedBox(
                      width: 70,
                      child: Row(
                        children: [
                          Icon(
                            appThemeController.mode == m
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          ...[
                            appThemeController.paletteForMode(m).primary,
                            appThemeController.paletteForMode(m).accent,
                            appThemeController.paletteForMode(m).appBg,
                          ].map(
                            (c) => Container(
                              margin: const EdgeInsets.only(right: 4),
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    title: Text(appThemeController.themeTitle(m)),
                    subtitle: Text(appThemeController.themeSubtitle(m)),
                    onTap: () async {
                      await appThemeController.setTheme(m);
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: p.appBg,
      drawer: _OTeacherDrawer(
        palette: p,
        name: _name,
        photoUrl: _photo,
        onOpenProfile: () {
          Navigator.of(context).pop();
          Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (_) => InternationalTeacherProfileScreen(uid: _uid),
                ),
              )
              .then((_) => _load());
        },
        onOpenStories: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LearnerStoriesScreen()),
          );
        },
        onOpenGames: () {
          Navigator.of(context).pop();
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LearnerGamesScreen()));
        },
        onOpenSubscription: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _SubscriptionScreen(
                subscription: _subscription,
                history: _subscriptionHistory,
              ),
            ),
          );
        },
        onOpenTheme: () {
          Navigator.of(context).pop();
          _openThemePicker();
        },
        onLogout: _logout,
      ),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: p.primary,
        title: const Text('International Teacher'),
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: SafeArea(
                top: false,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: Opacity(
                            opacity: 0.055,
                            child: Image.asset(
                              'assets/images/ybs_logo.png',
                              width: 320,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                    ),
                    ListView(
                      padding: EdgeInsets.fromLTRB(
                        14,
                        4,
                        14,
                        20 + MediaQuery.of(context).padding.bottom,
                      ),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            gradient: LinearGradient(
                              colors: [
                                p.primary,
                                Color.lerp(p.primary, p.accent, 0.35) ??
                                    p.primary,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x220D2B45),
                                blurRadius: 24,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 32,
                                backgroundColor: Colors.white24,
                                backgroundImage: _photo.isEmpty
                                    ? null
                                    : NetworkImage(_photo),
                                child: _photo.isEmpty
                                    ? const Icon(
                                        Icons.person,
                                        color: Colors.white,
                                        size: 30,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: p.accent.withValues(alpha: 0.28),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: const Text(
                                        'Premium Teacher Hub',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'Welcome back',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 20,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'Flexible course materials access',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_isExpired) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: p.soft.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: p.accent.withValues(alpha: 0.55),
                              ),
                            ),
                            child: Text(
                              'Your subscription has expired. Course start is locked until renewal.',
                              style: TextStyle(
                                color: p.text,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        const Text(
                          'Assigned Courses',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (_courses.isEmpty)
                          const Card(
                            child: ListTile(
                              title: Text('No assigned courses yet.'),
                              subtitle: Text(
                                'Ask admin to assign your courses.',
                              ),
                            ),
                          ),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _courses.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: 1,
                              ),
                          itemBuilder: (context, i) {
                            final c = _courses[i];
                            return _CourseSquareCard(
                              palette: p,
                              title: (c['title'] ?? '').isEmpty
                                  ? 'Untitled course'
                                  : c['title']!,
                              code: c['code'] ?? '',
                              imageUrl: c['thumbnail'] ?? '',
                              locked: _isExpired,
                              onStart: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        _InternationalTeacherSyllabusScreen(
                                          courseId: c['id']!,
                                          courseTitle: c['title'] ?? 'Course',
                                        ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  List<Map<String, dynamic>> _asListMapWithId(dynamic raw) {
    if (raw is! Map) return <Map<String, dynamic>>[];
    final rows = <Map<String, dynamic>>[];
    raw.forEach((k, v) {
      if (v is! Map) return;
      final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      m['id'] = k.toString();
      rows.add(m);
    });
    rows.sort((a, b) {
      final at = (a['createdAt'] is num) ? (a['createdAt'] as num).toInt() : 0;
      final bt = (b['createdAt'] is num) ? (b['createdAt'] as num).toInt() : 0;
      return bt.compareTo(at);
    });
    return rows;
  }
}

class _CourseSquareCard extends StatelessWidget {
  const _CourseSquareCard({
    required this.palette,
    required this.title,
    required this.code,
    required this.imageUrl,
    required this.locked,
    required this.onStart,
  });

  final AppPalette palette;
  final String title;
  final String code;
  final String imageUrl;
  final bool locked;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: palette.cardBg,
        boxShadow: const [
          BoxShadow(
            color: Color(0x110D2B45),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            Positioned.fill(
              child: imageUrl.isEmpty
                  ? Container(
                      color: palette.soft,
                      child: const Icon(Icons.image_outlined, size: 36),
                    )
                  : Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: palette.soft,
                        child: const Icon(Icons.image_not_supported_outlined),
                      ),
                    ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.08),
                      Colors.black.withValues(alpha: 0.74),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    code.isEmpty ? 'Flexible syllabus' : code,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: locked ? null : onStart,
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.accent,
                        disabledBackgroundColor: palette.text.withValues(
                          alpha: 0.35,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: Text(locked ? 'Locked' : 'Start'),
                    ),
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

class _OTeacherDrawer extends StatelessWidget {
  const _OTeacherDrawer({
    required this.palette,
    required this.name,
    required this.photoUrl,
    required this.onOpenProfile,
    required this.onOpenStories,
    required this.onOpenGames,
    required this.onOpenSubscription,
    required this.onOpenTheme,
    required this.onLogout,
  });

  final AppPalette palette;
  final String name;
  final String photoUrl;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenStories;
  final VoidCallback onOpenGames;
  final VoidCallback onOpenSubscription;
  final VoidCallback onOpenTheme;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: palette.appBg,
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  colors: [
                    palette.primary,
                    Color.lerp(palette.primary, palette.accent, 0.3) ??
                        palette.primary,
                  ],
                ),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.white24,
                    backgroundImage: photoUrl.trim().isEmpty
                        ? null
                        : NetworkImage(photoUrl),
                    child: photoUrl.trim().isEmpty
                        ? const Icon(Icons.person, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _DrawerItem(
              icon: Icons.person_outline,
              title: 'Profile',
              onTap: onOpenProfile,
            ),
            _DrawerItem(
              icon: Icons.auto_stories_outlined,
              title: 'Stories',
              onTap: onOpenStories,
            ),
            _DrawerItem(
              icon: Icons.sports_esports_outlined,
              title: 'Games',
              onTap: onOpenGames,
            ),
            _DrawerItem(
              icon: Icons.workspace_premium_outlined,
              title: 'Subscription',
              onTap: onOpenSubscription,
            ),
            _DrawerItem(
              icon: Icons.palette_outlined,
              title: 'Theme',
              onTap: onOpenTheme,
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => onLogout(),
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accent,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.title,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Material(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: Icon(icon, color: appThemeController.palette.primary),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _SubscriptionScreen extends StatelessWidget {
  const _SubscriptionScreen({
    required this.subscription,
    required this.history,
  });
  final Map<String, dynamic> subscription;
  final List<Map<String, dynamic>> history;

  ({double pct, int days, Color color, String state}) _status(AppPalette p) {
    final start = DateTime.tryParse(
      (subscription['startsOn'] ?? '').toString(),
    );
    final end = DateTime.tryParse((subscription['expiresOn'] ?? '').toString());
    if (start == null || end == null || !end.isAfter(start)) {
      return (pct: 0, days: 0, color: p.border, state: 'Not set');
    }
    final now = DateTime.now();
    final total = end.difference(start).inSeconds;
    final left = end.difference(now).inSeconds;
    final pct = (left / total).clamp(0, 1).toDouble();
    final days = end.difference(DateTime(now.year, now.month, now.day)).inDays;
    if (left <= 0) {
      return (pct: 0, days: 0, color: Colors.red.shade700, state: 'Expired');
    }
    if (pct <= 0.10) {
      return (
        pct: pct,
        days: days,
        color: Colors.orange.shade800,
        state: 'Critical',
      );
    }
    if (pct <= 0.30) {
      return (
        pct: pct,
        days: days,
        color: Colors.amber.shade700,
        state: 'Expiring',
      );
    }
    return (
      pct: pct,
      days: days,
      color: Colors.green.shade700,
      state: 'Active',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;
    final amount = (subscription['amountPaidUsd'] ?? '').toString();
    final startsOn = (subscription['startsOn'] ?? '').toString();
    final expiresOn = (subscription['expiresOn'] ?? '').toString();
    final st = _status(p);
    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(title: const Text('Subscription')),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Opacity(
                    opacity: 0.05,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      width: 300,
                    ),
                  ),
                ),
              ),
            ),
            ListView(
              padding: EdgeInsets.fromLTRB(
                14,
                14,
                14,
                14 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Current Subscription',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                            const Spacer(),
                            Text(
                              st.state,
                              style: TextStyle(
                                color: st.color,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('USD ${amount.isEmpty ? '-' : amount}'),
                        Text(
                          startsOn.isEmpty || expiresOn.isEmpty
                              ? 'No active period'
                              : '$startsOn -> $expiresOn',
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            minHeight: 10,
                            value: st.pct,
                            color: st.color,
                            backgroundColor: p.soft,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          st.days > 0 ? '${st.days} days left' : 'Expired',
                          style: TextStyle(
                            color: st.color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Previous Subscriptions',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 8),
                        if (history.isEmpty)
                          const Text('No subscription history yet.')
                        else
                          for (final h in history)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.history_rounded),
                              title: Text(
                                'USD ${(h['amountPaidUsd'] ?? '-').toString()}',
                              ),
                              subtitle: Text(
                                '${(h['startsOn'] ?? '').toString()} -> ${(h['expiresOn'] ?? '').toString()}',
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InternationalTeacherSyllabusScreen extends StatefulWidget {
  const _InternationalTeacherSyllabusScreen({
    required this.courseId,
    required this.courseTitle,
  });
  final String courseId;
  final String courseTitle;

  @override
  State<_InternationalTeacherSyllabusScreen> createState() =>
      _InternationalTeacherSyllabusScreenState();
}

class _InternationalTeacherSyllabusScreenState
    extends State<_InternationalTeacherSyllabusScreen> {
  final _db = FirebaseDatabase.instance.ref();
  bool _loading = true;
  List<_SyllabusLesson> _lessons = <_SyllabusLesson>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final snap = await _db.child('syllabi/${widget.courseId}/flexible').get();
      final root = snap.value;
      final out = <_SyllabusLesson>[];
      if (root is Map) {
        final m = root.map((k, v) => MapEntry(k.toString(), v));
        final units = _asListMap(m['units']);
        for (int i = 0; i < units.length; i++) {
          final u = units[i];
          final unitTitle = (u['title'] ?? u['name'] ?? 'Unit ${i + 1}')
              .toString()
              .trim();
          final unitObjective =
              (u['objectives'] ?? u['objective'] ?? u['description'] ?? '')
                  .toString()
                  .trim();
          final sessions = _asListMap(u['sessions']).isNotEmpty
              ? _asListMap(u['sessions'])
              : _asListMap(u['lessons']);
          for (int j = 0; j < sessions.length; j++) {
            final s = sessions[j];
            final title = (s['title'] ?? s['name'] ?? 'Lesson ${j + 1}')
                .toString()
                .trim();
            final materialsUrl = (s['materialsUrl'] ?? '').toString().trim();
            final objective =
                (s['objectives'] ?? s['objective'] ?? unitObjective)
                    .toString()
                    .trim();
            final content = (s['content'] ?? s['scope'] ?? '')
                .toString()
                .trim();
            final homework = (s['homework'] ?? '').toString().trim();
            final skillType = (s['skillType'] ?? s['skill'] ?? '')
                .toString()
                .trim();
            final id = (s['id'] ?? '').toString().trim();
            final orderRaw = (s['sessionNumber'] ?? s['order'] ?? (j + 1))
                .toString()
                .trim();
            final durationRaw = (s['durationMinutes'] ?? s['duration'] ?? '')
                .toString()
                .trim();
            final sessionLabel = orderRaw.isEmpty
                ? 'Session ${j + 1}'
                : 'Session $orderRaw';
            out.add(
              _SyllabusLesson(
                unitTitle: unitTitle,
                unitObjective: unitObjective,
                sessionLabel: sessionLabel,
                lessonTitle: title,
                materialsUrl: materialsUrl,
                objective: objective,
                content: content,
                durationMinutes: durationRaw,
                homework: homework,
                skillType: skillType,
                lessonId: id,
                order: orderRaw,
              ),
            );
          }
        }
      }
      _lessons = out;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;
    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        title: Text(widget.courseTitle),
        actions: [
          IconButton(
            tooltip: 'Course book',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Book panel coming soon.')),
              );
            },
            icon: const Icon(Icons.menu_book_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Opacity(
                    opacity: 0.05,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      width: 300,
                    ),
                  ),
                ),
              ),
            ),
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _lessons.isEmpty
                ? const Center(child: Text('No flexible syllabus found.'))
                : ListView.builder(
                    padding: EdgeInsets.only(
                      bottom: 10 + MediaQuery.of(context).padding.bottom,
                    ),
                    itemCount: _lessons.length,
                    itemBuilder: (context, i) {
                      final l = _lessons[i];
                      final accent = _skillColor(l.skillType);
                      return Card(
                        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        shape: RoundedRectangleBorder(
                          side: BorderSide(
                            color: accent.withValues(alpha: 0.35),
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final useMenu = constraints.maxWidth < 410;
                            return ListTile(
                              title: Text(l.lessonTitle),
                              subtitle: Text(
                                '${l.unitTitle} • ${l.sessionLabel}',
                              ),
                              leading: CircleAvatar(
                                backgroundColor: accent.withValues(alpha: 0.14),
                                foregroundColor: accent,
                                child: const Icon(Icons.school_outlined),
                              ),
                              trailing: useMenu
                                  ? PopupMenuButton<String>(
                                      tooltip: 'Lesson actions',
                                      onSelected: (value) {
                                        if (value == 'objectives') {
                                          _showLessonDetails(i);
                                        } else if (value == 'materials') {
                                          _openMaterials(l);
                                        } else {
                                          _showHomeworkToast();
                                        }
                                      },
                                      itemBuilder: (context) => const [
                                        PopupMenuItem<String>(
                                          value: 'objectives',
                                          child: Text('Objectives'),
                                        ),
                                        PopupMenuItem<String>(
                                          value: 'materials',
                                          child: Text('Materials'),
                                        ),
                                        PopupMenuItem<String>(
                                          value: 'homework',
                                          child: Text('Homework'),
                                        ),
                                      ],
                                    )
                                  : SizedBox(
                                      width: 126,
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          IconButton(
                                            tooltip: 'Objectives',
                                            onPressed: () =>
                                                _showLessonDetails(i),
                                            icon: const Icon(
                                              Icons.track_changes_outlined,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Open materials',
                                            onPressed: l.materialsUrl.isEmpty
                                                ? null
                                                : () => _openMaterials(l),
                                            icon: const Icon(
                                              Icons.folder_open_rounded,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Homework',
                                            onPressed: _showHomeworkToast,
                                            icon: const Icon(
                                              Icons.assignment_outlined,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _asListMap(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }
    if (raw is Map) {
      return raw.values
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  void _openMaterials(_SyllabusLesson lesson) {
    if (lesson.materialsUrl.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: lesson.lessonTitle,
          url: lesson.materialsUrl,
        ),
      ),
    );
  }

  void _showHomeworkToast() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Homework section coming soon.')),
    );
  }

  Future<void> _showLessonDetails(int initialIndex) async {
    if (_lessons.isEmpty) return;
    final pageController = PageController(initialPage: initialIndex);
    int page = initialIndex;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SizedBox(
              height: MediaQuery.of(context).size.height * 0.84,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Lesson Details',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy details',
                          onPressed: () {
                            final lesson = _lessons[page];
                            Clipboard.setData(
                              ClipboardData(text: _copyPayload(lesson)),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Lesson details copied.'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy_all_rounded),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text('Lesson ${page + 1} of ${_lessons.length}'),
                        const Spacer(),
                        Icon(
                          Icons.swipe_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        const Text('Swipe left/right'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: PageView.builder(
                      controller: pageController,
                      itemCount: _lessons.length,
                      onPageChanged: (value) {
                        setSheetState(() => page = value);
                      },
                      itemBuilder: (context, index) {
                        final lesson = _lessons[index];
                        final accent = _skillColor(lesson.skillType);
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.40),
                              ),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  accent.withValues(alpha: 0.14),
                                  Theme.of(
                                    context,
                                  ).colorScheme.surface.withValues(alpha: 0.94),
                                ],
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _detailBlock('Unit Title', lesson.unitTitle),
                                  _detailBlock(
                                    'Lesson Number (Session)',
                                    lesson.sessionLabel,
                                  ),
                                  _detailBlock(
                                    'Lesson Title',
                                    lesson.lessonTitle,
                                  ),
                                  _detailBlock(
                                    'Objective',
                                    lesson.objective.isEmpty
                                        ? 'No objective available yet.'
                                        : lesson.objective,
                                  ),
                                  if (lesson.content.isNotEmpty)
                                    _detailBlock('Content', lesson.content),
                                  if (lesson.homework.isNotEmpty)
                                    _detailBlock('Homework', lesson.homework),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _metaChip(
                                        context,
                                        accent,
                                        lesson.skillType.isEmpty
                                            ? 'Skill: not set'
                                            : 'Skill: ${lesson.skillType}',
                                      ),
                                      if (lesson.durationMinutes.isNotEmpty)
                                        _metaChip(
                                          context,
                                          accent,
                                          'Duration: ${lesson.durationMinutes} min',
                                        ),
                                      if (lesson.order.isNotEmpty)
                                        _metaChip(
                                          context,
                                          accent,
                                          'Order: ${lesson.order}',
                                        ),
                                      if (lesson.lessonId.isNotEmpty)
                                        _metaChip(
                                          context,
                                          accent,
                                          'ID: ${lesson.lessonId}',
                                        ),
                                      _metaChip(
                                        context,
                                        accent,
                                        lesson.materialsUrl.isEmpty
                                            ? 'Materials: not set'
                                            : 'Materials: available',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    pageController.dispose();
  }

  Widget _detailBlock(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(value),
        ],
      ),
    );
  }

  Widget _metaChip(BuildContext context, Color accent, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }

  String _copyPayload(_SyllabusLesson l) {
    final buffer = StringBuffer()
      ..writeln('Unit Title: ${l.unitTitle}')
      ..writeln('Lesson Number (Session): ${l.sessionLabel}')
      ..writeln('Lesson Title: ${l.lessonTitle}')
      ..writeln(
        'Objective: ${l.objective.isEmpty ? 'No objective available yet.' : l.objective}',
      );
    if (l.content.isNotEmpty) buffer.writeln('Content: ${l.content}');
    if (l.homework.isNotEmpty) buffer.writeln('Homework: ${l.homework}');
    if (l.skillType.isNotEmpty) buffer.writeln('Skill: ${l.skillType}');
    if (l.durationMinutes.isNotEmpty) {
      buffer.writeln('Duration (minutes): ${l.durationMinutes}');
    }
    if (l.order.isNotEmpty) buffer.writeln('Order: ${l.order}');
    if (l.lessonId.isNotEmpty) buffer.writeln('ID: ${l.lessonId}');
    if (l.materialsUrl.isNotEmpty) {
      buffer.writeln('Materials: ${l.materialsUrl}');
    }
    return buffer.toString().trim();
  }

  Color _skillColor(String rawSkill) {
    final v = rawSkill.toLowerCase();
    if (v.contains('listen')) return Colors.purple;
    if (v.contains('vocab')) return Colors.green;
    if (v.contains('grammar')) return Colors.red;
    if (v.contains('read')) return Colors.blue;
    if (v.contains('writ')) return Colors.deepOrange;
    if (v.contains('pronun')) return Colors.amber.shade700;
    return Theme.of(context).colorScheme.primary;
  }
}

class _SyllabusLesson {
  const _SyllabusLesson({
    required this.unitTitle,
    required this.unitObjective,
    required this.sessionLabel,
    required this.lessonTitle,
    required this.materialsUrl,
    required this.objective,
    required this.content,
    required this.durationMinutes,
    required this.homework,
    required this.skillType,
    required this.lessonId,
    required this.order,
  });
  final String unitTitle;
  final String unitObjective;
  final String sessionLabel;
  final String lessonTitle;
  final String materialsUrl;
  final String objective;
  final String content;
  final String durationMinutes;
  final String homework;
  final String skillType;
  final String lessonId;
  final String order;
}
