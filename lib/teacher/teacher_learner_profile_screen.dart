import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';

class TeacherLearnerProfileScreen extends StatefulWidget {
  const TeacherLearnerProfileScreen({
    super.key,
    required this.learnerUid,
    required this.learnerName,
  });

  final String learnerUid;
  final String learnerName;

  @override
  State<TeacherLearnerProfileScreen> createState() =>
      _TeacherLearnerProfileScreenState();
}

class _TeacherLearnerProfileScreenState
    extends State<TeacherLearnerProfileScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _busy = true;
  String? _error;
  Map<String, dynamic> _user = {};
  List<String> _photoUrls = [];
  String? _profilePhotoUrl;

  int _statCourses = 0;
  int _statAttendancePct = 0;
  int _statLessonsCovered = 0;
  int _statHomeworkPending = 0;

  AppPalette get palette => appThemeController.palette;

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

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _safeStr(dynamic v) => (v ?? '').toString().trim();

  Future<Map<int, String>> _loadSessionIdByNumber({
    required String courseId,
    required String variantKey,
  }) async {
    final out = <int, String>{};
    if (courseId.trim().isEmpty) return out;

    try {
      DatabaseReference syllabusRef = _db.child('syllabi/$courseId');
      if (variantKey.trim().isNotEmpty) {
        syllabusRef = syllabusRef.child(variantKey.trim().toLowerCase());
      }

      final snap = await syllabusRef.get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return out;

      final data = Map<String, dynamic>.from(snap.value as Map);
      final units = data['units'];

      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final unit = Map<String, dynamic>.from(u);
          final sessions = unit['sessions'];

          if (sessions is List) {
            for (final ss in sessions) {
              if (ss is! Map) continue;
              final sess = Map<String, dynamic>.from(ss);
              final sn = _toInt(sess['sessionNumber']);
              final sid = _safeStr(sess['id']);
              if (sn > 0 && sid.isNotEmpty) {
                out[sn] = sid;
              }
            }
          }
        }
      }
    } catch (_) {}

    return out;
  }

  Future<Set<String>> _coveredSessionIdsFromCourse({
    required String learnerUid,
    required Map<String, dynamic> course,
  }) async {
    final covered = <String>{};

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    final courseId = _safeStr(cls['course_id'] ?? course['id']);
    final variantKey =
    _safeStr(course['variantKey'] ?? course['variant']).toLowerCase();

    final sessionIdByNumber = await _loadSessionIdByNumber(
      courseId: courseId,
      variantKey: variantKey,
    );

    final attendance = course['attendance'];
    if (attendance is Map) {
      final attMap = Map<String, dynamic>.from(attendance);

      for (final entry in attMap.entries) {
        final rec = entry.value;
        if (rec is! Map) continue;

        final m = Map<String, dynamic>.from(rec);
        final taughtItems = m['taughtItems'];
        bool usedNew = false;

        if (taughtItems is List) {
          usedNew = true;
          for (final it in taughtItems) {
            if (it is! Map) continue;
            final item = Map<String, dynamic>.from(it);
            final type = _safeStr(item['type']).toLowerCase();
            if (type != 'syllabus') continue;

            final sid = _safeStr(item['sessionId']);
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(item['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }

        if (!usedNew) {
          final taught = m['taught'];
          if (taught is Map) {
            final tm = Map<String, dynamic>.from(taught);
            final sid = _safeStr(tm['sessionId']);
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(tm['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }
      }
    }

    if (learnerUid.isNotEmpty && courseId.isNotEmpty) {
      try {
        final snap = await _db
            .child('booking_progress/$learnerUid/$courseId/online_attendance')
            .get();

        if (snap.exists && snap.value is Map) {
          final om = Map<dynamic, dynamic>.from(snap.value as Map);

          for (final e in om.entries) {
            final rec = e.value;
            if (rec is! Map) continue;
            final r = Map<String, dynamic>.from(rec);

            final taughtItems = r['taughtItems'];
            if (taughtItems is List) {
              for (final it in taughtItems) {
                if (it is! Map) continue;
                final item = Map<String, dynamic>.from(it);

                final type = _safeStr(item['type']).toLowerCase();
                if (type != 'syllabus') continue;

                final sid = _safeStr(item['sessionId']);
                if (sid.isNotEmpty) {
                  covered.add(sid);
                  continue;
                }

                final sn = _toInt(item['sessionNumber']);
                if (sn > 0) {
                  final mapped = sessionIdByNumber[sn];
                  if (mapped != null && mapped.isNotEmpty) {
                    covered.add(mapped);
                  }
                }
              }
            } else {
              final sn = _toInt(r['sessionNo']);
              if (sn > 0) {
                final mapped = sessionIdByNumber[sn];
                if (mapped != null && mapped.isNotEmpty) {
                  covered.add(mapped);
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    return covered;
  }

  Future<void> _loadSmallStats() async {
    _statCourses = 0;
    _statAttendancePct = 0;
    _statLessonsCovered = 0;
    _statHomeworkPending = 0;

    try {
      final snap = await _db.child('users/${widget.learnerUid}/courses').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

      final courses = Map<dynamic, dynamic>.from(snap.value as Map);

      int totalAttendance = 0;
      int totalPresent = 0;
      int totalLessonsCovered = 0;
      int homeworkPending = 0;

      for (final entry in courses.entries) {
        final courseVal = entry.value;
        if (courseVal is! Map) continue;

        final course = Map<String, dynamic>.from(courseVal);
        _statCourses += 1;

        final attendance = course['attendance'];
        if (attendance is Map) {
          final attMap = Map<dynamic, dynamic>.from(attendance);

          for (final v in attMap.values) {
            if (v is! Map) continue;
            final rec = Map<String, dynamic>.from(v);

            totalAttendance += 1;
            final status = _safeStr(rec['status']).toLowerCase();
            if (status == 'present') {
              totalPresent += 1;
            }

            final hwAny = rec['homework'];
            if (hwAny is Map) {
              final hw = Map<String, dynamic>.from(hwAny);
              final text = _safeStr(hw['text']);
              final due = _safeStr(hw['dueDate']);
              final doneAt = hw['doneAt'];
              final hasHomework = text.isNotEmpty || due.isNotEmpty;
              final isDone = doneAt != null;

              if (hasHomework && !isDone) {
                homeworkPending += 1;
              }
            }
          }
        }

        final cls = (course['class'] is Map)
            ? Map<String, dynamic>.from(course['class'] as Map)
            : <String, dynamic>{};

        final courseId = _safeStr(cls['course_id'] ?? course['id']);
        if (courseId.isNotEmpty) {
          try {
            final onlineSnap = await _db
                .child('booking_progress/${widget.learnerUid}/$courseId/online_attendance')
                .get();

            if (onlineSnap.exists && onlineSnap.value is Map) {
              final om = Map<dynamic, dynamic>.from(onlineSnap.value as Map);
              for (final item in om.values) {
                if (item is! Map) continue;
                final rec = Map<String, dynamic>.from(item);

                totalAttendance += 1;
                final present = rec['present'] == true;
                if (present) totalPresent += 1;
              }
            }
          } catch (_) {}
        }

        final coveredSet = await _coveredSessionIdsFromCourse(
          learnerUid: widget.learnerUid,
          course: course,
        );
        totalLessonsCovered += coveredSet.length;
      }

      _statLessonsCovered = totalLessonsCovered;
      _statHomeworkPending = homeworkPending;
      _statAttendancePct =
      totalAttendance == 0 ? 0 : ((totalPresent / totalAttendance) * 100).round();
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _user = {};
      _photoUrls = [];
      _profilePhotoUrl = null;
    });

    try {
      final snap = await _db.child('users/${widget.learnerUid}').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        throw Exception('Learner profile not found.');
      }

      _user = Map<String, dynamic>.from(snap.value as Map);

      _profilePhotoUrl = _safeStr(_user['profile_photo']);
      if (_profilePhotoUrl != null && _profilePhotoUrl!.isEmpty) {
        _profilePhotoUrl = null;
      }

      _photoUrls.clear();
      final rawPhotos = _user['profile_photos'];
      if (rawPhotos is List) {
        for (final item in rawPhotos) {
          final url = _safeStr(item);
          if (url.isNotEmpty) _photoUrls.add(url);
        }
      } else if (rawPhotos is Map) {
        final map = Map<String, dynamic>.from(rawPhotos);
        final sortedKeys = map.keys.toList()..sort();
        for (final k in sortedKeys) {
          final url = _safeStr(map[k]);
          if (url.isNotEmpty) _photoUrls.add(url);
        }
      }

      await _loadSmallStats();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Color _attendanceColor(int pct) {
    if (pct >= 80) return const Color(0xFF10B981);
    if (pct >= 50) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  String _attendanceLabel(int pct) {
    if (pct >= 90) return 'Excellent';
    if (pct >= 80) return 'Strong';
    if (pct >= 60) return 'Fair';
    return 'Needs Support';
  }

  String _displayName() {
    final first = _safeStr(_user['first_name']);
    final last = _safeStr(_user['last_name']);
    final fullName = ('$first $last').trim();
    if (fullName.isNotEmpty) return fullName;
    if (widget.learnerName.trim().isNotEmpty) return widget.learnerName.trim();
    return 'Learner';
  }

  Widget _readonlyRow(AppPalette p, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(
                color: p.text.withOpacity(0.7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: TextStyle(
                color: p.text,
                fontWeight: FontWeight.w900,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallStatTile(
      AppPalette p, {
        required IconData icon,
        required String label,
        required String value,
        Color? tint,
      }) {
    final color = tint ?? p.accent;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withOpacity(0.85)),
        color: p.primary.withOpacity(0.04),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: p.text.withOpacity(0.72),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: p.text,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainProfileCard(AppPalette p) {
    final fullName = _displayName();
    final role = _safeStr(_user['role']).isEmpty ? 'Learner' : _safeStr(_user['role']);
    final serial = _safeStr(_user['serial']);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            p.primary,
            p.primary.withOpacity(0.88),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: p.primary.withOpacity(0.16),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 2),
              color: Colors.white.withOpacity(0.10),
            ),
            clipBehavior: Clip.antiAlias,
            child: (_profilePhotoUrl ?? '').isNotEmpty
                ? Image.network(
              _profilePhotoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.person_rounded,
                size: 56,
                color: Colors.white,
              ),
            )
                : const Icon(
              Icons.person_rounded,
              size: 56,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            fullName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            role,
            style: TextStyle(
              color: Colors.white.withOpacity(0.84),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _heroChip(
                text: serial.isEmpty ? 'No serial' : 'ID: $serial',
                icon: Icons.badge_rounded,
              ),
              _heroChip(
                text: 'Attendance $_statAttendancePct%',
                icon: Icons.how_to_reg_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroChip({
    required String text,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExtraPhotosCard(AppPalette p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Extra Photos',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          if (_photoUrls.isEmpty)
            Text(
              'No extra photos yet.',
              style: TextStyle(
                color: p.text.withOpacity(0.7),
                fontWeight: FontWeight.w700,
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _photoUrls.map((url) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    url,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 96,
                      height: 96,
                      color: p.soft,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: p.primary.withOpacity(0.55),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(AppPalette p) {
    final attendanceColor = _attendanceColor(_statAttendancePct);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Learning Summary',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.primary.withOpacity(0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.border.withOpacity(0.85)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Attendance Health',
                  style: TextStyle(
                    color: p.text.withOpacity(0.7),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      '$_statAttendancePct%',
                      style: TextStyle(
                        color: attendanceColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _attendanceLabel(_statAttendancePct),
                      style: TextStyle(
                        color: attendanceColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: (_statAttendancePct / 100).clamp(0, 1),
                    minHeight: 10,
                    backgroundColor: attendanceColor.withOpacity(0.12),
                    valueColor: AlwaysStoppedAnimation(attendanceColor),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            p,
            icon: Icons.school_rounded,
            label: 'Courses',
            value: '$_statCourses',
            tint: p.accent,
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            p,
            icon: Icons.menu_book_rounded,
            label: 'Lessons Covered',
            value: '$_statLessonsCovered',
            tint: p.primary,
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            p,
            icon: Icons.assignment_late_rounded,
            label: 'Homework Pending',
            value: '$_statHomeworkPending',
            tint: _statHomeworkPending > 0 ? const Color(0xFFEF4444) : p.accent,
          ),
        ],
      ),
    );
  }

  Widget _buildAboutMeCard(AppPalette p) {
    final aboutMe = _safeStr(_user['about_me']);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'About Me',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            aboutMe.isEmpty ? 'No about me yet.' : aboutMe,
            style: TextStyle(
              color: p.text,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(AppPalette p) {
    final email = _safeStr(_user['email']);
    final serial = _safeStr(_user['serial']);
    final role = _safeStr(_user['role']);
    final status = _safeStr(_user['status']);
    final phone1 = _safeStr(_user['phone1']);
    final phone2 = _safeStr(_user['phone2']);
    final dob = _safeStr(_user['dob']);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withOpacity(0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Profile Info',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          _readonlyRow(p, 'Email', email),
          _readonlyRow(p, 'Serial', serial),
          _readonlyRow(p, 'Role', role),
          _readonlyRow(p, 'Status', status),
          _readonlyRow(p, 'Phone 1', phone1),
          _readonlyRow(p, 'Phone 2', phone2),
          _readonlyRow(p, 'DOB', dob),
        ],
      ),
    );
  }

  Widget _buildErrorState(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 56,
                color: Color(0xFFEF4444),
              ),
              const SizedBox(height: 12),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFEF4444),
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final title = widget.learnerName.isEmpty ? 'Learner Profile' : widget.learnerName;

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Text(
          title,
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _busy
          ? Center(child: CircularProgressIndicator(color: p.primary))
          : _error != null
          ? _buildErrorState(p)
          : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildMainProfileCard(p),
          const SizedBox(height: 14),
          _buildExtraPhotosCard(p),
          const SizedBox(height: 14),
          _buildSummaryCard(p),
          const SizedBox(height: 14),
          _buildAboutMeCard(p),
          const SizedBox(height: 14),
          _buildAccountCard(p),
        ],
      ),
    );
  }
}