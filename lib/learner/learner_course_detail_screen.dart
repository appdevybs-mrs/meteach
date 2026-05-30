// learner_course_detail_screen.dart
// ✅ FULL DROP-IN REPLACEMENT (SAFE)
//
// Keeps your working Firebase/loading logic intact.
// Tabs: Overview / Progress
//
// ✅ NEW (requested):
// 1) Progress now includes BOTH:
//    - In-class attendance: users/<uid>/courses/<courseKey>/attendance
//    - Online attendance:   booking_progress/<uid>/<courseId>/online_attendance
//
// 2) Meetings progress = total attendance records (in-class + online)
// 3) Syllabus progress = unique SYLLABUS lessons covered from:
//    - In-class: taughtItems (type=syllabus) OR old taught.sessionId
//    - Online: sessionNo -> mapped to sessionId using syllabi sessionNumber
//
// 4) Attendance tab shows BOTH in-class + online records
//    - Online entries show (Online) + Session No + Present/Absent
//
// Notes:
// - This does NOT change your teacher writes.
// - It only reads the new online attendance and merges it into learner UI.
//
// ------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'learner_homework_screen.dart';
import 'learner_booking_screen.dart';
import 'learner_mail_thread_screen.dart';
import 'recorded_course_study_screen.dart';
import '../shared/offline_action_guard.dart';
import '../shared/human_error.dart';
import '../shared/payment_status.dart';
import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import '../shared/app_feedback.dart';
import '../shared/learner_web_layout.dart';
import '../shared/material_webview_screen.dart';
import '../shared/profile_avatar.dart';
import '../shared/responsive_layout.dart';
import '../shared/course_join_rules.dart';
import '../shared/shared_pdf_reader_screen.dart';
import '../services/course_feedback_service.dart';
import '../services/learner_join_signal_service.dart';
import '../services/push_dispatch_service.dart';
import '../services/secure_window_service.dart';

class LearnerCourseDetailScreen extends StatefulWidget {
  final String courseKey; // course_1, course_2 ...
  final Map<String, dynamic> courseData; // snapshot of user/courses/<courseKey>

  const LearnerCourseDetailScreen({
    super.key,
    required this.courseKey,
    required this.courseData,
  });

  @override
  State<LearnerCourseDetailScreen> createState() =>
      _LearnerCourseDetailScreenState();
}

