import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

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
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

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

  @override
  void initState() {
    super.initState();
    _load();
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

  Widget _readonlyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                color: mainText.withOpacity(0.7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: const TextStyle(
                color: mainText,
                fontWeight: FontWeight.w900,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallStatTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
        color: primaryBlue.withOpacity(0.04),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: actionOrange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: mainText.withOpacity(0.72),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: mainText,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainProfileCard() {
    final first = _safeStr(_user['first_name']);
    final last = _safeStr(_user['last_name']);
    final fullName = ('$first $last').trim();

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: uiBorder.withOpacity(0.9), width: 2),
                color: primaryBlue.withOpacity(0.06),
              ),
              clipBehavior: Clip.antiAlias,
              child: (_profilePhotoUrl ?? '').isNotEmpty
                  ? Image.network(
                _profilePhotoUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.person_rounded,
                  size: 54,
                  color: primaryBlue.withOpacity(0.8),
                ),
              )
                  : Icon(
                Icons.person_rounded,
                size: 54,
                color: primaryBlue.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              fullName.isEmpty ? widget.learnerName : fullName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _safeStr(_user['role']).isEmpty ? 'Learner' : _safeStr(_user['role']),
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtraPhotosCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Extra Photos',
              style: TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            if (_photoUrls.isEmpty)
              Text(
                'No extra photos yet.',
                style: TextStyle(
                  color: Colors.grey.shade700,
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
                        color: Colors.grey.shade200,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Learning Summary',
              style: TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            _smallStatTile(
              icon: Icons.school_rounded,
              label: 'Courses',
              value: '$_statCourses',
            ),
            const SizedBox(height: 10),
            _smallStatTile(
              icon: Icons.how_to_reg_rounded,
              label: 'Attendance',
              value: '$_statAttendancePct%',
            ),
            const SizedBox(height: 10),
            _smallStatTile(
              icon: Icons.menu_book_rounded,
              label: 'Lessons Covered',
              value: '$_statLessonsCovered',
            ),
            const SizedBox(height: 10),
            _smallStatTile(
              icon: Icons.assignment_late_rounded,
              label: 'Homework Pending',
              value: '$_statHomeworkPending',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutMeCard() {
    final aboutMe = _safeStr(_user['about_me']);

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'About Me',
              style: TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              aboutMe.isEmpty ? 'No about me yet.' : aboutMe,
              style: const TextStyle(
                color: mainText,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountCard() {
    final email = _safeStr(_user['email']);
    final serial = _safeStr(_user['serial']);
    final role = _safeStr(_user['role']);
    final status = _safeStr(_user['status']);
    final phone1 = _safeStr(_user['phone1']);
    final phone2 = _safeStr(_user['phone2']);
    final dob = _safeStr(_user['dob']);

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Profile Info',
              style: TextStyle(
                color: primaryBlue,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            _readonlyRow('Email', email),
            _readonlyRow('Serial', serial),
            _readonlyRow('Role', role),
            _readonlyRow('Status', status),
            _readonlyRow('Phone 1', phone1),
            _readonlyRow('Phone 2', phone2),
            _readonlyRow('DOB', dob),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: Text(
          widget.learnerName.isEmpty ? 'Learner Profile' : widget.learnerName,
          style: const TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      )
          : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildMainProfileCard(),
          const SizedBox(height: 14),
          _buildExtraPhotosCard(),
          const SizedBox(height: 14),
          _buildSummaryCard(),
          const SizedBox(height: 14),
          _buildAboutMeCard(),
          const SizedBox(height: 14),
          _buildAccountCard(),
        ],
      ),
    );
  }
}