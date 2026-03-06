// ✅ FULL REPLACEMENT (SAFE): lib/teacher/teacher_classes_screen.dart
//
// ✅ In-class tab: unchanged behavior (your existing screens still used)
// ✅ Online tab: bookings + attendance ONLY (Present / Absent)
// ✅ Online UI shows learner NAMES (no UID shown anywhere)
// ✅ Online attendance saved in TWO places (safe):
//    A) online_attendance/<bookingKey>
//    B) booking_progress/<learnerUid>/<courseId>/online_attendance/<bookingKey>   ✅ inside learner uid inside course
//
// NOTE: This file does NOT change your in-class DB writes.
// ------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:url_launcher/url_launcher.dart';

// ✅ your existing in-class screens (keep)
import 'take_attendance_screen.dart';
import 'attendance_history_screen.dart';
import 'attendance_stats_screen.dart';
import 'teacher_class_progress_screen.dart';

class TeacherClassesScreen extends StatefulWidget {
  const TeacherClassesScreen({super.key});

  @override
  State<TeacherClassesScreen> createState() => _TeacherClassesScreenState();
}

class _TeacherClassesScreenState extends State<TeacherClassesScreen>
    with TickerProviderStateMixin {
  // ===== UI colors (your same style) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  // ===== DB nodes (in-class) =====
  static const String usersNode = "users";
  static const String classesNode = "classes";
  static const String syllabiNode = "syllabi";

  // ===== DB nodes (online bookings) =====
  static const String bookingReservationsNode = "booking_reservations";
  static const String bookingAvailabilityNode = "booking_availability";

  // Online attendance storage (NEW, safe)
  static const String onlineAttendanceNode = "online_attendance";

  // Learner course node (same base you use in learner booking screen)
  // booking_progress/<learnerUid>/<courseId>/...
  static const String bookingProgressNode = "booking_progress";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  bool _busy = true;
  String? _error;

  String _teacherUid = '';
  String _teacherSerial = '';
  String _teacherName = '';

  // In-class
  List<Map<String, dynamic>> _myClasses = [];
  final Map<String, _ClassProg> _classProgCache = {};

  // Online
  bool _onlineBusy = true;
  String? _onlineError;
  List<_OnlineBooking> _onlineAll = [];

  // Cache user names: uid -> {full}
  final Map<String, Map<String, String>> _nameCache = {};
  final Map<String, String> _sessionTitleCache = {}; // courseId|sessionNo -> title
  final Map<String, String> _courseTitleCache = {}; // courseId -> course title
  late TabController _tab;
  late TabController _onlineTab;
  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _onlineTab = TabController(length: 3, vsync: this);
    _loadAll();
  }

  @override
  void dispose() {
    _tab.dispose();
    _onlineTab.dispose();
    super.dispose();
  }

  // ===================== helpers =====================

  void _toast(String msg) {
    if (!mounted) return;
    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
  }

  String _norm(String s) => s.trim().toLowerCase();

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _safeStr(dynamic v) => (v ?? '').toString().trim();

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  DateTime? _parseSlotStart(String dayKey, String hhmm) {
    try {
      final dp = dayKey.split('-');
      if (dp.length != 3) return null;
      final y = int.tryParse(dp[0]);
      final m = int.tryParse(dp[1]);
      final d = int.tryParse(dp[2]);
      if (y == null || m == null || d == null) return null;

      final tp = hhmm.split(':');
      if (tp.length != 2) return null;
      final hh = int.tryParse(tp[0]);
      final mm = int.tryParse(tp[1]);
      if (hh == null || mm == null) return null;

      return DateTime(y, m, d, hh, mm);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openExternalUrl(String url) async {
    var u = url.trim();
    if (u.isEmpty) {
      _toast('Missing meeting link.');
      return;
    }

    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }

    final uri = Uri.tryParse(u);
    if (uri == null) {
      _toast('Invalid meeting link.');
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _toast('Could not open the link.');
  }


  Future<Map<String, String>> _loadUserName(String uid) async {
    if (uid.isEmpty) return {'full': ''};
    if (_nameCache.containsKey(uid)) return _nameCache[uid]!;
    try {
      final snap = await _usersRef.child(uid).get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final fn = _safeStr(m['first_name']);
        final ln = _safeStr(m['last_name']);
        final full = ('$fn $ln').trim();
        final out = {'full': full};
        _nameCache[uid] = out;
        return out;
      }
    } catch (_) {}
    final out = {'full': ''};
    _nameCache[uid] = out;
    return out;
  }

  // ===================== load all =====================

  Future<void> _loadAll() async {
    await _loadTeacherProfile();
    await Future.wait([
      _loadMyClasses(),
      _loadMyOnlineBookings(),
    ]);
  }

  Future<void> _loadTeacherProfile() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');

      _teacherUid = user.uid;

      final userSnap = await _usersRef.child(_teacherUid).get();
      if (!userSnap.exists) throw Exception('Teacher record not found in /users/<uid>.');

      final u = (userSnap.value is Map)
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};

      _teacherSerial = _safeStr(u['serial']);
      final fn = _safeStr(u['first_name']);
      final ln = _safeStr(u['last_name']);
      _teacherName = ('$fn $ln').trim();

      if (!_isTeacherRole(u['role'])) {
        throw Exception('Your account role is not "teacher". Found: "${u['role']}"');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _onlineError = e.toString();
      });
    }
  }

  // ===================== IN-CLASS tab (your existing behavior) =====================

  Future<void> _loadMyClasses() async {
    setState(() {
      _busy = true;
      _error = null;
      _myClasses = [];
      _classProgCache.clear();
    });

    try {
      if (_teacherUid.isEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) throw Exception('Not logged in.');
        _teacherUid = user.uid;
      }

      final classesSnap = await _classesRef.get();
      if (!classesSnap.exists || classesSnap.value == null) {
        setState(() {
          _myClasses = [];
          _busy = false;
        });
        return;
      }

      final raw = (classesSnap.value is Map)
          ? Map<dynamic, dynamic>.from(classesSnap.value as Map)
          : <dynamic, dynamic>{};

      final List<Map<String, dynamic>> mine = [];

      raw.forEach((key, value) {
        final c = (value is Map)
            ? Map<String, dynamic>.from(value as Map)
            : <String, dynamic>{};

        String curUid = '';
        String curName = '';

        final cur = c['instructor_current'];
        if (cur is Map) {
          final curMap = Map<String, dynamic>.from(cur);
          curUid = _safeStr(curMap['uid']);
          curName = _safeStr(curMap['name']);
        }

        final legacyInstructorName = _safeStr(c['instructor']);

        final matchesUid = curUid.isNotEmpty && curUid == _teacherUid;

        final matchesName = _teacherName.isNotEmpty &&
            _norm(legacyInstructorName.isNotEmpty ? legacyInstructorName : curName) ==
                _norm(_teacherName);

        final legacySerial = _safeStr(c['instructorserial'] ?? c['serial']);
        final matchesSerial = _teacherSerial.isNotEmpty && legacySerial == _teacherSerial;

        if (matchesUid || matchesName || matchesSerial) {
          mine.add({
            'id': key.toString(),
            ...c.map((k, v) => MapEntry(k.toString(), v)),
          });
        }
      });

      mine.sort((a, b) {
        int numVal(dynamic v) {
          if (v is num) return v.toInt();
          return int.tryParse(v?.toString() ?? '') ?? 0;
        }

        final aU = numVal(a['updated_at'] ?? a['updatedAt'] ?? 0);
        final bU = numVal(b['updated_at'] ?? b['updatedAt'] ?? 0);
        if (aU != bU) return bU.compareTo(aU);

        final aC = numVal(a['created_at'] ?? a['createdAt'] ?? 0);
        final bC = numVal(b['created_at'] ?? b['createdAt'] ?? 0);
        return bC.compareTo(aC);
      });

      setState(() {
        _myClasses = mine;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  int _learnersCount(Map<String, dynamic> classData) {
    final learners = classData['learners'];
    if (learners is Map) return learners.length;
    return 0;
  }

  List<Map<String, String>> _inClassLearnersList(Map<String, dynamic> classData) {
    final learners = classData['learners'];
    if (learners is! Map) return [];

    final Map<dynamic, dynamic> raw = Map<dynamic, dynamic>.from(learners);
    final List<Map<String, String>> out = [];

    for (final entry in raw.entries) {
      final uid = entry.key.toString();
      final value = entry.value;

      if (value is Map) {
        final m = Map<String, dynamic>.from(value as Map);
        final name = _safeStr(m['name']);
        final serial = _safeStr(m['serial']);

        out.add({
          'uid': uid,
          'name': name,
          'serial': serial,
        });
      } else {
        out.add({
          'uid': uid,
          'name': '',
          'serial': '',
        });
      }
    }

    out.sort((a, b) {
      final an = _norm(a['name'] ?? '');
      final bn = _norm(b['name'] ?? '');
      return an.compareTo(bn);
    });

    return out;
  }
  String _firstSessionDate(Map<String, dynamic> classData) {
    final schedule = classData['schedule'];
    if (schedule is Map) {
      final firstDate = _safeStr(schedule['first_session_date']);
      return firstDate.isEmpty ? '-' : firstDate;
    }
    return '-';
  }

  int? _plannedMeetingsFromClass(Map<String, dynamic> classData) {
    final schedule = classData['schedule'];
    if (schedule is Map) {
      final m = Map<String, dynamic>.from(schedule);
      final v = m['meetingsCount'] ?? m['totalMeetings'] ?? m['sessionsCount'];
      final n = _asInt(v);
      if (n > 0) return n;
    }
    return null;
  }

  Future<_ClassProg> _loadClassProgress(String classId, Map<String, dynamic> classData) async {
    if (_classProgCache.containsKey(classId)) return _classProgCache[classId]!;

    final courseId = _safeStr(classData['course_id']);
    int totalLessons = 0;

    if (courseId.isNotEmpty) {
      final sSnap = await _syllabiRef.child(courseId).get();
      if (sSnap.exists && sSnap.value is Map) {
        final s = Map<String, dynamic>.from(sSnap.value as Map);
        final units = s['units'];
        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final sessions = unit['sessions'];
            if (sessions is List) totalLessons += sessions.length;
          }
        }
      }
    }

    final att = classData['attendance'];
    final Set<String> coveredLessonSessionIds = {};
    int meetingsHeld = 0;

    if (att is Map) {
      final m = Map<String, dynamic>.from(att);
      meetingsHeld = m.length;

      for (final entry in m.entries) {
        final rec = entry.value;
        if (rec is! Map) continue;
        final r = Map<String, dynamic>.from(rec);

        final taughtItems = r['taughtItems'];
        bool countedFromNewFormat = false;

        if (taughtItems is List) {
          countedFromNewFormat = true;
          for (final it in taughtItems) {
            if (it is! Map) continue;
            final item = Map<String, dynamic>.from(it);

            final type = _safeStr(item['type']).toLowerCase();
            if (type != 'syllabus') continue;

            final sid = _safeStr(item['sessionId']);
            if (sid.isNotEmpty) coveredLessonSessionIds.add(sid);
          }
        }

        if (!countedFromNewFormat) {
          final taught = r['taught'];
          if (taught is Map) {
            final tm = Map<String, dynamic>.from(taught);
            final sid = _safeStr(tm['sessionId']);
            if (sid.isNotEmpty) coveredLessonSessionIds.add(sid);
          }
        }
      }
    }

    final coveredLessons = coveredLessonSessionIds.length;
    final plannedMeetings = _plannedMeetingsFromClass(classData);

    final syllabusPct =
    totalLessons <= 0 ? 0 : ((coveredLessons / totalLessons) * 100).round().clamp(0, 100);

    final prog = _ClassProg(
      syllabusPercent: syllabusPct,
      coveredLessons: coveredLessons,
      totalLessons: totalLessons,
      meetingsHeld: meetingsHeld,
      plannedMeetings: plannedMeetings,
    );

    _classProgCache[classId] = prog;
    return prog;
  }

  Future<Map<String, dynamic>?> _loadSessionDetails(String courseId, int sessionNo) async {
    if (courseId.isEmpty || sessionNo <= 0) return null;
    try {
      final snap = await _db.child('booking_curriculum/$courseId/sessions/$sessionNo').get();
      if (snap.exists && snap.value is Map) {
        return (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> _loadOnlineSyllabusSession(String courseId, int sessionNo) async {
    if (courseId.isEmpty || sessionNo <= 0) return null;

    try {
      final snap = await _db.child('syllabi/$courseId/online').get();
      if (!snap.exists || snap.value is! Map) return null;

      final root = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
      final unitsRaw = root['units'];

      if (unitsRaw is! List) return null;

      for (final u in unitsRaw) {
        if (u is! Map) continue;
        final unit = u.map((k, v) => MapEntry(k.toString(), v));
        final sessionsRaw = unit['sessions'];

        if (sessionsRaw is! List) continue;

        for (final s in sessionsRaw) {
          if (s is! Map) continue;
          final session = s.map((k, v) => MapEntry(k.toString(), v));

          final sn = _asInt(session['sessionNumber']);
          final order = _asInt(session['order']);

          if (sn == sessionNo || order == sessionNo) {
            return session;
          }
        }
      }
    } catch (_) {}

    return null;
  }

  Future<void> _openSessionDetailsSheet(String courseId, int sessionNo) async {
    final info = await _loadSessionDetails(courseId, sessionNo);
    if (!mounted) return;

    if (info == null) {
      _toast('Session details not found.');
      return;
    }

    final titleRaw = (info['sessionTitle'] ?? info['title'] ?? '').toString().trim();
    final title = titleRaw.isEmpty ? 'Session $sessionNo' : 'Session $sessionNo — $titleRaw';

    final objective = (info['objective'] ?? '').toString().trim();
    final content = (info['content'] ?? '').toString().trim();
    final homework = (info['homework'] ?? '').toString().trim();
    final duration = _asInt(info['durationMinutes'] ?? info['durationMin'] ?? 0);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: primaryBlue)),
                  const SizedBox(height: 8),
                  Text('Course: $courseId', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
                  const SizedBox(height: 6),
                  if (duration > 0)
                    Text('Duration: $duration min',
                        style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
                  const SizedBox(height: 12),

                  if (objective.isNotEmpty) ...[
                    const Text('Objectives', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(objective, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
                    const SizedBox(height: 12),
                  ],

                  if (content.isNotEmpty) ...[
                    const Text('Content', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(content, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
                    const SizedBox(height: 12),
                  ],

                  if (homework.isNotEmpty) ...[
                    const Text('Homework', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                    const SizedBox(height: 6),
                    Text(homework, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
                    const SizedBox(height: 12),
                  ],

                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: actionOrange,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openOnlineSessionDetailsSheet(String courseId, int sessionNo, String courseTitle) async {
    final info = await _loadOnlineSyllabusSession(courseId, sessionNo);
    if (!mounted) return;

    if (info == null) {
      _toast('Online session details not found.');
      return;
    }

    final titleRaw = (info['title'] ?? '').toString().trim();
    final title = titleRaw.isEmpty ? 'Session $sessionNo' : 'Session $sessionNo — $titleRaw';

    final courseLabel = courseTitle.trim().isEmpty ? courseId : courseTitle;

    final objective = (info['objective'] ?? '').toString().trim();
    final content = (info['content'] ?? '').toString().trim();
    final homework = (info['homework'] ?? '').toString().trim();
    final materialsUrl = (info['materialsUrl'] ?? '').toString().trim();
    final duration = _asInt(info['durationMinutes'] ?? 0);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        final bottomPad = MediaQuery.of(context).padding.bottom;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      color: primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Course: $courseLabel',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (duration > 0)
                    Text(
                      'Duration: $duration min',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  const SizedBox(height: 12),

                  if (objective.isNotEmpty) ...[
                    const Text(
                      'Objectives',
                      style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      objective,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (content.isNotEmpty) ...[
                    const Text(
                      'Content',
                      style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      content,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (homework.isNotEmpty) ...[
                    const Text(
                      'Homework',
                      style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      homework,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (materialsUrl.isNotEmpty) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: actionOrange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => _openExternalUrl(materialsUrl),
                        icon: const Icon(Icons.slideshow_rounded),
                        label: const Text(
                          'Open materials',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Close',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }


  // ===================== ONLINE tab =====================

  Future<String> _loadCourseTitle(String courseId, List<String> learnerUids) async {
    if (courseId.isEmpty) return '';
    if (_courseTitleCache.containsKey(courseId)) return _courseTitleCache[courseId]!;

    try {
      for (final learnerUid in learnerUids) {
        if (learnerUid.trim().isEmpty) continue;

        final snap = await _usersRef.child(learnerUid).child('courses').get();
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final raw = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in raw.entries) {
          final value = entry.value;
          if (value is! Map) continue;

          final courseMap = Map<String, dynamic>.from(value as Map);
          final id = _safeStr(courseMap['id']);
          if (id != courseId) continue;

          final title = _safeStr(courseMap['title'] ?? courseMap['course_title']);
          if (title.isNotEmpty) {
            _courseTitleCache[courseId] = title;
            return title;
          }
        }
      }
    } catch (_) {}

    _courseTitleCache[courseId] = '';
    return '';
  }

  Future<String> _loadSessionTitle(String courseId, int sessionNo) async {
    if (courseId.isEmpty || sessionNo <= 0) return '';
    final key = '$courseId|$sessionNo';
    if (_sessionTitleCache.containsKey(key)) return _sessionTitleCache[key]!;

    try {
      final info = await _loadOnlineSyllabusSession(courseId, sessionNo);
      if (info != null) {
        final title = (info['title'] ?? '').toString().trim();
        _sessionTitleCache[key] = title;
        return title;
      }
    } catch (_) {}

    _sessionTitleCache[key] = '';
    return '';
  }

  Future<_AvailMeta> _loadAvailMeta(String teacherId, String courseId) async {
    // from booking_availability/<teacherId>/<courseId>/ {meetUrl, durationMinutes}
    try {
      if (teacherId.isEmpty || courseId.isEmpty) return const _AvailMeta.empty();
      final snap = await _db.child('$bookingAvailabilityNode/$teacherId/$courseId').get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));

        final meetUrl =
        _safeStr(m['meetUrl'] ?? m['meet_url'] ?? m['googleMeetUrl'] ?? m['google_meet_url']);
        int dur = _asInt(m['durationMinutes'] ?? m['durationMin'] ?? m['duration']);
        if (dur <= 0) dur = 60;

        final teacherName = _safeStr(m['teacherName'] ?? m['teacher_name']);
        return _AvailMeta(meetUrl: meetUrl, durationMinutes: dur, teacherName: teacherName);
      }
    } catch (_) {}
    return const _AvailMeta.empty();
  }

  bool _isInJoinWindow(DateTime start, int durationMinutes) {
    final now = DateTime.now();
    final openFrom = start.subtract(const Duration(minutes: 10));
    final dur = durationMinutes <= 0 ? 60 : durationMinutes;
    final openUntil = start.add(Duration(minutes: dur)).add(const Duration(minutes: 15));
    return now.isAfter(openFrom) && now.isBefore(openUntil);
  }

  Future<void> _loadMyOnlineBookings() async {
    setState(() {
      _onlineBusy = true;
      _onlineError = null;
      _onlineAll = [];
    });

    try {
      if (_teacherUid.isEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) throw Exception('Not logged in.');
        _teacherUid = user.uid;
      }

      final rootSnap = await _db.child(bookingReservationsNode).get();
      if (!rootSnap.exists || rootSnap.value == null || rootSnap.value is! Map) {
        setState(() {
          _onlineAll = [];
          _onlineBusy = false;
        });
        return;
      }

      final Map<dynamic, dynamic> byCourse = Map<dynamic, dynamic>.from(rootSnap.value as Map);
      final List<_OnlineBooking> out = [];

      // iterate: courseId -> date -> time -> slot
      for (final courseEntry in byCourse.entries) {
        final courseId = courseEntry.key.toString();
        final courseNode = courseEntry.value;
        if (courseNode is! Map) continue;

        final Map<dynamic, dynamic> byDate = Map<dynamic, dynamic>.from(courseNode);

        for (final dateEntry in byDate.entries) {
          final dayKey = dateEntry.key.toString(); // yyyy-mm-dd
          final dateNode = dateEntry.value;
          if (dateNode is! Map) continue;

          final Map<dynamic, dynamic> byTime = Map<dynamic, dynamic>.from(dateNode);

          for (final timeEntry in byTime.entries) {
            final hhmm = timeEntry.key.toString(); // HH:MM
            final slotNode = timeEntry.value;
            if (slotNode is! Map) continue;

            final slot = slotNode.map((k, v) => MapEntry(k.toString(), v));

            final teacherId = _safeStr(slot['teacherId'] ?? slot['teacherUid'] ?? slot['teacher_id']);
            if (teacherId != _teacherUid) continue; // ✅ only assigned to me

            final dt = _parseSlotStart(dayKey, hhmm);
            if (dt == null) continue;

            // learners list
            final learnersRaw = slot['learners'];
            final List<String> learnerUids = [];
            if (learnersRaw is Map) {
              final lm = learnersRaw.map((k, v) => MapEntry(k.toString(), v));
              for (final uid in lm.keys) {
                learnerUids.add(uid);
              }
            }

            final teacherNameFromSlot = _safeStr(slot['teacherName']);
            final sessionNo = _asInt(slot['sessionNo']);
            final createdAt = slot['createdAt'];

            // availability meta (meetUrl + duration)
            final meta = await _loadAvailMeta(teacherId, courseId);

            final courseTitle = await _loadCourseTitle(courseId, learnerUids);

            final bookingKey = _OnlineBooking.makeKey(courseId, dayKey, hhmm);

            out.add(
              _OnlineBooking(
                bookingKey: bookingKey,
                courseId: courseId,
                courseTitle: courseTitle,
                dayKey: dayKey,
                time: hhmm,
                startAtMillis: dt.millisecondsSinceEpoch,
                teacherId: teacherId,
                teacherName: meta.teacherName.isNotEmpty
                    ? meta.teacherName
                    : (teacherNameFromSlot.isNotEmpty
                    ? teacherNameFromSlot
                    : (_teacherName.isNotEmpty ? _teacherName : 'Teacher')),
                learnerUids: learnerUids,
                sessionNo: sessionNo,
                createdAtRaw: createdAt,
                meetUrl: meta.meetUrl,
                durationMinutes: meta.durationMinutes <= 0 ? 60 : meta.durationMinutes,
              ),
            );
          }
        }
      }

      // Sort by time
      out.sort((a, b) => a.startAtMillis.compareTo(b.startAtMillis));

      setState(() {
        _onlineAll = out;
        _onlineBusy = false;
      });
    } catch (e) {
      setState(() {
        _onlineError = e.toString();
        _onlineBusy = false;
      });
    }
  }

  // ===================== UI =====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'My Teaching',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        bottom: TabBar(
          controller: _tab,
          labelColor: primaryBlue,
          unselectedLabelColor: Colors.grey.shade600,
          indicatorColor: actionOrange,
          tabs: const [
            Tab(icon: Icon(Icons.groups_rounded), text: 'In-class'),
            Tab(icon: Icon(Icons.wifi_tethering_rounded), text: 'Online'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: actionOrange),
            onPressed: () async {
              await _loadAll();
              _toast('Refreshed ✅');
            },
          ),
        ],
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildInClassTab(),
          _buildOnlineTab(),
        ],
      ),
    );
  }

  // -------------------- In-class tab UI --------------------

  Widget _buildInClassTab() {
    if (_busy) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
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
                const Text('Teacher',
                    style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900, fontSize: 14)),
                const SizedBox(height: 6),
                Text(
                  _teacherName.isEmpty ? '-' : _teacherName,
                  style: const TextStyle(color: mainText, fontWeight: FontWeight.w900, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (_myClasses.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No classes found for you yet.',
                style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
              ),
            ),
          )
        else
          ..._myClasses.map((c) => _classCard(c)).toList(),
      ],
    );
  }

  Widget _classCard(Map<String, dynamic> c) {
    final classId = _safeStr(c['id'] ?? c['class_id']);
    final title = _safeStr(c['course_title']).isEmpty ? 'Class' : _safeStr(c['course_title']);
    final duration = _safeStr(c['course_duration']);
    final learnersCount = _learnersCount(c);
    final learnersList = _inClassLearnersList(c);

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        collapsedIconColor: primaryBlue,
        iconColor: primaryBlue,
        title: Text(title, style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Duration: ${duration.isEmpty ? '-' : duration}',
                  style: TextStyle(color: mainText.withOpacity(0.8), fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('First session: ${_firstSessionDate(c)}',
                  style: TextStyle(color: mainText.withOpacity(0.8), fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Learners: $learnersCount',
                  style: TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              FutureBuilder<_ClassProg>(
                future: classId.isEmpty ? Future.value(_ClassProg.zero()) : _loadClassProgress(classId, c),
                builder: (context, snap) {
                  final p = snap.data ?? _ClassProg.zero();

                  final plannedMeetingsStr =
                  (p.plannedMeetings == null || p.plannedMeetings! <= 0) ? '-' : '${p.plannedMeetings}';

                  final syllabusTotalStr = p.totalLessons <= 0 ? '-' : '${p.totalLessons}';
                  final syllabusPct = p.syllabusPercent.clamp(0, 100);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.event_available_rounded, size: 16, color: actionOrange),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('Meetings: ${p.meetingsHeld}/$plannedMeetingsStr',
                                style: TextStyle(color: mainText.withOpacity(0.80), fontWeight: FontWeight.w900)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.menu_book_rounded, size: 16, color: actionOrange),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('Syllabus: ${p.coveredLessons}/$syllabusTotalStr  •  $syllabusPct%',
                                style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w800)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: p.totalLessons <= 0 ? 0 : (p.coveredLessons / p.totalLessons).clamp(0, 1),
                          minHeight: 8,
                          backgroundColor: primaryBlue.withOpacity(0.10),
                          valueColor: const AlwaysStoppedAnimation(actionOrange),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        children: [
          const SizedBox(height: 8),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: appBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: uiBorder.withOpacity(0.85)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Learners',
                  style: TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                if (learnersList.isEmpty)
                  Text(
                    'No learners found in this class.',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  ...learnersList.map((learner) {
                    final name = _safeStr(learner['name']);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: uiBorder.withOpacity(0.65)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.person_rounded,
                            size: 16,
                            color: actionOrange,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name.isEmpty ? 'Learner' : name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: mainText,
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                height: 1.15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
              ],
            ),
          ),

          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.fact_check_rounded),
                  label: const Text("Take"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: actionOrange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => TakeAttendanceScreen(classData: c)));
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.history_rounded, color: primaryBlue),
                  label: const Text("History", style: TextStyle(color: primaryBlue)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: uiBorder.withOpacity(0.9)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceHistoryScreen(classData: c)));
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.bar_chart_rounded, color: primaryBlue),
                  label: const Text("Stats", style: TextStyle(color: primaryBlue)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: uiBorder.withOpacity(0.9)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceStatsScreen(classData: c)));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.insights_rounded, color: primaryBlue),
              label: const Text("Progress", style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: uiBorder.withOpacity(0.9)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: classId.isEmpty
                  ? null
                  : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TeacherClassProgressScreen(classId: classId, classData: c),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // -------------------- Online tab UI --------------------

  Widget _buildOnlineTab() {
    if (_onlineBusy) return const Center(child: CircularProgressIndicator());

    if (_onlineError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _onlineError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_onlineAll.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No online bookings found for you yet.',
            style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
          ),
        ),
      );
    }

    final now = DateTime.now();
    final pastLimit = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 7));

    final List<_OnlineBooking> startingOrOngoing = [];
    final List<_OnlineBooking> upcoming = [];
    final List<_OnlineBooking> past = [];

    for (final b in _onlineAll) {
      final dt = DateTime.fromMillisecondsSinceEpoch(b.startAtMillis);

      final inWindow = _isInJoinWindow(dt, b.durationMinutes);
      if (inWindow) {
        startingOrOngoing.add(b);
        continue;
      }

      if (dt.isAfter(now)) {
        upcoming.add(b);
        continue;
      }

      if (dt.isAfter(pastLimit)) {
        past.add(b);
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: _countCard(
                  label: 'Live',
                  value: '${startingOrOngoing.length}',
                  icon: Icons.play_circle_fill_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _countCard(
                  label: 'Upcoming',
                  value: '${upcoming.length}',
                  icon: Icons.schedule_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _countCard(
                  label: 'Past',
                  value: '${past.length}',
                  icon: Icons.history_rounded,
                ),
              ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: uiBorder.withOpacity(0.85)),
            ),
            child: TabBar(
              controller: _onlineTab,
              labelColor: primaryBlue,
              unselectedLabelColor: Colors.grey.shade600,
              indicatorColor: actionOrange,
              tabs: const [
                Tab(text: 'Live'),
                Tab(text: 'Upcoming'),
                Tab(text: 'Past'),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        Expanded(
          child: TabBarView(
            controller: _onlineTab,
            children: [
              _onlineBookingsList(
                items: startingOrOngoing,
                emptyText: 'No ongoing sessions right now.',
              ),
              _onlineBookingsList(
                items: upcoming,
                emptyText: 'No upcoming sessions.',
              ),
              _onlineBookingsList(
                items: past.reversed.toList(),
                emptyText: 'No past sessions in the last 7 days.',
              ),
            ],
          ),
        ),
      ],
    );
  }
  Widget _countCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: Column(
        children: [
          Icon(icon, color: actionOrange, size: 20),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, {required String badge}) {
    return Row(
      children: [
        Expanded(
          child: Text(title, style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900, fontSize: 14)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: actionOrange.withOpacity(0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: actionOrange.withOpacity(0.25)),
          ),
          child: Text(badge, style: const TextStyle(fontWeight: FontWeight.w900, color: actionOrange)),
        )
      ],
    );
  }


  Widget _onlineBookingsList({
    required List<_OnlineBooking> items,
    required String emptyText,
  }) {
    if (items.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _emptyHint(emptyText),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: items.map(_bookingCard).toList(),
    );
  }
  Widget _emptyHint(String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: Text(text, style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
    );
  }

  Widget _bookingCard(_OnlineBooking b) {
    final dt = DateTime.fromMillisecondsSinceEpoch(b.startAtMillis);
    final when = '${dt.year}-${_two(dt.month)}-${_two(dt.day)}  ${_two(dt.hour)}:${_two(dt.minute)}';

    final inWindow = _isInJoinWindow(dt, b.durationMinutes);
    final statusText = inWindow
        ? 'Ongoing / join window'
        : dt.isAfter(DateTime.now())
        ? 'Upcoming'
        : 'Past';

    final statusBg = inWindow
        ? const Color(0xFFEAF7EE)
        : (dt.isAfter(DateTime.now()) ? const Color(0xFFFFF1E3) : const Color(0xFFEFF3F8));

    final statusBorder = inWindow
        ? const Color(0xFFB9E2C5)
        : (dt.isAfter(DateTime.now()) ? const Color(0xFFF9C59D) : uiBorder.withOpacity(0.8));

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Course: ${b.courseTitle.trim().isEmpty ? b.courseId : b.courseTitle}',
              style: const TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text('When: $when', style: TextStyle(color: mainText.withOpacity(0.85), fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Teacher: ${b.teacherName}', style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Learners: ${b.learnerUids.length}', style: TextStyle(color: mainText.withOpacity(0.75), fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            FutureBuilder<String>(
              future: _loadSessionTitle(b.courseId, b.sessionNo),
              builder: (context, snap) {
                final title = (snap.data ?? '').trim();
                final sNo = b.sessionNo <= 0 ? '-' : '${b.sessionNo}';
                final label = title.isEmpty ? 'Session: $sNo' : 'Session: $sNo — $title';

                return Text(
                  label,
                  style: TextStyle(color: mainText.withOpacity(0.70), fontWeight: FontWeight.w700),
                );
              },
            ),
            const SizedBox(height: 10),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: statusBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: statusBorder),
              ),
              child: Row(
                children: [
                  Icon(inWindow ? Icons.play_circle_fill_rounded : Icons.schedule_rounded,
                      color: primaryBlue, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(statusText, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                  ),
                  if (b.meetUrl.trim().isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _openExternalUrl(b.meetUrl),
                      icon: const Icon(Icons.video_call_rounded, color: actionOrange),
                      label: const Text('Meet', style: TextStyle(fontWeight: FontWeight.w900, color: actionOrange)),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _openOnlineSessionDetailsSheet(
                  b.courseId,
                  b.sessionNo,
                  b.courseTitle,
                ),
                icon: const Icon(Icons.info_outline_rounded, color: actionOrange),
                label: const Text('Details', style: TextStyle(fontWeight: FontWeight.w900, color: actionOrange)),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.fact_check_rounded),
                    label: const Text("Take"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: actionOrange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OnlineTakeAttendanceScreen(
                            booking: b,
                            teacherUid: _teacherUid,
                            teacherName: _teacherName.isEmpty ? 'Teacher' : _teacherName,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.history_rounded, color: primaryBlue),
                    label: const Text("History", style: TextStyle(color: primaryBlue)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: uiBorder.withOpacity(0.9)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OnlineAttendanceHistoryScreen(
                            booking: b,
                            teacherUid: _teacherUid,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.bar_chart_rounded, color: primaryBlue),
                    label: const Text("Stats", style: TextStyle(color: primaryBlue)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: uiBorder.withOpacity(0.9)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OnlineAttendanceStatsScreen(
                            courseId: b.courseId,
                            courseTitle: b.courseTitle,
                            teacherUid: _teacherUid,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),
            _learnersPreview(b),
          ],
        ),
      ),
    );
  }

  Widget _learnersPreview(_OnlineBooking b) {
    final uids = b.learnerUids;
    if (uids.isEmpty) return const SizedBox.shrink();

    final show = uids.take(3).toList();
    final more = uids.length - show.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Learners (preview)', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
        const SizedBox(height: 6),
        ...show.map((uid) {
          return FutureBuilder<Map<String, String>>(
            future: _loadUserName(uid),
            builder: (context, snap) {
              final full = (snap.data?['full'] ?? '').trim();
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• ${full.isEmpty ? "Learner" : full}',
                  style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700),
                ),
              );
            },
          );
        }).toList(),
        if (more > 0)
          Text('… +$more more', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
      ],
    );
  }
}

// ============================================================
// Models
// ============================================================

class _ClassProg {
  final int syllabusPercent;
  final int coveredLessons;
  final int totalLessons;
  final int meetingsHeld;
  final int? plannedMeetings;

  const _ClassProg({
    required this.syllabusPercent,
    required this.coveredLessons,
    required this.totalLessons,
    required this.meetingsHeld,
    required this.plannedMeetings,
  });

  factory _ClassProg.zero() => const _ClassProg(
    syllabusPercent: 0,
    coveredLessons: 0,
    totalLessons: 0,
    meetingsHeld: 0,
    plannedMeetings: null,
  );
}

class _AvailMeta {
  final String meetUrl;
  final int durationMinutes;
  final String teacherName;

  const _AvailMeta({
    required this.meetUrl,
    required this.durationMinutes,
    required this.teacherName,
  });

  const _AvailMeta.empty()
      : meetUrl = '',
        durationMinutes = 60,
        teacherName = '';
}

class _OnlineBooking {
  final String bookingKey; // courseId|yyyy-mm-dd|HH:MM

  final String courseId;
  final String courseTitle;
  final String dayKey; // yyyy-mm-dd
  final String time; // HH:MM

  final int startAtMillis;

  final String teacherId;
  final String teacherName;

  final List<String> learnerUids;

  final int sessionNo;
  final dynamic createdAtRaw;

  final String meetUrl;
  final int durationMinutes;

  const _OnlineBooking({
    required this.bookingKey,
    required this.courseId,
    required this.courseTitle,
    required this.dayKey,
    required this.time,
    required this.startAtMillis,
    required this.teacherId,
    required this.teacherName,
    required this.learnerUids,
    required this.sessionNo,
    required this.createdAtRaw,
    required this.meetUrl,
    required this.durationMinutes,
  });

  static String makeKey(String courseId, String dayKey, String hhmm) => '$courseId|$dayKey|$hhmm';
}

// ============================================================
// ONLINE SCREENS (Attendance / History / Stats)
// Present/Absent ONLY + show learner NAMES (no UID shown)
// ============================================================

class OnlineTakeAttendanceScreen extends StatefulWidget {
  const OnlineTakeAttendanceScreen({
    super.key,
    required this.booking,
    required this.teacherUid,
    required this.teacherName,
  });

  final _OnlineBooking booking;
  final String teacherUid;
  final String teacherName;

  @override
  State<OnlineTakeAttendanceScreen> createState() => _OnlineTakeAttendanceScreenState();
}

class _OnlineTakeAttendanceScreenState extends State<OnlineTakeAttendanceScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const uiBorder = Color(0xFFD1D9E0);
  static const appBg = Color(0xFFF4F7F9);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool saving = false;

  // per learner present/absent (default: present)
  final Map<String, bool> presentMap = {};
  final Map<String, String> _localNameCache = {}; // uid -> full name

  void _toast(String msg) {
    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
  }

  Future<String> _loadLearnerFullName(String uid) async {
    if (_localNameCache.containsKey(uid)) return _localNameCache[uid]!;
    try {
      final snap = await _db.child('${_TeacherClassesScreenState.usersNode}/$uid').get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final fn = (m['first_name'] ?? '').toString().trim();
        final ln = (m['last_name'] ?? '').toString().trim();
        final full = ('$fn $ln').trim();
        final out = full.isEmpty ? 'Learner' : full;
        _localNameCache[uid] = out;
        return out;
      }
    } catch (_) {}
    _localNameCache[uid] = 'Learner';
    return 'Learner';
  }

  @override
  void initState() {
    super.initState();
    // default everyone to Present
    for (final uid in widget.booking.learnerUids) {
      presentMap[uid] = true;
    }
  }
  DatabaseReference _teacherAttendanceRef() =>
      _db.child('${_TeacherClassesScreenState.onlineAttendanceNode}/${widget.booking.bookingKey}');

  DatabaseReference _learnerAttendanceRef(String learnerUid) => _db.child(
      '${_TeacherClassesScreenState.bookingProgressNode}/$learnerUid/${widget.booking.courseId}/online_attendance/${widget.booking.bookingKey}');

  Future<void> _save() async {
    setState(() => saving = true);
    // ✅ NEW: what was taught (online = booked sessionNo)
    final int sessionNo = widget.booking.sessionNo;

    String sessionTitle = '';
    if (sessionNo > 0) {
      try {
        final snap = await _db
            .child('booking_curriculum/${widget.booking.courseId}/sessions/$sessionNo')
            .get();
        if (snap.exists && snap.value is Map) {
          final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
          sessionTitle = (m['sessionTitle'] ?? m['title'] ?? '').toString().trim();
        }
      } catch (_) {}
    }

    final List<Map<String, dynamic>> taughtItems = (sessionNo > 0)
        ? [
      {
        'type': 'syllabus',
        'sessionNumber': sessionNo,
        'title': sessionTitle,
      }
    ]
        : <Map<String, dynamic>>[];
    try {
      // Build learners map to store
      final Map<String, dynamic> learners = {};
      for (final uid in widget.booking.learnerUids) {
        learners[uid] = {
          'present': presentMap[uid] == true,
        };
      }

      final payload = {
        'bookingKey': widget.booking.bookingKey,
        'courseId': widget.booking.courseId,
        'dayKey': widget.booking.dayKey,
        'time': widget.booking.time,
        'startAt': widget.booking.startAtMillis,
        'teacherUid': widget.teacherUid,
        'teacherName': widget.teacherName,
        'teacherId': widget.booking.teacherId,
        'teacherNameFromBooking': widget.booking.teacherName,
        'meetUrl': widget.booking.meetUrl,
        'durationMinutes': widget.booking.durationMinutes,
        'sessionNo': widget.booking.sessionNo,
        'taughtItems': taughtItems,
        'learners': learners,
        'updatedAt': ServerValue.timestamp,
      };

      // A) teacher/global node
      await _teacherAttendanceRef().set(payload);

// B) mirror to each learner inside their course node ✅
// + ✅ advance currentSession ONLY when Present
      for (final uid in widget.booking.learnerUids) {
        final isPresent = presentMap[uid] == true;

        // 1) save online attendance record inside learner course
        await _learnerAttendanceRef(uid).set({
          'bookingKey': widget.booking.bookingKey,
          'courseId': widget.booking.courseId,
          'dayKey': widget.booking.dayKey,
          'time': widget.booking.time,
          'startAt': widget.booking.startAtMillis,
          'teacherUid': widget.teacherUid,
          'teacherName': widget.teacherName,
          'present': isPresent,
          'taughtItems': taughtItems,
          'updatedAt': ServerValue.timestamp,
        });

        // 2) ✅ Only if Present -> advance booking progress
        // currentSession should become sessionNo + 1 (but never go backwards)
        if (isPresent && widget.booking.sessionNo > 0) {
          final curRef = _db.child(
            '${_TeacherClassesScreenState.bookingProgressNode}/$uid/${widget.booking.courseId}/currentSession',
          );

          final curSnap = await curRef.get();
          final curVal = curSnap.value;

          int cur = 0;
          if (curVal is int) cur = curVal;
          else if (curVal is num) cur = curVal.toInt();
          else cur = int.tryParse(curVal?.toString() ?? '') ?? 0;

          final next = widget.booking.sessionNo + 1;

          // Don't decrease if someone already progressed further
          if (cur < next) {
            await curRef.set(next);
          }
        }
      }

      _toast('Online attendance saved ✅');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final dt = DateTime.fromMillisecondsSinceEpoch(b.startAtMillis);
    final when =
        '${dt.year}-${_TeacherClassesScreenState._two(dt.month)}-${_TeacherClassesScreenState._two(dt.day)}  '
        '${_TeacherClassesScreenState._two(dt.hour)}:${_TeacherClassesScreenState._two(dt.minute)}';

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text('Online Attendance',
            style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: saving ? null : _save,
            icon: saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_rounded, color: actionOrange),
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _box(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Course: ${b.courseTitle.trim().isEmpty ? b.courseId : b.courseTitle}',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                const SizedBox(height: 6),
                Text('When: $when', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
                const SizedBox(height: 4),
                Text('Learners: ${b.learnerUids.length}', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
                const SizedBox(height: 4),
                Text('Meet: ${b.meetUrl.isEmpty ? '-' : b.meetUrl}', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade600)),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _box(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Presence', style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
                const SizedBox(height: 10),
                if (b.learnerUids.isEmpty)
                  Text('No learners found in this booking.',
                      style: TextStyle(fontWeight: FontWeight.w800, color: Colors.grey.shade700))
                else
                  ...b.learnerUids.map((uid) {
                    final v = presentMap[uid] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: uiBorder.withOpacity(0.85)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: FutureBuilder<String>(
                              future: _loadLearnerFullName(uid),
                              builder: (context, snap) {
                                final name = (snap.data ?? 'Learner').trim();
                                return Text(
                                  name.isEmpty ? 'Learner' : name,
                                  style: const TextStyle(fontWeight: FontWeight.w900),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Switch(
                            value: v,
                            onChanged: (x) => setState(() => presentMap[uid] = x),
                            activeColor: actionOrange,
                          ),
                        ],
                      ),
                    );
                  }).toList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _box({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: child,
    );
  }
}

class OnlineAttendanceHistoryScreen extends StatelessWidget {
  const OnlineAttendanceHistoryScreen({super.key, required this.booking, required this.teacherUid});
  final _OnlineBooking booking;
  final String teacherUid;

  static const primaryBlue = Color(0xFF1A2B48);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseDatabase.instance
        .ref('${_TeacherClassesScreenState.onlineAttendanceNode}/${booking.bookingKey}');

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text('Online Attendance History',
            style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
      ),
      body: FutureBuilder<DataSnapshot>(
        future: ref.get(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData || !snap.data!.exists || snap.data!.value == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No online attendance found yet.', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            );
          }

          final data = (snap.data!.value is Map)
              ? Map<String, dynamic>.from(snap.data!.value as Map)
              : <String, dynamic>{};

          final learners = data['learners'];

          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              _box(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Course: ${booking.courseTitle.trim().isEmpty ? booking.courseId : booking.courseTitle}',
                      style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                    ),
                    const SizedBox(height: 10),
                    const Text('Learners:', style: TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    if (learners is Map && learners.isNotEmpty)
                      ...learners.entries.map((e) {
                        final uid = e.key.toString();
                        final v = e.value;
                        bool present = false;
                        if (v is Map) {
                          final m = v.map((k, vv) => MapEntry(k.toString(), vv));
                          present = m['present'] == true;
                        }

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: FutureBuilder<DataSnapshot>(
                            future: FirebaseDatabase.instance
                                .ref('${_TeacherClassesScreenState.usersNode}/$uid')
                                .get(),
                            builder: (context, userSnap) {
                              String fullName = 'Learner';
                              if (userSnap.hasData &&
                                  userSnap.data!.exists &&
                                  userSnap.data!.value is Map) {
                                final um = (userSnap.data!.value as Map)
                                    .map((k, vv) => MapEntry(k.toString(), vv));
                                final fn = (um['first_name'] ?? '').toString().trim();
                                final ln = (um['last_name'] ?? '').toString().trim();
                                final f = ('$fn $ln').trim();
                                if (f.isNotEmpty) fullName = f;
                              }

                              return Text(
                                '• $fullName  —  ${present ? "Present" : "Absent"}',
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              );
                            },
                          ),
                        );
                      }).toList()
                    else
                      const Text('No learners map saved.', style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _box({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: child,
    );
  }
}

class OnlineAttendanceStatsScreen extends StatefulWidget {
  const OnlineAttendanceStatsScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
    required this.teacherUid,
  });

  final String courseId;
  final String courseTitle;
  final String teacherUid;

  @override
  State<OnlineAttendanceStatsScreen> createState() => _OnlineAttendanceStatsScreenState();
}

class _OnlineAttendanceStatsScreenState extends State<OnlineAttendanceStatsScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool loading = true;
  int totalSessions = 0;
  int presentCount = 0;
  int absentCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);

    int sessions = 0;
    int p = 0;
    int a = 0;

    try {
      final snap = await _db.child(_TeacherClassesScreenState.onlineAttendanceNode).get();
      if (snap.exists && snap.value is Map) {
        final m = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final entry in m.entries) {
          if (entry.value is! Map) continue;
          final rec = Map<String, dynamic>.from(entry.value as Map);

          final teacherUid = (rec['teacherUid'] ?? '').toString();
          final courseId = (rec['courseId'] ?? '').toString();
          if (teacherUid != widget.teacherUid) continue;
          if (widget.courseId.isNotEmpty && courseId != widget.courseId) continue;

          sessions++;

          final learners = rec['learners'];
          if (learners is Map) {
            final lm = learners.map((k, v) => MapEntry(k.toString(), v));
            for (final v in lm.values) {
              if (v is Map) {
                final mm = v.map((k, vv) => MapEntry(k.toString(), vv));
                if (mm['present'] == true) {
                  p++;
                } else {
                  a++;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    setState(() {
      totalSessions = sessions;
      presentCount = p;
      absentCount = a;
      loading = false;
    });
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
        title: const Text('Online Stats', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _box(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Course: ${widget.courseTitle.trim().isEmpty ? widget.courseId : widget.courseTitle}',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                ),
                const SizedBox(height: 10),
                Text('Sessions with attendance: $totalSessions', style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text('Total Present marks: $presentCount', style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text('Total Absent marks: $absentCount', style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _box({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder.withOpacity(0.85)),
      ),
      child: child,
    );
  }
}