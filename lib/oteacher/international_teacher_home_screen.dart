import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/material_webview_screen.dart';
import 'international_teacher_profile_screen.dart';

class InternationalTeacherHomeScreen extends StatelessWidget {
  const InternationalTeacherHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please sign in again.')));
    }
    return _InternationalTeacherHomeBody(uid: user.uid);
  }
}

class _InternationalTeacherHomeBody extends StatefulWidget {
  const _InternationalTeacherHomeBody({required this.uid});
  final String uid;

  @override
  State<_InternationalTeacherHomeBody> createState() =>
      _InternationalTeacherHomeBodyState();
}

class _InternationalTeacherHomeBodyState
    extends State<_InternationalTeacherHomeBody> {
  final _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  String _name = 'International Teacher';
  String _photo = '';
  Map<String, dynamic> _subscription = <String, dynamic>{};
  List<Map<String, String>> _courses = <Map<String, String>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final uid = widget.uid;
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

  @override
  Widget build(BuildContext context) {
    final expiresOn = (_subscription['expiresOn'] ?? '').toString().trim();
    final amountUsd = (_subscription['amountPaidUsd'] ?? '').toString().trim();
    return Scaffold(
      appBar: AppBar(title: const Text('International Teacher')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundImage: _photo.isEmpty
                            ? null
                            : NetworkImage(_photo),
                        child: _photo.isEmpty ? const Icon(Icons.person) : null,
                      ),
                      title: Text(_name),
                      subtitle: Text(
                        _isExpired
                            ? 'Subscription expired on $expiresOn'
                            : (expiresOn.isEmpty
                                  ? 'Subscription date not set'
                                  : 'Subscription active until $expiresOn'),
                      ),
                      trailing: Text(
                        amountUsd.isEmpty ? 'USD -' : 'USD $amountUsd',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.manage_accounts_outlined),
                      title: const Text('Profile'),
                      subtitle: const Text(
                        'Photo, password, social links, subscription',
                      ),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => InternationalTeacherProfileScreen(
                              uid: widget.uid,
                            ),
                          ),
                        );
                        if (mounted) {
                          _load();
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Assigned Courses',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_courses.isEmpty)
                    const Card(
                      child: ListTile(title: Text('No assigned courses yet.')),
                    ),
                  for (final c in _courses)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.menu_book_outlined),
                        title: Text(
                          (c['title'] ?? '').isEmpty
                              ? 'Untitled course'
                              : c['title']!,
                        ),
                        subtitle: Text(
                          (c['code'] ?? '').isEmpty
                              ? 'Flexible syllabus'
                              : '${c['code']} • Flexible syllabus',
                        ),
                        trailing: FilledButton(
                          onPressed: _isExpired
                              ? null
                              : () {
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
                          child: const Text('Start'),
                        ),
                      ),
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
