// ✅ FULL REPLACEMENT (SAFE): lib/teacher/teacher_classes_screen.dart
//
// ✅ In-class tab: unchanged behavior (your existing screens still used)
// ✅ Admin/teacher class matching logic kept
// ✅ Online tab: bookings + attendance ONLY (Present / Absent)
// ✅ Online UI shows learner NAMES (no UID shown anywhere)
// ✅ Online attendance saved in TWO places (safe):
//    A) online_attendance/<bookingKey>
//    B) booking_progress/<learnerUid>/<courseId>/online_attendance/<bookingKey>
//
// ✅ NEW UI:
// - follows app_theme.dart
// - cleaner, more professional cards
// - prettier tabs / summary / empty states
// - logic preserved

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/payment_status.dart';
import '../shared/responsive_layout.dart';
import '../shared/study_variant.dart';
import '../shared/teacher_web_layout.dart';
import 'teacher_learner_profile_screen.dart';
import 'take_attendance_screen.dart';
import 'teacher_class_progress_screen.dart';
import 'teacher_learner_gallery_screen.dart';

class TeacherClassesScreen extends StatefulWidget {
  const TeacherClassesScreen({
    super.key,
    this.initialMainTab = 0,
    this.initialOnlineTab = 0,
  });

  final int initialMainTab;
  final int initialOnlineTab;

  @override
  State<TeacherClassesScreen> createState() => _TeacherClassesScreenState();
}

