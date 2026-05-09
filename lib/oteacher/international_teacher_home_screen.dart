import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/topic_service.dart';
import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/material_webview_screen.dart';
import '../shared/session_manager.dart';
import '../shared/shared_pdf_reader_screen.dart';
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
    final uid = _uid;

    await AppLoading.run(
      context,
      () async {
        await SessionManager.stopListening();
      },
      message: 'Logging out...',
      isLogout: true,
    );

    await FirebaseAuth.instance.signOut();

    unawaited(() async {
      try {
        await FirebaseMessaging.instance.deleteToken();
      } catch (_) {}

      if (uid.isNotEmpty) {
        try {
          await TopicService.clearForUser(uid);
        } catch (_) {}

        try {
          await FirebaseDatabase.instance.ref('fcm_tokens/$uid').remove();
        } catch (_) {}
      }

      try {
        await appThemeController.resetToDefault();
      } catch (_) {}
    }());
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
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        title: Text(
          _name.trim().isEmpty ? 'International Teacher' : _name.trim(),
        ),
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
                color: palette.primary,
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
  String _courseBookUrl = '';
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
        final courseBookMap = _asMapAny(m['courseBook']);
        _courseBookUrl = (courseBookMap['url'] ?? '').toString().trim();
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
      } else {
        _courseBookUrl = '';
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
            onPressed: _openCourseBook,
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
                      return TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: Duration(milliseconds: 220 + (i * 18)),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, child) {
                          return Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(0, (1 - value) * 10),
                              child: child,
                            ),
                          );
                        },
                        child: Container(
                          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: _skillCardGradient(accent),
                            ),
                            border: Border.all(color: accent, width: 1.25),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.16),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            title: Text(
                              l.lessonTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '${l.unitTitle} • ${l.sessionLabel}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.black.withValues(alpha: 0.72),
                                ),
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _actionIconButton(
                                  tooltip: 'Objectives',
                                  icon: Icons.track_changes_outlined,
                                  accent: accent,
                                  onPressed: () => _showLessonDetails(i),
                                ),
                                _actionIconButton(
                                  tooltip: 'Open materials',
                                  icon: Icons.folder_open_rounded,
                                  accent: accent,
                                  onPressed: l.materialsUrl.isEmpty
                                      ? null
                                      : () => _openMaterials(l),
                                ),
                                _actionIconButton(
                                  tooltip: 'Homework',
                                  icon: Icons.assignment_outlined,
                                  accent: accent,
                                  onPressed: _showHomeworkToast,
                                ),
                              ],
                            ),
                          ),
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

  Map<String, dynamic> _asMapAny(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return const <String, dynamic>{};
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

  void _openCourseBook() {
    final url = _courseBookUrl.trim();
    final uri = Uri.tryParse(url);
    final isHttp =
        uri != null &&
        uri.hasAbsolutePath &&
        (uri.scheme == 'http' || uri.scheme == 'https');
    if (!isHttp) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Course book is not available yet.')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SharedPdfReaderScreen(title: 'Course Book', pdfUrl: url),
      ),
    );
  }

  Future<void> _showLessonDetails(int initialIndex) async {
    if (_lessons.isEmpty) return;
    final pageController = PageController(initialPage: initialIndex);
    int page = initialIndex;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            10,
            0,
            10,
            10 + MediaQuery.of(ctx).padding.bottom,
          ),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              return TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 230),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) {
                  return Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, (1 - value) * 20),
                      child: child,
                    ),
                  );
                },
                child: FractionallySizedBox(
                  heightFactor: 0.74,
                  child: Material(
                    elevation: 28,
                    borderRadius: BorderRadius.circular(24),
                    clipBehavior: Clip.antiAlias,
                    color: Theme.of(context).colorScheme.surface,
                    child: Column(
                      children: [
                        const SizedBox(height: 10),
                        Container(
                          width: 56,
                          height: 6,
                          decoration: BoxDecoration(
                            color: const Color(0xFF6B7280),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
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
                              final accent = _skillColor(
                                '${lesson.skillType} ${lesson.lessonTitle}',
                              );
                              return SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  16,
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: accent,
                                      width: 1.25,
                                    ),
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: _skillCardGradient(accent),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: accent.withValues(alpha: 0.14),
                                        blurRadius: 14,
                                        offset: const Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _detailBlock(
                                          'Unit Title',
                                          lesson.unitTitle,
                                        ),
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
                                          _detailBlock(
                                            'Content',
                                            lesson.content,
                                          ),
                                        if (lesson.homework.isNotEmpty)
                                          _detailBlock(
                                            'Homework',
                                            lesson.homework,
                                          ),
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
                                            if (lesson
                                                .durationMinutes
                                                .isNotEmpty)
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
                  ),
                ),
              );
            },
          ),
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
        color: accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _actionIconButton({
    required String tooltip,
    required IconData icon,
    required Color accent,
    required VoidCallback? onPressed,
  }) {
    return _PremiumActionButton(
      tooltip: tooltip,
      icon: icon,
      accent: accent,
      onPressed: onPressed,
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
    if (v.contains('listen') || v.contains('speak')) {
      return const Color(0xFF7E22CE);
    }
    if (v.contains('vocab')) return const Color(0xFF16A34A);
    if (v.contains('read')) return const Color(0xFF2563EB);
    if (v.contains('grammar')) return const Color(0xFFDC2626);
    if (v.contains('writ')) return const Color(0xFFEA580C);
    if (v.contains('pronun')) return const Color(0xFFB45309);
    return Theme.of(context).colorScheme.primary;
  }

  Color _skillSurface(Color accent) {
    if (accent == const Color(0xFF16A34A)) return const Color(0xFFDFF4E6);
    if (accent == const Color(0xFF7E22CE)) return const Color(0xFFEEDFFD);
    if (accent == const Color(0xFFDC2626)) return const Color(0xFFFDE2E2);
    if (accent == const Color(0xFF2563EB)) return const Color(0xFFE0EAFF);
    if (accent == const Color(0xFFEA580C)) return const Color(0xFFFFE7D6);
    return const Color(0xFFFFF4CC);
  }

  List<Color> _skillCardGradient(Color accent) {
    return [_skillSurface(accent), Colors.white];
  }
}

class _PremiumActionButton extends StatefulWidget {
  const _PremiumActionButton({
    required this.tooltip,
    required this.icon,
    required this.accent,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color accent;
  final VoidCallback? onPressed;

  @override
  State<_PremiumActionButton> createState() => _PremiumActionButtonState();
}

class _PremiumActionButtonState extends State<_PremiumActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
          onTapCancel: disabled ? null : () => setState(() => _pressed = false),
          onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOut,
            scale: _pressed ? 0.92 : 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: disabled
                    ? Colors.grey.withValues(alpha: 0.14)
                    : widget.accent.withValues(alpha: _pressed ? 0.22 : 0.14),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 20,
                color: disabled ? Colors.grey : widget.accent,
              ),
            ),
          ),
        ),
      ),
    );
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