class _LearnerCourseDetailScreenState extends State<LearnerCourseDetailScreen>
    with SingleTickerProviderStateMixin {
  static const usersNode = 'users';
  static const syllabiNode = 'syllabi';
  static const classesNode = 'classes';
  static const paymentsNode = 'payments';

  // ✅ NEW (online progress node)
  static const bookingProgressNode = 'booking_progress';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);

  bool _busy = true;
  String? _error;

  String _uid = '';
  Map<String, dynamic> _course = {};

  // ✅ NEW: online attendance list
  List<Map<String, dynamic>> _onlineAttendance = [];

  // ✅ NEW: merged list (in-class + online) used by UI + counts
  List<Map<String, dynamic>> _attendanceAll = [];

  List<Map<String, dynamic>> _syllabiFlat = [];
  Set<String> _coveredSessionIds = {};
  Map<int, String> _sessionIdByNumber =
      {}; // sessionNumber -> sessionId (fallback)
  Map<int, String> _sessionTitleByNumber =
      {}; // sessionNumber -> title (for online taughtSummary)
  Map<int, Map<String, dynamic>> _sessionReviewsByNo = {};
  String _courseBookUrl = '';

  // ✅ meetings total (optional)
  int? _plannedMeetings;

  late final TabController _tab;
  StreamSubscription<DatabaseEvent>? _paySub;
  Map<String, dynamic> _paymentSummary = {};
  bool _payLoading = true;
  int _derivedSessionsPaidTotal = 0;
  bool _derivedSessionsReady = false;
  Future<_DetailPrivateMeta?>? _privateMetaFuture;
  Timer? _joinTicker;
  _TeacherMiniProfile? _teacherProfile;
  bool _mailingTeacher = false;
  final bool _showFlexibleDetails = false;
  String? _expandedFlexibleUnitKey;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _joinTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _joinTicker?.cancel();
    _paySub?.cancel();
    _tab.dispose();
    super.dispose();
  }

  // -------------------- Safe helpers --------------------

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmtDateFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static String _fmtDateTimeFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
  }

  static int? _tryParseYmdToMillis(String ymd) {
    try {
      final p = ymd.trim().split('-');
      if (p.length != 3) return null;
      final y = int.tryParse(p[0]);
      final m = int.tryParse(p[1]);
      final d = int.tryParse(p[2]);
      if (y == null || m == null || d == null) return null;
      return DateTime(y, m, d).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static int? _tryParseYmdHmToMillis(String ymd, String hm) {
    final base = _tryParseYmdToMillis(ymd);
    if (base == null) return null;

    final parts = hm.trim().split(':');
    if (parts.length < 2) return base;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;

    final d = DateTime.fromMillisecondsSinceEpoch(base);
    return DateTime(d.year, d.month, d.day, h, m).millisecondsSinceEpoch;
  }

  static int? _tryParseDateTimeTextToMillis(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;

    final direct = DateTime.tryParse(t);
    if (direct != null) return direct.millisecondsSinceEpoch;

    final normalized = t.replaceAll('  ', ' ');
    final secondTry = DateTime.tryParse(normalized);
    if (secondTry != null) return secondTry.millisecondsSinceEpoch;

    final pieces = normalized.split(' ');
    if (pieces.length >= 2) {
      final ymd = pieces[0].trim();
      final hm = pieces[1].trim();
      return _tryParseYmdHmToMillis(ymd, hm);
    }

    return _tryParseYmdToMillis(normalized);
  }

  static String _fmtMoney(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final left = s.length - i;
      buf.write(s[i]);
      if (left > 1 && left % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  static String _normalizeVariantKey(String raw) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return 'inclass';
      case 'flexible':
      case 'online':
        return 'flexible';
      case 'private':
      case 'vip':
      case 'live':
        return 'private';
      case 'recorded':
      case 'record':
        return 'recorded';
      default:
        return v;
    }
  }

  static bool _variantUsesSessions(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private' || v == 'flexible';
  }

  static bool _variantUsesLegacySessionFallback(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  Future<int> _deriveSessionsPaidTotalFromPayments() async {
    if (_uid.trim().isEmpty) return 0;

    final expectedVariant = _normalizeVariantKey(_deliveryKey);
    final expectedCourseId = _courseId.trim();

    try {
      final snap = await _db
          .child(paymentsNode)
          .orderByChild('uid')
          .equalTo(_uid)
          .get();
      final raw = snap.value;
      if (raw is! Map) return 0;

      var total = 0;
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final p = value.map((k, v) => MapEntry(k.toString(), v));

        final payCourseKey = (p['courseKey'] ?? '').toString().trim();
        final payCourseId = (p['course_id'] ?? p['courseId'] ?? '')
            .toString()
            .trim();
        final matchesCourse =
            payCourseKey == widget.courseKey ||
            (expectedCourseId.isNotEmpty && payCourseId == expectedCourseId);
        if (!matchesCourse) continue;

        final payVariant = _normalizeVariantKey(
          (p['variantKey'] ?? p['deliveryKey'] ?? p['variant'] ?? '')
              .toString(),
        );
        if (expectedVariant.isNotEmpty &&
            payVariant.isNotEmpty &&
            payVariant != expectedVariant) {
          continue;
        }

        final effectiveVariant = payVariant.isNotEmpty
            ? payVariant
            : expectedVariant;
        if (!_variantUsesSessions(effectiveVariant)) continue;

        var sp = _asInt(p['sessionsPaid']);
        final amount = _asInt(p['amount']);
        if (sp <= 0 &&
            amount > 0 &&
            _variantUsesLegacySessionFallback(effectiveVariant)) {
          sp = 8;
        }
        total += sp;
      }

      return total;
    } catch (_) {
      return 0;
    }
  }

  Map<String, dynamic> get _cls => (_course['class'] is Map)
      ? Map<String, dynamic>.from(_course['class'] as Map)
      : <String, dynamic>{};

  String get _courseTitle =>
      (_course['title'] ?? _course['course_title'] ?? 'Course').toString();
  String get _courseCode => (_course['course_code'] ?? '').toString();
  String get _classId => (_cls['class_id'] ?? '').toString();

  // syllabi key (courseId)
  String get _courseId => (_cls['course_id'] ?? _course['id'] ?? '').toString();

  String get _deliveryKey {
    return resolveCourseDeliveryKey(_course);
  }

  String get _studyMode => resolveCourseStudyMode(_course);

  String get _legacyVariantKey =>
      (_course['variantKey'] ?? _course['variant'] ?? '')
          .toString()
          .trim()
          .toLowerCase();

  String get _syllabusVariantKey {
    final delivery = _deliveryKey;
    final legacy = _legacyVariantKey;

    if (delivery == 'recorded') return 'recorded';
    if (delivery == 'inclass') return 'inclass';
    if (delivery == 'flexible') return 'flexible';
    if (delivery == 'private') return 'private';

    if (legacy == 'recorded') return 'recorded';
    if (legacy == 'inclass' || legacy == 'in_class') return 'inclass';
    if (legacy == 'flexible' || legacy == 'online') return 'flexible';
    if (legacy == 'private' || legacy == 'live') return 'private';

    return '';
  }

  String get _studyTypeLabel {
    final delivery = _deliveryKey;
    final studyMode = _studyMode;

    if (delivery == 'private') {
      if (studyMode == 'online') return 'Private Online';
      if (studyMode == 'inclass') return 'Private In-Class';
      return 'Private';
    }

    if (delivery == 'inclass') return 'In-Class';
    if (delivery == 'flexible') return 'Flexible';
    if (delivery == 'recorded') return 'Recorded';

    return '';
  }

  bool get _isPrivateOnlineCourse {
    return isPrivateOnlineCourse(_course);
  }

  String _weeklyScheduleLine(dynamic sessionsRaw) {
    final nodes = <Map<String, dynamic>>[];
    if (sessionsRaw is List) {
      for (final s in sessionsRaw) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    } else if (sessionsRaw is Map) {
      for (final s in sessionsRaw.values) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    if (nodes.isEmpty) return 'Schedule: not set';

    String normDay(String raw) {
      final d = raw.trim();
      if (d.length <= 3) return d;
      return d.substring(0, 3);
    }

    final parts = nodes
        .map((n) {
          final day = normDay((n['day'] ?? '').toString());
          final start = (n['start_time'] ?? '').toString().trim();
          if (day.isEmpty && start.isEmpty) return '';
          if (day.isEmpty) return start;
          if (start.isEmpty) return day;
          return '$day $start';
        })
        .where((e) => e.trim().isNotEmpty)
        .toList();

    if (parts.isEmpty) return 'Schedule: not set';
    return 'Schedule: ${parts.join(' • ')}';
  }

  String _compactScheduleText() {
    if (_deliveryKey == 'recorded') return 'Schedule: On-demand';
    if (_deliveryKey == 'flexible') return 'Schedule: Flexible booking';

    final scheduleRaw = _cls['schedule'];
    if (scheduleRaw is Map) {
      final schedule = scheduleRaw.map((k, v) => MapEntry(k.toString(), v));
      return _weeklyScheduleLine(schedule['sessions']);
    }

    if (_deliveryKey == 'private' || _deliveryKey == 'inclass') {
      return 'Schedule: not set';
    }
    return 'Schedule: -';
  }

  String _compactNextSessionText() {
    final scheduleRaw = _cls['schedule'];
    if (scheduleRaw is! Map) return '';
    final schedule = scheduleRaw.map((k, v) => MapEntry(k.toString(), v));
    final next = _nextOccurrenceFromSchedule(schedule);
    if (next == null) return '';
    return 'Next: ${_fmtDateTimeFromMs(next.start.millisecondsSinceEpoch)}';
  }

  int _attendanceSortMsFromRecord(Map<String, dynamic> rec) {
    final startAt = _asInt(rec['startAt']);
    if (startAt > 0) return startAt;

    final dateRaw = (rec['date'] ?? rec['dayKey'] ?? '').toString().trim();
    final timeRaw = (rec['time'] ?? '').toString().trim();

    int? parsed;
    if (dateRaw.isNotEmpty && timeRaw.isNotEmpty) {
      parsed = _tryParseYmdHmToMillis(dateRaw, timeRaw);
    }
    parsed ??= _tryParseDateTimeTextToMillis(dateRaw);
    if (parsed != null && parsed > 0) return parsed;

    final createdAt = rec['createdAt'] ?? rec['created_at'];
    if (createdAt is num) return createdAt.toInt();
    final updatedAt = rec['updatedAt'];
    if (updatedAt is num) return updatedAt.toInt();

    return 0;
  }

  int _weekdayFromShort(String day) {
    switch (day.trim().toLowerCase()) {
      case 'mon':
      case 'monday':
        return DateTime.monday;
      case 'tue':
      case 'tues':
      case 'tuesday':
        return DateTime.tuesday;
      case 'wed':
      case 'wednesday':
        return DateTime.wednesday;
      case 'thu':
      case 'thur':
      case 'thurs':
      case 'thursday':
        return DateTime.thursday;
      case 'fri':
      case 'friday':
        return DateTime.friday;
      case 'sat':
      case 'saturday':
        return DateTime.saturday;
      case 'sun':
      case 'sunday':
        return DateTime.sunday;
      default:
        return 0;
    }
  }

  ({DateTime start, int duration})? _nextOccurrenceFromSchedule(
    Map<String, dynamic> schedule,
  ) {
    final firstRaw = (schedule['first_session_date'] ?? '').toString().trim();
    final firstDate = DateTime.tryParse(firstRaw);
    if (firstDate == null) return null;

    final sessionsRaw = schedule['sessions'];
    final nodes = <Map<String, dynamic>>[];
    if (sessionsRaw is List) {
      for (final s in sessionsRaw) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    } else if (sessionsRaw is Map) {
      for (final s in sessionsRaw.values) {
        if (s is! Map) continue;
        nodes.add(s.map((k, v) => MapEntry(k.toString(), v)));
      }
    }
    if (nodes.isEmpty) return null;

    final now = DateTime.now();
    final firstDay = DateTime(firstDate.year, firstDate.month, firstDate.day);
    DateTime? best;
    int bestDur = 60;

    for (int i = 0; i <= 35; i++) {
      final day = DateTime(now.year, now.month, now.day).add(Duration(days: i));
      if (day.isBefore(firstDay)) continue;
      for (final n in nodes) {
        final wd = _weekdayFromShort((n['day'] ?? '').toString());
        if (wd <= 0 || wd != day.weekday) continue;
        final hm = (n['start_time'] ?? '').toString().trim().split(':');
        if (hm.length != 2) continue;
        final h = int.tryParse(hm[0]);
        final m = int.tryParse(hm[1]);
        if (h == null || m == null) continue;
        final start = DateTime(day.year, day.month, day.day, h, m);
        final dur = _asInt(n['duration_min']);
        final safeDur = dur > 0 ? dur : 60;
        final end = start.add(Duration(minutes: safeDur));
        if (end.isBefore(now)) continue;
        if (best == null || start.isBefore(best)) {
          best = start;
          bestDur = safeDur;
        }
      }
    }

    if (best == null) return null;
    return (start: best, duration: bestDur);
  }

  Future<void> _openExternalUrl(String url) async {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    final uri = Uri.tryParse(u);
    if (uri == null) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Invalid meeting link.')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
  }

  String _bestTeacherUidFromClassNode(Map<String, dynamic> classNode) {
    String teacherUid =
        (classNode['teacherUid'] ??
                classNode['teacher_uid'] ??
                classNode['teacherId'] ??
                classNode['teacher_id'] ??
                _cls['teacherUid'] ??
                _cls['teacherId'] ??
                '')
            .toString()
            .trim();

    if (teacherUid.isEmpty && classNode['instructor_current'] is Map) {
      teacherUid =
          (Map<String, dynamic>.from(
                    classNode['instructor_current'] as Map,
                  )['uid'] ??
                  '')
              .toString()
              .trim();
    }

    if (teacherUid.isEmpty && classNode['attendance'] is Map) {
      final att = Map<dynamic, dynamic>.from(classNode['attendance'] as Map);
      int bestTs = 0;
      String bestUid = '';
      for (final e in att.entries) {
        if (e.value is! Map) continue;
        final m = Map<String, dynamic>.from(e.value as Map);
        final uid =
            (m['teacherUid'] ??
                    m['teacher_uid'] ??
                    m['teacherId'] ??
                    m['teacher_id'] ??
                    '')
                .toString()
                .trim();
        if (uid.isEmpty) continue;
        final ts = _asInt(m['updatedAt']);
        if (ts >= bestTs) {
          bestTs = ts;
          bestUid = uid;
        }
      }
      if (bestUid.isNotEmpty) teacherUid = bestUid;
    }

    return teacherUid;
  }

  Future<_TeacherMiniProfile?> _loadTeacherProfile() async {
    Map<String, dynamic> classNode = <String, dynamic>{};
    if (_classId.trim().isNotEmpty) {
      try {
        final cs = await _classesRef.child(_classId).get();
        if (cs.exists && cs.value is Map) {
          classNode = Map<String, dynamic>.from(cs.value as Map);
        }
      } catch (_) {}
    }

    final teacherUid = _bestTeacherUidFromClassNode(classNode);
    if (teacherUid.isEmpty) return null;

    String displayName =
        (classNode['teacherName'] ??
                classNode['teacher_name'] ??
                classNode['instructor'] ??
                '')
            .toString()
            .trim();

    String photoUrl = '';
    String aboutMe = '';
    String introVideoUrl = '';
    bool socialVisible = true;
    final socialLinks = <String, String>{};

    try {
      final snap = await _usersRef.child(teacherUid).get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry('$k', v));
        final first = (m['first_name'] ?? m['firstName'] ?? '')
            .toString()
            .trim();
        final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
        final full = '$first $last'.trim();
        final email = (m['email'] ?? '').toString().trim();
        if (displayName.isEmpty) {
          displayName = full.isNotEmpty
              ? full
              : (email.isNotEmpty ? email : 'Teacher');
        }

        photoUrl = ProfileAvatar.resolvePhotoFromMap(m);
        aboutMe = (m['about_me'] ?? '').toString().trim();
        introVideoUrl = (m['intro_video_url'] ?? '').toString().trim();
        socialVisible = m['social_links_visible_to_learners'] != false;

        final rawSocial = m['social_links'];
        if (socialVisible && rawSocial is Map) {
          rawSocial.forEach((k, v) {
            final key = k.toString().trim().toLowerCase();
            final val = (v ?? '').toString().trim();
            if (key.isNotEmpty && val.isNotEmpty) {
              socialLinks[key] = val;
            }
          });
        }
      }
    } catch (_) {}

    if (displayName.isEmpty) displayName = 'Teacher';

    return _TeacherMiniProfile(
      uid: teacherUid,
      name: displayName,
      photoUrl: photoUrl,
      aboutMe: aboutMe,
      introVideoUrl: introVideoUrl,
      socialVisible: socialVisible,
      socialLinks: socialLinks,
    );
  }

  String _normalizeExternalUrl(String url) {
    var out = url.trim();
    if (out.isEmpty) return '';
    if (!out.startsWith('http://') && !out.startsWith('https://')) {
      out = 'https://$out';
    }
    return out;
  }

  Future<void> _openTeacherLink(String url, {String label = 'link'}) async {
    final normalized = _normalizeExternalUrl(url);
    if (normalized.isEmpty) return;
    final uri = Uri.tryParse(normalized);
    if (uri == null) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Invalid $label URL.')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Could not open $label.')),
      );
    }
  }

  Future<void> _openSecureMiniVideo({
    required String url,
    String title = 'Watch',
  }) async {
    final clean = url.trim();
    if (clean.isEmpty) return;
    if (!mounted) return;
    try {
      await SecureWindowService.setSecureEnabled(true);
    } catch (_) {}
    if (!mounted) return;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _MiniSecureVideoSheet(title: title, url: clean),
      );
    } finally {
      try {
        await SecureWindowService.setSecureEnabled(false);
      } catch (_) {}
    }
  }

  Future<String> _myDisplayName() async {
    final authUser = FirebaseAuth.instance.currentUser;
    final fromAuth = (authUser?.displayName ?? '').trim();
    if (fromAuth.isNotEmpty) return fromAuth;

    try {
      final snap = await _usersRef.child(_uid).get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry('$k', v));
        final first = (m['first_name'] ?? '').toString().trim();
        final last = (m['last_name'] ?? '').toString().trim();
        final full = '$first $last'.trim();
        if (full.isNotEmpty) return full;
      }
    } catch (_) {}

    final email = (authUser?.email ?? '').trim();
    if (email.isNotEmpty) return email;
    return 'Learner';
  }

  Future<void> _notifyTeacherJoinTap(_DetailPrivateMeta meta) async {
    final learnerUid = _uid.trim();
    final teacherUid = meta.teacherUid.trim();
    if (learnerUid.isEmpty || teacherUid.isEmpty) return;

    try {
      final learnerName = await _myDisplayName();
      await LearnerJoinSignalService.notifyTeacherJoinTap(
        learnerUid: learnerUid,
        teacherUid: teacherUid,
        learnerName: learnerName,
        source: 'learner/learner_course_detail',
        courseId: _courseId,
        courseTitle: _courseTitle,
        sessionStartMs: meta.nextStart?.millisecondsSinceEpoch ?? 0,
      );
    } catch (_) {}
  }

  Future<String> _createThreadWithTeacher(_TeacherMiniProfile teacher) async {
    final threadId = _db.child('mail_threads').push().key;
    if (threadId == null || threadId.trim().isEmpty) {
      throw Exception('Failed to create thread.');
    }

    final subject =
        'Course: ${_courseTitle.trim().isEmpty ? 'Message' : _courseTitle.trim()}';
    const placeholderLastMessage = '(No messages yet)';
    final now = DateTime.now().millisecondsSinceEpoch;
    final myName = await _myDisplayName();

    final Map<String, dynamic> updates = {
      'mail_threads/$threadId/subject': subject,
      'mail_threads/$threadId/type': 'mail',
      'mail_threads/$threadId/createdAt': now,
      'mail_threads/$threadId/updatedAt': now,
      'mail_threads/$threadId/lastMessage': placeholderLastMessage,
      'mail_threads/$threadId/participants/$_uid': true,
      'mail_threads/$threadId/participants/${teacher.uid}': true,

      'mail_index/$_uid/$threadId/subject': subject,
      'mail_index/$_uid/$threadId/type': 'mail',
      'mail_index/$_uid/$threadId/updatedAt': now,
      'mail_index/$_uid/$threadId/lastMessage': placeholderLastMessage,
      'mail_index/$_uid/$threadId/unreadCount': 0,
      'mail_index/$_uid/$threadId/peerUid': teacher.uid,
      'mail_index/$_uid/$threadId/peerName': teacher.name,
      'mail_index/$_uid/$threadId/peerRole': 'teacher',
      'mail_index/$_uid/$threadId/deletedAt': null,

      'mail_index/${teacher.uid}/$threadId/subject': subject,
      'mail_index/${teacher.uid}/$threadId/type': 'mail',
      'mail_index/${teacher.uid}/$threadId/updatedAt': now,
      'mail_index/${teacher.uid}/$threadId/lastMessage': placeholderLastMessage,
      'mail_index/${teacher.uid}/$threadId/unreadCount': 1,
      'mail_index/${teacher.uid}/$threadId/peerUid': _uid,
      'mail_index/${teacher.uid}/$threadId/peerName': myName,
      'mail_index/${teacher.uid}/$threadId/peerRole': 'learner',
      'mail_index/${teacher.uid}/$threadId/deletedAt': null,

      'mail_state/$_uid/$threadId/lastReadAt': now,
      'mail_state/$_uid/$threadId/lastDeliveredAt': now,
      'mail_state/${teacher.uid}/$threadId/lastDeliveredAt': now,
    };

    await _db.update(updates);
    unawaited(() async {
      try {
        await PushDispatchService.dispatchMailToUser(
          targetUid: teacher.uid,
          threadId: threadId,
          peerUid: _uid,
          title: subject,
          preview: 'New topic',
          nowMs: now,
          context: const PushDispatchContext(
            screen: 'learner/learner_course_detail',
            action: 'mail_push',
          ),
        );
      } catch (_) {}
    }());
    return threadId;
  }

  Future<void> _mailTeacherDirectly() async {
    if (_mailingTeacher) return;

    setState(() => _mailingTeacher = true);

    try {
      final teachers = await _loadAssignedTeachersForMessaging();
      if (!mounted) return;
      if (teachers.isEmpty) {
        AppToast.fromSnackBar(
          context,
          const SnackBar(
            content: Text('No assigned teachers for this course.'),
          ),
        );
        return;
      }
      final picked = await _pickTeacherForMail(teachers);
      if (picked == null || !mounted) return;
      final threadId = await _createThreadWithTeacher(picked);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LearnerMailThreadScreen(
            threadId: threadId,
            peerUid: picked.uid,
            peerName: picked.name,
            subject:
                'Course: ${_courseTitle.trim().isEmpty ? 'Message' : _courseTitle.trim()}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Could not open teacher mail: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _mailingTeacher = false);
      }
    }
  }

  Future<List<_TeacherMiniProfile>> _loadAssignedTeachersForMessaging() async {
    final out = <_TeacherMiniProfile>[];
    try {
      final classId = _classId.trim();
      final learnerUid = _uid.trim();
      if (classId.isEmpty || learnerUid.isEmpty) return out;

      final classSnap = await _classesRef.child(classId).get();
      if (!classSnap.exists || classSnap.value is! Map) return out;
      final classNode = (classSnap.value as Map).map(
        (k, v) => MapEntry('$k', v),
      );

      final learnersRaw = classNode['learners'];
      final learners = learnersRaw is Map
          ? Map<dynamic, dynamic>.from(learnersRaw)
          : <dynamic, dynamic>{};
      if (!learners.containsKey(learnerUid)) return out;

      final teacherUid = _bestTeacherUidFromClassNode(classNode).trim();
      if (teacherUid.isEmpty || teacherUid == learnerUid) return out;

      final teacherSnap = await _usersRef.child(teacherUid).get();
      if (!teacherSnap.exists || teacherSnap.value is! Map) return out;
      final m = (teacherSnap.value as Map).map((k, v) => MapEntry('$k', v));
      final roleRaw = (m['role'] ?? '').toString().trim().toLowerCase();
      final role = roleRaw == 'instructor' ? 'teacher' : roleRaw;
      if (role != 'teacher') return out;

      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = '$first $last'.trim();
      final email = (m['email'] ?? '').toString().trim();
      final name = full.isNotEmpty
          ? full
          : (email.isNotEmpty ? email : 'Teacher');

      out.add(
        _TeacherMiniProfile(
          uid: teacherUid,
          name: name,
          photoUrl: ProfileAvatar.resolvePhotoFromMap(m),
          aboutMe: '',
          introVideoUrl: '',
          socialVisible: false,
          socialLinks: const <String, String>{},
        ),
      );

      return out;
    } catch (_) {
      return out;
    }
  }

  Future<_TeacherMiniProfile?> _pickTeacherForMail(
    List<_TeacherMiniProfile> teachers,
  ) async {
    return showModalBottomSheet<_TeacherMiniProfile>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) {
        return SafeArea(
          child: SizedBox(
            height: 420,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Choose teacher',
                      style: TextStyle(
                        color: UiK.mainText,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: teachers.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final t = teachers[i];
                      return ListTile(
                        leading: ProfileAvatar(
                          photoUrl: t.photoUrl,
                          name: t.name,
                          radius: 18,
                        ),
                        title: Text(
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: const Text('Teacher'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.pop(context, t),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<_TeacherSocialAction> _socialActions(_TeacherMiniProfile teacher) {
    final actions = <_TeacherSocialAction>[];
    final social = teacher.socialLinks;
    final facebook = (social['facebook'] ?? '').trim();
    final linkedin = (social['linkedin'] ?? '').trim();
    final tiktok = (social['tiktok'] ?? '').trim();
    final extra = (social['extra_url'] ?? '').trim();
    final extraIcon = (social['extra_icon'] ?? '').trim().toLowerCase();

    if (facebook.isNotEmpty) {
      actions.add(
        const _TeacherSocialAction(
          key: 'facebook',
          label: 'Facebook',
          icon: Icons.facebook_rounded,
        ).copyWith(url: facebook),
      );
    }
    if (linkedin.isNotEmpty) {
      actions.add(
        const _TeacherSocialAction(
          key: 'linkedin',
          label: 'LinkedIn',
          icon: Icons.business_center_rounded,
        ).copyWith(url: linkedin),
      );
    }
    if (tiktok.isNotEmpty) {
      actions.add(
        const _TeacherSocialAction(
          key: 'tiktok',
          label: 'TikTok',
          icon: Icons.music_note_rounded,
        ).copyWith(url: tiktok),
      );
    }
    if (extra.isNotEmpty) {
      IconData icon = Icons.public_rounded;
      if (extraIcon == 'youtube') icon = Icons.ondemand_video_rounded;
      if (extraIcon == 'instagram') icon = Icons.photo_camera_rounded;
      if (extraIcon == 'telegram') icon = Icons.send_rounded;
      if (extraIcon == 'whatsapp') icon = Icons.chat_rounded;

      actions.add(
        _TeacherSocialAction(
          key: 'extra',
          label: 'More',
          icon: icon,
          url: extra,
        ),
      );
    }

    if (teacher.introVideoUrl.trim().isNotEmpty) {
      actions.add(
        _TeacherSocialAction(
          key: 'intro',
          label: 'Intro Video',
          icon: Icons.play_circle_fill_rounded,
          url: teacher.introVideoUrl,
        ),
      );
    }

    return actions;
  }

  Future<void> _openTeacherFloatingCard() async {
    final teacher = _teacherProfile;
    if (teacher == null) return;
    final actions = teacher.socialVisible
        ? _socialActions(teacher)
        : const <_TeacherSocialAction>[];

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Teacher profile',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, _, _) {
        final width = MediaQuery.of(ctx).size.width;
        final maxCardWidth = width >= 980 ? 520.0 : 460.0;
        return SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxCardWidth),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: UiK.uiBorder.withValues(alpha: 0.9),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.14),
                          blurRadius: 28,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ProfileAvatar(
                                name: teacher.name,
                                photoUrl: teacher.photoUrl,
                                radius: 30,
                                fallbackBg: UiK.primaryBlue.withValues(
                                  alpha: 0.12,
                                ),
                                fallbackFg: UiK.primaryBlue,
                                borderColor: UiK.uiBorder.withValues(
                                  alpha: 0.9,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      teacher.name,
                                      style: const TextStyle(
                                        color: UiK.mainText,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 18,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Teacher profile',
                                      style: UiK.subtleText(),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () => Navigator.of(ctx).pop(),
                              ),
                            ],
                          ),
                          if (teacher.aboutMe.trim().isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: UiK.uiBorder.withValues(alpha: 0.8),
                                ),
                                color: UiK.primaryBlue.withValues(alpha: 0.04),
                              ),
                              child: Text(
                                teacher.aboutMe,
                                style: UiK.subtleText(),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Text(
                            'Social & Links',
                            style: UiK.labelText().copyWith(
                              color: UiK.mainText,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (!teacher.socialVisible)
                            Text(
                              'This teacher has hidden social links.',
                              style: UiK.subtleText(),
                            )
                          else if (actions.isEmpty)
                            Text(
                              'No public links yet.',
                              style: UiK.subtleText(),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: actions
                                  .map<Widget>(
                                    (a) => OutlinedButton.icon(
                                      onPressed: () {
                                        if (a.key == 'intro') {
                                          _openSecureMiniVideo(
                                            url: a.url,
                                            title: 'Teacher Intro',
                                          );
                                          return;
                                        }
                                        _openTeacherLink(a.url, label: a.label);
                                      },
                                      icon: Icon(a.icon, size: 18),
                                      label: Text(
                                        a.key == 'intro' ? 'Watch' : a.label,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Widget _teacherContactSection() {
    final teacher = _teacherProfile;
    if (teacher == null || teacher.uid.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
        color: Colors.white,
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _openTeacherFloatingCard,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    ProfileAvatar(
                      name: teacher.name,
                      photoUrl: teacher.photoUrl,
                      radius: 18,
                      fallbackBg: UiK.primaryBlue.withValues(alpha: 0.12),
                      fallbackFg: UiK.primaryBlue,
                      borderColor: UiK.uiBorder.withValues(alpha: 0.9),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Teacher',
                            style: TextStyle(
                              color: UiK.mainText,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            teacher.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: UiK.subtleText(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _mailingTeacher ? null : _mailTeacherDirectly,
            icon: _mailingTeacher
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.mail_rounded),
            label: const Text('Mail'),
            style: FilledButton.styleFrom(
              backgroundColor: UiK.actionOrange,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Future<_DetailPrivateMeta?> _loadPrivateJoinMeta() async {
    if (!_isPrivateOnlineCourse) return null;
    if (_classId.trim().isEmpty) return null;

    Map<String, dynamic> classNode = <String, dynamic>{};
    try {
      final cs = await _classesRef.child(_classId).get();
      if (cs.exists && cs.value is Map) {
        classNode = Map<String, dynamic>.from(cs.value as Map);
      }
    } catch (_) {}

    final scheduleRaw = _cls['schedule'] ?? classNode['schedule'];
    if (scheduleRaw is! Map) return null;
    final schedule = scheduleRaw.map((k, v) => MapEntry(k.toString(), v));

    final scheduleLine = _weeklyScheduleLine(schedule['sessions']);
    final next = _nextOccurrenceFromSchedule(schedule);

    final teacherUid = _bestTeacherUidFromClassNode(classNode);

    String meetUrl = '';
    if (teacherUid.isNotEmpty) {
      try {
        final ms = await _usersRef
            .child(teacherUid)
            .child('google_meet_url')
            .get();
        meetUrl = (ms.value ?? '').toString().trim();
      } catch (_) {}
    }

    return _DetailPrivateMeta(
      scheduleLine: scheduleLine,
      nextStart: next?.start,
      durationMinutes: next?.duration ?? 60,
      meetUrl: meetUrl,
      teacherUid: teacherUid,
    );
  }

  int _sessionsConsumedForPayment({
    required int held,
    required int present,
    required int onlineConsumed,
  }) {
    final studyType = _deliveryKey;
    if (studyType == 'inclass') return held;
    if (studyType == 'private') return present;
    if (studyType == 'flexible') return onlineConsumed;
    return present;
  }

  int _studyTypeExpiresAtMs() {
    final studyType = _deliveryKey;
    if (studyType == 'flexible') {
      final node = (_course['flexible_access'] is Map)
          ? Map<String, dynamic>.from(_course['flexible_access'] as Map)
          : <String, dynamic>{};
      return _asInt(node['expiresAt']);
    }
    if (studyType == 'recorded') {
      final node = (_course['recorded_access'] is Map)
          ? Map<String, dynamic>.from(_course['recorded_access'] as Map)
          : <String, dynamic>{};
      return _asInt(node['expiresAt']);
    }
    return 0;
  }

  bool _isExpiredMs(int ms) {
    if (ms <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch >= ms;
  }

  bool _isNearExpiryMs(int ms, {int days = 3}) {
    if (ms <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = ms - now;
    if (diff <= 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  DatabaseReference get _paymentSummaryRef => _usersRef
      .child(_uid)
      .child('courses')
      .child(widget.courseKey)
      .child('payment_summary');

  // ✅ NEW: online attendance ref for this learner + course
  DatabaseReference get _onlineAttendanceRef =>
      _db.child('$bookingProgressNode/$_uid/$_courseId/online_attendance');

  int? _plannedMeetingsFromCourseOrClass(Map<String, dynamic> course) {
    // try in course/class snapshot first
    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    dynamic v;

    // direct
    v = cls['meetingsCount'] ?? cls['totalMeetings'] ?? cls['sessionsCount'];
    int n = _asInt(v);
    if (n > 0) return n;

    // inside schedule
    final schedule = cls['schedule'];
    if (schedule is Map) {
      final s = Map<String, dynamic>.from(schedule);
      v = s['meetingsCount'] ?? s['totalMeetings'] ?? s['sessionsCount'];
      n = _asInt(v);
      if (n > 0) return n;
    }

    return null;
  }

  Future<int?> _fetchPlannedMeetingsFromClassesNode(String classId) async {
    if (classId.trim().isEmpty) return null;
    try {
      final snap = await _classesRef.child(classId).child('schedule').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return null;
      final m = Map<String, dynamic>.from(snap.value as Map);
      final n = _asInt(
        m['meetingsCount'] ?? m['totalMeetings'] ?? m['sessionsCount'],
      );
      return n > 0 ? n : null;
    } catch (_) {
      return null;
    }
  }

  // -------------------- Load (keeps your working logic) --------------------

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _course = {};
      _onlineAttendance = [];
      _attendanceAll = [];
      _syllabiFlat = [];
      _coveredSessionIds = {};
      _sessionIdByNumber = {};
      _sessionTitleByNumber = {};
      _sessionReviewsByNo = {};
      _courseBookUrl = '';
      _plannedMeetings = null;
      _derivedSessionsPaidTotal = 0;
      _derivedSessionsReady = false;
      _privateMetaFuture = null;
      _teacherProfile = null;
      _mailingTeacher = false;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      // ✅ start payment listener (safe: one listener only)
      await _paySub?.cancel();
      _payLoading = true;

      _paySub = _paymentSummaryRef.onValue.listen(
        (event) {
          final raw = event.snapshot.value;
          final sum = raw is Map
              ? raw.map((k, v) => MapEntry(k.toString(), v))
              : <String, dynamic>{};

          if (!mounted) return;
          setState(() {
            _paymentSummary = Map<String, dynamic>.from(sum);
            _payLoading = false;
          });
        },
        onError: (_) {
          if (!mounted) return;
          setState(() {
            _paymentSummary = {};
            _payLoading = false;
          });
        },
      );

      // Reload course live (so it reflects new attendance/payment_summary)
      final snap = await _usersRef
          .child(_uid)
          .child('courses')
          .child(widget.courseKey)
          .get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        throw Exception('Course not found.');
      }
      _course = Map<String, dynamic>.from(snap.value as Map);
      _teacherProfile = await _loadTeacherProfile();

      // ✅ planned meetings (recommendation feature)
      _plannedMeetings = _plannedMeetingsFromCourseOrClass(_course);
      _plannedMeetings ??= await _fetchPlannedMeetingsFromClassesNode(_classId);

      // --------------------
      // Load syllabi flat list FIRST (so we can map sessionNo -> sessionId for online)
      // --------------------
      if (_courseId.isNotEmpty) {
        final rootSyllabusRef = _syllabiRef.child(_courseId);

        final List<String> variantCandidates = [];

        void addCandidate(String v) {
          final x = v.trim();
          if (x.isEmpty) return;
          if (!variantCandidates.contains(x)) variantCandidates.add(x);
        }

        final rootVariant = (_course['variantKey'] ?? _course['variant'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        final classMap = (_course['class'] is Map)
            ? Map<String, dynamic>.from(_course['class'] as Map)
            : <String, dynamic>{};

        final classVariant =
            (classMap['variantKey'] ?? classMap['variant'] ?? '')
                .toString()
                .trim()
                .toLowerCase();

        addCandidate(rootVariant);
        addCandidate(classVariant);
        addCandidate(_deliveryKey);
        addCandidate(_syllabusVariantKey);

        if (_deliveryKey == 'private') {
          if (_studyMode == 'online') {
            addCandidate('private');
            addCandidate('online');
          } else if (_studyMode == 'inclass') {
            addCandidate('private');
            addCandidate('inclass');
            addCandidate('in_class');
          } else {
            addCandidate('private');
            addCandidate('online');
          }
        }

        if (_deliveryKey == 'flexible') {
          addCandidate('flexible');
          addCandidate('online');
        }

        if (_deliveryKey == 'inclass') {
          addCandidate('inclass');
          addCandidate('in_class');
        }

        if (_deliveryKey == 'recorded') {
          addCandidate('recorded');
        }

        DataSnapshot? sSnap;

        for (final key in variantCandidates) {
          final testSnap = await rootSyllabusRef.child(key).get();
          if (testSnap.exists &&
              testSnap.value != null &&
              testSnap.value is Map) {
            sSnap = testSnap;
            break;
          }
        }

        sSnap ??= await rootSyllabusRef.get();

        if (sSnap.exists && sSnap.value != null && sSnap.value is Map) {
          final s = Map<String, dynamic>.from(sSnap.value as Map);
          final courseBookMap = (s['courseBook'] is Map)
              ? Map<String, dynamic>.from(s['courseBook'] as Map)
              : const <String, dynamic>{};
          _courseBookUrl = (courseBookMap['url'] ?? '').toString().trim();
          final List<Map<String, dynamic>> flat = [];
          final modules = s['modules'];
          if (modules is List) {
            for (int mi = 0; mi < modules.length; mi++) {
              final m = modules[mi];
              if (m is! Map) continue;
              final module = Map<String, dynamic>.from(m);
              final moduleLabel =
                  (module['otherTitle'] ?? '').toString().trim().isNotEmpty
                  ? (module['otherTitle'] ?? '').toString()
                  : ((module['title'] ?? '').toString().trim().isNotEmpty
                        ? (module['title'] ?? '').toString()
                        : 'Module ${mi + 1}');
              final units = module['units'];
              if (units is! List) continue;
              for (final u in units) {
                if (u is! Map) continue;
                final unit = Map<String, dynamic>.from(u);
                final unitId = (unit['id'] ?? '').toString();
                final unitTitle = (unit['title'] ?? '').toString();
                final unitDesc = (unit['description'] ?? '').toString();
                final unitOrder = unit['order'] ?? 0;
                final lessons = unit['lessons'];
                if (lessons is! List) continue;
                for (final ss in lessons) {
                  if (ss is! Map) continue;
                  final sess = Map<String, dynamic>.from(ss);
                  flat.add({
                    'unitOrder': unitOrder,
                    'unitId': unitId,
                    'unitTitle': unitTitle,
                    'unitDescription': unitDesc,
                    'unitOtherTitle': moduleLabel,
                    'order': sess['order'] ?? 0,
                    'sessionId': (sess['id'] ?? '').toString(),
                    'title': (sess['title'] ?? '').toString(),
                    'sessionNumber': sess['sessionNumber'] ?? 0,
                    'skillType': (sess['skillType'] ?? '').toString(),
                    'objective': (sess['objective'] ?? '').toString(),
                    'content': (sess['content'] ?? '').toString(),
                    'homework': (sess['homework'] ?? '').toString(),
                    'materialsUrl': (sess['materialsUrl'] ?? '').toString(),
                    'homeworkUrl': (sess['homeworkUrl'] ?? '').toString(),
                    'durationMinutes': sess['durationMinutes'] ?? 0,
                  });
                }
              }
            }
          } else {
            final units = s['units'];
            if (units is List) {
              for (final u in units) {
                if (u is! Map) continue;
                final unit = Map<String, dynamic>.from(u);
                final unitId = (unit['id'] ?? '').toString();
                final unitTitle = (unit['title'] ?? '').toString();
                final unitDesc = (unit['description'] ?? '').toString();
                final unitOtherTitle = (unit['otherTitle'] ?? '').toString();
                final unitOrder = unit['order'] ?? 0;

                final sessions = unit['sessions'];
                if (sessions is List) {
                  for (final ss in sessions) {
                    if (ss is! Map) continue;
                    final sess = Map<String, dynamic>.from(ss);
                    flat.add({
                      'unitOrder': unitOrder,
                      'unitId': unitId,
                      'unitTitle': unitTitle,
                      'unitDescription': unitDesc,
                      'unitOtherTitle': unitOtherTitle,
                      'order': sess['order'] ?? 0,
                      'sessionId': (sess['id'] ?? '').toString(),
                      'title': (sess['title'] ?? '').toString(),
                      'sessionNumber': sess['sessionNumber'] ?? 0,
                      'skillType': (sess['skillType'] ?? '').toString(),
                      'objective': (sess['objective'] ?? '').toString(),
                      'content': (sess['content'] ?? '').toString(),
                      'homework': (sess['homework'] ?? '').toString(),
                      'materialsUrl': (sess['materialsUrl'] ?? '').toString(),
                      'homeworkUrl': (sess['homeworkUrl'] ?? '').toString(),
                      'durationMinutes': sess['durationMinutes'] ?? 0,
                    });
                  }
                }
              }
            }
          }

          int n(dynamic v) =>
              (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
          flat.sort((a, b) {
            final uo = n(a['unitOrder']).compareTo(n(b['unitOrder']));
            if (uo != 0) return uo;
            return n(a['order']).compareTo(n(b['order']));
          });

          _syllabiFlat = flat;

          _sessionIdByNumber = {};
          _sessionTitleByNumber = {};
          for (final s in _syllabiFlat) {
            final sn = _asInt(s['sessionNumber']);
            final sid = (s['sessionId'] ?? '').toString().trim();
            final title = (s['title'] ?? '').toString().trim();

            if (sn > 0) {
              if (sid.isNotEmpty) _sessionIdByNumber[sn] = sid;
              if (title.isNotEmpty) _sessionTitleByNumber[sn] = title;
            }
          }
        }
      }
      // --------------------
      // Attendance list (IN-CLASS) - your existing logic (kept)
      // --------------------
      final att = _course['attendance'];
      final List<Map<String, dynamic>> attList = [];
      final Set<String> covered = {}; // syllabus covered (merge both sources)

      if (att is Map) {
        final m = Map<String, dynamic>.from(att);
        for (final entry in m.entries) {
          final meetingId = entry.key.toString();
          if (entry.value is! Map) continue;

          final rec = Map<String, dynamic>.from(entry.value as Map);

          // ✅ parse taughtItems (preferred)
          final taughtItems = rec['taughtItems'];
          final List<Map<String, dynamic>> taughtItemsList = [];
          final List<String> taughtSyllabusTitles = [];
          final List<String> taughtCustomTitles = [];

          bool hasNewFormat = false;
          if (taughtItems is List) {
            hasNewFormat = true;

            for (final it in taughtItems) {
              if (it is! Map) continue;
              final item = Map<String, dynamic>.from(it);
              final type = (item['type'] ?? '').toString().trim().toLowerCase();

              final String title = (item['title'] ?? item['name'] ?? '')
                  .toString()
                  .trim();
              final String sid = (item['sessionId'] ?? '').toString().trim();
              final int sn = _asInt(
                item['sessionNumber'],
              ); // fallback if sessionId missing
              taughtItemsList.add(item);

              if (type == 'syllabus') {
                if (sid.isNotEmpty) {
                  covered.add(sid);
                } else if (sn > 0) {
                  final mapped = _sessionIdByNumber[sn];
                  if (mapped != null && mapped.isNotEmpty) covered.add(mapped);
                }

                if (title.isNotEmpty) taughtSyllabusTitles.add(title);
              } else if (type == 'custom') {
                if (title.isNotEmpty) taughtCustomTitles.add(title);
              }
            }
          }

          // ✅ old single taught map
          final taughtOld = (rec['taught'] is Map)
              ? Map<String, dynamic>.from(rec['taught'] as Map)
              : <String, dynamic>{};
          if (!hasNewFormat) {
            final taughtSessionId = (taughtOld['sessionId'] ?? '')
                .toString()
                .trim();
            final taughtSn = _asInt(taughtOld['sessionNumber']); // fallback

            if (taughtSessionId.isNotEmpty) {
              covered.add(taughtSessionId);
            } else if (taughtSn > 0) {
              final mapped = _sessionIdByNumber[taughtSn];
              if (mapped != null && mapped.isNotEmpty) covered.add(mapped);
            }
          }

          // ✅ build taught summary string for Attendance UI
          String taughtSummary = '';
          if (hasNewFormat) {
            final parts = <String>[];
            if (taughtSyllabusTitles.isNotEmpty) {
              parts.add(taughtSyllabusTitles.join(', '));
            }
            if (taughtCustomTitles.isNotEmpty) {
              parts.add('Notes: ${taughtCustomTitles.join(', ')}');
            }
            taughtSummary = parts.join(' • ');
          } else {
            taughtSummary = (taughtOld['title'] ?? '').toString().trim();
          }

          final sortMs = _attendanceSortMsFromRecord(rec);

          attList.add({
            'source': 'in_class',
            'meetingId': meetingId,
            ...rec,
            'taughtItems': taughtItemsList,
            'taughtSummary': taughtSummary,
            'sortMs': sortMs,
          });
        }
      }

      // --------------------
      // ✅ NEW: Load ONLINE attendance for this learner/course
      // booking_progress/<uid>/<courseId>/online_attendance/<bookingKey>
      // --------------------
      final List<Map<String, dynamic>> onlineList = [];
      if (_courseId.isNotEmpty) {
        try {
          final reviewSnap = await _db
              .child('booking_progress/$_uid/$_courseId/session_reviews')
              .get();
          if (reviewSnap.exists && reviewSnap.value is Map) {
            final rm = Map<String, dynamic>.from(reviewSnap.value as Map);
            final byNo = <int, Map<String, dynamic>>{};
            for (final e in rm.entries) {
              if (e.value is! Map) continue;
              final rec = Map<String, dynamic>.from(e.value as Map);
              final sn = _asInt(rec['sessionNo']);
              if (sn <= 0) continue;
              final rating = _asInt(rec['rating']);
              if (rating < 1 || rating > 5) continue;
              byNo[sn] = rec;
            }
            _sessionReviewsByNo = byNo;
          } else {
            _sessionReviewsByNo = {};
          }
        } catch (_) {
          _sessionReviewsByNo = {};
        }

        try {
          final oSnap = await _onlineAttendanceRef.get();
          if (oSnap.exists && oSnap.value is Map) {
            final om = Map<String, dynamic>.from(oSnap.value as Map);
            for (final e in om.entries) {
              final bookingKey = e.key.toString();
              if (e.value is! Map) continue;
              final rec = Map<String, dynamic>.from(e.value as Map);

              final bool hasPresentFlag = rec.containsKey('present');
              final bool present = rec['present'] == true;

              final int startAt = _asInt(rec['startAt']);
              final String dayKey = (rec['dayKey'] ?? '').toString().trim();
              final String time = (rec['time'] ?? '').toString().trim();
              final int sessionNo = _asInt(rec['sessionNo']);

              // If startAt missing, try dayKey+time
              int sortMs = startAt;
              if (sortMs <= 0 && dayKey.isNotEmpty) {
                final base = _tryParseYmdToMillis(dayKey);
                if (base != null) sortMs = base; // still OK
              }

              // taught summary for online: SessionNo + title from syllabus map if possible
              String taughtSummary = '';
              if (sessionNo > 0) {
                final title = (_sessionTitleByNumber[sessionNo] ?? '').trim();
                taughtSummary = title.isEmpty
                    ? 'Session $sessionNo'
                    : 'Session $sessionNo — $title';

                // Only teacher-confirmed present sessions count as covered.
                if (present) {
                  final sid = _sessionIdByNumber[sessionNo];
                  if (sid != null && sid.isNotEmpty) covered.add(sid);
                }
              }

              // display date for UI
              String dateLabel = '';
              if (startAt > 0) {
                dateLabel = _fmtDateTimeFromMs(startAt);
              } else if (dayKey.isNotEmpty) {
                dateLabel = (time.isEmpty) ? dayKey : '$dayKey  $time';
              }

              final review = sessionNo > 0
                  ? _sessionReviewsByNo[sessionNo]
                  : null;
              final reviewRating = _asInt(review?['rating']);

              onlineList.add({
                'source': 'online',
                'meetingId': bookingKey,
                'date': dateLabel,
                'status': !hasPresentFlag
                    ? 'pending'
                    : (present ? 'present' : 'absent'),
                'taughtSummary': taughtSummary,
                'sessionNo': sessionNo,
                'reviewRating': (reviewRating >= 1 && reviewRating <= 5)
                    ? reviewRating
                    : 0,
                'reviewCreatedAt': _asInt(review?['createdAt']),
                'startAt': startAt,
                'dayKey': dayKey,
                'time': time,
                ...rec,
                'sortMs': sortMs,
              });
            }
          }
        } catch (_) {
          // ignore online read errors (UI will still work for in-class)
        }
      }

      // --------------------
      // finalize state
      // --------------------
      _onlineAttendance = onlineList;

      _coveredSessionIds = covered;
      // ✅ NEW: also include ONLINE taught items (from booking_progress)
      if (_courseId.isNotEmpty) {
        try {
          final onlineSnap = await _db
              .child('booking_progress/$_uid/$_courseId/online_attendance')
              .get();

          if (onlineSnap.exists && onlineSnap.value is Map) {
            final om = Map<String, dynamic>.from(onlineSnap.value as Map);

            for (final entry in om.entries) {
              final v = entry.value;
              if (v is! Map) continue;
              final rec = Map<String, dynamic>.from(v);
              if (rec['present'] != true) continue;

              // Prefer taughtItems if present
              final taughtItems = rec['taughtItems'];
              if (taughtItems is List) {
                for (final it in taughtItems) {
                  if (it is! Map) continue;
                  final item = Map<String, dynamic>.from(it);

                  final type = (item['type'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();
                  if (type != 'syllabus') continue;

                  final sn = _asInt(item['sessionNumber']);
                  final sid = (item['sessionId'] ?? '').toString().trim();

                  if (sid.isNotEmpty) {
                    covered.add(sid);
                  } else if (sn > 0) {
                    final mapped = _sessionIdByNumber[sn];
                    if (mapped != null && mapped.isNotEmpty) {
                      covered.add(mapped);
                    }
                  }
                }
              } else {
                // fallback: sessionNo -> map to sessionId
                final sn = _asInt(rec['sessionNo']);
                if (sn > 0) {
                  final mapped = _sessionIdByNumber[sn];
                  if (mapped != null && mapped.isNotEmpty) covered.add(mapped);
                }
              }
            }

            _coveredSessionIds =
                covered; // refresh after adding online coverage
          }
        } catch (_) {}
      }

      if (_deliveryKey == 'recorded') {
        try {
          final progressSnap = await _usersRef
              .child(_uid)
              .child('courses')
              .child(widget.courseKey)
              .child('recorded_progress')
              .get();
          final recordedCovered = <String>{};
          if (progressSnap.exists && progressSnap.value is Map) {
            final pm = Map<String, dynamic>.from(progressSnap.value as Map);
            bool asBool(dynamic v) {
              if (v is bool) return v;
              final s = (v ?? '').toString().trim().toLowerCase();
              return s == 'true' || s == '1';
            }

            for (final e in pm.entries) {
              final sid = e.key.toString().trim();
              if (sid.isEmpty || e.value is! Map) continue;
              final rec = Map<String, dynamic>.from(e.value as Map);
              final doneVideo = asBool(rec['videoCompleted']);
              final doneMaterials = asBool(rec['materialsCompleted']);
              if (doneVideo || doneMaterials) recordedCovered.add(sid);
            }
          }
          _coveredSessionIds = recordedCovered;
        } catch (_) {
          _coveredSessionIds = <String>{};
        }
      }
      // merge + sort (newest first)
      final all = <Map<String, dynamic>>[];
      all.addAll(attList);
      all.addAll(onlineList);

      all.sort((a, b) {
        final am = _asInt(a['sortMs']);
        final bm = _asInt(b['sortMs']);
        if (am != bm) return bm.compareTo(am); // newest first
        final ad = (a['date'] ?? '').toString();
        final bd = (b['date'] ?? '').toString();
        return bd.compareTo(ad);
      });

      _attendanceAll = all;

      _derivedSessionsPaidTotal = await _deriveSessionsPaidTotalFromPayments();
      _derivedSessionsReady = true;
      _privateMetaFuture = _isPrivateOnlineCourse
          ? _loadPrivateJoinMeta()
          : null;

      if (!mounted) return;
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Map<String, int> _attendanceCountsAll() {
    final total = _attendanceAll.where((x) {
      final status = (x['status'] ?? '').toString().toLowerCase();
      return status == 'present' || status == 'absent';
    }).length;
    final present = _attendanceAll
        .where((x) => (x['status'] ?? '').toString().toLowerCase() == 'present')
        .length;
    return {'total': total, 'present': present};
  }

  void _applySessionReviewToAttendance({
    required int sessionNo,
    required int rating,
    required int createdAt,
    required String teacherName,
  }) {
    if (sessionNo <= 0) return;

    _sessionReviewsByNo[sessionNo] = {
      'sessionNo': sessionNo,
      'rating': rating,
      'createdAt': createdAt,
      'teacherName': teacherName,
    };

    for (final row in _onlineAttendance) {
      if (_asInt(row['sessionNo']) != sessionNo) continue;
      row['reviewRating'] = rating;
      row['reviewCreatedAt'] = createdAt;
    }

    for (final row in _attendanceAll) {
      if ((row['source'] ?? '').toString() != 'online') continue;
      if (_asInt(row['sessionNo']) != sessionNo) continue;
      row['reviewRating'] = rating;
      row['reviewCreatedAt'] = createdAt;
    }
  }

  Future<void> _openSessionReviewSheetForAttendance(
    Map<String, dynamic> row,
  ) async {
    final sessionNo = _asInt(row['sessionNo']);
    if (sessionNo <= 0 || _uid.trim().isEmpty || _courseId.trim().isEmpty) {
      return;
    }

    final isPresent =
        (row['status'] ?? '').toString().toLowerCase().trim() == 'present';
    if (!isPresent) {
      AppToast.show(
        context,
        'You can review this session after attending it.',
        type: AppToastType.error,
      );
      return;
    }

    final teacherName =
        (row['teacherName'] ??
                row['teacherNameFromBooking'] ??
                row['teacher_name'] ??
                '')
            .toString()
            .trim();
    final taughtSummary = (row['taughtSummary'] ?? '').toString().trim();

    int rating = _asInt(row['reviewRating']);
    if (rating < 1 || rating > 5) {
      final saved = _sessionReviewsByNo[sessionNo];
      final savedRating = _asInt(saved?['rating']);
      rating = (savedRating >= 1 && savedRating <= 5) ? savedRating : 5;
    }

    int existingCreatedAt = _asInt(row['reviewCreatedAt']);
    if (existingCreatedAt <= 0) {
      existingCreatedAt = _asInt(_sessionReviewsByNo[sessionNo]?['createdAt']);
    }

    if (!mounted) return;

    bool submitting = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        return StatefulBuilder(
          builder: (context, setD) {
            Future<void> submit() async {
              if (rating < 1 || rating > 5) {
                AppToast.show(
                  context,
                  'Please choose a rating from 1 to 5 stars.',
                  type: AppToastType.error,
                );
                return;
              }

              setD(() => submitting = true);
              try {
                final payload = <String, dynamic>{
                  'sessionNo': sessionNo,
                  'rating': rating,
                  'teacherName': teacherName,
                  'updatedAt': ServerValue.timestamp,
                  'createdAt': existingCreatedAt > 0
                      ? existingCreatedAt
                      : ServerValue.timestamp,
                };

                await _db
                    .child(
                      'booking_progress/$_uid/$_courseId/session_reviews/$sessionNo',
                    )
                    .set(payload);

                final nextCreatedAt = existingCreatedAt > 0
                    ? existingCreatedAt
                    : DateTime.now().millisecondsSinceEpoch;

                if (!mounted) return;
                setState(() {
                  _applySessionReviewToAttendance(
                    sessionNo: sessionNo,
                    rating: rating,
                    createdAt: nextCreatedAt,
                    teacherName: teacherName,
                  );
                });

                if (!context.mounted) return;
                Navigator.pop(context);
                AppToast.show(context, 'Session review submitted.');
              } catch (e) {
                if (!context.mounted) return;
                AppToast.show(
                  context,
                  toHumanError(e),
                  type: AppToastType.error,
                );
              } finally {
                if (context.mounted) {
                  setD(() => submitting = false);
                }
              }
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                media.viewInsets.bottom + media.padding.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    taughtSummary.isEmpty
                        ? 'Session $sessionNo'
                        : taughtSummary,
                    style: const TextStyle(
                      color: UiK.mainText,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Teacher: ${teacherName.isEmpty ? '-' : teacherName}',
                    style: UiK.subtleText(),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Rate this session',
                    style: TextStyle(
                      color: UiK.mainText,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    children: List.generate(5, (i) {
                      final v = i + 1;
                      return IconButton(
                        onPressed: submitting
                            ? null
                            : () => setD(() => rating = v),
                        icon: Icon(
                          v <= rating
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: const Color(0xFFF59E0B),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: submitting ? null : submit,
                      icon: const Icon(Icons.send_rounded),
                      label: Text(
                        submitting ? 'Submitting...' : 'Submit review',
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // -------------------- Progress grouping helper --------------------

  List<Map<String, dynamic>> _groupSyllabiByUnit() {
    final Map<String, Map<String, dynamic>> groups = {};

    int n(dynamic v) =>
        (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    for (final s in _syllabiFlat) {
      final unitId = (s['unitId'] ?? '').toString();
      final unitTitle = (s['unitTitle'] ?? '').toString();
      final unitDesc = (s['unitDescription'] ?? '').toString();
      final unitOrder = n(s['unitOrder']);

      final key = unitId.isNotEmpty ? unitId : 'unit_$unitOrder|$unitTitle';

      groups.putIfAbsent(key, () {
        return {
          'unitId': unitId,
          'unitTitle': unitTitle.isEmpty ? 'Unit' : unitTitle,
          'unitDescription': unitDesc,
          'unitOrder': unitOrder,
          'sessions': <Map<String, dynamic>>[],
        };
      });

      (groups[key]!['sessions'] as List<Map<String, dynamic>>).add(s);
    }

    final list = groups.values.toList();
    list.sort((a, b) => n(a['unitOrder']).compareTo(n(b['unitOrder'])));

    for (final u in list) {
      final sessions = (u['sessions'] as List<Map<String, dynamic>>);
      sessions.sort((a, b) => n(a['order']).compareTo(n(b['order'])));
    }

    return list;
  }

  // -------------------- Homework parsing (UI-only) --------------------

  List<_HwBlock> _parseHomework(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return [];

    final lines = text.replaceAll('\r\n', '\n').split('\n');

    bool isHeader(String l) {
      final t = l.trim();
      if (t.isEmpty) return false;
      final up = t.toUpperCase();
      if (t.startsWith('📘') || t.startsWith('📤') || t.startsWith('✅')) {
        return true;
      }
      if (up.startsWith('PART ')) return true;
      if (up.startsWith('SUBMISSION')) return true;
      if (up.startsWith('FOCUS:')) return true;
      if (up.startsWith('UNIT ')) return true;
      if (up.startsWith('PREP')) return true;
      if (up.startsWith('POST')) return true;
      if (up.startsWith('FINAL')) return true;
      if (t.endsWith(':') && t.length <= 40) return true;
      return false;
    }

    bool isBullet(String l) =>
        l.trimLeft().startsWith('- ') || l.trimLeft().startsWith('• ');

    final List<_HwBlock> blocks = [];
    _HwBlock current = _HwBlock(title: '', lines: []);

    void pushCurrent() {
      final cleaned = current.lines.where((x) => x.trim().isNotEmpty).toList();
      if (current.title.trim().isNotEmpty || cleaned.isNotEmpty) {
        blocks.add(_HwBlock(title: current.title.trim(), lines: cleaned));
      }
    }

    for (final l in lines) {
      final t = l.trimRight();
      if (t.trim().isEmpty) {
        current.lines.add('');
        continue;
      }

      if (isHeader(t)) {
        if (current.title.trim().isNotEmpty ||
            current.lines.any((x) => x.trim().isNotEmpty)) {
          pushCurrent();
        }
        current = _HwBlock(title: t.trim(), lines: []);
        continue;
      }

      if (isBullet(t)) {
        final bl = t.trimLeft();
        final normalized = bl.startsWith('- ')
            ? bl.substring(2)
            : bl.startsWith('• ')
            ? bl.substring(2)
            : bl;
        current.lines.add('• $normalized');
      } else {
        current.lines.add(t.trim());
      }
    }

    pushCurrent();

    for (int i = 0; i < blocks.length; i++) {
      if (blocks[i].title.isEmpty) {
        blocks[i] = blocks[i].copyWith(title: 'Homework');
      }
    }

    return blocks;
  }

  // -------------------- Build --------------------

  Future<void> _openReviewSheet() async {
    if (_uid.trim().isEmpty) return;
    final courseId = _courseId.trim().isEmpty ? widget.courseKey : _courseId;
    final enrolled = await CourseFeedbackService.isUserEnrolledInCourse(
      _uid,
      courseId,
    );
    if (!mounted) return;
    if (!enrolled) {
      AppToast.show(
        context,
        'Only enrolled learners can add a review.',
        type: AppToastType.error,
      );
      return;
    }

    DataSnapshot existing;
    try {
      existing = await FirebaseDatabase.instance
          .ref('course_reviews/$courseId/$_uid')
          .get();
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        humanizeUiMessage(e.toString()),
        type: AppToastType.error,
      );
      return;
    }
    if (!mounted) return;

    int rating = 5;
    String comment = '';
    if (existing.exists && existing.value is Map) {
      final map = Map<String, dynamic>.from(existing.value as Map);
      final parsedRating = CourseFeedbackService.asInt(map['rating']);
      if (parsedRating >= 1 && parsedRating <= 5) rating = parsedRating;
      comment = (map['comment'] ?? '').toString();
    }

    final commentC = TextEditingController(text: comment);
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setD) {
            final media = MediaQuery.of(ctx);
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                media.viewInsets.bottom + media.padding.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Rate this course',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    children: List.generate(5, (i) {
                      final v = i + 1;
                      return IconButton(
                        onPressed: () => setD(() => rating = v),
                        icon: Icon(
                          v <= rating
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: const Color(0xFFF59E0B),
                        ),
                      );
                    }),
                  ),
                  TextField(
                    controller: commentC,
                    maxLength: 500,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Comment',
                      hintText: 'Share your feedback to help others enroll.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        if (commentC.text.trim().isEmpty) {
                          AppToast.show(
                            ctx,
                            'Please add a comment before submitting.',
                            type: AppToastType.error,
                          );
                          return;
                        }
                        Navigator.pop(ctx, true);
                      },
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Submit review'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (submitted != true || !mounted) return;
    try {
      await CourseFeedbackService.upsertCourseReview(
        courseId: courseId,
        uid: _uid,
        rating: rating,
        comment: commentC.text,
      );
      if (!mounted) return;
      AppToast.show(context, 'Your review was submitted for approval.');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        humanizeUiMessage(e.toString()),
        type: AppToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = _attendanceCountsAll();
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );
    final isRecordedCourse = _deliveryKey == 'recorded';

    // ✅ Meetings = attendance records (in-class + online)
    final meetingsHeld = counts['total'] ?? 0;
    final present = counts['present'] ?? 0;
    final onlineConsumed = _attendanceAll.where((x) {
      if ((x['source'] ?? '').toString().toLowerCase() != 'online') {
        return false;
      }
      return onlineAttendanceRecordConsumesCredit(x);
    }).length;
    final sessionsConsumed = _sessionsConsumedForPayment(
      held: meetingsHeld,
      present: present,
      onlineConsumed: onlineConsumed,
    );
    final attPct = meetingsHeld == 0
        ? 0
        : ((present / meetingsHeld) * 100).round();

    // ✅ Syllabus coverage (unique sessionIds) from BOTH sources
    final totalLessons = _syllabiFlat.length;
    final coveredLessons = _coveredSessionIds.length;
    final syllabusPct = totalLessons == 0
        ? 0
        : ((coveredLessons / totalLessons) * 100).round();
    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: Text(
          _courseTitle,
          style: const TextStyle(
            color: UiK.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: const [],
        bottom: null,
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 1480,
        child: WatermarkBackground(
          child: _busy
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
              : isRecordedCourse
              ? _recordedMergedBody()
              : _flexibleMergedBody(
                  desktopWorkspace: desktopWorkspace,
                  meetingsHeld: meetingsHeld,
                  present: present,
                  attPct: attPct,
                  sessionsConsumed: sessionsConsumed,
                  syllabusPct: syllabusPct,
                  coveredLessons: coveredLessons,
                  totalLessons: totalLessons,
                ),
        ),
      ),
      floatingActionButton: null,
    );
  }

  Widget _recordedMergedBody() {
    final mq = MediaQuery.of(context);
    final compact = mq.size.width < 420;
    final veryNarrow = mq.size.width < 370;
    final bottomPad = mq.viewPadding.bottom;

    final units = _groupSyllabiByUnit();
    final totalUnits = units.length;
    int doneUnits = 0;
    final moduleProgress = <String, List<Map<String, dynamic>>>{};
    for (final u in units) {
      final module = (u['unitOtherTitle'] ?? 'Module').toString().trim().isEmpty
          ? 'Module'
          : (u['unitOtherTitle'] ?? 'Module').toString().trim();
      moduleProgress.putIfAbsent(module, () => <Map<String, dynamic>>[]).add(u);
      final sessions =
          (u['sessions'] as List<Map<String, dynamic>>?) ?? const [];
      int covered = 0;
      for (final s in sessions) {
        final sid = (s['sessionId'] ?? '').toString();
        if (_coveredSessionIds.contains(sid)) covered++;
      }
      if (sessions.isNotEmpty && covered == sessions.length) doneUnits++;
    }
    final totalModules = moduleProgress.length;
    int doneModules = 0;
    for (final entry in moduleProgress.entries) {
      final list = entry.value;
      bool allDone = list.isNotEmpty;
      for (final u in list) {
        final sessions =
            (u['sessions'] as List<Map<String, dynamic>>?) ?? const [];
        int covered = 0;
        for (final s in sessions) {
          final sid = (s['sessionId'] ?? '').toString();
          if (_coveredSessionIds.contains(sid)) covered++;
        }
        if (sessions.isEmpty || covered != sessions.length) {
          allDone = false;
          break;
        }
      }
      if (allDone) doneModules++;
    }

    final totalLessons = _syllabiFlat.length;
    final doneLessons = _coveredSessionIds.length;

    final modulePct = totalModules == 0
        ? 0
        : ((doneModules / totalModules) * 100).round();
    final unitPct = totalUnits == 0
        ? 0
        : ((doneUnits / totalUnits) * 100).round();
    final lessonPct = totalLessons == 0
        ? 0
        : ((doneLessons / totalLessons) * 100).round();

    final sum = _paymentSummary;
    final access = (_course['recorded_access'] is Map)
        ? Map<String, dynamic>.from(_course['recorded_access'] as Map)
        : const <String, dynamic>{};
    final accessExpiresAt = _asInt(access['expiresAt']);
    final summaryExpiresAt = _asInt(sum['expiresAt']);
    final effectiveExpiresAt = accessExpiresAt > 0
        ? accessExpiresAt
        : summaryExpiresAt;
    final expiryDue =
        effectiveExpiresAt > 0 && _isExpiredMs(effectiveExpiresAt);
    final expirySoon =
        effectiveExpiresAt > 0 &&
        !expiryDue &&
        _isNearExpiryMs(effectiveExpiresAt);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final daysLeft = effectiveExpiresAt > 0
        ? ((effectiveExpiresAt - nowMs) / Duration.millisecondsPerDay).ceil()
        : 0;
    final paymentPct = effectiveExpiresAt <= 0
        ? 0
        : expiryDue
        ? 0
        : expirySoon
        ? (daysLeft <= 0 ? 0 : (daysLeft * 10).clamp(0, 70))
        : 100;
    final paymentDaysLabel = effectiveExpiresAt <= 0
        ? 'No expiry'
        : expiryDue
        ? 'Expired'
        : '$daysLeft days left';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 14,
              compact ? 10 : 12,
              compact ? 12 : 14,
              compact ? 10 : 12,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                colors: [Color(0xFF052B66), Color(0xFF001A4F)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              children: [
                if (veryNarrow) ...[
                  _recordedActionGrid(compact: true),
                  const SizedBox(height: 10),
                  _recordedProgressPanel(
                    compact: compact,
                    modulePct: modulePct,
                    unitPct: unitPct,
                    lessonPct: lessonPct,
                    paymentPct: paymentPct,
                    paymentLabel: paymentDaysLabel,
                    onTapPayment: () =>
                        _showRecordedPaymentDetails(paymentPct: paymentPct),
                  ),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: compact ? 8 : 12),
                          child: _recordedActionGrid(compact: true),
                        ),
                      ),
                      Expanded(
                        child: _recordedProgressPanel(
                          compact: compact,
                          modulePct: modulePct,
                          unitPct: unitPct,
                          lessonPct: lessonPct,
                          paymentPct: paymentPct,
                          paymentLabel: paymentDaysLabel,
                          onTapPayment: () => _showRecordedPaymentDetails(
                            paymentPct: paymentPct,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              0,
              0,
              bottomPad > 0 ? bottomPad : 8,
            ),
            child: RecordedCourseStudyScreen(
              courseKey: widget.courseKey,
              courseData: _course,
              embedded: true,
              showOverviewCard: false,
            ),
          ),
        ),
      ],
    );
  }

  void _openHomework() {
    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'learner.course_detail.homework.${widget.courseKey}',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LearnerHomeworkScreen(
                courseKey: widget.courseKey,
                courseTitle: _courseTitle,
              ),
            ),
          );
        },
      ),
    );
  }

  void _openFlexibleBooking() {
    if (_courseId.trim().isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Course booking is not available yet.')),
      );
      return;
    }
    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'learner.course_detail.booking.${widget.courseKey}',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LearnerBookingScreen(courseId: _courseId),
            ),
          );
        },
      ),
    );
  }

  Widget _flexibleMergedBody({
    required bool desktopWorkspace,
    required int meetingsHeld,
    required int present,
    required int attPct,
    required int sessionsConsumed,
    required int syllabusPct,
    required int coveredLessons,
    required int totalLessons,
  }) {
    final units = _groupSyllabiByUnit();
    final mq = MediaQuery.of(context);
    final bottomPad = mq.viewPadding.bottom;
    final width = mq.size.width;
    final textScale = mq.textScaler.scale(1.0).clamp(1.0, 1.35);
    final compact = width < 380 || textScale > 1.12;
    final veryNarrow = width < 360;

    final sum = _paymentSummary;
    final sessionsPaidTotal = _asInt(sum['sessionsPaidTotal']);
    final remindBeforeSession = _asInt(sum['remindBeforeSession']);
    final totalPaid = _asInt(sum['totalPaid']);
    final hasPaymentHistory = totalPaid > 0 || sessionsPaidTotal > 0;
    final lastAmount = _asInt(sum['lastAmount']);
    final lastMethod = (sum['lastMethod'] ?? '').toString();
    final lastPaymentAtMs = _asInt(sum['lastPaymentAt']);
    final lastPaymentAt = _fmtDateFromMs(lastPaymentAtMs);
    final derivedSessionsPaidTotal = _derivedSessionsReady
        ? _derivedSessionsPaidTotal
        : 0;
    final mergedSessionsPaidTotal =
        (sessionsPaidTotal >= derivedSessionsPaidTotal)
        ? sessionsPaidTotal
        : derivedSessionsPaidTotal;
    final fallbackSessionsPaid = mergedSessionsPaidTotal <= 0
        ? (hasPaymentHistory ? 8 : 0)
        : 0;
    final effectiveSessionsPaidTotal = mergedSessionsPaidTotal > 0
        ? mergedSessionsPaidTotal
        : fallbackSessionsPaid;
    final hasSessionBalance = effectiveSessionsPaidTotal > 0;
    final left = effectiveSessionsPaidTotal - sessionsConsumed;
    final leftSafe = left < 0 ? 0 : left;
    final isFreeCourse = courseIsFreeBilling(_course);

    final overdue =
        !isFreeCourse &&
        hasSessionBalance &&
        isPaymentDueBySessions(
          sessionsPaidTotal: effectiveSessionsPaidTotal,
          sessionsPresent: sessionsConsumed,
        );
    final dueSoon =
        !isFreeCourse &&
        hasSessionBalance &&
        isPaymentWarningBySessions(
          sessionsPaidTotal: effectiveSessionsPaidTotal,
          sessionsPresent: sessionsConsumed,
          remindBeforeSession: remindBeforeSession,
        );

    final expiresAt = _studyTypeExpiresAtMs();
    final expiryDue = !isFreeCourse && _isExpiredMs(expiresAt);
    final expirySoon =
        !isFreeCourse && !expiryDue && _isNearExpiryMs(expiresAt);

    final progressValue = totalLessons == 0
        ? 0.0
        : (coveredLessons / totalLessons).clamp(0.0, 1.0);
    final paymentLeftValue = hasSessionBalance
        ? (leftSafe / effectiveSessionsPaidTotal).clamp(0.0, 1.0)
        : 0.0;
    final paymentLeftPct = (paymentLeftValue * 100).round();
    final heroPad = compact ? 12.0 : 14.0;
    final ringSize = veryNarrow ? 138.0 : (compact ? 148.0 : 164.0);
    final paymentRingColor = _paymentProgressColor(1 - paymentLeftValue);

    return ListView(
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        12 + (bottomPad > 0 ? bottomPad : 8),
      ),
      children: [
        Container(
          padding: EdgeInsets.all(heroPad),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: const LinearGradient(
              colors: [Color(0xFF052B66), Color(0xFF001A4F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: compact ? 1 : 2),
              if (veryNarrow)
                Column(
                  children: [
                    _heroActionGrid(compact: compact),
                    const SizedBox(height: 8),
                    Center(
                      child: SizedBox(
                        width: ringSize + 20,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: () => _showProgressDetailsPopup(
                                attendance: present.clamp(0, meetingsHeld),
                                sessions: present.clamp(0, meetingsHeld),
                                syllabus: syllabusPct,
                                results: hasSessionBalance ? '$leftSafe' : '-',
                                paid: effectiveSessionsPaidTotal,
                                used: sessionsConsumed,
                                left: leftSafe,
                                paymentLeftPct: paymentLeftPct,
                              ),
                              child: SizedBox(
                                width: ringSize,
                                height: ringSize,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    CircularProgressIndicator(
                                      value: 1,
                                      strokeWidth: compact ? 10 : 12,
                                      backgroundColor: Colors.white.withValues(
                                        alpha: 0.14,
                                      ),
                                      valueColor: AlwaysStoppedAnimation(
                                        Colors.white.withValues(alpha: 0.14),
                                      ),
                                    ),
                                    CircularProgressIndicator(
                                      value: progressValue,
                                      strokeWidth: compact ? 10 : 12,
                                      backgroundColor: Colors.transparent,
                                      valueColor: const AlwaysStoppedAnimation(
                                        Color(0xFF57B0FF),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: CircularProgressIndicator(
                                        value: paymentLeftValue,
                                        strokeWidth: compact ? 6 : 7,
                                        strokeCap: StrokeCap.round,
                                        backgroundColor: Colors.transparent,
                                        valueColor: AlwaysStoppedAnimation(
                                          paymentRingColor,
                                        ),
                                      ),
                                    ),
                                    Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '$syllabusPct%',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w900,
                                              fontSize: compact ? 24 : 30,
                                            ),
                                          ),
                                          Text(
                                            'Overall',
                                            style: TextStyle(
                                              color: Colors.white.withValues(
                                                alpha: 0.9,
                                              ),
                                              fontWeight: FontWeight.w700,
                                              fontSize: compact ? 12 : 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            InkWell(
                              onTap: () => _showProgressDetailsPopup(
                                attendance: present.clamp(0, meetingsHeld),
                                sessions: present.clamp(0, meetingsHeld),
                                syllabus: syllabusPct,
                                results: hasSessionBalance ? '$leftSafe' : '-',
                                paid: effectiveSessionsPaidTotal,
                                used: sessionsConsumed,
                                left: leftSafe,
                                paymentLeftPct: paymentLeftPct,
                              ),
                              child: Text(
                                'Payment Left $paymentLeftPct%',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFFFF8B2C),
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            const SizedBox(height: 1),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.only(right: compact ? 8 : 12),
                        child: _heroActionGrid(compact: compact),
                      ),
                    ),
                    SizedBox(
                      width: ringSize,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => _showProgressDetailsPopup(
                              attendance: present.clamp(0, meetingsHeld),
                              sessions: present.clamp(0, meetingsHeld),
                              syllabus: syllabusPct,
                              results: hasSessionBalance ? '$leftSafe' : '-',
                              paid: effectiveSessionsPaidTotal,
                              used: sessionsConsumed,
                              left: leftSafe,
                              paymentLeftPct: paymentLeftPct,
                            ),
                            child: SizedBox(
                              width: ringSize,
                              height: ringSize,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  CircularProgressIndicator(
                                    value: 1,
                                    strokeWidth: compact ? 10 : 12,
                                    backgroundColor: Colors.white.withValues(
                                      alpha: 0.14,
                                    ),
                                    valueColor: AlwaysStoppedAnimation(
                                      Colors.white.withValues(alpha: 0.14),
                                    ),
                                  ),
                                  CircularProgressIndicator(
                                    value: progressValue,
                                    strokeWidth: compact ? 10 : 12,
                                    backgroundColor: Colors.transparent,
                                    valueColor: const AlwaysStoppedAnimation(
                                      Color(0xFF57B0FF),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: CircularProgressIndicator(
                                      value: paymentLeftValue,
                                      strokeWidth: compact ? 6 : 7,
                                      strokeCap: StrokeCap.round,
                                      backgroundColor: Colors.transparent,
                                      valueColor: AlwaysStoppedAnimation(
                                        paymentRingColor,
                                      ),
                                    ),
                                  ),
                                  Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '$syllabusPct%',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w900,
                                            fontSize: compact ? 26 : 30,
                                          ),
                                        ),
                                        Text(
                                          'Overall',
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.9,
                                            ),
                                            fontWeight: FontWeight.w700,
                                            fontSize: compact ? 13 : 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          InkWell(
                            onTap: () => _showProgressDetailsPopup(
                              attendance: present.clamp(0, meetingsHeld),
                              sessions: present.clamp(0, meetingsHeld),
                              syllabus: syllabusPct,
                              results: hasSessionBalance ? '$leftSafe' : '-',
                              paid: effectiveSessionsPaidTotal,
                              used: sessionsConsumed,
                              left: leftSafe,
                              paymentLeftPct: paymentLeftPct,
                            ),
                            child: Text(
                              'Payment Left $paymentLeftPct%',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFFFF8B2C),
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const SizedBox(height: 1),
                        ],
                      ),
                    ),
                  ],
                ),
              if (hasSessionBalance) ...[
                SizedBox(height: compact ? 8 : 12),
                Text(
                  'Paid $effectiveSessionsPaidTotal • Used $sessionsConsumed • Left $leftSafe',
                  style: UiK.subtleText().copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              SizedBox(height: compact ? 8 : 10),
              if (_deliveryKey == 'flexible')
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _openFlexibleBooking,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE65C00),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.event_available_rounded, size: 18),
                    label: const Text('Book Next Class'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (overdue || dueSoon) _dueBanner(overdue: overdue, left: leftSafe),
        if (expiryDue || expirySoon)
          _expiryBanner(expired: expiryDue, expiresAt: expiresAt),
        _sectionCard(
          icon: Icons.view_module_rounded,
          title: 'Learning Journey',
          child: _unitsGridSection(units: units, twoPerRow: false),
        ),
        if (_showFlexibleDetails) ...[
          const SizedBox(height: 8),
          _sectionCard(
            icon: Icons.receipt_long_rounded,
            title: 'Payment details',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sessionsTable(
                  paid: hasSessionBalance ? effectiveSessionsPaidTotal : null,
                  passed: sessionsConsumed,
                  left: hasSessionBalance ? leftSafe : null,
                ),
                const SizedBox(height: 8),
                if (!hasPaymentHistory)
                  Text(
                    'Payment history is not synced yet.',
                    style: UiK.subtleText(),
                  )
                else ...[
                  _kvRow(
                    'Amount',
                    lastAmount > 0 ? _fmtMoney(lastAmount) : '—',
                  ),
                  const SizedBox(height: 6),
                  _kvRow('Method', lastMethod.isNotEmpty ? lastMethod : '—'),
                  const SizedBox(height: 6),
                  _kvRow(
                    'Date',
                    lastPaymentAt.isNotEmpty ? lastPaymentAt : '—',
                  ),
                ],
                if (_payLoading) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(minHeight: 4),
                ],
                const SizedBox(height: 8),
                Text(
                  hasSessionBalance
                      ? 'Flexible access depends on session balance and expiry date.'
                      : 'Session balance is syncing from payment records.',
                  style: UiK.subtleText(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _sectionCard(
            icon: Icons.how_to_reg_rounded,
            title: 'Attendance history',
            child: _attendanceAll.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No attendance records yet.',
                      style: TextStyle(
                        color: UiK.mainText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                : Column(
                    children: _attendanceAll.map(_attendanceCard).toList(),
                  ),
          ),
          if (_teacherProfile != null) ...[
            const SizedBox(height: 8),
            _teacherContactSection(),
          ],
        ],
      ],
    );
  }

  void _openRecordedStudy() {
    if (_courseId.trim().isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Recorded course is not available.')),
      );
      return;
    }
    unawaited(
      OfflineActionGuard.runExclusive(
        context,
        'learner.course_detail.recorded_study.${widget.courseKey}',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RecordedCourseStudyScreen(
                courseKey: widget.courseKey,
                courseData: _course,
              ),
            ),
          );
        },
      ),
    );
  }

  Color _paymentProgressColor(double v) {
    final x = v.clamp(0.0, 1.0);
    if (x < 0.6) {
      return Color.lerp(
        const Color(0xFF88E05F),
        const Color(0xFFFFC247),
        x / 0.6,
      )!;
    }
    return Color.lerp(
      const Color(0xFFFFC247),
      const Color(0xFFFF5A5A),
      (x - 0.6) / 0.4,
    )!;
  }

  int _undoneHomeworkCount() {
    int count = 0;
    for (final a in _attendanceAll) {
      if (a['homework'] is! Map) continue;
      final hw = Map<String, dynamic>.from(a['homework'] as Map);
      final text = (hw['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      final submittedAt = _asInt(hw['submittedAt']);
      final doneAt = _asInt(hw['doneAt']);
      final reviewStatus = (hw['reviewStatus'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final done =
          submittedAt > 0 ||
          doneAt > 0 ||
          reviewStatus == 'pass' ||
          reviewStatus == 'done' ||
          reviewStatus == 'completed';
      if (!done) count++;
    }
    return count;
  }

  bool _hasHomeworkInCourse() {
    for (final row in _attendanceAll) {
      final hwMap = row['homework'] is Map
          ? Map<String, dynamic>.from(row['homework'] as Map)
          : const <String, dynamic>{};
      final text = (hwMap['text'] ?? row['homework'] ?? '').toString().trim();
      final fileUrl = (row['homeworkUrl'] ?? '').toString().trim();
      if (text.isNotEmpty || _isHttpUrl(fileUrl)) return true;
    }
    return false;
  }

  Widget _flexActionsRow({required double width}) {
    final useTwoCols = width < 340;
    final tiles = [
      _quickActionTile(
        label: 'Book',
        subtitle: 'Session',
        icon: Icons.menu_book_rounded,
        iconBg: const Color(0xFFDFF6F7),
        iconFg: UiK.primaryBlue,
        onTap: _openCourseBook,
      ),
      _quickActionTile(
        label: 'Homework',
        subtitle: 'Practice',
        icon: Icons.assignment_rounded,
        iconBg: const Color(0xFFFFECE5),
        iconFg: UiK.actionOrange,
        onTap: _openHomework,
      ),
      _quickActionTile(
        label: 'Review',
        subtitle: 'Progress',
        icon: Icons.reviews_rounded,
        iconBg: const Color(0xFFF2E8FF),
        iconFg: const Color(0xFF9B58D8),
        onTap: _openReviewSheet,
      ),
      _quickActionTile(
        label: 'Message',
        subtitle: 'Teacher',
        icon: Icons.mail_rounded,
        iconBg: const Color(0xFFEAF0FF),
        iconFg: const Color(0xFF4A76E8),
        onTap: _mailingTeacher ? null : _mailTeacherDirectly,
        busy: _mailingTeacher,
      ),
    ];

    if (useTwoCols) {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: tiles.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.2,
        ),
        itemBuilder: (_, i) => tiles[i],
      );
    }

    return Row(
      children: [
        for (int i = 0; i < tiles.length; i++) ...[
          Expanded(child: tiles[i]),
          if (i != tiles.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }

  Widget _heroStatsGrid({
    required int attPct,
    required int present,
    required int meetingsHeld,
    required int syllabusPct,
    required bool hasSessionBalance,
    required int leftSafe,
    required bool compact,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _heroStatItem(
                icon: Icons.how_to_reg_rounded,
                iconBg: const Color(0xFF1D784F),
                iconFg: const Color(0xFF6BF3A6),
                value: '${present.clamp(0, meetingsHeld)}',
                label: 'Attendance',
                compact: compact,
              ),
            ),
            _heroDividerV(compact: compact),
            Expanded(
              child: _heroStatItem(
                icon: Icons.event_note_rounded,
                iconBg: const Color(0xFF63423A),
                iconFg: const Color(0xFFFF7A38),
                value: '${present.clamp(0, meetingsHeld)}',
                label: 'Sessions',
                compact: compact,
              ),
            ),
          ],
        ),
        _heroDividerH(),
        Row(
          children: [
            Expanded(
              child: _heroStatItem(
                icon: Icons.bar_chart_rounded,
                iconBg: const Color(0xFF213C75),
                iconFg: const Color(0xFF52A3FF),
                value: '$syllabusPct%',
                label: 'Syllabus',
                compact: compact,
              ),
            ),
            _heroDividerV(compact: compact),
            Expanded(
              child: _heroStatItem(
                icon: Icons.account_balance_wallet_rounded,
                iconBg: const Color(0xFF4A2F77),
                iconFg: const Color(0xFFD279FF),
                value: hasSessionBalance ? '$leftSafe' : '-',
                label: 'Results',
                compact: compact,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _heroActionGrid({required bool compact}) {
    final hideBookTile = _deliveryKey == 'private' || _deliveryKey == 'inclass';
    final showHomeworkTile = _hasHomeworkInCourse();
    if (_deliveryKey == 'inclass') {
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _heroActionTile(
                  label: 'Book',
                  subtitle: 'Session',
                  icon: Icons.menu_book_rounded,
                  iconBg: const Color(0xFF0E4F8A),
                  iconFg: const Color(0xFF6FE8F1),
                  onTap: _openCourseBook,
                  compact: compact,
                ),
              ),
              _heroDividerV(compact: compact),
              Expanded(
                child: _heroActionTile(
                  label: 'Homework',
                  subtitle: 'Practice',
                  icon: Icons.assignment_rounded,
                  iconBg: const Color(0xFF58372F),
                  iconFg: const Color(0xFFFF7A38),
                  onTap: _openHomework,
                  compact: compact,
                ),
              ),
            ],
          ),
          _heroDividerH(),
          Row(
            children: [
              Expanded(
                child: _heroActionTile(
                  label: 'Review',
                  subtitle: 'Progress',
                  icon: Icons.reviews_rounded,
                  iconBg: const Color(0xFF223E79),
                  iconFg: const Color(0xFF52A3FF),
                  onTap: _openReviewSheet,
                  compact: compact,
                ),
              ),
              _heroDividerV(compact: compact),
              Expanded(
                child: _heroActionTile(
                  label: 'Message',
                  subtitle: 'Teacher',
                  icon: Icons.mail_rounded,
                  iconBg: const Color(0xFF4A2F77),
                  iconFg: const Color(0xFFD279FF),
                  onTap: _mailingTeacher ? null : _mailTeacherDirectly,
                  compact: compact,
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (hideBookTile) {
      if (!showHomeworkTile) {
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _heroActionTile(
                    label: 'Book',
                    subtitle: 'Session',
                    icon: Icons.menu_book_rounded,
                    iconBg: const Color(0xFF0E4F8A),
                    iconFg: const Color(0xFF6FE8F1),
                    onTap: _openCourseBook,
                    compact: compact,
                  ),
                ),
                _heroDividerV(compact: compact),
                Expanded(
                  child: _heroActionTile(
                    label: 'Review',
                    subtitle: 'Progress',
                    icon: Icons.reviews_rounded,
                    iconBg: const Color(0xFF223E79),
                    iconFg: const Color(0xFF52A3FF),
                    onTap: _openReviewSheet,
                    compact: compact,
                  ),
                ),
              ],
            ),
            _heroDividerH(),
            SizedBox(
              width: double.infinity,
              child: _heroActionTile(
                label: 'Message',
                subtitle: 'Teacher',
                icon: Icons.mail_rounded,
                iconBg: const Color(0xFF4A2F77),
                iconFg: const Color(0xFFD279FF),
                onTap: _mailingTeacher ? null : _mailTeacherDirectly,
                compact: compact,
              ),
            ),
          ],
        );
      }

      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _heroActionTile(
                  label: 'Book',
                  subtitle: 'Session',
                  icon: Icons.menu_book_rounded,
                  iconBg: const Color(0xFF0E4F8A),
                  iconFg: const Color(0xFF6FE8F1),
                  onTap: _openCourseBook,
                  compact: compact,
                ),
              ),
              _heroDividerV(compact: compact),
              Expanded(
                child: _heroActionTile(
                  label: 'Homework',
                  subtitle: 'Practice',
                  icon: Icons.assignment_rounded,
                  iconBg: const Color(0xFF58372F),
                  iconFg: const Color(0xFFFF7A38),
                  onTap: showHomeworkTile ? _openHomework : null,
                  compact: compact,
                ),
              ),
            ],
          ),
          _heroDividerH(),
          Row(
            children: [
              Expanded(
                child: _heroActionTile(
                  label: 'Review',
                  subtitle: 'Progress',
                  icon: Icons.reviews_rounded,
                  iconBg: const Color(0xFF223E79),
                  iconFg: const Color(0xFF52A3FF),
                  onTap: _openReviewSheet,
                  compact: compact,
                ),
              ),
              _heroDividerV(compact: compact),
              Expanded(
                child: _heroActionTile(
                  label: 'Message',
                  subtitle: 'Teacher',
                  icon: Icons.mail_rounded,
                  iconBg: const Color(0xFF4A2F77),
                  iconFg: const Color(0xFFD279FF),
                  onTap: _mailingTeacher ? null : _mailTeacherDirectly,
                  compact: compact,
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _heroActionTile(
                label: 'Book',
                subtitle: 'Session',
                icon: Icons.menu_book_rounded,
                iconBg: const Color(0xFF0E4F8A),
                iconFg: const Color(0xFF6FE8F1),
                onTap: _openCourseBook,
                compact: compact,
              ),
            ),
            _heroDividerV(compact: compact),
            Expanded(
              child: _heroActionTile(
                label: 'Homework',
                subtitle: 'Practice',
                icon: Icons.assignment_rounded,
                iconBg: const Color(0xFF58372F),
                iconFg: const Color(0xFFFF7A38),
                onTap: showHomeworkTile ? _openHomework : null,
                compact: compact,
              ),
            ),
          ],
        ),
        _heroDividerH(),
        Row(
          children: [
            Expanded(
              child: _heroActionTile(
                label: 'Review',
                subtitle: 'Progress',
                icon: Icons.reviews_rounded,
                iconBg: const Color(0xFF223E79),
                iconFg: const Color(0xFF52A3FF),
                onTap: _openReviewSheet,
                compact: compact,
              ),
            ),
            _heroDividerV(compact: compact),
            Expanded(
              child: _heroActionTile(
                label: 'Message',
                subtitle: 'Teacher',
                icon: Icons.mail_rounded,
                iconBg: const Color(0xFF4A2F77),
                iconFg: const Color(0xFFD279FF),
                onTap: _mailingTeacher ? null : _mailTeacherDirectly,
                compact: compact,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _recordedActionGrid({required bool compact}) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _heroActionTile(
                label: 'Book',
                subtitle: 'Session',
                icon: Icons.menu_book_rounded,
                iconBg: const Color(0xFF0E4F8A),
                iconFg: const Color(0xFF6FE8F1),
                onTap: _openCourseBook,
                compact: compact,
              ),
            ),
            _heroDividerV(compact: compact),
            Expanded(
              child: _heroActionTile(
                label: 'Review',
                subtitle: 'Progress',
                icon: Icons.reviews_rounded,
                iconBg: const Color(0xFF223E79),
                iconFg: const Color(0xFF52A3FF),
                onTap: _openReviewSheet,
                compact: compact,
              ),
            ),
          ],
        ),
        _heroDividerH(),
        SizedBox(
          width: double.infinity,
          child: _heroActionTile(
            label: 'Message',
            subtitle: '',
            icon: Icons.mail_rounded,
            iconBg: const Color(0xFF4A2F77),
            iconFg: const Color(0xFFD279FF),
            onTap: _mailingTeacher ? null : _mailTeacherDirectly,
            compact: compact,
          ),
        ),
      ],
    );
  }

  Widget _heroActionTile({
    required String label,
    required String subtitle,
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required VoidCallback? onTap,
    required bool compact,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: compact ? 8 : 10,
          horizontal: 4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: compact ? 46 : 52,
              height: compact ? 46 : 52,
              decoration: BoxDecoration(
                color: iconBg.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconFg, size: compact ? 24 : 28),
            ),
            SizedBox(height: compact ? 6 : 8),
            SizedBox(
              height: compact ? 18 : 20,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: compact ? 13 : 15,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: compact ? 14 : 16,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 9.6 : 10.6,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showProgressDetailsPopup({
    required int attendance,
    required int sessions,
    required int syllabus,
    required String results,
    required int paid,
    required int used,
    required int left,
    required int paymentLeftPct,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Course Details'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _kvRow('Attendance', '$attendance'),
              const SizedBox(height: 8),
              _kvRow('Sessions', '$sessions'),
              const SizedBox(height: 8),
              _kvRow('Syllabus', '$syllabus%'),
              const SizedBox(height: 8),
              _kvRow('Results', results),
              const SizedBox(height: 8),
              _kvRow('Paid / Used / Left', '$paid / $used / $left'),
              const SizedBox(height: 8),
              _kvRow('Payment Left', '$paymentLeftPct%'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _recordedProgressPanel({
    required bool compact,
    required int modulePct,
    required int unitPct,
    required int lessonPct,
    required int paymentPct,
    required String paymentLabel,
    required VoidCallback onTapPayment,
  }) {
    return Column(
      children: [
        _recordedProgressRow(
          icon: Icons.inventory_2_rounded,
          iconBg: const Color(0xFF0D3E7D),
          iconColor: const Color(0xFF2CB2FF),
          label: 'Modules',
          pct: modulePct,
          barColor: const Color(0xFF22B6FF),
        ),
        SizedBox(height: compact ? 10 : 12),
        _recordedProgressRow(
          icon: Icons.layers_rounded,
          iconBg: const Color(0xFF0B5B78),
          iconColor: const Color(0xFF22E0D2),
          label: 'Units',
          pct: unitPct,
          barColor: const Color(0xFF20D6D0),
        ),
        SizedBox(height: compact ? 10 : 12),
        _recordedProgressRow(
          icon: Icons.track_changes_rounded,
          iconBg: const Color(0xFF2F6B31),
          iconColor: const Color(0xFF9AE63B),
          label: 'Lessons',
          pct: lessonPct,
          barColor: const Color(0xFF8EDC3C),
        ),
        SizedBox(height: compact ? 10 : 12),
        _recordedProgressRow(
          icon: Icons.credit_card_rounded,
          iconBg: const Color(0xFF6D471D),
          iconColor: const Color(0xFFFF9A22),
          label: 'Payment',
          pct: paymentPct,
          valueLabel: paymentLabel,
          barColor: const Color(0xFFFF9800),
          onTap: onTapPayment,
        ),
      ],
    );
  }

  Widget _recordedProgressRow({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String label,
    required int pct,
    required Color barColor,
    String? valueLabel,
    VoidCallback? onTap,
  }) {
    final row = Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconBg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Text(
                    valueLabel ?? '$pct%',
                    style: TextStyle(
                      color: barColor,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: (pct / 100).clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: Colors.white.withValues(alpha: 0.22),
                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      ),
    );
  }

  Future<void> _showRecordedPaymentDetails({required int paymentPct}) async {
    final sum = _paymentSummary;
    final lastAmount = _asInt(sum['lastAmount']);
    final lastMethod = (sum['lastMethod'] ?? '').toString().trim();
    final lastPaymentAtMs = _asInt(sum['lastPaymentAt']);
    final lastPaymentAt = _fmtDateFromMs(lastPaymentAtMs);
    final access = (_course['recorded_access'] is Map)
        ? Map<String, dynamic>.from(_course['recorded_access'] as Map)
        : const <String, dynamic>{};
    final accessExpiresAt = _asInt(access['expiresAt']);
    final summaryExpiresAt = _asInt(sum['expiresAt']);
    final expiresAt = accessExpiresAt > 0 ? accessExpiresAt : summaryExpiresAt;
    final expiryLabel = expiresAt > 0
        ? _fmtDateFromMs(expiresAt)
        : 'No expiry set';
    final expired = expiresAt > 0 && _isExpiredMs(expiresAt);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1D5DB),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Payment details',
                style: TextStyle(
                  color: UiK.mainText,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 10),
              _kvRow('Access expiry', expiryLabel),
              const SizedBox(height: 8),
              _kvRow('Payment health', '$paymentPct%'),
              const SizedBox(height: 8),
              _kvRow(
                'Last amount',
                lastAmount > 0 ? _fmtMoney(lastAmount) : '—',
              ),
              const SizedBox(height: 8),
              _kvRow('Last method', lastMethod.isNotEmpty ? lastMethod : '—'),
              const SizedBox(height: 8),
              _kvRow(
                'Last payment date',
                lastPaymentAt.isNotEmpty ? lastPaymentAt : '—',
              ),
              _kvRow('Access status', expired ? 'Expired' : 'Active'),
              if (expired) ...[
                const SizedBox(height: 10),
                Text(
                  'Your recorded access is expired. Please renew to continue.',
                  style: UiK.subtleText(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  _SkillTheme _skillThemeForSession(Map<String, dynamic> s) {
    final raw = [
      (s['skill'] ?? '').toString(),
      (s['title'] ?? '').toString(),
      (s['objective'] ?? '').toString(),
      (s['content'] ?? '').toString(),
    ].join(' ').toLowerCase();

    if (raw.contains('vocabulary') ||
        raw.contains('vocab') ||
        raw.contains('word') ||
        raw.contains('terms') ||
        raw.contains('lexis')) {
      return const _SkillTheme(
        'Vocabulary',
        Color(0xFF52C86D),
        Icons.translate_rounded,
      );
    }
    if (raw.contains('read')) {
      return const _SkillTheme(
        'Reading',
        Color(0xFF4EA5FF),
        Icons.menu_book_rounded,
      );
    }
    if (raw.contains('writ')) {
      return const _SkillTheme(
        'Writing',
        Color(0xFFFF8A3B),
        Icons.edit_note_rounded,
      );
    }
    if (raw.contains('grammar')) {
      return const _SkillTheme(
        'Grammar',
        Color(0xFFFF5B5B),
        Icons.rule_rounded,
      );
    }
    if (raw.contains('speak')) {
      return const _SkillTheme(
        'Speaking',
        Color(0xFFB46CFF),
        Icons.mic_rounded,
      );
    }
    return const _SkillTheme(
      'Listening',
      Color(0xFFB46CFF),
      Icons.headphones_rounded,
    );
  }

  Widget _sessionDetailTile({
    required Color accent,
    required IconData icon,
    required String title,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Container(width: 4, height: 64, color: accent),
          const SizedBox(width: 10),
          CircleAvatar(
            backgroundColor: accent.withValues(alpha: 0.12),
            foregroundColor: accent,
            child: Icon(icon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: UiK.mainText,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: UiK.subtleText(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: accent),
        ],
      ),
    );
  }

  Widget _quickActionTile({
    required String label,
    required String subtitle,
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required VoidCallback? onTap,
    bool busy = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final tiny = w < 84;
          final compact = w < 96;
          final cardHeight = tiny ? 156.0 : (compact ? 148.0 : 138.0);
          final iconBox = tiny ? 36.0 : (compact ? 42.0 : 54.0);
          final iconSize = tiny ? 18.0 : (compact ? 21.0 : 26.0);
          final titleSize = tiny ? 9.8 : (compact ? 11.0 : 13.0);
          final subSize = tiny ? 8.8 : (compact ? 9.8 : 10.8);

          return Container(
            height: cardHeight,
            padding: EdgeInsets.all(tiny ? 6 : (compact ? 8 : 10)),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
              boxShadow: const [],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: iconBox,
                  height: iconBox,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: busy
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: iconFg,
                            ),
                          )
                        : Icon(icon, size: iconSize, color: iconFg),
                  ),
                ),
                SizedBox(height: tiny ? 6 : 8),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                  textScaler: const TextScaler.linear(1.0),
                  softWrap: true,
                  style: TextStyle(
                    color: UiK.mainText,
                    fontWeight: FontWeight.w900,
                    fontSize: titleSize,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                  textScaler: const TextScaler.linear(1.0),
                  softWrap: true,
                  style: TextStyle(
                    color: UiK.mainText.withValues(alpha: 0.65),
                    fontWeight: FontWeight.w700,
                    fontSize: subSize,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _heroDividerV({required bool compact}) {
    return Container(
      width: 1,
      height: compact ? 66 : 76,
      color: Colors.white.withValues(alpha: 0.18),
      margin: const EdgeInsets.symmetric(horizontal: 10),
    );
  }

  Widget _heroDividerH() {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: Colors.white.withValues(alpha: 0.18),
    );
  }

  Widget _heroStatItem({
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required String value,
    required String label,
    required bool compact,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: compact ? 44 : 52,
          height: compact ? 44 : 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: iconBg.withValues(alpha: 0.6),
          ),
          child: Icon(icon, size: compact ? 22 : 26, color: iconFg),
        ),
        SizedBox(height: compact ? 6 : 8),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: compact ? 18 : 22,
            height: 1,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.visible,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontWeight: FontWeight.w700,
            fontSize: compact ? 11 : 12,
            height: 1.12,
          ),
        ),
      ],
    );
  }

  Widget _progressStatItem({
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required String value,
    required String label,
  }) {
    final scale = MediaQuery.of(context).textScaler.scale(1.0).clamp(1.0, 1.35);
    final compact = scale > 1.08;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 10 : 12,
      ),
      child: Column(
        children: [
          Container(
            width: compact ? 36 : 40,
            height: compact ? 36 : 40,
            decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child: Icon(icon, size: compact ? 18 : 21, color: iconFg),
          ),
          SizedBox(height: compact ? 6 : 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                color: UiK.mainText,
                fontSize: compact ? 16 : 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: UiK.mainText.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
              height: 1.2,
              fontSize: compact ? 11 : 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dividerV() {
    return Container(
      width: 1,
      height: 122,
      color: UiK.uiBorder.withValues(alpha: 0.6),
    );
  }

  Widget _unitsGridSection({
    required List<Map<String, dynamic>> units,
    required bool twoPerRow,
  }) {
    if (units.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Syllabus not found for this course.',
          style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800),
        ),
      );
    }

    final List<Widget> rows = [];
    for (int i = 0; i < units.length; i++) {
      final item = units[i];
      rows.add(_unitGridCard(item));
      final isOpen = _unitKey(item) == _expandedFlexibleUnitKey;
      if (isOpen) {
        final sessions = (item['sessions'] as List<Map<String, dynamic>>);
        rows.add(
          Container(
            margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
              color: Colors.white,
            ),
            child: Column(children: sessions.map(_sessionLessonRow).toList()),
          ),
        );
      } else {
        rows.add(const SizedBox(height: 8));
      }
    }

    return Column(children: rows);
  }

  String _unitKey(Map<String, dynamic> u) {
    final unitId = (u['unitId'] ?? '').toString().trim();
    if (unitId.isNotEmpty) return unitId;
    return '${u['unitOrder'] ?? ''}|${u['unitTitle'] ?? ''}';
  }

  Widget _unitGridCard(Map<String, dynamic> u) {
    final w = MediaQuery.of(context).size.width;
    final compact = w < 390;
    final unitTitle = (u['unitTitle'] ?? 'Unit').toString();
    final sessions = (u['sessions'] as List<Map<String, dynamic>>);
    final total = sessions.length;
    var covered = 0;
    for (final s in sessions) {
      final sid = (s['sessionId'] ?? '').toString();
      if (_coveredSessionIds.contains(sid)) covered++;
    }
    final pct = total == 0 ? 0 : ((covered / total) * 100).round();
    final key = _unitKey(u);
    final isOpen = _expandedFlexibleUnitKey == key;

    return InkWell(
      onTap: () {
        setState(() {
          _expandedFlexibleUnitKey = isOpen ? null : key;
        });
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 14,
          vertical: compact ? 10 : 11,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isOpen
                ? UiK.primaryBlue.withValues(alpha: 0.5)
                : UiK.uiBorder.withValues(alpha: 0.75),
          ),
          color: isOpen ? const Color(0xFFF9FCFF) : Colors.white,
        ),
        child: Row(
          children: [
            SizedBox(
              width: compact ? 46 : 50,
              height: compact ? 46 : 50,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: total == 0 ? 0 : (covered / total).clamp(0.0, 1.0),
                    backgroundColor: UiK.primaryBlue.withValues(alpha: 0.10),
                    valueColor: const AlwaysStoppedAnimation(UiK.primaryBlue),
                    strokeWidth: compact ? 4 : 4.5,
                  ),
                  Center(
                    child: Text(
                      '$pct%',
                      style: TextStyle(
                        fontSize: compact ? 11 : 12,
                        fontWeight: FontWeight.w900,
                        color: UiK.mainText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: compact ? 10 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    unitTitle,
                    style: TextStyle(
                      color: UiK.mainText,
                      fontWeight: FontWeight.w900,
                      fontSize: compact ? 14 : 15,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$covered/$total lessons',
                    style: UiK.subtleText().copyWith(
                      fontSize: compact ? 11 : 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              isOpen
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: UiK.primaryBlue,
              size: compact ? 22 : 24,
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _desktopSummaryCard({
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: UiK.labelText().copyWith(color: UiK.primaryBlue)),
          const SizedBox(height: 10),
          Text(
            value,
            style: UiK.titleText(size: 28).copyWith(color: UiK.actionOrange),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: UiK.subtleText().copyWith(height: 1.35)),
        ],
      ),
    );
  }

  // -------------------- PAYMENT TAB (UNCHANGED) --------------------

  // ignore: unused_element
  Widget _paymentTab({
    required int sessionsPassed,
    required int attPct,
    required int present,
    required int total,
  }) {
    if (_payLoading) return const Center(child: CircularProgressIndicator());

    final sum = _paymentSummary;

    final sessionsPaidTotal = _asInt(sum['sessionsPaidTotal']);
    final remindBeforeSession = _asInt(sum['remindBeforeSession']);
    final totalPaid = _asInt(sum['totalPaid']);

    final lastAmount = _asInt(sum['lastAmount']);
    final lastMethod = (sum['lastMethod'] ?? '').toString();
    final lastPaymentAtMs = _asInt(sum['lastPaymentAt']);
    final lastPaymentAt = _fmtDateFromMs(lastPaymentAtMs);

    final hasPaymentHistory =
        totalPaid > 0 ||
        lastAmount > 0 ||
        lastPaymentAtMs > 0 ||
        lastMethod.trim().isNotEmpty;

    final derivedSessionsPaidTotal = _derivedSessionsReady
        ? _derivedSessionsPaidTotal
        : 0;

    final mergedSessionsPaidTotal =
        (sessionsPaidTotal >= derivedSessionsPaidTotal)
        ? sessionsPaidTotal
        : derivedSessionsPaidTotal;
    final fallbackSessionsPaid = mergedSessionsPaidTotal <= 0
        ? (hasPaymentHistory &&
                  (_deliveryKey == 'private' || _deliveryKey == 'inclass')
              ? 8
              : 0)
        : 0;
    final effectiveSessionsPaidTotal = mergedSessionsPaidTotal > 0
        ? mergedSessionsPaidTotal
        : fallbackSessionsPaid;
    final bool hasSessionBalance = effectiveSessionsPaidTotal > 0;
    final bool isFreeCourse = courseIsFreeBilling(_course);

    final left = effectiveSessionsPaidTotal - sessionsPassed;
    final bool overdue =
        !isFreeCourse &&
        hasSessionBalance &&
        isPaymentDueBySessions(
          sessionsPaidTotal: effectiveSessionsPaidTotal,
          sessionsPresent: sessionsPassed,
        );
    final bool dueSoon =
        !isFreeCourse &&
        hasSessionBalance &&
        isPaymentWarningBySessions(
          sessionsPaidTotal: effectiveSessionsPaidTotal,
          sessionsPresent: sessionsPassed,
          remindBeforeSession: remindBeforeSession,
        );

    final expiresAt = _studyTypeExpiresAtMs();
    final expiryDue =
        !isFreeCourse && _deliveryKey == 'flexible' && _isExpiredMs(expiresAt);
    final expirySoon =
        !isFreeCourse &&
        _deliveryKey == 'flexible' &&
        !expiryDue &&
        _isNearExpiryMs(expiresAt);

    final int leftSafe = left < 0 ? 0 : left;

    return ListView(
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
                Text('Course', style: UiK.titleText()),
                const SizedBox(height: 8),
                Text(
                  'Code: ${_courseCode.isEmpty ? '-' : _courseCode} • Class: ${_classId.isEmpty ? '-' : _classId}${_studyTypeLabel.isEmpty ? '' : ' • $_studyTypeLabel'}',
                  style: UiK.subtleText(),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: UiK.uiBorder.withValues(alpha: 0.85),
                    ),
                    color: UiK.primaryBlue.withValues(alpha: 0.04),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.schedule_rounded,
                            size: 16,
                            color: UiK.primaryBlue,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _compactScheduleText(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: UiK.subtleText(),
                            ),
                          ),
                        ],
                      ),
                      if (_compactNextSessionText().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          _compactNextSessionText(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: UiK.subtleText(),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_deliveryKey == 'flexible')
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    child: FilledButton.icon(
                      onPressed: _openCourseBook,
                      icon: const Icon(Icons.menu_book_rounded, size: 18),
                      label: const Text('Open Course Book'),
                      style: FilledButton.styleFrom(
                        backgroundColor: UiK.primaryBlue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                if (_isPrivateOnlineCourse && _privateMetaFuture != null)
                  FutureBuilder<_DetailPrivateMeta?>(
                    future: _privateMetaFuture,
                    builder: (context, snap) {
                      final meta = snap.data;
                      if (meta == null) {
                        return const SizedBox.shrink();
                      }

                      final next = meta.nextStart;
                      final hasMeet = meta.meetUrl.trim().isNotEmpty;

                      String nextLabel = 'Next session: -';
                      if (next != null) {
                        nextLabel =
                            'Next session: ${_fmtDateTimeFromMs(next.millisecondsSinceEpoch)}';
                      }

                      return Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: UiK.uiBorder.withValues(alpha: 0.85),
                          ),
                          color: UiK.primaryBlue.withValues(alpha: 0.04),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(meta.scheduleLine, style: UiK.subtleText()),
                            const SizedBox(height: 4),
                            Text(nextLabel, style: UiK.subtleText()),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: StreamBuilder<int>(
                                stream: Stream.periodic(
                                  const Duration(seconds: 1),
                                  (x) => x,
                                ),
                                initialData: 0,
                                builder: (context, _) {
                                  final now = DateTime.now();
                                  final canJoin =
                                      next != null &&
                                      canJoinFromStart(next, now: now) &&
                                      hasMeet;

                                  final joinLabel = next == null
                                      ? (hasMeet
                                            ? 'Join (schedule unavailable)'
                                            : 'Meet link not set')
                                      : joinButtonLabelForWindow(
                                          openFrom: joinOpensAt(next),
                                          openUntil: joinClosesAt(next),
                                          hasMeetLink: hasMeet,
                                          now: now,
                                          actionLabel: 'Join',
                                          closedLabel: 'Join window closed',
                                        );

                                  return ElevatedButton.icon(
                                    onPressed: canJoin
                                        ? () async {
                                            await _notifyTeacherJoinTap(meta);
                                            await _openExternalUrl(
                                              meta.meetUrl,
                                            );
                                          }
                                        : null,
                                    icon: const Icon(Icons.video_call_rounded),
                                    label: Text(joinLabel),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: canJoin
                                          ? UiK.actionOrange
                                          : Colors.grey.shade500,
                                      foregroundColor: Colors.white,
                                      disabledBackgroundColor:
                                          Colors.grey.shade500,
                                      disabledForegroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
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
                  ),
                if (_teacherProfile != null) _teacherContactSection(),
                if (overdue || dueSoon)
                  _dueBanner(overdue: overdue, left: leftSafe),
                if (expiryDue || expirySoon)
                  _expiryBanner(expired: expiryDue, expiresAt: expiresAt),
                _sessionsTable(
                  paid: hasSessionBalance ? effectiveSessionsPaidTotal : null,
                  passed: sessionsPassed,
                  left: hasSessionBalance ? leftSafe : null,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: UiK.uiBorder.withValues(alpha: 0.85),
                    ),
                    color: UiK.primaryBlue.withValues(alpha: 0.04),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.receipt_long_rounded,
                            size: 18,
                            color: UiK.actionOrange,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Last payment',
                            style: TextStyle(
                              color: UiK.mainText,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (!hasPaymentHistory)
                        Text(
                          'Your payment info is not available yet. If you already paid, contact Your Bridge School to sync it.',
                          style: UiK.subtleText(),
                        )
                      else ...[
                        _kvRow(
                          'Amount',
                          lastAmount > 0 ? _fmtMoney(lastAmount) : '—',
                        ),
                        const SizedBox(height: 6),
                        _kvRow(
                          'Method',
                          lastMethod.isNotEmpty ? lastMethod : '—',
                        ),
                        const SizedBox(height: 6),
                        _kvRow(
                          'Date',
                          lastPaymentAt.isNotEmpty ? lastPaymentAt : '—',
                        ),
                        if (!hasSessionBalance) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Payment is recorded, but the sessions balance is still syncing.',
                            style: UiK.subtleText(),
                          ),
                        ],
                        if (hasSessionBalance &&
                            derivedSessionsPaidTotal > sessionsPaidTotal) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Sessions restored from payment history.',
                            style: UiK.subtleText(),
                          ),
                        ],
                      ],
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: UiK.uiBorder.withValues(alpha: 0.85),
                          ),
                          color: Colors.white,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.tips_and_updates_rounded,
                                  size: 18,
                                  color: UiK.actionOrange,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Recommendation',
                                  style: TextStyle(
                                    color: UiK.mainText,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              !hasPaymentHistory
                                  ? 'Payment is not synced yet.'
                                  : !hasSessionBalance
                                  ? 'Payment is saved. Session balance will appear after sync.'
                                  : (overdue || expiryDue)
                                  ? 'Payment is due now. Please contact Your Bridge School to renew your sessions.'
                                  : (dueSoon || expirySoon)
                                  ? (leftSafe == 1
                                        ? 'Payment due in 1 session. It’s a good time to renew now.'
                                        : 'Payment due soon. It’s a good time to renew.')
                                  : 'Everything looks good. Keep attending and track your progress.',
                              style: UiK.subtleText(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _attendanceOverviewSection(
                  attPct: attPct,
                  present: present,
                  total: total,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _attendanceOverviewSection({
    required int attPct,
    required int present,
    required int total,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
        color: Colors.white,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.how_to_reg_rounded, size: 18, color: UiK.actionOrange),
              SizedBox(width: 8),
              Text(
                'Attendance',
                style: TextStyle(
                  color: UiK.mainText,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _kpi(
                icon: Icons.how_to_reg_rounded,
                label: 'Attendance',
                value: '$attPct%',
              ),
              _kpi(
                icon: Icons.check_circle_rounded,
                label: 'Present',
                value: '$present/$total',
              ),
              _kpi(
                icon: Icons.wifi_tethering_rounded,
                label: 'Online records',
                value: '${_onlineAttendance.length}',
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_attendanceAll.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No attendance records yet.',
                style: TextStyle(
                  color: UiK.mainText,
                  fontWeight: FontWeight.w800,
                ),
              ),
            )
          else
            ..._attendanceAll.map(_attendanceCard),
        ],
      ),
    );
  }

  Widget _sessionsTable({
    required int? paid,
    required int passed,
    required int? left,
  }) {
    Widget cell(String v, {bool strong = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        child: Text(
          v,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: UiK.mainText,
            fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
        color: Colors.white,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: BorderSide(
              color: UiK.uiBorder.withValues(alpha: 0.65),
            ),
            verticalInside: BorderSide(
              color: UiK.uiBorder.withValues(alpha: 0.65),
            ),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: UiK.primaryBlue.withValues(alpha: 0.04),
              ),
              children: [
                cell('Sessions paid', strong: true),
                cell('Sessions passed', strong: true),
                cell('Sessions left', strong: true),
              ],
            ),
            TableRow(
              children: [
                cell(paid == null ? '—' : '$paid'),
                cell('$passed'),
                cell(left == null ? '—' : '$left'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(String k, String v) {
    return Row(
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(
              color: UiK.mainText.withValues(alpha: 0.70),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          v,
          style: const TextStyle(
            color: UiK.mainText,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }

  Widget _dueBanner({required bool overdue, required int left}) {
    final title = overdue ? 'Payment is due' : 'Payment due soon';
    final msg = overdue
        ? 'You have reached the last paid session. Please renew your payment.'
        : 'You have $left session(s) left before payment is due.';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
        color: Colors.red.withValues(alpha: 0.08),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_rounded, color: Colors.red),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: UiK.mainText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  msg,
                  style: TextStyle(
                    color: UiK.mainText.withValues(alpha: 0.75),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _expiryBanner({required bool expired, required int expiresAt}) {
    final title = expired ? 'Access expired' : 'Expiry date is near';
    final msg = expired
        ? 'Your flexible access period has ended. Please renew to continue.'
        : 'Your flexible access expires on ${_fmtDateFromMs(expiresAt)}.';
    final tone = expired ? Colors.red : const Color(0xFF7C3AED);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
        color: tone.withValues(alpha: 0.08),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            expired ? Icons.event_busy_rounded : Icons.event_available_rounded,
            color: tone,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: UiK.mainText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(msg, style: UiK.subtleText()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _attendanceCard(Map<String, dynamic> a) {
    final source = (a['source'] ?? 'in_class').toString();
    final isOnline = source == 'online';

    final date = (a['date'] ?? '').toString();
    final status = (a['status'] ?? '').toString().toLowerCase();
    final rate = (a['successRate'] ?? '').toString();
    final taughtSummary = (a['taughtSummary'] ?? '').toString().trim();

    final taughtOld = (a['taught'] is Map)
        ? Map<String, dynamic>.from(a['taught'] as Map)
        : <String, dynamic>{};
    final unitTitle = (taughtOld['unitTitle'] ?? '').toString();

    final hw = (a['homework'] is Map)
        ? Map<String, dynamic>.from(a['homework'] as Map)
        : <String, dynamic>{};
    final hwText = (hw['text'] ?? '').toString().trim();
    final hwDue = (hw['dueDate'] ?? '').toString().trim();

    final isPresent = status == 'present';
    final isPending = status == 'pending';
    final presentBorder = UiK.primaryBlue.withValues(alpha: 0.28);
    final absentBorder = Colors.red.withValues(alpha: 0.22);
    final pendingBorder = UiK.actionOrange.withValues(alpha: 0.26);

    final tagBg = isOnline
        ? UiK.actionOrange.withValues(alpha: 0.10)
        : UiK.primaryBlue.withValues(alpha: 0.08);
    final tagFg = isOnline ? UiK.actionOrange : UiK.primaryBlue;
    final tagText = isOnline ? 'Online' : 'In-class';

    final sessionNo = _asInt(a['sessionNo']);
    final teacherName =
        (a['teacherName'] ??
                a['teacherNameFromBooking'] ??
                a['teacher_name'] ??
                '')
            .toString()
            .trim();
    final reviewRating = _asInt(a['reviewRating']);

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isPresent
                  ? presentBorder
                  : (isPending ? pendingBorder : absentBorder),
            ),
            gradient: isPresent
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      UiK.primaryBlue.withValues(alpha: 0.11),
                      UiK.primaryBlue.withValues(alpha: 0.04),
                    ],
                  )
                : null,
            boxShadow: isPresent
                ? [
                    BoxShadow(
                      color: UiK.primaryBlue.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : const [],
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor:
                      (isPresent
                              ? UiK.primaryBlue
                              : (isPending ? UiK.actionOrange : Colors.red))
                          .withValues(alpha: 0.10),
                  child: Icon(
                    isPresent
                        ? Icons.check_rounded
                        : (isPending
                              ? Icons.schedule_rounded
                              : Icons.close_rounded),
                    color: isPresent
                        ? UiK.primaryBlue
                        : (isPending ? UiK.actionOrange : Colors.red),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              date.isEmpty ? 'Meeting' : date,
                              style: UiK.titleText(size: 15),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: tagBg,
                              border: Border.all(
                                color: UiK.uiBorder.withValues(alpha: 0.85),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isOnline
                                      ? Icons.wifi_tethering_rounded
                                      : Icons.groups_rounded,
                                  size: 14,
                                  color: tagFg,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  tagText,
                                  style: const TextStyle(
                                    color: UiK.mainText,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Status: ${isPresent ? 'Present' : (isPending ? 'Pending confirmation' : 'Absent')}'
                        '${rate.isEmpty ? '' : ' • Success: $rate%'}'
                        '${(isOnline && sessionNo > 0) ? ' • Session: $sessionNo' : ''}',
                        style: UiK.subtleText(),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Teacher: ${teacherName.isEmpty ? '-' : teacherName}',
                        style: UiK.subtleText(),
                      ),
                      if (taughtSummary.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('Taught: $taughtSummary', style: UiK.subtleText()),
                      ],
                      if (isOnline && isPresent && sessionNo > 0) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(5, (i) {
                                final on = (i + 1) <= reviewRating;
                                return Icon(
                                  on
                                      ? Icons.star_rounded
                                      : Icons.star_border_rounded,
                                  size: 18,
                                  color: const Color(0xFFF59E0B),
                                );
                              }),
                            ),
                            TextButton.icon(
                              onPressed: () =>
                                  _openSessionReviewSheetForAttendance(a),
                              icon: const Icon(Icons.rate_review_rounded),
                              label: Text(
                                (reviewRating >= 1 && reviewRating <= 5)
                                    ? 'Update review'
                                    : 'Review session',
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (!isOnline && unitTitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Unit: $unitTitle',
                          style: TextStyle(
                            color: UiK.mainText.withValues(alpha: 0.6),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (!isOnline &&
                          (hwText.isNotEmpty || hwDue.isNotEmpty)) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: UiK.uiBorder.withValues(alpha: 0.85),
                            ),
                            color: UiK.primaryBlue.withValues(alpha: 0.04),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(
                                    Icons.assignment_rounded,
                                    size: 18,
                                    color: UiK.actionOrange,
                                  ),
                                ],
                              ),
                              if (hwDue.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text('Due: $hwDue', style: UiK.subtleText()),
                              ],
                              if (hwText.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(hwText, style: UiK.subtleText()),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------- PROGRESS TAB (NOW MERGED ONLINE + IN-CLASS) --------------------

  // ignore: unused_element
  Widget _progressTab({
    required int meetingsHeld,
    required int? plannedMeetings,
    required int syllabusPct,
    required int coveredLessons,
    required int totalLessons,
  }) {
    final units = _groupSyllabiByUnit();
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    final plannedStr = (plannedMeetings == null || plannedMeetings <= 0)
        ? '-'
        : '$plannedMeetings';

    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + (bottomPad > 0 ? bottomPad : 12),
      ),
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
                Text('Progress', style: UiK.titleText()),
                const SizedBox(height: 8),
                Text(
                  'Code: ${_courseCode.isEmpty ? '-' : _courseCode} • Class: ${_classId.isEmpty ? '-' : _classId}${_studyTypeLabel.isEmpty ? '' : ' • $_studyTypeLabel'}',
                  style: UiK.subtleText(),
                ),
                const SizedBox(height: 12),

                // meetings line
                Row(
                  children: [
                    const Icon(
                      Icons.event_available_rounded,
                      size: 18,
                      color: UiK.actionOrange,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Meetings',
                      style: TextStyle(
                        color: UiK.mainText,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$meetingsHeld/$plannedStr',
                      style: const TextStyle(
                        color: UiK.mainText,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // syllabus line + bar
                Row(
                  children: [
                    const Icon(
                      Icons.menu_book_rounded,
                      size: 18,
                      color: UiK.actionOrange,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Syllabus',
                      style: TextStyle(
                        color: UiK.mainText,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$syllabusPct%',
                      style: const TextStyle(
                        color: UiK.mainText,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: totalLessons == 0
                        ? 0
                        : (coveredLessons / totalLessons).clamp(0, 1),
                    minHeight: 10,
                    backgroundColor: UiK.primaryBlue.withValues(alpha: 0.10),
                    valueColor: const AlwaysStoppedAnimation(UiK.actionOrange),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Covered: $coveredLessons / $totalLessons lessons',
                  style: UiK.subtleText(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (_syllabiFlat.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Syllabus not found for this course.',
                style: TextStyle(
                  color: UiK.mainText,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          )
        else
          ...units.map(_unitModuleCard),
      ],
    );
  }

  Widget _unitModuleCard(Map<String, dynamic> u) {
    final unitTitle = (u['unitTitle'] ?? 'Unit').toString();
    final unitDesc = (u['unitDescription'] ?? '').toString().trim();
    final sessions = (u['sessions'] as List<Map<String, dynamic>>);

    int unitTotal = sessions.length;
    int unitPassed = 0;
    for (final s in sessions) {
      final sid = (s['sessionId'] ?? '').toString();
      if (_coveredSessionIds.contains(sid)) unitPassed++;
    }

    final bool completed = unitTotal > 0 && unitPassed >= unitTotal;
    final bool started = unitPassed > 0;

    final statusText = completed
        ? 'Completed'
        : started
        ? 'In progress'
        : 'Not started';
    final statusBg = completed
        ? UiK.primaryBlue.withValues(alpha: 0.10)
        : started
        ? UiK.actionOrange.withValues(alpha: 0.10)
        : UiK.uiBorder.withValues(alpha: 0.18);
    final statusFg = completed
        ? UiK.primaryBlue
        : started
        ? UiK.actionOrange
        : UiK.primaryBlue.withValues(alpha: 0.7);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
        color: Colors.white,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: CircleAvatar(
              backgroundColor: UiK.primaryBlue.withValues(alpha: 0.08),
              child: Icon(
                completed ? Icons.verified_rounded : Icons.folder_open_rounded,
                color: UiK.primaryBlue,
              ),
            ),
            title: Text(
              unitTitle.isEmpty ? 'Unit' : unitTitle,
              style: const TextStyle(
                color: UiK.mainText,
                fontWeight: FontWeight.w900,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: unitTotal == 0
                              ? 0
                              : (unitPassed / unitTotal).clamp(0, 1),
                          minHeight: 8,
                          backgroundColor: UiK.primaryBlue.withValues(
                            alpha: 0.08,
                          ),
                          valueColor: const AlwaysStoppedAnimation(
                            UiK.actionOrange,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$unitPassed/$unitTotal',
                      style: TextStyle(
                        color: UiK.mainText.withValues(alpha: 0.75),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                if (unitDesc.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    unitDesc,
                    style: UiK.subtleText(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _pill(
                    text: statusText,
                    icon: completed
                        ? Icons.check_circle_rounded
                        : started
                        ? Icons.timelapse_rounded
                        : Icons.hourglass_empty_rounded,
                    bg: statusBg,
                    fg: statusFg,
                    dense: true,
                  ),
                ),
              ],
            ),
            children: [
              const SizedBox(height: 8),
              ...sessions.map(_sessionLessonRow),
            ],
          ),
        ),
      ),
    );
  }

  bool _isHttpUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }

  void _showMissingHomeworkMessage() {
    AppToast.fromSnackBar(
      context,
      const SnackBar(
        content: Text(
          'Homework file is not available yet. Please contact Your Bridge School administration for support.',
        ),
      ),
    );
  }

  Future<void> _openLessonMaterial(Map<String, dynamic> session) async {
    final url = (session['homeworkUrl'] ?? '').toString().trim();
    if (!_isHttpUrl(url)) {
      _showMissingHomeworkMessage();
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showMissingHomeworkMessage();
      return;
    }

    if (!mounted) return;

    try {
      await OfflineActionGuard.runExclusive(
        context,
        'learner.course_detail.material.${widget.courseKey}.${session.hashCode}',
        () async {
          final title = (session['title'] ?? '').toString().trim();
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MaterialWebViewScreen.fromUrl(
                title: title.isEmpty ? 'Homework' : '$title Homework',
                url: uri.toString(),
                viewerMode: MaterialViewerMode.document,
              ),
            ),
          );
        },
      );
    } catch (_) {
      _showMissingHomeworkMessage();
    }
  }

  Future<void> _openCourseBook() async {
    final url = _courseBookUrl.trim();
    if (!_isHttpUrl(url)) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Course book is not available yet.')),
      );
      return;
    }

    if (!mounted) return;
    try {
      await OfflineActionGuard.runExclusive(
        context,
        'learner.course_detail.book.${widget.courseKey}',
        () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  SharedPdfReaderScreen(title: 'Course Book', pdfUrl: url),
            ),
          );
        },
      );
    } catch (_) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open course book.')),
      );
    }
  }

  Widget _sessionLessonRow(Map<String, dynamic> s) {
    final title = (s['title'] ?? '').toString().trim();
    final sessionId = (s['sessionId'] ?? '').toString().trim();
    final objective = (s['objective'] ?? '').toString().trim();
    final hasHomeworkFile = _isHttpUrl((s['homeworkUrl'] ?? '').toString());

    final passed = _coveredSessionIds.contains(sessionId);
    const materialAction = 'Homework';
    final statusText = passed ? 'Passed' : 'Coming';
    final passedBorder = UiK.primaryBlue.withValues(alpha: 0.24);
    final pendingBorder = UiK.uiBorder.withValues(alpha: 0.75);

    return InkWell(
      onTap: () => _openSessionDetailsSheet(s),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: passed ? passedBorder : pendingBorder),
          color: passed
              ? UiK.primaryBlue.withValues(alpha: 0.03)
              : Colors.white,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: (passed ? UiK.primaryBlue : UiK.uiBorder)
                  .withValues(alpha: 0.10),
              child: Icon(
                passed ? Icons.check_circle_rounded : Icons.schedule_rounded,
                size: 18,
                color: passed
                    ? UiK.primaryBlue
                    : UiK.primaryBlue.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? 'Session' : title,
                    style: const TextStyle(
                      color: UiK.mainText,
                      fontWeight: FontWeight.w900,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _miniChip(
                        icon: passed
                            ? Icons.check_rounded
                            : Icons.schedule_rounded,
                        text: statusText,
                        fg: passed
                            ? UiK.primaryBlue
                            : UiK.primaryBlue.withValues(alpha: 0.75),
                        bg: passed
                            ? UiK.primaryBlue.withValues(alpha: 0.10)
                            : UiK.uiBorder.withValues(alpha: 0.18),
                      ),
                    ],
                  ),
                  if (objective.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      objective,
                      style: TextStyle(
                        color: UiK.mainText.withValues(alpha: 0.70),
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (hasHomeworkFile)
                        FilledButton.icon(
                          onPressed: () => _openLessonMaterial(s),
                          icon: const Icon(
                            Icons.auto_stories_rounded,
                            size: 18,
                          ),
                          label: Text(materialAction),
                          style: FilledButton.styleFrom(
                            backgroundColor: UiK.actionOrange,
                            foregroundColor: Colors.white,
                            visualDensity: const VisualDensity(
                              horizontal: -1,
                              vertical: -1,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: passed
                  ? UiK.primaryBlue
                  : UiK.primaryBlue.withValues(alpha: 0.65),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------- Session details bottom sheet --------------------

  void _openSessionDetailsSheet(Map<String, dynamic> s) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SafeArea(
          top: false,
          child: DraggableScrollableSheet(
            initialChildSize: 0.84,
            minChildSize: 0.55,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              final title = (s['title'] ?? '').toString().trim();
              final unitTitle = (s['unitTitle'] ?? '').toString().trim();
              final sessionId = (s['sessionId'] ?? '').toString().trim();
              final objective = (s['objective'] ?? '').toString().trim();
              final content = (s['content'] ?? '').toString().trim();
              final hw = (s['homework'] ?? '').toString().trim();
              final passed = _coveredSessionIds.contains(sessionId);
              final statusText = passed ? 'Passed' : 'Coming';
              final hwBlocks = _parseHomework(hw);
              final bottomPad = MediaQuery.of(context).viewPadding.bottom;

              Widget section({required String label, required String value}) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: UiK.uiBorder.withValues(alpha: 0.85),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: UiK.mainText,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(value, style: UiK.subtleText()),
                    ],
                  ),
                );
              }

              return Container(
                decoration: BoxDecoration(
                  color: UiK.appBg,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(22),
                  ),
                  border: Border.all(
                    color: UiK.uiBorder.withValues(alpha: 0.85),
                  ),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 8),
                      child: Container(
                        width: 48,
                        height: 5,
                        decoration: BoxDecoration(
                          color: UiK.uiBorder.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: controller,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          8,
                          16,
                          16 + (bottomPad > 0 ? bottomPad : 12),
                        ),
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              gradient: const LinearGradient(
                                colors: [Color(0xFF052B66), Color(0xFF001A4F)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title.isEmpty ? 'Session' : title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 20,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  unitTitle.isEmpty ? 'Unit' : unitTitle,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _miniChip(
                                  icon: passed
                                      ? Icons.check_rounded
                                      : Icons.schedule_rounded,
                                  text: statusText,
                                  fg: Colors.white,
                                  bg: Colors.white.withValues(alpha: 0.18),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          section(
                            label: 'Learning Outcome',
                            value: objective.isEmpty
                                ? 'Students will understand and practice the topic.'
                                : objective,
                          ),
                          const SizedBox(height: 12),
                          section(
                            label: 'Assignment',
                            value: hw.isEmpty
                                ? 'No homework for this session.'
                                : hwBlocks.first.lines.join(' '),
                          ),
                          const SizedBox(height: 12),
                          section(
                            label: 'Session Content',
                            value: content.isEmpty
                                ? 'Session content will be added soon.'
                                : content,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  List<Widget> _buildHomeworkBrief(List<_HwBlock> blocks) {
    if (blocks.isEmpty) {
      return [
        Text('Homework details are not available.', style: UiK.subtleText()),
      ];
    }

    bool looksLikeSubmission(String t) {
      final up = t.toUpperCase();
      return up.contains('SUBMISSION') ||
          t.startsWith('📤') ||
          up.contains('UPLOAD');
    }

    final widgets = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final title = b.title.trim();
      final lines = b.lines;
      final submission = looksLikeSubmission(title);

      widgets.add(
        Container(
          width: double.infinity,
          margin: EdgeInsets.only(bottom: i == blocks.length - 1 ? 0 : 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
            color: submission
                ? UiK.actionOrange.withValues(alpha: 0.07)
                : UiK.primaryBlue.withValues(alpha: 0.04),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title.isNotEmpty) ...[
                Row(
                  children: [
                    Icon(
                      submission
                          ? Icons.upload_rounded
                          : Icons.description_rounded,
                      size: 18,
                      color: submission ? UiK.actionOrange : UiK.primaryBlue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: UiK.mainText,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              ..._renderHwLines(lines),
            ],
          ),
        ),
      );
    }

    return widgets;
  }

  List<Widget> _renderHwLines(List<String> lines) {
    final out = <Widget>[];
    for (final l in lines) {
      final t = l.trim();
      if (t.isEmpty) {
        out.add(const SizedBox(height: 8));
        continue;
      }

      final isBullet = t.startsWith('• ');
      if (isBullet) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '• ',
                  style: TextStyle(
                    color: UiK.mainText,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Expanded(child: Text(t.substring(2), style: UiK.subtleText())),
              ],
            ),
          ),
        );
      } else {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(t, style: UiK.subtleText()),
          ),
        );
      }
    }
    return out;
  }

  Widget _collapsibleText(String text) {
    return _ReadMore(
      text: text,
      collapsedLines: 6,
      style: UiK.subtleText(),
      linkStyle: const TextStyle(
        color: UiK.primaryBlue,
        fontWeight: FontWeight.w900,
      ),
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required Widget child,
    Color? accent,
    Widget? trailing,
  }) {
    final a = accent ?? UiK.primaryBlue;
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: a),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: UiK.mainText,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                ...?trailing == null ? null : [trailing],
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _miniChip({
    required IconData icon,
    required String text,
    Color? fg,
    Color? bg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
        color: bg ?? UiK.primaryBlue.withValues(alpha: 0.05),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg ?? UiK.primaryBlue),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: fg ?? UiK.mainText,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required String text,
    required IconData icon,
    required Color bg,
    required Color fg,
    bool dense = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 10 : 12,
        vertical: dense ? 6 : 8,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: bg,
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.70)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 14 : 16, color: fg),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: UiK.mainText,
              fontWeight: FontWeight.w900,
              fontSize: dense ? 12 : 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kpi({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
        color: UiK.primaryBlue.withValues(alpha: 0.04),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: UiK.actionOrange),
          const SizedBox(width: 10),
          Text(
            value,
            style: const TextStyle(
              color: UiK.mainText,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: UiK.mainText.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- Small UI model + ReadMore widget --------------------

class _TeacherMiniProfile {
  final String uid;
  final String name;
  final String photoUrl;
  final String aboutMe;
  final String introVideoUrl;
  final bool socialVisible;
  final Map<String, String> socialLinks;

  const _TeacherMiniProfile({
    required this.uid,
    required this.name,
    required this.photoUrl,
    required this.aboutMe,
    required this.introVideoUrl,
    required this.socialVisible,
    required this.socialLinks,
  });
}

class _TeacherSocialAction {
  final String key;
  final String label;
  final IconData icon;
  final String url;

  const _TeacherSocialAction({
    required this.key,
    required this.label,
    required this.icon,
    this.url = '',
  });

  _TeacherSocialAction copyWith({String? url}) {
    return _TeacherSocialAction(
      key: key,
      label: label,
      icon: icon,
      url: url ?? this.url,
    );
  }
}

class _MiniSecureVideoSheet extends StatefulWidget {
  final String title;
  final String url;

  const _MiniSecureVideoSheet({required this.title, required this.url});

  @override
  State<_MiniSecureVideoSheet> createState() => _MiniSecureVideoSheetState();
}

class _MiniSecureVideoSheetState extends State<_MiniSecureVideoSheet> {
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await c.initialize();
      await c.setLooping(false);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2C2C2C)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        )
                      : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'Video could not be loaded.',
                              style: TextStyle(
                                color: Colors.grey.shade300,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                      : VideoPlayer(c!),
                ),
              ),
              if (!_loading && _error == null && c != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () {
                        setState(() {
                          if (c.value.isPlaying) {
                            c.pause();
                          } else {
                            c.play();
                          }
                        });
                      },
                      icon: Icon(
                        c.value.isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailPrivateMeta {
  final String scheduleLine;
  final DateTime? nextStart;
  final int durationMinutes;
  final String meetUrl;
  final String teacherUid;

  const _DetailPrivateMeta({
    required this.scheduleLine,
    required this.nextStart,
    required this.durationMinutes,
    required this.meetUrl,
    required this.teacherUid,
  });
}

class _HwBlock {
  final String title;
  final List<String> lines;

  _HwBlock({required this.title, required this.lines});

  _HwBlock copyWith({String? title, List<String>? lines}) {
    return _HwBlock(title: title ?? this.title, lines: lines ?? this.lines);
  }
}

class _SkillTheme {
  final String label;
  final Color color;
  final IconData icon;

  const _SkillTheme(this.label, this.color, this.icon);
}

class _ReadMore extends StatefulWidget {
  final String text;
  final int collapsedLines;
  final TextStyle style;
  final TextStyle linkStyle;

  const _ReadMore({
    required this.text,
    this.collapsedLines = 6,
    required this.style,
    required this.linkStyle,
  });

  @override
  State<_ReadMore> createState() => _ReadMoreState();
}

class _ReadMoreState extends State<_ReadMore> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final span = TextSpan(text: widget.text, style: widget.style);
        final tp = TextPainter(
          text: span,
          maxLines: widget.collapsedLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: c.maxWidth);

        final overflow = tp.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: _expanded ? null : widget.collapsedLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflow) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'Show less' : 'Show more',
                  style: widget.linkStyle,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
