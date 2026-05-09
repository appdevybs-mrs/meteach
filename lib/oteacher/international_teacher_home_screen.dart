import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/topic_service.dart';
import '../shared/app_theme.dart';
import '../shared/material_webview_screen.dart';
import '../teacher/teacher_games_screen.dart';
import '../teacher/teacher_stories_screen.dart';
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
      ]);

      final userMap = _asMap(snaps[0].value);
      final first = (userMap['first_name'] ?? '').toString().trim();
      final last = (userMap['last_name'] ?? '').toString().trim();
      _name = [first, last].where((e) => e.isNotEmpty).join(' ').trim();
      if (_name.isEmpty) _name = 'International Teacher';
      _photo = (userMap['profile_photo'] ?? '').toString().trim();

      _subscription = _asMap(snaps[2].value);

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
    if (uid.isNotEmpty) {
      await TopicService.clearForUser(uid);
    }
    await FirebaseAuth.instance.signOut();
  }

  Future<void> _openThemePicker() async {
    final modes = AppThemeMode.values;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return ListView(
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
                leading: Icon(
                  appThemeController.mode == m
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(appThemeController.themeTitle(m)),
                subtitle: Text(appThemeController.themeSubtitle(m)),
                onTap: () async {
                  await appThemeController.setTheme(m);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
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
      backgroundColor: const Color(0xFFF2F5F9),
      drawer: _OTeacherDrawer(
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
            MaterialPageRoute(builder: (_) => const TeacherStoriesScreen()),
          );
        },
        onOpenGames: () {
          Navigator.of(context).pop();
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const TeacherGamesScreen()));
        },
        onOpenSubscription: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _SubscriptionScreen(subscription: _subscription),
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0D2B45), Color(0xFF224D6E)],
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
                        color: const Color(0xFFFFF3E8),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFF0B78B)),
                      ),
                      child: const Text(
                        'Your subscription has expired. Course start is locked until renewal.',
                        style: TextStyle(
                          color: Color(0xFF7A3E12),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Assigned Courses',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  const SizedBox(height: 10),
                  if (_courses.isEmpty)
                    const Card(
                      child: ListTile(
                        title: Text('No assigned courses yet.'),
                        subtitle: Text('Ask admin to assign your courses.'),
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
            ),
    );
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }
}

class _CourseSquareCard extends StatelessWidget {
  const _CourseSquareCard({
    required this.title,
    required this.code,
    required this.imageUrl,
    required this.locked,
    required this.onStart,
  });

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
        color: Colors.white,
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
                      color: const Color(0xFFE9EEF5),
                      child: const Icon(Icons.image_outlined, size: 36),
                    )
                  : Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: const Color(0xFFE9EEF5),
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
                        backgroundColor: const Color(0xFFBF6A3D),
                        disabledBackgroundColor: const Color(0xFF8B8B8B),
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
    required this.name,
    required this.photoUrl,
    required this.onOpenProfile,
    required this.onOpenStories,
    required this.onOpenGames,
    required this.onOpenSubscription,
    required this.onOpenTheme,
    required this.onLogout,
  });

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
      backgroundColor: const Color(0xFFF6F8FB),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  colors: [Color(0xFF0D2B45), Color(0xFF224D6E)],
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
                    backgroundColor: const Color(0xFFBF6A3D),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: Icon(icon, color: const Color(0xFF0D2B45)),
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
  const _SubscriptionScreen({required this.subscription});
  final Map<String, dynamic> subscription;

  @override
  Widget build(BuildContext context) {
    final amount = (subscription['amountPaidUsd'] ?? '').toString();
    final expiresOn = (subscription['expiresOn'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: const Text('Subscription')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: ListTile(
              title: const Text('Amount paid'),
              subtitle: Text('USD ${amount.isEmpty ? '-' : amount}'),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Expires on'),
              subtitle: Text(expiresOn.isEmpty ? 'Not set' : expiresOn),
            ),
          ),
        ],
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
          final sessions = _asListMap(u['sessions']).isNotEmpty
              ? _asListMap(u['sessions'])
              : _asListMap(u['lessons']);
          for (int j = 0; j < sessions.length; j++) {
            final s = sessions[j];
            final title = (s['title'] ?? s['name'] ?? 'Lesson ${j + 1}')
                .toString()
                .trim();
            final materialsUrl = (s['materialsUrl'] ?? '').toString().trim();
            out.add(
              _SyllabusLesson(
                unitTitle: unitTitle,
                lessonTitle: title,
                materialsUrl: materialsUrl,
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.courseTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _lessons.isEmpty
          ? const Center(child: Text('No flexible syllabus found.'))
          : ListView.builder(
              itemCount: _lessons.length,
              itemBuilder: (context, i) {
                final l = _lessons[i];
                return Card(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: ListTile(
                    title: Text(l.lessonTitle),
                    subtitle: Text(l.unitTitle),
                    trailing: OutlinedButton(
                      onPressed: l.materialsUrl.isEmpty
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MaterialWebViewScreen.fromUrl(
                                    title: l.lessonTitle,
                                    url: l.materialsUrl,
                                  ),
                                ),
                              );
                            },
                      child: const Text('Open Materials'),
                    ),
                  ),
                );
              },
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
}

class _SyllabusLesson {
  const _SyllabusLesson({
    required this.unitTitle,
    required this.lessonTitle,
    required this.materialsUrl,
  });
  final String unitTitle;
  final String lessonTitle;
  final String materialsUrl;
}