class _TeacherClassesScreenState extends State<TeacherClassesScreen>
    with TickerProviderStateMixin {
  static const String usersNode = "users";
  static const String classesNode = "classes";
  static const String syllabiNode = "syllabi";

  static const String bookingReservationsNode = "booking_reservations";
  static const String bookingAvailabilityNode = "booking_availability";
  static const String onlineAttendanceNode = "online_attendance";
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

  List<Map<String, dynamic>> _myClasses = [];
  final Map<String, _ClassProg> _classProgCache = {};

  bool _onlineBusy = true;
  String? _onlineError;
  List<_OnlineBooking> _onlineAll = [];

  final Map<String, Map<String, String>> _learnerMiniCache = {};
  final Map<String, String> _learnerBioCache = {};
  final Map<String, Future<List<_TeacherHandoffRow>>> _handoffCache = {};
  final Map<String, String> _sessionTitleCache = {};
  final Map<String, String> _courseTitleCache = {};
  final Map<String, bool> _expandedBookingCards = {};
  final Map<String, bool> _expandedLearnersByBooking = {};

  late TabController _tab;
  late TabController _onlineTab;
  String? _desktopSelectedClassId;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _tab = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialMainTab.clamp(0, 1).toInt(),
    );
    _onlineTab = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialOnlineTab.clamp(0, 2).toInt(),
    );
    _loadAll();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _tab.dispose();
    _onlineTab.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.show(context, humanizeUiMessage(msg), type: AppToastType.info);
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

  static String _initials(String fullName) {
    final parts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'L';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  DateTime? _parseSlotStartCore(String dayKey, String hhmm) {
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

  Future<Map<String, String>> _loadLearnerMini(String uid) async {
    if (uid.isEmpty) {
      return {'full': '', 'profilePhoto': ''};
    }

    if (_learnerMiniCache.containsKey(uid)) {
      return _learnerMiniCache[uid]!;
    }

    try {
      final snap = await _usersRef.child(uid).get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final fn = _safeStr(m['first_name']);
        final ln = _safeStr(m['last_name']);
        final full = ('$fn $ln').trim();
        final profilePhoto = _safeStr(m['profile_photo']);

        final out = {'full': full, 'profilePhoto': profilePhoto};

        _learnerMiniCache[uid] = out;
        return out;
      }
    } catch (_) {}

    final out = {'full': '', 'profilePhoto': ''};
    _learnerMiniCache[uid] = out;
    return out;
  }

  Future<String> _loadLearnerBio(String uid) async {
    final key = uid.trim();
    if (key.isEmpty) return '';
    if (_learnerBioCache.containsKey(key)) return _learnerBioCache[key]!;

    try {
      final snap = await _usersRef.child(key).child('about_me').get();
      final bio = (snap.value ?? '').toString().trim();
      _learnerBioCache[key] = bio;
      return bio;
    } catch (_) {
      _learnerBioCache[key] = '';
      return '';
    }
  }

  String _fmtWhenFromRow(_TeacherHandoffRow row) {
    if (row.startAt > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(row.startAt);
      return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
    }
    if (row.dayKey.isNotEmpty && row.time.isNotEmpty) {
      return '${row.dayKey} ${row.time}';
    }
    if (row.dayKey.isNotEmpty) return row.dayKey;
    return '-';
  }

  _RatingUiTone _ratingTone(int rating) {
    final r = rating.clamp(0, 5);
    switch (r) {
      case 5:
        return const _RatingUiTone(
          star: Color(0xFFF59E0B),
          cardBg: Color(0xFFFFF8EB),
          cardBorder: Color(0xFFF2C46E),
          chipBg: Color(0xFFFDE7BF),
          chipText: Color(0xFF92400E),
        );
      case 4:
        return const _RatingUiTone(
          star: Color(0xFFFBBF24),
          cardBg: Color(0xFFFFFAEF),
          cardBorder: Color(0xFFF8D27A),
          chipBg: Color(0xFFFFEDC7),
          chipText: Color(0xFF92400E),
        );
      case 3:
        return const _RatingUiTone(
          star: Color(0xFF38BDF8),
          cardBg: Color(0xFFF0F9FF),
          cardBorder: Color(0xFF94D6F8),
          chipBg: Color(0xFFDDF2FF),
          chipText: Color(0xFF075985),
        );
      case 2:
        return const _RatingUiTone(
          star: Color(0xFFFB923C),
          cardBg: Color(0xFFFFF4EB),
          cardBorder: Color(0xFFF9BE8A),
          chipBg: Color(0xFFFFE3CC),
          chipText: Color(0xFF9A3412),
        );
      case 1:
        return const _RatingUiTone(
          star: Color(0xFFEF4444),
          cardBg: Color(0xFFFFEFF0),
          cardBorder: Color(0xFFF3A8AD),
          chipBg: Color(0xFFFFD5D8),
          chipText: Color(0xFF991B1B),
        );
      default:
        return _RatingUiTone(
          star: p.text.withValues(alpha: 0.45),
          cardBg: p.cardBg,
          cardBorder: p.border.withValues(alpha: 0.84),
          chipBg: p.soft.withValues(alpha: 0.26),
          chipText: p.text.withValues(alpha: 0.72),
        );
    }
  }

  Widget _handoffMetaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: p.border.withValues(alpha: 0.76)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: p.text.withValues(alpha: 0.82),
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Future<List<_TeacherHandoffRow>> _loadTeacherHandoffRows({
    required String learnerUid,
    required String courseId,
  }) async {
    final uid = learnerUid.trim();
    final cid = courseId.trim();
    if (uid.isEmpty || cid.isEmpty) return const [];

    final out = <_TeacherHandoffRow>[];
    try {
      final snap = await _db
          .child('$bookingProgressNode/$uid/$cid/online_attendance')
          .get();
      if (!snap.exists || snap.value is! Map) return out;

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      for (final e in raw.entries) {
        if (e.value is! Map) continue;
        final m = Map<String, dynamic>.from(e.value as Map);

        final sessionNo = _asInt(m['sessionNo']);
        final present = m['present'] == true;
        final dayKey = _safeStr(m['dayKey']);
        final time = _safeStr(m['time']);
        final startAt = _asInt(m['startAt']);
        final teacherName = _safeStr(
          m['teacherName'] ?? m['teacherNameFromBooking'],
        );
        final teacherRating = _asInt(m['teacherRating']).clamp(0, 5);
        final teacherComment = _safeStr(m['teacherComment']);
        final noteAt = _asInt(m['teacherCommentUpdatedAt']);

        out.add(
          _TeacherHandoffRow(
            bookingKey: e.key.toString(),
            sessionNo: sessionNo,
            present: present,
            dayKey: dayKey,
            time: time,
            startAt: startAt,
            teacherName: teacherName,
            teacherRating: teacherRating,
            teacherComment: teacherComment,
            noteUpdatedAt: noteAt,
          ),
        );
      }
    } catch (_) {}

    out.sort((a, b) => b.sortMs.compareTo(a.sortMs));
    return out;
  }

  Future<List<_TeacherHandoffRow>> _handoffRowsFor(
    String learnerUid,
    String courseId,
  ) {
    final key = '${learnerUid.trim()}|${courseId.trim()}';
    return _handoffCache.putIfAbsent(
      key,
      () => _loadTeacherHandoffRows(learnerUid: learnerUid, courseId: courseId),
    );
  }

  Future<void> _openLearnerHandoffSheet({
    required String learnerUid,
    required String courseId,
    required String courseTitle,
  }) async {
    final mini = await _loadLearnerMini(learnerUid);
    final name = (mini['full'] ?? '').trim().isEmpty
        ? 'Learner'
        : (mini['full'] ?? '').trim();
    final rows = await _handoffRowsFor(learnerUid, courseId);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final h = MediaQuery.of(ctx).size.height;
        final safeBottom = MediaQuery.of(ctx).viewPadding.bottom;
        final latestNote = rows.where((r) => r.teacherNoteExists).toList();
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + safeBottom),
            child: Container(
              height: h * 0.74,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFDF9),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: p.border.withValues(alpha: 0.78)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 28,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 10),
                children: [
                  Text(
                    '$name • ${courseTitle.trim().isEmpty ? courseId : courseTitle}',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: p.primary,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (latestNote.isNotEmpty) ...[
                    Text(
                      'Latest note for next teacher',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: p.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (_) {
                        final note = latestNote.first;
                        final tone = _ratingTone(note.teacherRating);
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: tone.cardBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: tone.cardBorder),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: tone.chipBg,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: tone.cardBorder),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'S${note.sessionNo <= 0 ? '-' : note.sessionNo}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: tone.chipText,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.star_rounded,
                                      size: 16,
                                      color: tone.star,
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      note.teacherRating > 0
                                          ? '${note.teacherRating}'
                                          : '-',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: tone.chipText,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                note.teacherComment.isEmpty
                                    ? 'No comment text.'
                                    : note.teacherComment,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: p.text.withValues(alpha: 0.84),
                                  height: 1.36,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 14),
                  ],
                  Text(
                    'Previous sessions (same course)',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: p.primary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (rows.isEmpty)
                    Text(
                      'No previous online flexible sessions found.',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: p.text.withValues(alpha: 0.75),
                      ),
                    )
                  else
                    ...rows.map((r) {
                      final tone = _ratingTone(r.teacherRating);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: r.teacherNoteExists ? tone.cardBg : p.cardBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: r.teacherNoteExists
                                ? tone.cardBorder
                                : p.border.withValues(alpha: 0.84),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                _handoffMetaChip(_fmtWhenFromRow(r)),
                                _handoffMetaChip(
                                  'Session ${r.sessionNo <= 0 ? '-' : r.sessionNo}',
                                ),
                                _handoffMetaChip(
                                  r.present ? 'Present' : 'Absent',
                                ),
                                _handoffMetaChip(
                                  r.teacherName.isEmpty
                                      ? 'Teacher'
                                      : r.teacherName,
                                ),
                                if (r.teacherNoteExists)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tone.chipBg,
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: tone.cardBorder,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.star_rounded,
                                          size: 14,
                                          color: tone.star,
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          r.teacherRating > 0
                                              ? '${r.teacherRating}'
                                              : '-',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: tone.chipText,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                            if (r.teacherComment.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                r.teacherComment,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: p.text.withValues(alpha: 0.82),
                                  height: 1.34,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _learnerAvatar({required String profilePhotoUrl, double size = 38}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: p.soft, shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      child: profilePhotoUrl.trim().isNotEmpty
          ? Image.network(
              profilePhotoUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Icons.person_rounded,
                size: size * 0.48,
                color: p.primary,
              ),
            )
          : Icon(Icons.person_rounded, size: size * 0.48, color: p.primary),
    );
  }

  Future<void> _loadAll() async {
    await _loadTeacherProfile();
    await Future.wait([_loadMyClasses(), _loadMyOnlineBookings()]);
  }

  Future<void> _loadTeacherProfile() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');

      _teacherUid = user.uid;

      final userSnap = await _usersRef.child(_teacherUid).get();
      if (!userSnap.exists) {
        throw Exception('Teacher record not found in /users/<uid>.');
      }

      final u = (userSnap.value is Map)
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};

      _teacherSerial = _safeStr(u['serial']);
      final fn = _safeStr(u['first_name']);
      final ln = _safeStr(u['last_name']);
      _teacherName = ('$fn $ln').trim();

      if (!_isTeacherRole(u['role'])) {
        throw Exception(
          'Your account role is not "teacher". Found: "${u['role']}"',
        );
      }
    } catch (e) {
      final humanError = toHumanError(e);
      setState(() {
        _error = humanError;
        _onlineError = humanError;
      });
    }
  }

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
            ? Map<String, dynamic>.from(value)
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

        final matchesName =
            _teacherName.isNotEmpty &&
            _norm(
                  legacyInstructorName.isNotEmpty
                      ? legacyInstructorName
                      : curName,
                ) ==
                _norm(_teacherName);

        final legacySerial = _safeStr(c['instructorserial'] ?? c['serial']);
        final matchesSerial =
            _teacherSerial.isNotEmpty && legacySerial == _teacherSerial;

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
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  int _learnersCount(Map<String, dynamic> classData) {
    final learners =
        classData['learners'] ??
        classData['students'] ??
        classData['enrolled_learners'] ??
        classData['enrolledLearners'];

    if (learners is Map) return learners.length;

    if (learners is List) {
      return learners.where((e) => e != null).length;
    }

    return 0;
  }

  List<Map<String, String>> _inClassLearnersList(
    Map<String, dynamic> classData,
  ) {
    final learners =
        classData['learners'] ??
        classData['students'] ??
        classData['enrolled_learners'] ??
        classData['enrolledLearners'];

    final List<Map<String, String>> out = [];

    if (learners is Map) {
      final Map<dynamic, dynamic> raw = Map<dynamic, dynamic>.from(learners);

      for (final entry in raw.entries) {
        final uid = entry.key.toString();
        final value = entry.value;

        if (value is Map) {
          final m = Map<String, dynamic>.from(value);

          final name = _safeStr(
            m['name'] ??
                m['full_name'] ??
                m['fullName'] ??
                m['student_name'] ??
                m['learner_name'],
          );

          final serial = _safeStr(m['serial']);

          out.add({'uid': uid, 'name': name, 'serial': serial});
        } else if (value is String) {
          out.add({'uid': uid, 'name': value.trim(), 'serial': ''});
        } else {
          out.add({'uid': uid, 'name': '', 'serial': ''});
        }
      }
    } else if (learners is List) {
      for (final item in learners) {
        if (item == null) continue;

        if (item is Map) {
          final m = Map<String, dynamic>.from(item);

          final uid = _safeStr(m['uid'] ?? m['learnerUid'] ?? m['studentUid']);
          final name = _safeStr(
            m['name'] ??
                m['full_name'] ??
                m['fullName'] ??
                m['student_name'] ??
                m['learner_name'],
          );
          final serial = _safeStr(m['serial']);

          out.add({'uid': uid, 'name': name, 'serial': serial});
        } else if (item is String) {
          out.add({'uid': item.trim(), 'name': '', 'serial': ''});
        }
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

  Future<_ClassProg> _loadClassProgress(
    String classId,
    Map<String, dynamic> classData,
  ) async {
    if (_classProgCache.containsKey(classId)) return _classProgCache[classId]!;

    final courseId = _safeStr(classData['course_id']);
    final rawVariant = _safeStr(classData['variantKey']).isNotEmpty
        ? classData['variantKey']
        : classData['variant'];
    final classVariant = normalizeVariantKey(_safeStr(rawVariant));
    final syllabusVariant = syllabusVariantForScheduledAttendance(classVariant);
    int totalLessons = 0;

    if (courseId.isNotEmpty) {
      var sSnap = await _syllabiRef
          .child(courseId)
          .child(syllabusVariant)
          .get();
      if ((!sSnap.exists || sSnap.value is! Map) &&
          syllabusVariant == 'private') {
        sSnap = await _syllabiRef.child(courseId).child('inclass').get();
      }
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

    final syllabusPct = totalLessons <= 0
        ? 0
        : ((coveredLessons / totalLessons) * 100).round().clamp(0, 100);

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

  Future<Map<String, dynamic>?> _loadOnlineSyllabusSession(
    String courseId,
    int sessionNo,
  ) async {
    if (courseId.isEmpty || sessionNo <= 0) return null;

    try {
      for (final variantKey in const ['flexible', 'private']) {
        final snap = await _db.child('syllabi/$courseId/$variantKey').get();
        if (!snap.exists || snap.value is! Map) continue;

        final root = (snap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final unitsRaw = root['units'];

        if (unitsRaw is! List) continue;

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
              final unitTitle = (unit['title'] ?? '').toString().trim();
              final unitOtherTitle = (unit['otherTitle'] ?? '')
                  .toString()
                  .trim();
              final unitOrder = _asInt(unit['order']);

              return {
                ...session,
                'variantKey': variantKey,
                'sessionNoResolved': sn > 0 ? sn : order,
                'unitTitle': unitTitle,
                'unitOtherTitle': unitOtherTitle,
                'unitOrder': unitOrder,
              };
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  Future<void> _openOnlineSessionDetailsSheet(
    String courseId,
    int sessionNo,
    String courseTitle,
    List<String> learnerUids,
    int startAtMillis,
    int bookingDurationMinutes,
  ) async {
    final info = await _loadOnlineSyllabusSession(courseId, sessionNo);
    if (!mounted) return;

    if (info == null) {
      _toast('Online session details not found.');
      return;
    }

    final titleRaw = (info['title'] ?? '').toString().trim();
    final resolvedSessionNo = _asInt(info['sessionNoResolved']);
    final shownSessionNo = resolvedSessionNo > 0
        ? resolvedSessionNo
        : sessionNo;
    final title = titleRaw.isEmpty
        ? 'Session $shownSessionNo'
        : 'Session $shownSessionNo — $titleRaw';

    final courseLabel = courseTitle.trim().isEmpty ? courseId : courseTitle;

    final objective = (info['objective'] ?? '').toString().trim();
    final content = (info['content'] ?? '').toString().trim();
    final homework = (info['homework'] ?? '').toString().trim();
    final materialsUrl = (info['materialsUrl'] ?? '').toString().trim();
    final duration = _asInt(info['durationMinutes'] ?? 0) > 0
        ? _asInt(info['durationMinutes'] ?? 0)
        : bookingDurationMinutes;
    final skillType = (info['skillType'] ?? '').toString().trim();
    final unitTitle = (info['unitTitle'] ?? '').toString().trim();
    final unitOrder = _asInt(info['unitOrder']);
    final unitLabel = unitTitle.isEmpty
        ? '-'
        : (unitOrder > 0 ? 'Unit $unitOrder: $unitTitle' : unitTitle);
    final variantKey = (info['variantKey'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final variantLabel = switch (variantKey) {
      'inclass' => 'In-Class',
      'private' => 'Private',
      'flexible' => 'Flexible',
      'recorded' => 'Recorded',
      _ => '-',
    };
    final unitOtherTitle = (info['unitOtherTitle'] ?? '').toString().trim();

    final startsAt = DateTime.fromMillisecondsSinceEpoch(startAtMillis);
    final endsAt = startsAt.add(Duration(minutes: bookingDurationMinutes));
    final now = DateTime.now();
    final inWindow = _isInJoinWindow(startsAt, bookingDurationMinutes);
    final isUpcoming = startsAt.isAfter(now) && !inWindow;
    final statusText = inWindow ? 'Live' : (isUpcoming ? 'Upcoming' : 'Past');
    final statusBg = inWindow
        ? const Color(0xFFEAF7EE)
        : (isUpcoming
              ? p.accent.withValues(alpha: 0.12)
              : p.soft.withValues(alpha: 0.65));
    final statusBorder = inWindow
        ? const Color(0xFFB9E2C5)
        : (isUpcoming
              ? p.accent.withValues(alpha: 0.28)
              : p.border.withValues(alpha: 0.82));
    final statusColor = inWindow ? const Color(0xFF166534) : p.primary;
    final whenText =
        '${startsAt.year}-${_two(startsAt.month)}-${_two(startsAt.day)} ${_two(startsAt.hour)}:${_two(startsAt.minute)}';
    final endText =
        '${endsAt.year}-${_two(endsAt.month)}-${_two(endsAt.day)} ${_two(endsAt.hour)}:${_two(endsAt.minute)}';
    final uniqueLearners = learnerUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    var selectedLearnerUid = uniqueLearners.isEmpty ? '' : uniqueLearners.first;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (modalCtx) {
        final bottomPad = MediaQuery.of(modalCtx).viewPadding.bottom;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
            child: DefaultTabController(
              length: 2,
              child: SizedBox(
                height: MediaQuery.of(modalCtx).size.height * 0.84,
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8FA),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.75),
                        ),
                      ),
                      child: TabBar(
                        labelColor: p.primary,
                        unselectedLabelColor: p.text.withValues(alpha: 0.65),
                        indicator: BoxDecoration(
                          color: p.cardBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: p.accent.withValues(alpha: 0.35),
                          ),
                        ),
                        tabs: const [
                          Tab(text: 'Course Details'),
                          Tab(text: 'Learners'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TabBarView(
                        children: [
                          SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFFFFFCF6),
                                        Color(0xFFF9FBFF),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: p.border.withValues(alpha: 0.85),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 52,
                                        height: 5,
                                        decoration: BoxDecoration(
                                          color: p.accent.withValues(
                                            alpha: 0.75,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              title,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 16,
                                                color: p.primary,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: statusBg,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                color: statusBorder,
                                              ),
                                            ),
                                            child: Text(
                                              statusText,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: statusColor,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        'Course: $courseLabel',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: p.text.withValues(alpha: 0.78),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '$whenText - $endText',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: p.text.withValues(alpha: 0.72),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _detailsChip(
                                      Icons.layers_rounded,
                                      'Variant',
                                      variantLabel,
                                    ),
                                    _detailsChip(
                                      Icons.widgets_rounded,
                                      'Unit',
                                      unitLabel,
                                    ),
                                    _detailsChip(
                                      Icons.school_rounded,
                                      'Skill',
                                      skillType.isEmpty ? '-' : skillType,
                                    ),
                                    _detailsChip(
                                      Icons.timer_outlined,
                                      'Duration',
                                      duration > 0 ? '$duration min' : '-',
                                    ),
                                    if (unitOtherTitle.isNotEmpty)
                                      _detailsChip(
                                        Icons.category_rounded,
                                        'Module',
                                        unitOtherTitle,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _detailsSectionCard(
                                  icon: Icons.flag_rounded,
                                  iconColor: const Color(0xFFCC5803),
                                  title: 'Objective',
                                  body: objective,
                                ),
                                const SizedBox(height: 10),
                                _detailsSectionCard(
                                  icon: Icons.list_alt_rounded,
                                  iconColor: const Color(0xFF0D9488),
                                  title: 'Content',
                                  body: content,
                                ),
                                const SizedBox(height: 10),
                                _detailsSectionCard(
                                  icon: Icons.assignment_rounded,
                                  iconColor: const Color(0xFFB45309),
                                  title: 'Homework',
                                  body: homework,
                                ),
                                if (materialsUrl.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: p.accent.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: p.accent.withValues(alpha: 0.25),
                                      ),
                                    ),
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: p.accent,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      onPressed: () =>
                                          _openExternalUrl(materialsUrl),
                                      icon: const Icon(Icons.slideshow_rounded),
                                      label: const Text(
                                        'Open materials',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          StatefulBuilder(
                            builder: (context, setLocal) {
                              if (uniqueLearners.isEmpty) {
                                return Center(
                                  child: Text(
                                    'No learners linked to this booking.',
                                    style: TextStyle(
                                      color: p.text.withValues(alpha: 0.75),
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                );
                              }

                              return Column(
                                children: [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: uniqueLearners.map((uid) {
                                        return FutureBuilder<
                                          Map<String, String>
                                        >(
                                          future: _loadLearnerMini(uid),
                                          builder: (context, snap) {
                                            final name =
                                                (snap.data?['full'] ?? '')
                                                    .trim();
                                            return ChoiceChip(
                                              selected:
                                                  selectedLearnerUid == uid,
                                              selectedColor: p.accent
                                                  .withValues(alpha: 0.2),
                                              backgroundColor: p.soft
                                                  .withValues(alpha: 0.2),
                                              side: BorderSide(
                                                color: selectedLearnerUid == uid
                                                    ? p.accent.withValues(
                                                        alpha: 0.4,
                                                      )
                                                    : p.border.withValues(
                                                        alpha: 0.82,
                                                      ),
                                              ),
                                              onSelected: (_) => setLocal(
                                                () => selectedLearnerUid = uid,
                                              ),
                                              label: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  CircleAvatar(
                                                    radius: 10,
                                                    backgroundColor:
                                                        selectedLearnerUid ==
                                                            uid
                                                        ? p.accent.withValues(
                                                            alpha: 0.25,
                                                          )
                                                        : p.soft,
                                                    child: Text(
                                                      _initials(name),
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                        color: p.primary,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 7),
                                                  Text(
                                                    name.isEmpty
                                                        ? 'Learner'
                                                        : name,
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color:
                                                          selectedLearnerUid ==
                                                              uid
                                                          ? p.primary
                                                          : p.text,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Expanded(
                                    child: FutureBuilder<Map<String, String>>(
                                      future: _loadLearnerMini(
                                        selectedLearnerUid,
                                      ),
                                      builder: (context, miniSnap) {
                                        final mini =
                                            miniSnap.data ??
                                            const <String, String>{};
                                        final name =
                                            (mini['full'] ?? '').trim().isEmpty
                                            ? 'Learner'
                                            : mini['full']!.trim();

                                        return FutureBuilder<String>(
                                          future: _loadLearnerBio(
                                            selectedLearnerUid,
                                          ),
                                          builder: (context, bioSnap) {
                                            final bio = (bioSnap.data ?? '')
                                                .trim();
                                            return ListView(
                                              children: [
                                                Container(
                                                  width: double.infinity,
                                                  padding: const EdgeInsets.all(
                                                    12,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: p.soft.withValues(
                                                      alpha: 0.16,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          14,
                                                        ),
                                                    border: Border.all(
                                                      color: p.border
                                                          .withValues(
                                                            alpha: 0.82,
                                                          ),
                                                    ),
                                                  ),
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        name,
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          fontSize: 16,
                                                          color: p.primary,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 8),
                                                      Text(
                                                        bio.isEmpty
                                                            ? 'No profile bio yet.'
                                                            : bio,
                                                        style: TextStyle(
                                                          color: p.text
                                                              .withValues(
                                                                alpha: 0.8,
                                                              ),
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          height: 1.4,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                FutureBuilder<
                                                  List<_TeacherHandoffRow>
                                                >(
                                                  future: _handoffRowsFor(
                                                    selectedLearnerUid,
                                                    courseId,
                                                  ),
                                                  builder: (context, hsnap) {
                                                    final rows =
                                                        hsnap.data ??
                                                        const <
                                                          _TeacherHandoffRow
                                                        >[];
                                                    final latest = rows
                                                        .where(
                                                          (r) => r
                                                              .teacherNoteExists,
                                                        )
                                                        .toList();

                                                    return Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          'Previous sessions (same course)',
                                                          style: TextStyle(
                                                            fontWeight:
                                                                FontWeight.w900,
                                                            color: p.primary,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          height: 8,
                                                        ),
                                                        if (hsnap
                                                                .connectionState ==
                                                            ConnectionState
                                                                .waiting)
                                                          Padding(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  vertical: 8,
                                                                ),
                                                            child: SizedBox(
                                                              width: 18,
                                                              height: 18,
                                                              child:
                                                                  CircularProgressIndicator(
                                                                    strokeWidth:
                                                                        2,
                                                                    color: p
                                                                        .accent,
                                                                  ),
                                                            ),
                                                          )
                                                        else if (rows.isEmpty)
                                                          Text(
                                                            'No previous flexible sessions found.',
                                                            style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                              color: p.text
                                                                  .withValues(
                                                                    alpha: 0.75,
                                                                  ),
                                                            ),
                                                          )
                                                        else ...[
                                                          if (latest.isNotEmpty)
                                                            Builder(
                                                              builder: (context) {
                                                                final tone =
                                                                    _ratingTone(
                                                                      latest
                                                                          .first
                                                                          .teacherRating,
                                                                    );
                                                                return Container(
                                                                  margin:
                                                                      const EdgeInsets.only(
                                                                        bottom:
                                                                            10,
                                                                      ),
                                                                  padding:
                                                                      const EdgeInsets.all(
                                                                        10,
                                                                      ),
                                                                  decoration: BoxDecoration(
                                                                    color: tone
                                                                        .cardBg,
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          12,
                                                                        ),
                                                                    border: Border.all(
                                                                      color: tone
                                                                          .cardBorder,
                                                                    ),
                                                                  ),
                                                                  child: Row(
                                                                    children: [
                                                                      Icon(
                                                                        Icons
                                                                            .star_rounded,
                                                                        color: tone
                                                                            .star,
                                                                        size:
                                                                            18,
                                                                      ),
                                                                      const SizedBox(
                                                                        width:
                                                                            6,
                                                                      ),
                                                                      Expanded(
                                                                        child: Text(
                                                                          'Latest note: ${latest.first.teacherRating > 0 ? '${latest.first.teacherRating}★' : 'No stars'}${latest.first.teacherComment.isEmpty ? '' : ' • ${latest.first.teacherComment}'}',
                                                                          style: TextStyle(
                                                                            fontWeight:
                                                                                FontWeight.w800,
                                                                            color: p.text.withValues(
                                                                              alpha: 0.82,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                );
                                                              },
                                                            ),
                                                          ...rows.take(12).map((
                                                            r,
                                                          ) {
                                                            final tone =
                                                                _ratingTone(
                                                                  r.teacherRating,
                                                                );
                                                            return Row(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              children: [
                                                                Container(
                                                                  margin:
                                                                      const EdgeInsets.only(
                                                                        top: 9,
                                                                      ),
                                                                  width: 10,
                                                                  height: 10,
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        r.teacherNoteExists
                                                                        ? tone.star
                                                                        : p.border,
                                                                    shape: BoxShape
                                                                        .circle,
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                  width: 8,
                                                                ),
                                                                Expanded(
                                                                  child: Container(
                                                                    margin:
                                                                        const EdgeInsets.only(
                                                                          bottom:
                                                                              10,
                                                                        ),
                                                                    padding:
                                                                        const EdgeInsets.all(
                                                                          10,
                                                                        ),
                                                                    decoration: BoxDecoration(
                                                                      color:
                                                                          r.teacherNoteExists
                                                                          ? tone.cardBg
                                                                          : p.cardBg,
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                            12,
                                                                          ),
                                                                      border: Border.all(
                                                                        color:
                                                                            r.teacherNoteExists
                                                                            ? tone.cardBorder
                                                                            : p.border.withValues(
                                                                                alpha: 0.84,
                                                                              ),
                                                                      ),
                                                                    ),
                                                                    child: Column(
                                                                      crossAxisAlignment:
                                                                          CrossAxisAlignment
                                                                              .start,
                                                                      children: [
                                                                        Text(
                                                                          '${_fmtWhenFromRow(r)} • Session ${r.sessionNo <= 0 ? '-' : r.sessionNo}',
                                                                          style: TextStyle(
                                                                            fontWeight:
                                                                                FontWeight.w900,
                                                                            color:
                                                                                p.primary,
                                                                          ),
                                                                        ),
                                                                        const SizedBox(
                                                                          height:
                                                                              5,
                                                                        ),
                                                                        Text(
                                                                          '${r.present ? 'Present' : 'Absent'}${r.teacherName.isEmpty ? '' : ' • ${r.teacherName}'}${r.teacherRating > 0 ? ' • ${r.teacherRating}★' : ''}',
                                                                          style: TextStyle(
                                                                            fontWeight:
                                                                                FontWeight.w700,
                                                                            color: p.text.withValues(
                                                                              alpha: 0.82,
                                                                            ),
                                                                          ),
                                                                        ),
                                                                        if (r
                                                                            .teacherComment
                                                                            .isNotEmpty) ...[
                                                                          const SizedBox(
                                                                            height:
                                                                                6,
                                                                          ),
                                                                          Text(
                                                                            r.teacherComment,
                                                                            style: TextStyle(
                                                                              fontWeight: FontWeight.w700,
                                                                              color: p.text.withValues(
                                                                                alpha: 0.8,
                                                                              ),
                                                                              height: 1.35,
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ],
                                                                    ),
                                                                  ),
                                                                ),
                                                              ],
                                                            );
                                                          }),
                                                        ],
                                                        const SizedBox(
                                                          height: 12,
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                                SizedBox(
                                                  width: double.infinity,
                                                  child: FilledButton.icon(
                                                    style: FilledButton.styleFrom(
                                                      backgroundColor:
                                                          p.primary,
                                                      foregroundColor:
                                                          Colors.white,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              12,
                                                            ),
                                                      ),
                                                    ),
                                                    onPressed: () {
                                                      Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (_) =>
                                                              TeacherLearnerProfileScreen(
                                                                learnerUid:
                                                                    selectedLearnerUid,
                                                                learnerName:
                                                                    name,
                                                              ),
                                                        ),
                                                      );
                                                    },
                                                    icon: const Icon(
                                                      Icons
                                                          .person_outline_rounded,
                                                    ),
                                                    label: const Text(
                                                      'Open full learner profile',
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: p.border.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.only(top: 10),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.primary,
                          side: BorderSide(color: p.border),
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
          ),
        );
      },
    );
  }

  Widget _detailsChip(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border.withValues(alpha: 0.84)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: p.accent),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: p.text.withValues(alpha: 0.84),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsSectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String body,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFDFE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.w900, color: p.primary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body.isEmpty ? 'No ${title.toLowerCase()} set yet.' : body,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: p.text.withValues(alpha: 0.8),
              height: 1.42,
            ),
          ),
        ],
      ),
    );
  }

  Future<String> _loadCourseTitle(
    String courseId,
    List<String> learnerUids,
  ) async {
    if (courseId.isEmpty) return '';
    if (_courseTitleCache.containsKey(courseId)) {
      return _courseTitleCache[courseId]!;
    }

    try {
      for (final learnerUid in learnerUids) {
        if (learnerUid.trim().isEmpty) continue;

        final snap = await _usersRef.child(learnerUid).child('courses').get();
        if (!snap.exists || snap.value == null || snap.value is! Map) continue;

        final raw = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in raw.entries) {
          final value = entry.value;
          if (value is! Map) continue;

          final courseMap = Map<String, dynamic>.from(value);
          final id = _safeStr(courseMap['id']);
          if (id != courseId) continue;

          final title = _safeStr(
            courseMap['title'] ?? courseMap['course_title'],
          );
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
    try {
      if (teacherId.isEmpty) {
        return const _AvailMeta.empty();
      }

      String meetUrl = '';
      try {
        final meetSnap = await _db
            .child('users/$teacherId/google_meet_url')
            .get();
        meetUrl = _safeStr(meetSnap.value);
      } catch (_) {}

      if (courseId.isEmpty) {
        return _AvailMeta(
          meetUrl: meetUrl,
          durationMinutes: 60,
          teacherName: '',
        );
      }

      final snap = await _db
          .child('$bookingAvailabilityNode/$teacherId/$courseId')
          .get();
      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        int dur = _asInt(
          m['durationMinutes'] ?? m['durationMin'] ?? m['duration'],
        );
        if (dur <= 0) dur = 60;

        final teacherName = _safeStr(m['teacherName'] ?? m['teacher_name']);
        return _AvailMeta(
          meetUrl: meetUrl,
          durationMinutes: dur,
          teacherName: teacherName,
        );
      }

      if (meetUrl.isNotEmpty) {
        return _AvailMeta(
          meetUrl: meetUrl,
          durationMinutes: 60,
          teacherName: '',
        );
      }
    } catch (_) {}
    return const _AvailMeta.empty();
  }

  bool _isInJoinWindow(DateTime start, int durationMinutes) {
    final now = DateTime.now();
    final openFrom = start.subtract(const Duration(minutes: 10));
    final dur = durationMinutes <= 0 ? 60 : durationMinutes;
    final openUntil = start
        .add(Duration(minutes: dur))
        .add(const Duration(minutes: 15));
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
      if (!rootSnap.exists ||
          rootSnap.value == null ||
          rootSnap.value is! Map) {
        setState(() {
          _onlineAll = [];
          _onlineBusy = false;
        });
        return;
      }

      final Map<dynamic, dynamic> byCourse = Map<dynamic, dynamic>.from(
        rootSnap.value as Map,
      );
      final List<_OnlineBooking> out = [];

      for (final courseEntry in byCourse.entries) {
        final courseId = courseEntry.key.toString();
        final courseNode = courseEntry.value;
        if (courseNode is! Map) continue;

        final Map<dynamic, dynamic> byDate = Map<dynamic, dynamic>.from(
          courseNode,
        );

        for (final dateEntry in byDate.entries) {
          final dayKey = dateEntry.key.toString();
          final dateNode = dateEntry.value;
          if (dateNode is! Map) continue;

          final Map<dynamic, dynamic> byTime = Map<dynamic, dynamic>.from(
            dateNode,
          );

          for (final timeEntry in byTime.entries) {
            final hhmm = timeEntry.key.toString();
            final dt = _parseSlotStartCore(dayKey, hhmm);
            if (dt == null) continue;

            Future<void> ingestSlot(
              Map<String, dynamic> slot, {
              String fallbackTeacherId = '',
            }) async {
              final teacherId = _safeStr(
                slot['teacherId'] ??
                    slot['teacherUid'] ??
                    slot['teacher_id'] ??
                    fallbackTeacherId,
              );
              if (teacherId != _teacherUid) return;

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
                            : (_teacherName.isNotEmpty
                                  ? _teacherName
                                  : 'Teacher')),
                  learnerUids: learnerUids,
                  sessionNo: sessionNo,
                  createdAtRaw: createdAt,
                  meetUrl: meta.meetUrl,
                  durationMinutes: meta.durationMinutes <= 0
                      ? 60
                      : meta.durationMinutes,
                ),
              );
            }

            final slotNode = timeEntry.value;
            if (slotNode is! Map) continue;

            final firstMapValue = slotNode.values.isNotEmpty
                ? slotNode.values.first
                : null;
            final looksLikeDirectSlot =
                slotNode.containsKey('teacherId') ||
                slotNode.containsKey('teacherUid') ||
                slotNode.containsKey('teacher_id') ||
                slotNode.containsKey('learners') ||
                slotNode.containsKey('sessionNo');

            if (looksLikeDirectSlot) {
              await ingestSlot(
                slotNode.map((k, v) => MapEntry(k.toString(), v)),
              );
              continue;
            }

            if (firstMapValue is Map) {
              final nestedByTeacher = Map<dynamic, dynamic>.from(slotNode);
              for (final teacherEntry in nestedByTeacher.entries) {
                final nestedSlotRaw = teacherEntry.value;
                if (nestedSlotRaw is! Map) continue;
                await ingestSlot(
                  nestedSlotRaw.map((k, v) => MapEntry(k.toString(), v)),
                  fallbackTeacherId: teacherEntry.key.toString(),
                );
              }
            }
          }
        }
      }

      out.sort((a, b) => a.startAtMillis.compareTo(b.startAtMillis));

      setState(() {
        _onlineAll = out;
        _onlineBusy = false;
      });
    } catch (e) {
      setState(() {
        _onlineError = toHumanError(e);
        _onlineBusy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'My Teaching',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Classes, online sessions, and attendance',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tab,
          labelColor: p.primary,
          unselectedLabelColor: p.text.withValues(alpha: 0.62),
          indicatorColor: p.accent,
          tabs: const [
            Tab(icon: Icon(Icons.groups_rounded), text: 'In-class'),
            Tab(icon: Icon(Icons.wifi_tethering_rounded), text: 'Online'),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: () async {
              await _loadAll();
              _toast('Refreshed ✅');
            },
          ),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1640,
        child: SafeArea(
          top: false,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.045,
                    child: Center(
                      child: FractionallySizedBox(
                        widthFactor: 0.76,
                        child: Image.asset(
                          'assets/images/ybs_logo.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              TabBarView(
                controller: _tab,
                children: [_buildInClassTab(), _buildOnlineTab()],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInClassTab() {
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );
    final safeBottom = MediaQuery.of(context).viewPadding.bottom;

    if (_busy) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }

    if (_error != null) {
      return Center(
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
      );
    }

    if (!desktopWorkspace) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + safeBottom + 10),
        children: [
          if (_myClasses.isEmpty)
            _emptyState('No classes found for you yet.')
          else
            ..._myClasses.map((c) => _classCard(c)),
        ],
      );
    }

    if (_myClasses.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + safeBottom + 10),
        children: [_emptyState('No classes found for you yet.')],
      );
    }

    Map<String, dynamic> selectedClass = _myClasses.first;
    final selectedId = (_desktopSelectedClassId ?? '').trim();
    if (selectedId.isNotEmpty) {
      for (final c in _myClasses) {
        final cid = _safeStr(c['id'] ?? c['class_id']);
        if (cid == selectedId) {
          selectedClass = c;
          break;
        }
      }
    }

    final activeClassId = _safeStr(
      selectedClass['id'] ?? selectedClass['class_id'],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 380,
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + safeBottom + 10),
            children: _myClasses.map((c) {
              final classId = _safeStr(c['id'] ?? c['class_id']);
              final title = _safeStr(c['course_title']).isEmpty
                  ? 'Class'
                  : _safeStr(c['course_title']);
              return _desktopClassPickerTile(
                title: title,
                learnersCount: _learnersCount(c),
                firstSession: _firstSessionDate(c),
                selected: classId == activeClassId,
                onTap: () => setState(() => _desktopSelectedClassId = classId),
              );
            }).toList(),
          ),
        ),
        Container(width: 1, color: p.border.withValues(alpha: 0.7)),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + safeBottom + 10),
            children: [_classCard(selectedClass)],
          ),
        ),
      ],
    );
  }

  Widget _desktopClassPickerTile({
    required String title,
    required int learnersCount,
    required String firstSession,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: selected ? p.soft.withValues(alpha: 0.65) : p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: selected
              ? p.accent.withValues(alpha: 0.55)
              : p.border.withValues(alpha: 0.88),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 8),
              _miniInfoLine(Icons.groups_rounded, 'Learners', '$learnersCount'),
              const SizedBox(height: 4),
              _miniInfoLine(Icons.event_rounded, 'First session', firstSession),
            ],
          ),
        ),
      ),
    );
  }

  Widget _classCard(Map<String, dynamic> c) {
    final classId = _safeStr(c['id'] ?? c['class_id']);
    final title = _safeStr(c['course_title']).isEmpty
        ? 'Class'
        : _safeStr(c['course_title']);
    final duration = _safeStr(c['course_duration']);
    final classTitle = title;
    final learnersCount = _learnersCount(c);
    final learnersList = _inClassLearnersList(c);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        collapsedIconColor: p.primary,
        iconColor: p.primary,
        title: Text(
          title,
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _miniInfoLine(
                Icons.timelapse_rounded,
                'Duration',
                duration.isEmpty ? '-' : duration,
              ),
              const SizedBox(height: 4),
              _miniInfoLine(
                Icons.event_rounded,
                'First session',
                _firstSessionDate(c),
              ),
              const SizedBox(height: 4),
              _miniInfoLine(Icons.groups_rounded, 'Learners', '$learnersCount'),
              const SizedBox(height: 12),
              FutureBuilder<_ClassProg>(
                future: classId.isEmpty
                    ? Future.value(_ClassProg.zero())
                    : _loadClassProgress(classId, c),
                builder: (context, snap) {
                  final prog = snap.data ?? _ClassProg.zero();

                  final plannedMeetingsStr =
                      (prog.plannedMeetings == null ||
                          prog.plannedMeetings! <= 0)
                      ? '-'
                      : '${prog.plannedMeetings}';

                  final syllabusTotalStr = prog.totalLessons <= 0
                      ? '-'
                      : '${prog.totalLessons}';
                  final syllabusPct = prog.syllabusPercent.clamp(0, 100);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _miniInfoLine(
                        Icons.event_available_rounded,
                        'Meetings',
                        '${prog.meetingsHeld}/$plannedMeetingsStr',
                      ),
                      const SizedBox(height: 4),
                      _miniInfoLine(
                        Icons.menu_book_rounded,
                        'Syllabus',
                        '${prog.coveredLessons}/$syllabusTotalStr  •  $syllabusPct%',
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: prog.totalLessons <= 0
                              ? 0
                              : (prog.coveredLessons / prog.totalLessons).clamp(
                                  0,
                                  1,
                                ),
                          minHeight: 9,
                          backgroundColor: p.primary.withValues(alpha: 0.10),
                          valueColor: AlwaysStoppedAnimation(p.accent),
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
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.soft.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Learners',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 10),
                if (learnersList.isEmpty)
                  Text(
                    'No learners found in this class.',
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  ...learnersList.map((learner) {
                    final name = _safeStr(learner['name']);
                    final learnerUid = _safeStr(learner['uid']);
                    final learnerDisplayName = name.isEmpty ? 'Learner' : name;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.8),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              FutureBuilder<Map<String, String>>(
                                future: _loadLearnerMini(learnerUid),
                                builder: (context, snap) {
                                  final profilePhotoUrl =
                                      (snap.data?['profilePhoto'] ?? '').trim();

                                  return _learnerAvatar(
                                    profilePhotoUrl: profilePhotoUrl,
                                    size: 38,
                                  );
                                },
                              ),

                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  learnerDisplayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.text,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(
                                    Icons.person_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Profile'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: p.primary,
                                    side: BorderSide(color: p.border),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    textStyle: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onPressed: learnerUid.isEmpty
                                      ? null
                                      : () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  TeacherLearnerProfileScreen(
                                                    learnerUid: learnerUid,
                                                    learnerName:
                                                        learnerDisplayName,
                                                  ),
                                            ),
                                          );
                                        },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(
                                    Icons.assessment_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Report'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: p.primary,
                                    side: BorderSide(color: p.border),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    textStyle: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onPressed: learnerUid.isEmpty
                                      ? null
                                      : () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  TeacherLearnerProfileScreen(
                                                    learnerUid: learnerUid,
                                                    learnerName:
                                                        learnerDisplayName,
                                                    openReportComposerOnLoad:
                                                        true,
                                                    initialCourseTitle:
                                                        classTitle,
                                                  ),
                                            ),
                                          );
                                        },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(
                                    Icons.photo_library_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Gallery'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: p.primary,
                                    side: BorderSide(color: p.border),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    textStyle: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onPressed: learnerUid.isEmpty
                                      ? null
                                      : () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  TeacherLearnerGalleryScreen(
                                                    learnerUid: learnerUid,
                                                    learnerName:
                                                        learnerDisplayName,
                                                    classId: classId,
                                                    classTitle: classTitle,
                                                  ),
                                            ),
                                          );
                                        },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.fact_check_rounded),
                  label: const Text("Take"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TakeAttendanceScreen(classData: c),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: Icon(Icons.insights_rounded, color: p.primary),
                  label: Text(
                    "Progress",
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: p.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: classId.isEmpty
                      ? null
                      : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => TeacherClassProgressScreen(
                                classId: classId,
                                classData: c,
                              ),
                            ),
                          );
                        },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniInfoLine(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 15, color: p.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label: $value',
            style: TextStyle(
              color: p.text.withValues(alpha: 0.80),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOnlineTab() {
    final desktopWorkspace = AppResponsive.isWebDesktop(
      context,
      minWidth: 1280,
    );

    if (_onlineBusy) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }

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
      return _emptyState('No online bookings found for you yet.');
    }

    final now = DateTime.now();
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

      past.add(b);
    }

    return Column(
      children: [
        if (desktopWorkspace)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: _emptyHint('Live: ${startingOrOngoing.length}'),
                ),
                const SizedBox(width: 10),
                Expanded(child: _emptyHint('Upcoming: ${upcoming.length}')),
                const SizedBox(width: 10),
                Expanded(child: _emptyHint('Past: ${past.length}')),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
            ),
            child: TabBar(
              controller: _onlineTab,
              labelColor: p.primary,
              unselectedLabelColor: p.text.withValues(alpha: 0.62),
              indicatorColor: p.accent,
              tabs: [
                Tab(text: 'Past (${past.length})'),
                Tab(text: 'Live (${startingOrOngoing.length})'),
                Tab(text: 'Upcoming (${upcoming.length})'),
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
                items: past.reversed.toList(),
                emptyText: 'No past sessions yet.',
                groupByWeek: true,
              ),
              _onlineBookingsList(
                items: startingOrOngoing,
                emptyText: 'No ongoing sessions right now.',
              ),
              _onlineBookingsList(
                items: upcoming,
                emptyText: 'No upcoming sessions.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _onlineBookingsList({
    required List<_OnlineBooking> items,
    required String emptyText,
    bool groupByWeek = false,
  }) {
    final safeBottom = MediaQuery.of(context).viewPadding.bottom;
    final bottomGap = 16.0 + safeBottom + 10;
    if (items.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
        children: [_emptyHint(emptyText)],
      );
    }

    if (groupByWeek) {
      final Map<DateTime, List<_OnlineBooking>> byWeek = {};
      for (final booking in items) {
        final dt = DateTime.fromMillisecondsSinceEpoch(booking.startAtMillis);
        final weekStart = _weekStartMonday(dt);
        byWeek.putIfAbsent(weekStart, () => []).add(booking);
      }

      final weekStarts = byWeek.keys.toList()..sort((a, b) => b.compareTo(a));

      final children = <Widget>[];
      for (final weekStart in weekStarts) {
        children.add(_weekHeader(weekStart));
        final weekItems = byWeek[weekStart] ?? const <_OnlineBooking>[];
        for (final booking in weekItems) {
          children.add(_bookingCard(booking));
        }
      }

      return ListView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
        children: children,
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomGap),
      children: items.map(_bookingCard).toList(),
    );
  }

  DateTime _weekStartMonday(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    return d.subtract(Duration(days: d.weekday - DateTime.monday));
  }

  Widget _weekHeader(DateTime weekStart) {
    final weekEnd = weekStart.add(const Duration(days: 6));
    final fmt = DateFormat('yyyy-MM-dd');
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
      child: Text(
        'Week of ${fmt.format(weekStart)} - ${fmt.format(weekEnd)}',
        style: TextStyle(
          color: p.primary,
          fontWeight: FontWeight.w900,
          fontSize: 13,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _emptyHint(String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: p.text.withValues(alpha: 0.72),
        ),
      ),
    );
  }

  Widget _bookingCard(_OnlineBooking b) {
    final dt = DateTime.fromMillisecondsSinceEpoch(b.startAtMillis);
    final endAt = dt.add(Duration(minutes: b.durationMinutes));
    final classPassed = !DateTime.now().isBefore(endAt);
    final expanded = _expandedBookingCards[b.bookingKey] == true;
    final when =
        '${dt.year}-${_two(dt.month)}-${_two(dt.day)}  ${_two(dt.hour)}:${_two(dt.minute)}';

    final inWindow = _isInJoinWindow(dt, b.durationMinutes);
    final statusText = inWindow
        ? 'Ongoing / join window'
        : dt.isAfter(DateTime.now())
        ? 'Upcoming'
        : 'Past';

    final statusBg = inWindow
        ? const Color(0xFFEAF7EE)
        : (dt.isAfter(DateTime.now())
              ? p.accent.withValues(alpha: 0.12)
              : p.soft.withValues(alpha: 0.8));

    final statusBorder = inWindow
        ? const Color(0xFFB9E2C5)
        : (dt.isAfter(DateTime.now())
              ? p.accent.withValues(alpha: 0.28)
              : p.border.withValues(alpha: 0.8));

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Course: ${b.courseTitle.trim().isEmpty ? b.courseId : b.courseTitle}',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _expandedBookingCards[b.bookingKey] = !expanded;
                    });
                  },
                  tooltip: expanded ? 'Collapse card' : 'Expand card',
                  icon: AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: p.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _bookingInfoLine(Icons.event_rounded, 'When', when),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: statusBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: statusBorder),
              ),
              child: Row(
                children: [
                  Icon(
                    inWindow
                        ? Icons.play_circle_fill_rounded
                        : Icons.schedule_rounded,
                    color: p.primary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      statusText,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: p.primary,
                      ),
                    ),
                  ),
                  if (b.meetUrl.trim().isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _openExternalUrl(b.meetUrl),
                      icon: Icon(Icons.video_call_rounded, color: p.accent),
                      label: Text(
                        'Meet',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.accent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _openOnlineSessionDetailsSheet(
                  b.courseId,
                  b.sessionNo,
                  b.courseTitle,
                  b.learnerUids,
                  b.startAtMillis,
                  b.durationMinutes,
                ),
                icon: Icon(Icons.info_outline_rounded, color: p.accent),
                label: Text(
                  'Details',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: p.accent,
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        _bookingInfoLine(
                          Icons.person_rounded,
                          'Teacher',
                          b.teacherName,
                        ),
                        const SizedBox(height: 4),
                        _bookingInfoLine(
                          Icons.groups_rounded,
                          'Learners',
                          '${b.learnerUids.length}',
                        ),
                        const SizedBox(height: 4),
                        FutureBuilder<String>(
                          future: _loadSessionTitle(b.courseId, b.sessionNo),
                          builder: (context, snap) {
                            final title = (snap.data ?? '').trim();
                            final sNo = b.sessionNo <= 0
                                ? '-'
                                : '${b.sessionNo}';
                            final label = title.isEmpty
                                ? 'Session: $sNo'
                                : 'Session: $sNo — $title';

                            return _bookingInfoLine(
                              Icons.menu_book_rounded,
                              '',
                              label,
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: FutureBuilder<DataSnapshot>(
                                future: _db
                                    .child(
                                      '$onlineAttendanceNode/${b.bookingKey}',
                                    )
                                    .get(),
                                builder: (context, snap) {
                                  bool hasAttendance = false;
                                  bool mine = true;
                                  if (snap.hasData &&
                                      snap.data!.exists &&
                                      snap.data!.value is Map) {
                                    hasAttendance = true;
                                    final rec = Map<String, dynamic>.from(
                                      snap.data!.value as Map,
                                    );
                                    final owner = _safeStr(rec['teacherUid']);
                                    mine =
                                        owner.isEmpty || owner == _teacherUid;
                                  }

                                  final label = hasAttendance
                                      ? (mine ? 'Edit' : 'View')
                                      : 'Take';
                                  final icon = hasAttendance
                                      ? (mine
                                            ? Icons.edit_note_rounded
                                            : Icons.visibility_rounded)
                                      : Icons.fact_check_rounded;
                                  final canOpenTake =
                                      hasAttendance || classPassed;
                                  final actionBg = hasAttendance
                                      ? (mine
                                            ? const Color(0xFFD97706)
                                            : p.text.withValues(alpha: 0.55))
                                      : (classPassed
                                            ? p.accent
                                            : p.text.withValues(alpha: 0.35));

                                  return ElevatedButton.icon(
                                    icon: Icon(icon),
                                    label: Text(label),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: actionBg,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                    ),
                                    onPressed: canOpenTake
                                        ? () {
                                            if (!mine && hasAttendance) {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      _OnlineAttendanceHistoryScreen(
                                                        booking: b,
                                                        teacherUid: _teacherUid,
                                                      ),
                                                ),
                                              );
                                              return;
                                            }

                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    _OnlineTakeAttendanceScreen(
                                                      booking: b,
                                                      teacherUid: _teacherUid,
                                                      teacherName:
                                                          _teacherName.isEmpty
                                                          ? 'Teacher'
                                                          : _teacherName,
                                                    ),
                                              ),
                                            );
                                          }
                                        : null,
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: Icon(
                                  Icons.insights_rounded,
                                  color: p.primary,
                                ),
                                label: Text(
                                  'Progress',
                                  style: TextStyle(color: p.primary),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: p.border),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          _OnlineAttendanceHistoryScreen(
                                            booking: b,
                                            teacherUid: _teacherUid,
                                          ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _learnersPreview(b),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bookingInfoLine(IconData icon, String label, String value) {
    final text = label.isEmpty ? value : '$label: $value';
    return Row(
      children: [
        Icon(icon, size: 15, color: p.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.78),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _learnersPreview(_OnlineBooking b) {
    final uids = b.learnerUids;
    if (uids.isEmpty) return const SizedBox.shrink();

    final hasToggle = uids.length > 1;
    final expanded = _expandedLearnersByBooking[b.bookingKey] == true;
    final show = expanded || !hasToggle ? uids : uids.take(1).toList();
    final more = expanded ? 0 : (uids.length - show.length);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Learners',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: p.primary,
                  ),
                ),
              ),
              if (hasToggle)
                IconButton(
                  onPressed: () {
                    setState(() {
                      _expandedLearnersByBooking[b.bookingKey] = !expanded;
                    });
                  },
                  tooltip: expanded ? 'Collapse learners' : 'Show all learners',
                  icon: AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: p.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              key: ValueKey<bool>(expanded),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...show.map((uid) {
                  return FutureBuilder<Map<String, String>>(
                    future: _loadLearnerMini(uid),
                    builder: (context, snap) {
                      final full = (snap.data?['full'] ?? '').trim();
                      final profilePhotoUrl = (snap.data?['profilePhoto'] ?? '')
                          .trim();

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _openLearnerHandoffSheet(
                            learnerUid: uid,
                            courseId: b.courseId,
                            courseTitle: b.courseTitle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                _learnerAvatar(
                                  profilePhotoUrl: profilePhotoUrl,
                                  size: 28,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    full.isEmpty ? 'Learner' : full,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: p.text.withValues(alpha: 0.72),
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFFFFC15A),
                                        Color(0xFFF97316),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    borderRadius: BorderRadius.circular(9),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(
                                          0xFFF97316,
                                        ).withValues(alpha: 0.35),
                                        blurRadius: 8,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.sticky_note_2_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                }),
                if (more > 0)
                  Text(
                    '… +$more more',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: p.text.withValues(alpha: 0.72),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: p.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: p.soft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.school_outlined, color: p.primary, size: 30),
              ),
              const SizedBox(height: 14),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

class _TeacherHandoffRow {
  final String bookingKey;
  final int sessionNo;
  final bool present;
  final String dayKey;
  final String time;
  final int startAt;
  final String teacherName;
  final int teacherRating;
  final String teacherComment;
  final int noteUpdatedAt;

  const _TeacherHandoffRow({
    required this.bookingKey,
    required this.sessionNo,
    required this.present,
    required this.dayKey,
    required this.time,
    required this.startAt,
    required this.teacherName,
    required this.teacherRating,
    required this.teacherComment,
    required this.noteUpdatedAt,
  });

  bool get teacherNoteExists => teacherRating > 0 || teacherComment.isNotEmpty;

  int get sortMs {
    if (startAt > 0) return startAt;
    if (noteUpdatedAt > 0) return noteUpdatedAt;
    return 0;
  }
}

class _RatingUiTone {
  final Color star;
  final Color cardBg;
  final Color cardBorder;
  final Color chipBg;
  final Color chipText;

  const _RatingUiTone({
    required this.star,
    required this.cardBg,
    required this.cardBorder,
    required this.chipBg,
    required this.chipText,
  });
}

class _OnlineBooking {
  final String bookingKey;
  final String courseId;
  final String courseTitle;
  final String dayKey;
  final String time;
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

  static String makeKey(String courseId, String dayKey, String hhmm) =>
      '$courseId|$dayKey|$hhmm';
}

class _OnlineTakeAttendanceScreen extends StatefulWidget {
  const _OnlineTakeAttendanceScreen({
    required this.booking,
    required this.teacherUid,
    required this.teacherName,
  });

  final _OnlineBooking booking;
  final String teacherUid;
  final String teacherName;

  @override
  State<_OnlineTakeAttendanceScreen> createState() =>
      _OnlineTakeAttendanceScreenState();
}

class _OnlineTakeAttendanceScreenState
    extends State<_OnlineTakeAttendanceScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool saving = false;
  bool loadingExisting = false;
  bool canEditCurrent = true;
  String lockReason = '';

  final Map<String, bool> presentMap = {};
  final Map<String, int> teacherRatingMap = {};
  final Map<String, TextEditingController> _commentControllers = {};

  final Map<String, Map<String, String>> _localLearnerMiniCache = {};

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    for (final uid in widget.booking.learnerUids) {
      presentMap[uid] = true;
      teacherRatingMap[uid] = 0;
      _commentController(uid);
    }
    _loadExistingBookingAttendance();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    for (final c in _commentControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.show(context, humanizeUiMessage(msg), type: AppToastType.info);
  }

  Future<Map<String, String>> _loadLearnerMini(String uid) async {
    if (_localLearnerMiniCache.containsKey(uid)) {
      return _localLearnerMiniCache[uid]!;
    }

    try {
      final snap = await _db
          .child('${_TeacherClassesScreenState.usersNode}/$uid')
          .get();

      if (snap.exists && snap.value is Map) {
        final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final fn = (m['first_name'] ?? '').toString().trim();
        final ln = (m['last_name'] ?? '').toString().trim();
        final full = ('$fn $ln').trim();
        final profilePhoto = (m['profile_photo'] ?? '').toString().trim();

        final out = {
          'full': full.isEmpty ? 'Learner' : full,
          'profilePhoto': profilePhoto,
        };

        _localLearnerMiniCache[uid] = out;
        return out;
      }
    } catch (_) {}

    final out = {'full': 'Learner', 'profilePhoto': ''};
    _localLearnerMiniCache[uid] = out;
    return out;
  }

  Widget _learnerAvatar({required String profilePhotoUrl, double size = 36}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: p.soft, shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      child: profilePhotoUrl.trim().isNotEmpty
          ? Image.network(
              profilePhotoUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Icons.person_rounded,
                size: size * 0.48,
                color: p.primary,
              ),
            )
          : Icon(Icons.person_rounded, size: size * 0.48, color: p.primary),
    );
  }

  DatabaseReference _teacherAttendanceRef() => _db.child(
    '${_TeacherClassesScreenState.onlineAttendanceNode}/${widget.booking.bookingKey}',
  );

  DatabaseReference _learnerAttendanceRef(String learnerUid) => _db.child(
    '${_TeacherClassesScreenState.bookingProgressNode}/$learnerUid/${widget.booking.courseId}/online_attendance/${widget.booking.bookingKey}',
  );

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  String _safeStr(dynamic v) => (v ?? '').toString().trim();

  TextEditingController _commentController(String uid) {
    return _commentControllers.putIfAbsent(uid, TextEditingController.new);
  }

  int _normalizedRating(dynamic v) {
    final x = _toInt(v);
    if (x < 0) return 0;
    if (x > 5) return 5;
    return x;
  }

  Future<void> _loadExistingBookingAttendance() async {
    setState(() => loadingExisting = true);
    try {
      final snap = await _teacherAttendanceRef().get();
      if (snap.exists && snap.value is Map) {
        final m = Map<String, dynamic>.from(snap.value as Map);
        final ownerUid = _safeStr(m['teacherUid']);
        if (ownerUid.isNotEmpty && ownerUid != widget.teacherUid) {
          canEditCurrent = false;
          lockReason = 'Attendance was recorded by another teacher.';
        }

        final learners = m['learners'];
        if (learners is Map) {
          final lm = learners.map((k, v) => MapEntry(k.toString(), v));
          for (final uid in widget.booking.learnerUids) {
            final raw = lm[uid];
            bool present = false;
            int teacherRating = 0;
            String teacherComment = '';
            if (raw is Map) {
              final mm = raw.map((k, vv) => MapEntry(k.toString(), vv));
              present = mm['present'] == true;
              teacherRating = _normalizedRating(mm['teacherRating']);
              teacherComment = _safeStr(mm['teacherComment']);
            }
            presentMap[uid] = present;
            teacherRatingMap[uid] = teacherRating;
            _commentController(uid).text = teacherComment;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => loadingExisting = false);
  }

  Future<void> _save() async {
    if (!canEditCurrent) {
      _toast(
        lockReason.isEmpty
            ? 'You can edit only your own attendance records.'
            : lockReason,
      );
      return;
    }
    setState(() => saving = true);
    final int sessionNo = widget.booking.sessionNo;

    String sessionTitle = '';
    if (sessionNo > 0) {
      try {
        final snap = await _db
            .child(
              'booking_curriculum/${widget.booking.courseId}/sessions/$sessionNo',
            )
            .get();
        if (snap.exists && snap.value is Map) {
          final m = (snap.value as Map).map(
            (k, v) => MapEntry(k.toString(), v),
          );
          sessionTitle = (m['sessionTitle'] ?? m['title'] ?? '')
              .toString()
              .trim();
        }
      } catch (_) {}
    }

    final List<Map<String, dynamic>> taughtItems = (sessionNo > 0)
        ? [
            {
              'type': 'syllabus',
              'sessionNumber': sessionNo,
              'title': sessionTitle,
            },
          ]
        : <Map<String, dynamic>>[];

    try {
      final currentSnap = await _teacherAttendanceRef().get();
      if (currentSnap.exists && currentSnap.value is Map) {
        final m = Map<String, dynamic>.from(currentSnap.value as Map);
        final owner = _safeStr(m['teacherUid']);
        if (owner.isNotEmpty && owner != widget.teacherUid) {
          throw Exception(
            'Only the teacher who saved this attendance can edit it.',
          );
        }
      }

      final Map<String, dynamic> learners = {};
      for (final uid in widget.booking.learnerUids) {
        final rating = _normalizedRating(teacherRatingMap[uid]);
        final comment = _commentController(uid).text.trim();
        final hasTeacherNote = rating > 0 || comment.isNotEmpty;
        learners[uid] = {
          'present': presentMap[uid] == true,
          'teacherRating': rating,
          'teacherComment': comment,
          'teacherCommentUpdatedAt': hasTeacherNote ? ServerValue.timestamp : 0,
          'teacherCommentByUid': hasTeacherNote ? widget.teacherUid : '',
          'teacherCommentByName': hasTeacherNote ? widget.teacherName : '',
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

      await _teacherAttendanceRef().set(payload);

      for (final uid in widget.booking.learnerUids) {
        final isPresent = presentMap[uid] == true;
        final rating = _normalizedRating(teacherRatingMap[uid]);
        final comment = _commentController(uid).text.trim();
        final hasTeacherNote = rating > 0 || comment.isNotEmpty;
        final learnerRef = _learnerAttendanceRef(uid);
        final learnerSnap = await learnerRef.get();
        final existing = learnerSnap.exists && learnerSnap.value is Map
            ? Map<String, dynamic>.from(learnerSnap.value as Map)
            : <String, dynamic>{};
        final createdAt = existing['createdAt'];
        final countedCredit =
            onlineAttendanceRecordConsumesCredit(existing) ||
            isPresent ||
            widget.booking.sessionNo > 0;

        await learnerRef.set({
          ...existing,
          'bookingKey': widget.booking.bookingKey,
          'courseId': widget.booking.courseId,
          'dayKey': widget.booking.dayKey,
          'time': widget.booking.time,
          'startAt': widget.booking.startAtMillis,
          'teacherUid': widget.teacherUid,
          'teacherName': widget.teacherName,
          'sessionNo': widget.booking.sessionNo,
          'present': isPresent,
          'teacherRating': rating,
          'teacherComment': comment,
          'teacherCommentUpdatedAt': hasTeacherNote ? ServerValue.timestamp : 0,
          'teacherCommentByUid': hasTeacherNote ? widget.teacherUid : '',
          'teacherCommentByName': hasTeacherNote ? widget.teacherName : '',
          'taughtItems': taughtItems,
          'countedCredit': countedCredit,
          'creditCountReason':
              (existing['creditCountReason'] ?? '').toString().trim().isNotEmpty
              ? existing['creditCountReason']
              : 'teacher_attendance',
          'createdAt': createdAt ?? ServerValue.timestamp,
          'updatedAt': ServerValue.timestamp,
        });

        if (widget.booking.sessionNo > 0) {
          final curRef = _db.child(
            '${_TeacherClassesScreenState.bookingProgressNode}/$uid/${widget.booking.courseId}/currentSession',
          );

          final curSnap = await curRef.get();
          final curVal = curSnap.value;

          int cur = 0;
          if (curVal is int) {
            cur = curVal;
          } else if (curVal is num) {
            cur = curVal.toInt();
          } else {
            cur = int.tryParse(curVal?.toString() ?? '') ?? 0;
          }

          if (cur <= 0) cur = 1;

          if (isPresent) {
            final desiredNext = widget.booking.sessionNo + 1;
            if (cur < desiredNext) {
              await curRef.set(desiredNext);
            }
          } else {
            await curRef.set(widget.booking.sessionNo);
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
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Text(
          'Online Attendance',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: (saving || loadingExisting || !canEditCurrent)
                ? null
                : _save,
            icon: saving
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.accent,
                    ),
                  )
                : Icon(Icons.save_rounded, color: p.accent),
          ),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1180,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _box(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Course: ${b.courseTitle.trim().isEmpty ? b.courseId : b.courseTitle}',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: p.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'When: $when',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: p.text.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Learners: ${b.learnerUids.length}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: p.text.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Session: ${b.sessionNo > 0 ? b.sessionNo : '-'}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: p.text.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Meet: ${b.meetUrl.isEmpty ? '-' : b.meetUrl}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: p.text.withValues(alpha: 0.62),
                    ),
                  ),
                  if (loadingExisting) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: p.accent,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Loading existing attendance…',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: p.text.withValues(alpha: 0.72),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (!canEditCurrent) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Text(
                        lockReason.isEmpty
                            ? 'Read-only: only the teacher who created this attendance can edit it.'
                            : 'Read-only: $lockReason',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Colors.red.shade700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _box(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Presence',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: p.primary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (b.learnerUids.isEmpty)
                    Text(
                      'No learners found in this booking.',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: p.text.withValues(alpha: 0.72),
                      ),
                    )
                  else
                    ...b.learnerUids.map((uid) {
                      final v = presentMap[uid] == true;
                      final rating = _normalizedRating(teacherRatingMap[uid]);
                      final commentC = _commentController(uid);
                      final readOnly = !canEditCurrent || loadingExisting;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: p.border.withValues(alpha: 0.85),
                          ),
                          color: p.soft.withValues(alpha: 0.18),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: FutureBuilder<Map<String, String>>(
                                    future: _loadLearnerMini(uid),
                                    builder: (context, snap) {
                                      final name =
                                          (snap.data?['full'] ?? 'Learner')
                                              .trim();
                                      final profilePhotoUrl =
                                          (snap.data?['profilePhoto'] ?? '')
                                              .trim();

                                      return Row(
                                        children: [
                                          _learnerAvatar(
                                            profilePhotoUrl: profilePhotoUrl,
                                            size: 36,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              name.isEmpty ? 'Learner' : name,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                color: p.text,
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Switch(
                                  value: v,
                                  onChanged: readOnly
                                      ? null
                                      : (x) =>
                                            setState(() => presentMap[uid] = x),
                                  activeThumbColor: p.accent,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Teacher handoff',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: p.primary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 2,
                              children: List.generate(5, (i) {
                                final on = i < rating;
                                return IconButton(
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                    minWidth: 34,
                                    minHeight: 34,
                                  ),
                                  padding: EdgeInsets.zero,
                                  onPressed: readOnly
                                      ? null
                                      : () => setState(
                                          () => teacherRatingMap[uid] = i + 1,
                                        ),
                                  icon: Icon(
                                    on
                                        ? Icons.star_rounded
                                        : Icons.star_border_rounded,
                                    color: on ? p.accent : p.text,
                                    size: 20,
                                  ),
                                  tooltip: '${i + 1} stars',
                                );
                              }),
                            ),
                            TextField(
                              controller: commentC,
                              enabled: !readOnly,
                              minLines: 2,
                              maxLines: 3,
                              decoration: InputDecoration(
                                hintText:
                                    'Comment for next teacher (same course)',
                                filled: true,
                                fillColor: p.cardBg,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: p.border),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: p.border),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _box({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: child,
    );
  }
}

class _OnlineAttendanceHistoryScreen extends StatefulWidget {
  const _OnlineAttendanceHistoryScreen({
    required this.booking,
    required this.teacherUid,
  });

  final _OnlineBooking booking;
  final String teacherUid;

  @override
  State<_OnlineAttendanceHistoryScreen> createState() =>
      _OnlineAttendanceHistoryScreenState();
}

class _OnlineAttendanceHistoryScreenState
    extends State<_OnlineAttendanceHistoryScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final Map<String, Future<_LearnerHistoryInsight>> _learnerInsightCache = {};

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
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

  AppPalette get p => appThemeController.palette;

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  String _safeStr(dynamic v) => (v ?? '').toString().trim();

  String _formatWhen(Map<String, dynamic> rec) {
    final day = _safeStr(rec['dayKey']);
    final time = _safeStr(rec['time']);
    if (day.isNotEmpty && time.isNotEmpty) return '$day $time';
    if (day.isNotEmpty) return day;
    final ts = _toInt(rec['startAt']);
    if (ts <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.year}-${_TeacherClassesScreenState._two(d.month)}-${_TeacherClassesScreenState._two(d.day)} ${_TeacherClassesScreenState._two(d.hour)}:${_TeacherClassesScreenState._two(d.minute)}';
  }

  int _sessionNoFromRecord(Map<String, dynamic> rec) {
    final direct = _toInt(rec['sessionNo']);
    if (direct > 0) return direct;
    final taught = rec['taughtItems'];
    if (taught is List) {
      for (final it in taught) {
        if (it is! Map) continue;
        final m = it.map((k, v) => MapEntry(k.toString(), v));
        final sn = _toInt(m['sessionNumber']);
        if (sn > 0) return sn;
      }
    }
    return 0;
  }

  Future<Map<String, dynamic>?> _loadSyllabusSessionByNo(
    String courseId,
    int sessionNo,
  ) async {
    if (courseId.isEmpty || sessionNo <= 0) return null;
    try {
      final snap = await _db.child('syllabi/$courseId/flexible').get();
      if (!snap.exists || snap.value is! Map) return null;
      final root = Map<dynamic, dynamic>.from(snap.value as Map);

      final units = root['units'];
      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final um = u.map((k, v) => MapEntry(k.toString(), v));
          final sessions = um['sessions'];
          if (sessions is! List) continue;
          for (final s in sessions) {
            if (s is! Map) continue;
            final sm = s.map((k, v) => MapEntry(k.toString(), v));
            final sn = _toInt(sm['sessionNumber']);
            final order = _toInt(sm['order']);
            if (sn == sessionNo || order == sessionNo) {
              final unitTitle = _safeStr(um['title']);
              final unitOtherTitle = _safeStr(um['otherTitle']);
              final unitOrder = _toInt(um['order']);
              return {
                'sessionTitle': _safeStr(sm['title']),
                'title': _safeStr(sm['title']),
                'objective': _safeStr(sm['objective']),
                'content': _safeStr(sm['content']),
                'homework': _safeStr(sm['homework']),
                'skillType': _safeStr(sm['skillType']),
                'variantKey': 'flexible',
                'sessionNoResolved': sn > 0 ? sn : order,
                'unitTitle': unitTitle,
                'unitOtherTitle': unitOtherTitle,
                'unitOrder': unitOrder,
              };
            }
          }
        }
      }

      for (final e in root.entries) {
        final keyNo = int.tryParse(e.key.toString()) ?? 0;
        final raw = e.value;
        if (raw is! Map) continue;
        final m = raw.map((k, v) => MapEntry(k.toString(), v));
        final sn = _toInt(m['sessionNo']);
        final order = _toInt(m['order']);
        if (keyNo == sessionNo || sn == sessionNo || order == sessionNo) {
          return Map<String, dynamic>.from(m);
        }
      }
    } catch (_) {}
    return null;
  }

  int _sessionNoFromAnyRecord(Map<String, dynamic> rec) {
    final direct = _toInt(rec['sessionNo']);
    if (direct > 0) return direct;
    final taught = rec['taughtItems'];
    if (taught is List) {
      for (final it in taught) {
        if (it is! Map) continue;
        final m = it.map((k, v) => MapEntry(k.toString(), v));
        final sn = _toInt(m['sessionNumber']);
        if (sn > 0) return sn;
      }
    }
    final legacy = rec['taught'];
    if (legacy is Map) {
      final m = legacy.map((k, v) => MapEntry(k.toString(), v));
      final sn = _toInt(m['sessionNumber']);
      if (sn > 0) return sn;
    }
    return 0;
  }

  int _millisFromAnyDate(Map<String, dynamic> rec) {
    final direct = _toInt(rec['startAt']);
    if (direct > 0) return direct;
    final day = _safeStr(rec['dayKey']);
    final time = _safeStr(rec['time']);
    if (day.isNotEmpty) {
      final base = DateTime.tryParse(day);
      if (base != null) {
        var hour = 0;
        var minute = 0;
        if (time.contains(':')) {
          final parts = time.split(':');
          hour = int.tryParse(parts.first) ?? 0;
          minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
        }
        return DateTime(
          base.year,
          base.month,
          base.day,
          hour,
          minute,
        ).millisecondsSinceEpoch;
      }
    }

    final rawDate = _safeStr(rec['date']);
    if (rawDate.isNotEmpty) {
      final parsed = DateTime.tryParse(rawDate);
      if (parsed != null) return parsed.millisecondsSinceEpoch;
    }
    return 0;
  }

  String _formatShortWhen(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${_TeacherClassesScreenState._two(d.month)}-${_TeacherClassesScreenState._two(d.day)} ${_TeacherClassesScreenState._two(d.hour)}:${_TeacherClassesScreenState._two(d.minute)}';
  }

  List<String> _learnerUidsFromRecord(Map<String, dynamic> rec) {
    final out = <String>[];
    final learners = rec['learners'];
    if (learners is! Map) return out;
    final lm = learners.map((k, v) => MapEntry(k.toString(), v));
    for (final uid in lm.keys) {
      final clean = uid.trim();
      if (clean.isNotEmpty) out.add(clean);
    }
    return out;
  }

  Future<Map<int, String>> _loadSessionIdByNumber({
    required String courseId,
    required String variantKey,
  }) async {
    final out = <int, String>{};
    if (courseId.trim().isEmpty) return out;

    final variants = <String>[];
    if (variantKey.trim().isNotEmpty) variants.add(variantKey.trim());
    for (final v in const ['flexible', 'private', 'inclass']) {
      if (!variants.contains(v)) variants.add(v);
    }

    for (final v in variants) {
      try {
        final snap = await _db.child('syllabi/$courseId/$v').get();
        if (!snap.exists || snap.value is! Map) continue;
        final root = Map<String, dynamic>.from(snap.value as Map);
        final units = root['units'];
        if (units is! List) continue;

        for (final u in units) {
          if (u is! Map) continue;
          final um = Map<String, dynamic>.from(u);
          final sessions = um['sessions'];
          if (sessions is! List) continue;
          for (final s in sessions) {
            if (s is! Map) continue;
            final sm = Map<String, dynamic>.from(s);
            final sn = _toInt(sm['sessionNumber']);
            final sid = _safeStr(sm['id']);
            if (sn > 0 && sid.isNotEmpty) out[sn] = sid;
          }
        }
        if (out.isNotEmpty) return out;
      } catch (_) {}
    }

    return out;
  }

  Future<_LearnerHistoryInsight> _loadLearnerHistoryInsight(String uid) async {
    var displayName = 'Learner';
    var bio = '';

    final allSessions = <_LearnerSessionItem>[];
    final courseCards = <_LearnerCourseStudy>[];
    final coveredLessonKeys = <String>{};

    try {
      final userSnap = await _db
          .child('${_TeacherClassesScreenState.usersNode}/$uid')
          .get();
      if (userSnap.exists && userSnap.value is Map) {
        final user = Map<String, dynamic>.from(userSnap.value as Map);
        final fn = _safeStr(user['first_name']);
        final ln = _safeStr(user['last_name']);
        final full = ('$fn $ln').trim();
        if (full.isNotEmpty) displayName = full;
        bio = _safeStr(user['about_me']);

        final coursesRaw = user['courses'];
        if (coursesRaw is Map) {
          final courses = Map<dynamic, dynamic>.from(coursesRaw);
          for (final e in courses.entries) {
            if (e.value is! Map) continue;
            final c = Map<String, dynamic>.from(e.value as Map);
            final cls = c['class'] is Map
                ? Map<String, dynamic>.from(c['class'] as Map)
                : <String, dynamic>{};

            final courseId = _safeStr(cls['course_id'] ?? c['id']);
            final courseTitle = _safeStr(c['title'] ?? c['course_title']);
            final variantKey = _safeStr(
              c['variantKey'] ?? c['variant'] ?? c['deliveryKey'],
            ).toLowerCase();

            final sessionIdByNumber = await _loadSessionIdByNumber(
              courseId: courseId,
              variantKey: variantKey,
            );

            var inClassCount = 0;
            var onlineCount = 0;
            var presentCount = 0;
            final localCovered = <String>{};

            final attendance = c['attendance'];
            if (attendance is Map) {
              final attMap = Map<dynamic, dynamic>.from(attendance);
              for (final v in attMap.values) {
                if (v is! Map) continue;
                final rec = Map<String, dynamic>.from(v);
                inClassCount += 1;
                final present =
                    _safeStr(rec['status']).toLowerCase() == 'present';
                if (present) presentCount += 1;

                final sn = _sessionNoFromAnyRecord(rec);
                final ms = _millisFromAnyDate(rec);
                allSessions.add(
                  _LearnerSessionItem(
                    source: 'In-class',
                    courseLabel: courseTitle.isEmpty
                        ? (courseId.isEmpty ? e.key.toString() : courseId)
                        : courseTitle,
                    sessionNo: sn,
                    present: present,
                    whenLabel: _formatShortWhen(ms),
                    sortMs: ms,
                  ),
                );

                final taughtItems = rec['taughtItems'];
                var usedNew = false;
                if (taughtItems is List) {
                  usedNew = true;
                  for (final it in taughtItems) {
                    if (it is! Map) continue;
                    final item = Map<String, dynamic>.from(it);
                    if (_safeStr(item['type']).toLowerCase() != 'syllabus') {
                      continue;
                    }
                    final sid = _safeStr(item['sessionId']);
                    final n = _toInt(item['sessionNumber']);
                    if (sid.isNotEmpty) {
                      localCovered.add(sid);
                    } else if (n > 0) {
                      localCovered.add(sessionIdByNumber[n] ?? 'sn:$n');
                    }
                  }
                }

                if (!usedNew) {
                  final taught = rec['taught'];
                  if (taught is Map) {
                    final tm = Map<String, dynamic>.from(taught);
                    final sid = _safeStr(tm['sessionId']);
                    final n = _toInt(tm['sessionNumber']);
                    if (sid.isNotEmpty) {
                      localCovered.add(sid);
                    } else if (n > 0) {
                      localCovered.add(sessionIdByNumber[n] ?? 'sn:$n');
                    }
                  }
                }
              }
            }

            if (uid.isNotEmpty && courseId.isNotEmpty) {
              try {
                final onlineSnap = await _db
                    .child(
                      '${_TeacherClassesScreenState.bookingProgressNode}/$uid/$courseId/online_attendance',
                    )
                    .get();
                if (onlineSnap.exists && onlineSnap.value is Map) {
                  final online = Map<dynamic, dynamic>.from(
                    onlineSnap.value as Map,
                  );
                  for (final raw in online.values) {
                    if (raw is! Map) continue;
                    final rec = Map<String, dynamic>.from(raw);
                    onlineCount += 1;
                    final present = rec['present'] == true;
                    if (present) presentCount += 1;

                    final sn = _sessionNoFromAnyRecord(rec);
                    final ms = _millisFromAnyDate(rec);
                    allSessions.add(
                      _LearnerSessionItem(
                        source: 'Online',
                        courseLabel: courseTitle.isEmpty
                            ? courseId
                            : courseTitle,
                        sessionNo: sn,
                        present: present,
                        whenLabel: _formatShortWhen(ms),
                        sortMs: ms,
                      ),
                    );

                    final taughtItems = rec['taughtItems'];
                    if (taughtItems is List) {
                      for (final it in taughtItems) {
                        if (it is! Map) continue;
                        final item = Map<String, dynamic>.from(it);
                        if (_safeStr(item['type']).toLowerCase() !=
                            'syllabus') {
                          continue;
                        }
                        final sid = _safeStr(item['sessionId']);
                        final n = _toInt(item['sessionNumber']);
                        if (sid.isNotEmpty) {
                          localCovered.add(sid);
                        } else if (n > 0) {
                          localCovered.add(sessionIdByNumber[n] ?? 'sn:$n');
                        }
                      }
                    } else if (sn > 0) {
                      localCovered.add(sessionIdByNumber[sn] ?? 'sn:$sn');
                    }
                  }
                }
              } catch (_) {}
            }

            coveredLessonKeys.addAll(localCovered);
            courseCards.add(
              _LearnerCourseStudy(
                courseLabel: courseTitle.isEmpty
                    ? (courseId.isEmpty ? e.key.toString() : courseId)
                    : courseTitle,
                sessionsCount: inClassCount + onlineCount,
                presentCount: presentCount,
                lessonsCovered: localCovered.length,
              ),
            );
          }
        }
      }
    } catch (_) {}

    allSessions.sort((a, b) => b.sortMs.compareTo(a.sortMs));
    courseCards.sort((a, b) => b.sessionsCount.compareTo(a.sessionsCount));

    return _LearnerHistoryInsight(
      uid: uid,
      displayName: displayName,
      bio: bio,
      courses: courseCards,
      sessions: allSessions,
      totalLessonsCovered: coveredLessonKeys.length,
    );
  }

  Future<_LearnerHistoryInsight> _insightFor(String uid) {
    return _learnerInsightCache.putIfAbsent(
      uid,
      () => _loadLearnerHistoryInsight(uid),
    );
  }

  Widget _metricTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: p.text.withValues(alpha: 0.7),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.w900, color: p.primary),
          ),
        ],
      ),
    );
  }

  bool _isInJoinWindow(DateTime startsAt, int durationMinutes) {
    final now = DateTime.now();
    final startJoin = startsAt.subtract(const Duration(minutes: 10));
    final endJoin = startsAt.add(Duration(minutes: durationMinutes + 30));
    return !now.isBefore(startJoin) && !now.isAfter(endJoin);
  }

  Widget _buildCourseDetailsTab(
    Map<String, dynamic> rec,
    int sessionNo,
    Map<String, dynamic>? info,
  ) {
    final title = _safeStr(info?['sessionTitle']).isNotEmpty
        ? _safeStr(info?['sessionTitle'])
        : _safeStr(info?['title']);
    final objective = _safeStr(info?['objective']);
    final content = _safeStr(info?['content']);
    final homework = _safeStr(info?['homework']);
    final skillType = _safeStr(info?['skillType']);
    final unitTitle = _safeStr(info?['unitTitle']);
    final unitOrder = _toInt(info?['unitOrder']);
    final unitOtherTitle = _safeStr(info?['unitOtherTitle']);
    final variantKey = _safeStr(info?['variantKey']).toLowerCase();
    final unitLabel = unitTitle.isEmpty
        ? '-'
        : (unitOrder > 0 ? 'Unit $unitOrder: $unitTitle' : unitTitle);

    final variantLabel = switch (variantKey) {
      'inclass' => 'In-Class',
      'private' => 'Private',
      'flexible' => 'Flexible',
      'recorded' => 'Recorded',
      _ => '-',
    };

    final startAt = _toInt(rec['startAt']);
    final duration = _toInt(rec['durationMinutes']);
    final startDt = startAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(startAt)
        : DateTime.now();
    final inWindow = startAt > 0 ? _isInJoinWindow(startDt, duration) : false;
    final isUpcoming =
        startAt > 0 && startDt.isAfter(DateTime.now()) && !inWindow;
    final statusText = inWindow ? 'Live' : (isUpcoming ? 'Upcoming' : 'Past');
    final statusBg = inWindow
        ? const Color(0xFFEAF7EE)
        : (isUpcoming
              ? p.accent.withValues(alpha: 0.12)
              : p.soft.withValues(alpha: 0.65));
    final statusBorder = inWindow
        ? const Color(0xFFB9E2C5)
        : (isUpcoming
              ? p.accent.withValues(alpha: 0.28)
              : p.border.withValues(alpha: 0.82));
    final statusColor = inWindow ? const Color(0xFF166534) : p.primary;

    String whenText() {
      if (startAt <= 0) return '-';
      return '${startDt.year}-${_TeacherClassesScreenState._two(startDt.month)}-${_TeacherClassesScreenState._two(startDt.day)} ${_TeacherClassesScreenState._two(startDt.hour)}:${_TeacherClassesScreenState._two(startDt.minute)}';
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.soft.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title.isEmpty
                            ? 'Session ${sessionNo <= 0 ? '-' : sessionNo}'
                            : 'Session $sessionNo — $title',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: statusBg,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: statusBorder),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  whenText(),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: p.text.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _historyDetailsChip(
                Icons.layers_rounded,
                'Variant',
                variantLabel,
              ),
              _historyDetailsChip(Icons.widgets_rounded, 'Unit', unitLabel),
              _historyDetailsChip(
                Icons.school_rounded,
                'Skill',
                skillType.isEmpty ? '-' : skillType,
              ),
              _historyDetailsChip(
                Icons.timer_outlined,
                'Duration',
                duration > 0 ? '$duration min' : '-',
              ),
              if (unitOtherTitle.isNotEmpty)
                _historyDetailsChip(
                  Icons.category_rounded,
                  'Module',
                  unitOtherTitle,
                ),
            ],
          ),
          const SizedBox(height: 12),
          _historyDetailsSectionCard(
            icon: Icons.flag_rounded,
            iconColor: const Color(0xFFCC5803),
            title: 'Objective',
            body: objective,
          ),
          const SizedBox(height: 10),
          _historyDetailsSectionCard(
            icon: Icons.list_alt_rounded,
            iconColor: const Color(0xFF0D9488),
            title: 'Lesson content',
            body: content,
          ),
          const SizedBox(height: 10),
          _historyDetailsSectionCard(
            icon: Icons.assignment_rounded,
            iconColor: const Color(0xFFB45309),
            title: 'Homework',
            body: homework,
          ),
        ],
      ),
    );
  }

  Widget _historyDetailsChip(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border.withValues(alpha: 0.84)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: p.accent),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: p.text.withValues(alpha: 0.84),
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyDetailsSectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String body,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.w900, color: p.primary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body.isEmpty ? '-' : body,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: p.text.withValues(alpha: 0.8),
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLearnersTab(List<String> learnerUids) {
    if (learnerUids.isEmpty) {
      return Center(
        child: Text(
          'No learners found in this attendance record.',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: p.text.withValues(alpha: 0.78),
          ),
        ),
      );
    }

    var selectedUid = learnerUids.first;
    return StatefulBuilder(
      builder: (context, setLocal) {
        return Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: learnerUids.map((uid) {
                  return FutureBuilder<_LearnerHistoryInsight>(
                    future: _insightFor(uid),
                    builder: (context, snap) {
                      final name = (snap.data?.displayName ?? 'Learner').trim();
                      return ChoiceChip(
                        selected: selectedUid == uid,
                        onSelected: (_) => setLocal(() => selectedUid = uid),
                        label: Text(name.isEmpty ? 'Learner' : name),
                        labelStyle: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: selectedUid == uid ? Colors.white : p.primary,
                        ),
                        backgroundColor: p.cardBg,
                        selectedColor: p.accent,
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: p.border.withValues(alpha: 0.8),
                          ),
                        ),
                      );
                    },
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: FutureBuilder<_LearnerHistoryInsight>(
                future: _insightFor(selectedUid),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: CircularProgressIndicator(color: p.accent),
                    );
                  }

                  final data = snap.data;
                  if (data == null) {
                    return Center(
                      child: Text(
                        'Could not load learner details.',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: p.text.withValues(alpha: 0.78),
                        ),
                      ),
                    );
                  }

                  final totalSessions = data.sessions.length;
                  return ListView(
                    children: [
                      Text(
                        data.displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        data.bio.isEmpty ? 'No profile bio yet.' : data.bio,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: p.text.withValues(alpha: 0.82),
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _metricTile('Courses', '${data.courses.length}'),
                          _metricTile('Sessions', '$totalSessions'),
                          _metricTile(
                            'Lessons covered',
                            '${data.totalLessonsCovered}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Courses Studied',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (data.courses.isEmpty)
                        Text(
                          'No courses found.',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: p.text.withValues(alpha: 0.75),
                          ),
                        )
                      else
                        ...data.courses.map((c) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: p.soft.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: p.border.withValues(alpha: 0.84),
                              ),
                            ),
                            child: Text(
                              '${c.courseLabel} • Sessions ${c.sessionsCount} • Present ${c.presentCount} • Lessons ${c.lessonsCovered}',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: p.text.withValues(alpha: 0.84),
                              ),
                            ),
                          );
                        }),
                      const SizedBox(height: 12),
                      Text(
                        'Session Timeline',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (data.sessions.isEmpty)
                        Text(
                          'No sessions recorded yet.',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: p.text.withValues(alpha: 0.75),
                          ),
                        )
                      else
                        ...data.sessions.map((s) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: p.cardBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: p.border.withValues(alpha: 0.84),
                              ),
                            ),
                            child: Text(
                              '${s.whenLabel} • ${s.source} • ${s.courseLabel} • Session ${s.sessionNo <= 0 ? '-' : s.sessionNo} • ${s.present ? 'Present' : 'Absent'}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: p.text.withValues(alpha: 0.82),
                              ),
                            ),
                          );
                        }),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSessionDetails(
    Map<String, dynamic> rec,
    int sessionNo,
  ) async {
    final courseId = _safeStr(rec['courseId']);
    final info = sessionNo > 0
        ? await _loadSyllabusSessionByNo(courseId, sessionNo)
        : null;
    final learnerUids = _learnerUidsFromRecord(rec);

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final h = MediaQuery.of(context).size.height;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Container(
              height: h * 0.84,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.cardBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.border.withValues(alpha: 0.85)),
              ),
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: p.soft.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TabBar(
                        labelColor: p.primary,
                        unselectedLabelColor: p.text.withValues(alpha: 0.62),
                        indicatorColor: p.accent,
                        tabs: const [
                          Tab(text: 'Course Details'),
                          Tab(text: 'Learners'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildCourseDetailsTab(rec, sessionNo, info),
                          _buildLearnersTab(learnerUids),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<int> _resolveSessionNoFromReservations(
    Map<String, dynamic> rec,
  ) async {
    final courseId = _safeStr(rec['courseId']);
    final dayKey = _safeStr(rec['dayKey']);
    final time = _safeStr(rec['time']);
    final wantedTeacherId = _safeStr(rec['teacherId']);
    final wantedTeacherUid = _safeStr(rec['teacherUid']);
    if (courseId.isEmpty || dayKey.isEmpty || time.isEmpty) return 0;

    try {
      final snap = await _db
          .child('booking_reservations/$courseId/$dayKey/$time')
          .get();
      if (!snap.exists || snap.value is! Map) return 0;

      int readSessionNo(Map<dynamic, dynamic> slot) {
        final sn = _toInt(slot['sessionNo']);
        return sn > 0 ? sn : 0;
      }

      bool matchesTeacher(Map<dynamic, dynamic> slot, String keyFallback) {
        final sid = _safeStr(
          slot['teacherId'] ?? slot['teacherUid'] ?? slot['teacher_id'],
        );
        if (wantedTeacherId.isNotEmpty && sid == wantedTeacherId) return true;
        if (wantedTeacherUid.isNotEmpty && sid == wantedTeacherUid) return true;
        if (wantedTeacherId.isNotEmpty && keyFallback == wantedTeacherId) {
          return true;
        }
        if (wantedTeacherUid.isNotEmpty && keyFallback == wantedTeacherUid) {
          return true;
        }
        return false;
      }

      final root = Map<dynamic, dynamic>.from(snap.value as Map);
      final looksDirect =
          root.containsKey('sessionNo') ||
          root.containsKey('teacherId') ||
          root.containsKey('teacherUid') ||
          root.containsKey('learners');

      if (looksDirect) {
        return readSessionNo(root);
      }

      int fallback = 0;
      for (final e in root.entries) {
        if (e.value is! Map) continue;
        final slot = Map<dynamic, dynamic>.from(e.value as Map);
        final sn = readSessionNo(slot);
        if (sn <= 0) continue;
        if (matchesTeacher(slot, e.key.toString())) return sn;
        if (fallback <= 0) fallback = sn;
      }

      return fallback;
    } catch (_) {
      return 0;
    }
  }

  Future<List<Map<String, dynamic>>> _loadHistoryRows() async {
    final out = <Map<String, dynamic>>[];
    try {
      final snap = await _db
          .child(_TeacherClassesScreenState.onlineAttendanceNode)
          .get();
      if (!snap.exists || snap.value is! Map) return out;

      final m = Map<dynamic, dynamic>.from(snap.value as Map);
      for (final e in m.entries) {
        final raw = e.value;
        if (raw is! Map) continue;
        final rec = Map<String, dynamic>.from(raw);
        final teacherUid = _safeStr(rec['teacherUid']);
        final courseId = _safeStr(rec['courseId']);
        if (teacherUid != widget.teacherUid) continue;
        if (courseId != widget.booking.courseId) continue;

        var sessionNo = _sessionNoFromRecord(rec);
        if (sessionNo <= 0) {
          sessionNo = await _resolveSessionNoFromReservations(rec);
        }

        final learners = rec['learners'];
        var presentCount = 0;
        var absentCount = 0;
        if (learners is Map) {
          final lm = learners.map((k, v) => MapEntry(k.toString(), v));
          for (final v in lm.values) {
            if (v is! Map) continue;
            final mm = v.map((k, vv) => MapEntry(k.toString(), vv));
            if (mm['present'] == true) {
              presentCount += 1;
            } else {
              absentCount += 1;
            }
          }
        }

        out.add({
          'bookingKey': e.key.toString(),
          ...rec,
          'resolvedSessionNo': sessionNo,
          'presentCount': presentCount,
          'absentCount': absentCount,
        });
      }
    } catch (_) {}

    out.sort((a, b) => _toInt(b['startAt']).compareTo(_toInt(a['startAt'])));
    return out;
  }

  Future<int> _loadCourseLessonCount(String courseId) async {
    if (courseId.isEmpty) return 0;
    try {
      final snap = await _db.child('syllabi/$courseId/flexible').get();
      if (!snap.exists || snap.value is! Map) return 0;
      final root = Map<dynamic, dynamic>.from(snap.value as Map);

      final units = root['units'];
      if (units is List) {
        var count = 0;
        for (final u in units) {
          if (u is! Map) continue;
          final um = u.map((k, v) => MapEntry(k.toString(), v));
          final sessions = um['sessions'];
          if (sessions is List) {
            count += sessions.whereType<Map>().length;
          }
        }
        if (count > 0) return count;
      }

      final seen = <int>{};
      for (final e in root.entries) {
        if (e.value is! Map) continue;
        final m = (e.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final keyNo = int.tryParse(e.key.toString()) ?? 0;
        final sn = _toInt(m['sessionNo']);
        final order = _toInt(m['order']);
        final n = sn > 0 ? sn : (order > 0 ? order : keyNo);
        if (n > 0) seen.add(n);
      }
      return seen.length;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Text(
          'Online Progress',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1240,
        child: FutureBuilder<List<dynamic>>(
          future: Future.wait<dynamic>([
            _loadHistoryRows(),
            _loadCourseLessonCount(widget.booking.courseId),
          ]),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return Center(child: CircularProgressIndicator(color: p.accent));
            }
            final loaded = snap.data ?? const <dynamic>[];
            final rows = loaded.isNotEmpty
                ? List<Map<String, dynamic>>.from(loaded.first as List)
                : const <Map<String, dynamic>>[];
            final totalCourseLessons = loaded.length > 1
                ? (loaded[1] as int)
                : 0;

            final uniqueSessionNos = <int>{};
            var totalPresent = 0;
            var totalAbsent = 0;
            var learnersMarks = 0;
            var lastSessionAt = 0;
            for (final rec in rows) {
              final startAt = _toInt(rec['startAt']);
              if (startAt > lastSessionAt) lastSessionAt = startAt;
              final resolved = _toInt(rec['resolvedSessionNo']);
              if (resolved > 0) uniqueSessionNos.add(resolved);
              final taught = rec['taughtItems'];
              if (taught is List) {
                for (final it in taught) {
                  if (it is! Map) continue;
                  final mm = it.map((k, v) => MapEntry(k.toString(), v));
                  final sn = _toInt(mm['sessionNumber']);
                  if (sn > 0) uniqueSessionNos.add(sn);
                }
              }
              final presentCount = _toInt(rec['presentCount']);
              final absentCount = _toInt(rec['absentCount']);
              totalPresent += presentCount;
              totalAbsent += absentCount;
              learnersMarks += presentCount + absentCount;
            }
            final totalSessions = rows.length;
            final avgLearnersPerSession = totalSessions <= 0
                ? 0.0
                : (learnersMarks / totalSessions);

            if (rows.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No online attendance history found yet.',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: p.text,
                    ),
                  ),
                ),
              );
            }

            return ListView(
              padding: const EdgeInsets.all(14),
              children: [
                _box(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Course: ${widget.booking.courseTitle.trim().isEmpty ? widget.booking.courseId : widget.booking.courseTitle}',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _metricRow('Sessions with attendance', '$totalSessions'),
                      const SizedBox(height: 8),
                      _metricRow('Total Present marks', '$totalPresent'),
                      const SizedBox(height: 8),
                      _metricRow('Total Absent marks', '$totalAbsent'),
                      const SizedBox(height: 8),
                      _metricRow(
                        'Unique lessons taught',
                        '${uniqueSessionNos.length}${totalCourseLessons > 0 ? ' / $totalCourseLessons' : ''}',
                      ),
                      const SizedBox(height: 8),
                      _metricRow(
                        'Avg learners per session',
                        avgLearnersPerSession.toStringAsFixed(1),
                      ),
                      const SizedBox(height: 8),
                      _metricRow(
                        'Last session',
                        lastSessionAt > 0
                            ? DateFormat('yyyy-MM-dd HH:mm').format(
                                DateTime.fromMillisecondsSinceEpoch(
                                  lastSessionAt,
                                ),
                              )
                            : '-',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Course progress',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: p.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          minHeight: 10,
                          value: (totalCourseLessons <= 0)
                              ? 0
                              : (uniqueSessionNos.length / totalCourseLessons)
                                    .clamp(0, 1),
                          backgroundColor: p.soft,
                          color: p.accent,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ...rows.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final rec = entry.value;
                  final sessionNo = _toInt(rec['resolvedSessionNo']);
                  final when = _formatWhen(rec);
                  final learners = rec['learners'];
                  final startAt = _toInt(rec['startAt']);
                  final duration = _toInt(rec['durationMinutes']);
                  final startDt = startAt > 0
                      ? DateTime.fromMillisecondsSinceEpoch(startAt)
                      : null;
                  final inWindow = startDt != null
                      ? _isInJoinWindow(startDt, duration)
                      : false;
                  final isUpcoming =
                      startDt != null &&
                      startDt.isAfter(DateTime.now()) &&
                      !inWindow;
                  final statusText = inWindow
                      ? 'Live'
                      : (isUpcoming ? 'Upcoming' : 'Past');
                  final statusBg = inWindow
                      ? const Color(0xFFEAF7EE)
                      : (isUpcoming
                            ? p.accent.withValues(alpha: 0.12)
                            : p.soft.withValues(alpha: 0.65));
                  final statusBorder = inWindow
                      ? const Color(0xFFB9E2C5)
                      : (isUpcoming
                            ? p.accent.withValues(alpha: 0.28)
                            : p.border.withValues(alpha: 0.82));
                  final statusColor = inWindow
                      ? const Color(0xFF166534)
                      : p.primary;
                  final presentCount = _toInt(rec['presentCount']);
                  final absentCount = _toInt(rec['absentCount']);
                  final animMs = 180 + (idx * 40);
                  final durationMs = animMs > 520 ? 520 : animMs;

                  return TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: Duration(milliseconds: durationMs),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) {
                      return Opacity(
                        opacity: t,
                        child: Transform.translate(
                          offset: Offset(0, (1 - t) * 12),
                          child: child,
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _box(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Session ${sessionNo <= 0 ? '-' : sessionNo} • $when',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: p.primary,
                                    ),
                                  ),
                                ),
                                Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusBg,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: statusBorder),
                                  ),
                                  child: Text(
                                    statusText,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: statusColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  borderRadius: BorderRadius.circular(999),
                                  onTap: () =>
                                      _openSessionDetails(rec, sessionNo),
                                  child: Container(
                                    width: 24,
                                    height: 24,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: p.border.withValues(alpha: 0.82),
                                      ),
                                    ),
                                    child: Text(
                                      '!',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: p.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _historyDetailsChip(
                                  Icons.check_circle_outline_rounded,
                                  'Present',
                                  '$presentCount',
                                ),
                                _historyDetailsChip(
                                  Icons.cancel_outlined,
                                  'Absent',
                                  '$absentCount',
                                ),
                                if (duration > 0)
                                  _historyDetailsChip(
                                    Icons.timer_outlined,
                                    'Duration',
                                    '$duration min',
                                  ),
                              ],
                            ),
                            if (sessionNo > 0) ...[
                              const SizedBox(height: 6),
                              FutureBuilder<Map<String, dynamic>?>(
                                future: _loadSyllabusSessionByNo(
                                  _safeStr(rec['courseId']),
                                  sessionNo,
                                ),
                                builder: (context, infoSnap) {
                                  final info = infoSnap.data;
                                  final title = _safeStr(
                                    info?['sessionTitle'] ?? info?['title'],
                                  );
                                  final skill = _safeStr(info?['skillType']);
                                  final unitTitle = _safeStr(
                                    info?['unitTitle'],
                                  );
                                  final unitOrder = _toInt(info?['unitOrder']);
                                  final unitLabel = unitTitle.isEmpty
                                      ? '-'
                                      : (unitOrder > 0
                                            ? 'Unit $unitOrder: $unitTitle'
                                            : unitTitle);
                                  if (title.isEmpty && skill.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _historyDetailsChip(
                                        Icons.menu_book_rounded,
                                        'Lesson',
                                        title.isEmpty ? '-' : title,
                                      ),
                                      _historyDetailsChip(
                                        Icons.widgets_rounded,
                                        'Unit',
                                        unitLabel,
                                      ),
                                      if (skill.isNotEmpty)
                                        _historyDetailsChip(
                                          Icons.school_rounded,
                                          'Skill',
                                          skill,
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ],
                            const SizedBox(height: 8),
                            if (learners is Map && learners.isNotEmpty)
                              ...learners.entries.map((entry) {
                                final uid = entry.key.toString();
                                final raw = entry.value;
                                bool present = false;
                                if (raw is Map) {
                                  final mm = raw.map(
                                    (k, vv) => MapEntry(k.toString(), vv),
                                  );
                                  present = mm['present'] == true;
                                }

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: FutureBuilder<DataSnapshot>(
                                    future: _db
                                        .child(
                                          '${_TeacherClassesScreenState.usersNode}/$uid',
                                        )
                                        .get(),
                                    builder: (context, userSnap) {
                                      var name = 'Learner';
                                      if (userSnap.hasData &&
                                          userSnap.data!.exists &&
                                          userSnap.data!.value is Map) {
                                        final um = (userSnap.data!.value as Map)
                                            .map(
                                              (k, v) =>
                                                  MapEntry(k.toString(), v),
                                            );
                                        final fn = _safeStr(um['first_name']);
                                        final ln = _safeStr(um['last_name']);
                                        final full = ('$fn $ln').trim();
                                        if (full.isNotEmpty) name = full;
                                      }

                                      return Text(
                                        '$name — ${present ? 'Present' : 'Absent'}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: p.text.withValues(alpha: 0.8),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              })
                            else
                              Text(
                                'No learners map saved.',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: p.text.withValues(alpha: 0.72),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _box({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: child,
    );
  }

  Widget _metricRow(String label, String value) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: p.text.withValues(alpha: 0.78),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w900, color: p.primary),
        ),
      ],
    );
  }
}

class _LearnerHistoryInsight {
  final String uid;
  final String displayName;
  final String bio;
  final List<_LearnerCourseStudy> courses;
  final List<_LearnerSessionItem> sessions;
  final int totalLessonsCovered;

  const _LearnerHistoryInsight({
    required this.uid,
    required this.displayName,
    required this.bio,
    required this.courses,
    required this.sessions,
    required this.totalLessonsCovered,
  });
}

class _LearnerCourseStudy {
  final String courseLabel;
  final int sessionsCount;
  final int presentCount;
  final int lessonsCovered;

  const _LearnerCourseStudy({
    required this.courseLabel,
    required this.sessionsCount,
    required this.presentCount,
    required this.lessonsCovered,
  });
}

class _LearnerSessionItem {
  final String source;
  final String courseLabel;
  final int sessionNo;
  final bool present;
  final String whenLabel;
  final int sortMs;

  const _LearnerSessionItem({
    required this.source,
    required this.courseLabel,
    required this.sessionNo,
    required this.present,
    required this.whenLabel,
    required this.sortMs,
  });
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
  State<OnlineAttendanceStatsScreen> createState() =>
      _OnlineAttendanceStatsScreenState();
}

class _OnlineAttendanceStatsScreenState
    extends State<OnlineAttendanceStatsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool loading = true;
  int totalSessions = 0;
  int presentCount = 0;
  int absentCount = 0;
  int uniqueSessionsTaught = 0;
  int totalCourseLessons = 0;
  double avgLearnersPerSession = 0;
  int lastSessionAt = 0;

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

  AppPalette get p => appThemeController.palette;

  int _toInt(dynamic v, {int fallback = 0}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  String _safeStr(dynamic v) => (v ?? '').toString().trim();

  Future<int> _loadCourseLessonCount(String courseId) async {
    if (courseId.isEmpty) return 0;
    try {
      final snap = await _db.child('syllabi/$courseId/flexible').get();
      if (!snap.exists || snap.value is! Map) return 0;
      final root = Map<dynamic, dynamic>.from(snap.value as Map);

      final units = root['units'];
      if (units is List) {
        var count = 0;
        for (final u in units) {
          if (u is! Map) continue;
          final um = u.map((k, v) => MapEntry(k.toString(), v));
          final sessions = um['sessions'];
          if (sessions is List) {
            count += sessions.whereType<Map>().length;
          }
        }
        if (count > 0) return count;
      }

      final seen = <int>{};
      for (final e in root.entries) {
        if (e.value is! Map) continue;
        final m = (e.value as Map).map((k, v) => MapEntry(k.toString(), v));
        final keyNo = int.tryParse(e.key.toString()) ?? 0;
        final sn = _toInt(m['sessionNo']);
        final order = _toInt(m['order']);
        final n = sn > 0 ? sn : (order > 0 ? order : keyNo);
        if (n > 0) seen.add(n);
      }
      return seen.length;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _load() async {
    setState(() => loading = true);

    int sessions = 0;
    int present = 0;
    int absent = 0;
    int lastAt = 0;
    final uniqueSessionNos = <int>{};
    int learnersMarks = 0;

    try {
      final snap = await _db
          .child(_TeacherClassesScreenState.onlineAttendanceNode)
          .get();
      if (snap.exists && snap.value is Map) {
        final m = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final entry in m.entries) {
          if (entry.value is! Map) continue;
          final rec = Map<String, dynamic>.from(entry.value as Map);

          final teacherUid = _safeStr(rec['teacherUid']);
          final courseId = _safeStr(rec['courseId']);
          if (teacherUid != widget.teacherUid) continue;
          if (widget.courseId.isNotEmpty && courseId != widget.courseId) {
            continue;
          }

          sessions++;
          final startAt = _toInt(rec['startAt']);
          if (startAt > lastAt) lastAt = startAt;

          final directSessionNo = _toInt(rec['sessionNo']);
          if (directSessionNo > 0) uniqueSessionNos.add(directSessionNo);
          final taught = rec['taughtItems'];
          if (taught is List) {
            for (final it in taught) {
              if (it is! Map) continue;
              final mm = it.map((k, v) => MapEntry(k.toString(), v));
              final sn = _toInt(mm['sessionNumber']);
              if (sn > 0) uniqueSessionNos.add(sn);
            }
          }

          final learners = rec['learners'];
          if (learners is Map) {
            final lm = learners.map((k, v) => MapEntry(k.toString(), v));
            for (final v in lm.values) {
              if (v is Map) {
                final mm = v.map((k, vv) => MapEntry(k.toString(), vv));
                if (mm['present'] == true) {
                  present++;
                } else {
                  absent++;
                }
                learnersMarks++;
              }
            }
          }
        }
      }
    } catch (_) {}

    final lessons = await _loadCourseLessonCount(widget.courseId);
    final avgLearners = sessions <= 0 ? 0.0 : (learnersMarks / sessions);

    setState(() {
      totalSessions = sessions;
      presentCount = present;
      absentCount = absent;
      uniqueSessionsTaught = uniqueSessionNos.length;
      totalCourseLessons = lessons;
      avgLearnersPerSession = avgLearners;
      lastSessionAt = lastAt;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Text(
          'Online Stats',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1040,
        child: loading
            ? Center(child: CircularProgressIndicator(color: p.accent))
            : ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _box(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Course: ${widget.courseTitle.trim().isEmpty ? widget.courseId : widget.courseTitle}',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: p.primary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _statLine('Sessions with attendance', '$totalSessions'),
                        const SizedBox(height: 8),
                        _statLine('Total Present marks', '$presentCount'),
                        const SizedBox(height: 8),
                        _statLine('Total Absent marks', '$absentCount'),
                        const SizedBox(height: 8),
                        _statLine(
                          'Unique lessons taught',
                          '$uniqueSessionsTaught${totalCourseLessons > 0 ? ' / $totalCourseLessons' : ''}',
                        ),
                        const SizedBox(height: 8),
                        _statLine(
                          'Avg learners per session',
                          avgLearnersPerSession.toStringAsFixed(1),
                        ),
                        const SizedBox(height: 8),
                        _statLine(
                          'Last session',
                          lastSessionAt > 0
                              ? DateFormat('yyyy-MM-dd HH:mm').format(
                                  DateTime.fromMillisecondsSinceEpoch(
                                    lastSessionAt,
                                  ),
                                )
                              : '-',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Course progress',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: p.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            minHeight: 10,
                            value: (totalCourseLessons <= 0)
                                ? 0
                                : (uniqueSessionsTaught / totalCourseLessons)
                                      .clamp(0, 1),
                            backgroundColor: p.soft,
                            color: p.accent,
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

  Widget _statLine(String label, String value) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: p.text.withValues(alpha: 0.78),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w900, color: p.primary),
        ),
      ],
    );
  }

  Widget _box({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: child,
    );
  }
}
